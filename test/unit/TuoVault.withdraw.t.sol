// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ITuoSwapRouter} from "../../src/interfaces/ITuoSwapRouter.sol";
import {FixedPoint128} from "@uniswap/v3-core/contracts/libraries/FixedPoint128.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";

import {ITuoVault} from "../../src/interfaces/ITuoVault.sol";
import {PoolTwap} from "../../src/libraries/PoolTwap.sol";
import {TuoConstants} from "../../src/libraries/TuoConstants.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

contract TuoVaultWithdrawTest is VaultTestBase {
    // --------------------------------------------------------------- requests

    function test_RequestWithdrawArmsTheRequest() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);

        vm.expectEmit(address(vault));
        emit ITuoVault.WithdrawalRequested(nftId, 10_000);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertEq(p.withdrawalRequestedAt, block.timestamp);
        assertEq(p.withdrawalSharesBps, 10_000);
    }

    /// @dev No readiness flag gates the exit any more. What holds a hedged position back
    ///      is the measured gate: settlement will not value margin held on another venue.
    function test_RequestWithdrawDeployedPositionAwaitsKeeper() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);

        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vm.expectRevert(ITuoVault.HlMarginOutstanding.selector);
        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");

        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, 4_000e6, true);
        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");
        assertEq(usdc.balanceOf(alice), 10_000e6);
    }

    function test_RevertWhen_RequestWithdrawSharesExceedFull() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.InvalidSharesBps.selector, 10_001));
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_001);
    }

    /// @dev A restated request overwrites in place and restarts the emergency clock,
    ///      which is exactly what cancel-then-request did before the two merged.
    function test_RequestWithdrawRestatesAPendingRequest() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.startPrank(alice);
        vault.requestWithdraw(nftId, 5_000);
        uint256 armedAt = block.timestamp;
        vm.warp(armedAt + 1 hours);
        vault.requestWithdraw(nftId, 10_000);
        vm.stopPrank();

        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertEq(p.withdrawalSharesBps, 10_000);
        assertEq(p.withdrawalRequestedAt, armedAt + 1 hours, "restating restarts the clock");
    }

    function test_RevertWhen_RequestWithdrawCallerIsNotOwner() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.expectRevert(ITuoVault.NotPositionOwner.selector);
        vm.prank(bob);
        vault.requestWithdraw(nftId, 10_000);
    }

    /// @dev Zero shares IS the cancellation; there is no second entry point for it.
    function test_RequestWithdrawZeroSharesCancels() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.startPrank(alice);
        vault.requestWithdraw(nftId, 5_000);
        vm.expectEmit(address(vault));
        emit ITuoVault.WithdrawalRequested(nftId, 0);
        vault.requestWithdraw(nftId, 0);
        vm.stopPrank();

        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertEq(p.withdrawalRequestedAt, 0);
        assertEq(p.withdrawalSharesBps, 0);

        // And the cancellation reopens what a pending request was blocking.
        vm.expectRevert(ITuoVault.WithdrawalNotRequested.selector);
        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);
    }

    function test_RequestWithdrawCancelIsIdempotent() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 0);
        assertEq(vault.getPosition(nftId).withdrawalRequestedAt, 0);
    }

    function test_RevertWhen_RequestWithdrawCancelCallerIsNotOwner() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 5_000);

        vm.expectRevert(ITuoVault.NotPositionOwner.selector);
        vm.prank(bob);
        vault.requestWithdraw(nftId, 0);
        assertEq(vault.getPosition(nftId).withdrawalSharesBps, 5_000, "a stranger cannot clear it");
    }

    // ------------------------------------------------------------ withdrawals

    function test_WithdrawFullWithoutProfitChargesNoFeeAndBurnsNft() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        vm.expectEmit(address(vault));
        emit ITuoVault.PositionBurned(nftId);
        vm.expectEmit(address(vault));
        emit ITuoVault.PositionWithdrawn(nftId, 10_000, 10_000e6, 0, 10_000e6, address(usdc), 10_000e6, 0);
        vm.prank(alice);
        uint256 out = vault.withdraw(nftId, address(usdc), 0, "");

        assertEq(out, 10_000e6);
        assertEq(usdc.balanceOf(alice), 10_000e6);
        assertEq(vault.getPosition(nftId).basisUsdc, 0);
        assertFalse(vault.getPosition(nftId).active);
        assertEq(vault.idleBalance(nftId, address(usdc)), 0);
    }

    function test_WithdrawFullWithProfitChargesFee() public {
        // Profit arrives as HL margin coming back larger than what was bridged:
        // bridge 4,000 out, 7,000 returns -> NAV 13,000 on a 10,000 basis.
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        _hedgeRoundTrip(nftId, alice, 4_000e6, 7_000e6); // margin is home, so settlement resolves

        vm.expectEmit(address(vault));
        emit ITuoVault.FeesAccrued(nftId, 900e6, 900e6);
        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");

        // Specification worked example: fee $900, net $12,100. The fee is accrued, not pushed.
        assertEq(usdc.balanceOf(alice), 12_100e6);
        assertEq(usdc.balanceOf(treasury), 0, "fees are pull-payment");
        assertEq(vault.accruedFeesUsdc(), 900e6);
        assertEq(_claimFees(), 900e6);
        assertEq(usdc.balanceOf(treasury), 900e6);
        assertEq(vault.accruedFeesUsdc(), 0);
    }

    function test_WithdrawPartialReducesBasisProRata() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 5_000);

        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");

        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertTrue(p.active, "partial exit keeps the position");
        assertEq(p.basisUsdc, 5_000e6);
        assertEq(p.withdrawalRequestedAt, 0, "request consumed");
        assertEq(usdc.balanceOf(alice), 5_000e6);
        assertEq(vault.idleBalance(nftId, address(usdc)), 5_000e6);
    }

    function test_RevertWhen_WithdrawHasNoRequest() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.expectRevert(ITuoVault.WithdrawalNotRequested.selector);
        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");
    }

    /// @dev Settlement is measured-only, so every NAV-reading path refuses to run while
    ///      margin sits on Hyperliquid. It replaces a keeper-attested snapshot that was
    ///      both fee-extractable and fund-destroying: with the Hyperliquid leg omitted from
    ///      settlement NAV, a 100% withdrawal was covered by idle USDC alone, so the
    ///      position deactivated and the NFT burned while `hlMarginBridged` was still
    ///      non-zero. The inbound and claim legs then reverted against a position that no
    ///      longer existed, and the customer's margin was permanently unrecoverable.
    function test_RevertWhen_WithdrawWhileHlMarginOutstanding() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 5_000);

        // Every settlement read is gated uniformly - including the one inside `withdraw`,
        // which is now what makes the exit unreachable while hedged.
        vm.expectRevert(ITuoVault.HlMarginOutstanding.selector);
        vault.settlementNav(nftId);
        vm.expectRevert(ITuoVault.HlMarginOutstanding.selector);
        vault.previewWithdraw(nftId);
        vm.expectRevert(ITuoVault.HlMarginOutstanding.selector);
        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");

        // The full-share case is the one that used to burn the NFT out from under the
        // margin, so it gets its own assertion that both survive.
        vm.startPrank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vm.expectRevert(ITuoVault.HlMarginOutstanding.selector);
        vault.withdraw(nftId, address(usdc), 0, "");
        vm.stopPrank();

        assertEq(nft.ownerOf(nftId), alice, "the NFT the margin pays back to must survive");
        assertEq(vault.getPosition(nftId).hlMarginBridged, 4_000e6, "and so must the margin ledger");
    }

    /// @dev A return leg is sized from the venue's PERP ledger, so it can repay exactly the
    ///      nominal margin while a spot balance is still out. The keeper reports that leg as
    ///      non-final, and a zeroed `hlMarginBridged` used to open the exit regardless: the
    ///      NFT burned and the rest of the hedge had no position or claim left to land on.
    function test_RevertWhen_WithdrawAfterNonFinalReturnCoversTheMargin() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.startPrank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);
        vault.markBridgeInboundComplete(nftId, 4_000e6, false);
        vm.stopPrank();
        assertEq(vault.getPosition(nftId).hlMarginBridged, 0, "the nominal is repaid");

        vm.startPrank(alice);
        vault.requestWithdraw(nftId, 5_000);
        vm.expectRevert(ITuoVault.HlMarginOutstanding.selector);
        vault.withdraw(nftId, address(usdc), 0, "");

        vault.requestWithdraw(nftId, 10_000);
        vm.expectRevert(ITuoVault.HlMarginOutstanding.selector);
        vault.withdraw(nftId, address(usdc), 0, "");
        vm.stopPrank();

        assertEq(nft.ownerOf(nftId), alice, "the NFT the rest of the hedge pays back to must survive");
        assertTrue(vault.getPosition(nftId).active);
    }

    /// @dev The same split return, carried to the end: the second leg lands on the live
    ///      position, the keeper attests it as final, and the owner is paid on all of it.
    function test_LateHedgeProceedsReachTheOwnerAfterACoveringReturn() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.startPrank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);
        vault.markBridgeInboundComplete(nftId, 4_000e6, false);
        vm.stopPrank();
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        usdc.mint(hlOperator, 300e6);
        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, 300e6, true);

        assertEq(vault.settlementNav(nftId), 10_300e6, "the hedge's profit is measured, not stranded");
        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");
        assertEq(usdc.balanceOf(alice), 10_210e6, "principal plus 70% of the 300 profit");
        assertEq(vault.accruedFeesUsdc(), 90e6, "and the protocol's fee on it is charged");
        assertEq(usdc.balanceOf(hlOperator), 0);
    }

    /// @dev The settle-then-withdraw happy path the gate above forces.
    function test_WithdrawAfterSettlingHlMargin() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 5_000);

        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, 4_000e6, true);

        assertEq(vault.settlementNav(nftId), 10_000e6, "margin is back on-chain, valued at cost");
        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");
        assertEq(usdc.balanceOf(alice), 5_000e6);
        assertEq(vault.getPosition(nftId).basisUsdc, 5_000e6);
    }

    function test_RevertWhen_WithdrawExceedsIdleBalance() public {
        // NAV counts the open LP, but gross exceeds what sits idle on-chain. A partial share,
        // because a full one stops at the LP gate before the idle check.
        uint256 nftId = _depositUsdc(alice, 20_000e6);
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        _keeperMintLp(nftId, 4_000e6, 3_000e6);

        vm.prank(alice);
        vault.requestWithdraw(nftId, 9_000);

        uint256 idleUsdc = vault.idleBalance(nftId, address(usdc));
        (uint256 gross,,) = vault.previewWithdraw(nftId);
        assertGt(gross, idleUsdc, "the LP leg is not liquid");
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.InsufficientIdle.selector, address(usdc), gross, idleUsdc));
        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");
    }

    /// @dev The idle-cover check is the whole gate now that no keeper flag stands in
    ///      front of it: a share the position can actually pay executes unassisted, and
    ///      the residual LP stays with the position, which the owner still holds.
    function test_WithdrawPartialSucceedsWithoutKeeperWhileAnLpIsOpen() public {
        uint256 nftId = _depositUsdc(alice, 20_000e6);
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        _keeperMintLp(nftId, 4_000e6, 3_000e6);

        vm.prank(alice);
        vault.requestWithdraw(nftId, 2_500);
        (uint256 gross,, uint256 net) = vault.previewWithdraw(nftId);
        assertLe(gross, vault.idleBalance(nftId, address(usdc)), "the quarter share is covered by idle USDC");

        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");

        assertEq(usdc.balanceOf(alice), net);
        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertTrue(p.active);
        assertEq(p.basisUsdc, 15_000e6, "basis reduced pro rata");
        assertEq(p.lpTokenIds.length, 1, "the LP leg is untouched and still the owner's");
    }

    /// @dev The pool credits fees to a range only when it is touched, so `tokensOwed` reads
    ///      zero for a range that has earned. Settlement has to see those fees anyway: a
    ///      valuation that cannot is not "conservative" on a partial exit, because the basis
    ///      retired does not depend on NAV while the payout does.
    function test_SettlementNavIsFlatAcrossABurnWithUncheckpointedFees() public {
        (uint256 nftId, uint256 lpId, uint256 feeUsdc) = _positionWithUncheckpointedFees();
        uint256 navLive = vault.settlementNav(nftId);

        vm.prank(keeper);
        vault.burnLp(nftId, lpId);

        assertApproxEqAbs(vault.settlementNav(nftId), navLive, 2, "the burn releases nothing NAV had not seen");
        assertGt(navLive, 20_000e6 + feeUsdc - 2, "the live valuation carries the fees");
    }

    /// @dev Branch A of Cyfrin issue 49 (the LP live) and branch B (the LP burned first) must
    ///      quote and pay the same partial exit, so the fee the straddle used to suppress is
    ///      charged on the exit that earned it, and never again against the reduced basis.
    function test_PartialWithdrawIsPricedOnUncheckpointedFees() public {
        (uint256 nftId, uint256 lpId,) = _positionWithUncheckpointedFees();
        vm.prank(alice);
        vault.requestWithdraw(nftId, 2_500);
        (uint256 grossLive, uint256 feeLive, uint256 netLive) = vault.previewWithdraw(nftId);

        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        vault.burnLp(nftId, lpId);
        (uint256 grossBurned, uint256 feeBurned,) = vault.previewWithdraw(nftId);
        vm.revertToState(snap);

        assertApproxEqAbs(grossLive, grossBurned, 2, "the exited share is priced the same either way");
        assertApproxEqAbs(feeLive, feeBurned, 2, "and so is the fee on it");
        assertGt(feeLive, 0, "the fees the LP earned are profit, and the quarter exit pays its share");

        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");
        assertEq(usdc.balanceOf(alice), netLive);
        assertEq(vault.getPosition(nftId).basisUsdc, 15_000e6, "basis reduced pro rata");
    }

    function test_WithdrawInAnotherTokenSwapsNet() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        vm.prank(alice);
        uint256 out =
            vault.withdraw(nftId, address(weth), 3e18, _swapData(address(usdc), address(weth), 10_000e6, 4e18));

        assertEq(out, 4e18);
        assertEq(weth.balanceOf(alice), 4e18);
        assertEq(usdc.balanceOf(alice), 0);
    }

    /// @dev The owner's `minTokenOut` of zero must not be the bound: at a 1:1 TWAP a route
    ///      paying 90% trips the vault's own 99.5% floor, as it does on the keeper's swaps.
    function test_RevertWhen_ExitSwapPaysBelowVaultFloorWithZeroMin() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        bytes memory swapData = _swapData(address(usdc), address(weth), 10_000e6, 9_000e6);
        vm.expectRevert(abi.encodeWithSelector(ITuoSwapRouter.SlippageExceeded.selector, 9_000e6, 9_950e6));
        vm.prank(alice);
        vault.withdraw(nftId, address(weth), 0, swapData);
    }

    /// @dev The exit floor protects an owner whose frontend passes `minTokenOut == 0`, so it
    ///      is compiled in and does not follow the keeper's tolerance: the treasury widening
    ///      that one to its ceiling leaves the token-elected exit exactly as tight, and the
    ///      USDC exit for the same request is unaffected by the drift.
    function test_ExitFloorStaysCompiledWhenTheKeeperToleranceWidens() public {
        uint256 nftId = _depositUsdc(alice, 20_000e6);
        vm.prank(treasury);
        vault.setKeeperSwapSlippageBps(TuoConstants.MAX_KEEPER_SWAP_SLIPPAGE_BPS);

        // 40 ticks with WBTC dear against USDC, so an honest buy returns fewer tokens than
        // the mean-tick quote the floor is derived from.
        int24 spotTick = wbtcPool.token0() == address(wbtc) ? int24(40) : int24(-40);
        wbtcPool.setSpotTick(spotTick);

        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);
        (,, uint256 netUsdc) = vault.previewWithdraw(nftId);

        uint256 spotOut = PoolTwap.quoteFromUsdcAtTick(spotTick, address(wbtc), address(usdc), netUsdc);
        uint256 honestFill = (spotOut * (10_000 - 12)) / 10_000;
        uint256 meanOut = PoolTwap.quoteFromUsdcAtTick(0, address(wbtc), address(usdc), netUsdc);
        uint256 exitFloor = _ceilBps(meanOut, 10_000 - TuoConstants.EXIT_FLOOR_BPS);
        assertLt(honestFill, exitFloor, "the best honest fill sits under the exit floor");

        bytes memory swapData = _swapData(address(usdc), address(wbtc), netUsdc, honestFill);
        vm.expectRevert(abi.encodeWithSelector(ITuoSwapRouter.SlippageExceeded.selector, honestFill, exitFloor));
        vm.prank(alice);
        vault.withdraw(nftId, address(wbtc), 0, swapData);

        vm.expectRevert(abi.encodeWithSelector(ITuoSwapRouter.SlippageExceeded.selector, honestFill, exitFloor));
        vm.prank(alice);
        vault.withdraw(nftId, address(wbtc), 1, swapData);

        vm.prank(alice);
        uint256 out = vault.withdraw(nftId, address(usdc), 0, "");
        assertEq(out, netUsdc);
        assertEq(usdc.balanceOf(alice), netUsdc);
    }

    /// @dev A deposit token with no allowlisted pool has no on-chain price, so the vault
    ///      cannot derive a floor for its exit swap and the caller's `minTokenOut` would be
    ///      the only bound - the one value a bad frontend controls. The token is entry-only.
    ///      An honest route and a nonzero minimum show the refusal is unconditional.
    function test_RevertWhen_WithdrawTokenHasNoValuationPool() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        bytes memory swapData = _swapData(address(usdc), address(dai), 10_000e6, 10_000e18);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.TokenNotAllowlisted.selector, address(dai)));
        vm.prank(alice);
        vault.withdraw(nftId, address(dai), 9_950e18, swapData);
    }

    /// @dev The refusal must cost the owner nothing: the burn and the basis write happen
    ///      before the exit swap, so the revert has to roll them back, and the USDC exit
    ///      has to stay open on the same request.
    function test_PoollessTokenWithdrawalLeavesUsdcExitOpen() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        bytes memory swapData = _swapData(address(usdc), address(dai), 10_000e6, 10_000e18);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.TokenNotAllowlisted.selector, address(dai)));
        vm.prank(alice);
        vault.withdraw(nftId, address(dai), 0, swapData);

        ITuoVault.PositionView memory p = vault.getPosition(nftId);
        assertTrue(p.active, "the position is still open");
        assertEq(p.withdrawalSharesBps, 10_000, "the request is still armed");
        assertEq(p.basisUsdc, 10_000e6, "the basis is untouched");
        assertEq(vault.idleBalance(nftId, address(usdc)), 10_000e6, "no USDC left the position");
        assertEq(nft.ownerOf(nftId), alice, "the NFT was not burned");

        vm.prank(alice);
        uint256 out = vault.withdraw(nftId, address(usdc), 0, "");

        assertEq(out, 10_000e6);
        assertEq(usdc.balanceOf(alice), 10_000e6);
        assertEq(dai.balanceOf(alice), 0);
    }

    function test_WithdrawByNftTransfereeOwnershipFollowsToken() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        vm.prank(alice);
        nft.transferFrom(alice, bob, nftId);

        vm.expectRevert(ITuoVault.NotPositionOwner.selector);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        vm.startPrank(bob);
        vault.requestWithdraw(nftId, 10_000);
        vault.withdraw(nftId, address(usdc), 0, "");
        vm.stopPrank();
        assertEq(usdc.balanceOf(bob), 10_000e6);
    }

    /// @dev The consequence that made the LP slippage floors a custody problem rather than
    ///      a liveness one: with an in-range LP unburnable, `withdraw` failed
    ///      `InsufficientIdle` and every such customer was forced onto `emergencyWithdraw`,
    ///      which unwinds at zero floors and is MEV exposed. The protected exit was
    ///      unreachable and the unprotected one was the only door. 120 ticks of drift sits
    ///      inside the deviation band the vault permits and was fatal to the old floors.
    function test_FullExitIsReachableAfterBurningAnInRangeLp() public {
        uint256 nftId = _depositUsdc(alice, 20_000e6);
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        uint256 lpId = _keeperMintLp(nftId, 4_000e6, 4_000e6);

        npm.setBurnDriftTicks(120);
        vm.prank(keeper);
        vault.burnLp(nftId, lpId);
        npm.setBurnDriftTicks(0);

        // Back to a single asset so the exit can be paid in USDC.
        uint256 wethIdle = vault.idleBalance(nftId, address(weth));
        vm.prank(keeper);
        vault.swapIdle(
            nftId,
            address(weth),
            address(usdc),
            wethIdle,
            0,
            _swapData(address(weth), address(usdc), wethIdle, wethIdle)
        );

        vm.startPrank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vault.withdraw(nftId, address(usdc), 0, "");
        vm.stopPrank();

        assertApproxEqRel(usdc.balanceOf(alice), 20_000e6, 0.001e18, "the protected exit returns principal");
        vm.expectRevert();
        nft.ownerOf(nftId);
    }

    /// @dev A closing request makes the gross the whole settlement NAV, and that NAV counts
    ///      every pool token at its TWAP quote while the debit reaches idle USDC alone. So
    ///      the close is fail-closed on a single priced raw unit: the keeper has to sell the
    ///      complete balance, and the preview against idle USDC is how anyone sees it is not
    ///      done yet. The fixture's 1:1 tick hides this, because one raw WBTC unit is then
    ///      worth one raw USDC unit; at about 100,000 USDC per WBTC it is worth 999.
    function test_RevertWhen_FullCloseLeavesAPricedNonUsdcResidue() public {
        (uint256 nftId, uint256 residueUsdc) = _positionWithOneRawWbtcUnit();
        uint256 idleUsdc = vault.idleBalance(nftId, address(usdc));

        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        (uint256 gross,,) = vault.previewWithdraw(nftId);
        assertEq(gross, idleUsdc + residueUsdc, "the preview counts a leg the debit cannot reach");

        vm.expectRevert(
            abi.encodeWithSelector(ITuoVault.InsufficientIdle.selector, address(usdc), idleUsdc + residueUsdc, idleUsdc)
        );
        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");
    }

    /// @dev The other half of the fail-closed close: the sale that clears it is an ordinary
    ///      `swapIdle`. It has no minimum amount, its TWAP floor on one raw unit is 995 (999
    ///      at 99.5% is 994.005, rounded up) and not zero, so dust cannot be given away, and
    ///      the unit the fill gives up is what the loss budget is charged.
    ///      It still spends one metered keeper action.
    function test_KeeperClearsTheSmallestPricedResidueAndTheCloseSettles() public {
        (uint256 nftId, uint256 residueUsdc) = _positionWithOneRawWbtcUnit();
        uint256 idleUsdc = vault.idleBalance(nftId, address(usdc));
        uint256 floorUsdc = _ceilBps(residueUsdc, 9_950);
        assertEq(floorUsdc, 995, "the floor rounds up, never under 99.5%");
        (, uint256 lossBefore,) = vault.keeperBudgetOf(nftId);

        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        vm.expectRevert(abi.encodeWithSelector(ITuoSwapRouter.SlippageExceeded.selector, floorUsdc - 1, floorUsdc));
        vm.prank(keeper);
        vault.swapIdle(
            nftId, address(wbtc), address(usdc), 1, 0, _swapData(address(wbtc), address(usdc), 1, floorUsdc - 1)
        );

        vm.prank(keeper);
        vault.swapIdle(
            nftId, address(wbtc), address(usdc), 1, 0, _swapData(address(wbtc), address(usdc), 1, residueUsdc - 1)
        );
        assertEq(vault.idleBalance(nftId, address(wbtc)), 0, "the whole balance is sold");
        (, uint256 lossAfter,) = vault.keeperBudgetOf(nftId);
        assertEq(lossAfter - lossBefore, 1, "the budget is charged the one unit the fill gave up");

        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");

        assertEq(usdc.balanceOf(alice), idleUsdc + residueUsdc - 1, "the close pays every unit the sale returned");
        vm.expectRevert();
        nft.ownerOf(nftId);
    }

    /// @dev The smallest representable share, on a position with no profit. Fee rounding
    ///      has to land on zero rather than skim a unit, and the basis has to come down
    ///      pro rata rather than absorb a charge.
    function test_WithdrawAtOneBasisPointChargesNoFeeWithoutProfit() public {
        uint256 nftId = _depositUsdc(alice, 25_000e6);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 1);

        (uint256 gross, uint256 fee, uint256 net) = vault.previewWithdraw(nftId);
        assertEq(gross, 2_500_000, "1 bp of a 25,000 NAV");
        assertEq(fee, 0, "zero profit, zero fee");
        assertEq(net, 2_500_000);

        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");
        assertEq(vault.accruedFeesUsdc(), 0, "nothing accrued for the treasury");
        assertEq(vault.getPosition(nftId).basisUsdc, 24_997_500_000, "basis reduced pro rata, not eroded by a fee");
    }

    /// @dev Fees are pull payment, and this is why. Arbitrum USDC is Circle's
    ///      `FiatTokenV2_2`, which reverts on any transfer touching a blacklisted account,
    ///      so pushing the fee to `feeRecipient` before paying the owner froze the exit for
    ///      every profitable position - a total custody failure caused by an address Tuo
    ///      does not control. Now a recipient that cannot receive USDC blocks only Tuo's
    ///      own revenue. `MockERC20.setBlacklisted` reproduces the FiatTokenV2_2 behaviour;
    ///      the live counterpart belongs in a fork test that pranks Circle's blacklister.
    function test_WithdrawSurvivesAFeeRecipientThatCannotReceiveUsdc() public {
        uint256 nftId = _profitablePosition();
        usdc.setBlacklisted(treasury, true);

        vm.startPrank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vault.withdraw(nftId, address(usdc), 0, "");
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 12_100e6, "the customer is paid in full");
        assertEq(vault.accruedFeesUsdc(), 900e6, "the fee waits in the vault");

        // Only Tuo's own sweep is blocked, and it unblocks by pointing the fee at an
        // address that can receive - no customer is involved in either step.
        vm.expectRevert(abi.encodeWithSelector(MockERC20.Blacklisted.selector, treasury));
        vm.prank(treasury);
        vault.claimFees();

        vm.prank(treasury);
        vault.setFeeRecipient(bob);
        vm.prank(treasury);
        assertEq(vault.claimFees(), 900e6);
        assertEq(usdc.balanceOf(bob), 900e6);
    }

    function test_PreviewWithdrawMatchesExecution() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        _hedgeRoundTrip(nftId, alice, 4_000e6, 7_000e6);

        (uint256 gross, uint256 fee, uint256 net) = vault.previewWithdraw(nftId);
        assertEq(gross, 13_000e6);
        assertEq(fee, 900e6);
        assertEq(net, 12_100e6);
    }

    // ----------------------------------------------------------------- helpers

    /// @dev A 20,000 USDC position with an in-range LP that has earned about 100 USDC of
    ///      fees the pool has NOT credited to `tokensOwed`: the growth is written to the
    ///      pool's accumulators after the mint, as trading would.
    function _positionWithUncheckpointedFees() internal returns (uint256 nftId, uint256 lpId, uint256 feeUsdc) {
        nftId = _depositUsdc(alice, 20_000e6);
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        lpId = _keeperMintLp(nftId, 4_000e6, 3_000e6);

        (,,,,,,, uint128 liquidity,,,,) = npm.positions(lpId);
        uint256 growth = FullMath.mulDivRoundingUp(50e6, FixedPoint128.Q128, liquidity);
        wethPool.setFeeGrowthGlobal(growth, growth);
        // Both legs are worth par at the fixture's 1:1 tick.
        feeUsdc = 2 * FullMath.mulDiv(liquidity, growth, FixedPoint128.Q128);
    }

    /// @dev 10,000 basis, +3,000 realized through a Hyperliquid round trip, so the fee is
    ///      exactly 900 - the specification's worked example.
    function _profitablePosition() internal returns (uint256 nftId) {
        nftId = _depositUsdc(alice, 10_000e6);
        _hedgeRoundTrip(nftId, alice, 4_000e6, 7_000e6);
    }

    /// @dev A keeper round trip through the WBTC leg that ends one raw unit short of a clean
    ///      conversion, priced at about 100,000 USDC per WBTC.
    function _positionWithOneRawWbtcUnit() internal returns (uint256 nftId, uint256 residueUsdc) {
        int24 tick = wbtcPool.token0() == address(wbtc) ? int24(69_081) : int24(-69_081);
        wbtcPool.setTwapTick(tick);
        wbtcPool.setSpotTick(tick);

        nftId = _depositUsdc(alice, 20_000e6);
        uint256 wbtcOut = PoolTwap.quoteFromUsdcAtTick(tick, address(wbtc), address(usdc), 5_000e6);
        uint256 usdcBack = PoolTwap.quoteToUsdcAtTick(tick, address(wbtc), address(usdc), wbtcOut - 1);
        vm.startPrank(keeper);
        vault.swapIdle(
            nftId, address(usdc), address(wbtc), 5_000e6, 0, _swapData(address(usdc), address(wbtc), 5_000e6, wbtcOut)
        );
        vault.swapIdle(
            nftId,
            address(wbtc),
            address(usdc),
            wbtcOut - 1,
            0,
            _swapData(address(wbtc), address(usdc), wbtcOut - 1, usdcBack)
        );
        vm.stopPrank();

        residueUsdc = PoolTwap.quoteToUsdcAtTick(tick, address(wbtc), address(usdc), 1);
        assertEq(vault.idleBalance(nftId, address(wbtc)), 1, "one raw unit of WBTC left behind");
        assertEq(residueUsdc, 999, "one raw WBTC unit is priced, not zero");
    }
}
