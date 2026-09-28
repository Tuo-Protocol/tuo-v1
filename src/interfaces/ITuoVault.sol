// SPDX-License-Identifier: LicenseRef-BUSL-1.1
pragma solidity 0.8.26;

/// @title ITuoVault - custody vault for Tuo positions
/// @author Tuo Team
/// @notice One vault instance custodies every position. Each position is owned by a
///         transferable ERC-721 (TuoPositionNFT); the NFT's current owner is the sole
///         withdrawal authority. The keeper (KEEPER_ROLE) may only reshape a position's
///         holdings inside the vault (swap idle balances, mint/burn Uniswap V3 liquidity)
///         or move margin to an allowlisted Hyperliquid operator address the position is
///         bound to. No function moves position funds to any other address.
///
/// @dev Accounting convention: all "USD" figures are USDC amounts with 6 decimals.
///      Deposits are swapped to USDC on entry, so basis == USDC actually received.
///      Events below are the frozen contract with the off-chain indexer: full position
///      state must be reconstructible from events alone.
interface ITuoVault {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice Snapshot view of a position (storage layout is internal to the vault).
    struct PositionView {
        uint16 productCode; // 1 = BP_CORE, 2 = DH_STANDALONE
        bool active;
        uint40 createdAt;
        uint256 basisUsdc; // deposited-capital basis (USDC, 6 decimals); retained while a claim is open
        uint256 hlMarginBridged; // USDC currently attributed to Hyperliquid
        bool hlLifecycleOpen; // set by bridgeToHl, cleared only by a final return or finalizeHlClaim
        uint256 hlClaimUsdc; // margin converted into the emergency claim; zero when returns had already repaid it
        uint256 hlClaimReturnedUsdc; // cumulative USDC returned against the claim through settleHlClaim
        uint256 hlClaimExitNavUsdc; // on-chain NAV the emergency exit was valued at; 0 when no price existed
        uint256 hlClaimFeeChargedUsdc; // performance fee charged so far on the claim lifecycle, USDC terms
        address hlOperator; // operator bound on the first bridge; 0 until then
        uint256[] lpTokenIds; // open Uniswap NonfungiblePositionManager token ids
        uint40 withdrawalRequestedAt; // 0 when no request pending
        uint16 withdrawalSharesBps;
    }

    /// @notice On-chain policy for one product code.
    /// @dev Replaces a hardcoded `productCode != 1 && != 2` check. `label` doubles as the
    ///      registered flag - a code with a zero label does not exist - so it is never
    ///      cleared, including on retirement. Code 0 is reserved forever: `deposit` uses
    ///      it as the top-up sentinel.
    struct Product {
        bytes32 label; // "BP_CORE" / "DH_STANDALONE", decoded off-chain
        bool openForDeposits; // retiring blocks NEW positions only
        uint16 maxHedgeBps; // ceiling on hlMarginBridged as a share of basisUsdc
        uint8 maxLpCount; // ceiling on simultaneously open LPs, at most MAX_LP_COUNT
    }

    // ---------------------------------------------------------------------
    // Events (frozen indexer contract)
    // ---------------------------------------------------------------------

    /// @notice A new position was opened and its NFT minted to `owner`.
    /// @param nftId the minted position id
    /// @param owner the depositor, and the position's sole withdrawal authority
    /// @param productCode 1 = BP_CORE, 2 = DH_STANDALONE
    /// @param depositToken token supplied by the depositor; address(0) means native ETH
    /// @param depositAmount amount of `depositToken` supplied
    /// @param usdcCredited USDC actually received from the entry swap; this IS the basis
    event PositionOpened(
        uint256 indexed nftId,
        address indexed owner,
        uint16 productCode,
        address depositToken,
        uint256 depositAmount,
        uint256 usdcCredited
    );

    /// @notice An existing position received an additional deposit.
    /// @param nftId the topped-up position
    /// @param depositToken token supplied; address(0) means native ETH
    /// @param depositAmount amount of `depositToken` supplied
    /// @param usdcCredited USDC actually received from the entry swap
    /// @param newBasisUsdc the position's basis after the top-up
    event PositionToppedUp(
        uint256 indexed nftId, address depositToken, uint256 depositAmount, uint256 usdcCredited, uint256 newBasisUsdc
    );

    /// @notice The owner set, restated or cancelled a withdrawal request. A nonzero
    ///         `sharesBps` arms the request and tells the keeper to unwind; zero is the
    ///         cancellation, so an indexer clears the pending request on that value
    ///         rather than on a separate event.
    /// @param nftId the position
    /// @param sharesBps share requested, 1..10_000; 0 cancels
    event WithdrawalRequested(uint256 indexed nftId, uint16 sharesBps);

    /// @notice A withdrawal executed. `grossUsdc == feeUsdc + netUsdc` holds exactly.
    /// @param nftId the position
    /// @param sharesBps share withdrawn, 1..10_000
    /// @param grossUsdc the withdrawn share of settlement NAV
    /// @param feeUsdc 30% of the withdrawn share of profit; zero when the position is down
    /// @param netUsdc paid to the owner, in USDC terms before the exit swap
    /// @param withdrawalToken token the owner elected to be paid in
    /// @param tokenAmountOut amount of `withdrawalToken` actually delivered
    /// @param newBasisUsdc the position's basis after the pro-rata reduction
    event PositionWithdrawn(
        uint256 indexed nftId,
        uint16 sharesBps,
        uint256 grossUsdc,
        uint256 feeUsdc,
        uint256 netUsdc,
        address withdrawalToken,
        uint256 tokenAmountOut,
        uint256 newBasisUsdc
    );

    /// @notice The position NFT was burned: a 100% withdrawal, an emergency exit with the
    ///         Hyperliquid lifecycle closed, or a finalized claim.
    /// @param nftId the burned position
    event PositionBurned(uint256 indexed nftId);

    /// @notice The owner force-recovered the on-chain side without keeper cooperation.
    /// @param nftId the position
    /// @param feeUsdc performance fee accrued on profit already certain from the on-chain leg
    /// @param hlClaimUsdc nominal margin still attributed to Hyperliquid, recorded as the
    ///        claim's principal. NOT the signal that a claim opened: it is zero when earlier
    ///        non-final returns had already repaid the nominal, and the NFT survives all the
    ///        same. A claim is open exactly when this event arrives with no PositionBurned in
    ///        the same transaction, and stays open until {finalizeHlClaim}.
    event EmergencyWithdrawn(uint256 indexed nftId, uint256 feeUsdc, uint256 hlClaimUsdc);

    /// @notice One idle balance was paid in kind: by an emergency withdrawal, or by a 100%
    ///         {withdraw} returning a balance valued at zero. Emitted once per token holding
    ///         a nonzero balance.
    /// @param nftId the position
    /// @param token the token paid out
    /// @param amount amount transferred to the owner
    event EmergencyTokenPaid(uint256 indexed nftId, address indexed token, uint256 amount);

    /// @notice Hyperliquid value returned against an open emergency claim. The return is
    ///         routed through the vault, so `grossUsdc == feeUsdc + netUsdc` holds exactly.
    ///         The claim stays open afterwards whatever the cumulative return; only
    ///         {finalizeHlClaim} closes it.
    /// @param nftId the position
    /// @param grossUsdc USDC pulled from the operator into the vault
    /// @param feeUsdc performance fee charged on this return: the fee owed on cumulative
    ///        realized value less what the claim lifecycle already charged
    /// @param netUsdc USDC paid to the current NFT owner
    event HlClaimSettled(uint256 indexed nftId, uint256 grossUsdc, uint256 feeUsdc, uint256 netUsdc);

    /// @notice The owner closed an open emergency claim and burned the position. Whatever
    ///         part of the bridged principal never came back is written off here, by the
    ///         owner and nobody else.
    /// @param nftId the position
    /// @param shortfallUsdc bridged principal the claim closed without, zero when returns
    ///        reached or exceeded it
    event HlClaimFinalized(uint256 indexed nftId, uint256 shortfallUsdc);

    /// @notice The keeper swapped between a position's idle balances.
    /// @param nftId the position
    /// @param tokenIn token sold
    /// @param tokenOut token bought
    /// @param amountIn exact amount of `tokenIn` spent
    /// @param amountOut amount of `tokenOut` received, measured on the balance delta
    event IdleSwapped(
        uint256 indexed nftId, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    /// @notice The keeper minted Uniswap V3 liquidity from a position's idle balances.
    /// @param nftId the position
    /// @param lpTokenId the NonfungiblePositionManager token id, now owned by the vault
    /// @param pool the allowlisted pool
    /// @param tickLower lower tick of the minted range
    /// @param tickUpper upper tick of the minted range
    /// @param liquidity liquidity the mint produced
    /// @param amount0 token0 actually consumed
    /// @param amount1 token1 actually consumed
    event LpMinted(
        uint256 indexed nftId,
        uint256 indexed lpTokenId,
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice An LP token was unwound back to idle balances and burned.
    /// @param nftId the position
    /// @param lpTokenId the burned NPM token id
    /// @param amount0 token0 principal returned
    /// @param amount1 token1 principal returned
    /// @param fees0 token0 collected over and above principal
    /// @param fees1 token1 collected over and above principal
    event LpBurned(
        uint256 indexed nftId, uint256 indexed lpTokenId, uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1
    );

    /// @notice Margin left the vault toward an allowlisted Hyperliquid operator EOA. This
    ///         is where the hedge leg leaves on-chain custody: a disclosed deviation, and
    ///         the reason per-NFT attribution is tracked on-chain rather than inferred.
    /// @param nftId the position the margin is attributed to
    /// @param operator the operator the position is bound to; the same for every bridge
    ///        this position ever makes, and the address both inbound legs pull from
    /// @param amountUsdc USDC transferred to the operator
    event HlBridgeOutbound(uint256 indexed nftId, address indexed operator, uint256 amountUsdc);

    /// @notice The treasury added or removed a Hyperliquid operator.
    /// @dev Index and alert on this in the same class as {KeeperLossCharged}: it is the
    ///      only on-chain signal that the set of addresses customer margin may leave
    ///      toward has changed, and a removal never revokes an existing position's binding.
    /// @param operator the operator address
    /// @param allowed true when added, false when retired
    event HlOperatorUpdated(address indexed operator, bool allowed);

    /// @notice Margin returned from the Hyperliquid operator into the position's idle USDC.
    /// @dev `finalReturn` is load-bearing for an indexer twice over. It is the only signal
    ///      that the remaining attribution was cleared rather than decremented, and the only
    ///      signal that the Hyperliquid lifecycle closed: a non-final return that reaches or
    ///      passes the nominal floors it at zero and leaves the lifecycle open. A projection
    ///      that ignores it disagrees with the chain for the rest of the position's life.
    /// @param nftId the position
    /// @param amountReturnedUsdc USDC pulled back from the operator
    /// @param finalReturn true when this credit cleared the whole attribution and closed the
    ///        lifecycle
    event HlBridgeInboundCompleted(uint256 indexed nftId, uint256 amountReturnedUsdc, bool finalReturn);

    /// @notice A USDC performance fee was taken from `nftId` and added to the claimable
    ///         pool. `totalAccruedUsdc` is the pool balance after the accrual, so an
    ///         indexer never has to replay to know what the treasury can claim.
    /// @param nftId the position charged
    /// @param feeUsdc the fee taken
    /// @param totalAccruedUsdc claimable pool balance after this accrual
    event FeesAccrued(uint256 indexed nftId, uint256 feeUsdc, uint256 totalAccruedUsdc);

    /// @notice A performance fee was withheld from `nftId` in a token other than USDC.
    /// @dev Only {emergencyWithdraw} produces these: it pays out in kind, so it withholds
    ///      its fee in kind. A settlement withdrawal always emits {FeesAccrued} instead.
    ///      Deliberately a separate event rather than a `token` field on {FeesAccrued}, so
    ///      the existing USDC fee projection keeps its exact shape.
    /// @param nftId the position charged
    /// @param token the token the fee was withheld in
    /// @param amount the fee withheld, in `token`'s own decimals
    /// @param totalAccrued claimable balance of `token` after this accrual
    event TokenFeesAccrued(uint256 indexed nftId, address indexed token, uint256 amount, uint256 totalAccrued);

    /// @notice The treasury swept the claimable USDC pool to `recipient`.
    /// @param recipient the fee recipient at the time of the sweep
    /// @param amountUsdc the amount swept
    event FeesClaimed(address indexed recipient, uint256 amountUsdc);

    /// @notice The treasury swept a claimable in-kind fee pool to `recipient`.
    /// @param token the token swept
    /// @param recipient the fee recipient at the time of the sweep
    /// @param amount the amount swept, in `token`'s own decimals
    event TokenFeesClaimed(address indexed token, address indexed recipient, uint256 amount);

    /// @notice A keeper action cost the position measurable value. Indexing and alerting
    ///         on this is part of the loss-budget control, not an optional extra: the
    ///         budget only slows a drain, the alert is what stops it.
    /// @param nftId the position charged
    /// @param lossUsdc value lost to this single action
    /// @param windowLossUsdc the loss bucket's charge after its refill and after this one.
    ///        Name kept for ABI compatibility; it is not a sliding-window total
    /// @param ceilingUsdc the window ceiling, a share of the position's current basis
    event KeeperLossCharged(uint256 indexed nftId, uint256 lossUsdc, uint256 windowLossUsdc, uint256 ceilingUsdc);

    /// @notice A Uniswap V3 pool was frozen into the allowlist at construction. One per entry
    ///         in `InitConfig.pools`, in configuration order, and the whole on-chain record of
    ///         a registry that has no setter and no enumerable getter: `isPoolAllowlisted` and
    ///         `valuationPoolOf` only answer for an address the caller already holds.
    /// @dev This is what attributes `LpMinted` / `LpBurned` `amount0` and `amount1` for a
    ///      consumer reading events alone. The pair is `token` and USDC, ordered as the pool
    ///      orders them: the lower of the two addresses is `token0`.
    /// @param pool the allowlisted pool, mintable whether or not it values its token
    /// @param token the pool's non-USDC token
    /// @param isValuationPool whether this pool became `valuationPoolOf(token)`. Only the first
    ///        pool listed for a token does; a later one for the same token emits false and is
    ///        allowlisted without pricing anything
    event PoolRegistered(address indexed pool, address indexed token, bool isValuationPool);

    /// @notice A product code was registered. Add-only: policy is immutable once set.
    /// @param productCode the registered code
    /// @param label "BP_CORE" / "DH_STANDALONE", decoded off-chain
    /// @param maxHedgeBps ceiling on bridged margin as a share of basis
    /// @param maxLpCount ceiling on simultaneously open LPs, at most
    ///        `TuoConstants.MAX_LP_COUNT`
    event ProductRegistered(uint16 indexed productCode, bytes32 label, uint16 maxHedgeBps, uint8 maxLpCount);

    /// @notice A product was opened or retired for NEW deposits. Existing positions keep
    ///         running under the policy they were opened with.
    /// @param productCode the product
    /// @param openForDeposits whether new positions may be opened against it
    event ProductOpenUpdated(uint16 indexed productCode, bool openForDeposits);

    /// @notice The treasury changed the per-NFT deposit cap.
    /// @param perNftCapUsdc new ceiling on a single position's basis
    event PerNftCapUpdated(uint256 perNftCapUsdc);

    /// @notice The tolerance under the mean-tick quote for the keeper's idle swaps changed,
    ///         from the constructor seed or {setKeeperSwapSlippageBps}. The owner's exit floor
    ///         is compiled in and never moves with it.
    /// @param keeperSwapSlippageBps the new tolerance, in bps
    event KeeperSwapSlippageUpdated(uint16 keeperSwapSlippageBps);

    /// @notice The performance-fee recipient changed.
    /// @param feeRecipient the new recipient of {claimFees} sweeps
    event FeeRecipientUpdated(address indexed feeRecipient);

    /// @notice Deposits were paused or unpaused. Withdrawals and emergency exits are
    ///         never affected.
    /// @param paused whether deposits are now blocked
    event DepositsPauseUpdated(bool paused);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice An amount that must be positive was zero.
    error ZeroAmount();

    /// @notice An address that must be set was the zero address.
    error ZeroAddress();

    /// @notice The address is one of the three protocol-owned contracts: the vault itself,
    ///         its position NFT, or its swap router. None of them can pay such a balance back
    ///         out, so naming one as a payee orphans the transfer: the vault has no sweep for
    ///         value attributed to neither a position nor the fee pool, the NFT holds no ERC-20
    ///         transfer at all, and the router only ever pays the vault the measured delta of a
    ///         swap it was asked to make.
    /// @param account the rejected address
    error ProtocolOwnedAddress(address account);

    /// @notice No position has ever been opened under this id.
    /// @param nftId the id that was looked up
    error UnknownPosition(uint256 nftId);

    /// @notice The caller does not hold the position NFT, which is the sole withdrawal
    ///         authority. Approvals do not confer it.
    error NotPositionOwner();

    /// @notice The position exists but has been closed out.
    error PositionNotActive();

    /// @notice The product code or its policy is malformed: code 0 (reserved as
    ///         `deposit`'s top-up sentinel), an empty label, a hedge cap above 100%, or an
    ///         LP count of zero or above `TuoConstants.MAX_LP_COUNT`.
    /// @param productCode the offending code
    error InvalidProductCode(uint16 productCode);

    /// @notice A top-up named a product code other than the one the position was opened
    ///         under. Pass 0 to top up without restating it.
    error ProductCodeMismatch();

    /// @notice The registry is add-only and this code is already registered; an existing
    ///         product's policy can never be rewritten under a live position.
    /// @param productCode the already-registered code
    error ProductAlreadyRegistered(uint16 productCode);

    /// @notice The product has been retired for NEW positions. Existing positions under
    ///         it are unaffected.
    /// @param productCode the retired code
    error ProductClosedForDeposits(uint16 productCode);

    /// @notice The product code was never registered.
    /// @param productCode the unknown code
    error UnknownProduct(uint16 productCode);

    /// @notice The token is not on the deposit allowlist fixed at deployment.
    /// @param token the rejected token
    error DepositTokenNotAllowed(address token);

    /// @notice A native-ETH deposit whose `msg.value` did not equal the stated `amount`.
    error NativeAmountMismatch();

    /// @notice The entry swap credited less than MIN_DEPOSIT_USDC. The floor is on USDC
    ///         actually received, not on what was offered, so a bad route cannot slip
    ///         under it.
    /// @param usdcCredited what the swap actually credited
    error BelowMinDeposit(uint256 usdcCredited);

    /// @notice The deposit would push this position's basis past the per-NFT cap.
    error PerNftCapExceeded();

    /// @notice Deposits are paused. Withdrawals and emergency exits are never gated by
    ///         the pause.
    error DepositsArePaused();

    /// @notice The pool is not on the allowlist fixed at deployment. New pools mean a new
    ///         deployment, not a config change a compromised role could make.
    /// @param pool the rejected pool
    error PoolNotAllowlisted(address pool);

    /// @notice The token has no allowlisted USDC pool, so the vault has no price for it
    ///         and will not let a keeper trade it, nor an owner withdraw into it.
    /// @param token the unpriceable token
    error TokenNotAllowlisted(address token);

    /// @notice The pool has not provisioned enough oracle observations to answer a
    ///         TWAP_WINDOW read, so it could not be priced against. Raised by the
    ///         constructor: the pool allowlist has no setter, so a pool that cannot answer
    ///         has to abort the deployment rather than be discovered in production.
    /// @param pool the rejected pool
    /// @param cardinalityNext the pool's provisioned ring size
    error PoolOracleTooShallow(address pool, uint16 cardinalityNext);

    /// @notice A value view was called by someone other than the vault itself.
    /// @dev {idleValueUsdc} is a self-call helper; leaving it open would reintroduce the
    ///      unguarded mid-update read that {ReentrantRead} exists to close.
    error OnlySelf();

    /// @notice The pool's spot tick strays further than MAX_TWAP_DEVIATION_TICKS from its
    ///         30-minute TWAP, so spot is not trustworthy as a value right now.
    /// @dev Mirrors the {PoolTwap} declaration so the selector appears on the vault's
    ///      own ABI; the library's copy is the one actually reverted.
    /// @param pool the pool that failed the gate
    error TwapDeviationTooHigh(address pool);

    /// @notice The position does not hold enough of `token` idle. Balances are per-NFT;
    ///         there is no shared pot to borrow from.
    /// @param token the token being spent
    /// @param requested amount the call tried to spend
    /// @param available amount the position actually holds
    error InsufficientIdle(address token, uint256 requested, uint256 available);

    /// @notice The share must be 1..10_000 basis points.
    /// @param sharesBps the rejected value
    error InvalidSharesBps(uint16 sharesBps);

    /// @notice No withdrawal request is pending for this position.
    error WithdrawalNotRequested();

    /// @notice A withdrawal request is already pending; top-ups of the position, bridges,
    ///         LP mints and swaps out of USDC are blocked while one is open. Clear it with
    ///         `requestWithdraw(nftId, 0)`.
    error WithdrawalRequestPending();

    /// @notice EMERGENCY_WITHDRAW_DELAY has not elapsed since the withdrawal request. The
    ///         delay applies only while `hlLifecycleOpen` is set: it is skipped for a position
    ///         that never bridged, and for one whose final return closed the lifecycle.
    error EmergencyDelayNotElapsed();

    /// @notice The keeper's action allowance for this position is exhausted. The allowance
    ///         is a leaky bucket rather than a sliding-window total: 10 of capacity refilling
    ///         one action per 2.4h, so a full bucket buys a burst of 10, up to 20 inside a
    ///         closed 24h span, and 10 per day sustained.
    /// @param nftId the rate-limited position
    error KeeperRateLimitExceeded(uint256 nftId);

    /// @notice The action would push measured keeper-attributed value loss past the
    ///         position's bucket ceiling. That bucket refills in proportion to the charge it
    ///         holds, so at the ceiling it frees 15 bps per 2.4h: a burst of 150 bps, up to
    ///         300 bps inside a closed 24h span, and 150 bps per day sustained.
    /// @param nftId the position
    /// @param windowLossUsdc the charge the action would have reached, after refill
    /// @param ceilingUsdc the ceiling, a share of the position's current basis
    error KeeperLossBudgetExceeded(uint256 nftId, uint256 windowLossUsdc, uint256 ceilingUsdc);

    /// @notice The bridge would put more margin at Hyperliquid than the product's
    ///         `maxHedgeBps` allows. This is the bound on the leg the loss budget cannot
    ///         measure, because it lives on another venue.
    /// @param nftId the position
    /// @param requestedUsdc total bridged margin the call would have reached
    /// @param capUsdc the product's ceiling for this position
    error HedgeCapExceeded(uint256 nftId, uint256 requestedUsdc, uint256 capUsdc);

    /// @notice Below MIN_HL_BRIDGE_USDC, the operational floor Tuo derives from the
    ///         Hyperliquid bridge rails. The floor is not what keeps a bridge from arming
    ///         the outstanding-margin rules: every successful bridge arms them.
    /// @param amountUsdc the rejected amount
    error BelowMinHlBridge(uint256 amountUsdc);

    /// @notice The bridge destination is not on the treasury's operator allowlist.
    /// @param operator the rejected destination
    error HlOperatorNotAllowlisted(address operator);

    /// @notice The position already bridged to a different operator. A position's margin
    ///         lives under exactly one Hyperliquid operator for its whole life; an HL
    ///         account cannot migrate its open hedge to another one.
    /// @param nftId the position
    /// @param bound the operator it is bound to
    /// @param requested the operator the caller asked for
    error HlOperatorMismatch(uint256 nftId, address bound, address requested);

    /// @notice The operator already serves another position. Operators are one-to-one
    ///         with positions for life; the inbound legs credit the named position with
    ///         whatever its operator returns, so a shared operator would let one
    ///         position's margin be credited to another.
    /// @param operator the requested destination
    /// @param boundNftId the position it already serves
    /// @param nftId the position that asked for it
    error HlOperatorAlreadyBound(address operator, uint256 boundNftId, uint256 nftId);

    /// @notice An inbound leg ran for a position that never bridged, so there is no
    ///         operator to pull from. Reachable only by a keeper calling the legs out of
    ///         order; the source is never caller-supplied.
    /// @param nftId the position
    error HlOperatorUnbound(uint256 nftId);

    /// @notice The position already holds the maximum simultaneous LPs its product allows.
    /// @param nftId the position
    /// @param maxLpCount the product's ceiling
    error LpCountExceeded(uint256 nftId, uint8 maxLpCount);

    /// @notice The LP token is not registered to this position. The registry is what makes
    ///         every LP attributable to exactly one NFT.
    /// @param nftId the position named by the caller
    /// @param lpTokenId the LP token that does not belong to it
    error LpNotOwnedByPosition(uint256 nftId, uint256 lpTokenId);

    /// @notice The range is narrower than MIN_LP_TICK_WIDTH. A range the price crosses in
    ///         one block acts as a swap that bypasses `swapIdle`'s TWAP floor and loss
    ///         budget.
    /// @param tickLower lower tick requested
    /// @param tickUpper upper tick requested
    error LpRangeTooNarrow(int24 tickLower, int24 tickUpper);

    /// @notice An unwind returned less than LP_BURN_VALUE_FLOOR_BPS of the position's TWAP
    ///         value, measured on the COMBINED value of both legs: the position manager
    ///         returned less than the liquidity implies. Price drift alone cannot cause it;
    ///         TuoConstants.LP_BURN_FLOOR_MIN_VALUE_USDC covers rounding.
    /// @param valueUsdc combined value the unwind actually returned
    /// @param floorUsdc the floor it had to clear
    error LpValueBelowFloor(uint256 valueUsdc, uint256 floorUsdc);

    /// @notice The Hyperliquid lifecycle is still open: nominal margin is outstanding, or it
    ///         is repaid but the keeper has not attested the final return. Settlement is
    ///         measured-only: the vault will not value a hedge held on another venue. The
    ///         keeper's attestation decides WHEN a position may settle, never for how much.
    error HlMarginOutstanding();

    /// @notice A 100% withdrawal while the position still has an LP. The close burns the NFT
    ///         and nothing reaches a burned position, so the keeper burns every LP first,
    ///         including one the mean tick values at zero.
    error LpsOutstanding();

    /// @notice The position has no open emergency claim to settle or finalize: it is still
    ///         active, or its Hyperliquid lifecycle is closed.
    /// @param nftId the position
    error NoClaim(uint256 nftId);

    /// @notice The per-NFT deposit cap is zero - from the constructor, a vault that could
    ///         never accept a deposit; from {setPerNftCap}, deposits closed through a
    ///         parameter rather than through the pause the pauser role owns. Note the check
    ///         is only against zero: any cap below MIN_DEPOSIT_USDC closes deposits just as
    ///         completely and is accepted, so `PerNftCapUpdated` is the signal to watch.
    error InvalidCap();

    /// @notice The keeper swap tolerance is above MAX_KEEPER_SWAP_SLIPPAGE_BPS, from the
    ///         constructor or from {setKeeperSwapSlippageBps}.
    error InvalidKeeperSwapSlippage();

    /// @notice A guarded view was entered from inside an in-flight vault call, when NAV
    ///         would read low and the keeper budget half-charged (read-only reentrancy).
    error ReentrantRead();

    /// @notice TREASURY_ROLE cannot be renounced or self-revoked; TuoVault.renounceRole explains
    ///         why. Rotation goes grant-then-revoke, the new holder revoking the old one.
    error TreasuryRoleIsNotRenounceable();

    // ---------------------------------------------------------------------
    // Customer functions
    // ---------------------------------------------------------------------

    /// @notice Deposit an allowlisted token; it is swapped to USDC (unless already USDC)
    ///         and credited to a new position (existingNftId == 0) or an existing one.
    /// @param token deposit token; address(0) = native ETH (wrapped to WETH before swap)
    /// @param amount token amount (must equal msg.value for native ETH)
    /// @param productCode product to open under; on a top-up, 0 or the position's own code, else ProductCodeMismatch
    /// @param minUsdcOut caller's slippage floor for the entry swap
    /// @param swapData aggregator calldata for the entry swap (empty when token == USDC)
    /// @param existingNftId 0 to open a new position, otherwise the position to top up
    /// @return nftId the opened or topped-up position id
    function deposit(
        address token,
        uint256 amount,
        uint16 productCode,
        uint256 minUsdcOut,
        bytes calldata swapData,
        uint256 existingNftId
    ) external payable returns (uint256 nftId);

    /// @notice Set, restate or cancel this position's withdrawal request. A pending
    ///         request is the keeper's signal to unwind holdings into idle USDC, and it
    ///         blocks top-ups, new bridges, LP mints and swaps out of USDC until it clears.
    ///         It is also what arms {emergencyWithdraw}'s delay, so restating one restarts
    ///         that clock.
    /// @dev There is deliberately no separate cancel entry point, and no readiness flag
    ///      for a keeper to flip: {withdraw} is gated on what the vault can measure -
    ///      settlement reverts while the Hyperliquid lifecycle is open, a 100% withdraw
    ///      reverts LpsOutstanding while any LP is registered, and the payout must be
    ///      covered by idle USDC - so a request the keeper has not serviced yet simply
    ///      cannot execute. See {withdraw}.
    /// @param nftId the position to withdraw from
    /// @param sharesBps share to withdraw, 1..10_000 (10_000 closes the position);
    ///        0 cancels a pending request
    function requestWithdraw(uint256 nftId, uint16 sharesBps) external;

    /// @notice Execute the requested withdrawal. Charges the 30% performance fee on the
    ///         withdrawn share of profit (never on principal), pays out in
    ///         `withdrawalToken`, burns the NFT when the request was for 100%.
    /// @dev Two measured conditions decide whether the position is withdrawable, and
    ///      neither is anybody's attestation: settlement NAV reverts with
    ///      HlMarginOutstanding while the hedge leg is open, and the withdrawn share of
    ///      that NAV must be covered by the position's idle USDC or the call reverts
    ///      InsufficientIdle. Both are readable off-chain ({previewWithdraw} against
    ///      {idleBalance}), which is how a frontend shows a request as serviceable. The
    ///      debit runs before the payout branch, so a shortfall closes the exit in every
    ///      token including USDC; the keeper covers it with {swapIdle}, which needs an
    ///      allowlisted aggregator. {emergencyWithdraw} is the exit that needs none.
    ///      A request for 100% makes the gross the whole settlement NAV, so it settles only
    ///      once every LP and every pool-token balance the vault values above zero is
    ///      converted completely into USDC: one priced raw unit left idle reverts
    ///      InsufficientIdle. That is deliberate and fail-closed, because paying a share
    ///      the USDC does not cover would pay it out of another position's idle balance or
    ///      the accrued fee pool. It also reverts LpsOutstanding while any LP is registered,
    ///      even one valued at zero, because nothing reaches a burned position. A pool-token
    ///      balance valued at zero is outside the NAV: the close pays it to the owner in kind,
    ///      fee-free, with an {EmergencyTokenPaid} per nonzero token.
    /// @param nftId the position
    /// @param withdrawalToken token the owner wants to be paid in: USDC, or a deposit token
    ///        with a valuation pool ({valuationPoolOf}). A deposit token without one is
    ///        entry-only, because the vault cannot derive a floor for its exit swap, and
    ///        reverts TokenNotAllowlisted here. USDC is always available.
    /// @param minTokenOut caller's slippage floor for the exit swap. The vault always applies
    ///        its own floor on top, the mean-tick quote less the compiled EXIT_FLOOR_BPS;
    ///        whichever bound is tighter wins.
    /// @param swapData aggregator calldata for the exit swap (empty when paying in USDC)
    /// @return tokenAmountOut amount of `withdrawalToken` delivered to the owner
    function withdraw(uint256 nftId, address withdrawalToken, uint256 minTokenOut, bytes calldata swapData)
        external
        returns (uint256 tokenAmountOut);

    /// @notice Force-recover the on-chain side of a position without keeper cooperation:
    ///         burns all open LPs and pays every idle balance in-kind to the owner.
    ///         Callable EMERGENCY_WITHDRAW_DELAY after a withdrawal request (immediately
    ///         when the position's Hyperliquid lifecycle is closed or was never opened).
    ///         Works while deposits are paused. An open lifecycle becomes a claim ticket,
    ///         whatever nominal margin is left, zero included; the NFT survives until the
    ///         owner finalizes the claim.
    /// @dev Why an open lifecycle adds the delay at all: the vault can neither value nor
    ///      recover the Hyperliquid leg, so exiting on it immediately would convert live
    ///      margin into a claim ticket no on-chain rule enforces. The request plus the
    ///      window is the keeper's bounded chance to return the margin instead, and
    ///      {bridgeToHl} is closed for the whole of it, so the amount waited on cannot grow.
    ///
    ///      The fee is measured against {idleValueUsdc}, each pool's 30-minute mean tick,
    ///      while the payout is the tokens themselves at whatever the market pays for them.
    ///      The two clocks disagree while spot is moving, so the amount withheld is 30% of
    ///      mean-measured profit rather than 30% of what the exit realizes.
    ///      The fee is charged only on profit already certain, on-chain NAV against the FULL
    ///      basis: the hedge may still return above or below what was bridged, so the basis,
    ///      the exit NAV and this fee are retained and every later return is charged on
    ///      cumulative realized value through {settleHlClaim}.
    /// @param nftId the position to recover
    function emergencyWithdraw(uint256 nftId) external;

    /// @notice Close an open emergency claim and burn the position. Accepts whatever part of
    ///         the bridged principal never returned as a shortfall: the design guarantees no
    ///         margin and has no treasury top-up, so a claim closing below par is the owner's
    ///         write-off of a lost hedge, not a keeper's.
    /// @dev Owner-only by construction: once a claim is open the keeper can never write it
    ///      off, and there is no delay because finalizing only forfeits the owner's own
    ///      future returns. Every return already charged its fee, so nothing is owed here. A
    ///      position with an open claim is never active, so this is also the only owner entry
    ///      point left after the emergency exit.
    /// @param nftId the position with the open claim
    function finalizeHlClaim(uint256 nftId) external;

    // ---------------------------------------------------------------------
    // Keeper functions (KEEPER_ROLE)
    // ---------------------------------------------------------------------

    /// @notice Swap between a position's idle balances via the allowlisted aggregator
    ///         route. Both tokens must be vault-known (USDC or an allowlisted pool
    ///         token); the pool-token leg is TWAP-gated on top of `minAmountOut`.
    /// @dev Value the leg gives up is charged to the keeper-loss budget. Input and output
    ///      are valued at the pool's mean tick as one pair and at its gated spot tick as
    ///      another, and the larger loss is charged, so a fill at a stale mean is charged
    ///      what it gives up against spot. There is no minimum `amountIn`, but a swap of
    ///      any size spends one metered keeper action. An unwind toward a withdrawal sells
    ///      the position's complete {idleBalance} of the token, never an estimate, because
    ///      a 100% {withdraw} reverts on any priced balance left behind. A leg selling USDC
    ///      reverts `WithdrawalRequestPending` while a request is armed: the payout is funded
    ///      from idle USDC alone, so spending it would leave the request unfundable.
    /// @param nftId the position whose idle balances are being reshaped
    /// @param tokenIn token to sell
    /// @param tokenOut token to buy
    /// @param amountIn exact amount of `tokenIn` to spend
    /// @param minAmountOut keeper's floor; the vault's own floor, the mean-tick quote less
    ///        {keeperSwapSlippageBps}, also applies
    /// @param swapData abi.encode(address aggregator, bytes callData) for the router
    /// @return amountOut amount of `tokenOut` received, measured on the balance delta
    function swapIdle(
        uint256 nftId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata swapData
    ) external returns (uint256 amountOut);

    /// @notice Mint Uniswap V3 liquidity for a position from its idle balances. The vault builds
    ///         the NPM mint itself: the pool must be allowlisted, the range at least
    ///         MIN_LP_TICK_WIDTH wide and spot within MAX_TWAP_DEVIATION_TICKS of the pool TWAP.
    ///         That deviation gate, and the keeper-loss charge on the gap between what the mint
    ///         consumed and the liquidity it produced, both at the mean tick, are the bounds. The
    ///         per-leg NPM minimums are zero by design: V3 fixes the consumed ratio from the price
    ///         and the range, so a per-leg floor derived from the same price the mint executes at
    ///         never binds, and one taken as a share of desired rejects honest mints. There is
    ///         deliberately no keeper-supplied slippage parameter either, since it would be the
    ///         only per-leg floor and the keeper could set it to zero. The NPM `deadline` is a
    ///         no-op by design; see the note at the call site.
    /// @dev The pool fixes the minted composition at spot while the vault values it at the
    ///      mean tick, so the gap between the amounts consumed and the minted liquidity, both
    ///      valued at the mean, is charged to the keeper-loss budget. A mint that breaches
    ///      the ceiling reverts with `KeeperLossBudgetExceeded` and the NPM mint rolls back.
    ///      Reverts `WithdrawalRequestPending` while a request is armed, whichever legs it
    ///      spends: only {burnLp} and sales into USDC may reshape a position awaiting payout.
    /// @param nftId the position to mint for
    /// @param pool the allowlisted pool
    /// @param tickLower lower tick of the range
    /// @param tickUpper upper tick of the range
    /// @param amount0Desired token0 offered from the position's idle balance
    /// @param amount1Desired token1 offered from the position's idle balance
    /// @return lpTokenId the NPM token id, registered to this position
    /// @return liquidity liquidity the mint produced
    function mintLp(
        uint256 nftId,
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external returns (uint256 lpTokenId, uint128 liquidity);

    /// @notice Burn one of the position's LP tokens back to idle balances (principal +
    ///         accrued fees). TWAP-gated like mintLp, and floored on the COMBINED USDC
    ///         value of the principal returned rather than on each leg; see
    ///         TuoConstants.LP_BURN_VALUE_FLOOR_BPS. A floor under
    ///         TuoConstants.LP_BURN_FLOOR_MIN_VALUE_USDC is not enforced.
    /// @param nftId the position
    /// @param lpTokenId the LP token to unwind; must be registered to `nftId`
    /// @return amount0 total token0 credited back to idle (principal + fees)
    /// @return amount1 total token1 credited back to idle (principal + fees)
    function burnLp(uint256 nftId, uint256 lpTokenId) external returns (uint256 amount0, uint256 amount1);

    /// @notice Move idle USDC to an allowlisted Hyperliquid operator address for hedging.
    ///         The destination must be on the allowlist, and the FIRST bridge binds the
    ///         position and the operator to each other permanently, one-to-one; per-NFT
    ///         attribution is tracked on-chain.
    /// @param nftId the position the margin is attributed to
    /// @param amountUsdc USDC to send; at least MIN_HL_BRIDGE_USDC, and bounded overall by
    ///        the product's `maxHedgeBps`
    /// @param operator the destination; must satisfy `isHlOperator`, must equal the
    ///        operator this position is already bound to if it has bridged before, and
    ///        must not be bound to any other position (`hlOperatorPositionOf`)
    function bridgeToHl(uint256 nftId, uint256 amountUsdc, address operator) external;

    /// @notice Pull returned margin from the position's bound HL operator back into its
    ///         idle USDC (that operator must have approved the vault).
    /// @dev The source is the bound operator, never a caller-supplied address, so margin
    ///      can only ever return from the account it left toward.
    ///
    ///      A hedge that lost money returns LESS than it was sent, and the difference
    ///      would otherwise sit in `hlMarginBridged` for ever - `settlementNav` reverts
    ///      `HlMarginOutstanding` on any residue, so the owner could never withdraw.
    ///      `finalReturn` is the keeper attesting that nothing is left at the venue, and
    ///      it clears the residue instead of decrementing it. Stated rather than inferred:
    ///      the keeper knows the book is flat and the account swept, the vault cannot.
    ///
    ///      The same reasoning runs the other way. A return that reaches the nominal proves
    ///      nothing about the venue either, because a leg sized from one ledger can repay
    ///      `hlMarginBridged` while proceeds sit on another. So a non-final return only
    ///      reduces the nominal, floored at zero, and `hlLifecycleOpen` stays set: settlement
    ///      stays shut and an emergency exit still opens a claim. Only `finalReturn` closes
    ///      the lifecycle, with a zero amount when nothing is left to pull.
    ///
    ///      The attestation is irreversible. Nothing reopens a closed lifecycle but a new
    ///      bridge, and once the owner has settled and burned on the strength of it, value
    ///      the venue releases later has no position to land on. It must not be given
    ///      until the venue and the operator account are both drained.
    ///      Restricted to a position with an armed withdrawal request, because that is the
    ///      only state in which `bridgeToHl` is closed and the attribution cannot grow
    ///      between the sweep being sized and this credit landing.
    /// @param nftId the position to credit
    /// @param amountReturnedUsdc USDC to pull back from the operator; may be zero only
    ///        when `finalReturn` is set, which writes off a fully lost hedge or closes a
    ///        lifecycle whose nominal earlier returns had already repaid
    /// @param finalReturn true to clear the position's whole outstanding attribution and
    ///        close its Hyperliquid lifecycle
    function markBridgeInboundComplete(uint256 nftId, uint256 amountReturnedUsdc, bool finalReturn) external;

    /// @notice Return Hyperliquid value against an open emergency claim: pulls USDC from the
    ///         bound operator into the vault, charges the performance fee owed on cumulative
    ///         realized value less what was already charged, and pays the rest to the NFT
    ///         owner. Any amount is accepted, above or below the bridged principal, because
    ///         the hedge may have realized either profit or loss.
    /// @dev The claim is never closed here, not even when returns reach the principal: the
    ///      vault cannot know whether more is coming, so the owner closes it with
    ///      {finalizeHlClaim}. Realized value is the NAV the exit was valued at plus every
    ///      return so far; the fee is 30% of its excess over the retained basis, charged
    ///      exactly once because each return only tops up what the lifecycle already charged.
    /// @param nftId the position with the open claim
    /// @param amountUsdc USDC to pull from the operator; must be nonzero
    function settleHlClaim(uint256 nftId, uint256 amountUsdc) external;

    // ---------------------------------------------------------------------
    // Treasury / pauser functions
    // ---------------------------------------------------------------------

    /// @notice Set the address that {claimFees} sweeps performance fees to.
    /// @dev Rejects the zero address and the three protocol-owned contracts (the vault, its
    ///      position NFT, its swap router): none of them can pay the swept balance back out,
    ///      so a claim to one would orphan the whole accrued balance for that token.
    /// @param newFeeRecipient the new recipient
    function setFeeRecipient(address newFeeRecipient) external;

    /// @notice Register a new product code. Add-only by design: an existing code's policy
    ///         is immutable, so a position can never have the rules it was opened under
    ///         changed underneath it. Retirement goes through {setProductOpen}, which
    ///         blocks NEW positions only.
    /// @dev Code 0 is rejected - `deposit` uses it as the top-up sentinel.
    /// @param productCode the code to register
    /// @param label "BP_CORE" / "DH_STANDALONE", decoded off-chain; doubles as the
    ///        registered flag, so it may not be empty
    /// @param maxHedgeBps ceiling on bridged margin as a share of basis, at most 10_000
    /// @param maxLpCount ceiling on simultaneously open LPs, at least 1 and at most
    ///        `TuoConstants.MAX_LP_COUNT` - `emergencyWithdraw` closes every one of them
    ///        in a single transaction
    function registerProduct(uint16 productCode, bytes32 label, uint16 maxHedgeBps, uint8 maxLpCount) external;

    /// @notice Open or retire a product for new deposits. Existing positions are unaffected.
    /// @param productCode the product
    /// @param openForDeposits whether new positions may be opened against it
    function setProductOpen(uint16 productCode, bool openForDeposits) external;

    /// @notice Sweep the accrued USDC performance fees to the current fee recipient.
    /// @dev Pull payment: {withdraw}, {emergencyWithdraw} and {settleHlClaim} accrue, the
    ///      treasury claims. An exit never pushes the fee: the customer's exit must not
    ///      depend on Tuo's own ability to receive funds. Fees withheld in kind by
    ///      {emergencyWithdraw} are swept per token with {claimTokenFees}.
    /// @return amountUsdc the amount swept
    function claimFees() external returns (uint256 amountUsdc);

    /// @notice Sweep the accrued performance fees held in `token` to the fee recipient.
    /// @dev The emergency exit pays in kind, so it withholds its fee in kind; this is the
    ///      matching claim. `token` is USDC-equivalent value, not USDC, so the treasury
    ///      converts off-chain.
    /// @param token the token to sweep
    /// @return amount the amount swept, in `token`'s own decimals
    function claimTokenFees(address token) external returns (uint256 amount);

    /// @notice Set the per-NFT deposit cap. It bounds ONE position's basis; the vault
    ///         enforces no aggregate cap and no limit on how many positions an address may
    ///         open, so this is not a bound on total exposure.
    /// @param newPerNftCapUsdc ceiling on a single position's basis; may not be zero
    function setPerNftCap(uint256 newPerNftCapUsdc) external;

    /// @notice Set the tolerance under the mean-tick quote that bounds the keeper's idle
    ///         swaps. TREASURY_ROLE. A liveness setting: the fill happens at spot while the
    ///         floor comes off the 30-minute mean, so drift the deviation gate permits plus
    ///         the route's own cost is what it has to cover. It moves nothing else: the
    ///         owner's exit floor is the compiled EXIT_FLOOR_BPS, and the loss budget still
    ///         charges every leg the larger of its mean- and spot-measured loss.
    /// @param newBps the tolerance in bps; at most MAX_KEEPER_SWAP_SLIPPAGE_BPS. Zero is
    ///        accepted and makes the floor the mean quote itself, which an honest fill at spot
    ///        cannot reach: it stalls the keeper's swaps until the treasury moves it, and
    ///        never touches an owner's exit
    function setKeeperSwapSlippageBps(uint16 newBps) external;

    /// @notice Add or retire a Hyperliquid operator address. TREASURY_ROLE.
    /// @dev Retiring closes new bridges toward the operator and nothing else: the position
    ///      it serves stays bound and can still settle home, and the operator is never
    ///      freed for another position, whether it is later re-listed or not.
    ///      Listing refuses the zero address and the three protocol-owned contracts: each
    ///      would be paid by {bridgeToHl} and pulled from by the inbound legs, and none of
    ///      them can approve the vault, so the margin would be stranded. Only listing is
    ///      refused, never retirement, so the refusal can never freeze the allowlist it
    ///      protects.
    /// @param operator the operator EOA; may not be the zero address, nor - when listing -
    ///        the vault, its position NFT or its swap router
    /// @param allowed true to allow new bridges toward it, false to retire it
    function setHlOperator(address operator, bool allowed) external;

    /// @notice Allowlist another aggregator on the swap router. TREASURY_ROLE.
    /// @param aggregator the aggregator router to allow
    function addAggregator(address aggregator) external;

    /// @notice Retire an aggregator from the swap router's allowlist. TREASURY_ROLE. This
    ///         is the only lever that can stop routes through an aggregator later found
    ///         exploitable: `swapData` is caller-supplied on both the deposit and the
    ///         withdraw leg, and `withdraw` is not pausable. See
    ///         ITuoSwapRouter.removeAggregator for the accepted counter-risk.
    /// @dev Retiring the last one also suspends {swapIdle}, and with it the USDC
    ///      settlement of any position still holding a pool token, which reverts
    ///      InsufficientIdle until a replacement is listed. Batch the replacement into
    ///      this transaction; {emergencyWithdraw} is the exit that needs no aggregator.
    /// @param aggregator the aggregator router to retire
    function removeAggregator(address aggregator) external;

    /// @notice Pause deposits. PAUSER_ROLE, and the whole of it: there is no
    ///         operator-triggered unwind. Capital already deployed into LPs is reached
    ///         only by the keeper's `burnLp` or by the owner's own `emergencyWithdraw`,
    ///         so no privileged account can force-realize a position's impermanent loss.
    function pauseDeposits() external;

    /// @notice Unpause deposits. Withdrawals and emergency exits were never gated by the
    ///         pause, so this only reopens the entry path.
    function unpauseDeposits() external;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Snapshot of a position's state.
    /// @param nftId the position
    /// @return position the snapshot; reverts with UnknownPosition if it never existed
    function getPosition(uint256 nftId) external view returns (PositionView memory position);

    /// @notice A position's idle balance of one token. Balances are per-NFT; there is no
    ///         shared pot, which is what makes every asset attributable to one position.
    /// @param nftId the position
    /// @param token the token to read
    /// @return amount the idle balance, in the token's own decimals
    function idleBalance(uint256 nftId, address token) external view returns (uint256 amount);

    /// @notice Settlement NAV in USDC (6 decimals), measured only: idle balances (pool
    ///         tokens valued at their allowlisted pool's TWAP) plus open LP positions
    ///         valued at TWAP. Margin bridged to the Hyperliquid operator is NOT valued
    ///         - the vault cannot measure a position held on another venue and will not
    ///         value one from a keeper attestation. Reverts with HlMarginOutstanding
    ///         while `hlLifecycleOpen` is set or `hlMarginBridged != 0`; the keeper returns
    ///         the margin and attests the final return first, then the position settles.
    ///         Full NAV including the hedge leg is produced off-chain by the NAV service.
    /// @param nftId the position to value
    /// @return navUsdc the measured settlement NAV, USDC 6 decimals
    function settlementNav(uint256 nftId) external view returns (uint256 navUsdc);

    /// @notice Preview the pending withdrawal request against current settlement NAV.
    /// @dev The quote models no funding constraint. {withdraw} executes only when
    ///      `grossUsdc` is covered by {idleBalance} of USDC, so compare the two. It does not
    ///      check open LPs either: a 100% request that previews fine still reverts
    ///      LpsOutstanding in {withdraw} while any LP is registered, even one valued at zero.
    /// @param nftId the position with a pending request
    /// @return grossUsdc the withdrawn share of settlement NAV
    /// @return feeUsdc 30% of the withdrawn share of profit; zero when the position is down
    /// @return netUsdc what the owner would receive, in USDC terms before the exit swap
    function previewWithdraw(uint256 nftId) external view returns (uint256 grossUsdc, uint256 feeUsdc, uint256 netUsdc);

    /// @notice Metered keeper actions currently charged against the action bucket.
    /// @dev Name kept for ABI compatibility; the budget is neither a calendar day nor a
    ///      sliding window, but a bucket of 10 refilling one action per 2.4h.
    ///      Whole slots, rounded UP. Admission charges one WHOLE unit against a balance
    ///      that regenerates continuously, so a part-regenerated slot is not an available
    ///      one and a floored count would advertise it as free. Rounded up,
    ///      `MAX_KEEPER_ACTIONS_PER_WINDOW - count` is exactly the number of further
    ///      metered calls this position admits at this timestamp.
    /// @param nftId the position
    /// @return count actions charged, out of MAX_KEEPER_ACTIONS_PER_WINDOW
    function keeperActionsToday(uint256 nftId) external view returns (uint256 count);

    /// @notice The full keeper budget state for a position: actions charged against the
    ///         action bucket, value loss charged against the loss bucket, and its ceiling.
    /// @dev Reverts {ReentrantRead} from inside an in-flight vault call. The two halves are
    ///      written at opposite ends of a metered call, so mid-call the tuple counts an
    ///      action whose loss is not charged yet; read it after the transaction, never from
    ///      a callback.
    /// @param nftId the position
    /// @return actionsUsed metered actions charged against the action bucket, whole slots
    ///         rounded up; see {keeperActionsToday} for the headroom it implies
    /// @return lossUsdcUsed measured value loss charged against the loss bucket
    /// @return lossCeilingUsdc the ceiling, a share of the position's current basis
    function keeperBudgetOf(uint256 nftId)
        external
        view
        returns (uint256 actionsUsed, uint256 lossUsdcUsed, uint256 lossCeilingUsdc);

    /// @notice The on-chain policy registered for a product code.
    /// @param productCode the code to look up
    /// @return product the policy; a zero `label` means the code was never registered
    function productOf(uint16 productCode) external view returns (Product memory product);

    /// @notice USDC performance fees accrued and awaiting a treasury sweep.
    /// @dev Convenience alias for `accruedTokenFees(USDC)`, kept because it is the figure
    ///      every settlement withdrawal accrues into.
    /// @return amountUsdc the claimable pool balance
    function accruedFeesUsdc() external view returns (uint256 amountUsdc);

    /// @notice Performance fees accrued in `token` and awaiting a treasury sweep.
    /// @dev Non-USDC balances arise only from {emergencyWithdraw}, which pays in kind and
    ///      withholds its fee in kind.
    /// @param token the token to look up
    /// @return amount the claimable balance, in `token`'s own decimals
    function accruedTokenFees(address token) external view returns (uint256 amount);

    /// @notice USDC value of a position's idle balances at the pools' TWAP ticks.
    /// @dev External only so {emergencyWithdraw} can `try` it and fall back to a zero fee
    ///      when a pool oracle cannot answer - that is what keeps the guaranteed exit free
    ///      of any price dependency. Self-call only; reverts {OnlySelf} otherwise.
    ///
    ///      The bare mean tick, with no comparison against spot. It is deliberately ungated: a gate
    ///      here would let a displaced pool decide whether the emergency fee is charged at all. The
    ///      settlement NAV built on it (LP legs included) is ungated too, so a displaced pool
    ///      cannot close the withdrawal path. The mean is therefore the clock the emergency fee is
    ///      measured on while the payout is in kind at spot, which is a disclosed residual rather
    ///      than an oversight.
    /// @param nftId the position to value
    /// @return valueUsdc the idle value, 6 decimals
    function idleValueUsdc(uint256 nftId) external view returns (uint256 valueUsdc);

    /// @notice The id the next opened position will be minted under.
    /// @return nftId the next id
    function nextNftId() external view returns (uint256 nftId);

    /// @notice Whether a pool is on the allowlist fixed at deployment.
    /// @param pool the pool to check
    /// @return allowlisted whether the keeper may mint liquidity into it
    function isPoolAllowlisted(address pool) external view returns (bool allowlisted);

    /// @notice Whether a token may be deposited.
    /// @dev A non-USDC deposit token is a valid `withdraw` payout token only when
    ///      {valuationPoolOf} returns a pool for it; without one it is entry-only. USDC is
    ///      always payable.
    /// @param token the token to check
    /// @return allowed whether `deposit` accepts it
    function isDepositToken(address token) external view returns (bool allowed);

    /// @notice The allowlisted token/USDC pool the vault prices `token` against.
    /// @param token the token to price
    /// @return pool the valuation pool, or address(0) when the vault has no price for it,
    ///         which makes a non-USDC deposit token entry-only: `withdraw` will not pay out
    ///         in it
    function valuationPoolOf(address token) external view returns (address pool);
}
