// SPDX-License-Identifier: LicenseRef-BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITuoVault} from "./interfaces/ITuoVault.sol";
import {TuoVaultViews} from "./TuoVaultViews.sol";
import {TuoRoles} from "./libraries/TuoRoles.sol";

/// @title TuoVaultAdmin - the treasury / pauser surface of TuoVault
/// @author Tuo Team
abstract contract TuoVaultAdmin is TuoVaultViews {
    using SafeERC20 for IERC20;

    /// @inheritdoc ITuoVault
    function setFeeRecipient(address newFeeRecipient) external onlyRole(TuoRoles.TREASURY_ROLE) {
        if (newFeeRecipient == address(0)) revert ZeroAddress();
        // {_claimFees} clears the attribution before it pays, so the vault as recipient drops
        // the fee out of `accruedTokenFees` without moving a token, breaking
        // `balanceOf(vault) == sum(idle) + accruedTokenFees`. The NFT has no ERC-20 call at
        // all, and the router only ever pays the vault the measured delta of a swap it was
        // asked to make, so a sweep to either is unrecoverable.
        _requireNotProtocolOwned(newFeeRecipient);
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(newFeeRecipient);
    }

    /// @inheritdoc ITuoVault
    function claimFees() external onlyRole(TuoRoles.TREASURY_ROLE) nonReentrant returns (uint256) {
        return _claimFees(address(USDC));
    }

    /// @inheritdoc ITuoVault
    function claimTokenFees(address token) external onlyRole(TuoRoles.TREASURY_ROLE) nonReentrant returns (uint256) {
        return _claimFees(token);
    }

    /// @inheritdoc ITuoVault
    function setPerNftCap(uint256 newPerNftCapUsdc) external onlyRole(TuoRoles.TREASURY_ROLE) {
        // Bounds ONE position's basis, and nothing else. The vault has no aggregate cap and
        // no admission control on who deposits, so total exposure is unbounded on-chain:
        // one address can open any number of positions at this ceiling. `pauseDeposits` and
        // `setProductOpen(code, false)` are the only on-chain brakes, and both are reactive.
        // There is deliberately no hard ceiling above this value either - the 2-of-3 treasury
        // Safe that would raise it is the same one that can revoke KEEPER_ROLE.
        if (newPerNftCapUsdc == 0) revert InvalidCap();
        perNftCapUsdc = newPerNftCapUsdc;
        emit PerNftCapUpdated(newPerNftCapUsdc);
    }

    /// @inheritdoc ITuoVault
    function setKeeperSwapSlippageBps(uint16 newBps) external onlyRole(TuoRoles.TREASURY_ROLE) {
        _setKeeperSwapSlippageBps(newBps);
    }

    /// @inheritdoc ITuoVault
    function addAggregator(address aggregator) external onlyRole(TuoRoles.TREASURY_ROLE) {
        SWAP_ROUTER.addAggregator(aggregator);
    }

    /// @inheritdoc ITuoVault
    function removeAggregator(address aggregator) external onlyRole(TuoRoles.TREASURY_ROLE) {
        SWAP_ROUTER.removeAggregator(aggregator);
    }

    /// @inheritdoc ITuoVault
    function registerProduct(uint16 productCode, bytes32 label, uint16 maxHedgeBps, uint8 maxLpCount)
        external
        onlyRole(TuoRoles.TREASURY_ROLE)
    {
        _registerProduct(productCode, label, maxHedgeBps, maxLpCount);
    }

    /// @inheritdoc ITuoVault
    function setProductOpen(uint16 productCode, bool openForDeposits) external onlyRole(TuoRoles.TREASURY_ROLE) {
        Product storage product = _products[productCode];
        if (product.label == bytes32(0)) revert UnknownProduct(productCode);
        // `label` is never cleared: it is the registered flag, and a retired product's
        // existing positions still need their policy to resolve.
        product.openForDeposits = openForDeposits;
        emit ProductOpenUpdated(productCode, openForDeposits);
    }

    /// @inheritdoc ITuoVault
    function setHlOperator(address operator, bool allowed) external onlyRole(TuoRoles.TREASURY_ROLE) {
        _setHlOperator(operator, allowed);
    }

    /// @inheritdoc ITuoVault
    function pauseDeposits() external onlyRole(TuoRoles.PAUSER_ROLE) {
        _pause();
        emit DepositsPauseUpdated(true);
    }

    /// @inheritdoc ITuoVault
    function unpauseDeposits() external onlyRole(TuoRoles.PAUSER_ROLE) {
        _unpause();
        emit DepositsPauseUpdated(false);
    }

    /// @dev One sweep for both entry points. The fee pool is per token because the
    ///      emergency exit withholds in kind; USDC is simply the token every settlement
    ///      withdrawal accrues into.
    function _claimFees(address token) internal returns (uint256 amount) {
        amount = accruedTokenFees[token];
        if (amount == 0) revert ZeroAmount();
        accruedTokenFees[token] = 0;
        address recipient = feeRecipient;
        IERC20(token).safeTransfer(recipient, amount);
        if (token == address(USDC)) emit FeesClaimed(recipient, amount);
        else emit TokenFeesClaimed(token, recipient, amount);
    }
}
