// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ITuoVault} from "../../src/interfaces/ITuoVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev Hyperliquid finality is tracked apart from the nominal margin. A return that merely
///      reaches what was bridged used to zero `hlMarginBridged`, and that zero was the only
///      thing settlement consulted: the owner could burn the position while proceeds were
///      still at the venue, and every route a later return could arrive by closed behind the
///      burn. Only the keeper's explicit final return closes the lifecycle now.
contract TuoVaultHlLifecycleTest is VaultTestBase {
    uint256 internal constant BRIDGED = 6_000e6;

    uint256 internal nftId;

    function setUp() public override {
        super.setUp();
        nftId = _depositUsdc(alice, 20_000e6);
    }

    function _bridge(uint256 amount) internal {
        vm.prank(keeper);
        vault.bridgeToHl(nftId, amount, hlOperator);
    }

    function _return(uint256 amount, bool finalReturn) internal {
        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, amount, finalReturn);
    }

    function _request(uint16 sharesBps) internal {
        vm.prank(alice);
        vault.requestWithdraw(nftId, sharesBps);
    }

    function test_BridgeToHlOpensTheLifecycle() public {
        assertFalse(vault.getPosition(nftId).hlLifecycleOpen, "a position that never bridged has no lifecycle");

        _bridge(BRIDGED);
        assertTrue(vault.getPosition(nftId).hlLifecycleOpen, "the first bridge opens it");

        _bridge(1_000e6);
        assertTrue(vault.getPosition(nftId).hlLifecycleOpen, "a later bridge keeps it open");
    }

    function testFuzz_NonFinalReturnNeverClosesTheLifecycle(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e6);
        _bridge(BRIDGED);
        usdc.mint(hlOperator, amount);

        _return(amount, false);

        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertTrue(p.hlLifecycleOpen, "only a final return closes the lifecycle");
        assertEq(p.hlMarginBridged, amount >= BRIDGED ? 0 : BRIDGED - amount, "the nominal still decrements");
        vm.expectRevert(ITuoVault.HlMarginOutstanding.selector);
        vault.settlementNav(nftId);
    }

    /// @dev The leg is sized from the venue's PERP ledger alone, so it can deliver exactly the
    ///      nominal margin while a spot balance is still out. The keeper says so with
    ///      `finalReturn == false`, and the vault has to believe it.
    function test_NonFinalReturnCoveringTheMarginKeepsSettlementShut() public {
        _bridge(BRIDGED);
        _return(BRIDGED, false);

        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertEq(p.hlMarginBridged, 0, "the nominal is repaid");
        assertTrue(p.hlLifecycleOpen, "the venue is not finished");

        _request(10_000);
        vm.expectRevert(ITuoVault.HlMarginOutstanding.selector);
        vault.settlementNav(nftId);
        vm.expectRevert(ITuoVault.HlMarginOutstanding.selector);
        vault.previewWithdraw(nftId);
    }

    function test_ZeroAmountFinalReturnClosesACoveredLifecycle() public {
        _bridge(BRIDGED);
        _return(BRIDGED, false);
        _request(10_000);

        vm.expectEmit(true, false, false, true, address(vault));
        emit ITuoVault.HlBridgeInboundCompleted(nftId, 0, true);
        _return(0, true);

        assertFalse(vault.getPosition(nftId).hlLifecycleOpen, "the attestation closes it");
        assertEq(vault.settlementNav(nftId), 20_000e6);

        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");
        assertFalse(vault.getPosition(nftId).active);
    }

    function test_BridgeAfterAFinalReturnReopensTheLifecycle() public {
        _bridge(BRIDGED);
        _request(5_000);
        _return(BRIDGED, true);
        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");
        assertFalse(vault.getPosition(nftId).hlLifecycleOpen);

        // The partial exit cleared the request, so the keeper may hedge what is left.
        _bridge(2_000e6);

        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertTrue(p.hlLifecycleOpen, "a new bridge is a new lifecycle");
        assertEq(p.hlMarginBridged, 2_000e6);
        vm.expectRevert(ITuoVault.HlMarginOutstanding.selector);
        vault.settlementNav(nftId);
    }

    /// @dev A closed lifecycle does not close the inbound leg: value the venue releases late
    ///      still reaches a position that is alive to receive it.
    function test_LateReturnCreditsAnActivePositionAfterTheLifecycleClosed() public {
        _bridge(BRIDGED);
        _request(5_000);
        _return(BRIDGED, true);

        usdc.mint(hlOperator, 300e6);
        _return(300e6, false);

        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertFalse(p.hlLifecycleOpen, "a credit never reopens what a final return closed");
        assertEq(p.hlMarginBridged, 0);
        assertEq(vault.settlementNav(nftId), 20_300e6, "the late proceeds are the position's");
    }

    /// @dev Closing is the same attestation whether or not any nominal is left, so it keeps
    ///      the same precondition: without an armed request `bridgeToHl` is open, and the
    ///      keeper could close a lifecycle it is about to refill.
    function test_RevertWhen_FinalReturnOnCoveredMarginHasNoWithdrawalRequest() public {
        _bridge(BRIDGED);
        _return(BRIDGED, false);

        vm.expectRevert(ITuoVault.WithdrawalNotRequested.selector);
        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, 0, true);
    }

    /// @dev An open lifecycle is a claim only once the emergency exit has deactivated the
    ///      position. While it is active the ordinary inbound leg is the only way home, so
    ///      the claim leg cannot be used to pay the owner around settlement.
    function test_RevertWhen_SettleHlClaimTargetsAnActiveHedgedPosition() public {
        _bridge(BRIDGED);

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.NoClaim.selector, nftId));
        vm.prank(keeper);
        vault.settleHlClaim(nftId, 1_000e6);

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.NoClaim.selector, nftId));
        vm.prank(alice);
        vault.finalizeHlClaim(nftId);
    }
}
