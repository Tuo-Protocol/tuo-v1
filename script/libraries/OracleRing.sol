// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

/// @title OracleRing - provision a Uniswap V3 pool's observation ring in bounded steps
/// @notice `increaseObservationCardinalityNext` writes one cold slot per new observation
///         (~22k gas), so a large jump can exceed what ArbOS accepts in one transaction.
///         Walking the ring up `step` slots per call keeps every broadcast under that cap.
/// @dev `internal` so it inlines into the calling script: no deployment, no link step.
library OracleRing {
    /// @notice Raise `pool`'s `observationCardinalityNext` to `target`, `step` slots per call.
    /// @dev Uniswap's `Oracle.grow` is monotonic - a target at or below the current one
    ///      returns early - so the walk is idempotent, resumes from a ring grown by hand, and
    ///      costs no call on a pool already at or above `target`.
    function grow(IUniswapV3Pool pool, uint16 target, uint16 step) internal {
        require(step != 0, "OracleRing: zero cardinality step");
        if (step > target) step = target;

        (,,,, uint16 next,,) = pool.slot0();
        while (next < target) {
            // `target - step` cannot underflow: step is clamped above.
            next = next > target - step ? target : next + step;
            pool.increaseObservationCardinalityNext(next);
        }
    }
}
