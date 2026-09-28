// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Inventory-backed aggregator stand-in for the fork suite, same shape as
///         `script/mocks/TestnetAggregator`.
/// @dev The fork `InitConfig` used to pass `aggregators = []`, so `swapIdle` was
///      unreachable and the WETH leg of a two-sided LP could never be funded. Prices are
///      the caller's problem: the vault's own `_twapFloor` is what makes a fill
///      acceptable, and the fork tests quote at the pool TWAP so that floor passes on
///      merit rather than being routed around.
contract ForkAggregator {
    using SafeERC20 for IERC20;

    function fill(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}
