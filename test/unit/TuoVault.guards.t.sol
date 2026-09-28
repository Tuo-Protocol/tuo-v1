// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITuoVault} from "../../src/interfaces/ITuoVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev The negative paths on the customer and keeper surfaces. Each one is a rail
///      that only ever fires when something has already gone wrong - a hostile
///      keeper, a wrong caller, a malformed amount - which is exactly why they need
///      an assertion rather than a reviewer's word that they are there.
contract TuoVaultGuardsTest is VaultTestBase {
    uint256 internal nftId;

    function setUp() public override {
        super.setUp();
        nftId = _depositUsdc(alice, 20_000e6);
    }

    // ----------------------------------------------- ownership on the exit paths

    function test_RevertWhen_WithdrawalLifecycleCallerIsNotOwner() public {
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        vm.prank(mallory);
        vm.expectRevert(ITuoVault.NotPositionOwner.selector);
        vault.requestWithdraw(nftId, 0);

        vm.prank(mallory);
        vm.expectRevert(ITuoVault.NotPositionOwner.selector);
        vault.withdraw(nftId, address(usdc), 0, "");

        vm.prank(mallory);
        vm.expectRevert(ITuoVault.NotPositionOwner.selector);
        vault.emergencyWithdraw(nftId);
    }

    function test_RevertWhen_WithdrawTokenIsNotListed() public {
        // The withdrawal token doubles as a swap target, so it has to be one of the
        // allowlisted deposit tokens - otherwise the keeper-free exit could be
        // routed into an arbitrary contract.
        vm.startPrank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.DepositTokenNotAllowed.selector, address(npm)));
        vault.withdraw(nftId, address(npm), 0, "");
        vm.stopPrank();
    }

    // ------------------------------------------------- zero amounts on the keeper

    function test_RevertWhen_KeeperEntryPointsGetZeroAmount() public {
        vm.startPrank(keeper);
        vm.expectRevert(ITuoVault.ZeroAmount.selector);
        vault.swapIdle(nftId, address(usdc), address(weth), 0, 0, "");
        // A zero bridge is caught by the operational floor rather than the zero check: the
        // floor is the stricter of the two, and the point is that ANY sub-floor amount is
        // rejected, not just zero. The floor is not what keeps a bridge from arming the
        // outstanding-margin rules - every successful bridge arms them.
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.BelowMinHlBridge.selector, uint256(0)));
        vault.bridgeToHl(nftId, 0, hlOperator);
        vm.expectRevert(ITuoVault.ZeroAmount.selector);
        vault.markBridgeInboundComplete(nftId, 0, false);
        vm.stopPrank();
    }

    // ------------------------------------------- idle USDC owed to an armed request

    /// @dev The payout is funded from idle USDC while NAV counts every leg, so a keeper
    ///      that moves that USDC into an LP or a pool token leaves NAV unchanged and every
    ///      share of the armed request unfundable. Both legs that leave USDC are refused.
    function test_ArmedWithdrawalStaysServiceableWhenKeeperTriesToDeployUsdc() public {
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        (uint256 amount0, uint256 amount1) = _pair(20_000e6, 0);
        vm.startPrank(keeper);
        vm.expectRevert(ITuoVault.WithdrawalRequestPending.selector);
        vault.mintLp(nftId, address(wethPool), -20_000, -19_800, amount0, amount1);
        vm.expectRevert(ITuoVault.WithdrawalRequestPending.selector);
        vault.swapIdle(nftId, address(usdc), address(weth), 20_000e6, 0, "");
        vm.stopPrank();

        vm.prank(alice);
        assertEq(vault.withdraw(nftId, address(usdc), 0, ""), 20_000e6, "the request stays serviceable");
    }

    /// @dev The directions that raise the exit's USDC stay open, and a cancel lifts the
    ///      block: it binds the owner's own request, never the position for good.
    function test_KeeperRaisesUsdcForAnArmedWithdrawalAndRedeploysAfterACancel() public {
        _keeperSwapToWeth(nftId, 10_000e6, 10_000e6);
        uint256 lpId = _keeperMintLp(nftId, 5_000e6, 5_000e6);

        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        vm.startPrank(keeper);
        vault.burnLp(nftId, lpId);
        uint256 wethIdle = vault.idleBalance(nftId, address(weth));
        vault.swapIdle(
            nftId,
            address(weth),
            address(usdc),
            wethIdle,
            0,
            _swapData(address(weth), address(usdc), wethIdle, wethIdle)
        );
        vm.stopPrank();
        (uint256 gross,,) = vault.previewWithdraw(nftId);
        assertEq(vault.idleBalance(nftId, address(usdc)), gross, "idle USDC funds the whole close");

        vm.prank(alice);
        vault.requestWithdraw(nftId, 0);
        assertEq(vault.getPosition(nftId).lpTokenIds.length, 0);
        _keeperMintLp(nftId, 1_000e6, 0);
        assertEq(vault.getPosition(nftId).lpTokenIds.length, 1, "a cancel reopens deployment");
    }

    // -------------------------------------------------------- the HL claim ledger

    function test_RevertWhen_SettleHlClaimHasNoClaimOrNoAmount() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.UnknownPosition.selector, uint256(99)));
        vault.settleHlClaim(99, 1e6);

        // A live position with nothing bridged has no claim to settle.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.NoClaim.selector, nftId));
        vault.settleHlClaim(nftId, 1e6);

        // Open a real claim: bridge margin out, then exit before it comes back.
        vm.prank(keeper);
        vault.bridgeToHl(nftId, 5_000e6, hlOperator);
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(alice);
        vault.emergencyWithdraw(nftId);
        assertEq(vault.getPosition(nftId).hlClaimUsdc, 5_000e6);

        // A zero return pulls nothing and is refused; a write-off is the owner's finalize.
        vm.prank(keeper);
        vm.expectRevert(ITuoVault.ZeroAmount.selector);
        vault.settleHlClaim(nftId, 0);
    }

    // ------------------------------------------------------ TWAP-derived floors

    function test_RevertWhen_SwapIdleLegHasNoUsdcPool() public {
        // The floor is derived from a token/USDC pool TWAP. Without one there is no
        // on-chain price, so the keeper could name any minOut it liked - refuse the
        // swap instead of falling back to a keeper-supplied number.
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.TokenNotAllowlisted.selector, address(dai)));
        vault.swapIdle(nftId, address(usdc), address(dai), 1_000e6, 0, "");

        // Neither leg is USDC: unpriceable in this design, whatever the tokens are.
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.TokenNotAllowlisted.selector, address(wbtc)));
        vault.swapIdle(nftId, address(weth), address(wbtc), 1_000e6, 0, "");
        vm.stopPrank();
    }

    // ------------------------------------ emergency fee when no USDC leg is left

    /// @dev This used to clamp the fee to the idle USDC balance and hand the whole in-kind
    ///      payout over when that balance was zero, which turned the emergency door into a
    ///      fee-free exit for any position the keeper had rotated out of USDC. The fee is a
    ///      share of value, so it is taken from whatever holds the value.
    function test_EmergencyWithdrawTakesTheFeeInKindWhenProfitIsNotInUsdc() public {
        _keeperSwapToWeth(nftId, 20_000e6, 40_000e6);
        assertEq(vault.idleBalance(nftId, address(usdc)), 0, "no USDC left to pay a fee with");
        assertGt(vault.settlementNav(nftId), vault.getPosition(nftId).basisUsdc, "position is in profit");

        uint256 wethBefore = weth.balanceOf(alice);
        vm.prank(alice);
        vault.emergencyWithdraw(nftId);

        // 20,000 of profit over a 20,000 basis is 6,000 of fee, denominated in USDC but
        // settled in the token that actually holds the value.
        assertEq(vault.accruedFeesUsdc(), 0, "nothing owed in USDC");
        assertEq(vault.accruedTokenFees(address(weth)), 6_000e6, "fee withheld in kind");
        assertEq(weth.balanceOf(alice) - wethBefore, 34_000e6, "owner gets the in-kind balance net of fee");
    }

    // --------------------------------------------------- read-only reentrancy

    /// @dev `nonReentrant` stops a re-entering write, but not a re-entering READ - and an
    ///      aggregator callback fires exactly when `swapIdle` has debited the input and not
    ///      yet credited the output, so a NAV read there answers low. The keeper budget is
    ///      worse than low: its two halves are written at opposite ends of the call, the
    ///      action at the top and the measured loss at the bottom, so mid-callback the pair
    ///      is MIXED - this swap already counted as an action, its loss not yet charged.
    ///      That tuple is unobservable once the call returns, which is what makes it a
    ///      trap for an integration that persists it. Nothing on-chain consumes these views
    ///      today, which is why the window was harmless and why it is cheap to close now.
    ///      Proved by actually reentering from inside the swap rather than by reading the
    ///      modifier list off the source, and on a LOSS-MAKING fill: a break-even leg never
    ///      reaches the second write, so it could not expose the discrepancy at all.
    function test_GuardedViewsRefuseAReentrantRead() public {
        ReentrantReadAggregator probe = new ReentrantReadAggregator(vault, nftId);
        vm.prank(treasury);
        vault.addAggregator(address(probe));

        // 20 USDC under par, just inside the vault's own 50 bps floor of 4,975.
        bytes memory data = abi.encode(
            address(probe),
            abi.encodeCall(ReentrantReadAggregator.fill, (address(usdc), address(weth), 5_000e6, 4_980e6))
        );
        vm.prank(keeper);
        vault.swapIdle(nftId, address(usdc), address(weth), 5_000e6, 0, data);

        assertEq(probe.navSelector(), ITuoVault.ReentrantRead.selector, "the mid-swap NAV read must be refused");
        assertEq(probe.budgetSelector(), ITuoVault.ReentrantRead.selector, "so must the mixed budget tuple");
        assertEq(probe.actionsSelector(), ITuoVault.ReentrantRead.selector, "and its action half alone");

        // What the callback would have read: (1, 0). What is true: (1, 20e6).
        (uint256 actions, uint256 loss, uint256 ceiling) = vault.keeperBudgetOf(nftId);
        assertEq(actions, 1, "the swap counted as one metered action");
        assertEq(loss, 20e6, "the charge a mid-swap read would have missed");
        assertEq(ceiling, 300e6, "150 bps of the 20,000 USDC basis");
    }

    // ------------------------------------------------------------ unknown reads

    function test_RevertWhen_GetPositionIsUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.UnknownPosition.selector, uint256(404)));
        vault.getPosition(404);
    }
}

/// @dev An aggregator that reads the vault from inside the swap it is executing - the free
///      hand every aggregator callback has. Records what each guarded view answered rather
///      than reverting on it, so one swap proves all three at once.
contract ReentrantReadAggregator {
    using SafeERC20 for IERC20;

    ITuoVault internal immutable VAULT;
    uint256 internal immutable NFT_ID;
    bytes4 public navSelector;
    bytes4 public budgetSelector;
    bytes4 public actionsSelector;

    constructor(ITuoVault vault_, uint256 nftId_) {
        VAULT = vault_;
        NFT_ID = nftId_;
    }

    function fill(address tokenIn, address tokenOut, uint256 spendAmount, uint256 payoutAmount) external {
        navSelector = _probe(abi.encodeCall(ITuoVault.settlementNav, (NFT_ID)));
        budgetSelector = _probe(abi.encodeCall(ITuoVault.keeperBudgetOf, (NFT_ID)));
        actionsSelector = _probe(abi.encodeCall(ITuoVault.keeperActionsToday, (NFT_ID)));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), spendAmount);
        MockERC20(tokenOut).mint(msg.sender, payoutAmount);
    }

    /// @dev STATICCALL rather than try/catch so one helper serves views of any return
    ///      arity. Zero means the read went through, which is the failure this pins.
    function _probe(bytes memory call) internal view returns (bytes4) {
        (bool ok, bytes memory reason) = address(VAULT).staticcall(call);
        if (ok) return bytes4(0);
        // Truncation to the leading four bytes is the point: this IS the selector.
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes4(reason);
    }
}
