// SPDX-License-Identifier: LicenseRef-BUSL-1.1
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title ITuoPositionNFT - transferable ERC-721 representing a Tuo position
/// @author Tuo Team
/// @notice Whoever owns the token owns the position: the vault treats `ownerOf(nftId)`
///         as the sole withdrawal authority. Mint and burn are vault-only; transfers are
///         plain ERC-721, refusing only the vault itself as a recipient.
interface ITuoPositionNFT is IERC721 {
    /// @notice The metadata base URI changed. Cosmetic only: no custody or accounting
    ///         path reads it.
    /// @param baseURI the new base URI
    event BaseURIUpdated(string baseURI);

    /// @notice The caller is not the vault. Mint and burn are vault-only.
    error OnlyVault();

    /// @notice The recipient is the vault. Ownership is the whole authority model and the
    ///         vault cannot call the owner-only entry points, so a position parked there
    ///         would be unreachable.
    /// @param recipient the rejected recipient
    error InvalidRecipient(address recipient);

    /// @notice Mint `nftId` to `to`. Only callable by the vault.
    /// @param to the depositor, who becomes the position's sole withdrawal authority
    /// @param nftId the position id to mint
    function mint(address to, uint256 nftId) external;

    /// @notice Burn `nftId`. Only callable by the vault: a 100% withdrawal, an emergency exit
    ///         with no Hyperliquid lifecycle open, or the owner finalizing an emergency claim.
    /// @param nftId the position id to burn
    function burn(uint256 nftId) external;

    /// @notice Update the metadata base URI (backend-served JSON). Treasury-gated.
    /// @param baseURI the new base URI
    function setBaseURI(string calldata baseURI) external;

    /// @notice The TuoVault that deployed this token and holds sole mint/burn authority.
    /// @dev SCREAMING_SNAKE to match the implementation's `immutable`, whose auto-generated
    ///      getter is the function that satisfies this declaration.
    /// @return vault the vault address, fixed at construction
    // forge-lint: disable-next-line(mixed-case-function)
    function VAULT() external view returns (address vault);
}
