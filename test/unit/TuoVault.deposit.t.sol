// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ITuoVault} from "../../src/interfaces/ITuoVault.sol";
import {TuoConstants} from "../../src/libraries/TuoConstants.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev A minimal EIP-7702 delegate with no `onERC721Received`, which is what most wallet
///      delegates look like: they exist to batch calls and sponsor gas, not to custody
///      NFTs.
contract PlainDelegate {
    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}
}

contract TuoVaultDepositTest is VaultTestBase {
    // ------------------------------------------------------------- new deposits

    function test_DepositUsdcOpensPosition() public {
        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000e6);

        vm.expectEmit(address(vault));
        emit ITuoVault.PositionOpened(1, alice, 1, address(usdc), 10_000e6, 10_000e6);
        uint256 nftId = vault.deposit(address(usdc), 10_000e6, 1, 0, "", 0);
        vm.stopPrank();

        assertEq(nftId, 1);
        assertEq(nft.ownerOf(1), alice);
        assertEq(vault.idleBalance(1, address(usdc)), 10_000e6);
        assertEq(vault.nextNftId(), 2);

        ITuoVault.PositionView memory p = vault.getPosition(1);
        assertEq(p.basisUsdc, 10_000e6);
        assertEq(p.productCode, 1);
        assertTrue(p.active);
    }

    function test_DepositErc20SwapsToUsdc() public {
        // 2 WETH -> 5,000 USDC via the aggregator.
        weth.mint(alice, 2e18);
        vm.startPrank(alice);
        weth.approve(address(vault), 2e18);
        uint256 nftId =
            vault.deposit(address(weth), 2e18, 2, 4_900e6, _swapData(address(weth), address(usdc), 2e18, 5_000e6), 0);
        vm.stopPrank();

        assertEq(vault.getPosition(nftId).basisUsdc, 5_000e6, "basis must be USDC actually received");
        assertEq(vault.idleBalance(nftId, address(usdc)), 5_000e6);
        assertEq(vault.getPosition(nftId).productCode, 2);
    }

    function test_DepositNativeEthWrapsAndSwaps() public {
        vm.deal(alice, 3e18);
        vm.prank(alice);
        uint256 nftId = vault.deposit{value: 3e18}(
            address(0), 3e18, 1, 0, _swapData(address(weth), address(usdc), 3e18, 7_500e6), 0
        );

        assertEq(vault.getPosition(nftId).basisUsdc, 7_500e6);
        assertEq(address(vault).balance, 0, "no stray ETH in the vault");
    }

    /// @dev The position mint uses `_mint`, not `_safeMint`. With `_safeMint`, `deposit()`
    ///      reverted `ERC721InvalidReceiver` for any caller whose EOA carries a 7702
    ///      delegation to a contract without `onERC721Received` - a growing share of
    ///      ordinary wallets, locked out of the product entirely. `_mint` is right here
    ///      specifically because the recipient is always `deposit()`'s `msg.sender`, an
    ///      address that just executed a transaction, so there is no blind recipient for
    ///      the acceptance check to protect. Uniswap's own position manager mints the same
    ///      way for the same reason. Re-introduce `_safeMint` if `deposit` ever gains a
    ///      `recipient` parameter.
    function test_DepositFromA7702DelegatedEoaSucceeds() public {
        PlainDelegate delegate = new PlainDelegate();
        (address depositor, uint256 depositorKey) = makeAddrAndKey("delegated-depositor");

        vm.signAndAttachDelegation(address(delegate), depositorKey);
        assertGt(depositor.code.length, 0, "the EOA must actually be delegated");

        usdc.mint(depositor, 10_000e6);
        vm.startPrank(depositor);
        usdc.approve(address(vault), 10_000e6);
        uint256 nftId = vault.deposit(address(usdc), 10_000e6, 1, 0, "", 0);
        vm.stopPrank();

        assertEq(nft.ownerOf(nftId), depositor);
        assertEq(vault.getPosition(nftId).basisUsdc, 10_000e6);
    }

    /// @dev And the position works end to end from that account - the point is a usable
    ///      product, not merely a mint that does not revert.
    function test_ADelegatedDepositorCanAlsoExit() public {
        PlainDelegate delegate = new PlainDelegate();
        (address depositor, uint256 depositorKey) = makeAddrAndKey("delegated-exiter");
        vm.signAndAttachDelegation(address(delegate), depositorKey);

        usdc.mint(depositor, 10_000e6);
        vm.startPrank(depositor);
        usdc.approve(address(vault), 10_000e6);
        uint256 nftId = vault.deposit(address(usdc), 10_000e6, 1, 0, "", 0);
        vault.requestWithdraw(nftId, 10_000);
        vault.withdraw(nftId, address(usdc), 0, "");
        vm.stopPrank();

        assertEq(usdc.balanceOf(depositor), 10_000e6);
        vm.expectRevert();
        nft.ownerOf(nftId);
    }

    function test_RevertWhen_DepositIsBelowMinimum() public {
        usdc.mint(alice, 2_499e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 2_499e6);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.BelowMinDeposit.selector, 2_499e6));
        vault.deposit(address(usdc), 2_499e6, 1, 0, "", 0);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositTokenIsNotListed() public {
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.DepositTokenNotAllowed.selector, address(0xBEEF)));
        vm.prank(alice);
        vault.deposit(address(0xBEEF), 1e18, 1, 0, "", 0);
    }

    function test_RevertWhen_DepositNativeValueMismatches() public {
        vm.deal(alice, 1e18);
        vm.startPrank(alice);
        vm.expectRevert(ITuoVault.NativeAmountMismatch.selector);
        vault.deposit{value: 0.5e18}(address(0), 1e18, 1, 0, "", 0);

        // ...and stray value on an ERC-20 deposit is rejected too.
        usdc.mint(alice, 5_000e6);
        usdc.approve(address(vault), 5_000e6);
        vm.expectRevert(ITuoVault.NativeAmountMismatch.selector);
        vault.deposit{value: 0.5e18}(address(usdc), 5_000e6, 1, 0, "", 0);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositAmountIsZero() public {
        vm.expectRevert(ITuoVault.ZeroAmount.selector);
        vm.prank(alice);
        vault.deposit(address(usdc), 0, 1, 0, "", 0);
    }

    function test_RevertWhen_DepositProductCodeIsInvalid() public {
        usdc.mint(alice, 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 5_000e6);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.InvalidProductCode.selector, 3));
        vault.deposit(address(usdc), 5_000e6, 3, 0, "", 0);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositWhilePaused() public {
        vm.prank(pauser);
        vault.pauseDeposits();

        usdc.mint(alice, 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 5_000e6);
        vm.expectRevert(ITuoVault.DepositsArePaused.selector);
        vault.deposit(address(usdc), 5_000e6, 1, 0, "", 0);
        vm.stopPrank();

        vm.prank(pauser);
        vault.unpauseDeposits();
        _depositUsdc(alice, 5_000e6); // works again
    }

    // -------------------------------------------------------------------- cap

    /// @dev The per-NFT cap is the whole deposit-cap surface: the vault keeps no aggregate
    ///      total, so nothing bounds the number of capped positions that may be opened.
    function test_DepositEnforcesPerNftCap() public {
        usdc.mint(alice, PER_NFT_CAP + 1e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), PER_NFT_CAP + 1e6);
        vm.expectRevert(ITuoVault.PerNftCapExceeded.selector);
        vault.deposit(address(usdc), PER_NFT_CAP + 1e6, 1, 0, "", 0);
        vm.stopPrank();
    }

    /// @dev The top-up branch enforces the cap against the ACCUMULATED basis, which is the
    ///      half a single oversized deposit cannot reach: without it a position could be
    ///      grown past the cap 2,500e6 at a time.
    function test_RevertWhen_TopUpExceedsPerNftCap() public {
        uint256 nftId = _depositUsdc(alice, PER_NFT_CAP);

        usdc.mint(alice, TuoConstants.MIN_DEPOSIT_USDC);
        vm.startPrank(alice);
        usdc.approve(address(vault), TuoConstants.MIN_DEPOSIT_USDC);
        vm.expectRevert(ITuoVault.PerNftCapExceeded.selector);
        vault.deposit(address(usdc), TuoConstants.MIN_DEPOSIT_USDC, 0, 0, "", nftId);
        vm.stopPrank();

        assertEq(vault.getPosition(nftId).basisUsdc, PER_NFT_CAP);
    }

    /// @dev The cap is per position and nothing else. Ten capped positions total 250,000e6,
    ///      the figure the deleted global cap used to stop at; the eleventh is refused
    ///      nothing, which is the behaviour change this suite exists to pin.
    function test_DepositsAreNotBoundedInAggregate() public {
        uint256 total;
        for (uint256 i = 0; i < 5; i++) {
            total += vault.getPosition(_depositUsdc(alice, PER_NFT_CAP)).basisUsdc;
            total += vault.getPosition(_depositUsdc(bob, PER_NFT_CAP)).basisUsdc;
        }
        assertEq(total, 250_000e6);

        uint256 nftId = _depositUsdc(mallory, PER_NFT_CAP);
        assertEq(nftId, 11);
        assertEq(vault.getPosition(nftId).basisUsdc, PER_NFT_CAP);
    }

    // ----------------------------------------------------------------- top-up

    function test_TopUpIncreasesBasis() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);

        usdc.mint(alice, 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 5_000e6);
        vm.expectEmit(address(vault));
        emit ITuoVault.PositionToppedUp(nftId, address(usdc), 5_000e6, 5_000e6, 15_000e6);
        vault.deposit(address(usdc), 5_000e6, 0, 0, "", nftId);
        vm.stopPrank();

        assertEq(vault.getPosition(nftId).basisUsdc, 15_000e6);
        assertEq(vault.idleBalance(nftId, address(usdc)), 15_000e6);
    }

    function test_RevertWhen_TopUpCallerIsNotOwner() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        usdc.mint(bob, 5_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 5_000e6);
        vm.expectRevert(ITuoVault.NotPositionOwner.selector);
        vault.deposit(address(usdc), 5_000e6, 0, 0, "", nftId);
        vm.stopPrank();
    }

    function test_RevertWhen_TopUpProductCodeMismatches() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6); // product 1
        usdc.mint(alice, 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 5_000e6);
        vm.expectRevert(ITuoVault.ProductCodeMismatch.selector);
        vault.deposit(address(usdc), 5_000e6, 2, 0, "", nftId);
        vm.stopPrank();
    }

    function test_RevertWhen_TopUpDuringWithdrawalRequest() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 5_000);

        usdc.mint(alice, 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 5_000e6);
        vm.expectRevert(ITuoVault.WithdrawalRequestPending.selector);
        vault.deposit(address(usdc), 5_000e6, 0, 0, "", nftId);
        vm.stopPrank();
    }

    function test_RevertWhen_TopUpPositionIsUnknown() public {
        usdc.mint(alice, 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 5_000e6);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.UnknownPosition.selector, 99));
        vault.deposit(address(usdc), 5_000e6, 0, 0, "", 99);
        vm.stopPrank();
    }

    // ------------------------------------------------------ treasury controls

    function test_SetPerNftCapIsTreasuryOnly() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, mallory, keccak256("TREASURY_ROLE")
            )
        );
        vm.prank(mallory);
        vault.setPerNftCap(1e6);

        vm.expectEmit(address(vault));
        emit ITuoVault.PerNftCapUpdated(50_000e6);
        vm.prank(treasury);
        vault.setPerNftCap(50_000e6);
        assertEq(vault.perNftCapUsdc(), 50_000e6);
    }

    /// @dev Zero is the one argument the setter refuses. There is deliberately no upper
    ///      bound: the treasury Safe that would raise the cap is the same one that can
    ///      revoke KEEPER_ROLE, so a ceiling it could lift itself bought nothing.
    function test_RevertWhen_SetPerNftCapIsZero() public {
        vm.prank(treasury);
        vm.expectRevert(ITuoVault.InvalidCap.selector);
        vault.setPerNftCap(0);
    }

    function testFuzz_SetPerNftCapAcceptsAnyNonZeroValue(uint256 newCap) public {
        newCap = bound(newCap, 1, type(uint256).max);
        vm.prank(treasury);
        vault.setPerNftCap(newCap);
        assertEq(vault.perNftCapUsdc(), newCap);
    }

    function test_SetFeeRecipientIsTreasuryOnlyAndRejectsZero() public {
        vm.prank(treasury);
        vm.expectRevert(ITuoVault.ZeroAddress.selector);
        vault.setFeeRecipient(address(0));

        vm.expectEmit(address(vault));
        emit ITuoVault.FeeRecipientUpdated(bob);
        vm.prank(treasury);
        vault.setFeeRecipient(bob);
        assertEq(vault.feeRecipient(), bob);
    }

    /// @dev All three protocol-owned contracts are dead ends for a fee sweep: {_claimFees}
    ///      clears the attribution before it pays, so the vault as recipient drops the fee
    ///      out of `accruedTokenFees` without moving a token, and neither the NFT nor the
    ///      router has a call that sends an ERC-20 back out.
    function test_RevertWhen_SetFeeRecipientIsProtocolOwned() public {
        address[3] memory sinks = [address(vault), address(nft), address(router)];
        for (uint256 i = 0; i < sinks.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(ITuoVault.ProtocolOwnedAddress.selector, sinks[i]));
            vm.prank(treasury);
            vault.setFeeRecipient(sinks[i]);
        }
    }

    function test_RevertWhen_PauseCallerIsNotPauser() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, mallory, keccak256("PAUSER_ROLE")
            )
        );
        vm.prank(mallory);
        vault.pauseDeposits();
    }
}
