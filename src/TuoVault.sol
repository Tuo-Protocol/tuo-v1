// SPDX-License-Identifier: LicenseRef-BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {ITuoVault} from "./interfaces/ITuoVault.sol";
import {INonfungiblePositionManager} from "./interfaces/external/INonfungiblePositionManager.sol";
import {TuoPositionNFT} from "./TuoPositionNFT.sol";
import {TuoSwapRouter} from "./TuoSwapRouter.sol";
import {TuoVaultStorage} from "./TuoVaultStorage.sol";
import {TuoVaultAdmin} from "./TuoVaultAdmin.sol";
import {PerformanceFee} from "./libraries/PerformanceFee.sol";
import {PoolTwap} from "./libraries/PoolTwap.sol";
import {PositionValuation} from "./libraries/PositionValuation.sol";
import {TuoConstants} from "./libraries/TuoConstants.sol";
import {TuoRoles} from "./libraries/TuoRoles.sol";

/// @title TuoVault - custody vault for Tuo positions
/// @author Tuo Team
/// @notice See ITuoVault. Custody invariants this implementation upholds:
///         Every asset in the vault is attributed to exactly one position (per-NFT
///         idle balances + per-NFT LP token registry).
contract TuoVault is TuoVaultAdmin, IERC721Receiver {
    using SafeERC20 for IERC20;

    /// @notice Deploy the vault, its position NFT and its swap router in one transaction,
    ///         so there is no post-deploy configuration window in which the contracts are
    ///         live but not yet wired.
    /// @dev DEFAULT_ADMIN_ROLE is deliberately never granted; TREASURY_ROLE administers
    ///      itself, KEEPER_ROLE and PAUSER_ROLE. Every allowlisted pool must pair its
    ///      token with USDC.
    /// @param cfg the deployment configuration; see {InitConfig}
    constructor(InitConfig memory cfg) TuoVaultStorage(cfg.usdc, cfg.weth, cfg.positionManager) {
        if (
            cfg.usdc == address(0) || cfg.weth == address(0) || cfg.positionManager == address(0)
                || cfg.treasury == address(0) || cfg.keeper == address(0) || cfg.pauser == address(0)
        ) revert ZeroAddress();

        NFT = new TuoPositionNFT(cfg.nftBaseURI);
        SWAP_ROUTER = new TuoSwapRouter(cfg.aggregators);

        // Seeded here rather than left for a post-deploy call: the vault must never be
        // live with an empty operator set, or the first hedge would revert. It follows the
        // two deployments above so {_setHlOperator}'s protocol-owned check reads their real
        // addresses rather than zero: a seed can name one as readily as a later call can,
        // both being CREATE-derived and predictable before the fact. The loop performs no
        // CREATE, so its place does not move either address.
        if (cfg.hlOperators.length == 0) revert ZeroAddress();
        for (uint256 i = 0; i < cfg.hlOperators.length; i++) {
            _setHlOperator(cfg.hlOperators[i], true);
        }

        // Roles: treasury administers, the keeper, and the pauser.
        _setRoleAdmin(TuoRoles.TREASURY_ROLE, TuoRoles.TREASURY_ROLE);
        _setRoleAdmin(TuoRoles.KEEPER_ROLE, TuoRoles.TREASURY_ROLE);
        _setRoleAdmin(TuoRoles.PAUSER_ROLE, TuoRoles.TREASURY_ROLE);
        _grantRole(TuoRoles.TREASURY_ROLE, cfg.treasury);
        _grantRole(TuoRoles.KEEPER_ROLE, cfg.keeper);
        _grantRole(TuoRoles.PAUSER_ROLE, cfg.pauser);
        // The one payee the constructor writes without going through {setFeeRecipient},
        // and so without its refusal. Checked here too: the treasury also takes the role
        // that would fix it, so a protocol-owned value leaves nothing able to reach the
        // setter afterwards.
        _requireNotProtocolOwned(cfg.treasury);
        feeRecipient = cfg.treasury;

        // Pool allowlist is deployment-fixed: every pool must pair its token with
        // USDC; the first pool listed for a token becomes its valuation pool.
        for (uint256 i = 0; i < cfg.pools.length; i++) {
            address pool = cfg.pools[i];
            address token0 = IUniswapV3Pool(pool).token0();
            address token1 = IUniswapV3Pool(pool).token1();
            address other;
            if (token0 == cfg.usdc) other = token1;
            else if (token1 == cfg.usdc) other = token0;
            else revert PoolNotAllowlisted(pool);
            // A pool whose observation ring cannot span TWAP_WINDOW answers no valuation
            // at all.
            (,,,, uint16 cardinalityNext,,) = IUniswapV3Pool(pool).slot0();
            if (cardinalityNext < TuoConstants.MIN_OBSERVATION_CARDINALITY) {
                revert PoolOracleTooShallow(pool, cardinalityNext);
            }
            _allowedPools[pool] = true;
            bool isValuationPool = _valuationPools[other] == address(0);
            if (isValuationPool) {
                _valuationPools[other] = pool;
                _poolTokens.push(other);
            }
            // Every entry, not only the ones that won valuation: a repeat for a token
            // already registered is still allowlisted and still mintable, and nothing
            // else on chain reports it.
            emit PoolRegistered(pool, other, isValuationPool);
        }

        for (uint256 i = 0; i < cfg.products.length; i++) {
            ProductInit memory product = cfg.products[i];
            _registerProduct(product.code, product.label, product.maxHedgeBps, product.maxLpCount);
        }

        _depositTokens[cfg.usdc] = true;
        _depositTokens[cfg.weth] = true;
        for (uint256 i = 0; i < cfg.depositTokens.length; i++) {
            if (cfg.depositTokens[i] == address(0)) revert ZeroAddress();
            _depositTokens[cfg.depositTokens[i]] = true;
        }

        if (cfg.perNftCapUsdc == 0) revert InvalidCap();
        perNftCapUsdc = cfg.perNftCapUsdc;
        _setKeeperSwapSlippageBps(cfg.keeperSwapSlippageBps);
    }

    // ---------------------------------------------------------------------
    // Customer functions (NFT owner)
    // ---------------------------------------------------------------------

    /// @inheritdoc ITuoVault
    function deposit(
        address token,
        uint256 amount,
        uint16 productCode,
        uint256 minUsdcOut,
        bytes calldata swapData,
        uint256 existingNftId
    ) external payable nonReentrant returns (uint256 nftId) {
        if (paused()) revert DepositsArePaused();
        if (amount == 0) revert ZeroAmount();

        address tokenIn = token;
        if (token == address(0)) {
            if (msg.value != amount) revert NativeAmountMismatch();
            WETH.deposit{value: amount}();
            tokenIn = address(WETH);
        } else {
            if (msg.value != 0) revert NativeAmountMismatch();
            if (!_depositTokens[token]) revert DepositTokenNotAllowed(token);
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        uint256 credited;
        if (tokenIn == address(USDC)) {
            credited = amount;
        } else {
            credited = _routeSwap(tokenIn, address(USDC), amount, minUsdcOut, swapData);
        }
        if (credited < TuoConstants.MIN_DEPOSIT_USDC) {
            revert BelowMinDeposit(credited);
        }

        if (existingNftId == 0) {
            // Code 0 has no label by construction, so the top-up sentinel can never open
            // a position.
            Product storage product = _products[productCode];
            if (product.label == bytes32(0)) {
                revert InvalidProductCode(productCode);
            }
            if (!product.openForDeposits) {
                revert ProductClosedForDeposits(productCode);
            }
            if (credited > perNftCapUsdc) revert PerNftCapExceeded();

            nftId = nextNftId++;
            Position storage p = _positions[nftId];
            p.productCode = productCode;
            p.active = true;
            p.createdAt = uint40(block.timestamp);
            p.basisUsdc = credited;

            _idle[nftId][address(USDC)] += credited;

            NFT.mint(msg.sender, nftId);
            emit PositionOpened(nftId, msg.sender, productCode, token, amount, credited);
        } else {
            nftId = existingNftId;
            Position storage p = _activePosition(nftId);
            if (NFT.ownerOf(nftId) != msg.sender) revert NotPositionOwner();
            _revertIfWithdrawalPending(p);
            if (productCode != 0 && productCode != p.productCode) {
                revert ProductCodeMismatch();
            }
            uint256 newBasis = p.basisUsdc + credited;
            if (newBasis > perNftCapUsdc) revert PerNftCapExceeded();

            p.basisUsdc = newBasis;
            _idle[nftId][address(USDC)] += credited;

            emit PositionToppedUp(nftId, token, amount, credited, newBasis);
        }
    }

    /// @inheritdoc ITuoVault
    function requestWithdraw(uint256 nftId, uint16 sharesBps) external nonReentrant {
        Position storage p = _activePosition(nftId);
        if (NFT.ownerOf(nftId) != msg.sender) revert NotPositionOwner();
        if (sharesBps > TuoConstants.BPS_DENOMINATOR) {
            revert InvalidSharesBps(sharesBps);
        }

        // Zero is the cancellation, and a nonzero value restates a pending request in
        // place. One entry point owns the whole request state, so there is no second
        // function whose preconditions have to agree with this one's. Restating resets
        // the emergency-withdraw clock, exactly as cancel-then-request did.
        p.withdrawalRequestedAt = sharesBps == 0 ? 0 : uint40(block.timestamp);
        p.withdrawalSharesBps = sharesBps;
        emit WithdrawalRequested(nftId, sharesBps);
    }

    /// @inheritdoc ITuoVault
    function withdraw(uint256 nftId, address withdrawalToken, uint256 minTokenOut, bytes calldata swapData)
        external
        nonReentrant
        returns (uint256 tokenAmountOut)
    {
        Position storage p = _activePosition(nftId);
        if (NFT.ownerOf(nftId) != msg.sender) revert NotPositionOwner();
        if (p.withdrawalRequestedAt == 0) revert WithdrawalNotRequested();

        uint16 sharesBps = p.withdrawalSharesBps;
        bool closing = sharesBps == TuoConstants.BPS_DENOMINATOR;
        if (closing && p.lpTokenIds.length != 0) revert LpsOutstanding();
        uint256 nav = _settlementNav(nftId);
        (uint256 grossUsdc, uint256 feeUsdc, uint256 netUsdc) = PerformanceFee.quote(p.basisUsdc, nav, sharesBps);

        _debitIdle(nftId, address(USDC), grossUsdc);

        uint256 newBasis = PerformanceFee.reducedBasis(p.basisUsdc, sharesBps);
        p.basisUsdc = newBasis;
        _reduceKeeperLoss(nftId, sharesBps);
        _clearWithdrawRequest(p);
        _accrueFee(nftId, address(USDC), feeUsdc);

        if (closing) {
            p.active = false;
            _burnPosition(nftId);
            // The debit took the whole settlement NAV, so a pool-token balance left here is
            // one the mean tick values at zero: it goes back in kind and owes no fee.
            _payPoolTokensInKind(nftId, 0, 0);
        }

        if (withdrawalToken == address(USDC)) {
            tokenAmountOut = netUsdc;
            USDC.safeTransfer(msg.sender, netUsdc);
        } else {
            if (!_depositTokens[withdrawalToken]) {
                revert DepositTokenNotAllowed(withdrawalToken);
            }
            // A vault-derived floor at EXIT_FLOOR_BPS, not the keeper's tolerance. The owner
            // supplies `minTokenOut`, but a bad frontend supplying zero should not be able to
            // hand the exit swap away; whichever bound is tighter wins.
            uint256 exitFloor = _exitFloor(withdrawalToken, netUsdc);
            uint256 effectiveMin = minTokenOut > exitFloor ? minTokenOut : exitFloor;
            tokenAmountOut = _routeSwap(address(USDC), withdrawalToken, netUsdc, effectiveMin, swapData);
            IERC20(withdrawalToken).safeTransfer(msg.sender, tokenAmountOut);
        }

        emit PositionWithdrawn(nftId, sharesBps, grossUsdc, feeUsdc, netUsdc, withdrawalToken, tokenAmountOut, newBasis);
    }

    /// @inheritdoc ITuoVault
    function emergencyWithdraw(uint256 nftId) external nonReentrant {
        Position storage p = _activePosition(nftId);
        if (NFT.ownerOf(nftId) != msg.sender) revert NotPositionOwner();
        // Keyed on the lifecycle, not on the nominal margin: a non-final return can repay
        // `hlMarginBridged` while value is still at the venue, and that state needs the
        // request, the delay and the claim exactly as much as an unpaid nominal does.
        bool open = p.hlLifecycleOpen;
        if (open) {
            if (p.withdrawalRequestedAt == 0) revert WithdrawalNotRequested();
            if (block.timestamp < p.withdrawalRequestedAt + TuoConstants.EMERGENCY_WITHDRAW_DELAY) {
                revert EmergencyDelayNotElapsed();
            }
        }

        p.active = false;

        // Recover every open LP with no value floor and no TWAP gate: the exit must work
        // under any market condition, and the caller recovers only their own funds
        // in-kind. A floor here would let a bad market block the guaranteed door.
        uint256[] storage lps = p.lpTokenIds;
        while (lps.length != 0) {
            _closeLp(nftId, lps[lps.length - 1], 0, 0);
        }

        // Only profit already certain is charged: on-chain NAV against the FULL basis. The
        // hedge leg is unresolved and may come back above or below what was bridged, so a
        // claim retains the basis, the exit NAV and this fee for settleHlClaim to charge the
        // rest on cumulative realized value.
        (uint256 feeUsdc, uint256 navOnchain) = _emergencyFee(nftId, p.basisUsdc);

        uint256 bridged = p.hlMarginBridged;
        p.hlMarginBridged = 0;
        if (!open) {
            p.basisUsdc = 0;
        } else {
            // The principal may be zero; the lifecycle staying open is what keeps the claim.
            p.hlClaimUsdc = bridged;
            p.hlClaimExitNavUsdc = navOnchain;
            p.hlClaimFeeChargedUsdc = feeUsdc;
        }
        _reduceKeeperLoss(nftId, TuoConstants.BPS_DENOMINATOR);
        _clearWithdrawRequest(p);

        _payIdleInKind(nftId, address(USDC), msg.sender, feeUsdc, navOnchain);
        _payPoolTokensInKind(nftId, feeUsdc, navOnchain);

        emit EmergencyWithdrawn(nftId, feeUsdc, bridged);
        if (!open) _burnPosition(nftId);
    }

    /// @inheritdoc ITuoVault
    function finalizeHlClaim(uint256 nftId) external nonReentrant {
        Position storage p = _claimedPosition(nftId);
        if (NFT.ownerOf(nftId) != msg.sender) revert NotPositionOwner();

        uint256 principal = p.hlClaimUsdc;
        uint256 returned = p.hlClaimReturnedUsdc;
        uint256 shortfall = principal > returned ? principal - returned : 0;

        p.hlClaimUsdc = 0;
        p.hlClaimReturnedUsdc = 0;
        p.hlClaimExitNavUsdc = 0;
        p.hlClaimFeeChargedUsdc = 0;
        p.basisUsdc = 0;
        p.hlLifecycleOpen = false;

        emit HlClaimFinalized(nftId, shortfall);
        _burnPosition(nftId);
    }

    // ---------------------------------------------------------------------
    // Keeper functions (KEEPER_ROLE)
    // ---------------------------------------------------------------------

    /// @inheritdoc ITuoVault
    function swapIdle(
        uint256 nftId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata swapData
    ) external onlyRole(TuoRoles.KEEPER_ROLE) nonReentrant returns (uint256 amountOut) {
        Position storage p = _activePosition(nftId);
        if (tokenIn == address(USDC)) _revertIfWithdrawalPending(p);
        _consumeKeeperAction(nftId);
        if (amountIn == 0) revert ZeroAmount();

        // Only USDC <-> allowlisted-pool-token legs exist. One oracle read gives the
        // deviation gate, the vault's own slippage floor, and the two ticks the loss
        // budget below measures the leg at.
        (uint256 twapFloor, int24 meanTick, int24 spotTick) = _twapLeg(tokenIn, tokenOut, amountIn);
        uint256 effectiveMin = minAmountOut > twapFloor ? minAmountOut : twapFloor;

        _debitIdle(nftId, tokenIn, amountIn);

        amountOut = _routeSwap(tokenIn, tokenOut, amountIn, effectiveMin, swapData);
        _idle[nftId][tokenOut] += amountOut;
        emit IdleSwapped(nftId, tokenIn, tokenOut, amountIn, amountOut);

        // swapIdle and mintLp are the two metered actions with a value delta: bridgeToHl
        // is delta-zero by construction (custody NAV books bridged margin at par) and a
        // burn is non-negative.
        _chargeSwapLoss(nftId, tokenIn, tokenOut, amountIn, amountOut, meanTick, spotTick);
    }

    /// @inheritdoc ITuoVault
    function mintLp(
        uint256 nftId,
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external onlyRole(TuoRoles.KEEPER_ROLE) nonReentrant returns (uint256 lpTokenId, uint128 liquidity) {
        Position storage p = _activePosition(nftId);
        _revertIfWithdrawalPending(p);
        _consumeKeeperAction(nftId);
        if (!_allowedPools[pool]) revert PoolNotAllowlisted(pool);
        if (int256(tickUpper) - int256(tickLower) < TuoConstants.MIN_LP_TICK_WIDTH) {
            revert LpRangeTooNarrow(tickLower, tickUpper);
        }
        // The count must be capped: `emergencyWithdraw` closes every LP in one
        // transaction, so unbounded dust-LP spam could push the customer's guaranteed
        // exit past the block gas ceiling.
        uint8 maxLpCount = _products[p.productCode].maxLpCount;
        if (p.lpTokenIds.length >= maxLpCount) {
            revert LpCountExceeded(nftId, maxLpCount);
        }
        int24 meanTick = PoolTwap.checkDeviationAndMeanTick(pool);

        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();

        _debitIdle(nftId, token0, amount0Desired);
        _debitIdle(nftId, token1, amount1Desired);

        IERC20(token0).forceApprove(address(POSITION_MANAGER), amount0Desired);
        IERC20(token1).forceApprove(address(POSITION_MANAGER), amount1Desired);

        uint256 amount0;
        uint256 amount1;
        (lpTokenId, liquidity, amount0, amount1) = POSITION_MANAGER.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: IUniswapV3Pool(pool).fee(),
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                // Zero per-leg minimums by design: the deviation gate above and the loss
                // charge below bound the mint. ITuoVault.mintLp carries the argument.
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                // Deliberately a no-op: there is nothing on-chain to derive a deadline
                // from, and checkDeviationAndMeanTick above is a stronger staleness gate -
                // it requires spot within MAX_TWAP_DEVIATION_TICKS of the 30-minute
                // mean AT INCLUSION, so a transaction delayed into a moved market fails
                // and one delayed into an unmoved market is harmless.
                deadline: block.timestamp
            })
        );

        IERC20(token0).forceApprove(address(POSITION_MANAGER), 0);
        IERC20(token1).forceApprove(address(POSITION_MANAGER), 0);

        // Credit back what the mint did not consume.
        _idle[nftId][token0] += amount0Desired - amount0;
        _idle[nftId][token1] += amount1Desired - amount1;

        lpOwnerOf[lpTokenId] = nftId;
        lpPoolOf[lpTokenId] = pool;
        p.lpTokenIds.push(lpTokenId);

        emit LpMinted(nftId, lpTokenId, pool, tickLower, tickUpper, liquidity, amount0, amount1);

        // The pool fixed the composition at spot; the vault values it at the mean. The gap,
        // up to ~1% at the band edge on the narrowest one-sided range, is the keeper's. Mean
        // only, unlike swapIdle: at spot the composition is exact, so that gap is zero.
        _chargeKeeperLoss(
            nftId,
            PositionValuation.pairValueUsdcAtTick(meanTick, token0, token1, amount0, amount1, address(USDC)),
            PositionValuation.liquidityValueUsdcAtTick(
                meanTick, token0, token1, tickLower, tickUpper, liquidity, address(USDC)
            )
        );
    }

    /// @inheritdoc ITuoVault
    function burnLp(uint256 nftId, uint256 lpTokenId)
        external
        onlyRole(TuoRoles.KEEPER_ROLE)
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _activePosition(nftId);
        _consumeKeeperAction(nftId);
        if (lpOwnerOf[lpTokenId] != nftId) {
            revert LpNotOwnedByPosition(nftId, lpTokenId);
        }

        address pool = lpPoolOf[lpTokenId];
        int24 meanTick = PoolTwap.checkDeviationAndMeanTick(pool);

        // What the position is worth at the mean tick, as ONE number: the floor is on
        // the COMBINED value of both legs. TuoConstants.LP_BURN_VALUE_FLOOR_BPS explains
        // why per-leg floors cannot express the constraint.
        (,, address token0, address token1,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            POSITION_MANAGER.positions(lpTokenId);
        uint256 floorUsdc = FullMath.mulDivRoundingUp(
            PositionValuation.liquidityValueUsdcAtTick(
                meanTick, token0, token1, tickLower, tickUpper, liquidity, address(USDC)
            ),
            TuoConstants.LP_BURN_VALUE_FLOOR_BPS,
            TuoConstants.BPS_DENOMINATOR
        );

        (amount0, amount1) = _closeLp(nftId, lpTokenId, meanTick, floorUsdc);
    }

    /// @inheritdoc ITuoVault
    function bridgeToHl(uint256 nftId, uint256 amountUsdc, address operator)
        external
        onlyRole(TuoRoles.KEEPER_ROLE)
        nonReentrant
    {
        Position storage p = _activePosition(nftId);
        _consumeKeeperAction(nftId);

        // The destination is caller-supplied but not caller-chosen: it must be on the
        // treasury's allowlist and, after the first bridge, the same operator every time.
        // One operator serves one position for life: the inbound legs credit whatever the
        // bound operator hands back, so a shared operator would let one position's margin
        // be credited to another.
        if (!isHlOperator[operator]) revert HlOperatorNotAllowlisted(operator);
        bool binding = p.hlOperator == address(0);
        if (binding) {
            uint256 boundNftId = hlOperatorPositionOf[operator];
            if (boundNftId != 0) revert HlOperatorAlreadyBound(operator, boundNftId, nftId);
        } else if (p.hlOperator != operator) {
            revert HlOperatorMismatch(nftId, p.hlOperator, operator);
        }

        // Reject bridge operations below the absolute operational minimum. Any successful
        // bridge intentionally activates the outstanding-margin rules. Bridging is blocked
        // while a withdrawal is pending, and the hedge cap bounds the total outbound.
        if (amountUsdc < TuoConstants.MIN_HL_BRIDGE_USDC) {
            revert BelowMinHlBridge(amountUsdc);
        }
        _revertIfWithdrawalPending(p);
        uint256 hedgeCap = (p.basisUsdc * _products[p.productCode].maxHedgeBps) / TuoConstants.BPS_DENOMINATOR;
        uint256 hedgeAfter = p.hlMarginBridged + amountUsdc;
        if (hedgeAfter > hedgeCap) {
            revert HedgeCapExceeded(nftId, hedgeAfter, hedgeCap);
        }

        // The binding is for life, so it is written only once every guard above has passed.
        // The `_debitIdle` below can still revert InsufficientIdle, which undoes it atomically.
        if (binding) {
            hlOperatorPositionOf[operator] = nftId;
            p.hlOperator = operator;
        }
        _debitIdle(nftId, address(USDC), amountUsdc);
        p.hlMarginBridged = hedgeAfter;
        p.hlLifecycleOpen = true;

        USDC.safeTransfer(operator, amountUsdc);
        emit HlBridgeOutbound(nftId, operator, amountUsdc);
    }

    /// @inheritdoc ITuoVault
    function markBridgeInboundComplete(uint256 nftId, uint256 amountReturnedUsdc, bool finalReturn)
        external
        onlyRole(TuoRoles.KEEPER_ROLE)
        nonReentrant
    {
        Position storage p = _activePosition(nftId);
        // A write-off pulls nothing, so zero is only meaningful as a final return.
        if (amountReturnedUsdc == 0 && !finalReturn) revert ZeroAmount();
        // An armed request is what makes the attestation safe: bridgeToHl reverts while
        // one is pending, so the margin cannot grow between the sweep and this credit.
        if (finalReturn && p.withdrawalRequestedAt == 0) revert WithdrawalNotRequested();

        address operator = _boundHlOperator(p, nftId);
        uint256 bridged = p.hlMarginBridged;
        _idle[nftId][address(USDC)] += amountReturnedUsdc;
        // Reaching the nominal proves nothing about the venue, so only the attestation
        // closes the lifecycle; a non-final return reduces the nominal and no more.
        if (finalReturn) {
            p.hlMarginBridged = 0;
            p.hlLifecycleOpen = false;
        } else {
            p.hlMarginBridged = amountReturnedUsdc >= bridged ? 0 : bridged - amountReturnedUsdc;
        }

        // Checks-Effects-Interactions: the attribution is rewritten before the pull.
        USDC.safeTransferFrom(operator, address(this), amountReturnedUsdc);
        emit HlBridgeInboundCompleted(nftId, amountReturnedUsdc, finalReturn);
    }

    /// @inheritdoc ITuoVault
    function settleHlClaim(uint256 nftId, uint256 amountUsdc) external onlyRole(TuoRoles.KEEPER_ROLE) nonReentrant {
        if (amountUsdc == 0) revert ZeroAmount();
        Position storage p = _claimedPosition(nftId);
        address operator = _boundHlOperator(p, nftId);
        address owner = NFT.ownerOf(nftId);

        // The fee already charged always equals the fee owed on the value realized so far
        // (the exit charged exactly that, and every return tops it up), so the delta here is
        // at most 30% of this return and the net can never underflow.
        uint256 returned = p.hlClaimReturnedUsdc + amountUsdc;
        uint256 owedUsdc = _claimFee(p.basisUsdc, p.hlClaimExitNavUsdc + returned);
        uint256 chargedUsdc = p.hlClaimFeeChargedUsdc;
        uint256 feeUsdc = owedUsdc > chargedUsdc ? owedUsdc - chargedUsdc : 0;
        uint256 netUsdc = amountUsdc - feeUsdc;

        p.hlClaimReturnedUsdc = returned;
        p.hlClaimFeeChargedUsdc = chargedUsdc + feeUsdc;
        _accrueFee(nftId, address(USDC), feeUsdc);

        // Routed through the vault, never operator-to-owner: the fee has to come out of it.
        USDC.safeTransferFrom(operator, address(this), amountUsdc);
        USDC.safeTransfer(owner, netUsdc);
        emit HlClaimSettled(nftId, amountUsdc, feeUsdc, netUsdc);
    }

    // ---------------------------------------------------------------------
    // ERC-721 receiver / roles
    // ---------------------------------------------------------------------

    /// @notice Accept LP token custody from the Uniswap NonfungiblePositionManager.
    /// @dev NPM safe-transfer compatibility. Parameters are intentionally unnamed: the
    ///      vault mints its own LPs, so nothing here is inspected.
    /// @return selector the ERC-721 receiver magic value
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Renounce a role. TREASURY_ROLE cannot be renounced.
    /// @dev TREASURY_ROLE administers every role and DEFAULT_ADMIN_ROLE is never
    ///      granted, so the last treasury holder renouncing would irreversibly leave
    ///      nobody able to grant or revoke a role again - in particular, a compromised
    ///      keeper could never be revoked. {revokeRole} closes the same door for a
    ///      self-revoke, so the set of treasury holders can never reach zero. Treasury
    ///      rotation goes grant-then-revoke through the Safe, the NEW holder revoking the
    ///      old one. Declared `public` rather than `external` because it overrides
    ///      OpenZeppelin's `public virtual`.
    /// @param role the role to give up
    /// @param callerConfirmation must equal `msg.sender`; a role can only be renounced by
    ///        its own holder
    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == TuoRoles.TREASURY_ROLE) {
            revert TreasuryRoleIsNotRenounceable();
        }
        super.renounceRole(role, callerConfirmation);
    }

    /// @notice Revoke a role. A treasury holder cannot revoke its own TREASURY_ROLE.
    /// @dev A self-revoke is {renounceRole} spelled through the other entry point, so it
    ///      gets the same block. Revoking another holder stays open because rotation needs
    ///      it, and the caller keeps its own role, so at least one holder always remains.
    /// @param role the role to revoke
    /// @param account the holder to revoke it from; not `msg.sender` for TREASURY_ROLE
    function revokeRole(bytes32 role, address account) public override {
        if (role == TuoRoles.TREASURY_ROLE && account == msg.sender) {
            revert TreasuryRoleIsNotRenounceable();
        }
        super.revokeRole(role, account);
    }

    // ---------------------------------------------------------------------
    // Internal flow helpers (state-mutating)
    // ---------------------------------------------------------------------

    function _burnPosition(uint256 nftId) internal {
        NFT.burn(nftId);
        emit PositionBurned(nftId);
    }

    function _clearWithdrawRequest(Position storage p) internal {
        p.withdrawalRequestedAt = 0;
        p.withdrawalSharesBps = 0;
    }

    /// @dev A payout is quoted on NAV but funded from idle USDC alone, so an armed request
    ///      freezes bridges, USDC-selling swaps and every mint, even one funded from pool
    ///      tokens alone: each moves value away from idle USDC or from a sale into it. Top-ups
    ///      are frozen too, so no capital is added under an armed request.
    function _revertIfWithdrawalPending(Position storage p) internal view {
        if (p.withdrawalRequestedAt != 0) revert WithdrawalRequestPending();
    }

    /// @dev Charge one metered keeper action against the action bucket. Runs at the TOP
    ///      of every metered call, so the cheap early-out is preserved; the value half of
    ///      the budget is charged separately at the bottom, where the delta is known.
    function _consumeKeeperAction(uint256 nftId) internal {
        KeeperBudget storage b = _keeperBudget[nftId];
        (uint256 units, uint256 loss) = _decayedBudget(b);
        units += TuoConstants.KEEPER_ACTION_UNIT;
        if (units > TuoConstants.MAX_KEEPER_ACTION_UNITS) {
            revert KeeperRateLimitExceeded(nftId);
        }
        b.updatedAt = uint40(block.timestamp);
        // Bounded by MAX_KEEPER_ACTION_UNITS (1e7) and by the value already stored.
        // forge-lint: disable-next-line(unsafe-typecast)
        b.actionUnits = uint56(units);
        // forge-lint: disable-next-line(unsafe-typecast)
        b.lossUsdc = uint96(loss);
    }

    /// @dev Charge measured value loss against the loss bucket. The measurement is a
    ///      per-action-local delta against custody NAV (idle + open LPs + bridged margin
    ///      at par + open claims), not `_settlementNav`: settlement reverts while
    ///      hedged, a bridge would otherwise read as a 100% loss, and every untouched
    ///      leg cancels in the local difference anyway. Hyperliquid-side loss is
    ///      deliberately outside this budget - the vault cannot measure a position on
    ///      another venue - and is bounded by the product's `maxHedgeBps` instead.
    function _chargeKeeperLoss(uint256 nftId, uint256 beforeUsdc, uint256 afterUsdc) internal {
        if (afterUsdc >= beforeUsdc) return; // gains and no-ops are free
        uint256 lossThis = beforeUsdc - afterUsdc;
        KeeperBudget storage b = _keeperBudget[nftId];
        // Already decayed by _consumeKeeperAction at the top of this same call.
        uint256 loss = uint256(b.lossUsdc) + lossThis;
        uint256 ceiling = _keeperLossCeiling(nftId);
        if (loss > ceiling) {
            revert KeeperLossBudgetExceeded(nftId, loss, ceiling);
        }

        // Checked, unlike the raw casts in _consumeKeeperAction and _reduceKeeperLoss: this
        // value carries a fresh delta and is bounded by the ceiling, not by a stored uint96.
        b.lossUsdc = SafeCast.toUint96(loss);
        emit KeeperLossCharged(nftId, lossThis, loss, ceiling);
    }

    /// @dev Value a swap leg's input and output at the mean tick as one pair and at the
    ///      gated spot tick as another, never an input at one tick against an output at
    ///      the other, and charge the larger loss. A manipulated spot cannot erase a
    ///      mean-measured loss, and a fill at a stale mean is charged what it gives up
    ///      against spot, which the deviation gate alone licenses up to ~2%.
    function _chargeSwapLoss(
        uint256 nftId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        int24 meanTick,
        int24 spotTick
    ) internal {
        uint256 meanValueIn = _valueUsdcAtTick(meanTick, tokenIn, amountIn);
        uint256 meanValueOut = _valueUsdcAtTick(meanTick, tokenOut, amountOut);
        uint256 spotValueIn = _valueUsdcAtTick(spotTick, tokenIn, amountIn);
        uint256 spotValueOut = _valueUsdcAtTick(spotTick, tokenOut, amountOut);
        uint256 meanLoss = meanValueIn > meanValueOut ? meanValueIn - meanValueOut : 0;
        uint256 spotLoss = spotValueIn > spotValueOut ? spotValueIn - spotValueOut : 0;
        if (spotLoss > meanLoss) {
            _chargeKeeperLoss(nftId, spotValueIn, spotValueOut);
        } else {
            _chargeKeeperLoss(nftId, meanValueIn, meanValueOut);
        }
    }

    /// @dev Basis is the scale the loss ceiling is measured against, so a withdrawal
    ///      that reduces basis takes its pro-rata share of the charged loss with it -
    ///      otherwise a full exit would leave a charge standing against a zero ceiling
    ///      and the budget would read as permanently breached.
    function _reduceKeeperLoss(uint256 nftId, uint16 sharesBps) internal {
        KeeperBudget storage b = _keeperBudget[nftId];
        uint256 loss = b.lossUsdc;
        if (loss == 0) return;
        // Bounded above by the value already stored.
        // forge-lint: disable-next-line(unsafe-typecast)
        b.lossUsdc = uint96(loss - (loss * sharesBps) / TuoConstants.BPS_DENOMINATOR);
    }

    /// @dev Book a performance fee into the claimable pool for `token`. The caller has
    ///      already taken the amount out of idle accounting, or, in settleHlClaim, withholds
    ///      it from a return that never enters idle. Nothing moves until the treasury claims.
    function _accrueFee(uint256 nftId, address token, uint256 amount) internal {
        if (amount == 0) return;
        uint256 total = accruedTokenFees[token] + amount;
        accruedTokenFees[token] = total;
        // Two events rather than one with a `token` field: the USDC accrual is what every
        // settlement withdrawal emits and what the indexer already projects, so it keeps
        // its exact shape and in-kind withholding arrives as new information.
        if (token == address(USDC)) emit FeesAccrued(nftId, amount, total);
        else emit TokenFeesAccrued(nftId, token, amount, total);
    }

    /// @dev The emergency exit's fee, as a USDC amount alongside the on-chain NAV it was
    ///      measured against; the pair is what lets each leg be charged pro rata without a
    ///      second valuation. Returns (0, 0) when a pool oracle cannot answer.
    ///
    ///      The `try` is the point: `_closeLp` is deliberately given a zero floor so the
    ///      unwind cannot be gated by market conditions, and a bare `_idleValueUsdc` one
    ///      line later put the same oracle dependency straight back - a pool whose
    ///      observation ring cannot span TWAP_WINDOW would revert the whole exit and lock
    ///      the position. Forgoing the fee is the correct trade against locking a customer
    ///      out; this is the guaranteed door, and it must not need a price to open. A claim
    ///      then records a zero exit NAV, so later returns can only ever be undercharged.
    ///
    ///      Accepted residual, disclosed rather than fixed: `nav` is measured at each pool's
    ///      30-minute mean tick with no comparison against spot, while `_payIdleInKind`
    ///      hands the owner tokens the market prices at spot. The fee is therefore 30% of
    ///      mean-measured profit, not 30% of what the exit realizes. A crash charges against
    ///      profit that has already gone; a run-up charges against profit the mean has not
    ///      caught up to, and a mean that has not moved at all reads the position at its
    ///      basis and charges nothing. Gating this read on the deviation band was considered
    ///      and rejected: it would hand the owner a fee waiver purchasable with a single
    ///      atomic displacement of the thinnest pool the position holds a balance in.
    function _emergencyFee(uint256 nftId, uint256 basis) internal view returns (uint256 fee, uint256 nav) {
        try this.idleValueUsdc(nftId) returns (uint256 navOnchain) {
            return (_claimFee(basis, navOnchain), navOnchain);
        } catch {
            return (0, 0);
        }
    }

    /// @dev 30% of realized value over basis, zero when under. The one formula behind the
    ///      exit fee and every claim return, which is what makes "charged so far" equal
    ///      "owed on value realized so far" at every step of a claim's life.
    function _claimFee(uint256 basis, uint256 realized) internal pure returns (uint256) {
        if (realized <= basis) return 0;
        return ((realized - basis) * TuoConstants.PERFORMANCE_FEE_BPS) / TuoConstants.BPS_DENOMINATOR;
    }

    function _debitIdle(uint256 nftId, address token, uint256 amount) internal {
        uint256 available = _idle[nftId][token];
        if (available < amount) {
            revert InsufficientIdle(token, amount, available);
        }
        _idle[nftId][token] = available - amount;
    }

    /// @dev Decrease-all + collect + burn one LP token, crediting proceeds to idle.
    /// @param meanTick the TWAP tick the floor was derived from; the principal is valued at
    ///        the same tick. Unread when the floor is skipped.
    /// @param minPrincipalValueUsdc floor on the COMBINED USDC value of the principal the
    ///        unwind returns, valued at `meanTick`. A floor under
    ///        LP_BURN_FLOOR_MIN_VALUE_USDC disables the check: a dust `burnLp`, where
    ///        rounding alone can trip it, and the zero the customer's own
    ///        `emergencyWithdraw` passes, the path that must run under any market condition.
    ///        Per-leg floors are deliberately left at zero even when this one is set -
    ///        they cannot express the constraint and would only make the weaker bound
    ///        bind first.
    function _closeLp(uint256 nftId, uint256 lpTokenId, int24 meanTick, uint256 minPrincipalValueUsdc)
        internal
        returns (uint256 total0, uint256 total1)
    {
        (,, address token0, address token1,,,, uint128 liquidity,,,,) = POSITION_MANAGER.positions(lpTokenId);

        uint256 principal0;
        uint256 principal1;
        if (liquidity != 0) {
            // Zero per-leg minimums and a no-op deadline by design: the combined floor below
            // is the bound (see the parameter note) and mintLp's call site covers the deadline.
            (principal0, principal1) = POSITION_MANAGER.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: lpTokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                })
            );
        }
        if (minPrincipalValueUsdc >= TuoConstants.LP_BURN_FLOOR_MIN_VALUE_USDC) {
            uint256 valueUsdc =
                PositionValuation.pairValueUsdcAtTick(meanTick, token0, token1, principal0, principal1, address(USDC));
            if (valueUsdc < minPrincipalValueUsdc) {
                revert LpValueBelowFloor(valueUsdc, minPrincipalValueUsdc);
            }
        }
        (total0, total1) = POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: lpTokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        POSITION_MANAGER.burn(lpTokenId);

        _idle[nftId][token0] += total0;
        _idle[nftId][token1] += total1;

        _removeLpToken(nftId, lpTokenId);
        emit LpBurned(nftId, lpTokenId, principal0, principal1, total0 - principal0, total1 - principal1);
    }

    function _removeLpToken(uint256 nftId, uint256 lpTokenId) internal {
        uint256[] storage ids = _positions[nftId].lpTokenIds;
        // Safe to cache across the `pop`: the only branch that shortens `ids` breaks out of
        // the loop, so the stale length is never used as a bound or an index afterwards.
        uint256 count = ids.length;
        for (uint256 i = 0; i < count; i++) {
            if (ids[i] == lpTokenId) {
                ids[i] = ids[count - 1];
                ids.pop();
                break;
            }
        }
        delete lpOwnerOf[lpTokenId];
        delete lpPoolOf[lpTokenId];
    }

    /// @dev Approve + execute an aggregator swap through the vault-only router.
    ///      `swapData` = abi.encode(address aggregator, bytes callData).
    function _routeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata swapData
    ) internal returns (uint256 amountOut) {
        (address aggregator, bytes memory callData) = abi.decode(swapData, (address, bytes));
        IERC20(tokenIn).forceApprove(address(SWAP_ROUTER), amountIn);
        amountOut = SWAP_ROUTER.swap(aggregator, tokenIn, tokenOut, amountIn, minAmountOut, callData);
        IERC20(tokenIn).forceApprove(address(SWAP_ROUTER), 0);
    }

    /// @dev Every pool-token leg of `_payIdleInKind`, paid to the caller.
    function _payPoolTokensInKind(uint256 nftId, uint256 feeUsdc, uint256 navUsdc) internal {
        uint256 poolTokenCount = _poolTokens.length;
        for (uint256 i = 0; i < poolTokenCount; i++) {
            _payIdleInKind(nftId, _poolTokens[i], msg.sender, feeUsdc, navUsdc);
        }
    }

    /// @dev Pay one idle leg out in kind, withholding that leg's pro-rata share of
    ///      `feeUsdc` first. The share is `balance * feeUsdc / navUsdc` - one mul/div
    ///      against the NAV the fee was measured on, so the split is exact rather than
    ///      routed through a basis-point rate, and it floors in the owner's favour.
    ///      A zero `navUsdc` is the no-price case and charges nothing.
    ///
    ///      Exact against `navUsdc`, which is a mean-tick measurement: the owner is paid
    ///      tokens worth spot, so what the withholding costs them differs from `feeUsdc` by
    ///      the spot-to-mean gap. The division floors in their favour; the measurement does
    ///      not take a side. See {_emergencyFee}.
    function _payIdleInKind(uint256 nftId, address token, address to, uint256 feeUsdc, uint256 navUsdc) internal {
        uint256 balance = _idle[nftId][token];
        if (balance == 0) return;
        _idle[nftId][token] = 0;
        if (feeUsdc != 0) {
            uint256 fee = (balance * feeUsdc) / navUsdc;
            _accrueFee(nftId, token, fee);
            balance -= fee;
        }
        IERC20(token).safeTransfer(to, balance);
        emit EmergencyTokenPaid(nftId, token, balance);
    }
}
