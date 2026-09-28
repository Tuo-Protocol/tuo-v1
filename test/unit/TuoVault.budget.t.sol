// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {ITuoVault} from "../../src/interfaces/ITuoVault.sol";
import {PoolTwap} from "../../src/libraries/PoolTwap.sol";
import {TuoConstants} from "../../src/libraries/TuoConstants.sol";
import {LiquidityAmounts} from "../../src/vendor/uniswap/LiquidityAmounts.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev The two per-position leaky buckets that bound the keeper: the NUMBER of actions it
///      may take (capacity 10, refilling one action per 2.4h) and the VALUE those actions
///      may cost (capacity 150 bps of basis, refilling 15 bps per 2.4h while held at the
///      ceiling, charged on `swapIdle` and `mintLp`). Neither is a maximum over every
///      sliding window; `TuoVault.budgetRefill.t.sol` pins what a closed one really admits.
///
///      Be precise about what the loss budget buys. The ceiling is sized on `basisUsdc`,
///      which measured loss never shrinks, so a sustained drain is linear on the original
///      basis: thirty daily refills are 45% of it, not the 36% that compounding 150 bps on
///      a shrinking position would give. Either way it is a rate limiter that makes a drain
///      slow enough to notice, not a solvency guarantee. The real bound is the response -
///      revoking `KEEPER_ROLE` - which is why `KeeperLossCharged` carries the whole bucket
///      state and ceiling for an off-chain alert to key on, and why the budget must never be
///      able to stand between an owner and their exit.
contract TuoVaultBudgetTest is VaultTestBase {
    uint256 internal nftId;

    function setUp() public override {
        super.setUp();
        nftId = _depositUsdc(alice, 20_000e6);
    }

    // ------------------------------------------------------------- action count

    function test_KeeperRateLimitIsTenPerWindowPerPosition() public {
        bytes memory data = _swapData(address(usdc), address(weth), 100e6, 100e6);
        vm.startPrank(keeper);
        for (uint256 i = 0; i < TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW; i++) {
            vault.swapIdle(nftId, address(usdc), address(weth), 100e6, 0, data);
        }
        assertEq(vault.keeperActionsToday(nftId), TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW);

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.KeeperRateLimitExceeded.selector, nftId));
        vault.swapIdle(nftId, address(usdc), address(weth), 100e6, 0, data);

        // The allowance refills linearly, so a tenth of the window buys one action back.
        vm.warp(block.timestamp + TuoConstants.KEEPER_ACTION_WINDOW / 10);
        assertEq(vault.keeperActionsToday(nftId), TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW - 1);
        vault.swapIdle(nftId, address(usdc), address(weth), 100e6, 0, data);
        vm.stopPrank();
    }

    /// @dev A part-used slot is a spent slot. Admission adds a WHOLE unit to the unrounded
    ///      balance, so nine actions plus an hour of regeneration - 8,583,334 units - leave
    ///      room for one call, not two. A floored count read eight, and a scheduler
    ///      subtracting it from MAX_KEEPER_ACTIONS_PER_WINDOW planned a tenth and an
    ///      eleventh call whose second reverts. Cyfrin audit 2026-09, issue 46.
    function test_KeeperActionViewsCountAPartUsedSlotAsSpent() public {
        bytes memory data = _swapData(address(usdc), address(weth), 100e6, 100e6);
        vm.startPrank(keeper);
        for (uint256 i = 0; i < TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW - 1; i++) {
            vault.swapIdle(nftId, address(usdc), address(weth), 100e6, 0, data);
        }
        // An hour buys back 416,666 units, well under one whole action.
        vm.warp(block.timestamp + 1 hours);

        uint256 expected = TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW - 1;
        assertEq(vault.keeperActionsToday(nftId), expected, "a partly regenerated slot is still spent");
        (uint256 actionsUsed,,) = vault.keeperBudgetOf(nftId);
        assertEq(actionsUsed, expected, "both views report the same count");

        vault.swapIdle(nftId, address(usdc), address(weth), 100e6, 0, data);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.KeeperRateLimitExceeded.selector, nftId));
        vault.swapIdle(nftId, address(usdc), address(weth), 100e6, 0, data);
        vm.stopPrank();
    }

    /// @dev The headroom the view advertises is exact at every point of the regeneration
    ///      curve, not only at the hour the finding named: what MAX_KEEPER_ACTIONS_PER_WINDOW
    ///      minus the view promises is what admission then grants, and the next call reverts.
    function testFuzz_KeeperActionHeadroomMatchesWhatAdmissionGrants(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, TuoConstants.KEEPER_ACTION_WINDOW);
        bytes memory data = _swapData(address(usdc), address(weth), 100e6, 100e6);
        vm.startPrank(keeper);
        for (uint256 i = 0; i < TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW; i++) {
            vault.swapIdle(nftId, address(usdc), address(weth), 100e6, 0, data);
        }
        vm.warp(block.timestamp + elapsed);

        uint256 headroom = TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW - vault.keeperActionsToday(nftId);
        for (uint256 i = 0; i < headroom; i++) {
            vault.swapIdle(nftId, address(usdc), address(weth), 100e6, 0, data);
        }
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.KeeperRateLimitExceeded.selector, nftId));
        vault.swapIdle(nftId, address(usdc), address(weth), 100e6, 0, data);
        vm.stopPrank();
    }

    /// @dev Action units are elapsed-time units, not a calendar bucket. The old budget was
    ///      keyed on `block.timestamp / 1 days`, so ten actions at 23:59 and ten more at
    ///      00:01 were both "within budget" - a keeper could spend two full days in two
    ///      minutes. A leaky bucket cannot express that state at all.
    function test_KeeperBudgetSurvivesTheMidnightBoundary() public {
        bytes memory data = _swapData(address(usdc), address(weth), 100e6, 100e6);
        // 60 seconds before UTC midnight, the boundary the old bucket keyed on.
        // forge-lint: disable-next-line(divide-before-multiply)
        vm.warp((block.timestamp / 1 days) * 1 days + 1 days - 60);

        vm.startPrank(keeper);
        for (uint256 i = 0; i < TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW; i++) {
            vault.swapIdle(nftId, address(usdc), address(weth), 100e6, 0, data);
        }
        // Crossing midnight buys nothing; only elapsed time does.
        vm.warp(block.timestamp + 120);

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.KeeperRateLimitExceeded.selector, nftId));
        vault.swapIdle(nftId, address(usdc), address(weth), 100e6, 0, data);
        vm.stopPrank();
    }

    function test_RateLimitIsPerPosition() public {
        uint256 other = _depositUsdc(bob, 10_000e6);
        bytes memory data = _swapData(address(usdc), address(weth), 100e6, 100e6);
        vm.startPrank(keeper);
        for (uint256 i = 0; i < TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW; i++) {
            vault.swapIdle(nftId, address(usdc), address(weth), 100e6, 0, data);
        }
        // Different position: budget untouched.
        vault.swapIdle(other, address(usdc), address(weth), 100e6, 0, data);
        vm.stopPrank();
    }

    // -------------------------------------------------------- the value budget

    function test_KeeperLossBudgetChargesSwapsAndEventuallyRefuses() public {
        (uint256 actions, uint256 loss, uint256 ceiling) = vault.keeperBudgetOf(nftId);
        assertEq(actions, 0);
        assertEq(loss, 0);
        // 150 bps of a 20,000 basis.
        assertEq(ceiling, 300e6);

        // Three round trips whose outbound leg pays exactly the vault's own floor, so
        // each one gives up the full 50 bps allowance. The return legs are priced fairly
        // and cost nothing, which is what makes this a keeper-attributed loss rather than
        // market noise.
        vm.startPrank(keeper);
        for (uint256 i = 0; i < 3; i++) {
            uint256 amountIn = vault.idleBalance(nftId, address(usdc));
            uint256 payout = _ceilBps(amountIn, 9_950);
            vault.swapIdle(
                nftId,
                address(usdc),
                address(weth),
                amountIn,
                0,
                _swapData(address(usdc), address(weth), amountIn, payout)
            );
            vault.swapIdle(
                nftId, address(weth), address(usdc), payout, 0, _swapData(address(weth), address(usdc), payout, payout)
            );
        }
        vm.stopPrank();

        (actions, loss,) = vault.keeperBudgetOf(nftId);
        assertEq(actions, 6);
        assertEq(loss, 298_502_500, "three floor-priced legs, compounding on a shrinking balance");
        assertLt(loss, ceiling);

        // The fourth would take the window past 300 USDC, and it is refused before the
        // aggregator is ever called.
        uint256 amountIn4 = vault.idleBalance(nftId, address(usdc));
        uint256 payout4 = _ceilBps(amountIn4, 9_950);
        vm.expectPartialRevert(ITuoVault.KeeperLossBudgetExceeded.selector);
        vm.prank(keeper);
        vault.swapIdle(
            nftId,
            address(usdc),
            address(weth),
            amountIn4,
            0,
            _swapData(address(usdc), address(weth), amountIn4, payout4)
        );
    }

    function test_KeeperLossBudgetRegeneratesOverTheWindow() public {
        uint256 payout = _ceilBps(10_000e6, 9_950);
        vm.prank(keeper);
        vault.swapIdle(
            nftId, address(usdc), address(weth), 10_000e6, 0, _swapData(address(usdc), address(weth), 10_000e6, payout)
        );
        (, uint256 loss,) = vault.keeperBudgetOf(nftId);
        assertEq(loss, 50e6, "50 bps of 10,000");

        vm.warp(block.timestamp + TuoConstants.KEEPER_LOSS_WINDOW / 2);
        (, uint256 halfway,) = vault.keeperBudgetOf(nftId);
        assertEq(halfway, 25e6, "half a window regenerates half the charge");

        vm.warp(block.timestamp + TuoConstants.KEEPER_LOSS_WINDOW);
        (, uint256 after_,) = vault.keeperBudgetOf(nftId);
        assertEq(after_, 0, "a full window clears it");
    }

    /// @dev The ceiling is measured against basis, so when the owner withdraws part of
    ///      the position the charged loss has to shrink with it. Otherwise a partial exit
    ///      leaves a charge sized for a position that no longer exists, and a full exit
    ///      leaves one standing against a zero ceiling.
    function test_KeeperLossShrinksProRataWithTheBasis() public {
        uint256 payout = _ceilBps(10_000e6, 9_950);
        vm.prank(keeper);
        vault.swapIdle(
            nftId, address(usdc), address(weth), 10_000e6, 0, _swapData(address(usdc), address(weth), 10_000e6, payout)
        );
        vm.prank(keeper);
        vault.swapIdle(
            nftId, address(weth), address(usdc), payout, 0, _swapData(address(weth), address(usdc), payout, payout)
        );
        (, uint256 loss, uint256 ceiling) = vault.keeperBudgetOf(nftId);
        assertEq(loss, 50e6);
        assertEq(ceiling, 300e6);

        vm.startPrank(alice);
        vault.requestWithdraw(nftId, 5_000);
        vault.withdraw(nftId, address(usdc), 0, "");
        vm.stopPrank();

        (, loss, ceiling) = vault.keeperBudgetOf(nftId);
        assertEq(loss, 25e6, "half the position left, half the charge");
        assertEq(ceiling, 150e6, "and half the ceiling");
    }

    function test_EmergencyWithdrawClearsTheKeeperLossWithTheBasis() public {
        uint256 payout = _ceilBps(10_000e6, 9_950);
        vm.prank(keeper);
        vault.swapIdle(
            nftId, address(usdc), address(weth), 10_000e6, 0, _swapData(address(usdc), address(weth), 10_000e6, payout)
        );

        vm.prank(alice);
        vault.emergencyWithdraw(nftId);

        (, uint256 loss, uint256 ceiling) = vault.keeperBudgetOf(nftId);
        assertEq(loss, 0);
        assertEq(ceiling, 0);
    }

    // ------------------------------------------- spot against the mean, inside the gate

    /// @dev The loss used to be measured at the mean tick alone, the same tick the floor
    ///      comes from. With spot 200 ticks in the position's favour, a fill at exactly the
    ///      mean quote read as value-neutral while 198 bps left through the keeper's own
    ///      counterparty. The pair is now also valued at the spot tick the gate just read,
    ///      and the larger of the two consistently measured losses is charged.
    function test_SwapIdleChargesTheSpotMeasuredLossOnAMeanPricedFill() public {
        int24 spotTick = _tickWhereTokenIsCheap(wethPool, address(weth));
        wethPool.setSpotTick(spotTick);

        uint256 amountIn = 10_000e6;
        uint256 meanQuote = PoolTwap.quoteFromUsdcAtTick(0, address(weth), address(usdc), amountIn);
        uint256 spotLoss = amountIn - PoolTwap.quoteToUsdcAtTick(spotTick, address(weth), address(usdc), meanQuote);
        assertEq(spotLoss, 198_003_466, "198 bps of the leg");

        vm.expectEmit(address(vault));
        emit ITuoVault.KeeperLossCharged(nftId, spotLoss, spotLoss, 300e6);
        vm.prank(keeper);
        vault.swapIdle(
            nftId,
            address(usdc),
            address(weth),
            amountIn,
            0,
            _swapData(address(usdc), address(weth), amountIn, meanQuote)
        );

        (, uint256 loss,) = vault.keeperBudgetOf(nftId);
        assertEq(loss, spotLoss);
    }

    /// @dev The same fill on the whole position: one action would cost more than the 24h
    ///      ceiling, so it reverts and the swap is rolled back with it.
    function test_RevertWhen_SwapIdleMeanPricedFillExceedsTheLossCeiling() public {
        int24 spotTick = _tickWhereTokenIsCheap(wethPool, address(weth));
        wethPool.setSpotTick(spotTick);

        uint256 amountIn = 20_000e6;
        uint256 meanQuote = PoolTwap.quoteFromUsdcAtTick(0, address(weth), address(usdc), amountIn);
        uint256 spotLoss = amountIn - PoolTwap.quoteToUsdcAtTick(spotTick, address(weth), address(usdc), meanQuote);
        assertEq(spotLoss, 396_006_932, "198 bps of the position, against a 150 bps ceiling");

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.KeeperLossBudgetExceeded.selector, nftId, spotLoss, 300e6));
        vm.prank(keeper);
        vault.swapIdle(
            nftId,
            address(usdc),
            address(weth),
            amountIn,
            0,
            _swapData(address(usdc), address(weth), amountIn, meanQuote)
        );
    }

    /// @dev The worst fill the vault's own floor admits, at the edge of the gate: 50 bps
    ///      under the mean quote while spot is 200 ticks better than the mean. It records
    ///      about 2.5% of the leg, so the second such leg breaches the ceiling. An honest
    ///      route fills near spot, so this is the intended outcome, not a liveness cost.
    function test_SwapIdleFloorFillAtTheBandEdgeRecordsAboutTwoAndAHalfPercent() public {
        int24 spotTick = _tickWhereTokenIsCheap(wethPool, address(weth));
        wethPool.setSpotTick(spotTick);

        uint256 amountIn = 10_000e6;
        uint256 payout = _ceilBps(amountIn, 9_950);
        uint256 expected = amountIn - PoolTwap.quoteToUsdcAtTick(spotTick, address(weth), address(usdc), payout);
        assertEq(expected, 247_013_449, "247 bps of the leg");

        vm.expectEmit(address(vault));
        emit ITuoVault.KeeperLossCharged(nftId, expected, expected, 300e6);
        vm.prank(keeper);
        vault.swapIdle(
            nftId, address(usdc), address(weth), amountIn, 0, _swapData(address(usdc), address(weth), amountIn, payout)
        );

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.KeeperLossBudgetExceeded.selector, nftId, 2 * expected, 300e6));
        vm.prank(keeper);
        vault.swapIdle(
            nftId, address(usdc), address(weth), amountIn, 0, _swapData(address(usdc), address(weth), amountIn, payout)
        );
    }

    /// @dev The selling direction. The input is the pool-token side here, so the spot pair
    ///      values what went IN at the tick where the token is dear, and that pair wins.
    function test_SwapIdleChargesTheSpotMeasuredLossOnATokenSale() public {
        _keeperSwapToWeth(nftId, 10_000e6, 10_000e6);

        int24 spotTick = -_tickWhereTokenIsCheap(wethPool, address(weth));
        wethPool.setSpotTick(spotTick);
        uint256 expected = PoolTwap.quoteToUsdcAtTick(spotTick, address(weth), address(usdc), 10_000e6) - 10_000e6;
        assertEq(expected, 202_003_198, "the mean-priced sale gives up the 200 ticks");

        vm.expectEmit(address(vault));
        emit ITuoVault.KeeperLossCharged(nftId, expected, expected, 300e6);
        vm.prank(keeper);
        vault.swapIdle(
            nftId,
            address(weth),
            address(usdc),
            10_000e6,
            0,
            _swapData(address(weth), address(usdc), 10_000e6, 10_000e6)
        );
    }

    /// @dev Spot is evidence against the keeper only. Pushed to the side that flatters the
    ///      fill, it cannot erase a loss the mean pair measures: the charge stays 50 bps.
    function test_SwapIdleKeepsTheMeanMeasuredLossWhenSpotFlattersTheFill() public {
        wethPool.setSpotTick(-_tickWhereTokenIsCheap(wethPool, address(weth)));

        uint256 payout = _ceilBps(10_000e6, 9_950);
        vm.prank(keeper);
        vault.swapIdle(
            nftId, address(usdc), address(weth), 10_000e6, 0, _swapData(address(usdc), address(weth), 10_000e6, payout)
        );
        (, uint256 loss,) = vault.keeperBudgetOf(nftId);
        assertEq(loss, 50e6, "the mean-measured 50 bps, not zero");
    }

    /// @dev An honest route fills near spot. With spot in the position's favour the charge
    ///      is the route cost and nothing else, at every gap the gate admits.
    function test_HonestFillAtSpotIsChargedOnlyItsRouteCost() public {
        uint256 amountIn = 2_000e6;
        uint256 charged;
        for (int24 gap = 0; gap <= TuoConstants.MAX_TWAP_DEVIATION_TICKS; gap += 50) {
            int24 spotTick = wethPool.token0() == address(weth) ? -gap : gap;
            wethPool.setSpotTick(spotTick);
            // 12 bps of pool fee and aggregator spread off the spot quote.
            uint256 payout =
                (PoolTwap.quoteFromUsdcAtTick(spotTick, address(weth), address(usdc), amountIn) * 9_988) / 10_000;

            vm.prank(keeper);
            vault.swapIdle(
                nftId,
                address(usdc),
                address(weth),
                amountIn,
                0,
                _swapData(address(usdc), address(weth), amountIn, payout)
            );
            (, uint256 loss,) = vault.keeperBudgetOf(nftId);
            assertApproxEqAbs(loss - charged, 2_400_000, 2, "12 bps of the leg");
            charged = loss;
        }
    }

    /// @dev The vault values the pair at the mean tick and again at the spot tick, each
    ///      pair at ONE tick, and charges the larger loss. This recomputes both losses the
    ///      long way and compares. The two pools sort USDC into opposite slots, so both
    ///      tick directions are hit.
    function testFuzz_SwapIdleChargesTheLargerOfTheTwoConsistentLosses(
        int256 meanSeed,
        int256 gapSeed,
        uint256 payoutBps,
        bool useWbtc,
        bool sellToken
    ) public {
        assertTrue(wethPool.token0() == address(weth) && wbtcPool.token1() == address(wbtc), "both sort orders");
        MockUniswapV3Pool pool = useWbtc ? wbtcPool : wethPool;
        address token = useWbtc ? address(wbtc) : address(weth);

        // Bounded to int24 range by the two `bound` calls. The mean spans a price ratio
        // of roughly 1e-4.34 to 1e4.34, wide enough to cover 18- and 8-decimal tokens
        // against USDC without pushing the 10,000 USDC leg past the uint128 quote cast.
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 meanTick = int24(bound(meanSeed, -100_000, 100_000));
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 spotTick = meanTick
            + int24(bound(gapSeed, -TuoConstants.MAX_TWAP_DEVIATION_TICKS, TuoConstants.MAX_TWAP_DEVIATION_TICKS));
        payoutBps = bound(payoutBps, 9_950, 10_300);
        pool.setTwapTick(meanTick);

        address tokenIn = address(usdc);
        address tokenOut = token;
        uint256 amountIn = 10_000e6;
        uint256 meanQuote = PoolTwap.quoteFromUsdcAtTick(meanTick, token, address(usdc), amountIn);
        if (sellToken) {
            // Fund the token side at par with spot on the mean, which charges nothing.
            pool.setSpotTick(meanTick);
            vm.prank(keeper);
            vault.swapIdle(nftId, tokenIn, tokenOut, amountIn, 0, _swapData(tokenIn, tokenOut, amountIn, meanQuote));
            (tokenIn, tokenOut, amountIn) = (token, address(usdc), meanQuote);
            meanQuote = PoolTwap.quoteToUsdcAtTick(meanTick, token, address(usdc), amountIn);
        }
        pool.setSpotTick(spotTick);
        uint256 payout = _ceilBps(meanQuote, payoutBps);

        (, uint256 lossBefore,) = vault.keeperBudgetOf(nftId);
        vm.prank(keeper);
        vault.swapIdle(nftId, tokenIn, tokenOut, amountIn, 0, _swapData(tokenIn, tokenOut, amountIn, payout));
        (, uint256 lossAfter,) = vault.keeperBudgetOf(nftId);

        uint256 meanLoss = _lossAtTick(meanTick, token, sellToken, amountIn, payout);
        uint256 spotLoss = _lossAtTick(spotTick, token, sellToken, amountIn, payout);
        assertEq(lossAfter - lossBefore, meanLoss > spotLoss ? meanLoss : spotLoss);
    }

    /// @dev One consistently measured loss: input and output valued at the same tick.
    function _lossAtTick(int24 tick, address token, bool sellToken, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (uint256)
    {
        uint256 valueIn = sellToken ? PoolTwap.quoteToUsdcAtTick(tick, token, address(usdc), amountIn) : amountIn;
        uint256 valueOut = sellToken ? amountOut : PoolTwap.quoteToUsdcAtTick(tick, token, address(usdc), amountOut);
        return valueIn > valueOut ? valueIn - valueOut : 0;
    }

    /// @dev The spot tick at the edge of the gate on the side where `token` is cheap against
    ///      USDC, off the fixture's zero mean. Which sign that is depends on the slot the
    ///      pool sorted the token into, so it is derived rather than assumed.
    function _tickWhereTokenIsCheap(MockUniswapV3Pool pool, address token) internal view returns (int24) {
        return pool.token0() == token ? -TuoConstants.MAX_TWAP_DEVIATION_TICKS : TuoConstants.MAX_TWAP_DEVIATION_TICKS;
    }

    // ------------------------------- mint: composition fixed at spot, valued at the mean

    /// @dev The pool fixes a mint's composition at spot; the vault values the liquidity at
    ///      the mean. With spot at the band edge and the narrowest one-sided range, the mean-
    ///      measured NAV drop is about 99.5 bps of what went in (1 - 1.0001^-100), and it
    ///      used to be recorded nowhere. The charge is exactly the settlement-NAV drop.
    function test_MintLpChargesTheMeanMeasuredCompositionGapAtTheBandEdge() public {
        (int24 lower, int24 upper, int24 spotTick) = _narrowestEdgeRange(wethPool);
        wethPool.setSpotTick(spotTick);
        (uint256 amount0, uint256 amount1) = _pair(10_000e6, 0);

        uint256 expected = _expectedMintCharge(wethPool, 0, spotTick, lower, upper, amount0, amount1);
        assertApproxEqRel(expected, 99.5e6, 0.001e18, "99.5 bps of the leg");

        uint256 navBefore = vault.settlementNav(nftId);
        vm.expectEmit(address(vault));
        emit ITuoVault.KeeperLossCharged(nftId, expected, expected, 300e6);
        vm.prank(keeper);
        vault.mintLp(nftId, address(wethPool), lower, upper, amount0, amount1);

        (, uint256 loss,) = vault.keeperBudgetOf(nftId);
        assertEq(loss, expected);
        assertEq(loss, navBefore - vault.settlementNav(nftId), "the charge is the NAV drop the mint booked");
    }

    /// @dev The whole position at the edge: about 199 USDC per mint against a 300 USDC
    ///      ceiling. The burn in between returns what the mint pulled and charges nothing, so
    ///      the second mint is the one the ceiling refuses, and the NPM mint rolls back with it.
    function test_EdgeMintsAccrueUntilTheLossCeilingRefusesOne() public {
        (int24 lower, int24 upper, int24 spotTick) = _narrowestEdgeRange(wethPool);
        wethPool.setSpotTick(spotTick);
        (uint256 amount0, uint256 amount1) = _pair(20_000e6, 0);

        vm.startPrank(keeper);
        (uint256 lpId,) = vault.mintLp(nftId, address(wethPool), lower, upper, amount0, amount1);
        (, uint256 loss,) = vault.keeperBudgetOf(nftId);
        assertApproxEqRel(loss, 199e6, 0.001e18, "one edge mint is two thirds of the ceiling");

        vault.burnLp(nftId, lpId);
        (, uint256 afterBurn,) = vault.keeperBudgetOf(nftId);
        assertEq(afterBurn, loss, "the burn returns what was pulled and charges nothing");

        uint256 idleBefore = vault.idleBalance(nftId, address(usdc));
        (amount0, amount1) = _pair(idleBefore, 0);
        vm.expectPartialRevert(ITuoVault.KeeperLossBudgetExceeded.selector);
        vault.mintLp(nftId, address(wethPool), lower, upper, amount0, amount1);
        vm.stopPrank();

        assertEq(vault.getPosition(nftId).lpTokenIds.length, 0, "the refused mint left no LP behind");
        assertEq(vault.idleBalance(nftId, address(usdc)), idleBefore, "and no idle left the position");
    }

    /// @dev At the mean the two measurements coincide: nothing is charged, nothing emitted.
    function test_MintLpAtTheMeanChargesNothing() public {
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        vm.recordLogs();
        _keeperMintLp(nftId, 4_000e6, 3_000e6);

        (, uint256 loss,) = vault.keeperBudgetOf(nftId);
        assertEq(loss, 0);
        _assertNoKeeperLossEvent();
    }

    /// @dev The gap falls with the width of the range: an honest, wide deploy at the same
    ///      spot is charged a fraction of what the narrowest one is.
    function test_MintLpChargesLessOnAWiderRange() public {
        (int24 lower, int24 upper, int24 spotTick) = _narrowestEdgeRange(wethPool);
        wethPool.setSpotTick(spotTick);
        (uint256 amount0, uint256 amount1) = _pair(5_000e6, 0);
        bool upperIsSpot = upper == spotTick;

        vm.startPrank(keeper);
        vault.mintLp(nftId, address(wethPool), lower, upper, amount0, amount1);
        (, uint256 narrow,) = vault.keeperBudgetOf(nftId);

        int24 wideLower = upperIsSpot ? lower - 1_000 : lower;
        int24 wideUpper = upperIsSpot ? upper : upper + 1_000;
        vault.mintLp(nftId, address(wethPool), wideLower, wideUpper, amount0, amount1);
        (, uint256 both,) = vault.keeperBudgetOf(nftId);
        vm.stopPrank();

        uint256 wide = both - narrow;
        assertGt(wide, 0, "still a gap, still charged");
        assertLt(wide * 4, narrow, "the six-times-wider range is charged less than a quarter");
    }

    /// @dev The vault charges the mean-valued amounts the mint consumed against the mean-
    ///      valued liquidity it produced. This recomputes that gap the long way from the idle
    ///      deltas and the returned liquidity, with spot anywhere inside the gate and the range
    ///      anywhere around the mean, on both pool sort orders.
    function testFuzz_MintLpChargesTheMeanMeasuredDelta(
        int256 meanSeed,
        int256 gapSeed,
        int256 lowerSeed,
        int256 widthSeed,
        uint256 usdcAmount,
        uint256 tokenUsdc,
        bool useWbtc
    ) public {
        assertTrue(wethPool.token0() == address(weth) && wbtcPool.token1() == address(wbtc), "both sort orders");
        MockUniswapV3Pool pool = useWbtc ? wbtcPool : wethPool;
        address token = useWbtc ? address(wbtc) : address(weth);

        // Same tick envelope as the swap fuzz; the range sits anywhere around the mean.
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 meanTick = int24(bound(meanSeed, -100_000, 100_000));
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 lower = meanTick + int24(bound(lowerSeed, -3_000, 500));
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 upper = lower + int24(bound(widthSeed, TuoConstants.MIN_LP_TICK_WIDTH, 3_000));
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 spotTick = meanTick
            + int24(bound(gapSeed, -TuoConstants.MAX_TWAP_DEVIATION_TICKS, TuoConstants.MAX_TWAP_DEVIATION_TICKS));
        // Up to 10,000 USDC in, so the worst gap (about 1%) stays inside the 300 USDC ceiling.
        usdcAmount = bound(usdcAmount, 1e6, 5_000e6);
        tokenUsdc = bound(tokenUsdc, 1e6, 5_000e6);

        // Fund the token side at par with spot on the mean, which charges nothing.
        pool.setTwapTick(meanTick);
        pool.setSpotTick(meanTick);
        uint256 tokenAmount = PoolTwap.quoteFromUsdcAtTick(meanTick, token, address(usdc), tokenUsdc);
        vm.prank(keeper);
        vault.swapIdle(
            nftId, address(usdc), token, tokenUsdc, 0, _swapData(address(usdc), token, tokenUsdc, tokenAmount)
        );
        pool.setSpotTick(spotTick);

        bool usdcIsToken0 = pool.token0() == address(usdc);
        (uint256 desired0, uint256 desired1) = usdcIsToken0 ? (usdcAmount, tokenAmount) : (tokenAmount, usdcAmount);
        uint256 idle0 = vault.idleBalance(nftId, pool.token0());
        uint256 idle1 = vault.idleBalance(nftId, pool.token1());
        (, uint256 lossBefore,) = vault.keeperBudgetOf(nftId);

        vm.prank(keeper);
        (, uint128 liquidity) = vault.mintLp(nftId, address(pool), lower, upper, desired0, desired1);

        uint256 consumed = _pairValueAtTick(
            pool,
            meanTick,
            idle0 - vault.idleBalance(nftId, pool.token0()),
            idle1 - vault.idleBalance(nftId, pool.token1())
        );
        uint256 minted = _liquidityValueAtTick(pool, meanTick, lower, upper, liquidity);
        (, uint256 lossAfter,) = vault.keeperBudgetOf(nftId);
        assertEq(lossAfter - lossBefore, consumed > minted ? consumed - minted : 0);
    }

    /// @dev The narrowest range the vault admits, one-sided against spot at the far edge of
    ///      the gate so the mean sits on the range's other boundary: the configuration the
    ///      gap is largest in. Which side that is depends on the slot USDC sorted into.
    function _narrowestEdgeRange(MockUniswapV3Pool pool)
        internal
        view
        returns (int24 lower, int24 upper, int24 spotTick)
    {
        int24 width = TuoConstants.MIN_LP_TICK_WIDTH;
        int24 edge = TuoConstants.MAX_TWAP_DEVIATION_TICKS;
        // USDC as token1 is held below spot, so the range runs from the mean UP to spot.
        return pool.token1() == address(usdc) ? (int24(0), width, edge) : (-width, int24(0), -edge);
    }

    /// @dev Replays the mock NPM's execution at `spotTick` to derive what the mint consumes,
    ///      then values that and the resulting liquidity at `meanTick`.
    function _expectedMintCharge(
        MockUniswapV3Pool pool,
        int24 meanTick,
        int24 spotTick,
        int24 lower,
        int24 upper,
        uint256 desired0,
        uint256 desired1
    ) internal view returns (uint256) {
        uint160 sqrtSpot = TickMath.getSqrtRatioAtTick(spotTick);
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(upper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtSpot, sqrtA, sqrtB, desired0, desired1);
        (uint256 consumed0, uint256 consumed1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtSpot, sqrtA, sqrtB, liquidity);
        uint256 consumed = _pairValueAtTick(pool, meanTick, consumed0, consumed1);
        uint256 minted = _liquidityValueAtTick(pool, meanTick, lower, upper, liquidity);
        return consumed > minted ? consumed - minted : 0;
    }

    function _liquidityValueAtTick(MockUniswapV3Pool pool, int24 tick, int24 lower, int24 upper, uint128 liquidity)
        internal
        view
        returns (uint256)
    {
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtRatioAtTick(tick),
            TickMath.getSqrtRatioAtTick(lower),
            TickMath.getSqrtRatioAtTick(upper),
            liquidity
        );
        return _pairValueAtTick(pool, tick, amount0, amount1);
    }

    function _pairValueAtTick(MockUniswapV3Pool pool, int24 tick, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint256 value)
    {
        address token0 = pool.token0();
        address token1 = pool.token1();
        value = token0 == address(usdc) ? amount0 : PoolTwap.quoteToUsdcAtTick(tick, token0, address(usdc), amount0);
        value += token1 == address(usdc) ? amount1 : PoolTwap.quoteToUsdcAtTick(tick, token1, address(usdc), amount1);
    }

    function _assertNoKeeperLossEvent() internal view {
        bytes32 topic = ITuoVault.KeeperLossCharged.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != topic, "no KeeperLossCharged emitted");
        }
    }

    /// @dev A fill better than the TWAP is not a loss, and must not bank credit either.
    function test_KeeperLossBudgetIgnoresFavourableFills() public {
        vm.prank(keeper);
        vault.swapIdle(
            nftId,
            address(usdc),
            address(weth),
            10_000e6,
            0,
            _swapData(address(usdc), address(weth), 10_000e6, 10_500e6)
        );
        (, uint256 loss,) = vault.keeperBudgetOf(nftId);
        assertEq(loss, 0);
    }

    /// @dev `bridgeToHl` is delta-zero by construction - custody NAV books bridged margin
    ///      at par - so hedging never eats the value budget. The Hyperliquid leg is bounded
    ///      by the product's `maxHedgeBps` instead, and saying so is the honest description
    ///      of what these two controls cover between them.
    function test_BridgingToHlIsNotChargedAsLoss() public {
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 10_000e6, hlOperator);

        (uint256 actions, uint256 loss,) = vault.keeperBudgetOf(nftId);
        assertEq(actions, 1, "still a metered action");
        assertEq(loss, 0, "but not a loss");
        assertEq(vault.getPosition(nftId).hlMarginBridged, 10_000e6);
    }

    /// @dev The ceiling is sized on total basis by policy, so bridging margin shrinks what
    ///      the charged actions can reach without shrinking what they may lose. At Basis
    ///      Plus Core's 50% cap the unchanged 300 USDC ceiling is 3% of the 10,000 USDC still
    ///      in the vault, and that ceiling is the control that binds first.
    function test_BridgingToTheHedgeCapLeavesTheLossCeilingOnTotalBasis() public {
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 10_000e6, hlOperator);

        (,, uint256 ceiling) = vault.keeperBudgetOf(nftId);
        uint256 idle = vault.idleBalance(nftId, address(usdc));
        assertEq(ceiling, 300e6, "150 bps of the 20,000 USDC basis");
        assertEq(idle, 10_000e6, "half the basis is still in the vault");
        assertEq((ceiling * TuoConstants.BPS_DENOMINATOR) / idle, 300, "3% of what the keeper can still swap");
    }

    /// @dev Delta Hedge Standalone at its 90% cap: the same ceiling is 15% of the 2,000 USDC
    ///      left on-chain, but a floor fill of the whole allocation costs 50 bps of it. The
    ///      bridge spent one of the ten actions, so the nine floor legs the window still admits
    ///      lose 1 - 0.995^9 = 4.4% and the action budget runs out long before the ceiling is
    ///      reached. The swap floor and the action budget are what bind on a heavily hedged
    ///      position, and only a wider floor or a deeper action budget would change that.
    function test_FloorBindsBeforeTheLossCeilingOnADeltaHedgePosition() public {
        usdc.mint(bob, 20_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 20_000e6);
        uint256 dh = vault.deposit(address(usdc), 20_000e6, 2, 0, "", 0);
        vm.stopPrank();

        vm.startPrank(keeper);
        vault.bridgeToHl(dh, 18_000e6, hlOperatorB);
        (,, uint256 ceiling) = vault.keeperBudgetOf(dh);
        assertEq(ceiling, 300e6, "15% of the 2,000 USDC left on-chain");

        assertEq(vault.idleBalance(dh, address(usdc)), 2_000e6);

        // Nine legs at the floor, each selling the whole allocation back and forth.
        address tokenIn = address(usdc);
        address tokenOut = address(weth);
        for (uint256 i = 1; i < TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW; i++) {
            uint256 amountIn = vault.idleBalance(dh, tokenIn);
            uint256 payout = _applyFloor(amountIn);
            vault.swapIdle(dh, tokenIn, tokenOut, amountIn, 0, _swapData(tokenIn, tokenOut, amountIn, payout));
            (tokenIn, tokenOut) = (tokenOut, tokenIn);
        }

        (uint256 actions, uint256 loss,) = vault.keeperBudgetOf(dh);
        assertEq(actions, TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW, "the window is spent");
        assertApproxEqRel(loss, 88.19e6, 0.001e18, "4.4% of the allocation, nine floor legs compounded");
        assertLt(loss, ceiling / 3, "and nowhere near the 15% the ceiling would allow");

        uint256 leftover = vault.idleBalance(dh, tokenIn);
        bytes memory swapData = _swapData(tokenIn, tokenOut, leftover, _applyFloor(leftover));
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.KeeperRateLimitExceeded.selector, dh));
        vault.swapIdle(dh, tokenIn, tokenOut, leftover, 0, swapData);
        vm.stopPrank();
    }

    function _applyFloor(uint256 amount) internal view returns (uint256) {
        return _ceilBps(amount, TuoConstants.BPS_DENOMINATOR - vault.keeperSwapSlippageBps());
    }

    /// @dev The tolerance is a liveness setting, never a licence: a floor fill is still
    ///      charged what it gives up at the mean, so the ceiling refuses a whole-position leg
    ///      at the widest tolerance and books a smaller one to the unit.
    function test_AWiderKeeperToleranceCannotBypassTheLossCeiling() public {
        vm.prank(treasury);
        vault.setKeeperSwapSlippageBps(TuoConstants.MAX_KEEPER_SWAP_SLIPPAGE_BPS);
        assertEq(TuoConstants.MAX_KEEPER_SWAP_SLIPPAGE_BPS, 250);

        uint256 amountIn = 20_000e6;
        uint256 payout = _applyFloor(amountIn);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.KeeperLossBudgetExceeded.selector, nftId, 500e6, 300e6));
        vm.prank(keeper);
        vault.swapIdle(
            nftId, address(usdc), address(weth), amountIn, 0, _swapData(address(usdc), address(weth), amountIn, payout)
        );

        uint256 leg = 6_500e6;
        uint256 legPayout = _applyFloor(leg);
        vm.expectEmit(address(vault));
        emit ITuoVault.KeeperLossCharged(nftId, 162.5e6, 162.5e6, 300e6);
        vm.prank(keeper);
        vault.swapIdle(
            nftId, address(usdc), address(weth), leg, 0, _swapData(address(usdc), address(weth), leg, legPayout)
        );
    }

    /// @dev The event is the alerting surface, so it has to carry enough for an off-chain
    ///      consumer to judge severity without a second call: the leg's own charge, the
    ///      rolling window total, and the ceiling it is measured against.
    function test_KeeperLossChargedEventCarriesTheWindowAndCeiling() public {
        uint256 payout = _ceilBps(10_000e6, 9_950);

        // Both constants are uint16, so the basis has to carry the width of the product.
        uint256 ceiling =
            (uint256(20_000e6) * TuoConstants.MAX_KEEPER_LOSS_BPS_PER_WINDOW) / TuoConstants.BPS_DENOMINATOR;
        assertEq(ceiling, 300e6);

        vm.expectEmit(address(vault));
        emit ITuoVault.KeeperLossCharged(nftId, 50e6, 50e6, ceiling);
        vm.prank(keeper);
        vault.swapIdle(
            nftId, address(usdc), address(weth), 10_000e6, 0, _swapData(address(usdc), address(weth), 10_000e6, payout)
        );
    }

    /// @dev The budget must never be able to block the customer. Exhausting it stops the
    ///      keeper and nothing else, which is the correct failure mode: an exit path that
    ///      consulted the keeper's allowance would hand a compromised keeper a way to
    ///      trap the position it is draining.
    function test_AnExhaustedLossBudgetStillLetsTheOwnerExit() public {
        vm.startPrank(keeper);
        for (uint256 i = 0; i < 3; i++) {
            uint256 amountIn = vault.idleBalance(nftId, address(usdc));
            uint256 payout = _ceilBps(amountIn, 9_950);
            vault.swapIdle(
                nftId,
                address(usdc),
                address(weth),
                amountIn,
                0,
                _swapData(address(usdc), address(weth), amountIn, payout)
            );
            vault.swapIdle(
                nftId, address(weth), address(usdc), payout, 0, _swapData(address(weth), address(usdc), payout, payout)
            );
        }
        uint256 remaining = vault.idleBalance(nftId, address(usdc));
        vm.expectPartialRevert(ITuoVault.KeeperLossBudgetExceeded.selector);
        vault.swapIdle(
            nftId,
            address(usdc),
            address(weth),
            remaining,
            0,
            _swapData(address(usdc), address(weth), remaining, _ceilBps(remaining, 9_950))
        );
        vm.stopPrank();

        vm.prank(alice);
        vault.emergencyWithdraw(nftId);
        assertGt(usdc.balanceOf(alice), 0, "the exit does not consult the keeper budget");
        assertFalse(vault.getPosition(nftId).active);
    }
}
