// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

/// @title TestnetPoolPoker - move a real pool's spot price on demand
/// @notice Pushes a real Uniswap V3 pool's spot price to a target tick, by swapping
///         against it with a price limit.
/// @dev Test-only. Nothing else can move the price on a fork, and without a price move the
///      LP burn leg is never exercised against a moved tick: the original fork test minted
///      a single-sided range strictly below spot, the one configuration where the returned
///      amounts are tick-invariant, so a broken burn-side value floor still passed.
///
///      Fund it with `deal` before poking. The callback pays from this contract's own
///      balance, so a poke that needs more than it holds reverts inside the pool rather
///      than silently doing nothing.
contract TestnetPoolPoker {
    using SafeERC20 for IERC20;

    /// @notice Swap until the pool's spot price reaches `targetTick` (or liquidity runs out).
    function pokeTo(IUniswapV3Pool pool, int24 targetTick) external {
        (, int24 currentTick,,,,,) = pool.slot0();
        if (targetTick == currentTick) return;
        bool zeroForOne = targetTick < currentTick;
        pool.swap(
            address(this),
            zeroForOne,
            type(int256).max / 2, // exact-input, capped by the price limit below
            TickMath.getSqrtRatioAtTick(targetTick),
            abi.encode(pool.token0(), pool.token1())
        );
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        (address token0, address token1) = abi.decode(data, (address, address));
        // Both casts are guarded by the sign check on the same line; a positive delta is
        // what the pool is owed.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (amount0Delta > 0) IERC20(token0).safeTransfer(msg.sender, uint256(amount0Delta));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (amount1Delta > 0) IERC20(token1).safeTransfer(msg.sender, uint256(amount1Delta));
    }
}
