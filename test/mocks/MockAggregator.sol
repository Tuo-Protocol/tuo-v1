// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MockERC20} from "./MockERC20.sol";

/// @dev Scriptable aggregator: pulls `spendAmount` of tokenIn from the caller and
///      mints `payoutAmount` of tokenOut to it. Misbehavior modes cover the router's
///      failure paths (partial spend, underpayment, outright revert).
contract MockAggregator {
    using SafeERC20 for IERC20;

    function fill(address tokenIn, address tokenOut, uint256 spendAmount, uint256 payoutAmount) external {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), spendAmount);
        MockERC20(tokenOut).mint(msg.sender, payoutAmount);
    }

    function alwaysReverts() external pure {
        revert("MockAggregator: no route");
    }
}
