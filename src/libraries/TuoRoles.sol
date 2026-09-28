// SPDX-License-Identifier: LicenseRef-BUSL-1.1
pragma solidity 0.8.26;

/// @title TuoRoles - role identifiers shared across the Tuo contracts
/// @author Tuo Team
/// @notice Roles live on TuoVault's AccessControl. DEFAULT_ADMIN_ROLE is never granted:
///         role admins are wired in the vault constructor (TREASURY_ROLE administers
///         itself, KEEPER_ROLE, and PAUSER_ROLE), so there is no super-admin to renounce.
library TuoRoles {
    /// @dev Restricted robot account: reshape holdings inside the vault, bridge margin
    ///      to an allowlisted HL operator. Rotatable by treasury.
    bytes32 internal constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /// @dev 2-of-3 Safe: sweeps fees to a recipient it sets, rotates keeper/pauser, tunes
    ///      the per-NFT deposit cap and the keeper swap tolerance, manages aggregators, HL
    ///      operators and products, sets the NFT base URI. Cannot change the fee, upgrade, or
    ///      touch positions.
    bytes32 internal constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    /// @dev Circuit breaker: pause/unpause new deposits. Never affects withdrawals.
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
}
