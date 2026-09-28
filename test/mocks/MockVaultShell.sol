// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {TuoPositionNFT} from "../../src/TuoPositionNFT.sol";

/// @dev Stands in for TuoVault where a unit test only needs the deployer/role surface
///      the satellite contracts see: it deploys the NFT (so `VAULT == address(this)`)
///      and answers IAccessControl.hasRole from a settable map.
contract MockVaultShell {
    TuoPositionNFT public nft;
    mapping(bytes32 => mapping(address => bool)) private _roles;

    constructor(string memory baseURI) {
        nft = new TuoPositionNFT(baseURI);
    }

    function setRole(bytes32 role, address account, bool granted) external {
        _roles[role][account] = granted;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    function mint(address to, uint256 nftId) external {
        nft.mint(to, nftId);
    }

    function burn(uint256 nftId) external {
        nft.burn(nftId);
    }

    /// @dev The real vault accepts any ERC-721 unconditionally, for the Uniswap LPs it holds.
    ///      Without this the safe-transfer leg of the recipient gate would pass on
    ///      `ERC721InvalidReceiver` and prove nothing.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
