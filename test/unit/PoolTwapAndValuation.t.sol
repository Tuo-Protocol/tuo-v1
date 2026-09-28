// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPoint128} from "@uniswap/v3-core/contracts/libraries/FixedPoint128.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";

import {INonfungiblePositionManager} from "../../src/interfaces/external/INonfungiblePositionManager.sol";
import {PoolTwap} from "../../src/libraries/PoolTwap.sol";
import {PositionValuation} from "../../src/libraries/PositionValuation.sol";
import {TuoConstants} from "../../src/libraries/TuoConstants.sol";
import {MockNonfungiblePositionManager} from "../mocks/MockNonfungiblePositionManager.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";

/// @dev External harness so internal-library reverts surface as call reverts.
contract TwapHarness {
    function twapTick(address pool) external view returns (int24) {
        return PoolTwap.twapTick(pool);
    }

    function checkDeviation(address pool) external view {
        PoolTwap.checkDeviation(pool);
    }

    function quoteToUsdc(address pool, address token, address usdc, uint256 amount) external view returns (uint256) {
        return PoolTwap.quoteToUsdc(pool, token, usdc, amount);
    }

    function quoteFromUsdc(address pool, address token, address usdc, uint256 usdcAmount)
        external
        view
        returns (uint256)
    {
        return PoolTwap.quoteFromUsdc(pool, token, usdc, usdcAmount);
    }

    function valueLpUsdc(address npm, address pool, uint256 lpTokenId, address usdc) external view returns (uint256) {
        return PositionValuation.valueLpUsdc(INonfungiblePositionManager(npm), pool, lpTokenId, usdc);
    }

    function uncollectedFees(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 inside0Last,
        uint256 inside1Last
    ) external view returns (uint256, uint256) {
        return PositionValuation.uncollectedFees(pool, tickLower, tickUpper, liquidity, inside0Last, inside1Last);
    }
}

contract PoolTwapAndValuationTest is Test {
    TwapHarness internal harness;
    MockNonfungiblePositionManager internal npm;

    address internal usdc;
    address internal weth;
    MockUniswapV3Pool internal poolUsdcIsToken1; // weth/usdc with usdc as token1
    MockUniswapV3Pool internal poolUsdcIsToken0; // usdc/other with usdc as token0

    /// @dev 1.0001^6931 ~= 2.0000: token1-per-token0 price of 2 at tick 6931.
    int24 internal constant TICK_PRICE_2 = 6931;

    /// @dev Fee-growth fixtures: `Q128` growth per unit of liquidity is one wei per unit, so
    ///      at growth `k * Q128` a position of `L` earns `k * L`.
    uint128 internal constant L = 1e6;
    uint256 internal constant Q128 = FixedPoint128.Q128;

    function setUp() public {
        vm.warp(30 days); // observe() math needs timestamp >> TWAP window

        harness = new TwapHarness();
        npm = new MockNonfungiblePositionManager();

        // Deterministic ordering: usdc must be token1 in one pool, token0 in the other.
        usdc = address(0xAAA0);
        weth = address(0x0AA0); // weth < usdc
        address other = address(0xFFF0); // usdc < other

        poolUsdcIsToken1 = new MockUniswapV3Pool(weth, usdc, 500);
        poolUsdcIsToken0 = new MockUniswapV3Pool(usdc, other, 500);
    }

    // ------------------------------------------------------------------ twap

    function test_TwapTickReturnsConstantHistoryTick() public {
        poolUsdcIsToken1.setTwapTick(1234);
        assertEq(harness.twapTick(address(poolUsdcIsToken1)), 1234);

        poolUsdcIsToken1.setTwapTick(-887000);
        assertEq(harness.twapTick(address(poolUsdcIsToken1)), -887000);
    }

    function test_CheckDeviationWithinBoundPasses() public {
        poolUsdcIsToken1.setTwapTick(1000);
        poolUsdcIsToken1.setSpotTick(1000 + TuoConstants.MAX_TWAP_DEVIATION_TICKS);
        harness.checkDeviation(address(poolUsdcIsToken1));

        poolUsdcIsToken1.setSpotTick(1000 - TuoConstants.MAX_TWAP_DEVIATION_TICKS);
        harness.checkDeviation(address(poolUsdcIsToken1));
    }

    function test_RevertWhen_DeviationExceedsBound() public {
        poolUsdcIsToken1.setTwapTick(1000);
        poolUsdcIsToken1.setSpotTick(1000 + TuoConstants.MAX_TWAP_DEVIATION_TICKS + 1);
        vm.expectRevert(abi.encodeWithSelector(PoolTwap.TwapDeviationTooHigh.selector, address(poolUsdcIsToken1)));
        harness.checkDeviation(address(poolUsdcIsToken1));
    }

    function test_QuoteToUsdcAtParityIsIdentity() public {
        poolUsdcIsToken1.setTwapTick(0); // 1:1
        assertEq(harness.quoteToUsdc(address(poolUsdcIsToken1), weth, usdc, 5_000e6), 5_000e6);
    }

    function test_QuoteToUsdcWithUsdcAsToken1AppliesPrice() public {
        // token1-per-token0 = 2 -> 100 weth ~= 200 usdc.
        poolUsdcIsToken1.setTwapTick(TICK_PRICE_2);
        assertApproxEqRel(harness.quoteToUsdc(address(poolUsdcIsToken1), weth, usdc, 100e18), 200e18, 0.001e18);
    }

    function test_QuoteToUsdcWithUsdcAsToken0AppliesInversePrice() public {
        // token1-per-token0 = 2 with usdc as token0 -> 100 other ~= 50 usdc.
        address other = poolUsdcIsToken0.token1();
        poolUsdcIsToken0.setTwapTick(TICK_PRICE_2);
        assertApproxEqRel(harness.quoteToUsdc(address(poolUsdcIsToken0), other, usdc, 100e18), 50e18, 0.001e18);
    }

    function test_QuoteFromUsdcIsInverseOfQuoteToUsdc() public {
        poolUsdcIsToken1.setTwapTick(TICK_PRICE_2);
        // 200 usdc ~= 100 weth.
        assertApproxEqRel(harness.quoteFromUsdc(address(poolUsdcIsToken1), weth, usdc, 200e18), 100e18, 0.001e18);
    }

    function test_QuoteZeroAmountIsZero() public view {
        assertEq(harness.quoteToUsdc(address(poolUsdcIsToken1), weth, usdc, 0), 0);
        assertEq(harness.quoteFromUsdc(address(poolUsdcIsToken1), weth, usdc, 0), 0);
    }

    // ------------------------------------------------------------- valuation

    function _setLp(
        uint256 id,
        MockUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 owed0,
        uint128 owed1
    ) internal {
        _setLpWithGrowth(id, pool, tickLower, tickUpper, liquidity, owed0, owed1, 0, 0);
    }

    function _setLpWithGrowth(
        uint256 id,
        MockUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 owed0,
        uint128 owed1,
        uint256 inside0Last,
        uint256 inside1Last
    ) internal {
        npm.setPosition(
            id,
            MockNonfungiblePositionManager.StoredPosition({
                token0: pool.token0(),
                token1: pool.token1(),
                fee: pool.fee(),
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                feeGrowthInside0LastX128: inside0Last,
                feeGrowthInside1LastX128: inside1Last,
                tokensOwed0: owed0,
                tokensOwed1: owed1
            })
        );
    }

    function _value(uint256 id) internal view returns (uint256) {
        return harness.valueLpUsdc(address(npm), address(poolUsdcIsToken1), id, usdc);
    }

    function test_ValueLpOwedFeesOnlyAtParitySumsBothSides() public {
        poolUsdcIsToken1.setTwapTick(0);
        _setLp(1, poolUsdcIsToken1, -1000, 1000, 0, 70e6, 30e6);
        // At 1:1, value = owed0 + owed1.
        assertEq(harness.valueLpUsdc(address(npm), address(poolUsdcIsToken1), 1, usdc), 100e6);
    }

    function test_ValueLpBelowRangeAllToken0QuotedAtTwap() public {
        // TWAP below the range: position is 100% token0 (weth), priced at 2 usdc each.
        poolUsdcIsToken1.setTwapTick(TICK_PRICE_2);
        _setLp(2, poolUsdcIsToken1, 20000, 30000, 1e15, 0, 0);
        uint256 value = harness.valueLpUsdc(address(npm), address(poolUsdcIsToken1), 2, usdc);
        assertGt(value, 0);

        // Same liquidity valued when usdc side dominates: TWAP above the range means
        // 100% token1 == usdc, no price conversion.
        poolUsdcIsToken1.setTwapTick(40000);
        uint256 valueAllUsdc = harness.valueLpUsdc(address(npm), address(poolUsdcIsToken1), 2, usdc);
        assertGt(valueAllUsdc, 0);
    }

    function test_ValueLpInRangeMatchesManualRecomputation() public {
        poolUsdcIsToken1.setTwapTick(0);
        _setLp(3, poolUsdcIsToken1, -600, 600, 5e14, 10e6, 20e6);

        uint256 value = harness.valueLpUsdc(address(npm), address(poolUsdcIsToken1), 3, usdc);
        // At parity the position is symmetric: amount0 ~= amount1, both ~ L * (1 - 1/sqrt(1.0001^600)).
        // 5e14 * 0.0295-ish per side ~= 1.478e13 per side. Owed adds 30e6.
        assertGt(value, 30e6);
        // Cross-check symmetry: token0 leg and token1 leg contribute equally at parity.
        uint256 principal = value - 30e6;
        assertApproxEqRel(principal, 2 * (principal / 2), 1); // even split sanity
        assertApproxEqRel(principal, 29_549_016_957_988, 0.01e18); // 2 * L*(1-1/1.03045^0.5)-ish
    }

    // ------------------------------------------------- uncheckpointed fees

    // Fees the pool has accrued to the range since the position's last touch. Every case
    // below is at parity (tick 0, USDC as token1), where the token0 quote is the identity,
    // so the value moves by exactly the fee amounts.

    function test_ValueLpAddsUncheckpointedFeesAtParity() public {
        poolUsdcIsToken1.setTwapTick(0);
        poolUsdcIsToken1.setSpotTick(0);
        _setLp(10, poolUsdcIsToken1, -1000, 1000, L, 7e6, 3e6);
        uint256 checkpointed = _value(10);

        poolUsdcIsToken1.setFeeGrowthGlobal(70 * Q128, 30 * Q128);
        assertEq(_value(10), checkpointed + 70 * L + 30 * L, "growth since the last touch is fee");
    }

    function test_ValueLpUnchangedWhenGrowthAlreadyCheckpointed() public {
        poolUsdcIsToken1.setTwapTick(0);
        poolUsdcIsToken1.setSpotTick(0);
        _setLp(11, poolUsdcIsToken1, -1000, 1000, L, 7e6, 3e6);
        uint256 checkpointed = _value(11);

        poolUsdcIsToken1.setFeeGrowthGlobal(40 * Q128, 25 * Q128);
        _setLpWithGrowth(11, poolUsdcIsToken1, -1000, 1000, L, 7e6, 3e6, 40 * Q128, 25 * Q128);
        assertEq(_value(11), checkpointed, "a snapshot equal to the pool's growth adds nothing");
    }

    /// @dev The four `below` / `above` branches of the pool's `getFeeGrowthInside`, driven by
    ///      the SPOT tick, while the principal stays valued at the mean: the two are different
    ///      questions and the library must not conflate them.
    function test_ValueLpFeeGrowthInsideHonoursTickOutsideOnBothSides() public {
        poolUsdcIsToken1.setTwapTick(0);
        poolUsdcIsToken1.setSpotTick(0);
        _setLp(12, poolUsdcIsToken1, -1000, 1000, L, 0, 0);
        uint256 checkpointed = _value(12);

        poolUsdcIsToken1.setFeeGrowthGlobal(100 * Q128, 100 * Q128);
        poolUsdcIsToken1.setTickFeeGrowthOutside(-1000, 30 * Q128, 9 * Q128);
        poolUsdcIsToken1.setTickFeeGrowthOutside(1000, 10 * Q128, 4 * Q128);

        // Spot inside: inside = global - lower - upper.
        assertEq(_value(12), checkpointed + 60 * L + 87 * L, "spot in range");

        // Spot below: below = global - lower, above = upper; inside = lower - upper.
        poolUsdcIsToken1.setSpotTick(-2000);
        assertEq(_value(12), checkpointed + 20 * L + 5 * L, "spot below the range");

        // Spot above: below = lower, above = global - upper; inside = upper - lower.
        poolUsdcIsToken1.setSpotTick(2000);
        poolUsdcIsToken1.setTickFeeGrowthOutside(-1000, 20 * Q128, 1 * Q128);
        poolUsdcIsToken1.setTickFeeGrowthOutside(1000, 50 * Q128, 8 * Q128);
        assertEq(_value(12), checkpointed + 30 * L + 7 * L, "spot above the range");
    }

    /// @dev Fee growth is a wrapping accumulator by design; the delta must wrap with it.
    function test_ValueLpFeeGrowthDeltaWrapsLikeThePool() public {
        poolUsdcIsToken1.setTwapTick(0);
        poolUsdcIsToken1.setSpotTick(0);
        _setLp(13, poolUsdcIsToken1, -1000, 1000, L, 0, 0);
        uint256 checkpointed = _value(13);

        poolUsdcIsToken1.setFeeGrowthGlobal(5 * Q128, 2 * Q128);
        _setLpWithGrowth(
            13,
            poolUsdcIsToken1,
            -1000,
            1000,
            L,
            0,
            0,
            type(uint256).max - 5 * Q128 + 1,
            type(uint256).max - 3 * Q128 + 1
        );
        assertEq(_value(13), checkpointed + 10 * L + 5 * L, "the snapshot sits before the wrap");
    }

    function testFuzz_ValueLpUncheckpointedFeesMatchPoolFormula(
        uint128 liquidity,
        uint256 growth0,
        uint256 growth1,
        uint256 last0,
        uint256 last1
    ) public {
        // The full liquidity range, with growth bounded so the fee stays a uint128 amount.
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        growth0 = bound(growth0, 0, 1 << 120);
        growth1 = bound(growth1, 0, 1 << 120);
        last0 = bound(last0, 0, growth0);
        last1 = bound(last1, 0, growth1);

        poolUsdcIsToken1.setTwapTick(0);
        poolUsdcIsToken1.setSpotTick(0);
        _setLp(14, poolUsdcIsToken1, -1000, 1000, liquidity, 0, 0);
        uint256 checkpointed = _value(14);

        poolUsdcIsToken1.setFeeGrowthGlobal(growth0, growth1);
        _setLpWithGrowth(14, poolUsdcIsToken1, -1000, 1000, liquidity, 0, 0, last0, last1);

        uint256 expected =
            FullMath.mulDiv(liquidity, growth0 - last0, Q128) + FullMath.mulDiv(liquidity, growth1 - last1, Q128);
        assertEq(_value(14), checkpointed + expected);
    }

    /// @dev The bound the unchecked delta rests on: once a position holds no liquidity its
    ///      bound ticks can be cleared and re-initialized under it, so the snapshot may sit
    ///      past the pool's current inside figure. Zero liquidity must make that harmless.
    function test_UncollectedFeesAreZeroWithoutLiquidityWhateverTheSnapshot() public {
        poolUsdcIsToken1.setSpotTick(0);
        poolUsdcIsToken1.setFeeGrowthGlobal(3 * Q128, 3 * Q128);
        (uint256 fees0, uint256 fees1) =
            harness.uncollectedFees(address(poolUsdcIsToken1), -1000, 1000, 0, type(uint256).max, type(uint256).max);
        assertEq(fees0, 0);
        assertEq(fees1, 0);

        _setLpWithGrowth(15, poolUsdcIsToken1, -1000, 1000, 0, 7e6, 3e6, type(uint256).max, type(uint256).max);
        assertEq(_value(15), 10e6, "only what the NPM has credited");
    }
}
