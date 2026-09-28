// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ITuoVault} from "../../src/interfaces/ITuoVault.sol";
import {ITuoSwapRouter} from "../../src/interfaces/ITuoSwapRouter.sol";
import {TuoConstants} from "../../src/libraries/TuoConstants.sol";
import {TuoRoles} from "../../src/libraries/TuoRoles.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev The privileged surface: role rotation, the deposit pause, and the two registries
///      the treasury can extend. Every one of these is a path that only matters once
///      something else has already gone wrong, which is exactly why it needs an assertion
///      rather than a reviewer's word that it is there. Note how small the surface is: no
///      privileged account can reach a deployed LP, so the pauser's bound is asserted
///      here as an absence.
contract TuoVaultAdminTest is VaultTestBase {
    address internal newKeeper = makeAddr("newKeeper");
    address internal newTreasury = makeAddr("newTreasury");

    // ------------------------------------------------------------ role rotation

    /// @dev TREASURY_ROLE administers itself, the keeper and the pauser, and
    ///      DEFAULT_ADMIN_ROLE is never granted - so the last treasury holder renouncing
    ///      leaves nobody able to grant any role, and a compromised keeper could never be
    ///      revoked. One transaction, irreversible. That is the response half of the loss
    ///      budget's story: the budget only buys time to act, and this made acting
    ///      impossible.
    function test_RevertWhen_TreasuryRoleIsRenounced() public {
        vm.expectRevert(ITuoVault.TreasuryRoleIsNotRenounceable.selector);
        vm.prank(treasury);
        vault.renounceRole(TuoRoles.TREASURY_ROLE, treasury);
        assertTrue(vault.hasRole(TuoRoles.TREASURY_ROLE, treasury));

        // The other roles stay renounceable: losing a keeper or pauser is recoverable,
        // because the treasury can grant them again.
        vm.prank(keeper);
        vault.renounceRole(TuoRoles.KEEPER_ROLE, keeper);
        assertFalse(vault.hasRole(TuoRoles.KEEPER_ROLE, keeper));
        vm.prank(pauser);
        vault.renounceRole(TuoRoles.PAUSER_ROLE, pauser);
        assertFalse(vault.hasRole(TuoRoles.PAUSER_ROLE, pauser));
    }

    /// @dev The block is unconditional, not "unless somebody else holds it too" - because
    ///      "am I the last holder?" is not a question the contract can answer:
    ///      `AccessControl` does not enumerate members. Revocation by another holder is the
    ///      supported way out, and it keeps the property that somebody always holds it.
    function test_TreasuryRoleIsRevocableButNeverRenounceable() public {
        address second = makeAddr("second-treasury");
        vm.prank(treasury);
        vault.grantRole(TuoRoles.TREASURY_ROLE, second);

        vm.expectRevert(ITuoVault.TreasuryRoleIsNotRenounceable.selector);
        vm.prank(second);
        vault.renounceRole(TuoRoles.TREASURY_ROLE, second);

        vm.prank(treasury);
        vault.revokeRole(TuoRoles.TREASURY_ROLE, second);
        assertFalse(vault.hasRole(TuoRoles.TREASURY_ROLE, second));
        assertTrue(vault.hasRole(TuoRoles.TREASURY_ROLE, treasury));
    }

    /// @dev The scenario the renounce block exists for, spelled end to end: whatever the
    ///      operator accounts do to themselves, the treasury can rebuild the surface and
    ///      revoke a keeper again the moment it misbehaves.
    function test_TreasuryCanRebuildTheOperatorSurfaceAfterRenunciation() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);

        vm.prank(keeper);
        vault.renounceRole(TuoRoles.KEEPER_ROLE, keeper);
        vm.prank(pauser);
        vault.renounceRole(TuoRoles.PAUSER_ROLE, pauser);

        address freshKeeper = makeAddr("fresh-keeper");
        address freshPauser = makeAddr("fresh-pauser");
        vm.startPrank(treasury);
        vault.grantRole(TuoRoles.KEEPER_ROLE, freshKeeper);
        vault.grantRole(TuoRoles.PAUSER_ROLE, freshPauser);
        vm.stopPrank();

        vm.prank(freshKeeper);
        vault.bridgeToHl(nftId, 1_000e6, hlOperator);
        assertEq(vault.getPosition(nftId).hlMarginBridged, 1_000e6);

        vm.prank(treasury);
        vault.revokeRole(TuoRoles.KEEPER_ROLE, freshKeeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, freshKeeper, TuoRoles.KEEPER_ROLE
            )
        );
        vm.prank(freshKeeper);
        vault.bridgeToHl(nftId, 1_000e6, hlOperator);
    }

    function test_KeeperRoleRotatesGrantThenRevoke() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);

        vm.startPrank(treasury);
        vault.grantRole(TuoRoles.KEEPER_ROLE, newKeeper);
        vault.revokeRole(TuoRoles.KEEPER_ROLE, keeper);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, keeper, TuoRoles.KEEPER_ROLE
            )
        );
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 1_000e6, hlOperator);

        vm.prank(newKeeper);
        vault.bridgeToHl(nftId, 1_000e6, hlOperator);
        assertEq(vault.getPosition(nftId).hlMarginBridged, 1_000e6);
    }

    /// @dev A self-revoke is the same brick as a renounce, spelled through the other
    ///      entry point, so it gets the same block. Revoking ANOTHER holder stays open:
    ///      that is what rotation needs, and the caller keeps its own role, so the set
    ///      of holders can never reach zero.
    function test_RevertWhen_TreasuryRevokesItself() public {
        vm.expectRevert(ITuoVault.TreasuryRoleIsNotRenounceable.selector);
        vm.prank(treasury);
        vault.revokeRole(TuoRoles.TREASURY_ROLE, treasury);
        assertTrue(vault.hasRole(TuoRoles.TREASURY_ROLE, treasury));

        // Self-revocation of the other roles is unaffected: the treasury can regrant them.
        vm.prank(treasury);
        vault.revokeRole(TuoRoles.KEEPER_ROLE, keeper);
        assertFalse(vault.hasRole(TuoRoles.KEEPER_ROLE, keeper));
    }

    /// @dev The rotation that matters most: handing the treasury itself to a new Safe.
    ///      The old Safe grants, then the NEW Safe revokes the old one - the old Safe
    ///      cannot revoke itself, which is what keeps the reverse order from bricking.
    function test_TreasuryRoleRotatesWithoutLosingControl() public {
        vm.prank(treasury);
        vault.grantRole(TuoRoles.TREASURY_ROLE, newTreasury);
        vm.prank(newTreasury);
        vault.revokeRole(TuoRoles.TREASURY_ROLE, treasury);

        // Read the cap BEFORE arming expectRevert: an argument expression is itself a call,
        // and it would consume both the expectRevert and the prank.
        uint256 cap = vault.perNftCapUsdc();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, treasury, TuoRoles.TREASURY_ROLE
            )
        );
        vm.prank(treasury);
        vault.setPerNftCap(cap);
        assertEq(vault.perNftCapUsdc(), cap, "the revoked treasury changed nothing");

        vm.prank(newTreasury);
        vault.grantRole(TuoRoles.KEEPER_ROLE, newKeeper);
        assertTrue(vault.hasRole(TuoRoles.KEEPER_ROLE, newKeeper), "the new treasury still administers roles");
    }

    // --------------------------------------------------------------- the pauser

    /// @dev The pauser's entire surface is the deposit pause. There is deliberately no
    ///      operator-triggered unwind, so a compromised pauser can stop new money coming
    ///      in and nothing else: it cannot reach a deployed LP, cannot force impermanent
    ///      loss to be realized, and cannot block the owner's own exit.
    function test_PauserCanOnlyGateDepositsNotDeployedCapital() public {
        uint256 nftId = _depositUsdc(alice, 20_000e6);
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        _keeperMintLp(nftId, 4_000e6, 3_000e6);

        uint256 navBefore = vault.settlementNav(nftId);
        (uint256 actionsBefore, uint256 lossBefore,) = vault.keeperBudgetOf(nftId);

        vm.prank(pauser);
        vault.pauseDeposits();

        assertEq(vault.getPosition(nftId).lpTokenIds.length, 1, "the LP is untouched by the pause");
        assertEq(vault.settlementNav(nftId), navBefore, "and so is its value");
        (uint256 actionsAfter, uint256 lossAfter,) = vault.keeperBudgetOf(nftId);
        assertEq(actionsAfter, actionsBefore, "pausing spends no keeper action budget");
        assertEq(lossAfter, lossBefore, "nor the loss budget");

        // The custody guarantee: the owner still exits while paused.
        vm.prank(alice);
        vault.emergencyWithdraw(nftId);
        assertEq(vault.getPosition(nftId).lpTokenIds.length, 0, "the owner's exit unwinds the LP");
    }

    function test_RevertWhen_PauseCallerIsNotPauser() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, mallory, TuoRoles.PAUSER_ROLE
            )
        );
        vm.prank(mallory);
        vault.pauseDeposits();
    }

    // ------------------------------------------------------ HL operator registry

    function test_SetHlOperatorIsTreasuryOnly() public {
        address fresh = makeAddr("hlOperatorC");
        assertFalse(vault.isHlOperator(fresh));

        // Not the keeper's to set, even though the keeper is the only role that bridges.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, keeper, TuoRoles.TREASURY_ROLE
            )
        );
        vm.prank(keeper);
        vault.setHlOperator(fresh, true);

        vm.expectEmit(address(vault));
        emit ITuoVault.HlOperatorUpdated(fresh, true);
        vm.prank(treasury);
        vault.setHlOperator(fresh, true);
        assertTrue(vault.isHlOperator(fresh));

        vm.expectEmit(address(vault));
        emit ITuoVault.HlOperatorUpdated(fresh, false);
        vm.prank(treasury);
        vault.setHlOperator(fresh, false);
        assertFalse(vault.isHlOperator(fresh));
    }

    function test_RevertWhen_SetHlOperatorGetsTheZeroAddress() public {
        vm.expectRevert(ITuoVault.ZeroAddress.selector);
        vm.prank(treasury);
        vault.setHlOperator(address(0), true);
    }

    /// @dev The same three dead ends {setFeeRecipient} refuses, refused one layer down for
    ///      the same reason: `bridgeToHl` debits the position and records the margin before
    ///      it transfers, so a bridge to the vault itself charges the position and moves
    ///      nothing, and both inbound legs pull with `safeTransferFrom` from an address that
    ///      can never approve the vault. The margin would never come home.
    function test_RevertWhen_SetHlOperatorIsProtocolOwned() public {
        address[3] memory sinks = [address(vault), address(nft), address(router)];
        for (uint256 i = 0; i < sinks.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(ITuoVault.ProtocolOwnedAddress.selector, sinks[i]));
            vm.prank(treasury);
            vault.setHlOperator(sinks[i], true);
        }
    }

    /// @dev The refusal is conditioned on `allowed` rather than applied in both directions,
    ///      so it can never freeze the allowlist it protects. The gate has applied since
    ///      construction, so none of the three can be listed in the first place and what this
    ///      reaches is the idempotent early return - which is the point: retirement answers
    ///      the same whether or not the address was ever there.
    function test_RetiringAProtocolOwnedHlOperatorIsStillPermitted() public {
        address[3] memory sinks = [address(vault), address(nft), address(router)];
        for (uint256 i = 0; i < sinks.length; i++) {
            vm.prank(treasury);
            vault.setHlOperator(sinks[i], false);
            assertFalse(vault.isHlOperator(sinks[i]), "retiring one is a no-op, never a revert");
        }
    }

    /// @dev And nothing wider: the gate names four addresses, so every other one still
    ///      lists. A delegated EOA is a valid operator and must not be caught by it.
    function testFuzz_SetHlOperatorAllowlistsEveryOtherAddress(address operator) public {
        // Reshaped, not assumed: the four refused addresses fold onto one that is not.
        if (
            operator == address(0) || operator == address(vault) || operator == address(nft)
                || operator == address(router)
        ) operator = makeAddr("hlOperatorFuzz");

        vm.prank(treasury);
        vault.setHlOperator(operator, true);
        assertTrue(vault.isHlOperator(operator));
    }

    /// @dev THE property that makes removal safe. Retiring an operator has to stop new
    ///      bridges toward it without touching the positions already bound to it -
    ///      otherwise a routine account rotation would strand live customer margin with no
    ///      way back, and `emergencyWithdraw` (which leaves an HL claim ticket) would be
    ///      unsettleable. The inbound legs therefore read the binding and never re-check
    ///      the allowlist.
    function test_RemovedHlOperatorCanStillSettleAnExistingPosition() public {
        uint256 nftId = _depositUsdc(alice, 20_000e6);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);

        vm.prank(treasury);
        vault.setHlOperator(hlOperator, false);

        // New outbound routes to it are closed.
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.HlOperatorNotAllowlisted.selector, hlOperator));
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 1_000e6, hlOperator);

        // ...and the position it already holds margin for still comes home in full.
        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, 4_000e6, false);
        assertEq(vault.getPosition(nftId).hlMarginBridged, 0, "retired operator still settled");
        assertEq(vault.idleBalance(nftId, address(usdc)), 20_000e6, "margin fully returned");

        // Including the attestation that closes the lifecycle and opens the owner's exit.
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, 0, true);
        assertEq(vault.settlementNav(nftId), 20_000e6, "a retired operator never blocks settlement");
    }

    /// @dev A retired operator is not a re-bindable one either: the position stays bound,
    ///      so the keeper cannot use a rotation to move a live hedge to another account.
    function test_RevertWhen_RetiredOperatorPositionIsRebridgedElsewhere() public {
        uint256 nftId = _depositUsdc(alice, 20_000e6);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);

        vm.prank(treasury);
        vault.setHlOperator(hlOperator, false);

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.HlOperatorMismatch.selector, nftId, hlOperator, hlOperatorB));
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 1_000e6, hlOperatorB);
    }

    /// @dev Retirement flips the allowlist bit and nothing else. The reverse binding is
    ///      what keeps an operator one-to-one with its position, so it must survive a
    ///      removal and a later re-listing alike: otherwise a treasury rotation would
    ///      reopen the shared-operator route the binding exists to close.
    function test_RetiredOperatorStaysBoundToItsPosition() public {
        uint256 nftId = _depositUsdc(alice, 20_000e6);
        uint256 otherId = _depositUsdc(bob, 20_000e6);
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 4_000e6, hlOperator);

        vm.prank(treasury);
        vault.setHlOperator(hlOperator, false);
        assertEq(vault.hlOperatorPositionOf(hlOperator), nftId, "retirement does not unbind");

        vm.prank(treasury);
        vault.setHlOperator(hlOperator, true);
        assertEq(vault.hlOperatorPositionOf(hlOperator), nftId, "re-listing does not unbind");

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.HlOperatorAlreadyBound.selector, hlOperator, nftId, otherId));
        vm.prank(keeper);
        vault.bridgeToHl(otherId, 4_000e6, hlOperator);
    }

    // ------------------------------------------------- keeper swap tolerance

    /// @dev The tolerance under the mean-tick quote for `swapIdle` is the one floor the
    ///      treasury can move. It is a keeper liveness setting, so it is gated like every
    ///      other treasury write and announced on the same event stream.
    function test_SetKeeperSwapSlippageBpsIsTreasuryOnly() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, mallory, TuoRoles.TREASURY_ROLE
            )
        );
        vm.prank(mallory);
        vault.setKeeperSwapSlippageBps(100);
        assertEq(vault.keeperSwapSlippageBps(), KEEPER_SWAP_SLIPPAGE_BPS);

        vm.expectEmit(address(vault));
        emit ITuoVault.KeeperSwapSlippageUpdated(100);
        vm.prank(treasury);
        vault.setKeeperSwapSlippageBps(100);
        assertEq(vault.keeperSwapSlippageBps(), 100);
    }

    /// @dev The ceiling is compiled in: the treasury tunes the tolerance for route cost and
    ///      spot-to-mean drift, and never past what the loss budget was sized against.
    function test_RevertWhen_KeeperSwapSlippageExceedsTheCeiling() public {
        vm.prank(treasury);
        vm.expectRevert(ITuoVault.InvalidKeeperSwapSlippage.selector);
        vault.setKeeperSwapSlippageBps(TuoConstants.MAX_KEEPER_SWAP_SLIPPAGE_BPS + 1);
        assertEq(vault.keeperSwapSlippageBps(), KEEPER_SWAP_SLIPPAGE_BPS);
    }

    /// @dev Zero included: a tolerance of nothing stalls the keeper until the treasury moves
    ///      it and never costs the owner, so it is a valid setting.
    function testFuzz_SetKeeperSwapSlippageBpsAcceptsAnyValueUpToTheCeiling(uint16 bps) public {
        bps = uint16(bound(bps, 0, TuoConstants.MAX_KEEPER_SWAP_SLIPPAGE_BPS));
        vm.prank(treasury);
        vault.setKeeperSwapSlippageBps(bps);
        assertEq(vault.keeperSwapSlippageBps(), bps);
    }

    // ------------------------------------------------------ aggregator registry

    function test_AddAggregatorRejectsDuplicatesAndZeroAndIsTreasuryGated() public {
        MockAggregator fresh = new MockAggregator();
        assertFalse(router.isAggregator(address(fresh)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, mallory, TuoRoles.TREASURY_ROLE
            )
        );
        vm.prank(mallory);
        vault.addAggregator(address(fresh));

        // Only the vault may reach the router's setter, whoever the caller is.
        vm.expectRevert(ITuoSwapRouter.OnlyVault.selector);
        vm.prank(treasury);
        router.addAggregator(address(fresh));

        vm.expectEmit(address(router));
        emit ITuoSwapRouter.AggregatorAdded(address(fresh));
        vm.prank(treasury);
        vault.addAggregator(address(fresh));
        assertTrue(router.isAggregator(address(fresh)));

        // A duplicate is a no-op the caller should know about, and a zero would allowlist
        // the empty account.
        vm.expectRevert(abi.encodeWithSelector(ITuoSwapRouter.AggregatorAlreadyAllowlisted.selector, address(fresh)));
        vm.prank(treasury);
        vault.addAggregator(address(fresh));

        vm.expectRevert(ITuoSwapRouter.ZeroAddress.selector);
        vm.prank(treasury);
        vault.addAggregator(address(0));
    }

    /// @dev The registry was add-only while the depositor allowlist gated who could reach
    ///      `swap`. `swapData` is caller-supplied on both the deposit and the withdraw leg,
    ///      and `withdraw` is not pausable, so retiring an aggregator is now the only lever
    ///      that stops routes through one later found exploitable.
    function test_RemoveAggregatorStopsRoutesAndIsTreasuryGated() public {
        uint256 nftId = _depositUsdc(alice, 20_000e6);
        bytes memory data = abi.encode(
            address(aggregator), abi.encodeCall(MockAggregator.fill, (address(usdc), address(weth), 5_000e6, 5_000e6))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, mallory, TuoRoles.TREASURY_ROLE
            )
        );
        vm.prank(mallory);
        vault.removeAggregator(address(aggregator));

        // Only the vault may reach the router's setter, whoever the caller is.
        vm.expectRevert(ITuoSwapRouter.OnlyVault.selector);
        vm.prank(treasury);
        router.removeAggregator(address(aggregator));

        vm.expectEmit(address(router));
        emit ITuoSwapRouter.AggregatorRemoved(address(aggregator));
        vm.prank(treasury);
        vault.removeAggregator(address(aggregator));
        assertFalse(router.isAggregator(address(aggregator)));

        // The route is dead from this block, through the vault as well as the router.
        vm.expectRevert(abi.encodeWithSelector(ITuoSwapRouter.AggregatorNotAllowlisted.selector, address(aggregator)));
        vm.prank(keeper);
        vault.swapIdle(nftId, address(usdc), address(weth), 5_000e6, 0, data);

        // Retiring one that is not on the list says so rather than silently succeeding.
        vm.expectRevert(abi.encodeWithSelector(ITuoSwapRouter.AggregatorNotAllowlisted.selector, address(aggregator)));
        vm.prank(treasury);
        vault.removeAggregator(address(aggregator));

        // And it is reversible: retiring is not a one-way door either.
        vm.prank(treasury);
        vault.addAggregator(address(aggregator));
        vm.prank(keeper);
        assertEq(vault.swapIdle(nftId, address(usdc), address(weth), 5_000e6, 0, data), 5_000e6);
    }

    /// @dev Emptying the allowlist entirely is permitted rather than blocked by a counter,
    ///      and the USDC payout branch is the reason it can be: it transfers, it never
    ///      swaps. What that argument covers is a share the position's idle USDC already
    ///      holds - the whole basis of one that was never deployed, or a partial share that
    ///      fits inside what came back. Where the USDC has to be earned first, see the
    ///      revert case below.
    function test_EmptyAllowlistStillSettlesWhatIdleUsdcAlreadyCovers() public {
        uint256 pureUsdc = _depositUsdc(alice, 20_000e6);
        uint256 mixed = _depositUsdc(bob, 20_000e6);
        _keeperSwapToWeth(mixed, 6_500e6, 6_500e6);

        vm.prank(treasury);
        vault.removeAggregator(address(aggregator));

        vm.startPrank(alice);
        vault.requestWithdraw(pureUsdc, 10_000);
        vault.withdraw(pureUsdc, address(usdc), 0, "");
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 20_000e6, "a position already sitting in USDC settles in full");

        // 13,500 idle USDC against a 20,000 settlement: a half share is 10,000 gross, so
        // the debit lands inside what is there and the WETH leg is never reached.
        vm.startPrank(bob);
        vault.requestWithdraw(mixed, 5_000);
        assertEq(
            vault.withdraw(mixed, address(usdc), 0, ""), 10_000e6, "a partial share inside idle USDC still settles"
        );
        vm.stopPrank();
    }

    /// @dev The half the note and the README missed. `withdraw` debits the gross settlement
    ///      from idle USDC, and `swapIdle` is the only way a pool token becomes idle USDC -
    ///      through the same allowlist the exit swap uses. Empty the list and the converter
    ///      goes with it, so the USDC exit closes for any position still holding a pool
    ///      token, not just the token-elected one. Retiring the last aggregator stays
    ///      permitted on purpose, because a floor on the list would pin a compromised venue
    ///      in place; the counterweight is operational, batching the replacement into the
    ///      same treasury transaction. The in-kind door needs no aggregator and opens either
    ///      way, which is why nothing here is locked.
    ///
    ///      Note where the debit sits: before the payout branch, so a FULL exit hits
    ///      InsufficientIdle whatever token it elects. Reopening the USDC door by touching
    ///      only the payout branch would not work.
    function test_RevertWhen_EmptyAllowlistLeavesSettlementShortOfIdleUsdc() public {
        uint256 nftId = _depositUsdc(alice, 20_000e6);
        _keeperSwapToWeth(nftId, 6_500e6, 6_500e6);

        vm.prank(treasury);
        vault.removeAggregator(address(aggregator));

        // The keeper's converter is gone, so the idle WETH can never become idle USDC.
        uint256 wethIdle = vault.idleBalance(nftId, address(weth));
        vm.expectRevert(abi.encodeWithSelector(ITuoSwapRouter.AggregatorNotAllowlisted.selector, address(aggregator)));
        vm.prank(keeper);
        vault.swapIdle(
            nftId,
            address(weth),
            address(usdc),
            wethIdle,
            0,
            _swapData(address(weth), address(usdc), wethIdle, wethIdle)
        );

        wbtc.mint(alice, 1e8);
        vm.startPrank(alice);
        wbtc.approve(address(vault), 1e8);
        vm.expectRevert(abi.encodeWithSelector(ITuoSwapRouter.AggregatorNotAllowlisted.selector, address(aggregator)));
        vault.deposit(address(wbtc), 1e8, 1, 0, _swapData(address(wbtc), address(usdc), 1e8, 1e8), 0);

        // A half share, so the debit clears and the call reaches the swap it cannot route.
        vault.requestWithdraw(nftId, 5_000);
        vm.expectRevert(abi.encodeWithSelector(ITuoSwapRouter.AggregatorNotAllowlisted.selector, address(aggregator)));
        vault.withdraw(nftId, address(wbtc), 0, _swapData(address(usdc), address(wbtc), 1, 1));

        vault.requestWithdraw(nftId, 10_000);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.InsufficientIdle.selector, address(usdc), 20_000e6, 13_500e6));
        vault.withdraw(nftId, address(usdc), 0, "");
        vm.stopPrank();
        assertEq(vault.settlementNav(nftId), 20_000e6, "the position still measures as whole");

        // Only the in-kind door is left, and it needs no aggregator at all.
        vm.prank(alice);
        vault.emergencyWithdraw(nftId);
        assertEq(usdc.balanceOf(alice) + weth.balanceOf(alice), 20_000e6, "paid in kind, not in the elected token");
    }

    /// @dev A rotated aggregator (1inch v5 to v6, 2024) used to kill every swap path with
    ///      no fix short of redeploying and migrating positions.
    function test_ANewlyAddedAggregatorCanActuallyExecute() public {
        uint256 nftId = _depositUsdc(alice, 20_000e6);
        MockAggregator fresh = new MockAggregator();
        vm.prank(treasury);
        vault.addAggregator(address(fresh));

        bytes memory data = abi.encode(
            address(fresh), abi.encodeCall(MockAggregator.fill, (address(usdc), address(weth), 5_000e6, 5_000e6))
        );
        vm.prank(keeper);
        assertEq(vault.swapIdle(nftId, address(usdc), address(weth), 5_000e6, 0, data), 5_000e6);
    }
}
