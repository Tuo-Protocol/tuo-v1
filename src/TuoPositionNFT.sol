// SPDX-License-Identifier: LicenseRef-BUSL-1.1
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ITuoPositionNFT} from "./interfaces/ITuoPositionNFT.sol";
import {TuoRoles} from "./libraries/TuoRoles.sol";

/// @title TuoPositionNFT - transferable ERC-721 representing a Tuo position
/// @author Tuo Team
/// @notice See {ITuoPositionNFT}: the token IS the position, and `ownerOf(nftId)` is
///         the sole withdrawal authority. Deployed by the vault's constructor; mint and
///         burn are vault-only and transfers are plain ERC-721, refusing only the vault
///         itself as a recipient. Metadata is served by the backend under a
///         treasury-updatable base URI (cosmetic only - no custody or accounting reads
///         it).
contract TuoPositionNFT is ERC721, ITuoPositionNFT {
    /// @inheritdoc ITuoPositionNFT
    address public immutable VAULT;

    string private _baseTokenUri;

    modifier onlyVault() {
        _onlyVault();
        _;
    }

    /// @notice Deployed by the vault's constructor, which becomes the immutable `VAULT`.
    /// @param baseURI initial metadata base URI; treasury-updatable afterwards
    constructor(string memory baseURI) ERC721("Tuo Position", "TUO-POS") {
        VAULT = msg.sender;
        _baseTokenUri = baseURI;
    }

    /// @inheritdoc ITuoPositionNFT
    /// @dev `_mint`, not `_safeMint`. The recipient is always `deposit()`'s
    ///      `msg.sender`, an address that just executed a transaction, so there is no
    ///      blind-recipient risk for the acceptance check to prevent - while the check
    ///      itself would revert deposits from any EOA carrying an EIP-7702 delegation to
    ///      a contract without `onERC721Received`. Re-introduce `_safeMint` if `deposit`
    ///      ever gains a `recipient` parameter: the argument stops holding the moment
    ///      the recipient is not the caller.
    function mint(address to, uint256 nftId) external onlyVault {
        _mint(to, nftId);
    }

    /// @inheritdoc ITuoPositionNFT
    function burn(uint256 nftId) external onlyVault {
        _burn(nftId);
    }

    /// @inheritdoc ITuoPositionNFT
    function setBaseURI(string calldata baseURI) external {
        if (!IAccessControl(VAULT).hasRole(TuoRoles.TREASURY_ROLE, msg.sender)) {
            revert IAccessControl.AccessControlUnauthorizedAccount(msg.sender, TuoRoles.TREASURY_ROLE);
        }
        _baseTokenUri = baseURI;
        emit BaseURIUpdated(baseURI);
    }

    /// @inheritdoc IERC165
    /// @dev Both ERC721 and ITuoPositionNFT (via IERC721) declare the standard surface.
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _onlyVault() internal view {
        if (msg.sender != VAULT) revert OnlyVault();
    }

    /// @dev The vault cannot call the owner-only entry points, and `settleHlClaim` pays
    ///      `ownerOf`, so a position parked there would freeze and its claim would land in
    ///      the vault's own balance as neither idle nor fee. Only the vault is named: it
    ///      alone holds that accounting. Mint and burn route through here too and pass,
    ///      their destinations being the depositor and `address(0)`.
    function _update(address to, uint256 nftId, address auth) internal override returns (address) {
        if (to == VAULT) revert InvalidRecipient(to);
        return super._update(to, nftId, auth);
    }

    /// @dev Name is fixed by the OpenZeppelin `ERC721._baseURI` virtual: the override is
    ///      linked by name, so renaming this to `_baseUri` would compile and silently
    ///      detach `tokenURI` from the base URI.
    // forge-lint: disable-next-line(mixed-case-function)
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenUri;
    }
}
