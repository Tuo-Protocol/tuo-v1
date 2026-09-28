// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ITuoVault} from "../../src/interfaces/ITuoVault.sol";
import {ITuoSwapRouter} from "../../src/interfaces/ITuoSwapRouter.sol";
import {PoolTwap} from "../../src/libraries/PoolTwap.sol";
import {PositionValuation} from "../../src/libraries/PositionValuation.sol";
import {TuoConstants} from "../../src/libraries/TuoConstants.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

contract TuoVaultKeeperTest is VaultTestBase {
    uint256 internal nftId;

    function setUp() public override {
        super.setUp();
        nftId = _depositUsdc(alice, 20_000e6);
    }

    // ----------------------------------------------------------- access gates

    function test_RevertWhen_KeeperSurfaceCallerLacksRole() public {
        bytes memory unauthorized = abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, mallory, keccak256("KEEPER_ROLE")
        );
        vm.startPrank(mallory);
        vm.expectRevert(unauthorized);
        vault.swapIdle(nftId, address(usdc), address(weth), 1e6, 0, "");
        vm.expectRevert(unauthorized);
        vault.mintLp(nftId, address(wethPool), -600, 600, 1e6, 1e6);
        vm.expectRevert(unauthorized);
        vault.burnLp(nftId, 100);
        vm.expectRevert(unauthorized);
        vault.bridgeToHl(nftId, 1e6, hlOperator);
        vm.expectRevert(unauthorized);
        vault.markBridgeInboundComplete(nftId, 1e6, false);
        vm.expectRevert(unauthorized);
        vault.settleHlClaim(nftId, 1e6);
        vm.stopPrank();
    }

    // -------------------------------------------------------------- swapIdle

    function test_SwapIdleMovesIdleBetweenTokens() public {
        vm.expectEmit(address(vault));
        emit ITuoVault.IdleSwapped(nftId, address(usdc), address(weth), 5_000e6, 5_000e6);
        vm.prank(keeper);
        uint256 out = vault.swapIdle(
            nftId, address(usdc), address(weth), 5_000e6, 0, _swapData(address(usdc), address(weth), 5_000e6, 5_000e6)
        );

        assertEq(out, 5_000e6);
        assertEq(vault.idleBalance(nftId, address(usdc)), 15_000e6);
        assertEq(vault.idleBalance(nftId, address(weth)), 5_000e6);
    }

    function test_SwapIdleEnforcesTwapFloorEvenWithZeroMin() public {
        // TWAP price is 1:1; paying only 90% must trip the vault's own floor
        // (99.5%) even though the keeper passed minAmountOut = 0.
        vm.expectRevert(abi.encodeWithSelector(ITuoSwapRouter.SlippageExceeded.selector, 4_500e6, 4_975e6));
        vm.prank(keeper);
        vault.swapIdle(
            nftId, address(usdc), address(weth), 5_000e6, 0, _swapData(address(usdc), address(weth), 5_000e6, 4_500e6)
        );
    }

    function test_RevertWhen_SwapIdleTokenIsUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.TokenNotAllowlisted.selector, address(dai)));
        vm.prank(keeper);
        vault.swapIdle(nftId, address(usdc), address(dai), 1_000e6, 0, "");
    }

    function test_RevertWhen_SwapIdleExceedsIdleBalance() public {
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.InsufficientIdle.selector, address(weth), 1e18, 0));
        vm.prank(keeper);
        vault.swapIdle(nftId, address(weth), address(usdc), 1e18, 0, "");
    }

    /// @dev The deviation gate is not an LP-only control. `swapIdle`'s own floor is the
    ///      30-minute TWAP minus 50 bps, so with spot far from the mean the keeper could
    ///      trade the whole position at a stale price - and the aggregator allowlist
    ///      constrains WHICH aggregator, never which pools it routes through, so a keeper
    ///      that is its own counterparty pockets the gap. 1,823 ticks is roughly 20%.
    function test_RevertWhen_SwapIdleTwapDeviationIsTooHigh() public {
        wethPool.setSpotTick(1_823);

        vm.expectRevert(abi.encodeWithSelector(PoolTwap.TwapDeviationTooHigh.selector, address(wethPool)));
        vm.prank(keeper);
        vault.swapIdle(
            nftId,
            address(usdc),
            address(weth),
            20_000e6,
            0,
            _swapData(address(usdc), address(weth), 20_000e6, 19_900e6)
        );
    }

    /// @dev And it is the same gate at the same width as `mintLp` / `burnLp` use, so the
    ///      three keeper price paths cannot disagree about what "current" means.
    function test_SwapIdleDeviationGateMatchesTheLpCallsExactly() public {
        int24 edge = TuoConstants.MAX_TWAP_DEVIATION_TICKS;

        wethPool.setSpotTick(edge);
        vm.prank(keeper);
        vault.swapIdle(
            nftId, address(usdc), address(weth), 1_000e6, 0, _swapData(address(usdc), address(weth), 1_000e6, 1_000e6)
        );

        wethPool.setSpotTick(edge + 1);
        vm.expectRevert(abi.encodeWithSelector(PoolTwap.TwapDeviationTooHigh.selector, address(wethPool)));
        vm.prank(keeper);
        vault.swapIdle(
            nftId, address(usdc), address(weth), 1_000e6, 0, _swapData(address(usdc), address(weth), 1_000e6, 1_000e6)
        );
    }

    /// @dev The floor is taken off the MEAN quote while the fill happens at spot, so drift the
    ///      gate permits eats the tolerance before any execution slippage does: 40 ticks and a
    ///      12 bps route leave an honest fill under a 50 bps floor. The treasury tolerance is
    ///      what makes the conversion reachable again, and the loss budget still measures the
    ///      leg at the mean, so nothing about the charge is loosened with it.
    function test_KeeperSwapFloorFollowsTheTreasuryTolerance() public {
        _keeperSwapToWeth(nftId, 6_500e6, 6_500e6);
        uint256 wethIdle = vault.idleBalance(nftId, address(weth));

        int24 spotTick = wethPool.token0() == address(weth) ? int24(-40) : int24(40);
        wethPool.setSpotTick(spotTick);

        uint256 spotValue = PoolTwap.quoteToUsdcAtTick(spotTick, address(weth), address(usdc), wethIdle);
        uint256 honestFill = (spotValue * (10_000 - 12)) / 10_000;
        uint256 meanValue = PoolTwap.quoteToUsdcAtTick(0, address(weth), address(usdc), wethIdle);
        uint256 tightFloor = _ceilBps(meanValue, 10_000 - KEEPER_SWAP_SLIPPAGE_BPS);
        assertLt(honestFill, tightFloor, "the best honest fill sits under the 50 bps floor");

        bytes memory swapData = _swapData(address(weth), address(usdc), wethIdle, honestFill);
        vm.expectRevert(abi.encodeWithSelector(ITuoSwapRouter.SlippageExceeded.selector, honestFill, tightFloor));
        vm.prank(keeper);
        vault.swapIdle(nftId, address(weth), address(usdc), wethIdle, 0, swapData);

        vm.prank(treasury);
        vault.setKeeperSwapSlippageBps(100);

        vm.prank(keeper);
        uint256 out = vault.swapIdle(nftId, address(weth), address(usdc), wethIdle, 0, swapData);
        assertEq(out, honestFill);
        assertEq(vault.idleBalance(nftId, address(weth)), 0, "the whole balance is converted");

        (, uint256 loss, uint256 ceiling) = vault.keeperBudgetOf(nftId);
        assertEq(loss, meanValue - honestFill, "charged the mean-measured loss: drift plus route cost");
        assertLt(loss, ceiling);
    }

    /// @dev The tolerance the treasury sets is the tolerance the floor applies, to the unit.
    function test_SwapIdleFloorIsExactAtTheTreasuryTolerance() public {
        vm.prank(treasury);
        vault.setKeeperSwapSlippageBps(100);

        uint256 amountIn = 5_000e6;
        uint256 floor = _ceilBps(PoolTwap.quoteFromUsdcAtTick(0, address(weth), address(usdc), amountIn), 9_900);

        vm.expectRevert(abi.encodeWithSelector(ITuoSwapRouter.SlippageExceeded.selector, floor - 1, floor));
        vm.prank(keeper);
        vault.swapIdle(
            nftId,
            address(usdc),
            address(weth),
            amountIn,
            0,
            _swapData(address(usdc), address(weth), amountIn, floor - 1)
        );

        vm.prank(keeper);
        uint256 out = vault.swapIdle(
            nftId, address(usdc), address(weth), amountIn, 0, _swapData(address(usdc), address(weth), amountIn, floor)
        );
        assertEq(out, floor);
    }

    // ------------------------------------------------------------- mintLp

    function test_MintLpConsumesIdleAndRegistersLp() public {
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        uint256 navBefore = vault.settlementNav(nftId);
        (uint256 amount0, uint256 amount1) = _pair(4_000e6, 3_000e6);

        vm.prank(keeper);
        (uint256 lpId, uint128 liquidity) = vault.mintLp(nftId, address(wethPool), -600, 600, amount0, amount1);

        assertGt(liquidity, 0);
        assertEq(vault.lpOwnerOf(lpId), nftId);
        assertEq(vault.lpPoolOf(lpId), address(wethPool));
        assertEq(vault.getPosition(nftId).lpTokenIds.length, 1);

        // The pool chooses the ratio, so the vault spends AT MOST what it offered on each
        // leg; the scarce side binds and is spent in full.
        uint256 usdcSpent = 15_000e6 - vault.idleBalance(nftId, address(usdc));
        uint256 wethSpent = 5_000e6 - vault.idleBalance(nftId, address(weth));
        assertLe(usdcSpent, 4_000e6);
        assertLe(wethSpent, 3_000e6);
        assertTrue(usdcSpent >= 4_000e6 - 1 || wethSpent >= 3_000e6 - 1, "one leg must bind");
        // Minting reshapes value, it does not consume it.
        assertApproxEqRel(vault.settlementNav(nftId), navBefore, 0.0001e18, "NAV across the mint");
    }

    function test_RevertWhen_MintLpPoolIsNotAllowlisted() public {
        address rogue = address(_newPool(address(dai), address(usdc)));
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.PoolNotAllowlisted.selector, rogue));
        vm.prank(keeper);
        vault.mintLp(nftId, rogue, -600, 600, 1e6, 1e6);
    }

    function test_RevertWhen_MintLpTwapDeviationIsTooHigh() public {
        wethPool.setSpotTick(500); // 500 ticks off a 0-tick TWAP > 200 bound
        vm.expectRevert(abi.encodeWithSelector(PoolTwap.TwapDeviationTooHigh.selector, address(wethPool)));
        vm.prank(keeper);
        vault.mintLp(nftId, address(wethPool), -600, 600, 1e6, 1e6);
    }

    /// @dev The gate is the only bound on a mint, so its edge must match swapIdle's exactly:
    ///      MAX_TWAP_DEVIATION_TICKS off the mean mints, one tick further reverts.
    function test_MintLpAcceptsSpotAtTheDeviationEdge() public {
        int24 edge = TuoConstants.MAX_TWAP_DEVIATION_TICKS;
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        (uint256 a0, uint256 a1) = _pair(1_000e6, 1_000e6);

        wethPool.setSpotTick(edge);
        vm.prank(keeper);
        (, uint128 liquidity) = vault.mintLp(nftId, address(wethPool), -600, 600, a0, a1);
        assertGt(liquidity, 0, "a mint at the deviation edge must land");

        wethPool.setSpotTick(edge + 1);
        vm.expectRevert(abi.encodeWithSelector(PoolTwap.TwapDeviationTooHigh.selector, address(wethPool)));
        vm.prank(keeper);
        vault.mintLp(nftId, address(wethPool), -600, 600, a0, a1);
    }

    function test_RevertWhen_MintLpExceedsIdleBalance() public {
        // No WETH idle at all.
        uint256 wethAmount = 1e18;
        (uint256 a0, uint256 a1) =
            wethPool.token0() == address(usdc) ? (uint256(1e6), wethAmount) : (wethAmount, uint256(1e6));
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.InsufficientIdle.selector, address(weth), wethAmount, 0));
        vm.prank(keeper);
        vault.mintLp(nftId, address(wethPool), -600, 600, a0, a1);
    }

    function test_MintLpRefundsUnconsumedAmounts() public {
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        // No haircut knob any more: with real V3 math the refund is automatic. Deliberately
        // non-ratio amounts at a symmetric range around spot mean the larger leg cannot be
        // fully consumed, and the excess must come back to idle.
        uint256 usdcBefore = vault.idleBalance(nftId, address(usdc));
        uint256 wethBefore = vault.idleBalance(nftId, address(weth));
        (uint256 a0, uint256 a1) = _pair(2_000e6, 500e6);

        vm.prank(keeper);
        vault.mintLp(nftId, address(wethPool), -600, 600, a0, a1);

        uint256 usdcSpent = usdcBefore - vault.idleBalance(nftId, address(usdc));
        uint256 wethSpent = wethBefore - vault.idleBalance(nftId, address(weth));
        // The scarce leg binds and is consumed in full (bar a wei of flooring); the
        // abundant one is refunded.
        assertApproxEqAbs(wethSpent, 500e6, 1, "scarce leg fully consumed");
        assertGt(usdcSpent, 0);
        assertLt(usdcSpent, 2_000e6, "the excess side must be refunded to idle");
    }

    /// @dev The vault passes zero per-leg minimums to the NPM by design. The mock's drift is
    ///      a synthetic skew of its own execution price that production cannot produce (the
    ///      mint executes against the slot0 the gate just read); its only purpose here is to
    ///      prove no floor is passed, since any floor would trip the mock's slippage check.
    function test_MintLpHasNoPerLegFloor() public {
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        npm.setMintDriftTicks(400);
        (uint256 a0, uint256 a1) = _pair(1_000e6, 1_000e6);
        vm.prank(keeper);
        (, uint128 liquidity) = vault.mintLp(nftId, address(wethPool), -600, 600, a0, a1);
        assertGt(liquidity, 0, "a mint has no per-leg floor to fail");
    }

    function test_RevertWhen_MintLpRangeIsTooNarrow() public {
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        int24 half = TuoConstants.MIN_LP_TICK_WIDTH / 2;
        (uint256 a0, uint256 a1) = _pair(1_000e6, 1_000e6);

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.LpRangeTooNarrow.selector, -half + 1, half));
        vm.prank(keeper);
        vault.mintLp(nftId, address(wethPool), -half + 1, half, a0, a1);

        // Exactly at the floor is allowed.
        vm.prank(keeper);
        (, uint128 liquidity) = vault.mintLp(nftId, address(wethPool), -half, half, a0, a1);
        assertGt(liquidity, 0);
    }

    /// @dev Nothing capped `lpTokenIds` before the product registry did. That matters
    ///      because `emergencyWithdraw` closes every LP in one transaction and
    ///      `_removeLpToken` is an O(n) scan per removal, so the array is quadratic in the
    ///      customer's guaranteed exit. Measured at 4.86M gas for 60 LPs against the mock
    ///      alone, and the real position manager is several times that - a keeper spending
    ///      its ten daily actions on dust LPs could push the exit past Arbitrum's per-
    ///      transaction ceiling inside a few weeks.
    function test_RevertWhen_MintLpExceedsTheProductLpCountCap() public {
        uint256 id = _depositUsdc(bob, 24_000e6);
        _keeperSwapToWeth(id, 6_000e6, 6_000e6);
        uint8 maxLpCount = vault.productOf(1).maxLpCount;

        for (uint256 i = 0; i < maxLpCount; i++) {
            _keeperMintLp(id, 1_000e6, 1_000e6);
        }
        assertEq(vault.getPosition(id).lpTokenIds.length, maxLpCount);

        (uint256 a0, uint256 a1) = _pair(1_000e6, 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.LpCountExceeded.selector, id, maxLpCount));
        vm.prank(keeper);
        vault.mintLp(id, address(wethPool), -600, 600, a0, a1);
    }

    // ------------------------------------------------------------- burnLp

    function test_BurnLpCreditsPrincipalAndFees() public {
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        uint256 usdcBeforeMint = vault.idleBalance(nftId, address(usdc));
        uint256 wethBeforeMint = vault.idleBalance(nftId, address(weth));
        uint256 lpId = _keeperMintLp(nftId, 4_000e6, 3_000e6);
        uint256 usdcPrincipal = usdcBeforeMint - vault.idleBalance(nftId, address(usdc));
        uint256 wethPrincipal = wethBeforeMint - vault.idleBalance(nftId, address(weth));
        npm.accrueFees(lpId, 50e6, 20e6);

        uint256 usdcIdleBefore = vault.idleBalance(nftId, address(usdc));
        uint256 wethIdleBefore = vault.idleBalance(nftId, address(weth));

        vm.prank(keeper);
        vault.burnLp(nftId, lpId);

        // At an unchanged price a round trip returns exactly the principal it consumed,
        // plus the fees, split by token slot.
        uint256 usdcGain = vault.idleBalance(nftId, address(usdc)) - usdcIdleBefore;
        uint256 wethGain = vault.idleBalance(nftId, address(weth)) - wethIdleBefore;
        uint256 usdcFee = wethPool.token0() == address(usdc) ? 50e6 : 20e6;
        uint256 wethFee = wethPool.token0() == address(usdc) ? 20e6 : 50e6;
        assertEq(usdcGain, usdcPrincipal + usdcFee);
        assertEq(wethGain, wethPrincipal + wethFee);

        assertEq(vault.lpOwnerOf(lpId), 0, "registry cleared");
        assertEq(vault.getPosition(nftId).lpTokenIds.length, 0);
    }

    function test_RevertWhen_BurnLpIsNotOwnedByThePosition() public {
        uint256 other = _depositUsdc(bob, 10_000e6);
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        uint256 lpId = _keeperMintLp(nftId, 4_000e6, 3_000e6);

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.LpNotOwnedByPosition.selector, other, lpId));
        vm.prank(keeper);
        vault.burnLp(other, lpId);
    }

    /// @dev The burn leg. 120 ticks of drift sits inside the deviation band the
    ///      vault permits, and the pre-fix per-leg floors (99.5% of the TWAP-tick expected
    ///      amounts) could not clear it in either direction: an in-range position's legs
    ///      move opposite ways with the tick, so one of them always fell short. The
    ///      combined-value floor holds because the pair is worth what it was.
    function test_BurnLpSurvivesPriceDriftInsideTheDeviationBand() public {
        int24 band = TuoConstants.MAX_TWAP_DEVIATION_TICKS;
        int24[6] memory drifts = [-band, int24(-120), int24(-10), int24(10), int24(120), band];
        for (uint256 i = 0; i < drifts.length; i++) {
            uint256 id = _depositUsdc(alice, 20_000e6);
            _keeperSwapToWeth(id, 5_000e6, 5_000e6);
            uint256 lpId = _keeperMintLp(id, 4_000e6, 3_000e6);

            npm.setBurnDriftTicks(drifts[i]);
            vm.prank(keeper);
            vault.burnLp(id, lpId);
            assertEq(vault.getPosition(id).lpTokenIds.length, 0, "burn must clear inside the band");
        }
        npm.setBurnDriftTicks(0);
    }

    /// @dev The other half of the story: price movement can never trip the burn floor,
    ///      because an LP measured at a price it has moved AWAY from is worth more, not
    ///      less (V(p,q) - V(q,q) = L(q-p)^2/p >= 0). So the floor guards the case that
    ///      remains - the position manager returning less than the liquidity implies.
    function test_RevertWhen_BurnLpReturnsLessThanTheLiquidityImplies() public {
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        uint256 lpId = _keeperMintLp(nftId, 4_000e6, 3_000e6);

        npm.setBurnShortfallBps(100); // 1%, twice the 50 bp allowance
        vm.expectPartialRevert(ITuoVault.LpValueBelowFloor.selector);
        vm.prank(keeper);
        vault.burnLp(nftId, lpId);

        // Inside the allowance it goes through.
        npm.setBurnShortfallBps(10);
        vm.prank(keeper);
        vault.burnLp(nftId, lpId);
        npm.setBurnShortfallBps(0);
    }

    /// @dev The burn floor is the TWAP value times LP_BURN_VALUE_FLOOR_BPS rounded UP, so it
    ///      never sits a unit under the exact 99.5% bound when the product is not exact.
    function test_BurnLpFloorRoundsUp() public {
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        uint256 lpId = _keeperMintLp(nftId, 4_000e6, 3_000e6);
        (,, address token0, address token1,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            npm.positions(lpId);
        uint256 valueUsdc = PositionValuation.liquidityValueUsdcAtTick(
            0, token0, token1, tickLower, tickUpper, liquidity, address(usdc)
        );
        assertNotEq((valueUsdc * TuoConstants.LP_BURN_VALUE_FLOOR_BPS) % 10_000, 0, "the exact bound is fractional");

        npm.setBurnShortfallBps(100);
        vm.prank(keeper);
        try vault.burnLp(nftId, lpId) {
            revert("burn under the floor went through");
        } catch (bytes memory err) {
            uint256 returnedUsdc;
            assembly {
                returnedUsdc := mload(add(err, 36))
            }
            assertEq(
                err,
                abi.encodeWithSelector(
                    ITuoVault.LpValueBelowFloor.selector,
                    returnedUsdc,
                    _ceilBps(valueUsdc, TuoConstants.LP_BURN_VALUE_FLOOR_BPS)
                )
            );
        }
    }

    function test_BurnLpValueNeverFallsBelowTheMeanTickExpectation() public {
        int24[5] memory drifts = [int24(-200), int24(-120), int24(0), int24(120), int24(200)];
        for (uint256 i = 0; i < drifts.length; i++) {
            uint256 id = _depositUsdc(alice, 20_000e6);
            _keeperSwapToWeth(id, 5_000e6, 5_000e6);
            uint256 lpId = _keeperMintLp(id, 4_000e6, 3_000e6);

            uint256 navBefore = vault.settlementNav(id);
            npm.setBurnDriftTicks(drifts[i]);
            vm.prank(keeper);
            vault.burnLp(id, lpId);

            // Tolerance is a few wei of flooring in the two TWAP conversions, on 20,000 USDC.
            assertGe(vault.settlementNav(id) + 4, navBefore, "burn lost value at the mean tick");
        }
        npm.setBurnDriftTicks(0);
    }

    // ------------------------------------------------------------- HL bridge

    function test_BridgeToHlBindsThePositionToItsOperator() public {
        vm.expectEmit(address(vault));
        emit ITuoVault.HlBridgeOutbound(nftId, hlOperator, 6_000e6);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 6_000e6, hlOperator);

        assertEq(usdc.balanceOf(hlOperator), 6_000e6, "funds may only reach an allowlisted operator");
        assertEq(usdc.balanceOf(hlOperatorB), 0, "the other operator receives nothing");
        assertEq(vault.getPosition(nftId).hlOperator, hlOperator, "position bound on the first bridge");
        assertEq(vault.hlOperatorPositionOf(hlOperator), nftId, "operator bound back to the position");
        assertEq(vault.hlOperatorPositionOf(hlOperatorB), 0, "the other operator stays free");
        assertEq(vault.getPosition(nftId).hlMarginBridged, 6_000e6);
        assertEq(vault.idleBalance(nftId, address(usdc)), 14_000e6);
    }

    /// @dev The allowlist is the whole of the destination control. A keeper holding the
    ///      role still cannot invent a destination: this is the authorized-but-hostile
    ///      case, not the unauthorized one.
    function test_RevertWhen_BridgeToHlTargetsANonAllowlistedOperator() public {
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.HlOperatorNotAllowlisted.selector, mallory));
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 6_000e6, mallory);
    }

    /// @dev A second allowlisted operator is still the wrong one once the position has
    ///      bound. Without this, a keeper could scatter one position's margin across every
    ///      operator account and no single inbound leg could bring it all home.
    function test_RevertWhen_BridgeToHlSwitchesOperatorMidPosition() public {
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.HlOperatorMismatch.selector, nftId, hlOperator, hlOperatorB));
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 1_000e6, hlOperatorB);
    }

    /// @dev The point of running several operator accounts: two positions hedged under
    ///      different Hyperliquid masters, each settling back through its own.
    function test_TwoPositionsBindToDifferentOperatorsAndSettleIndependently() public {
        uint256 otherId = _depositUsdc(bob, 20_000e6);

        vm.startPrank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);
        vault.bridgeToHl(otherId, 5_000e6, hlOperatorB);
        vm.stopPrank();

        assertEq(usdc.balanceOf(hlOperator), 4_000e6, "operator A holds only its position's margin");
        assertEq(usdc.balanceOf(hlOperatorB), 5_000e6, "operator B holds only its position's margin");

        // Each inbound leg pulls from the position's own binding, with no operator argument
        // for a keeper to get wrong.
        vm.startPrank(keeper);
        vault.markBridgeInboundComplete(nftId, 4_000e6, false);
        vault.markBridgeInboundComplete(otherId, 5_000e6, false);
        vm.stopPrank();

        assertEq(usdc.balanceOf(hlOperator), 0, "operator A fully settled");
        assertEq(usdc.balanceOf(hlOperatorB), 0, "operator B fully settled");
        assertEq(vault.getPosition(nftId).hlMarginBridged, 0);
        assertEq(vault.getPosition(otherId).hlMarginBridged, 0);
        assertTrue(vault.getPosition(nftId).hlLifecycleOpen, "neither return was attested as final");
        assertTrue(vault.getPosition(otherId).hlLifecycleOpen);
    }

    /// @dev The inbound legs credit the named position with whatever its operator hands
    ///      back, so an operator shared by two positions would let a hostile keeper pull
    ///      one position's margin and book it as the other's profit: the victim keeps an
    ///      attribution nothing can settle, the attacker exits with the principal and 30%
    ///      of it is charged as a fee. The binding is therefore one-to-one, and the
    ///      cheapest bridge that would have created the share is refused outright.
    function test_BridgeToHlRefusesAnOperatorAnotherPositionHoldsAndBindsAFreeOne() public {
        uint256 otherId = _depositUsdc(bob, 20_000e6);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 5_000e6, hlOperator);

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.HlOperatorAlreadyBound.selector, hlOperator, nftId, otherId));
        vm.prank(keeper);
        vault.bridgeToHl(otherId, TuoConstants.MIN_HL_BRIDGE_USDC, hlOperator);

        assertEq(vault.getPosition(otherId).hlOperator, address(0), "the refused bridge bound nothing");
        assertEq(vault.getPosition(otherId).hlMarginBridged, 0, "the refused bridge attributed nothing");
        assertEq(vault.idleBalance(otherId, address(usdc)), 20_000e6, "the refused bridge moved nothing");
        assertEq(vault.hlOperatorPositionOf(hlOperator), nftId, "the first binding stands");
        assertEq(usdc.balanceOf(hlOperator), 5_000e6, "the operator holds one position's margin only");

        // The second position is not stranded: it binds to a free operator like any other.
        vm.prank(keeper);
        vault.bridgeToHl(otherId, 5_000e6, hlOperatorB);
        assertEq(vault.hlOperatorPositionOf(hlOperatorB), otherId, "the free operator binds to the second position");
    }

    /// @dev The binding outlives the position. A retired key may still owe a late bridge
    ///      credit or an outstanding claim, so it is never handed to a second position,
    ///      not even once the first has settled home and burned its NFT.
    function test_RevertWhen_ClosedPositionsOperatorIsReboundToANewPosition() public {
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 5_000e6, hlOperator);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, 5_000e6, true);
        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");
        assertFalse(vault.getPosition(nftId).active, "the first position is closed");

        uint256 otherId = _depositUsdc(bob, 20_000e6);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.HlOperatorAlreadyBound.selector, hlOperator, nftId, otherId));
        vm.prank(keeper);
        vault.bridgeToHl(otherId, 5_000e6, hlOperator);
        assertEq(vault.hlOperatorPositionOf(hlOperator), nftId, "a closed position keeps its operator for good");
    }

    function test_RevertWhen_MarkBridgeInboundCompleteBeforeAnyBridge() public {
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.HlOperatorUnbound.selector, nftId));
        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, 1_000e6, false);
    }

    function test_RevertWhen_BridgeToHlExceedsIdleBalance() public {
        // Inside the product's hedge cap (50% of a 20,000 basis) but past what is idle.
        _keeperSwapToWeth(nftId, 15_000e6, 15_000e6);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.InsufficientIdle.selector, address(usdc), 8_000e6, 5_000e6));
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 8_000e6, hlOperator);
    }

    function test_RevertWhen_BridgeToHlBreachesTheProductHedgeCap() public {
        // BP_CORE caps the hedge at 50% of basis: 10,000 of a 20,000 position.
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 10_000e6, hlOperator);

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.HedgeCapExceeded.selector, nftId, 10_100e6, 10_000e6));
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 100e6, hlOperator);
    }

    function test_RevertWhen_BridgeToHlIsBelowTheFloorOrAfterAWithdrawalRequest() public {
        vm.expectRevert(
            abi.encodeWithSelector(ITuoVault.BelowMinHlBridge.selector, TuoConstants.MIN_HL_BRIDGE_USDC - 1)
        );
        vm.prank(keeper);
        vault.bridgeToHl(nftId, TuoConstants.MIN_HL_BRIDGE_USDC - 1, hlOperator);

        // Once the owner has asked to leave, no more value goes to the venue.
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vm.expectRevert(ITuoVault.WithdrawalRequestPending.selector);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 1_000e6, hlOperator);
    }

    /// @dev The floor is an operational minimum, so the boundary value itself has to pass:
    ///      only what is strictly under it is refused. Pinned at both ends so a later `<=`
    ///      or a re-raised constant cannot pass unnoticed.
    function test_BridgeToHlAcceptsExactlyTheOperationalFloor() public {
        vm.prank(keeper);
        vault.bridgeToHl(nftId, TuoConstants.MIN_HL_BRIDGE_USDC, hlOperator);

        assertEq(vault.getPosition(nftId).hlMarginBridged, TuoConstants.MIN_HL_BRIDGE_USDC);
        // A floor-sized bridge arms the outstanding-margin rules exactly like a full one.
        vm.expectRevert(ITuoVault.HlMarginOutstanding.selector);
        vault.settlementNav(nftId);
    }

    /// @dev At the floor the rails' flat 1 USDC return fee leaves a residue worth 10% of the
    ///      leg, and settlement is blocked until something clears it. Two things can: the
    ///      operator returning the shortfall out of its own float, or `finalReturn` once a
    ///      request is armed, which is the path when the venue is genuinely empty.
    function test_FloorSizedLegSettlesThroughFinalReturn() public {
        uint256 floor = TuoConstants.MIN_HL_BRIDGE_USDC;
        vm.startPrank(keeper);
        vault.bridgeToHl(nftId, floor, hlOperator);
        vault.markBridgeInboundComplete(nftId, floor - 1e6, false);
        vm.stopPrank();

        assertEq(vault.getPosition(nftId).hlMarginBridged, 1e6, "the return fee is the residue");
        vm.expectRevert(ITuoVault.HlMarginOutstanding.selector);
        vault.settlementNav(nftId);

        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, 0, true);

        assertEq(vault.getPosition(nftId).hlMarginBridged, 0, "finalReturn clears the residue");
        assertEq(vault.settlementNav(nftId), 20_000e6 - 1e6, "the fee was a real loss to the position");
    }

    function test_MarkBridgeInboundCompletePullsFromOperator() public {
        vm.startPrank(keeper);
        vault.bridgeToHl(nftId, 6_000e6, hlOperator);
        vault.markBridgeInboundComplete(nftId, 2_000e6, false);
        vm.stopPrank();

        assertEq(vault.idleBalance(nftId, address(usdc)), 16_000e6);
        assertEq(vault.getPosition(nftId).hlMarginBridged, 4_000e6);
    }

    /// @dev Returned margin has to be counted exactly once. It used to be credited to idle
    ///      USDC and decremented from `hlMarginBridged` without clearing the keeper's
    ///      published snapshot, which stayed "fresh" for four more hours - so settlement
    ///      NAV counted the same margin twice and a withdrawal in that window charged the
    ///      30% fee on phantom profit. Measured-only settlement makes that unrepresentable:
    ///      settlement values no Hyperliquid quantity at all, it only refuses to run while
    ///      the lifecycle is open, and the returned USDC is idle before that gate lifts.
    function test_SettlementNavCountsReturnedMarginExactlyOnce() public {
        assertEq(vault.settlementNav(nftId), 20_000e6);

        vm.prank(keeper);
        vault.bridgeToHl(nftId, 10_000e6, hlOperator);

        // While hedged there is no measurable NAV at all - the vault refuses to guess.
        vm.expectRevert(ITuoVault.HlMarginOutstanding.selector);
        vault.settlementNav(nftId);

        // The hedge returns with 1,000 USDC of profit.
        usdc.mint(hlOperator, 1_000e6);
        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, 11_000e6, false);

        assertEq(vault.getPosition(nftId).hlMarginBridged, 0, "margin ledger cleared");
        assertEq(vault.idleBalance(nftId, address(usdc)), 21_000e6);

        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, 0, true);
        // 21,000, not 31,000: the returned USDC is idle, and nothing else claims it.
        assertEq(vault.settlementNav(nftId), 21_000e6, "returned margin counted twice");
    }

    function test_MarkBridgeInboundCompleteOverReturnClampsTheNominalToZero() public {
        vm.startPrank(keeper);
        vault.bridgeToHl(nftId, 6_000e6, hlOperator);
        usdc.mint(hlOperator, 1_500e6); // pnl
        vault.markBridgeInboundComplete(nftId, 7_500e6, false);
        vm.stopPrank();

        assertEq(vault.getPosition(nftId).hlMarginBridged, 0);
        assertTrue(vault.getPosition(nftId).hlLifecycleOpen, "the clamp is bookkeeping, not finality");
        assertEq(vault.idleBalance(nftId, address(usdc)), 21_500e6);
    }

    /// @dev D6 settle-then-withdraw: a hedged position has no measurable settlement NAV,
    ///      so returning the margin is what makes the exit executable. The keeper has no
    ///      readiness flag to flip - and therefore none to withhold.
    function test_WithdrawBecomesExecutableOnceMarginIsHome() public {
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 6_000e6, hlOperator);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        vm.expectRevert(ITuoVault.HlMarginOutstanding.selector);
        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");

        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, 6_000e6, true);
        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");
        assertFalse(vault.getPosition(nftId).active);
    }

    /// @dev The exit a losing hedge used to make unreachable. The venue returns what the
    ///      hedge is worth, not what it was sent, so a rally against the short brings back
    ///      LESS than went out - and the shortfall stayed in `hlMarginBridged` for ever,
    ///      with `settlementNav` reverting `HlMarginOutstanding` on every attempt. The
    ///      keeper's `finalReturn` attestation clears the residue instead of decrementing
    ///      it, and the position settles through the ordinary withdraw path.
    function test_FinalReturnZeroesTheResidueAfterAHedgeLoss() public {
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 6_000e6, hlOperator);

        // The short lost 1,500 to the counterparty: that USDC is not coming home.
        vm.prank(hlOperator);
        assertTrue(usdc.transfer(address(0xdead), 1_500e6));

        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        vm.expectEmit(true, false, false, true, address(vault));
        emit ITuoVault.HlBridgeInboundCompleted(nftId, 4_500e6, true);
        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, 4_500e6, true);

        assertEq(vault.getPosition(nftId).hlMarginBridged, 0, "the lost margin is written off, not owed");
        assertEq(vault.idleBalance(nftId, address(usdc)), 18_500e6, "only what returned is credited");
        assertEq(vault.settlementNav(nftId), 18_500e6, "the loss is the owner's, and it is measurable");

        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");
        assertFalse(vault.getPosition(nftId).active);
    }

    /// @dev The attestation is only safe while `bridgeToHl` is closed. Without an armed
    ///      request a keeper could clear the attribution on a live position and then
    ///      re-bridge past the product's hedge cap against the same basis.
    function test_RevertWhen_FinalReturnWithoutWithdrawalRequest() public {
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 6_000e6, hlOperator);

        vm.expectRevert(ITuoVault.WithdrawalNotRequested.selector);
        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, 4_500e6, true);

        // The ordinary decrement is unaffected: it never clears more than it credits.
        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, 4_500e6, false);
        assertEq(vault.getPosition(nftId).hlMarginBridged, 1_500e6);
    }

    /// @dev The extreme of the same case: the hedge is liquidated and the venue holds
    ///      nothing worth bridging, so no leg opens at all. Zero is legal only as a final
    ///      return, which writes the position off rather than stranding it behind the
    ///      24-hour emergency delay.
    function test_FinalReturnAcceptsZeroAmountAsAWriteOff() public {
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 6_000e6, hlOperator);

        vm.prank(hlOperator);
        assertTrue(usdc.transfer(address(0xdead), 6_000e6));

        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, 0, true);

        assertEq(vault.getPosition(nftId).hlMarginBridged, 0);
        assertEq(vault.idleBalance(nftId, address(usdc)), 14_000e6, "nothing was pulled");

        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");
        assertFalse(vault.getPosition(nftId).active);
    }

    // -------------------------------------------------- hostile keeper drills

    function test_RevertWhen_HostileKeeperRoutesSwapProceedsElsewhere() public {
        // The aggregator pays the router, the router sweeps to the vault, the vault
        // credits the position. Even with keeper-crafted calldata the tokens land in
        // vault-attributed idle, never on the keeper.
        vm.prank(keeper);
        vault.swapIdle(
            nftId, address(usdc), address(weth), 5_000e6, 0, _swapData(address(usdc), address(weth), 5_000e6, 5_000e6)
        );
        assertEq(weth.balanceOf(keeper), 0);
        assertEq(weth.balanceOf(address(vault)), 5_000e6);
    }

    function test_RevertWhen_HostileKeeperUsesUnlistedAggregator() public {
        address rogueAgg = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(ITuoSwapRouter.AggregatorNotAllowlisted.selector, rogueAgg));
        vm.prank(keeper);
        vault.swapIdle(nftId, address(usdc), address(weth), 5_000e6, 0, abi.encode(rogueAgg, bytes("")));
    }

    function test_RevertWhen_HostileKeeperDrainsViaSettleClaim() public {
        // settleHlClaim pays the NFT owner from the operator, and only against an
        // open claim; finalizing one is the owner's act and never the keeper's.
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.NoClaim.selector, nftId));
        vault.settleHlClaim(nftId, 1e6);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.NoClaim.selector, nftId));
        vault.finalizeHlClaim(nftId);
        vm.stopPrank();
    }

    function test_VaultBalanceIsFullyAttributed() public {
        // Vault ERC20 balance always equals the sum of positions' accounted assets.
        uint256 other = _depositUsdc(bob, 10_000e6);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 6_000e6, hlOperator);

        uint256 accounted = vault.idleBalance(nftId, address(usdc)) + vault.idleBalance(other, address(usdc));
        assertEq(usdc.balanceOf(address(vault)), accounted);
    }
}
