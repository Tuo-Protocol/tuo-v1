// SPDX-License-Identifier: LicenseRef-BUSL-1.1
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";

import {ITuoVault} from "./interfaces/ITuoVault.sol";
import {TuoVaultStorage} from "./TuoVaultStorage.sol";
import {PerformanceFee} from "./libraries/PerformanceFee.sol";
import {PoolTwap} from "./libraries/PoolTwap.sol";
import {PositionValuation} from "./libraries/PositionValuation.sol";
import {TuoConstants} from "./libraries/TuoConstants.sol";

/// @title TuoVaultViews - the read layer of TuoVault
/// @author Tuo Team
abstract contract TuoVaultViews is TuoVaultStorage {
    /// @inheritdoc ITuoVault
    function getPosition(uint256 nftId) external view returns (PositionView memory v) {
        Position storage p = _positions[nftId];
        if (p.createdAt == 0) revert UnknownPosition(nftId);
        v = PositionView({
            productCode: p.productCode,
            active: p.active,
            createdAt: p.createdAt,
            basisUsdc: p.basisUsdc,
            hlMarginBridged: p.hlMarginBridged,
            hlLifecycleOpen: p.hlLifecycleOpen,
            hlClaimUsdc: p.hlClaimUsdc,
            hlClaimReturnedUsdc: p.hlClaimReturnedUsdc,
            hlClaimExitNavUsdc: p.hlClaimExitNavUsdc,
            hlClaimFeeChargedUsdc: p.hlClaimFeeChargedUsdc,
            hlOperator: p.hlOperator,
            lpTokenIds: p.lpTokenIds,
            withdrawalRequestedAt: p.withdrawalRequestedAt,
            withdrawalSharesBps: p.withdrawalSharesBps
        });
    }

    /// @inheritdoc ITuoVault
    function idleBalance(uint256 nftId, address token) external view returns (uint256) {
        _noReentrantRead();
        return _idle[nftId][token];
    }

    /// @inheritdoc ITuoVault
    function accruedFeesUsdc() external view returns (uint256) {
        return accruedTokenFees[address(USDC)];
    }

    /// @inheritdoc ITuoVault
    function idleValueUsdc(uint256 nftId) external view returns (uint256) {
        if (msg.sender != address(this)) revert OnlySelf();
        return _idleValueUsdc(nftId);
    }

    /// @inheritdoc ITuoVault
    function settlementNav(uint256 nftId) external view returns (uint256) {
        _noReentrantRead();
        if (_positions[nftId].createdAt == 0) revert UnknownPosition(nftId);
        return _settlementNav(nftId);
    }

    /// @inheritdoc ITuoVault
    function previewWithdraw(uint256 nftId) external view returns (uint256, uint256, uint256) {
        _noReentrantRead();
        Position storage p = _positions[nftId];
        if (p.createdAt == 0) revert UnknownPosition(nftId);
        if (p.withdrawalRequestedAt == 0) revert WithdrawalNotRequested();
        return PerformanceFee.quote(p.basisUsdc, _settlementNav(nftId), p.withdrawalSharesBps);
    }

    /// @inheritdoc ITuoVault
    function keeperActionsToday(uint256 nftId) external view returns (uint256) {
        _noReentrantRead();
        (uint256 units,) = _decayedBudget(_keeperBudget[nftId]);
        return _actionsCharged(units);
    }

    /// @inheritdoc ITuoVault
    function keeperBudgetOf(uint256 nftId)
        external
        view
        returns (uint256 actionsUsed, uint256 lossUsdcUsed, uint256 lossCeilingUsdc)
    {
        _noReentrantRead();
        (uint256 units, uint256 loss) = _decayedBudget(_keeperBudget[nftId]);
        actionsUsed = _actionsCharged(units);
        lossUsdcUsed = loss;
        lossCeilingUsdc = _keeperLossCeiling(nftId);
    }

    /// @inheritdoc ITuoVault
    function productOf(uint16 productCode) external view returns (Product memory) {
        return _products[productCode];
    }

    /// @inheritdoc ITuoVault
    function isPoolAllowlisted(address pool) external view returns (bool) {
        return _allowedPools[pool];
    }

    /// @inheritdoc ITuoVault
    function isDepositToken(address token) external view returns (bool) {
        return _depositTokens[token];
    }

    /// @inheritdoc ITuoVault
    function valuationPoolOf(address token) external view returns (address) {
        return _valuationPools[token];
    }

    /// @dev Read-only reentrancy guard. `nonReentrant` stops a re-entering *write*, but an
    ///      aggregator callback can still STATICCALL back in mid-`swapIdle` or
    ///      mid-`withdraw`, at the one moment when the input side has been debited and the
    ///      output not yet credited - so NAV would read low.
    ///
    ///      It also covers the two keeper-budget views, where the flaw is not a low value
    ///      but a MIXED one: `_consumeKeeperAction` charges the action at the top of a
    ///      metered call and `_chargeKeeperLoss` the measured loss at the bottom, so a
    ///      callback in between sees its own swap counted as an action with its loss still
    ///      uncharged - a pair that is unobservable once the call returns.
    function _noReentrantRead() internal view {
        if (_reentrancyGuardEntered()) revert ReentrantRead();
    }

    function _activePosition(uint256 nftId) internal view returns (Position storage p) {
        p = _positions[nftId];
        if (p.createdAt == 0) revert UnknownPosition(nftId);
        if (!p.active) revert PositionNotActive();
    }

    /// @dev A claim is an open Hyperliquid lifecycle on a deactivated position: only the
    ///      emergency exit produces that pair, and only finalizeHlClaim ends it. Not keyed on
    ///      `hlClaimUsdc`, which is zero when earlier returns had already repaid the nominal.
    function _claimedPosition(uint256 nftId) internal view returns (Position storage p) {
        p = _positions[nftId];
        if (p.createdAt == 0) revert UnknownPosition(nftId);
        if (p.active || !p.hlLifecycleOpen) revert NoClaim(nftId);
    }

    /// @dev The operator a position is bound to, for the two legs that PULL USDC in.
    ///      Deliberately not re-checked against {isHlOperator}: retiring an operator must
    ///      stop new bridges toward it, never strand the margin of a position that already
    ///      bridged there. A retired operator can still settle its positions home.
    function _boundHlOperator(Position storage p, uint256 nftId) internal view returns (address operator) {
        operator = p.hlOperator;
        if (operator == address(0)) revert HlOperatorUnbound(nftId);
    }

    /// @dev Whole action slots occupied by `units`, rounded UP. Admission charges one
    ///      WHOLE unit against a balance that regenerates continuously, so a slot that is
    ///      only part-regenerated is not an available one: floored, the two budget views
    ///      would advertise it as free and a scheduler would plan one call too many.
    function _actionsCharged(uint256 units) internal pure returns (uint256) {
        return (units + TuoConstants.KEEPER_ACTION_UNIT - 1) / TuoConstants.KEEPER_ACTION_UNIT;
    }

    /// @dev The two counters refill on different shapes: action units at an absolute rate
    ///      (one capacity per window, so one action per 2.4h), the loss in proportion to the
    ///      charge held (one window clears whatever is there). Neither enforces a maximum
    ///      over every sliding window, because both free capacity before the call that spent
    ///      it is a window old, so a CLOSED 24h span admits capacity plus a window of refill:
    ///      20 actions and 300 bps. A zero `updatedAt` means the position was never metered.
    function _decayedBudget(KeeperBudget storage b) internal view returns (uint256 units, uint256 loss) {
        if (b.updatedAt == 0) return (0, 0);
        uint256 elapsed = block.timestamp - b.updatedAt;
        uint256 unitRegen = (TuoConstants.MAX_KEEPER_ACTION_UNITS * elapsed) / TuoConstants.KEEPER_ACTION_WINDOW;
        units = b.actionUnits > unitRegen ? b.actionUnits - unitRegen : 0;
        // The ceiling is position-relative, so decay the loss on the same relative scale:
        // one full window regenerates it entirely, whatever it was.
        uint256 lossRegen = (uint256(b.lossUsdc) * elapsed) / TuoConstants.KEEPER_LOSS_WINDOW;
        loss = b.lossUsdc > lossRegen ? b.lossUsdc - lossRegen : 0;
    }

    /// @dev Sized on TOTAL basis by policy, bridged margin included, not on the on-chain
    ///      allocation the charged actions can reach. Against that allocation the ceiling is
    ///      150 bps / (1 - hedged share): 3% at a 50% hedge cap, 15% at 90%, and only at that
    ///      end can the swap floor and the action budget bind before it, depending on the
    ///      tolerance the treasury set (see MAX_KEEPER_SWAP_SLIPPAGE_BPS).
    function _keeperLossCeiling(uint256 nftId) internal view returns (uint256) {
        return
            (_positions[nftId].basisUsdc * TuoConstants.MAX_KEEPER_LOSS_BPS_PER_WINDOW) / TuoConstants.BPS_DENOMINATOR;
    }

    /// @dev Everything a keeper swap leg needs from the pool oracle, from ONE `observe()`:
    ///      the vault's own minimum output, priced at the mean tick less the treasury's
    ///      `keeperSwapSlippageBps`, and the two ticks the loss budget measures the leg at.
    ///      Legs must be USDC <-> allowlisted pool token.
    ///      The deviation gate must run here as on every keeper price path: an ungated swap
    ///      leg would let the keeper trade at a stale mean after spot has moved - and the
    ///      aggregator allowlist constrains which aggregator, never which pools it routes
    ///      through, so the keeper could be its own counterparty.
    ///
    ///      The gate still licenses 200 ticks between spot and the mean, so the loss is NOT
    ///      measured at the mean alone: a fill at the mean quote would read as value-neutral
    ///      while giving up ~2% against spot. The caller values the leg at both ticks and
    ///      charges the larger loss, so spot can raise a charge and never lower one.
    function _twapLeg(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (uint256 minAmountOut, int24 meanTick, int24 spotTick)
    {
        bool sellingUsdc = tokenIn == address(USDC);
        address poolToken = sellingUsdc ? tokenOut : tokenIn;
        if (!sellingUsdc && tokenOut != address(USDC)) {
            revert TokenNotAllowlisted(tokenOut);
        }
        address pool = _valuationPools[poolToken];
        if (pool == address(0)) revert TokenNotAllowlisted(poolToken);

        (meanTick, spotTick) = PoolTwap.checkDeviationAndTicks(pool);
        minAmountOut = _applySlippageFloor(
            sellingUsdc
                ? PoolTwap.quoteFromUsdcAtTick(meanTick, poolToken, address(USDC), amountIn)
                : PoolTwap.quoteToUsdcAtTick(meanTick, poolToken, address(USDC), amountIn),
            keeperSwapSlippageBps
        );
    }

    /// @dev USDC value of one side of a swap leg at `tick`; USDC itself is taken at par.
    function _valueUsdcAtTick(int24 tick, address token, uint256 amount) internal view returns (uint256) {
        return token == address(USDC) ? amount : PoolTwap.quoteToUsdcAtTick(tick, token, address(USDC), amount);
    }

    /// @dev The exit swap's vault-derived floor. A deposit token with no allowlisted pool has
    ///      no on-chain price, so the vault could bound its exit swap only by the caller's own
    ///      `minTokenOut` - the one value a bad frontend controls. Such a token is entry-only:
    ///      the withdrawal reverts, and the owner is paid in USDC or a priced token instead.
    ///      The tolerance is the compiled EXIT_FLOOR_BPS, not the keeper's: this floor is the
    ///      owner's protection, and the keeper's is a liveness setting the treasury tunes.
    function _exitFloor(address withdrawalToken, uint256 netUsdc) internal view returns (uint256) {
        address pool = _valuationPools[withdrawalToken];
        if (pool == address(0)) revert TokenNotAllowlisted(withdrawalToken);
        int24 meanTick = PoolTwap.checkDeviationAndMeanTick(pool);
        return _applySlippageFloor(
            PoolTwap.quoteFromUsdcAtTick(meanTick, withdrawalToken, address(USDC), netUsdc), TuoConstants.EXIT_FLOOR_BPS
        );
    }

    /// @dev USDC value of all idle balances (pool tokens at their TWAP price). The bare
    ///      mean tick: no deviation gate, so this answers while spot is displaced. That is
    ///      required of {_settlementNav}, which must keep the protected withdrawal path
    ///      open, and accepted of the emergency fee, which is measured here and paid in
    ///      kind at spot. See {ITuoVault.idleValueUsdc}.
    function _idleValueUsdc(uint256 nftId) internal view returns (uint256 value) {
        value = _idle[nftId][address(USDC)];
        for (uint256 i = 0; i < _poolTokens.length; i++) {
            address token = _poolTokens[i];
            uint256 balance = _idle[nftId][token];
            if (balance != 0) {
                value += PoolTwap.quoteToUsdc(_valuationPools[token], token, address(USDC), balance);
            }
        }
    }

    /// @dev Measured-only settlement NAV; {ITuoVault.settlementNav} carries the full
    ///      rationale. Margin that has left toward the Hyperliquid operator is NOT valued
    ///      here, so settlement reverts while the hedge is open; the keeper returns the
    ///      margin first (markBridgeInboundComplete), then the position settles. Both halves
    ///      are required: the nominal reconciled AND the keeper's final return on record. A
    ///      repaid nominal alone says nothing about what the venue still holds.
    function _settlementNav(uint256 nftId) internal view returns (uint256 nav) {
        Position storage p = _positions[nftId];
        if (p.hlLifecycleOpen || p.hlMarginBridged != 0) revert HlMarginOutstanding();
        nav = _idleValueUsdc(nftId);
        uint256[] storage lps = p.lpTokenIds;
        for (uint256 i = 0; i < lps.length; i++) {
            uint256 lpTokenId = lps[i];
            nav += PositionValuation.valueLpUsdc(POSITION_MANAGER, lpPoolOf[lpTokenId], lpTokenId, address(USDC));
        }
    }

    /// @dev `toleranceBps` must not exceed BPS_DENOMINATOR; both callers pass a compile-time
    ///      bounded value (EXIT_FLOOR_BPS, or a tolerance capped at MAX_KEEPER_SWAP_SLIPPAGE_BPS).
    ///      Rounds up: a protective minimum never sits a unit under the exact bound.
    function _applySlippageFloor(uint256 amount, uint256 toleranceBps) internal pure returns (uint256) {
        return
            FullMath.mulDivRoundingUp(amount, TuoConstants.BPS_DENOMINATOR - toleranceBps, TuoConstants.BPS_DENOMINATOR);
    }
}
