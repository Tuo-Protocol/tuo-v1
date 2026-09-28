// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {TuoPositionNFT} from "../../src/TuoPositionNFT.sol";
import {ITuoPositionNFT} from "../../src/interfaces/ITuoPositionNFT.sol";
import {TuoRoles} from "../../src/libraries/TuoRoles.sol";
import {MockVaultShell} from "../mocks/MockVaultShell.sol";

contract TuoPositionNFTTest is Test {
    MockVaultShell internal vaultShell;
    TuoPositionNFT internal nft;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal mallory = makeAddr("mallory");
    address internal treasury = makeAddr("treasury");

    string internal constant BASE_URI = "https://api.tuo.finance/nft/";

    function setUp() public {
        vaultShell = new MockVaultShell(BASE_URI);
        nft = vaultShell.nft();
        vaultShell.setRole(TuoRoles.TREASURY_ROLE, treasury, true);
    }

    function test_VaultIsDeployer() public view {
        assertEq(nft.VAULT(), address(vaultShell));
    }

    function test_MintByVaultAssignsOwner() public {
        vaultShell.mint(alice, 1);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.balanceOf(alice), 1);
    }

    function test_RevertWhen_MintCallerIsNotVault() public {
        vm.expectRevert(ITuoPositionNFT.OnlyVault.selector);
        vm.prank(alice);
        nft.mint(alice, 1);
    }

    function test_BurnByVaultRemovesToken() public {
        vaultShell.mint(alice, 1);
        vaultShell.burn(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        nft.ownerOf(1);
    }

    function test_RevertWhen_BurnCallerIsNotVault() public {
        vaultShell.mint(alice, 1);
        vm.expectRevert(ITuoPositionNFT.OnlyVault.selector);
        vm.prank(alice);
        nft.burn(1);
    }

    // -------------------------------------------------------------------- transfers

    /// @dev The owner is the sole withdrawal authority and may hand that authority to anyone
    ///      but the vault, which is the single recipient the token refuses.
    function test_TransferMovesOwnershipToAnyThirdParty() public {
        vaultShell.mint(alice, 7);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 7);
        assertEq(nft.ownerOf(7), bob);
    }

    /// @dev There is no Tuo-authored code on the transfer path any more, so ERC-721's own
    ///      authorization IS the custody boundary and has to be pinned here.
    function test_RevertWhen_TransferCallerIsNotOwnerOrApproved() public {
        vaultShell.mint(alice, 7);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, mallory, 7));
        vm.prank(mallory);
        nft.transferFrom(alice, mallory, 7);
        assertEq(nft.ownerOf(7), alice);
    }

    function test_ApprovedSpenderCanTransfer() public {
        vaultShell.mint(alice, 7);
        vm.prank(alice);
        nft.approve(bob, 7);

        vm.prank(bob);
        nft.transferFrom(alice, bob, 7);
        assertEq(nft.ownerOf(7), bob);
    }

    /// @dev `setApprovalForAll` is per-owner, not per-token, so it also covers positions the
    ///      owner opens afterwards. On a token that IS the withdrawal authority a blanket
    ///      approval is total custody, and nothing on-chain narrows it.
    function test_OperatorApprovalCoversPositionsMintedLater() public {
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);

        vaultShell.mint(alice, 7);
        vm.prank(bob);
        nft.transferFrom(alice, bob, 7);
        assertEq(nft.ownerOf(7), bob);
    }

    /// @dev The vault answers the receiver hook and cannot call the owner-only entry points,
    ///      so a position parked there would be frozen with its LPs open, and an emergency
    ///      claim would settle into the vault's own balance as neither idle nor fee. The gate
    ///      is on the recipient, not the caller, so an approved spender is refused too.
    function test_RevertWhen_TransferRecipientIsTheVault() public {
        vaultShell.mint(alice, 7);
        bytes memory expected = abi.encodeWithSelector(ITuoPositionNFT.InvalidRecipient.selector, address(vaultShell));

        vm.startPrank(alice);
        vm.expectRevert(expected);
        nft.transferFrom(alice, address(vaultShell), 7);
        vm.expectRevert(expected);
        nft.safeTransferFrom(alice, address(vaultShell), 7);
        nft.approve(bob, 7);
        vm.stopPrank();

        vm.expectRevert(expected);
        vm.prank(bob);
        nft.transferFrom(alice, address(vaultShell), 7);
        assertEq(nft.ownerOf(7), alice, "the position never leaves its owner");
    }

    /// @dev The vault is the only refused recipient, and it is refused by address rather than
    ///      by any property a fuzzer could stumble into.
    function testFuzz_TransferIsRefusedOnlyForTheVault(address to) public {
        vaultShell.mint(alice, 7);
        if (to == address(0) || to == alice) to = bob;

        vm.prank(alice);
        if (to == address(vaultShell)) {
            vm.expectRevert(abi.encodeWithSelector(ITuoPositionNFT.InvalidRecipient.selector, to));
            nft.transferFrom(alice, to, 7);
            assertEq(nft.ownerOf(7), alice);
        } else {
            nft.transferFrom(alice, to, 7);
            assertEq(nft.ownerOf(7), to);
        }
    }

    /// @dev The burn path is what the old design cited to justify having no recipient gate at
    ///      all. The gate reads `to`, and a burn's destination is `address(0)`, so a full
    ///      withdrawal still ends the position.
    function test_BurnIsUnaffectedByTheRecipientGate() public {
        vaultShell.mint(alice, 7);
        vaultShell.burn(7);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 7));
        nft.ownerOf(7);
    }

    function test_SafeTransferReachesAContractReceiver() public {
        AcceptingReceiver receiver = new AcceptingReceiver();
        vaultShell.mint(alice, 7);

        vm.prank(alice);
        nft.safeTransferFrom(alice, address(receiver), 7);
        assertEq(nft.ownerOf(7), address(receiver));
        assertEq(receiver.lastTokenId(), 7);
    }

    function test_RevertWhen_SafeTransferRecipientHasNoReceiverHook() public {
        RejectingReceiver receiver = new RejectingReceiver();
        vaultShell.mint(alice, 7);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(receiver)));
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(receiver), 7);
        assertEq(nft.ownerOf(7), alice);
    }

    function test_TokenUriUsesBaseUri() public {
        vaultShell.mint(alice, 42);
        assertEq(nft.tokenURI(42), string.concat(BASE_URI, "42"));
    }

    function test_SetBaseUriByTreasuryUpdates() public {
        vaultShell.mint(alice, 1);
        vm.expectEmit(address(nft));
        emit ITuoPositionNFT.BaseURIUpdated("ipfs://tuo/");
        vm.prank(treasury);
        nft.setBaseURI("ipfs://tuo/");
        assertEq(nft.tokenURI(1), "ipfs://tuo/1");
    }

    function test_RevertWhen_SetBaseUriCallerIsNotTreasury() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, TuoRoles.TREASURY_ROLE
            )
        );
        vm.prank(alice);
        nft.setBaseURI("ipfs://evil/");
    }
}

/// @dev A well-behaved ERC-721 recipient, so the safe-transfer path is exercised against a
///      contract rather than an EOA that satisfies the acceptance check trivially.
contract AcceptingReceiver is IERC721Receiver {
    uint256 public lastTokenId;

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        lastTokenId = tokenId;
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev A contract with no acceptance hook. `mint` uses `_mint` for exactly this reason;
///      `safeTransferFrom` must still refuse, so a position cannot be stranded.
contract RejectingReceiver {}

