// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ITuoPositionNFT} from "../../src/interfaces/ITuoPositionNFT.sol";
import {ITuoVault} from "../../src/interfaces/ITuoVault.sol";
import {TuoConstants} from "../../src/libraries/TuoConstants.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev The claim lifecycle after an emergency exit with margin outstanding. The exit used to
///      book the claim at par, close it the moment returns reached par and charge the fee
///      against a basis reduced by margin that had not come back. A profitable hedge could
///      not return above par, a losing one left an unburnable NFT, and a position that lost
///      overall could still pay a fee. The claim now retains the basis, the exit NAV and the
///      fee charged, accepts any return, charges once on cumulative realized value, and is
///      closed only by the owner.
contract TuoVaultClaimTest is VaultTestBase {
    uint256 internal constant BASIS = 10_000e6;

    /// @dev Open a position, bridge `bridged`, and take the emergency exit.
    function _exitWithClaim(uint256 bridged) internal returns (uint256 nftId) {
        nftId = _depositUsdc(alice, BASIS);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, bridged, hlOperator);
        _exit(nftId);
    }

    function _exit(uint256 nftId) internal {
        vm.prank(alice);
        vault.requestWithdraw(nftId, TuoConstants.BPS_DENOMINATOR);
        vm.warp(block.timestamp + TuoConstants.EMERGENCY_WITHDRAW_DELAY);
        vm.prank(alice);
        vault.emergencyWithdraw(nftId);
    }

    function _settle(uint256 nftId, uint256 amount) internal {
        vm.prank(keeper);
        vault.settleHlClaim(nftId, amount);
    }

    function _claimFee(uint256 realized) internal pure returns (uint256) {
        if (realized <= BASIS) return 0;
        return ((realized - BASIS) * TuoConstants.PERFORMANCE_FEE_BPS) / TuoConstants.BPS_DENOMINATOR;
    }

    function _assertNoNft(uint256 nftId) internal {
        vm.expectRevert();
        nft.ownerOf(nftId);
    }

    // ------------------------------------------------------------- the exit books

    function test_EmergencyExitRetainsTheClaimAccounting() public {
        uint256 nftId = _depositUsdc(alice, BASIS);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);
        _keeperSwapToWeth(nftId, 6_000e6, 13_000e6);
        _exit(nftId);

        // 13,000 of on-chain value against the FULL 10,000 basis is 3,000 of certain profit.
        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertFalse(p.active);
        assertEq(p.basisUsdc, BASIS, "basis retained while the claim is open");
        assertEq(p.hlClaimUsdc, 4_000e6, "claim booked at the bridged principal");
        assertEq(p.hlClaimReturnedUsdc, 0);
        assertEq(p.hlClaimExitNavUsdc, 13_000e6, "the NAV the exit was valued at");
        assertEq(p.hlClaimFeeChargedUsdc, 900e6, "30% of the certain profit, recorded nominally");
        assertEq(vault.accruedTokenFees(address(weth)), 900e6, "withheld in kind");
        assertEq(weth.balanceOf(alice), 12_100e6);
    }

    // ---------------------------------------------------------- returns and fees

    /// @dev A hedge that made money returns more than it was sent, and the whole return
    ///      reaches the owner net of the fee on the profit it realizes.
    function test_SettleHlClaimPaysAReturnAbovePrincipal() public {
        uint256 nftId = _exitWithClaim(4_000e6);
        usdc.mint(hlOperator, 300e6);
        assertEq(usdc.balanceOf(alice), 6_000e6, "on-chain leg paid at the exit");

        // Realized 6,000 + 4,300 = 10,300 against a 10,000 basis: 90 of fee on 300 of profit.
        vm.expectEmit(address(vault));
        emit ITuoVault.HlClaimSettled(nftId, 4_300e6, 90e6, 4_210e6);
        _settle(nftId, 4_300e6);

        assertEq(usdc.balanceOf(alice), 10_210e6, "principal and gain, net of the fee");
        assertEq(vault.accruedFeesUsdc(), 90e6);
        assertEq(usdc.balanceOf(hlOperator), 0, "nothing stranded at the operator");
        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertEq(p.hlClaimReturnedUsdc, 4_300e6);
        assertEq(p.hlClaimFeeChargedUsdc, 90e6);
        assertEq(p.hlClaimUsdc, 4_000e6, "the claim stays open above par");
        assertEq(nft.ownerOf(nftId), alice, "only the owner closes it");
    }

    /// @dev Each return is charged the fee owed on cumulative realized value less what was
    ///      already charged, so the lifecycle charges exactly once however the hedge result
    ///      arrives.
    function test_SettleHlClaimChargesTheFeeOnceOnCumulativeRealizedValue() public {
        uint256 nftId = _depositUsdc(alice, BASIS);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 5_000e6, hlOperator);
        _keeperSwapToWeth(nftId, 5_000e6, 6_000e6);
        _exit(nftId);
        assertEq(vault.accruedTokenFees(address(weth)), 0, "6,000 against 10,000 is no certain profit");

        // Realized 8,000: still under basis, nothing charged.
        vm.expectEmit(address(vault));
        emit ITuoVault.HlClaimSettled(nftId, 2_000e6, 0, 2_000e6);
        _settle(nftId, 2_000e6);

        // Realized 11,500: 1,500 of profit, 450 of fee, all of it on this return.
        usdc.mint(hlOperator, 500e6);
        vm.expectEmit(address(vault));
        emit ITuoVault.HlClaimSettled(nftId, 3_500e6, 450e6, 3_050e6);
        _settle(nftId, 3_500e6);

        // Realized 12,000: 600 owed, 450 already charged, 150 on this return.
        usdc.mint(hlOperator, 500e6);
        vm.expectEmit(address(vault));
        emit ITuoVault.HlClaimSettled(nftId, 500e6, 150e6, 350e6);
        _settle(nftId, 500e6);

        assertEq(vault.accruedFeesUsdc(), 600e6, "30% of the 2,000 lifetime profit, once");
        assertEq(usdc.balanceOf(alice), 2_000e6 + 3_050e6 + 350e6);
        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertEq(p.hlClaimReturnedUsdc, 6_000e6);
        assertEq(p.hlClaimFeeChargedUsdc, 600e6);
    }

    function test_SettleHlClaimTopsUpAnExitFeeAlreadyCharged() public {
        uint256 nftId = _depositUsdc(alice, BASIS);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);
        _keeperSwapToWeth(nftId, 6_000e6, 13_000e6);
        _exit(nftId);
        assertEq(vault.getPosition(nftId).hlClaimFeeChargedUsdc, 900e6);

        // Realized 17,000: 2,100 owed, 900 charged at the exit, 1,200 on this return.
        vm.expectEmit(address(vault));
        emit ITuoVault.HlClaimSettled(nftId, 4_000e6, 1_200e6, 2_800e6);
        _settle(nftId, 4_000e6);

        assertEq(vault.accruedFeesUsdc(), 1_200e6);
        assertEq(vault.accruedTokenFees(address(weth)), 900e6, "the in-kind exit fee stands");
        assertEq(vault.getPosition(nftId).hlClaimFeeChargedUsdc, 2_100e6);
    }

    /// @dev The headline case: the on-chain leg appreciates by exactly the move the hedge
    ///      exists to offset, the hedge loses more than that, and the position finishes at a
    ///      loss. No fee is charged at any point.
    function test_LosingHedgeLargerThanOnchainGainPaysNoFee() public {
        uint256 nftId = _depositUsdc(alice, BASIS);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 5_000e6, hlOperator);
        usdc.burn(hlOperator, 3_000e6); // the venue kept it
        _keeperSwapToWeth(nftId, 5_000e6, 6_000e6);
        _exit(nftId);

        _settle(nftId, 2_000e6);

        uint256 lifetimeReturned = weth.balanceOf(alice) + usdc.balanceOf(alice);
        assertEq(lifetimeReturned, 8_000e6, "8,000 returned against a 10,000 deposit");
        assertEq(vault.accruedFeesUsdc(), 0, "no fee on a loss");
        assertEq(vault.accruedTokenFees(address(weth)), 0, "no fee on a loss");

        vm.expectEmit(address(vault));
        emit ITuoVault.HlClaimFinalized(nftId, 3_000e6);
        vm.prank(alice);
        vault.finalizeHlClaim(nftId);
        _assertNoNft(nftId);
    }

    /// @dev The same total return charges the same total fee whether it lands in one leg or
    ///      two, because every return only tops the charged figure up to what is owed on the
    ///      value realized so far.
    function testFuzz_ClaimFeeIsPathIndependent(uint256 wethOut, uint256 total, uint256 split) public {
        // The whole on-chain leg is the WETH the swap returns, anywhere from the keeper's
        // loss floor to a 4x gain, so the exit books anything from no fee to a large one;
        // the returns go down to one unit.
        wethOut = bound(wethOut, 4_985e6, 20_000e6);
        total = bound(total, 1, 20_000e6);
        split = bound(split, 1, total);
        uint256 nftId = _depositUsdc(alice, BASIS);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 5_000e6, hlOperator);
        _keeperSwapToWeth(nftId, 5_000e6, wethOut);
        _exit(nftId);
        uint256 exitNav = wethOut;
        uint256 exitFee = _claimFee(exitNav);
        assertEq(vault.getPosition(nftId).hlClaimFeeChargedUsdc, exitFee);
        usdc.mint(hlOperator, total);

        _settleAuditingTheFee(nftId, split);
        if (split < total) _settleAuditingTheFee(nftId, total - split);

        uint256 lifetimeFee = _claimFee(exitNav + total);
        assertEq(vault.accruedFeesUsdc(), lifetimeFee - exitFee, "fee is a function of the total, not the path");
        assertEq(vault.getPosition(nftId).hlClaimFeeChargedUsdc, lifetimeFee);
        assertEq(usdc.balanceOf(alice), total - (lifetimeFee - exitFee), "the owner gets the rest");
    }

    /// @dev One return, with the bound the design rests on asserted: the fee on a return is
    ///      at most 30% of it, so the net never underflows however large the exit fee was.
    function _settleAuditingTheFee(uint256 nftId, uint256 amount) internal {
        uint256 feesBefore = vault.accruedFeesUsdc();
        _settle(nftId, amount);
        uint256 fee = vault.accruedFeesUsdc() - feesBefore;
        assertLe(
            fee * TuoConstants.BPS_DENOMINATOR, amount * TuoConstants.PERFORMANCE_FEE_BPS + TuoConstants.BPS_DENOMINATOR
        );
        assertLe(fee, amount);
    }

    /// @dev The exit forgoes its fee when no pool can be priced, and it records a zero exit
    ///      NAV rather than a fabricated one. Later returns are then charged only above the
    ///      full basis: the on-chain leg paid fee-free is never counted, so the lifecycle can
    ///      undercharge but never overcharge.
    function test_SettleHlClaimAfterAnOracleThatCouldNotAnswer() public {
        uint256 nftId = _depositUsdc(alice, BASIS);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);
        _keeperSwapToWeth(nftId, 6_000e6, 13_000e6);
        wethPool.setOracleBricked(true);
        _exit(nftId);
        assertEq(weth.balanceOf(alice), 13_000e6, "every token returned, no fee");
        assertEq(vault.getPosition(nftId).hlClaimExitNavUsdc, 0);

        _settle(nftId, 4_000e6);
        assertEq(vault.accruedFeesUsdc(), 0, "4,000 realized against 10,000 of basis");

        usdc.mint(hlOperator, 7_000e6);
        _settle(nftId, 7_000e6);
        assertEq(vault.accruedFeesUsdc(), 300e6, "11,000 realized: charged on the 1,000 above basis only");
    }

    function test_SettleHlClaimRoutesThroughTheVault() public {
        uint256 nftId = _exitWithClaim(4_000e6);
        usdc.mint(hlOperator, 1_000e6);
        assertEq(usdc.balanceOf(address(vault)), 0);

        _settle(nftId, 5_000e6);

        // 11,000 realized: 300 of fee stays in the vault as the accrued pool, the rest left
        // for the owner in the same call.
        assertEq(usdc.balanceOf(address(vault)), 300e6);
        assertEq(vault.accruedFeesUsdc(), 300e6, "the vault holds exactly the fee it accrued");
        assertEq(usdc.balanceOf(alice), 6_000e6 + 4_700e6);
        assertEq(_claimFees(), 300e6);
    }

    function test_SettleHlClaimPartialThenParKeepsTheNft() public {
        uint256 nftId = _exitWithClaim(4_000e6);

        _settle(nftId, 1_500e6);
        assertEq(usdc.balanceOf(alice), 7_500e6);
        _settle(nftId, 2_500e6);
        assertEq(usdc.balanceOf(alice), 10_000e6, "principal fully recovered");

        // Par is not a terminal state any more: the hedge may still owe a profit leg, and
        // the vault cannot tell, so the ticket stays open until the owner says otherwise.
        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertEq(p.hlClaimUsdc, 4_000e6);
        assertEq(p.hlClaimReturnedUsdc, 4_000e6);
        assertEq(nft.ownerOf(nftId), alice, "NFT survives at par");
    }

    function test_SettleHlClaimPaysCurrentNftOwner() public {
        uint256 nftId = _exitWithClaim(4_000e6);
        vm.prank(alice);
        nft.transferFrom(alice, bob, nftId);

        _settle(nftId, 4_000e6);
        assertEq(usdc.balanceOf(bob), 4_000e6, "the claim follows the NFT");
    }

    /// @dev The claim pays `ownerOf`, and the vault answers the ERC-721 receiver hook for the
    ///      Uniswap LPs it holds, so a position parked at the vault used to settle into the
    ///      vault's own balance: booked as neither idle nor fee, and unreachable afterwards
    ///      because every way out of a claim is owner-only. The token refuses the vault.
    function test_ClaimedPositionRefusesTheVaultAndSettlesToItsOwner() public {
        uint256 nftId = _exitWithClaim(4_000e6);
        bytes memory expected = abi.encodeWithSelector(ITuoPositionNFT.InvalidRecipient.selector, address(vault));

        vm.startPrank(alice);
        vm.expectRevert(expected);
        nft.safeTransferFrom(alice, address(vault), nftId);
        vm.expectRevert(expected);
        nft.transferFrom(alice, address(vault), nftId);
        vm.stopPrank();
        assertEq(nft.ownerOf(nftId), alice, "the claim keeps a bearer that can act on it");

        _settle(nftId, 4_000e6);
        assertEq(usdc.balanceOf(alice), BASIS, "the claim settles to a real owner");
    }

    // ------------------------------------------------------------- finalization

    /// @dev A losing hedge returns less than it was sent and the operator cannot fund the
    ///      rest. The owner closes the claim on what came back; the shortfall is written off
    ///      by the owner, and only the owner.
    function test_FinalizeHlClaimClosesAShortfallAndBurns() public {
        uint256 nftId = _depositUsdc(alice, 25_000e6);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 10_000e6, hlOperator);
        usdc.burn(hlOperator, 4_000e6); // the venue kept it
        _exit(nftId);
        assertEq(usdc.balanceOf(alice), 15_000e6);

        _settle(nftId, 6_000e6);
        assertEq(nft.ownerOf(nftId), alice, "NFT survives while the claim is open");
        vm.expectRevert();
        _settle(nftId, 4_000e6);
        vm.prank(keeper);
        vm.expectRevert(ITuoVault.PositionNotActive.selector);
        vault.markBridgeInboundComplete(nftId, 0, true);

        vm.expectEmit(address(vault));
        emit ITuoVault.HlClaimFinalized(nftId, 4_000e6);
        vm.expectEmit(address(vault));
        emit ITuoVault.PositionBurned(nftId);
        vm.prank(alice);
        vault.finalizeHlClaim(nftId);

        _assertNoNft(nftId);
        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertEq(p.basisUsdc, 0);
        assertEq(p.hlClaimUsdc, 0);
        assertEq(p.hlClaimReturnedUsdc, 0);
        assertEq(p.hlClaimExitNavUsdc, 0);
        assertEq(p.hlClaimFeeChargedUsdc, 0);
        assertEq(usdc.balanceOf(alice), 21_000e6, "what came back is what the owner keeps");
    }

    function test_FinalizeHlClaimAtParBurnsWithZeroShortfall() public {
        uint256 nftId = _exitWithClaim(4_000e6);
        _settle(nftId, 4_000e6);

        vm.expectEmit(address(vault));
        emit ITuoVault.HlClaimFinalized(nftId, 0);
        vm.prank(alice);
        vault.finalizeHlClaim(nftId);
        _assertNoNft(nftId);
    }

    function test_FinalizeHlClaimWithNothingReturned() public {
        uint256 nftId = _exitWithClaim(4_000e6);
        usdc.burn(hlOperator, 4_000e6); // the venue kept it

        vm.expectEmit(address(vault));
        emit ITuoVault.HlClaimFinalized(nftId, 4_000e6);
        vm.prank(alice);
        vault.finalizeHlClaim(nftId);
        _assertNoNft(nftId);
    }

    function test_FinalizeHlClaimFollowsTheNft() public {
        uint256 nftId = _exitWithClaim(4_000e6);
        vm.prank(alice);
        nft.transferFrom(alice, bob, nftId);

        vm.prank(alice);
        vm.expectRevert(ITuoVault.NotPositionOwner.selector);
        vault.finalizeHlClaim(nftId);

        vm.prank(bob);
        vault.finalizeHlClaim(nftId);
        _assertNoNft(nftId);
    }

    function test_RevertWhen_FinalizeHlClaimCallerIsNotOwner() public {
        uint256 nftId = _exitWithClaim(4_000e6);

        vm.prank(mallory);
        vm.expectRevert(ITuoVault.NotPositionOwner.selector);
        vault.finalizeHlClaim(nftId);

        // The keeper in particular: a write-off is the owner's decision, never Tuo's.
        vm.prank(keeper);
        vm.expectRevert(ITuoVault.NotPositionOwner.selector);
        vault.finalizeHlClaim(nftId);

        assertEq(nft.ownerOf(nftId), alice);
    }

    function test_RevertWhen_FinalizeHlClaimHasNoClaim() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.UnknownPosition.selector, uint256(99)));
        vault.finalizeHlClaim(99);

        uint256 live = _depositUsdc(alice, BASIS);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.NoClaim.selector, live));
        vault.finalizeHlClaim(live);

        uint256 nftId = _exitWithClaim(4_000e6);
        vm.startPrank(alice);
        vault.finalizeHlClaim(nftId);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.NoClaim.selector, nftId));
        vault.finalizeHlClaim(nftId);
        vm.stopPrank();
    }

    // ------------------------------------------------- the zero-principal claim

    /// @dev Bridge, take a NON-final return that repays the whole nominal, then exit. The
    ///      venue is unfinished, so the exit opens a claim whose principal is zero.
    function _exitWithCoveredMargin(uint256 bridged) internal returns (uint256 nftId) {
        nftId = _depositUsdc(alice, BASIS);
        vm.startPrank(keeper);
        vault.bridgeToHl(nftId, bridged, hlOperator);
        vault.markBridgeInboundComplete(nftId, bridged, false);
        vm.stopPrank();
        _exit(nftId);
    }

    /// @dev The claim is keyed on the open lifecycle, not on a nonzero principal, so the rest
    ///      of the hedge is payable, and the fee on it is still the one formula: 30% of
    ///      cumulative realized value over the retained basis.
    function test_ZeroPrincipalClaimSettlesLateProceedsAtTheCumulativeFee() public {
        uint256 nftId = _exitWithCoveredMargin(4_000e6);
        assertEq(usdc.balanceOf(alice), BASIS, "the exit paid the whole on-chain side, fee-free");

        usdc.mint(hlOperator, 300e6);
        vm.expectEmit(address(vault));
        emit ITuoVault.HlClaimSettled(nftId, 300e6, 90e6, 210e6);
        _settle(nftId, 300e6);

        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertEq(p.hlClaimUsdc, 0);
        assertEq(p.hlClaimReturnedUsdc, 300e6);
        assertEq(p.hlClaimFeeChargedUsdc, _claimFee(BASIS + 300e6));
        assertEq(usdc.balanceOf(alice), BASIS + 210e6);
        assertEq(nft.ownerOf(nftId), alice, "a return never closes the claim");
    }

    function test_FinalizeZeroPrincipalClaimBurnsWithZeroShortfall() public {
        uint256 nftId = _exitWithCoveredMargin(4_000e6);

        vm.expectEmit(address(vault));
        emit ITuoVault.HlClaimFinalized(nftId, 0);
        vm.prank(alice);
        vault.finalizeHlClaim(nftId);

        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertFalse(p.hlLifecycleOpen, "finalizing is the owner's way of closing the lifecycle");
        assertEq(p.basisUsdc, 0);
        _assertNoNft(nftId);
    }

    function test_RevertWhen_SettleHlClaimAfterZeroPrincipalClaimFinalized() public {
        uint256 nftId = _exitWithCoveredMargin(4_000e6);
        vm.prank(alice);
        vault.finalizeHlClaim(nftId);

        usdc.mint(hlOperator, 300e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.NoClaim.selector, nftId));
        vault.settleHlClaim(nftId, 300e6);
    }

    function test_RevertWhen_SettleHlClaimAfterFinalization() public {
        uint256 nftId = _exitWithClaim(4_000e6);
        vm.prank(alice);
        vault.finalizeHlClaim(nftId);

        // Whatever is still at the operator stays with Tuo by the owner's explicit choice.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.NoClaim.selector, nftId));
        vault.settleHlClaim(nftId, 4_000e6);
    }
}
