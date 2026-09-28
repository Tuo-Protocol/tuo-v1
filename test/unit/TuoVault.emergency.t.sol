// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ITuoVault} from "../../src/interfaces/ITuoVault.sol";
import {TuoConstants} from "../../src/libraries/TuoConstants.sol";
import {PoolTwap} from "../../src/libraries/PoolTwap.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

contract TuoVaultEmergencyTest is VaultTestBase {
    function test_EmergencyLiquidPositionPaysOutImmediately() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);

        // No request, no delay: never bridged to HL.
        vm.expectEmit(address(vault));
        emit ITuoVault.EmergencyTokenPaid(nftId, address(usdc), 10_000e6);
        vm.expectEmit(address(vault));
        emit ITuoVault.EmergencyWithdrawn(nftId, 0, 0);
        vm.expectEmit(address(vault));
        emit ITuoVault.PositionBurned(nftId);
        vm.prank(alice);
        vault.emergencyWithdraw(nftId);

        assertEq(usdc.balanceOf(alice), 10_000e6);
        assertFalse(vault.getPosition(nftId).active);
        assertEq(vault.getPosition(nftId).basisUsdc, 0);
    }

    function test_EmergencyWithOpenLpsBurnsThemAndPaysInKind() public {
        uint256 nftId = _depositUsdc(alice, 20_000e6);
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        uint256 lpId = _keeperMintLp(nftId, 4_000e6, 3_000e6);
        npm.accrueFees(lpId, 10e6, 5e6);

        vm.prank(alice);
        vault.emergencyWithdraw(nftId);

        // Everything on-chain comes back in-kind (idle USDC + LP principal + accrued
        // fees) minus the performance fee: the 15 of LP fees are profit over the
        // 20,000 basis, so 30% x 15 = 4.5 goes to the treasury. The position holds both
        // legs when it exits, so the fee is withheld from both pro rata rather than taken
        // out of the USDC leg alone.
        uint256 feeUsdcLeg = vault.accruedFeesUsdc();
        uint256 feeWethLeg = vault.accruedTokenFees(address(weth));
        assertGt(feeUsdcLeg, 0, "USDC leg charged");
        assertGt(feeWethLeg, 0, "WETH leg charged");
        // At TWAP tick 0 the two tokens are 1:1 in raw units, so the legs sum to the USDC
        // fee bar one unit of flooring each, and flooring favours the owner.
        assertApproxEqAbs(feeUsdcLeg + feeWethLeg, 4.5e6, 2, "30% of realized on-chain profit");

        assertEq(
            usdc.balanceOf(alice) + weth.balanceOf(alice),
            20_000e6 + 15e6 - (feeUsdcLeg + feeWethLeg),
            "all on-chain value returned net of fee"
        );
        assertEq(vault.getPosition(nftId).lpTokenIds.length, 0, "LPs force-closed");
        assertEq(usdc.balanceOf(address(vault)), feeUsdcLeg, "only the unclaimed USDC fee remains");
        assertEq(weth.balanceOf(address(vault)), feeWethLeg, "only the unclaimed WETH fee remains");

        assertEq(_claimFees(), feeUsdcLeg);
        vm.prank(treasury);
        assertEq(vault.claimTokenFees(address(weth)), feeWethLeg, "in-kind fee is claimable too");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault fully drained for this position");
        assertEq(weth.balanceOf(address(vault)), 0);
    }

    function test_EmergencyWithHlMarginRequiresRequestAndDelay() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);

        // Without a withdrawal request: refused.
        vm.expectRevert(ITuoVault.WithdrawalNotRequested.selector);
        vm.prank(alice);
        vault.emergencyWithdraw(nftId);

        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        // Before the delay: refused.
        vm.expectRevert(ITuoVault.EmergencyDelayNotElapsed.selector);
        vm.prank(alice);
        vault.emergencyWithdraw(nftId);

        // After the delay: pays the on-chain side, records the HL claim, keeps the NFT.
        vm.warp(block.timestamp + TuoConstants.EMERGENCY_WITHDRAW_DELAY);
        vm.expectEmit(address(vault));
        emit ITuoVault.EmergencyWithdrawn(nftId, 0, 4_000e6);
        vm.prank(alice);
        vault.emergencyWithdraw(nftId);

        assertEq(usdc.balanceOf(alice), 6_000e6, "the on-chain side comes back immediately");
        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertFalse(p.active);
        assertEq(p.hlMarginBridged, 0, "margin converted to a claim, not dropped");
        assertEq(p.hlClaimUsdc, 4_000e6);
        assertEq(nft.ownerOf(nftId), alice, "NFT survives while the claim is open");

        // And the ticket is redeemable, which is the whole point of keeping the NFT: this
        // is the guaranteed door out of a position whose margin is still on another venue.
        vm.prank(keeper);
        vault.settleHlClaim(nftId, 4_000e6);
        assertEq(usdc.balanceOf(alice), 10_000e6, "principal fully recovered");
        assertEq(nft.ownerOf(nftId), alice, "par does not close the claim; the owner does");
        vm.prank(alice);
        vault.finalizeHlClaim(nftId);
        vm.expectRevert();
        nft.ownerOf(nftId);
    }

    /// @dev The request and the delay guard the venue, not the nominal figure: a non-final
    ///      return that repays `hlMarginBridged` leaves value at Hyperliquid, so the keeper
    ///      still gets its window to bring it home before the owner can force the exit.
    function test_RevertWhen_EmergencyWithCoveredMarginSkipsTheRequestOrTheDelay() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.startPrank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);
        vault.markBridgeInboundComplete(nftId, 4_000e6, false);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(ITuoVault.WithdrawalNotRequested.selector);
        vault.emergencyWithdraw(nftId);

        vault.requestWithdraw(nftId, 10_000);
        vm.warp(block.timestamp + TuoConstants.EMERGENCY_WITHDRAW_DELAY - 1);
        vm.expectRevert(ITuoVault.EmergencyDelayNotElapsed.selector);
        vault.emergencyWithdraw(nftId);
        vm.stopPrank();
    }

    /// @dev The exit that used to burn. With the nominal repaid and the venue unfinished, the
    ///      owner leaves with everything on-chain and keeps the NFT as a zero-principal claim,
    ///      so the rest of the hedge still has somewhere to land.
    function test_EmergencyWithOpenLifecycleAndZeroMarginKeepsTheNft() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.startPrank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);
        vault.markBridgeInboundComplete(nftId, 4_000e6, false);
        vm.stopPrank();

        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vm.warp(block.timestamp + TuoConstants.EMERGENCY_WITHDRAW_DELAY);
        vm.expectEmit(address(vault));
        emit ITuoVault.EmergencyWithdrawn(nftId, 0, 0);
        vm.prank(alice);
        vault.emergencyWithdraw(nftId);

        assertEq(usdc.balanceOf(alice), 10_000e6, "the on-chain side comes back in full");
        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertFalse(p.active);
        assertTrue(p.hlLifecycleOpen, "the claim is the open lifecycle, not the principal");
        assertEq(p.hlClaimUsdc, 0, "nothing nominal was left to convert");
        assertEq(p.basisUsdc, 10_000e6, "the basis is retained for the fee on later returns");
        assertEq(nft.ownerOf(nftId), alice, "NFT survives while the claim is open");
    }

    function test_EmergencyAfterFinalReturnBurnsImmediately() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, 4_000e6, true);

        // The lifecycle is closed, so there is nothing to wait for and nothing to claim.
        vm.expectEmit(address(vault));
        emit ITuoVault.PositionBurned(nftId);
        vm.prank(alice);
        vault.emergencyWithdraw(nftId);

        assertEq(usdc.balanceOf(alice), 10_000e6);
        assertEq(vault.getPosition(nftId).basisUsdc, 0);
    }

    function test_EmergencyWorksWhilePaused() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(pauser);
        vault.pauseDeposits();

        vm.prank(alice);
        vault.emergencyWithdraw(nftId);
        assertEq(usdc.balanceOf(alice), 10_000e6);
    }

    function test_EmergencyChargesFeeOnOnchainProfit() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        // Realize +3,000 profit on-chain via an HL round trip the keeper attested as final,
        // so the lifecycle is closed and the exit needs no delay.
        _hedgeRoundTrip(nftId, alice, 4_000e6, 7_000e6);

        vm.prank(alice);
        vault.emergencyWithdraw(nftId);

        // Fee = 30% x 3,000 = 900, in USDC; the rest in-kind.
        assertEq(vault.accruedFeesUsdc(), 900e6);
        assertEq(usdc.balanceOf(alice), 12_100e6);
        assertEq(_claimFees(), 900e6);
        assertEq(usdc.balanceOf(treasury), 900e6);
    }

    /// @dev The emergency door used to take its fee out of the USDC leg alone and clamp it
    ///      to whatever USDC happened to be idle. A position the keeper had rotated into a
    ///      pool token therefore exited paying nothing, which made this the cheaper door
    ///      and the 30% fee optional for anyone who noticed. The fee is now withheld in
    ///      kind, pro rata, from every leg the position holds.
    function test_EmergencyChargesFeeOnProfitHeldInAPoolToken() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        // Rotate the whole position into WETH at a profit: 10,000 of basis in, 13,000 of
        // TWAP value out. Nothing is left in the leg the fee used to be taken from.
        _keeperSwapToWeth(nftId, 10_000e6, 13_000e6);
        assertEq(vault.idleBalance(nftId, address(usdc)), 0, "no USDC left to take a fee from");

        vm.prank(alice);
        vault.emergencyWithdraw(nftId);

        // 3,000 of profit over a 10,000 basis is 900 of fee, withheld from the only leg
        // that holds any value.
        assertEq(vault.accruedFeesUsdc(), 0, "nothing owed in USDC");
        assertEq(vault.accruedTokenFees(address(weth)), 900e6, "fee withheld in kind");
        assertEq(weth.balanceOf(alice), 12_100e6, "owner keeps value net of the fee");
    }

    /// @dev The same door, hedged. The fee used to be charged against the basis net of the
    ///      margin still at Hyperliquid, on the premise that margin returns at par. A hedge
    ///      returns above or below par, so on-chain profit smaller than the bridged amount is
    ///      not certain yet: it is charged when the hedge leg comes home and the lifetime
    ///      result is known.
    function test_EmergencyDefersTheFeeWhileHedged() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);
        // 6,000 of basis stays on-chain; grow it to 8,000 of TWAP value.
        _keeperSwapToWeth(nftId, 6_000e6, 8_000e6);

        vm.prank(alice);
        vault.requestWithdraw(nftId, TuoConstants.BPS_DENOMINATOR);
        vm.warp(block.timestamp + TuoConstants.EMERGENCY_WITHDRAW_DELAY);
        vm.expectEmit(address(vault));
        emit ITuoVault.EmergencyWithdrawn(nftId, 0, 4_000e6);
        vm.prank(alice);
        vault.emergencyWithdraw(nftId);

        // 8,000 of value against the FULL 10,000 basis is no certain profit yet.
        assertEq(vault.accruedTokenFees(address(weth)), 0, "nothing certain to charge");
        assertEq(weth.balanceOf(alice), 8_000e6, "the whole on-chain leg in kind");
        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertEq(p.basisUsdc, 10_000e6, "basis retained for the claim");
        assertEq(p.hlClaimExitNavUsdc, 8_000e6);
        assertEq(p.hlClaimFeeChargedUsdc, 0);

        // The margin comes home at par: 12,000 realized, 2,000 of profit, 600 of fee.
        vm.prank(keeper);
        vault.settleHlClaim(nftId, 4_000e6);
        assertEq(vault.accruedFeesUsdc(), 600e6, "30% of the lifetime profit, once known");
        assertEq(usdc.balanceOf(alice), 3_400e6);
    }

    /// @dev The guaranteed exit must not depend on a price. `_closeLp` is already given a
    ///      zero floor so the unwind cannot be gated, but the fee computation used to read
    ///      every pool's 30-minute TWAP one line later - so a pool whose observation ring
    ///      could not span the window locked the position instead of releasing it.
    function test_EmergencyExitSurvivesAnOracleThatCannotAnswer() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        _keeperSwapToWeth(nftId, 10_000e6, 13_000e6);

        wethPool.setOracleBricked(true);
        vm.expectRevert();
        vault.settlementNav(nftId);

        vm.prank(alice);
        vault.emergencyWithdraw(nftId);

        // No price means no fee can be computed, so the exit is taken fee-free rather than
        // refused: forgoing the fee is the correct trade against locking a customer out.
        assertEq(vault.accruedTokenFees(address(weth)), 0, "no fee without a price");
        assertEq(weth.balanceOf(alice), 13_000e6, "every on-chain token returned");
        assertFalse(vault.getPosition(nftId).active);
    }

    /// @dev The fee's clock and the payout's clock are not the same one, and that is
    ///      disclosed rather than fixed. `_emergencyFee` values the position at each pool's
    ///      30-minute mean tick; `_payIdleInKind` hands over the tokens themselves, worth
    ///      whatever the market pays. After a fast fall the mean is still carrying the old
    ///      price, so the fee is 30% of profit that has already gone and the owner pays an
    ///      effective rate well above 30% on what they actually realize. Gating the read on
    ///      the deviation band was considered and rejected: a waived fee is purchasable with
    ///      one atomic displacement of the thinnest pool the position holds.
    function test_EmergencyFeeIsMeasuredAtTheMeanAndNotAtSpot() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        _keeperSwapToWeth(nftId, 10_000e6, 13_000e6);

        // Spot falls hard while the 30-minute mean still reads the pre-fall price. The pool
        // answers `observe` throughout, so the try/catch in `_emergencyFee` never fires.
        int24 spotTick = wethPool.token0() == address(weth) ? int24(-1_431) : int24(1_431);
        wethPool.setSpotTick(spotTick);
        uint256 spotValue = PoolTwap.quoteToUsdcAtTick(spotTick, address(weth), address(usdc), 13_000e6);
        assertLt(spotValue, 13_000e6, "the leg is worth less than the mean still says");

        vm.prank(alice);
        vault.emergencyWithdraw(nftId);

        // Unchanged by the fall: the same 900 the calm-market exit charges. This is the
        // property, and it is what makes the fee spot-independent in both directions.
        assertEq(vault.accruedTokenFees(address(weth)), 900e6, "30% of the mean-measured gain");
        assertEq(weth.balanceOf(alice), 12_100e6, "the owner keeps the rest of the leg");

        // What the withholding costs at the price the owner can actually sell at.
        uint256 feeAtSpot = PoolTwap.quoteToUsdcAtTick(spotTick, address(weth), address(usdc), 900e6);
        uint256 realProfit = spotValue - 10_000e6;
        assertGt(feeAtSpot, (realProfit * TuoConstants.PERFORMANCE_FEE_BPS) / TuoConstants.BPS_DENOMINATOR);
        assertGt(
            (feeAtSpot * TuoConstants.BPS_DENOMINATOR) / realProfit,
            TuoConstants.PERFORMANCE_FEE_BPS,
            "an effective rate above the documented 30%"
        );
    }

    /// @dev The same mismatch from the other side, at its limit. A mean that has not begun
    ///      to absorb a rise reads the position at exactly its basis, `_claimFee` takes its
    ///      zero branch, and an exit that is demonstrably profitable at the market price
    ///      pays nothing at all. The owner picks the block, so this direction is the one
    ///      they can wait for. Accepted: bounded by how far a 30-minute mean can lag, on a
    ///      path that is MEV-exposed by construction.
    function test_EmergencyFeeIsZeroWhileTheMeanHasNotAbsorbedARise() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        _keeperSwapToWeth(nftId, 10_000e6, 10_000e6);

        int24 spotTick = wethPool.token0() == address(weth) ? int24(100) : int24(-100);
        wethPool.setSpotTick(spotTick);

        vm.prank(alice);
        vault.emergencyWithdraw(nftId);

        assertEq(vault.accruedTokenFees(address(weth)), 0, "the mean still reads the basis");
        assertEq(weth.balanceOf(alice), 10_000e6, "the whole leg, fee-free");
        uint256 atSpot = PoolTwap.quoteToUsdcAtTick(spotTick, address(weth), address(usdc), 10_000e6);
        assertGt(atSpot, 10_000e6, "a profitable exit that paid no fee");
    }

    /// @dev The consequence the product's LP-count cap protects. `emergencyWithdraw` closes
    ///      every LP in one transaction and the removal is an O(n) scan, so an uncapped
    ///      array made the customer's guaranteed exit grow quadratically in whatever the
    ///      keeper minted. At the cap it has to stay far inside a sane gas envelope.
    function test_EmergencyExitStaysAffordableAtTheLpCap() public {
        uint256 nftId = _depositUsdc(alice, 24_000e6);
        _keeperSwapToWeth(nftId, 6_000e6, 6_000e6);
        for (uint256 i = 0; i < vault.productOf(1).maxLpCount; i++) {
            _keeperMintLp(nftId, 1_000e6, 1_000e6);
        }

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        vault.emergencyWithdraw(nftId);
        uint256 spent = gasBefore - gasleft();

        assertLt(spent, 2_000_000, "the exit must stay far inside Arbitrum's per-tx ceiling");
        assertEq(vault.getPosition(nftId).lpTokenIds.length, 0);
    }

    /// @dev The guaranteed exit must not be reachable only when Tuo's own fee address is
    ///      healthy. Circle's `FiatTokenV2_2` reverts on any transfer touching a
    ///      blacklisted account, so pushing the fee before paying the owner froze this path
    ///      too. Pull payment means a blacklisted treasury costs Tuo its revenue and the
    ///      customer nothing.
    function test_EmergencyWithdrawSurvivesAFeeRecipientThatCannotReceiveUsdc() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        _hedgeRoundTrip(nftId, alice, 4_000e6, 7_000e6);

        usdc.setBlacklisted(treasury, true);

        vm.prank(alice);
        vault.emergencyWithdraw(nftId);

        assertEq(usdc.balanceOf(alice), 12_100e6, "the guaranteed exit still runs");
        assertEq(vault.accruedFeesUsdc(), 900e6, "the fee waits in the vault");
        assertFalse(vault.getPosition(nftId).active);
    }

    function test_RevertWhen_EmergencyCallerIsNotOwner() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.expectRevert(ITuoVault.NotPositionOwner.selector);
        vm.prank(mallory);
        vault.emergencyWithdraw(nftId);
    }

    function test_RevertWhen_EmergencyCalledTwice() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vm.warp(block.timestamp + TuoConstants.EMERGENCY_WITHDRAW_DELAY);
        vm.startPrank(alice);
        vault.emergencyWithdraw(nftId);
        vm.expectRevert(ITuoVault.PositionNotActive.selector);
        vault.emergencyWithdraw(nftId);
        vm.stopPrank();
    }
}
