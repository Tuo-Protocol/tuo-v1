// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ITuoVault} from "../../src/interfaces/ITuoVault.sol";
import {TuoConstants} from "../../src/libraries/TuoConstants.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev What a CLOSED 24-hour span really admits, as opposed to what a sliding-window reading
///      of the two budgets would promise. Both are leaky buckets: `_decayedBudget` frees
///      capacity 2.4h after a call spent it, not 24h after, so a keeper that opens on a full
///      bucket and tops it back up at every refill step spends capacity PLUS a window of
///      refill inside one span - twice the advertised number, on both counters, before
///      settling to one capacity per day. `TuoConstants` documents those figures; these two
///      tests are what pins them. Cyfrin audit 2026-09, issue 48.
///
///      Every warp targets an ABSOLUTE instant read through `vm.getBlockTimestamp()`. The
///      optimizer rematerializes a plain `block.timestamp` across a `vm.warp`, so both
///      `vm.warp(block.timestamp + step)` and a local copy of it re-read the CURRENT time on
///      each iteration: the steps would compound and the assertions would pass on the wrong
///      instants. Only the cheatcode read is opaque enough to anchor the span.
contract TuoVaultBudgetRefillTest is VaultTestBase {
    uint256 internal nftId;

    function setUp() public override {
        super.setUp();
        nftId = _depositUsdc(alice, 20_000e6);
    }

    /// @dev Ten actions at t0, then one at each tenth of the window, the last landing exactly
    ///      on t0 + 24h and still admitted. Twenty metered calls inside the closed span.
    function test_KeeperActionsPeakAtTwiceCapacityInAClosedWindow() public {
        uint256 openedAt = vm.getBlockTimestamp();
        uint256 step = TuoConstants.KEEPER_ACTION_WINDOW / TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW;
        bytes memory data = _swapData(address(usdc), address(weth), 100e6, 100e6);
        uint256 admitted;

        vm.startPrank(keeper);
        for (uint256 i = 0; i < TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW; i++) {
            vault.swapIdle(nftId, address(usdc), address(weth), 100e6, 0, data);
            admitted++;
        }
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.KeeperRateLimitExceeded.selector, nftId));
        vault.swapIdle(nftId, address(usdc), address(weth), 100e6, 0, data);

        for (uint256 i = 1; i <= TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW; i++) {
            vm.warp(openedAt + i * step);
            assertEq(
                vault.keeperActionsToday(nftId),
                TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW - 1,
                "a step frees one whole slot, and exactly one"
            );
            vault.swapIdle(nftId, address(usdc), address(weth), 100e6, 0, data);
            admitted++;
        }

        // The tenth step lands on t0 + 24h, so nothing more fits inside the closed span.
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.KeeperRateLimitExceeded.selector, nftId));
        vault.swapIdle(nftId, address(usdc), address(weth), 100e6, 0, data);
        vm.stopPrank();

        assertEq(openedAt + TuoConstants.KEEPER_ACTION_WINDOW, vm.getBlockTimestamp(), "the span closed at 24h");
        assertEq(admitted, 2 * TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW, "capacity plus a window of refill");
    }

    /// @dev The same shape on the value half, where the refill is proportional to the charge
    ///      held rather than absolute: held at the ceiling, a fifth of the window frees a
    ///      fifth of it. Five charges fill both buckets at t0, then one charge at each fifth
    ///      of the window, for 300 bps of the basis inside the closed span against a ceiling
    ///      that never reads above 150 bps.
    function test_KeeperLossPeaksAtTwiceTheCeilingInAClosedWindow() public {
        uint256 openedAt = vm.getBlockTimestamp();
        uint256 step = TuoConstants.KEEPER_LOSS_WINDOW / 5;
        (,, uint256 ceiling) = vault.keeperBudgetOf(nftId);
        assertEq(ceiling, 300e6, "150 bps of the 20,000 USDC basis");

        // A charge costs a fifth of the ceiling and two actions, so five of them exhaust both
        // buckets at once.
        uint256 charged;
        for (uint256 i = 0; i < 5; i++) {
            charged += _chargeAFifthOfTheCeiling();
        }
        (uint256 actionsUsed, uint256 lossUsed,) = vault.keeperBudgetOf(nftId);
        assertEq(actionsUsed, TuoConstants.MAX_KEEPER_ACTIONS_PER_WINDOW, "the action bucket is spent too");
        assertEq(lossUsed, ceiling, "the opening burst reaches the ceiling exactly");
        assertEq(charged, ceiling, "and 150 bps is all it reaches");

        // Each fifth of the window frees 60e6 of loss headroom and the two actions to spend it.
        for (uint256 i = 1; i <= 5; i++) {
            vm.warp(openedAt + i * step);
            charged += _chargeAFifthOfTheCeiling();
        }

        (, lossUsed, ceiling) = vault.keeperBudgetOf(nftId);
        assertEq(openedAt + TuoConstants.KEEPER_LOSS_WINDOW, vm.getBlockTimestamp(), "the span closed at 24h");
        assertEq(charged, 600e6, "twice the ceiling, 300 bps of basis, inside one closed window");
        assertEq(lossUsed, ceiling, "while the bucket itself never reads above 150 bps");
    }

    /// @dev One round trip whose outbound leg fills at exactly the vault's own floor and whose
    ///      return leg is fair, so it costs 60e6 - a fifth of the ceiling - and two metered
    ///      actions. Sized in absolute USDC rather than off the idle balance, so the charge
    ///      does not compound as the position shrinks.
    function _chargeAFifthOfTheCeiling() internal returns (uint256 lossUsdc) {
        uint256 spend = 12_000e6;
        uint256 payout = _ceilBps(spend, TuoConstants.BPS_DENOMINATOR - vault.keeperSwapSlippageBps());

        vm.startPrank(keeper);
        vault.swapIdle(
            nftId, address(usdc), address(weth), spend, 0, _swapData(address(usdc), address(weth), spend, payout)
        );
        vault.swapIdle(
            nftId, address(weth), address(usdc), payout, 0, _swapData(address(weth), address(usdc), payout, payout)
        );
        vm.stopPrank();

        lossUsdc = spend - payout;
    }
}
