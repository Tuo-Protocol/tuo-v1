// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {ITuoVault} from "../../src/interfaces/ITuoVault.sol";
import {PoolTwap} from "../../src/libraries/PoolTwap.sol";
import {PositionValuation} from "../../src/libraries/PositionValuation.sol";
import {TuoConstants} from "../../src/libraries/TuoConstants.sol";
import {LiquidityAmounts} from "../../src/vendor/uniswap/LiquidityAmounts.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev The burn value floor at dust scale, on the WBTC/USDC pool where one raw unit of the
///      priced leg is worth the most. Ticks are written for WBTC as token0, the Arbitrum
///      order, and mirrored when the deployment sorts USDC first, which the unit fixture does.
contract TuoVaultLpBurnFloorTest is VaultTestBase {
    uint256 internal nftId;

    function setUp() public override {
        super.setUp();
        nftId = _depositUsdc(alice, 20_000e6);
    }

    /// @dev Mean 66,000, spot 65,900, range [65,800, 66,000]: the mean composition is worth
    ///      3 raw USDC, so the floor is 3, while the burn at spot returns 0 WBTC and 1 USDC.
    ///      The legs and the quote floor independently, and at this size their fixed residue
    ///      outweighs the 50 bp tolerance, so the relative check used to revert
    ///      `LpValueBelowFloor(1, 3)` and leave the ordinary unwind blocked.
    function test_BurnLpClosesADustPositionTheFloorsRoundingWouldBlock() public {
        _setTicks(66_000, 66_000);
        _fundWbtc(nftId, 66_000);
        _setTicks(66_000, 65_900);
        (uint256 lpId, uint128 liquidity) = _mintWbtcLp(nftId, 65_800, 66_000, 2, 1);
        assertEq(liquidity, 14, "the minimum-width dust position");

        vm.prank(keeper);
        (uint256 amount0, uint256 amount1) = vault.burnLp(nftId, lpId);

        (uint256 usdcBack, uint256 wbtcBack) = _usdcFirst() ? (amount0, amount1) : (amount1, amount0);
        assertEq(usdcBack, 1, "one raw USDC back");
        assertEq(wbtcBack, 0, "no WBTC back");
        assertEq(vault.lpOwnerOf(lpId), 0, "registry cleared");
        assertEq(vault.getPosition(nftId).lpTokenIds.length, 0);
    }

    /// @dev Under the line the check is off: a USDC-only range makes the mean value exactly
    ///      controllable, and a 1% shortfall on a floor one unit under 1 USDC goes through.
    function test_BurnLpToleratesAShortfallUnderTheDustThreshold() public {
        _setTicks(66_000, 66_000);
        npm.setBurnShortfallBps(100);

        (uint256 lpId,) =
            _mintWbtcLp(nftId, 65_000, 65_200, _usdcForFloor(TuoConstants.LP_BURN_FLOOR_MIN_VALUE_USDC - 1), 0);
        assertEq(_floor(lpId, 66_000), TuoConstants.LP_BURN_FLOOR_MIN_VALUE_USDC - 1);
        vm.prank(keeper);
        vault.burnLp(nftId, lpId);
        assertEq(vault.getPosition(nftId).lpTokenIds.length, 0);
    }

    /// @dev The floor binds from exactly LP_BURN_FLOOR_MIN_VALUE_USDC: the same 1% shortfall
    ///      on a floor of 1 USDC reverts with what the unwind returned against that floor.
    function test_RevertWhen_BurnLpAboveTheDustThresholdReturnsLessThanTheLiquidityImplies() public {
        _setTicks(66_000, 66_000);
        npm.setBurnShortfallBps(100);

        (uint256 lpId,) =
            _mintWbtcLp(nftId, 65_000, 65_200, _usdcForFloor(TuoConstants.LP_BURN_FLOOR_MIN_VALUE_USDC), 0);
        uint256 floorUsdc = _floor(lpId, 66_000);
        assertEq(floorUsdc, TuoConstants.LP_BURN_FLOOR_MIN_VALUE_USDC);
        uint256 valueUsdc = _meanValue(lpId, 66_000);
        uint256 returnedUsdc = valueUsdc - valueUsdc * 100 / 10_000;

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.LpValueBelowFloor.selector, returnedUsdc, floorUsdc));
        vm.prank(keeper);
        vault.burnLp(nftId, lpId);
    }

    /// @dev Honest execution never trips the floor, dust or not: the threshold is sized from
    ///      the complete residue (one raw unit of each leg, the quote's floor and the floor's
    ///      ceiling), so every position the relative check still applies to clears it. The
    ///      mean is bounded to the band the constant is sized for, WBTC at up to ~$490k.
    function testFuzz_BurnLpNeverTripsTheFloorOnHonestExecution(
        uint256 meanSeed,
        uint256 driftSeed,
        uint256 offsetSeed,
        uint256 widthSeed,
        uint256 usdcAmount,
        uint256 wbtcAmount
    ) public {
        int24 mean = int24(int256(bound(meanSeed, 40_000, 85_000)));
        int24 drift = int24(int256(bound(driftSeed, 0, 400))) - TuoConstants.MAX_TWAP_DEVIATION_TICKS;
        int24 width = int24(int256(bound(widthSeed, 20, 60))) * 10;
        int24 lower = mean - mean % 10 + int24(int256(bound(offsetSeed, 0, 100))) * 10 - 600;
        usdcAmount = bound(usdcAmount, 0, 5e6);
        wbtcAmount = bound(wbtcAmount, 0, 10_000);

        _setTicks(mean, mean);
        _fundWbtc(nftId, mean);
        (uint256 lpId,) = _mintWbtcLp(nftId, lower, lower + width, usdcAmount, wbtcAmount);

        _setTicks(mean, mean + drift);
        vm.prank(keeper);
        vault.burnLp(nftId, lpId);
        assertEq(vault.getPosition(nftId).lpTokenIds.length, 0, "honest burn must clear");
    }

    /// @dev USDC to mint into the [65,000, 65,200] range, all USDC at mean 66,000, so the
    ///      burn floor lands exactly on `target`. Searched because the liquidity round trip
    ///      can drop a unit.
    function _usdcForFloor(uint256 target) internal view returns (uint256 usdcAmount) {
        (int24 lo, int24 hi) = _usdcFirst() ? (int24(-65_200), int24(-65_000)) : (int24(65_000), int24(65_200));
        uint256 lineUsdc = target * TuoConstants.BPS_DENOMINATOR / TuoConstants.LP_BURN_VALUE_FLOOR_BPS;
        for (usdcAmount = lineUsdc - 5; usdcAmount < lineUsdc + 10; usdcAmount++) {
            (uint256 amount0, uint256 amount1) = _usdcFirst() ? (usdcAmount, uint256(0)) : (uint256(0), usdcAmount);
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                TickMath.getSqrtRatioAtTick(_tick(66_000)),
                TickMath.getSqrtRatioAtTick(lo),
                TickMath.getSqrtRatioAtTick(hi),
                amount0,
                amount1
            );
            uint256 valueUsdc = PositionValuation.liquidityValueUsdcAtTick(
                _tick(66_000), wbtcPool.token0(), wbtcPool.token1(), lo, hi, liquidity, address(usdc)
            );
            if (_ceilBps(valueUsdc, TuoConstants.LP_BURN_VALUE_FLOOR_BPS) == target) return usdcAmount;
        }
        revert("no USDC amount lands the floor on target");
    }

    function _usdcFirst() internal view returns (bool) {
        return wbtcPool.token0() == address(usdc);
    }

    function _tick(int24 tick) internal view returns (int24) {
        return _usdcFirst() ? -tick : tick;
    }

    function _setTicks(int24 mean, int24 spot) internal {
        wbtcPool.setTwapTick(_tick(mean));
        wbtcPool.setSpotTick(_tick(spot));
    }

    /// @dev Idle WBTC at the mean quote, so the swap charges no keeper loss.
    function _fundWbtc(uint256 id, int24 mean) internal {
        uint256 usdcIn = 50e6;
        uint256 wbtcOut = PoolTwap.quoteFromUsdcAtTick(_tick(mean), address(wbtc), address(usdc), usdcIn);
        vm.prank(keeper);
        vault.swapIdle(
            id, address(usdc), address(wbtc), usdcIn, wbtcOut, _swapData(address(usdc), address(wbtc), usdcIn, wbtcOut)
        );
    }

    function _mintWbtcLp(uint256 id, int24 tickLower, int24 tickUpper, uint256 usdcAmount, uint256 wbtcAmount)
        internal
        returns (uint256 lpId, uint128 liquidity)
    {
        (int24 lo, int24 hi) = _usdcFirst() ? (-tickUpper, -tickLower) : (tickLower, tickUpper);
        (uint256 amount0, uint256 amount1) = _usdcFirst() ? (usdcAmount, wbtcAmount) : (wbtcAmount, usdcAmount);
        vm.prank(keeper);
        (lpId, liquidity) = vault.mintLp(id, address(wbtcPool), lo, hi, amount0, amount1);
    }

    function _meanValue(uint256 lpId, int24 mean) internal view returns (uint256) {
        (,, address token0, address token1,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            npm.positions(lpId);
        return PositionValuation.liquidityValueUsdcAtTick(
            _tick(mean), token0, token1, tickLower, tickUpper, liquidity, address(usdc)
        );
    }

    function _floor(uint256 lpId, int24 mean) internal view returns (uint256) {
        return _ceilBps(_meanValue(lpId, mean), TuoConstants.LP_BURN_VALUE_FLOOR_BPS);
    }
}
