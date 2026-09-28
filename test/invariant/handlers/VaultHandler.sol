// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {TuoVault} from "../../../src/TuoVault.sol";
import {TuoPositionNFT} from "../../../src/TuoPositionNFT.sol";
import {ITuoVault} from "../../../src/interfaces/ITuoVault.sol";
import {PoolTwap} from "../../../src/libraries/PoolTwap.sol";
import {LiquidityAmounts} from "../../../src/vendor/uniswap/LiquidityAmounts.sol";
import {TuoConstants} from "../../../src/libraries/TuoConstants.sol";
import {MockAggregator} from "../../mocks/MockAggregator.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockPositionManager} from "../../mocks/MockPositionManager.sol";
import {MockUniswapV3Pool} from "../../mocks/MockUniswapV3Pool.sol";
import {MockWETH} from "../../mocks/MockWETH.sol";

/// @dev Stateful fuzz driver. Every vault entry point is exercised with bounded
///      inputs under fail_on_revert = false; ghost state lets the invariant contract
///      check attribution, basis accounting, and value-conservation afterwards.
contract VaultHandler is Test {
    TuoVault public vault;
    TuoPositionNFT public nft;
    MockERC20 public usdc;
    MockWETH public weth;
    MockUniswapV3Pool public wethPool;
    MockPositionManager public npm;
    MockAggregator public aggregator;

    address public keeper;
    address public pauser;
    address public treasury;

    /// @dev One operator per position, allowlisted and approved on first use, because
    ///      the vault binds them one-to-one for life: two fixed operators would let only
    ///      two positions ever bridge and hollow out every inbound-leg property.
    address[] public operators;
    mapping(uint256 nftId => address operator) public operatorOf;

    address[3] public actors;
    uint256[] public allNftIds;

    // Ghost accounting.
    uint256 public ghostDepositedUsdc; // all USDC ever credited into positions
    uint256 public ghostPaidOutUsdc; // all USDC paid to owners (withdraw/emergency/claims)
    uint256 public ghostFeesUsdc; // all fees paid to the treasury
    uint256 public ghostOperatorPnlMinted; // USDC minted to the operator as fake HL pnl
    uint256 public ghostSwapMintedUsdc; // USDC minted by the mock aggregator on weth->usdc swaps
    uint256 public ghostLpFeesMintedUsdc; // USDC minted to the NPM as simulated LP fee accrual
    uint256 public ghostClaimOpenedUsdc; // HL claim tickets opened by emergencyWithdraw
    uint256 public ghostClaimFinalizedUsdc; // HL claim tickets closed by the owner's finalizeHlClaim
    uint256 public ghostClaimTicketsOpened; // tickets COUNTED, because a ticket's principal may be zero
    uint256 public ghostClaimTicketsFinalized;
    uint256 public ghostZeroPrincipalTicketsOpened; // tickets opened with the nominal already repaid
    uint256 public ghostMischargedClaims; // claim returns charged anything but the cumulative fee delta
    uint256 public ghostClaimReturnsAudited; // successful claim returns whose fee was recomputed
    bool public ghostSubFloorBridgeLanded; // a bridge under MIN_HL_BRIDGE_USDC was accepted
    uint256 public ghostUnderchargedSwaps; // swaps charged less than their larger consistent loss
    uint256 public ghostUnderchargedMints; // mints charged less than their mean-measured gap
    uint256 public ghostFullCloses; // 100% closes that settled over a dust LP

    constructor(
        TuoVault vault_,
        MockERC20 usdc_,
        MockWETH weth_,
        MockUniswapV3Pool wethPool_,
        MockPositionManager npm_,
        MockAggregator aggregator_,
        address keeper_,
        address pauser_,
        address treasury_
    ) {
        vault = vault_;
        nft = vault_.NFT();
        usdc = usdc_;
        weth = weth_;
        wethPool = wethPool_;
        npm = npm_;
        aggregator = aggregator_;
        keeper = keeper_;
        pauser = pauser_;
        treasury = treasury_;
        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");
    }

    // ------------------------------------------------------------ helpers

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _existingNft(uint256 seed) internal view returns (uint256) {
        if (allNftIds.length == 0) return 0;
        return allNftIds[seed % allNftIds.length];
    }

    function operatorCount() external view returns (uint256) {
        return operators.length;
    }

    /// @dev The operator this position is meant to bridge to, created on first use: the
    ///      treasury lists it and it pre-approves the vault, as the real pool does.
    function _operatorFor(uint256 nftId) internal returns (address operator) {
        operator = operatorOf[nftId];
        if (operator != address(0)) return operator;
        operator = makeAddr(string.concat("hlOperator", vm.toString(nftId)));
        operatorOf[nftId] = operator;
        operators.push(operator);
        vm.prank(treasury);
        vault.setHlOperator(operator, true);
        vm.prank(operator);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _swapData(address tokenIn, address tokenOut, uint256 spend, uint256 payout)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(address(aggregator), abi.encodeCall(MockAggregator.fill, (tokenIn, tokenOut, spend, payout)));
    }

    function _claimFee(uint256 basis, uint256 realized) internal pure returns (uint256) {
        if (realized <= basis) return 0;
        return ((realized - basis) * TuoConstants.PERFORMANCE_FEE_BPS) / TuoConstants.BPS_DENOMINATOR;
    }

    function _tryOwnerOf(uint256 nftId) internal view returns (address owner) {
        try nft.ownerOf(nftId) returns (address o) {
            owner = o;
        } catch {
            owner = address(0);
        }
    }

    /// @dev The operator a position bridged to, or zero if it never bridged or no longer
    ///      exists. Both inbound legs pull from this address, so the handler has to fund
    ///      and bound against it rather than against a fixed operator.
    function _boundOperator(uint256 nftId) internal view returns (address operator) {
        try vault.getPosition(nftId) returns (ITuoVault.PositionView memory p) {
            operator = p.hlOperator;
        } catch {
            operator = address(0);
        }
    }

    // ------------------------------------------------------------- customer ops

    function deposit(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        amount = bound(amount, 2_500e6, 25_000e6);
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        try vault.deposit(address(usdc), amount, 1, 0, "", 0) returns (uint256 nftId) {
            allNftIds.push(nftId);
            ghostDepositedUsdc += amount;
        } catch {
            usdc.burn(who, amount);
        }
        vm.stopPrank();
    }

    function topUp(uint256 actorSeed, uint256 nftSeed, uint256 amount) external {
        uint256 nftId = _existingNft(nftSeed);
        if (nftId == 0) return;
        address who = _tryOwnerOf(nftId);
        if (who == address(0)) return;
        amount = bound(amount, 2_500e6, 10_000e6);
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        try vault.deposit(address(usdc), amount, 0, 0, "", nftId) {
            ghostDepositedUsdc += amount;
        } catch {
            usdc.burn(who, amount);
        }
        vm.stopPrank();
        actorSeed; // silence
    }

    function requestWithdraw(uint256 nftSeed, uint16 shares) external {
        uint256 nftId = _existingNft(nftSeed);
        address who = _tryOwnerOf(nftId);
        if (who == address(0)) return;
        shares = uint16(bound(shares, 1, 10_000));
        vm.prank(who);
        try vault.requestWithdraw(nftId, shares) {} catch {}
    }

    /// @dev Zero shares is the cancellation, so the handler drives it through the same
    ///      entry point the owner uses rather than a separate one.
    function cancelRequest(uint256 nftSeed) external {
        uint256 nftId = _existingNft(nftSeed);
        address who = _tryOwnerOf(nftId);
        if (who == address(0)) return;
        vm.prank(who);
        try vault.requestWithdraw(nftId, 0) {} catch {}
    }

    /// @dev The position NFT refuses only the vault as a recipient, so the fuzzer has to be
    ///      able to move one. It matters because the request state (`withdrawalRequestedAt`,
    ///      `withdrawalSharesBps`) and the operator binding (`hlOperator`) all survive a
    ///      transfer: this drives transfer while a withdrawal is armed, while margin is
    ///      bridged, and in the gap between `requestWithdraw` and `withdraw`.
    ///
    ///      The recipient is always another actor, never an arbitrary address. Not a
    ///      restriction on what the vault permits - it permits any address but its own - but
    ///      on what the
    ///      probes can measure: I8 pays the current owner in kind, so a position parked on
    ///      an address outside the actor set would leave `_ownerHoldings` unreadable.
    function transferPosition(uint256 nftSeed, uint256 actorSeed, bool useSafeTransfer) external {
        uint256 nftId = _existingNft(nftSeed);
        address from = _tryOwnerOf(nftId);
        if (from == address(0)) return;
        address to = _actor(actorSeed);
        if (to == from) return;

        vm.startPrank(from);
        if (useSafeTransfer) {
            try nft.safeTransferFrom(from, to, nftId) {} catch {}
        } else {
            try nft.transferFrom(from, to, nftId) {} catch {}
        }
        vm.stopPrank();
    }

    function withdraw(uint256 nftSeed) external {
        uint256 nftId = _existingNft(nftSeed);
        address who = _tryOwnerOf(nftId);
        if (who == address(0)) return;
        _withdrawAndTally(nftId, who);
    }

    /// @dev A 100% close over a dust LP, the one state where idle USDC covers the close with
    ///      a holding still attached. `requestWithdraw` bounds a random share, so the fuzzer
    ///      almost never reaches it alone. The first attempt must not retire the position;
    ///      the second runs after the keeper has burned every LP and sold the WETH back.
    function ownerFullCloseOverADustLp(uint256 nftSeed) external {
        uint256 nftId = _existingNft(nftSeed);
        address who = _tryOwnerOf(nftId);
        if (who == address(0)) return;

        // An armed request refuses the setup's USDC buy and mint, so start unarmed.
        vm.prank(who);
        try vault.requestWithdraw(nftId, 0) {} catch {}
        _swapAndAuditCharge(nftId, true, 1e6, 1e6, 0);
        vm.prank(keeper);
        try vault.mintLp(nftId, address(wethPool), -600, 600, 1, 1) {} catch {}
        _keeperSellAllWeth(nftId);

        vm.prank(who);
        try vault.requestWithdraw(nftId, 10_000) {}
        catch {
            return;
        }
        if (!_withdrawAndTally(nftId, who)) {
            uint256[] memory lps = vault.getPosition(nftId).lpTokenIds;
            for (uint256 i = 0; i < lps.length; i++) {
                vm.prank(keeper);
                try vault.burnLp(nftId, lps[i]) {} catch {}
            }
            _keeperSellAllWeth(nftId);
            if (!_withdrawAndTally(nftId, who)) return;
        }
        ghostFullCloses++;
    }

    function _keeperSellAllWeth(uint256 nftId) internal {
        uint256 wethIdle = vault.idleBalance(nftId, address(weth));
        if (wethIdle != 0) _swapAndAuditCharge(nftId, false, wethIdle, wethIdle, 0);
    }

    function _withdrawAndTally(uint256 nftId, address who) internal returns (bool ok) {
        uint256 balBefore = usdc.balanceOf(who);
        uint256 feeBefore = usdc.balanceOf(treasury);
        vm.prank(who);
        try vault.withdraw(nftId, address(usdc), 0, "") {
            ghostPaidOutUsdc += usdc.balanceOf(who) - balBefore;
            ghostFeesUsdc += usdc.balanceOf(treasury) - feeBefore;
            ok = true;
        } catch {}
    }

    function emergencyWithdraw(uint256 nftSeed) external {
        uint256 nftId = _existingNft(nftSeed);
        address who = _tryOwnerOf(nftId);
        if (who == address(0)) return;
        _emergencyExit(nftId, who);
    }

    /// @dev The whole road to a claim in one step: bridge, arm the request, wait out the
    ///      delay, exit. The granular actions above reach the same state only through a
    ///      five-call ordering the fuzzer rarely finds inside the default depth, which left
    ///      every claim property asserting nothing on a local run.
    function ownerEmergencyExitWithMargin(uint256 nftSeed, uint256 amount) external {
        uint256 nftId = _existingNft(nftSeed);
        if (nftId == 0) return;
        address who = _tryOwnerOf(nftId);
        if (who == address(0)) return;
        amount = bound(amount, TuoConstants.MIN_HL_BRIDGE_USDC, 10_000e6);
        address operator = _operatorFor(nftId);
        vm.prank(keeper);
        try vault.bridgeToHl(nftId, amount, operator) {} catch {}
        vm.prank(who);
        try vault.requestWithdraw(nftId, 10_000) {} catch {}
        vm.warp(block.timestamp + TuoConstants.EMERGENCY_WITHDRAW_DELAY);
        _emergencyExit(nftId, who);
    }

    /// @dev The other road to a claim, and the one a nonzero-principal ledger cannot see: a
    ///      NON-final return repays the whole nominal, the venue is still unfinished, and
    ///      the owner exits. The ticket that opens has a zero principal.
    function ownerEmergencyExitAfterCoveringReturn(uint256 nftSeed, uint256 amount) external {
        uint256 nftId = _existingNft(nftSeed);
        if (nftId == 0) return;
        address who = _tryOwnerOf(nftId);
        if (who == address(0)) return;
        amount = bound(amount, TuoConstants.MIN_HL_BRIDGE_USDC, 10_000e6);
        address operator = _operatorFor(nftId);
        vm.startPrank(keeper);
        try vault.bridgeToHl(nftId, amount, operator) {} catch {}
        uint256 nominal = vault.getPosition(nftId).hlMarginBridged;
        if (nominal != 0 && usdc.balanceOf(operator) >= nominal) {
            try vault.markBridgeInboundComplete(nftId, nominal, false) {} catch {}
        }
        vm.stopPrank();
        vm.prank(who);
        try vault.requestWithdraw(nftId, 10_000) {} catch {}
        vm.warp(block.timestamp + TuoConstants.EMERGENCY_WITHDRAW_DELAY);
        _emergencyExit(nftId, who);
    }

    function _emergencyExit(uint256 nftId, address who) internal {
        uint256 usdcBefore = usdc.balanceOf(who);
        uint256 feeBefore = usdc.balanceOf(treasury);
        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        vm.prank(who);
        try vault.emergencyWithdraw(nftId) {
            ghostPaidOutUsdc += usdc.balanceOf(who) - usdcBefore;
            ghostFeesUsdc += usdc.balanceOf(treasury) - feeBefore;
            ghostClaimOpenedUsdc += p.hlMarginBridged;
            if (p.hlLifecycleOpen) {
                ghostClaimTicketsOpened++;
                if (p.hlMarginBridged == 0) ghostZeroPrincipalTicketsOpened++;
            }
        } catch {}
    }

    // -------------------------------------------------------------- keeper ops

    /// @dev The one floor the treasury can move. Every tolerance up to the ceiling has to
    ///      leave I8 and I9 standing: the hostile keeper above fills at whatever floor is set.
    function treasurySetKeeperSwapSlippage(uint16 bps) external {
        bps = uint16(bound(bps, 0, TuoConstants.MAX_KEEPER_SWAP_SLIPPAGE_BPS));
        vm.prank(treasury);
        vault.setKeeperSwapSlippageBps(bps);
    }

    /// @dev A cooperative keeper. `badFillBps` is where the hostile one lives.
    function keeperSwapIdle(uint256 nftSeed, uint256 amount, bool toWeth, int256 gapSeed) external {
        uint256 nftId = _existingNft(nftSeed);
        if (nftId == 0) return;
        amount = bound(amount, 1e6, 10_000e6);
        _swapAndAuditCharge(nftId, toWeth, amount, amount, gapSeed);
    }

    /// @dev The hostile keeper. Pays exactly the vault's own TWAP floor on every leg -
    ///      the worst fill that still passes every on-chain check - so the loss budget is
    ///      actually exercised rather than sitting at zero for the whole run. The old
    ///      harness assumed a cooperative keeper, which is precisely how 155 green tests
    ///      coexisted with an unmetered keeper perimeter.
    function keeperSwapIdleAtTheFloor(uint256 nftSeed, uint256 amount, bool toWeth, uint16 badFillBps, int256 gapSeed)
        external
    {
        uint256 nftId = _existingNft(nftSeed);
        if (nftId == 0) return;
        amount = bound(amount, 1e6, 10_000e6);
        // Up to 50 bps past the tolerance the treasury set; anything past it must be
        // refused outright.
        badFillBps = uint16(bound(badFillBps, 0, vault.keeperSwapSlippageBps() + 50));
        _swapAndAuditCharge(nftId, toWeth, amount, amount - (amount * badFillBps) / 10_000, gapSeed);
    }

    /// @dev Swap with spot anywhere inside the deviation gate, then recompute both
    ///      consistently measured losses the long way - input and output valued at the mean
    ///      tick, and again at the spot tick - and record any swap the vault charged less
    ///      than the larger of the two. Both budget reads are in the block of the charge, so
    ///      the window has not decayed between them. Spot returns to the mean afterwards:
    ///      the NPM mock is not an AMM, so an LP minted and burned across a moved spot would
    ///      break value conservation in the mock rather than in the vault.
    function _swapAndAuditCharge(uint256 nftId, bool toWeth, uint256 amount, uint256 payout, int256 gapSeed) internal {
        address tokenIn = toWeth ? address(usdc) : address(weth);
        address tokenOut = toWeth ? address(weth) : address(usdc);
        int24 meanTick = PoolTwap.twapTick(address(wethPool));
        // Bounded to the gate's width by `bound`, well inside int24.
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 gap = int24(bound(gapSeed, -TuoConstants.MAX_TWAP_DEVIATION_TICKS, TuoConstants.MAX_TWAP_DEVIATION_TICKS));
        wethPool.setSpotTick(meanTick + gap);

        (, uint256 lossBefore,) = vault.keeperBudgetOf(nftId);
        vm.prank(keeper);
        try vault.swapIdle(nftId, tokenIn, tokenOut, amount, 0, _swapData(tokenIn, tokenOut, amount, payout)) {
            // The mock aggregator mints the output token: usdc payouts add supply.
            if (!toWeth) ghostSwapMintedUsdc += payout;

            uint256 meanLoss = _lossAtTick(meanTick, toWeth, amount, payout);
            uint256 spotLoss = _lossAtTick(meanTick + gap, toWeth, amount, payout);
            (, uint256 lossAfter,) = vault.keeperBudgetOf(nftId);
            if (lossAfter - lossBefore < (meanLoss > spotLoss ? meanLoss : spotLoss)) ghostUnderchargedSwaps++;
        } catch {}
        wethPool.setSpotTick(meanTick);
    }

    /// @dev One consistently measured loss: input and output valued at the same tick.
    function _lossAtTick(int24 tick, bool toWeth, uint256 amountIn, uint256 amountOut) internal view returns (uint256) {
        uint256 valueIn = toWeth ? amountIn : PoolTwap.quoteToUsdcAtTick(tick, address(weth), address(usdc), amountIn);
        uint256 valueOut =
            toWeth ? PoolTwap.quoteToUsdcAtTick(tick, address(weth), address(usdc), amountOut) : amountOut;
        return valueIn > valueOut ? valueIn - valueOut : 0;
    }

    /// @dev A keeper trying to route the proceeds through an aggregator nobody approved.
    ///      Must always revert; the assertion is that no invariant moves when it does.
    function keeperSwapViaRogueAggregator(uint256 nftSeed, uint256 amount) external {
        uint256 nftId = _existingNft(nftSeed);
        if (nftId == 0) return;
        amount = bound(amount, 1e6, 10_000e6);
        vm.prank(keeper);
        try vault.swapIdle(nftId, address(usdc), address(weth), amount, 0, abi.encode(keeper, bytes(""))) {
            revert("handler: a non-allowlisted aggregator executed");
        } catch {}
    }

    function keeperMintLp(uint256 nftSeed, uint256 amount0, uint256 amount1) external {
        uint256 nftId = _existingNft(nftSeed);
        if (nftId == 0) return;
        amount0 = bound(amount0, 1e6, 5_000e6);
        amount1 = bound(amount1, 1e6, 5_000e6);
        vm.prank(keeper);
        try vault.mintLp(nftId, address(wethPool), -600, 600, amount0, amount1) {} catch {}
    }

    /// @dev Mint with spot anywhere inside the deviation gate, recompute the gap between the
    ///      mean-valued amounts consumed and the mean-valued liquidity the long way, and record
    ///      any mint the vault charged less. The LP is burned in the same call at the same
    ///      spot: the NPM mock is not an AMM, so an LP minted at a moved spot and unwound at
    ///      the mean would have the mock create tokens and break the conservation ghosts,
    ///      while a burn at the mint's own spot hands back exactly what was pulled. Both
    ///      actions have to fit the action budget, and a burn that still fails reverts the
    ///      whole call so the moved-spot LP never survives it.
    function keeperMintLpInsideTheGate(
        uint256 nftSeed,
        uint256 amount0,
        uint256 amount1,
        int256 gapSeed,
        int256 lowerSeed,
        int256 widthSeed
    ) external {
        uint256 nftId = _existingNft(nftSeed);
        if (nftId == 0) return;
        if (vault.keeperActionsToday(nftId) + 2 > TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW) return;
        amount0 = bound(amount0, 1e6, 5_000e6);
        amount1 = bound(amount1, 1e6, 5_000e6);
        int24 meanTick = PoolTwap.twapTick(address(wethPool));
        // Bounded to a few thousand ticks by `bound`, well inside int24.
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 gap = int24(bound(gapSeed, -TuoConstants.MAX_TWAP_DEVIATION_TICKS, TuoConstants.MAX_TWAP_DEVIATION_TICKS));
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 lower = meanTick + int24(bound(lowerSeed, -3_000, 500));
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 upper = lower + int24(bound(widthSeed, TuoConstants.MIN_LP_TICK_WIDTH, 3_000));
        wethPool.setSpotTick(meanTick + gap);

        uint256 idle0 = vault.idleBalance(nftId, wethPool.token0());
        uint256 idle1 = vault.idleBalance(nftId, wethPool.token1());
        (, uint256 lossBefore,) = vault.keeperBudgetOf(nftId);
        vm.prank(keeper);
        try vault.mintLp(nftId, address(wethPool), lower, upper, amount0, amount1) returns (
            uint256 lpId, uint128 liquidity
        ) {
            uint256 consumed = _pairValueAtTick(
                meanTick,
                idle0 - vault.idleBalance(nftId, wethPool.token0()),
                idle1 - vault.idleBalance(nftId, wethPool.token1())
            );
            (uint256 mean0, uint256 mean1) = LiquidityAmounts.getAmountsForLiquidity(
                TickMath.getSqrtRatioAtTick(meanTick),
                TickMath.getSqrtRatioAtTick(lower),
                TickMath.getSqrtRatioAtTick(upper),
                liquidity
            );
            uint256 minted = _pairValueAtTick(meanTick, mean0, mean1);
            (, uint256 lossAfter,) = vault.keeperBudgetOf(nftId);
            if (lossAfter - lossBefore < (consumed > minted ? consumed - minted : 0)) ghostUnderchargedMints++;

            vm.prank(keeper);
            try vault.burnLp(nftId, lpId) {}
            catch {
                revert("handler: a gated mint could not be unwound at its own spot");
            }
        } catch {}
        wethPool.setSpotTick(meanTick);
    }

    /// @dev USDC value of a token0/token1 pair of the WETH/USDC pool at one tick.
    function _pairValueAtTick(int24 tick, uint256 amount0, uint256 amount1) internal view returns (uint256 value) {
        address token0 = wethPool.token0();
        address token1 = wethPool.token1();
        value = token0 == address(usdc) ? amount0 : PoolTwap.quoteToUsdcAtTick(tick, token0, address(usdc), amount0);
        value += token1 == address(usdc) ? amount1 : PoolTwap.quoteToUsdcAtTick(tick, token1, address(usdc), amount1);
    }

    /// @dev Dust-LP spam: the griefing vector against the O(n) exit, now bounded by the
    ///      product's `maxLpCount`. The exit path has to stay affordable however many of
    ///      these land.
    function keeperSpamDustLp(uint256 nftSeed, uint256 seed) external {
        uint256 nftId = _existingNft(nftSeed);
        if (nftId == 0) return;
        uint256 dust = bound(seed, 1, 1e6);
        vm.prank(keeper);
        try vault.mintLp(nftId, address(wethPool), -600, 600, dust, dust) {} catch {}
    }

    /// @dev Bridges under the operational floor. Every one must be refused whatever the
    ///      position's state, so a sub-floor amount never reaches the attribution at all.
    ///      Recorded as ghost state rather than asserted here: under fail_on_revert = false
    ///      a reverting handler call is discarded, so a `revert` in the success branch
    ///      could never fail the run. invariant_I11 reads the flag.
    function keeperDustBridge(uint256 nftSeed, uint256 amount) external {
        uint256 nftId = _existingNft(nftSeed);
        if (nftId == 0) return;
        amount = bound(amount, 1, TuoConstants.MIN_HL_BRIDGE_USDC - 1);
        // The position's own operator, so the floor is the only reason left to refuse.
        address operator = _operatorFor(nftId);
        vm.prank(keeper);
        try vault.bridgeToHl(nftId, amount, operator) {
            ghostSubFloorBridgeLanded = true;
        } catch {}
    }

    function keeperBurnLp(uint256 nftSeed, uint256 lpSeed) external {
        uint256 nftId = _existingNft(nftSeed);
        if (nftId == 0) return;
        ITuoVault.PositionView memory p;
        try vault.getPosition(nftId) returns (ITuoVault.PositionView memory pv) {
            p = pv;
        } catch {
            return;
        }
        if (p.lpTokenIds.length == 0) return;
        uint256 lpId = p.lpTokenIds[lpSeed % p.lpTokenIds.length];
        vm.prank(keeper);
        try vault.burnLp(nftId, lpId) {} catch {}
    }

    function keeperAccrueLpFees(uint256 nftSeed, uint256 lpSeed, uint256 fee0, uint256 fee1) external {
        uint256 nftId = _existingNft(nftSeed);
        if (nftId == 0) return;
        ITuoVault.PositionView memory p;
        try vault.getPosition(nftId) returns (ITuoVault.PositionView memory pv) {
            p = pv;
        } catch {
            return;
        }
        if (p.lpTokenIds.length == 0) return;
        fee0 = bound(fee0, 0, 100e6);
        fee1 = bound(fee1, 0, 100e6);
        npm.accrueFees(p.lpTokenIds[lpSeed % p.lpTokenIds.length], fee0, fee1);
        ghostLpFeesMintedUsdc += wethPool.token0() == address(usdc) ? fee0 : fee1;
    }

    /// @dev The keeper picks the destination, so the hostile handler picks it too: half
    ///      the runs aim at a DIFFERENT position's operator whenever there is one. Those
    ///      must revert (HlOperatorAlreadyBound once that operator is bound,
    ///      HlOperatorMismatch once this position is) and are swallowed here; what the
    ///      invariants then prove is that a rejected route moved no value, left no
    ///      accounting behind and never put two positions on one operator (I12).
    function keeperBridgeToHl(uint256 nftSeed, uint256 amount, bool hostile, uint256 victimSeed) external {
        if (allNftIds.length == 0) return;
        uint256 selfIndex = nftSeed % allNftIds.length;
        uint256 nftId = allNftIds[selfIndex];
        amount = bound(amount, 1e6, 10_000e6);
        address operator = _operatorFor(nftId);
        if (hostile && allNftIds.length > 1) {
            uint256 victimIndex = (selfIndex + 1 + (victimSeed % (allNftIds.length - 1))) % allNftIds.length;
            operator = _operatorFor(allNftIds[victimIndex]);
        }
        vm.prank(keeper);
        try vault.bridgeToHl(nftId, amount, operator) {} catch {}
    }

    function keeperMarkInbound(uint256 nftSeed, uint256 amount, uint256 pnl, bool finalReturn) external {
        uint256 nftId = _existingNft(nftSeed);
        if (nftId == 0) return;
        // Hedge PnL lands on the operator the position is actually bound to, not on a
        // fixed one: the vault pulls from the binding, so funding the wrong account would
        // just make every inbound leg fail on balance and hollow out the invariant.
        address operator = _boundOperator(nftId);
        if (operator == address(0)) return;
        pnl = bound(pnl, 0, 2_000e6);
        if (pnl != 0) {
            usdc.mint(operator, pnl);
            ghostOperatorPnlMinted += pnl;
        }
        // bound() reverts when min > max, and a reverting handler call is discarded, so
        // an underfunded operator has to return before the bound rather than through it.
        if (usdc.balanceOf(operator) < 1e6) return;
        amount = bound(amount, 1e6, usdc.balanceOf(operator));
        vm.prank(keeper);
        try vault.markBridgeInboundComplete(nftId, amount, finalReturn) {} catch {}
    }

    /// @dev The zero-amount final return: a write-off when nominal is left, the close
    ///      attestation when a non-final leg already repaid it. `keeperMarkInbound` floors
    ///      its amount at one dollar, so without this neither was ever fuzzed.
    function keeperCloseLifecycle(uint256 nftSeed) external {
        uint256 nftId = _existingNft(nftSeed);
        if (nftId == 0) return;
        vm.prank(keeper);
        try vault.markBridgeInboundComplete(nftId, 0, true) {} catch {}
    }

    /// @dev Hedge pnl is minted here as well as in the inbound leg: once a claim is open the
    ///      position is inactive and `keeperMarkInbound` is refused, so without it the
    ///      operator could never return more than it was sent and the above-par branch would
    ///      go unfuzzed. The fee each return is charged is recomputed the long way, as the
    ///      delta of the cumulative formula, and any disagreement is recorded for I10.
    function keeperSettleClaim(uint256 nftSeed, uint256 amount, uint256 pnl) external {
        uint256 nftId = _existingNft(nftSeed);
        if (nftId == 0) return;
        address operator = _boundOperator(nftId);
        if (operator == address(0)) return;
        address owner = _tryOwnerOf(nftId);
        if (owner == address(0)) return;
        pnl = bound(pnl, 0, 2_000e6);
        if (pnl != 0) {
            usdc.mint(operator, pnl);
            ghostOperatorPnlMinted += pnl;
        }
        // From 1, not 1e6: a floor-sized leg's return fee leaves a claim well under a
        // dollar, and a ticket the harness can never settle never gets its fee audited.
        amount = bound(amount, 1, usdc.balanceOf(operator) + 1);
        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        uint256 ownerBefore = usdc.balanceOf(owner);
        uint256 feesBefore = vault.accruedFeesUsdc();
        vm.prank(keeper);
        try vault.settleHlClaim(nftId, amount) {
            ghostPaidOutUsdc += usdc.balanceOf(owner) - ownerBefore;
            uint256 owed = _claimFee(p.basisUsdc, p.hlClaimExitNavUsdc + p.hlClaimReturnedUsdc + amount);
            uint256 expected = owed > p.hlClaimFeeChargedUsdc ? owed - p.hlClaimFeeChargedUsdc : 0;
            if (vault.accruedFeesUsdc() - feesBefore != expected) ghostMischargedClaims++;
            ghostClaimReturnsAudited++;
        } catch {}
    }

    /// @dev The only owner entry point after a hedged emergency exit. Records the principal
    ///      the ticket was opened for, so I10 can prove no ticket ever vanished any other way.
    function ownerFinalizeClaim(uint256 nftSeed) external {
        uint256 nftId = _existingNft(nftSeed);
        if (nftId == 0) return;
        address who = _tryOwnerOf(nftId);
        if (who == address(0)) return;
        uint256 principal = vault.getPosition(nftId).hlClaimUsdc;
        vm.prank(who);
        try vault.finalizeHlClaim(nftId) {
            ghostClaimFinalizedUsdc += principal;
            ghostClaimTicketsFinalized++;
        } catch {}
    }

    // ------------------------------------------------------------ environment

    /// @dev Fees are pull-payment, so the sweep is its own action rather than a side
    ///      effect of an exit. Also the only path that moves USDC to the treasury,
    ///      which is what I4 accounts for.
    function treasuryClaimFees() external {
        uint256 before = usdc.balanceOf(treasury);
        vm.prank(treasury);
        try vault.claimFees() {
            ghostFeesUsdc += usdc.balanceOf(treasury) - before;
        } catch {}
    }

    function togglePause(bool paused) external {
        vm.prank(pauser);
        if (paused) {
            try vault.pauseDeposits() {} catch {}
        } else {
            try vault.unpauseDeposits() {} catch {}
        }
    }

    function warp(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 1 minutes, 2 days));
    }

    // --------------------------------------------------------------- getters

    function nftCount() external view returns (uint256) {
        return allNftIds.length;
    }
}
