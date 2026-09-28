// SPDX-License-Identifier: LicenseRef-BUSL-1.1
pragma solidity 0.8.26;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {OracleLibrary} from "../vendor/uniswap/OracleLibrary.sol";
import {TuoConstants} from "./TuoConstants.sol";

/// @title PoolTwap - pool-native TWAP reads for valuation and manipulation gates
/// @author Tuo Team
/// @notice The vault's only on-chain price source. Every allowlisted pool pairs its
///         token with USDC, so a pool's TWAP is that token's USDC price directly.
///         Raw slot0 is read ONLY to compare against the TWAP (the deviation gate
///         against single-block spot manipulation) and, once it has passed that gate,
///         as evidence when the vault measures a keeper swap's loss; every price and
///         every floor use the TWAP tick. {PositionValuation} also reads the slot0 tick,
///         but only to select fee-growth branches, never as a price.
library PoolTwap {
    /// @notice The pool's spot tick strays further than MAX_TWAP_DEVIATION_TICKS from its
    ///         TWAP tick, so spot cannot be trusted as a value right now.
    /// @dev Also declared on {ITuoVault} so the selector appears on the vault's ABI; this
    ///      is the copy that is actually reverted.
    /// @param pool the pool that failed the gate
    error TwapDeviationTooHigh(address pool);

    /// @notice Arithmetic mean tick over TuoConstants.TWAP_WINDOW.
    /// @param pool the pool to consult
    /// @return tick the mean tick; reverts `OLD` if the pool's observation array does not
    ///         yet span the window
    function twapTick(address pool) internal view returns (int24 tick) {
        (tick,) = OracleLibrary.consult(pool, TuoConstants.TWAP_WINDOW);
    }

    /// @notice Revert when the pool's spot tick strays more than
    ///         MAX_TWAP_DEVIATION_TICKS from its TWAP tick.
    /// @dev The gate stated in its simplest form. It has no production caller: every path
    ///      that gates also prices something next, so each takes its ticks back from
    ///      {checkDeviationAndMeanTick} or {checkDeviationAndTicks} rather than pay a second
    ///      `observe()`. Kept as the readable statement of the property, and exercised
    ///      directly by the test harness.
    /// @param pool the pool to gate
    function checkDeviation(address pool) internal view {
        checkDeviationAndMeanTick(pool);
    }

    /// @notice `checkDeviation`, also returning the mean tick the caller needs next, so
    ///         `mintLp`, `burnLp` and the exit floor do not pay a second `observe()`. The
    ///         keeper swap floor uses {checkDeviationAndTicks}, which also returns spot.
    /// @param pool the pool to gate and read
    /// @return meanTick the TWAP tick over TuoConstants.TWAP_WINDOW
    function checkDeviationAndMeanTick(address pool) internal view returns (int24 meanTick) {
        (meanTick,) = checkDeviationAndTicks(pool);
    }

    /// @notice The gate, returning both ticks it compared. One `slot0()` and one `observe()`.
    /// @dev `spotTick` is evidence for a keeper-loss measurement only, never a floor or a
    ///      valuation: it is inside the band, and `swapIdle` values with it only where doing
    ///      so raises a keeper charge.
    /// @param pool the pool to gate and read
    /// @return meanTick the TWAP tick over TuoConstants.TWAP_WINDOW
    /// @return spotTick the `slot0` tick, within MAX_TWAP_DEVIATION_TICKS of `meanTick`
    function checkDeviationAndTicks(address pool) internal view returns (int24 meanTick, int24 spotTick) {
        (, spotTick,,,,,) = IUniswapV3Pool(pool).slot0();
        meanTick = twapTick(pool);
        int256 delta = int256(spotTick) - int256(meanTick);
        if (delta < 0) delta = -delta;
        if (delta > TuoConstants.MAX_TWAP_DEVIATION_TICKS) {
            revert TwapDeviationTooHigh(pool);
        }
    }

    /// @notice Value `amount` of `token` in USDC at the pool's TWAP tick.
    /// @dev `pool` must be the allowlisted token/USDC pool for `token`.
    /// @param pool the token/USDC pool to price against
    /// @param token the token being valued
    /// @param usdc the USDC address
    /// @param amount amount of `token`, in its own decimals
    /// @return the value in USDC, 6 decimals
    function quoteToUsdc(address pool, address token, address usdc, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        return OracleLibrary.getQuoteAtTick(twapTick(pool), _toUint128(amount), token, usdc);
    }

    /// @notice Value `usdcAmount` in `token` terms at the pool's TWAP tick.
    /// @dev No vault caller: the floors use {quoteFromUsdcAtTick} on a tick they already
    ///      read. The scripts use this form.
    /// @param pool the token/USDC pool to price against
    /// @param token the token being priced
    /// @param usdc the USDC address
    /// @param usdcAmount amount of USDC, 6 decimals
    /// @return the equivalent amount of `token`, in its own decimals
    function quoteFromUsdc(address pool, address token, address usdc, uint256 usdcAmount)
        internal
        view
        returns (uint256)
    {
        if (usdcAmount == 0) return 0;
        return OracleLibrary.getQuoteAtTick(twapTick(pool), _toUint128(usdcAmount), usdc, token);
    }

    /// @notice Value `amount` of `token` in USDC at an already-read tick.
    /// @dev The tick-taking counterpart of {quoteToUsdc}, for callers that have paid for
    ///      the `observe()` already. `pool` is not needed because the tick IS the price.
    /// @param tick an already-read tick: the TWAP tick, or the gated spot tick when the
    ///        vault measures a keeper swap's loss
    /// @param token the token being valued
    /// @param usdc the USDC address
    /// @param amount amount of `token`, in its own decimals
    /// @return the value in USDC, 6 decimals
    function quoteToUsdcAtTick(int24 tick, address token, address usdc, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        if (amount == 0) return 0;
        return OracleLibrary.getQuoteAtTick(tick, _toUint128(amount), token, usdc);
    }

    /// @notice Value `usdcAmount` in `token` terms at an already-read TWAP tick.
    /// @dev The tick-taking counterpart of {quoteFromUsdc}; see its note.
    /// @param tick an already-read TWAP tick
    /// @param token the token being priced
    /// @param usdc the USDC address
    /// @param usdcAmount amount of USDC, 6 decimals
    /// @return the equivalent amount of `token`, in its own decimals
    function quoteFromUsdcAtTick(int24 tick, address token, address usdc, uint256 usdcAmount)
        internal
        pure
        returns (uint256)
    {
        if (usdcAmount == 0) return 0;
        return OracleLibrary.getQuoteAtTick(tick, _toUint128(usdcAmount), usdc, token);
    }

    /// @dev The cast IS checked: the assignment happens inside the `require`, which reverts
    ///      unless the round-trip is lossless. This is the canonical Uniswap `toUint128`
    ///      idiom; the linter cannot see that the guard and the cast are the same statement.
    function _toUint128(uint256 x) private pure returns (uint128 y) {
        // A custom error cannot express this one: the guard and the cast are the same statement,
        // and splitting them to hoist an `if (...) revert` would defeat the idiom this mirrors.
        // forge-lint: disable-next-line(unsafe-typecast)
        require((y = uint128(x)) == x); // solhint-disable-line gas-custom-errors
    }
}
