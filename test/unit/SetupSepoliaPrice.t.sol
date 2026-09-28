// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {OracleLibrary} from "../../src/vendor/uniswap/OracleLibrary.sol";
import {SetupSepolia} from "../../script/SetupSepolia.s.sol";

/// @dev The Sepolia pools are initialized from a price this script derives at runtime,
///      because the testnet token addresses (and therefore the token ordering) only exist
///      after a CREATE2 in the same broadcast. A wrong sqrtPriceX96 would not fail the
///      deploy - it would silently give the vault a nonsense oracle, exactly the state the
///      pre-existing Sepolia pool is in. So round-trip it here: derive the price, convert
///      back to a tick, and quote one whole token against it.
///
///      The two `...InitTickHasTheEngineSign` tests are the other half, and they are the
///      point of the whole change: the frozen engine converts a price to a tick with
///      `tick = log(p * 10**d1 / 10**d0) / log(1.0001)` over `POOL_META`'s d0/d1, which puts
///      WETH/USDC deep NEGATIVE and WBTC/USDC POSITIVE. A pool whose tick carries the other
///      sign is the inverted-ordering bug, and no amount of round-tripping would catch it.
contract SetupSepoliaPriceTest is Test, SetupSepolia {
    // Two orderings: an address below and one above the canonical Sepolia WETH9.
    address internal constant WETH = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;
    address internal constant USDC_BELOW_WETH = 0x1111111111111111111111111111111111111111;
    address internal constant USDC_ABOVE_WETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // A WBTC stand-in on each side of the pivot, so the 8-decimal leg is exercised in both
    // orderings exactly as the WETH leg is.
    address internal constant WBTC_BELOW_USDC = 0x2222222222222222222222222222222222222222;
    address internal constant WBTC_ABOVE_USDC = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    uint256 internal constant USDC_PER_ETH = 3_000;
    uint256 internal constant USDC_PER_WBTC = 100_000;

    // --------------------------------------------------------- the price round trip

    function test_InitialPriceQuotesOneEthAtTargetWhenUsdcIsToken0() public pure {
        _assertQuote(USDC_BELOW_WETH, WETH, WETH_DECIMALS, USDC_PER_ETH);
    }

    function test_InitialPriceQuotesOneEthAtTargetWhenUsdcIsToken1() public pure {
        _assertQuote(USDC_ABOVE_WETH, WETH, WETH_DECIMALS, USDC_PER_ETH);
    }

    function test_InitialPriceQuotesOneWbtcAtTargetWhenUsdcIsToken0() public pure {
        _assertQuote(USDC_ABOVE_WETH, WBTC_ABOVE_USDC, WBTC_DECIMALS, USDC_PER_WBTC);
    }

    function test_InitialPriceQuotesOneWbtcAtTargetWhenUsdcIsToken1() public pure {
        _assertQuote(USDC_ABOVE_WETH, WBTC_BELOW_USDC, WBTC_DECIMALS, USDC_PER_WBTC);
    }

    function testFuzz_InitialPriceQuotesOneWholeTokenAtTarget(uint256 usdcPerToken, uint8 tokenDecimals, bool usdcFirst)
        public
        pure
    {
        usdcPerToken = bound(usdcPerToken, 1, 1_000_000);
        tokenDecimals = uint8(bound(tokenDecimals, 6, 18));
        address token = usdcFirst ? WBTC_ABOVE_USDC : WBTC_BELOW_USDC;
        _assertQuote(USDC_ABOVE_WETH, token, tokenDecimals, usdcPerToken);
    }

    // -------------------------------------------------------------- the tick signs

    /// @dev WETH token0 (18 dp), USDC token1 (6 dp), 3,000 USDC per ETH: the pool price is
    ///      `3000e6 / 1e18 = 3e-9`, so `log(3e-9) / log(1.0001)` is about -196,256. The
    ///      engine computes the identical quantity from `POOL_META`'s `d0: 18, d1: 6`.
    function test_WethUsdcInitTickHasTheEngineSign() public pure {
        int24 tick = _tickAt(USDC_ABOVE_WETH, WETH, WETH_DECIMALS, USDC_PER_ETH);

        // The exact value is -196256.35, and `getTickAtSqrtRatio` FLOORS, so -196,257. The
        // engine's Python `int()` truncates toward zero and prints -196,256; the two differ
        // by one tick and both are inside the tolerance. Do not "correct" one to the other.
        assertLt(tick, 0, "WETH/USDC must be deep NEGATIVE, or USDC sorted first");
        assertApproxEqAbs(int256(tick), int256(-196_257), 2, "the engine's tick for 3,000 USDC per ETH");
    }

    /// @dev WBTC token0 (8 dp), USDC token1 (6 dp), 100,000 USDC per WBTC: the pool price is
    ///      `100000e6 / 1e8 = 1e3`, so `log(1000) / log(1.0001)` is about +69,081. Same
    ///      formula, `d0: 8, d1: 6`. The two signs differ only because WBTC carries fewer
    ///      decimals than USDC does and WETH carries more.
    function test_WbtcUsdcInitTickHasTheEngineSign() public pure {
        int24 tick = _tickAt(USDC_ABOVE_WETH, WBTC_BELOW_USDC, WBTC_DECIMALS, USDC_PER_WBTC);

        assertGt(tick, 0, "WBTC/USDC must be POSITIVE, or USDC sorted first");
        assertApproxEqAbs(int256(tick), int256(69_081), 2, "the engine's tick for 100,000 USDC per WBTC");
    }

    /// @dev The inversion, stated as a property rather than as two constants: flipping which
    ///      side of USDC the token sorts on negates the tick. That is precisely the bug the
    ///      salt mining removes, and it holds for any decimals and any price.
    function testFuzz_FlippingTheTokenOrderNegatesTheTick(uint256 usdcPerToken, uint8 tokenDecimals) public pure {
        usdcPerToken = bound(usdcPerToken, 2, 1_000_000);
        tokenDecimals = uint8(bound(tokenDecimals, 6, 18));

        int24 usdcSecond = _tickAt(USDC_ABOVE_WETH, WBTC_BELOW_USDC, tokenDecimals, usdcPerToken);
        int24 usdcFirst = _tickAt(USDC_ABOVE_WETH, WBTC_ABOVE_USDC, tokenDecimals, usdcPerToken);

        // Tick granularity means the round trip is exact only to within a tick.
        assertApproxEqAbs(int256(usdcFirst), -int256(usdcSecond), 2, "the two orderings must mirror each other");
    }

    // ----------------------------------------------------------------------- helpers

    function _tickAt(address usdc, address token, uint8 tokenDecimals, uint256 usdcPerToken)
        internal
        pure
        returns (int24)
    {
        return TickMath.getTickAtSqrtRatio(_initialSqrtPriceX96(usdc, token, usdcPerToken, tokenDecimals));
    }

    function _assertQuote(address usdc, address token, uint8 tokenDecimals, uint256 usdcPerToken) internal pure {
        uint160 sqrtPriceX96 = _initialSqrtPriceX96(usdc, token, usdcPerToken, tokenDecimals);
        assertGt(sqrtPriceX96, TickMath.MIN_SQRT_RATIO, "below the representable range");
        assertLt(sqrtPriceX96, TickMath.MAX_SQRT_RATIO, "above the representable range");

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
        uint256 quoted = OracleLibrary.getQuoteAtTick(tick, uint128(10 ** tokenDecimals), token, usdc);

        // Ticks are 1 bp apart, so the round trip is exact to within a tick's width.
        assertApproxEqRel(quoted, usdcPerToken * 1e6, 0.0002e18, "one whole token must quote at the target price");
    }
}
