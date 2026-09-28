// SPDX-License-Identifier: LicenseRef-BUSL-1.1
pragma solidity 0.8.26;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {FixedPoint128} from "@uniswap/v3-core/contracts/libraries/FixedPoint128.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {INonfungiblePositionManager} from "../interfaces/external/INonfungiblePositionManager.sol";
import {LiquidityAmounts} from "../vendor/uniswap/LiquidityAmounts.sol";
import {PoolTwap} from "./PoolTwap.sol";

/// @title PositionValuation - USDC valuation of Uniswap V3 LP positions
/// @author Tuo Team
/// @notice Prices an NPM position at its pool's TWAP tick, never at raw slot0 (spot can
///         be manipulated mid-transaction; the TWAP cannot, cheaply). The slot0 tick only
///         selects fee-growth branches, as the note below explains. Principal (liquidity
///         converted to amounts at the TWAP price), fees the NPM has already credited
///         (tokensOwed) and fees the pool has accrued to the range since the position's
///         last touch are all included, so a live LP is worth what burning it would return,
///         with principal priced at the TWAP.
/// @dev The NPM writes tokensOwed only when something touches the position, so the
///      uncollected part is recomputed here from the pool's fee growth, the same arithmetic
///      `collect` runs. That part is read at the pool's SPOT tick, as the pool itself does:
///      crossing a tick flips its `feeGrowthOutside`, so the inside figure is invariant to
///      where spot sits, and a manipulator can only add to it.
library PositionValuation {
    /// @notice Value one LP position in USDC (6 decimals).
    /// @param npm the NonfungiblePositionManager custodying the position
    /// @param pool the position's pool (recorded by the vault at mint; must pair USDC)
    /// @param lpTokenId the NPM token id
    /// @param usdc the USDC address
    /// @return usdcValue principal plus credited and uncollected fees, in USDC 6 decimals
    function valueLpUsdc(INonfungiblePositionManager npm, address pool, uint256 lpTokenId, address usdc)
        internal
        view
        returns (uint256 usdcValue)
    {
        (
            ,,
            address token0,
            address token1,,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 inside0Last,
            uint256 inside1Last,
            uint128 owed0,
            uint128 owed1
        ) = npm.positions(lpTokenId);

        (uint256 fees0, uint256 fees1) =
            uncollectedFees(pool, tickLower, tickUpper, liquidity, inside0Last, inside1Last);

        int24 meanTick = PoolTwap.twapTick(pool);
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtRatioAtTick(meanTick),
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity
        );

        usdcValue =
            pairValueUsdcAtTick(meanTick, token0, token1, amount0 + owed0 + fees0, amount1 + owed1 + fees1, usdc);
    }

    /// @notice Fees the pool has accrued to a range since the position's fee growth snapshot,
    ///         which the NPM has not yet moved into tokensOwed.
    /// @dev Ported from Uniswap v3-core `Tick.getFeeGrowthInside` and v3-periphery
    ///      `PositionValue._fees` (github.com/Uniswap/v3-periphery/blob/0.8/contracts/libraries/PositionValue.sol),
    ///      taking the pool directly since the vault records it at mint.
    /// @param pool the position's pool
    /// @param tickLower lower tick of the range
    /// @param tickUpper upper tick of the range
    /// @param liquidity the position's liquidity
    /// @param inside0Last the position's feeGrowthInside0LastX128 snapshot
    /// @param inside1Last the position's feeGrowthInside1LastX128 snapshot
    /// @return fees0 uncollected token0 fees
    /// @return fees1 uncollected token1 fees
    function uncollectedFees(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 inside0Last,
        uint256 inside1Last
    ) internal view returns (uint256 fees0, uint256 fees1) {
        (, int24 tickCurrent,,,,,) = IUniswapV3Pool(pool).slot0();
        uint256 global0 = IUniswapV3Pool(pool).feeGrowthGlobal0X128();
        uint256 global1 = IUniswapV3Pool(pool).feeGrowthGlobal1X128();
        (uint256 lower0, uint256 lower1) = _feeGrowthOutside(pool, tickLower);
        (uint256 upper0, uint256 upper1) = _feeGrowthOutside(pool, tickUpper);

        // Fee growth accumulators wrap by design (the pool's own NatSpec: "can overflow the
        // uint256"); the differences are exact modulo 2^256, as in the pool's arithmetic. The
        // delta is the range's real growth since the snapshot while `liquidity > 0`, because
        // the position's own liquidity keeps both bound ticks initialized; at zero liquidity
        // the snapshot may be stale, and `mulDiv(0, ...)` is zero whatever the delta.
        unchecked {
            if (tickCurrent < tickLower) {
                lower0 = global0 - lower0;
                lower1 = global1 - lower1;
            }
            if (tickCurrent >= tickUpper) {
                upper0 = global0 - upper0;
                upper1 = global1 - upper1;
            }
            fees0 = FullMath.mulDiv(liquidity, global0 - lower0 - upper0 - inside0Last, FixedPoint128.Q128);
            fees1 = FullMath.mulDiv(liquidity, global1 - lower1 - upper1 - inside1Last, FixedPoint128.Q128);
        }
    }

    /// @notice USDC value at an already-read TWAP tick of the amounts `liquidity` represents
    ///         across [tickLower, tickUpper].
    /// @dev The composition a range holds at the mean, whatever spot fixed it at: `burnLp`
    ///      floors what an unwind returns against it, and `mintLp` charges the keeper the
    ///      gap between what a mint consumed and this.
    /// @param meanTick an already-read TWAP tick
    /// @param token0 the pool's token0
    /// @param token1 the pool's token1
    /// @param tickLower lower tick of the range
    /// @param tickUpper upper tick of the range
    /// @param liquidity the position's liquidity
    /// @param usdc the USDC address; whichever leg IS USDC is taken at par
    /// @return usdcValue combined value of both legs, in USDC 6 decimals
    function liquidityValueUsdcAtTick(
        int24 meanTick,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address usdc
    ) internal pure returns (uint256 usdcValue) {
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtRatioAtTick(meanTick),
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity
        );
        usdcValue = pairValueUsdcAtTick(meanTick, token0, token1, amount0, amount1, usdc);
    }

    /// @notice USDC value of a token0/token1 pair at an already-read TWAP tick.
    /// @dev Extracted so `burnLp` can floor the COMBINED value of what a burn returns;
    ///      {TuoConstants.LP_BURN_VALUE_FLOOR_BPS} explains why per-leg floors cannot
    ///      express that constraint.
    /// @param meanTick an already-read TWAP tick
    /// @param token0 the pool's token0
    /// @param token1 the pool's token1
    /// @param amount0 amount of token0 to value
    /// @param amount1 amount of token1 to value
    /// @param usdc the USDC address; whichever leg IS USDC is taken at par
    /// @return usdcValue combined value of both legs, in USDC 6 decimals
    function pairValueUsdcAtTick(
        int24 meanTick,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        address usdc
    ) internal pure returns (uint256 usdcValue) {
        usdcValue = token0 == usdc ? amount0 : PoolTwap.quoteToUsdcAtTick(meanTick, token0, usdc, amount0);
        usdcValue += token1 == usdc ? amount1 : PoolTwap.quoteToUsdcAtTick(meanTick, token1, usdc, amount1);
    }

    /// @dev The one `ticks()` call site: its eight-word decoder is emitted once for both bounds.
    function _feeGrowthOutside(address pool, int24 tick) private view returns (uint256 outside0, uint256 outside1) {
        (,, outside0, outside1,,,,) = IUniswapV3Pool(pool).ticks(tick);
    }
}
