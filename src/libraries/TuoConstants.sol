// SPDX-License-Identifier: LicenseRef-BUSL-1.1
pragma solidity 0.8.26;

/// @title TuoConstants - protocol-wide immutable parameters
/// @author Tuo Team
/// @notice USD accounting is USDC 6-decimals throughout: the vault prices against pool
///         TWAPs only, so no external oracle decimal convention applies.
library TuoConstants {
    /// @dev Basis-point denominator shared by every ratio below.
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Performance fee: 30% of the withdrawn share of profit, never of principal.
    uint16 internal constant PERFORMANCE_FEE_BPS = 3_000;

    /// @dev Minimum USDC credited per deposit (new position or top-up).
    uint256 internal constant MIN_DEPOSIT_USDC = 2_500e6;

    /// @dev Metered keeper actions per position (mintLp, burnLp, swapIdle, bridgeToHl).
    ///      A leaky bucket, NOT a maximum over every sliding window: MAX_KEEPER_ACTION_UNITS
    ///      is the capacity and KEEPER_ACTION_WINDOW the time to refill all of it, so a slot
    ///      is free again 2.4h after it was spent rather than 24h after it. A full bucket
    ///      therefore buys an opening burst of 10, then one call per 2.4h: up to 20 inside a
    ///      closed 24h span, and 10 per day sustained.
    uint256 internal constant KEEPER_ACTION_UNIT = 1e6;
    uint256 internal constant MAX_KEEPER_ACTION_UNITS = 10 * KEEPER_ACTION_UNIT;
    uint256 internal constant MAX_KEEPER_ACTIONS_PER_WINDOW = MAX_KEEPER_ACTION_UNITS / KEEPER_ACTION_UNIT;
    uint256 internal constant KEEPER_ACTION_WINDOW = 24 hours;

    /// @dev Measured value loss a keeper may hold against one position at any instant, as a
    ///      share of that position's total basis, margin bridged to Hyperliquid included. A
    ///      swap is measured at the pool's mean tick and at its gated spot tick, and charged
    ///      the larger loss. A mint is charged the gap between what it consumed and the
    ///      liquidity it produced, both valued at the mean tick.
    ///
    ///      A bucket like the action count, and equally not a sliding-window maximum, but it
    ///      refills in proportion to the charge it holds rather than at an absolute rate: one
    ///      window clears whatever is there. Held at the ceiling that frees 15 bps per 2.4h,
    ///      and 150 bps per window whatever the step size. So an opening burst of 150 bps, up
    ///      to 300 bps inside a closed 24h span, and 150 bps per day sustained.
    ///
    ///      The ceiling is computed from basisUsdc, which measured loss does not shrink, so
    ///      the sustained drain is LINEAR against the original basis: thirty daily refills are
    ///      45% of it, plus up to 1.5% from capacity already free at the start. It is not the
    ///      36% that 150 bps compounding on a shrinking position would give. What a keeper can
    ///      actually reach is bounded further by the swap floor, the deviation gate and the
    ///      action budget, and the real bound is detection plus the Safe revoking KEEPER_ROLE.
    uint16 internal constant MAX_KEEPER_LOSS_BPS_PER_WINDOW = 150;
    uint256 internal constant KEEPER_LOSS_WINDOW = 24 hours;

    /// @dev Smallest margin transfer to the Hyperliquid operator. An absolute operational
    ///      floor set by the bridge rails, not a position-relative bound: under 5 USDC
    ///      neither rail credits and the funds are lost rather than returned, the return
    ///      leg pays a flat 1 USDC, and 10 USD is the venue's own minimum order notional,
    ///      so a bridge that size could not back a hedge on its own. At the floor
    ///      that flat return fee leaves a nominal residue, and settlement stays blocked
    ///      until a `finalReturn` attestation closes the lifecycle; an operator top-up can
    ///      repay the nominal but does not unblock settlement.
    uint256 internal constant MIN_HL_BRIDGE_USDC = 10e6;

    /// @dev Floor under the owner's exit swap: the mean-tick quote less this. Compiled in
    ///      because it protects an owner whose frontend passes `minTokenOut == 0`, and tight
    ///      on purpose: an exit that drift blocks can be taken in USDC instead.
    uint16 internal constant EXIT_FLOOR_BPS = 50;

    /// @dev Ceiling on the treasury-set `keeperSwapSlippageBps`, the tolerance under the
    ///      mean-tick quote for keeper idle swaps. The deviation gate licenses about 200 bps
    ///      between spot and the mean and an honest route costs about 12 bps, so this width
    ///      keeps a spot-priced fill reachable anywhere inside the gate. The loss budget is the
    ///      independent bound: a fill is charged the larger of its mean- and spot-measured
    ///      loss, so on an unhedged position a tolerance above MAX_KEEPER_LOSS_BPS_PER_WINDOW
    ///      cannot be spent on one full-allocation leg. The ceiling is sized on total basis,
    ///      so against a hedged allocation the ten-action budget is what binds: at tolerance
    ///      t, ten floor swaps of the whole on-chain allocation lose 1 - (1 - t)^10 of it,
    ///      4.9% at 50 bps, 9.6% at 100, 22.4% at 250, against a ceiling worth 15% of the
    ///      allocation at a 90% hedge.
    uint16 internal constant MAX_KEEPER_SWAP_SLIPPAGE_BPS = 250;

    /// @dev Max allowed |spot - TWAP| distance before keeper pool operations, and the owner's
    ///      exit into a non-USDC token, revert.
    int24 internal constant MAX_TWAP_DEVIATION_TICKS = 200;

    /// @dev A burn must return at least this share of the position's TWAP value, measured
    ///      on the COMBINED value of both legs. Per-leg floors cannot express the
    ///      constraint: an in-range position's legs move in opposite directions with the
    ///      tick, so any drift pushes one of them below any per-leg floor while the pair
    ///      is worth exactly what it was.
    ///
    ///      The floor checks the position manager's execution, not the market: at any spot,
    ///      a range valued at the mean is worth at least its composition at the mean, so
    ///      only integer rounding (see LP_BURN_FLOOR_MIN_VALUE_USDC) or an unwind returning
    ///      less than the liquidity implies can trip it.
    uint16 internal constant LP_BURN_VALUE_FLOOR_BPS = 9_950;

    /// @dev Burn floor under which the check above is skipped (1 USDC). Both legs and the
    ///      quote round down and the floor rounds up, a residue under p + 3 raw USDC, p being
    ///      one raw unit of the priced leg at the mean. It outweighs the 50 bp tolerance only
    ///      while value < 200 * (p + 3): about $0.15 for WBTC at $73k. Above this threshold the
    ///      tolerance absorbs it, so no separate absolute tolerance is kept. 1 USDC covers p up
    ///      to 4,997, so any WETH price and WBTC up to about $499k. Past that, an LP worth
    ///      between this and 200 * (p + 3) can still false-positive; `emergencyWithdraw`
    ///      closes it.
    uint256 internal constant LP_BURN_FLOOR_MIN_VALUE_USDC = 1e6;

    /// @dev Narrowest LP range the keeper may mint, in ticks (~2.02% of price).
    int24 internal constant MIN_LP_TICK_WIDTH = 200;

    /// @dev TWAP window used for valuation and deviation gates.
    uint32 internal constant TWAP_WINDOW = 30 minutes;

    /// @dev Oracle observation slots an allowlisted pool must have provisioned before the
    ///      vault will price against it, checked against `observationCardinalityNext` in
    ///      the vault constructor (the pool allowlist has no setter, so a pool that cannot
    ///      answer has to abort the deployment).
    uint16 internal constant MIN_OBSERVATION_CARDINALITY = 2_000;

    /// @dev Protocol-wide ceiling on a product's `maxLpCount`, enforced at registration.
    ///      `emergencyWithdraw` closes every open LP in one transaction and each closure
    ///      scans the LP array, so the exit the design guarantees costs more than linearly
    ///      in this number and an uncapped product could put it past a block. Three is the
    ///      widest registered product. Raise it only after measuring a full unwind against
    ///      the real position manager on an Arbitrum fork.
    uint8 internal constant MAX_LP_COUNT = 3;

    /// @dev Wait after requestWithdraw before emergencyWithdraw unlocks
    uint256 internal constant EMERGENCY_WITHDRAW_DELAY = 24 hours;
}
