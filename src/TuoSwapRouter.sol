// SPDX-License-Identifier: LicenseRef-BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {ITuoSwapRouter} from "./interfaces/ITuoSwapRouter.sol";

/// @title TuoSwapRouter - vault-only DEX-aggregator execution wrapper
/// @author Tuo Team
/// @notice Deployed by the vault's constructor with a seed aggregator allowlist the
///         treasury maintains afterwards.
///         The calldata is built off-chain and untrusted; safety comes from the
///         constrained call target, exact-amount approvals cleared after use,
///         balance-delta verification of both legs, and the vault-supplied
///         `minAmountOut` floor. The router never custodies funds across calls.
/// @dev A route that spends less than `amountIn` reverts rather than refunding; see
///      {ITuoSwapRouter.InputNotFullySpent}.
///      The reentrancy guard keeps its flag in transient storage, so this deploys only to a
///      chain with EIP-1153: Arbitrum One since ArbOS 20, per foundry.toml's cancun target.
contract TuoSwapRouter is ITuoSwapRouter, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @inheritdoc ITuoSwapRouter
    address public immutable VAULT;

    mapping(address aggregator => bool allowed) private _aggregators;

    modifier onlyVault() {
        _onlyVault();
        _;
    }

    /// @notice Deployed by the vault's constructor, which becomes the immutable `VAULT`.
    /// @param aggregators the initial aggregator allowlist; treasury-maintained afterwards
    constructor(address[] memory aggregators) {
        VAULT = msg.sender;
        for (uint256 i = 0; i < aggregators.length; i++) {
            // See ITuoSwapRouter.ZeroAddress for why address(0) must be rejected here.
            if (aggregators[i] == address(0)) revert ZeroAddress();
            _aggregators[aggregators[i]] = true;
        }
    }

    /// @inheritdoc ITuoSwapRouter
    function addAggregator(address aggregator) external onlyVault {
        if (aggregator == address(0)) revert ZeroAddress();
        if (_aggregators[aggregator]) revert AggregatorAlreadyAllowlisted(aggregator);
        _aggregators[aggregator] = true;
        emit AggregatorAdded(aggregator);
    }

    /// @inheritdoc ITuoSwapRouter
    function removeAggregator(address aggregator) external onlyVault {
        if (!_aggregators[aggregator]) revert AggregatorNotAllowlisted(aggregator);
        _aggregators[aggregator] = false;
        emit AggregatorRemoved(aggregator);
    }

    /// @inheritdoc ITuoSwapRouter
    function swap(
        address aggregator,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external onlyVault nonReentrant returns (uint256 amountOut) {
        if (tokenIn == tokenOut) revert SameToken();
        if (!_aggregators[aggregator]) revert AggregatorNotAllowlisted(aggregator);

        IERC20(tokenIn).safeTransferFrom(VAULT, address(this), amountIn);
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).forceApprove(aggregator, amountIn);
        // The raw call is deliberate: an aggregator route is opaque pre-built calldata
        // with no typed interface to call through. It is bounded by the allowlisted
        // target, the exact-amount approval either side, and the balance-delta plus
        // full-spend checks below.
        (bool ok,) = aggregator.call(data); // solhint-disable-line avoid-low-level-calls
        if (!ok) revert SwapCallFailed();
        IERC20(tokenIn).forceApprove(aggregator, 0);

        uint256 leftover = IERC20(tokenIn).balanceOf(address(this)) - (inBefore - amountIn);
        if (leftover != 0) revert InputNotFullySpent(leftover);

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (amountOut < minAmountOut) revert SlippageExceeded(amountOut, minAmountOut);
        IERC20(tokenOut).safeTransfer(VAULT, amountOut);

        emit SwapExecuted(aggregator, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @inheritdoc ITuoSwapRouter
    function isAggregator(address aggregator) external view returns (bool) {
        return _aggregators[aggregator];
    }

    function _onlyVault() internal view {
        if (msg.sender != VAULT) revert OnlyVault();
    }
}
