// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TestnetAggregator - inventory-backed stand-in for 0x / 1inch
/// @notice TESTNET ONLY. Neither 0x AllowanceHolder nor 1inch v6 is deployed on Arbitrum
///         Sepolia, so `TuoSwapRouter`'s constructor allowlist would have nothing real to
///         point at and every swap path (non-USDC deposits, `swapIdle`, non-USDC
///         withdrawals) would be untestable.
/// @dev Pays out of its own inventory rather than minting, so it works with the canonical
///      Sepolia WETH9 as well as with `TestnetUSDC`. Fund it before use. The call shape
///      matches what the vault expects: the keeper passes
///      `abi.encode(aggregator, abi.encodeCall(TestnetAggregator.fill, (...)))` as
///      `swapData`, `TuoSwapRouter` approves exactly `amountIn` and then calls the blob,
///      so `fill` must spend the input in full or the router reverts with
///      `InputNotFullySpent`.
contract TestnetAggregator {
    using SafeERC20 for IERC20;

    error InsufficientInventory(address token, uint256 requested, uint256 available);

    /// @notice Take `amountIn` of `tokenIn` from the caller, pay `amountOut` of `tokenOut`.
    function fill(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external {
        uint256 available = IERC20(tokenOut).balanceOf(address(this));
        if (available < amountOut) revert InsufficientInventory(tokenOut, amountOut, available);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}
