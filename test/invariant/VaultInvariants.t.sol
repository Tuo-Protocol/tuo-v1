// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";

import {ITuoVault} from "../../src/interfaces/ITuoVault.sol";
import {TuoConstants} from "../../src/libraries/TuoConstants.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {VaultHandler} from "./handlers/VaultHandler.sol";

/// @dev Custody invariants. The handler drives every entry point
///      with bounded fuzz inputs; these properties must hold after any call
///      sequence:
///      I1/I2 full attribution - the vault's token balances equal the sum of
///            per-position idle accounting (no orphaned or shared funds);
///      I3    no position's basis exceeds the USDC actually deposited into it;
///      I4    value conservation - every USDC that entered (deposits + simulated
///            HL pnl) is exactly at the vault, an HL operator, the NPM, the
///            aggregator, or was paid to owners/treasury;
///      I5    the keeper address never accumulates funds;
///      I6    an NFT exists iff its position is active or its Hyperliquid lifecycle is open;
///      I7    the per-position rolling keeper action budget is never exceeded;
///      I8    the NFT owner can always exit (the self-serve custody guarantee);
///      I9    cumulative keeper-attributed value loss stays inside the rolling budget;
///      I10   the HL claim ledger never loses a ticket: an NFT survives while the lifecycle
///            is open, a ticket is only ever closed by its owner's finalizeHlClaim, and
///            every return is charged exactly the cumulative fee delta;
///      I11   no bridge under MIN_HL_BRIDGE_USDC ever lands;
///      I12   operators and positions are one-to-one: a bound operator's reverse record
///            names the position bound to it, so no two positions ever share one;
///      I13   the owner of an open claim can always finalize it and reach a terminal state;
///      I14   outstanding nominal margin implies an open lifecycle, so the lifecycle flag
///            alone is never weaker than the nominal gate it was added beside;
///      I15   a retired position holds no LP and no idle balance.
///
///      The handler drives a HOSTILE keeper, not a cooperative one: floor-priced fills,
///      dust bridges, dust-LP spam, and attacker-routed swaps, plus a pauser toggling the
///      deposit gate underneath all of it. That matters more than any single property
///      below: the explanation for 155 green tests coexisting with a fee-extraction
///      vector, an unbounded hedge and an unbounded LP array was that the harness only
///      ever asked the keeper to behave.
contract VaultInvariantsTest is StdInvariant, VaultTestBase {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new VaultHandler(vault, usdc, weth, wethPool, npm, aggregator, keeper, pauser, treasury);
        targetContract(address(handler));
    }

    /// @dev The accrued fee pool is the one balance the vault holds that belongs to no
    ///      position, because fees are pull payment. Everything the vault holds is still
    ///      either a position's idle balance or a claimable fee - in EVERY token, not just
    ///      USDC: the emergency exit pays in kind and so withholds its fee in kind, which
    ///      is exactly the balance I2 would otherwise report as unattributed.
    function invariant_I1_usdcFullyAttributed() public view {
        uint256 sum = vault.accruedFeesUsdc();
        uint256 n = handler.nftCount();
        for (uint256 i = 0; i < n; i++) {
            sum += vault.idleBalance(handler.allNftIds(i), address(usdc));
        }
        assertEq(usdc.balanceOf(address(vault)), sum, "I1: unattributed USDC in the vault");
    }

    function invariant_I2_wethFullyAttributed() public view {
        uint256 sum = vault.accruedTokenFees(address(weth));
        uint256 n = handler.nftCount();
        for (uint256 i = 0; i < n; i++) {
            sum += vault.idleBalance(handler.allNftIds(i), address(weth));
        }
        assertEq(weth.balanceOf(address(vault)), sum, "I2: unattributed WETH in the vault");
    }

    /// @notice I3 - the vault never invents principal. `basisUsdc` is what the 30% fee is
    ///         charged above, what the keeper's loss ceiling is a share of, and what the
    ///         product hedge cap is measured against, so a basis larger than the USDC that
    ///         was actually deposited suppresses Tuo's fee and widens both keeper budgets
    ///         at once. It replaced the aggregate-accounting property that went with
    ///         `globalDepositedUsdc`, which was near-tautological (both sides were written
    ///         by the same expression); this one is not, because the two sides are
    ///         maintained by unrelated code.
    function invariant_I3_basisNeverExceedsWhatWasDeposited() public view {
        uint256 sum;
        uint256 n = handler.nftCount();
        for (uint256 i = 0; i < n; i++) {
            sum += vault.getPosition(handler.allNftIds(i)).basisUsdc;
        }
        assertLe(sum, handler.ghostDepositedUsdc(), "I3: vault invented principal");
    }

    function invariant_I4_valueConservation() public view {
        // EVERY operator counts: the handler lists one per position, and margin sitting
        // on any of them is just as much "in the system" as the vault's own balance.
        // Summing a fixed subset would let the invariant pass while USDC went missing.
        uint256 inSystem =
            usdc.balanceOf(address(vault)) + usdc.balanceOf(address(npm)) + usdc.balanceOf(address(aggregator));
        uint256 operatorCount = handler.operatorCount();
        for (uint256 i = 0; i < operatorCount; i++) {
            inSystem += usdc.balanceOf(handler.operators(i));
        }
        uint256 released = handler.ghostPaidOutUsdc() + handler.ghostFeesUsdc();
        assertEq(
            handler.ghostDepositedUsdc() + handler.ghostOperatorPnlMinted() + handler.ghostSwapMintedUsdc()
                + handler.ghostLpFeesMintedUsdc(),
            inSystem + released,
            "I4: USDC created or destroyed"
        );
    }

    function invariant_I5_keeperNeverEnriched() public view {
        assertEq(usdc.balanceOf(keeper), 0, "I5: keeper extracted USDC");
        assertEq(weth.balanceOf(keeper), 0, "I5: keeper extracted WETH");
    }

    function invariant_I6_nftExistenceMatchesLifecycle() public view {
        uint256 n = handler.nftCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 nftId = handler.allNftIds(i);
            ITuoVault.PositionView memory p = vault.getPosition(nftId);
            bool exists;
            try nft.ownerOf(nftId) returns (address) {
                exists = true;
            } catch {
                exists = false;
            }
            assertEq(exists, p.active || p.hlLifecycleOpen, "I6: NFT lifecycle desynced");
        }
    }

    function invariant_I7_keeperActionBudgetHolds() public view {
        uint256 n = handler.nftCount();
        for (uint256 i = 0; i < n; i++) {
            assertLe(
                vault.keeperActionsToday(handler.allNftIds(i)),
                TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW,
                "I7: rolling keeper action budget exceeded"
            );
        }
    }

    /// @notice I8 - the custody guarantee: whatever sequence the keeper, the pauser and
    ///         the other actors ran, the NFT owner can still get their funds out on
    ///         their own. Deliberately the one invariant with NO try/catch: the handler
    ///         runs under `fail_on_revert = false` and wraps every exit, so an exit path
    ///         that reverted systematically would otherwise never fail the suite.
    /// @dev Non-view on purpose - it executes the exits. The snapshot/revert pair makes
    ///      the probe side-effect free, so the fuzz sequence continues from the state it
    ///      was in. `emergencyWithdraw` is the right probe rather than `withdraw`: it
    ///      needs no keeper unwind, ignores the TWAP gate and the HL snapshot, and pays
    ///      in kind, which is exactly what "the client can always leave" means when Tuo
    ///      is offline or hostile.
    function invariant_I8_ownerCanAlwaysExit() public {
        uint256 snapshot = vm.snapshotState();

        uint256 n = handler.nftCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 nftId = handler.allNftIds(i);
            ITuoVault.PositionView memory p = vault.getPosition(nftId);
            if (!p.active) continue;

            address owner = nft.ownerOf(nftId);
            uint256 before = _ownerHoldings(owner);
            bool hadValue = _onchainHoldings(nftId) > 0;

            // An open Hyperliquid lifecycle is the only case gated by the emergency
            // delay, and the gate is intentional (it gives the keeper a window to pull
            // value back). Satisfy it the way a real owner would rather than skip it.
            if (p.hlLifecycleOpen) {
                if (p.withdrawalRequestedAt == 0) {
                    vm.prank(owner);
                    vault.requestWithdraw(nftId, TuoConstants.BPS_DENOMINATOR);
                }
                vm.warp(block.timestamp + TuoConstants.EMERGENCY_WITHDRAW_DELAY + 1);
            }

            vm.prank(owner);
            vault.emergencyWithdraw(nftId);

            assertFalse(vault.getPosition(nftId).active, "I8: exit left the position active");
            if (hadValue) {
                assertGt(_ownerHoldings(owner), before, "I8: exit paid the owner nothing");
            }
        }

        vm.revertToState(snapshot);
    }

    /// @notice I9 - whatever the keeper did, the value it cost each position stays inside
    ///         that position's rolling budget. The budget is the only thing standing
    ///         between a compromised keeper key and a slow drain, so "it is enforced on
    ///         every path" has to be a property rather than a code-reading exercise.
    function invariant_I9_keeperLossBudgetHolds() public view {
        uint256 n = handler.nftCount();
        for (uint256 i = 0; i < n; i++) {
            (, uint256 used, uint256 ceiling) = vault.keeperBudgetOf(handler.allNftIds(i));
            assertLe(used, ceiling, "I9: keeper loss budget exceeded");
        }
        // A ceiling only binds what is charged. With spot anywhere inside the gate, every
        // swap must have been charged the larger of its mean-valued and spot-valued loss.
        assertEq(handler.ghostUnderchargedSwaps(), 0, "I9: a swap was charged less than it cost");
        // And every mint the gap between what it consumed and what it produced, both at the mean.
        assertEq(handler.ghostUnderchargedMints(), 0, "I9: a mint was charged less than it cost");
    }

    /// @notice I10 - the Hyperliquid claim ledger is lossless. A full withdrawal used to
    ///         burn the NFT out from under outstanding margin, leaving the customer with
    ///         an unrecoverable principal and no token to claim against. Three parts:
    ///         (a) an open lifecycle implies the NFT still exists - the nominal margin may
    ///             already read zero, which is exactly when the burn used to slip through,
    ///         (b) every ticket ever opened is still open or was closed by its owner's
    ///             finalizeHlClaim - a return, whatever its size, never closes one. Counted
    ///             as well as summed, because a ticket's principal may be zero, and
    ///         (c) every return was charged exactly the fee owed on cumulative realized
    ///             value less what the claim lifecycle had already charged.
    function invariant_I10_hlClaimLedgerIsLossless() public view {
        uint256 openClaims;
        uint256 openTickets;
        uint256 n = handler.nftCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 nftId = handler.allNftIds(i);
            ITuoVault.PositionView memory p = vault.getPosition(nftId);
            openClaims += p.hlClaimUsdc;
            if (!p.active && p.hlLifecycleOpen) openTickets++;
            if (p.hlLifecycleOpen) {
                try nft.ownerOf(nftId) returns (address) {}
                catch {
                    revert("I10: NFT burned while the HL lifecycle was open");
                }
            }
        }
        assertEq(
            openClaims + handler.ghostClaimFinalizedUsdc(),
            handler.ghostClaimOpenedUsdc(),
            "I10: HL claim ledger drifted"
        );
        assertEq(
            openTickets + handler.ghostClaimTicketsFinalized(),
            handler.ghostClaimTicketsOpened(),
            "I10: an HL claim ticket vanished"
        );
        assertEq(handler.ghostMischargedClaims(), 0, "I10: a claim return was charged the wrong fee");
    }

    /// @notice I11: no bridge under MIN_HL_BRIDGE_USDC is ever accepted.
    /// @dev The floor is the one `bridgeToHl` bound that holds in every position state, so
    ///      the hostile handler aims a sub-floor amount at it on every run. Every successful
    ///      bridge arms the outstanding-margin rules whatever its size; the floor decides
    ///      only the smallest amount that can do so, and it must not be crossable.
    function invariant_I11_noSubFloorBridgeEverLands() public view {
        assertFalse(handler.ghostSubFloorBridgeLanded(), "I11: a sub-floor bridge was accepted");
    }

    /// @dev Everything the vault still holds for a position, in raw token units. Only
    ///      used as a "was there anything to pay out" flag, so summing across decimals
    ///      is fine.

    /// @dev The inbound legs credit the named position with whatever its operator hands
    ///      back, so an operator shared by two positions is a route from one position's
    ///      margin into another's idle balance. The reverse record naming exactly the
    ///      position bound to it is what rules that out: two positions on one operator
    ///      cannot both satisfy it.
    function invariant_I12_operatorBindingIsOneToOne() public view {
        uint256 n = handler.nftCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 nftId = handler.allNftIds(i);
            address operator = vault.getPosition(nftId).hlOperator;
            if (operator == address(0)) continue;
            assertEq(vault.hlOperatorPositionOf(operator), nftId, "I12: operator shared between positions");
        }
    }

    /// @notice I13 - a hedged emergency exit needs two parties to close: the keeper returns
    ///         what the venue gives back, the owner finalizes. The second half must never
    ///         depend on the first, or an absent keeper would leave the NFT open for ever.
    /// @dev Non-view like I8, and for the same reason: it executes the finalize under a
    ///      snapshot so a systematic revert fails the suite instead of being swallowed.
    function invariant_I13_ownerCanAlwaysFinalizeAClaim() public {
        uint256 snapshot = vm.snapshotState();

        uint256 n = handler.nftCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 nftId = handler.allNftIds(i);
            ITuoVault.PositionView memory claim = vault.getPosition(nftId);
            if (claim.active || !claim.hlLifecycleOpen) continue;

            address owner = nft.ownerOf(nftId);
            vm.prank(owner);
            vault.finalizeHlClaim(nftId);

            ITuoVault.PositionView memory p = vault.getPosition(nftId);
            assertFalse(p.hlLifecycleOpen, "I13: finalize left the claim open");
            assertEq(p.hlClaimUsdc, 0, "I13: finalize left the principal standing");
            assertEq(p.basisUsdc, 0, "I13: finalize left the basis standing");
            try nft.ownerOf(nftId) returns (address) {
                revert("I13: finalize did not burn the NFT");
            } catch {}
        }

        vm.revertToState(snapshot);
    }

    /// @notice I14 - settlement and the emergency gate read the lifecycle flag, so a nominal
    ///         that could outlive it would be margin the vault had stopped guarding.
    function invariant_I14_outstandingMarginImpliesOpenLifecycle() public view {
        uint256 n = handler.nftCount();
        for (uint256 i = 0; i < n; i++) {
            ITuoVault.PositionView memory p = vault.getPosition(handler.allNftIds(i));
            if (p.hlMarginBridged != 0) assertTrue(p.hlLifecycleOpen, "I14: margin outstanding on a closed lifecycle");
        }
    }

    /// @notice I15 - no entry point reaches a retired position, so whatever a close leaves
    ///         behind is stranded for good. Every close must leave it empty.
    function invariant_I15_retiredPositionHoldsNothing() public view {
        uint256 n = handler.nftCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 nftId = handler.allNftIds(i);
            ITuoVault.PositionView memory p = vault.getPosition(nftId);
            if (p.active || p.hlLifecycleOpen) continue;
            assertEq(p.lpTokenIds.length, 0, "I15: LP left on a retired position");
            assertEq(vault.idleBalance(nftId, address(usdc)), 0, "I15: USDC left on a retired position");
            assertEq(vault.idleBalance(nftId, address(weth)), 0, "I15: WETH left on a retired position");
            assertEq(vault.idleBalance(nftId, address(wbtc)), 0, "I15: WBTC left on a retired position");
        }
    }

    /// @dev The ticket count in I10 exists for the zero-principal claim, which adds nothing to
    ///      the USDC sums. It would pass vacuously if the handler action meant to open one
    ///      stopped doing so, and a per-run "was it reached" assertion would flake on a run
    ///      the fuzzer never deposits in. So the action is driven once, deterministically.
    function test_HandlerOpensAZeroPrincipalTicketThatI10Counts() public {
        handler.deposit(0, 10_000e6);
        handler.ownerEmergencyExitAfterCoveringReturn(0, 4_000e6);

        assertEq(handler.ghostZeroPrincipalTicketsOpened(), 1, "the covering-return exit opened no ticket");
        ITuoVault.PositionView memory p = vault.getPosition(handler.allNftIds(0));
        assertEq(p.hlClaimUsdc, 0);
        assertTrue(!p.active && p.hlLifecycleOpen, "the ticket is the open lifecycle");
        invariant_I10_hlClaimLedgerIsLossless();

        handler.ownerFinalizeClaim(0);
        assertEq(handler.ghostClaimTicketsFinalized(), 1);
        invariant_I10_hlClaimLedgerIsLossless();
        invariant_I6_nftExistenceMatchesLifecycle();
    }

    /// @dev I15 is vacuous unless a 100% close runs over a holding the NAV does not see, and
    ///      the fuzzer rarely requests exactly 100%. So the close is driven once, directly.
    function test_HandlerClosesOverADustLpThatI15Checks() public {
        handler.deposit(0, 10_000e6);
        handler.ownerFullCloseOverADustLp(0);

        assertEq(handler.ghostFullCloses(), 1, "the dust-LP close never settled");
        assertFalse(vault.getPosition(handler.allNftIds(0)).active);
        invariant_I15_retiredPositionHoldsNothing();
        invariant_I4_valueConservation();
    }

    function _onchainHoldings(uint256 nftId) internal view returns (uint256) {
        return vault.idleBalance(nftId, address(usdc)) + vault.idleBalance(nftId, address(weth))
            + vault.idleBalance(nftId, address(wbtc)) + vault.getPosition(nftId).lpTokenIds.length;
    }

    function _ownerHoldings(address owner) internal view returns (uint256) {
        return usdc.balanceOf(owner) + weth.balanceOf(owner) + wbtc.balanceOf(owner);
    }
}
