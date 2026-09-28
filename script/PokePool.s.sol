// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3PoolDerivedState} from "@uniswap/v3-core/contracts/interfaces/pool/IUniswapV3PoolDerivedState.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {PoolTwap} from "../src/libraries/PoolTwap.sol";
import {TuoConstants} from "../src/libraries/TuoConstants.sol";
import {TestnetPoolPoker} from "./mocks/TestnetPoolPoker.sol";

/// @title PokePool - move one Uniswap V3 pool's spot price to a target tick
/// @notice The Sepolia pools are seeded at a fixed price and nothing keeps them in step with
///         the Hyperliquid mark the engine centres its LP band on. Once they drift apart the
///         keeper mints a single-sided position that earns no fee and hedges nothing. This
///         realigns a pool without the redeploy a fixture change would otherwise cost.
/// @dev TESTNET ONLY, chain-gated to Arbitrum Sepolia. `TestnetPoolPoker` pays the swap out of
///      its own balance, so this script approves nothing and holds nothing, and an empty pool
///      owes nothing at all. A realignment is a move past the vault's 200-tick band by
///      definition, so the band is reported, not enforced.
///      Both entry points take `--sig` arguments, which no other script here does, so the pool
///      and the tick land in shell history beside the transaction they produced.
contract PokePool is Script {
    /// @notice Everything the preflight resolved, so the poke itself reads as one call.
    /// @param pool the pool being moved
    /// @param poker the `TestnetPoolPoker` that will do the swap
    /// @param owedToken the token the pool is owed in this direction
    /// @param spotTick the pool's tick before the poke
    /// @param targetTick the tick asked for
    /// @param zeroForOne true when the target is below spot, so the pool is owed token0
    /// @param poolLiquidity in-range liquidity, which decides whether the swap costs anything
    /// @param pokerBalance the poker's balance of `owedToken`
    struct PokePlan {
        address pool;
        address poker;
        address owedToken;
        int24 spotTick;
        int24 targetTick;
        bool zeroForOne;
        uint128 poolLiquidity;
        uint256 pokerBalance;
    }

    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    /// @notice Move `pool` to `targetTick`, in one broadcast transaction.
    /// @dev `forge script` simulates before it sends, so the arrival assertion below blocks a
    ///      bad transaction rather than reporting on one already mined. Pass the arguments
    ///      after a single `--` (`--sig 'run(address,int24)' -- <pool> <tick>`): forge needs it
    ///      before a negative tick, and a second one becomes a third positional argument.
    /// @param pool the Uniswap V3 pool to move
    /// @param targetTick the tick to land on; it need NOT be spacing-aligned, because a pool
    ///        price is not a position boundary
    function run(address pool, int24 targetTick) external {
        PokePlan memory plan = _preflight(pool, _loadPoker(), targetTick);
        _reportPlan(plan);

        vm.broadcast();
        TestnetPoolPoker(plan.poker).pokeTo(IUniswapV3Pool(pool), targetTick);

        int24 spotAfter = _spotTick(IUniswapV3Pool(pool));
        _assertArrived(plan.spotTick, spotAfter, targetTick, plan.zeroForOne);

        console2.log("tick after:        ", int256(spotAfter));
        _reportOracle(IUniswapV3Pool(pool), spotAfter);
    }

    /// @notice Report a pool's price, its 30-minute mean, and whether the vault's gate is open.
    /// @dev Broadcasts nothing. Run it before a poke to see where a pool stands, and after one
    ///      to see when the keeper can act again.
    /// @param pool the Uniswap V3 pool to inspect
    function check(address pool) external view {
        require(block.chainid == ARBITRUM_SEPOLIA, "PokePool: wrong chain");
        require(pool.code.length != 0, "PokePool: pool has no code");

        IUniswapV3Pool target = IUniswapV3Pool(pool);
        console2.log("chain id / caller: %s / %s", block.chainid, msg.sender);
        console2.log("pool:              ", pool);
        console2.log("token0 / token1:   %s / %s", target.token0(), target.token1());
        console2.log("tick spacing:      ", int256(target.tickSpacing()));
        console2.log("liquidity:         ", uint256(target.liquidity()));

        int24 spotTick = _spotTick(target);
        console2.log("spot tick:         ", int256(spotTick));
        _reportOracle(target, spotTick);
    }

    /// @dev Kept out of `_preflight` so the unit suite never touches the process environment:
    ///      `vm.setEnv` leaks into every other suite in the same `forge test` run.
    function _loadPoker() internal view returns (address poker) {
        poker = vm.envOr("SEPOLIA_POOL_POKER", address(0));
        // Deploying a fresh poker is deliberately not offered as a fallback: it would hold no
        // inventory, and fail the moment it is pointed at a pool that has liquidity.
        require(poker != address(0), "PokePool: set SEPOLIA_POOL_POKER (SetupSepolia prints it)");
        require(poker.code.length != 0, "PokePool: SEPOLIA_POOL_POKER has no code on this chain");
    }

    /// @dev Every guard here is a failure `pokeTo` would otherwise report as a silent success
    ///      or bury inside the pool.
    function _preflight(address pool, address poker, int24 targetTick) internal view returns (PokePlan memory plan) {
        require(block.chainid == ARBITRUM_SEPOLIA, "PokePool: wrong chain");
        require(pool.code.length != 0, "PokePool: pool has no code");
        // Both ends are STRICT. `UniswapV3Pool.swap` wants the limit above MIN_SQRT_RATIO going
        // down and below MAX_SQRT_RATIO going up, and those equal the ratios AT the extreme
        // ticks, so a target on either one reverts `SPL` inside the pool with no explanation.
        require(
            targetTick > TickMath.MIN_TICK && targetTick < TickMath.MAX_TICK,
            "PokePool: target tick outside the pool's usable range"
        );

        IUniswapV3Pool target = IUniswapV3Pool(pool);
        int24 spotTick = _spotTick(target);
        // `pokeTo` returns silently when the target is already spot, which would read as a
        // successful realignment having done nothing.
        require(targetTick != spotTick, "PokePool: target tick equals spot; nothing to poke");

        (address owedToken, bool zeroForOne) = _owedToken(target, targetTick, spotTick);
        uint128 poolLiquidity = target.liquidity();
        uint256 pokerBalance = IERC20(owedToken).balanceOf(poker);
        // An empty pool moves for free: the swap owes nothing, so the callback transfers
        // nothing. Only a pool with liquidity actually bills the poker.
        if (poolLiquidity != 0) {
            require(pokerBalance != 0, "PokePool: poker holds none of the token this direction owes");
        }

        plan = PokePlan({
            pool: pool,
            poker: poker,
            owedToken: owedToken,
            spotTick: spotTick,
            targetTick: targetTick,
            zeroForOne: zeroForOne,
            poolLiquidity: poolLiquidity,
            pokerBalance: pokerBalance
        });
    }

    /// @dev A partial move leaves the pool at a price nobody chose, which is the very bug this
    ///      script exists to fix, so exact arrival is required. It is also assertable: the swap
    ///      loop exits on the price limit, not on liquidity, and an underfunded poker reverts
    ///      inside the callback rather than stopping short.
    ///
    ///      The one tolerated miss is Uniswap's own. When the limit lands exactly on a tick the
    ///      loop was already stepping to, the pool sets `tick = tickNext - 1` for a downward
    ///      swap instead of re-deriving it from the price.
    function _assertArrived(int24 spotBefore, int24 spotAfter, int24 targetTick, bool zeroForOne) internal pure {
        require(spotAfter != spotBefore, "PokePool: the poke did not move spot");
        int256 shortfall = int256(targetTick) - int256(spotAfter);
        require(shortfall == 0 || (zeroForOne && shortfall == 1), "PokePool: poke stopped short of the target");
    }

    /// @dev `pokeTo` sets `zeroForOne = target < current`, and a `zeroForOne` swap sells token0.
    function _owedToken(IUniswapV3Pool pool, int24 targetTick, int24 spotTick)
        internal
        view
        returns (address token, bool zeroForOne)
    {
        zeroForOne = targetTick < spotTick;
        token = zeroForOne ? pool.token0() : pool.token1();
    }

    /// @dev With no other swaps the mean after a step change at `t = 0` is
    ///      `(old * (W - t) + new * t) / W`, so the deviation decays linearly. Writing `r` for
    ///      the seconds of the old tick still inside the window, the gate reopens
    ///      `r * (d - cap) / d` seconds from now. Rounded UP, because an under-stated wait
    ///      sends the operator back to a gate that is still shut. Assumes the last observation
    ///      was the poke; a pool somebody else is trading converges faster, never slower.
    function _secondsUntilGateOpens(uint256 deviation, uint256 secondsSinceLastObservation)
        internal
        pure
        returns (uint256)
    {
        uint256 cap = _deviationCap();
        if (deviation <= cap) return 0;
        if (secondsSinceLastObservation >= TuoConstants.TWAP_WINDOW) return 0;

        uint256 remainingWindow = TuoConstants.TWAP_WINDOW - secondsSinceLastObservation;
        uint256 numerator = remainingWindow * (deviation - cap);
        return (numerator + deviation - 1) / deviation;
    }

    /// @dev A raw staticcall rather than `try this.probe(...)`, because `forge script` aborts on
    ///      any call a script makes to its OWN address. The empty-return check matters because a
    ///      staticcall to a codeless address succeeds with no data, and here the pool is an
    ///      arbitrary command-line argument.
    function _twapReady(IUniswapV3Pool pool) internal view returns (bool) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TuoConstants.TWAP_WINDOW;
        secondsAgos[1] = 0;
        (bool ok, bytes memory ret) =
            address(pool).staticcall(abi.encodeCall(IUniswapV3PoolDerivedState.observe, (secondsAgos)));
        return ok && ret.length != 0;
    }

    function _spotTick(IUniswapV3Pool pool) internal view returns (int24 spotTick) {
        (, spotTick,,,,,) = pool.slot0();
    }

    /// @dev When the pool last wrote an observation is when its mean started converging on the
    ///      current tick.
    function _secondsSinceLastObservation(IUniswapV3Pool pool) internal view returns (uint256) {
        (,, uint16 observationIndex,,,,) = pool.slot0();
        (uint32 observedAt,,,) = pool.observations(observationIndex);
        if (uint256(observedAt) >= block.timestamp) return 0;
        return block.timestamp - uint256(observedAt);
    }

    function _deviation(int24 spotTick, int24 meanTick) internal pure returns (uint256) {
        int256 delta = int256(spotTick) - int256(meanTick);
        return SafeCast.toUint256(delta < 0 ? -delta : delta);
    }

    function _deviationCap() internal pure returns (uint256) {
        return SafeCast.toUint256(int256(TuoConstants.MAX_TWAP_DEVIATION_TICKS));
    }

    function _reportPlan(PokePlan memory plan) internal view {
        console2.log("chain id / sender: %s / %s", block.chainid, msg.sender);
        console2.log("pool:              ", plan.pool);
        console2.log("poker:             ", plan.poker);
        console2.log("tick before:       ", int256(plan.spotTick));
        console2.log("tick target:       ", int256(plan.targetTick));
        console2.log("liquidity:         ", uint256(plan.poolLiquidity));
        console2.log(plan.zeroForOne ? "direction:          DOWN, owes token0" : "direction:          UP, owes token1");
        console2.log("owed token:        ", plan.owedToken);
        console2.log("poker balance:     ", plan.pokerBalance);
    }

    /// @dev The mean, the deviation and the wait, or the reason none of them can be read yet.
    function _reportOracle(IUniswapV3Pool pool, int24 spotTick) internal view {
        if (!_twapReady(pool)) {
            console2.log("oracle:             ring cannot span the 30 minute window yet");
            return;
        }

        int24 meanTick = PoolTwap.twapTick(address(pool));
        uint256 deviation = _deviation(spotTick, meanTick);
        uint256 wait = _secondsUntilGateOpens(deviation, _secondsSinceLastObservation(pool));

        console2.log("30 minute mean:    ", int256(meanTick));
        console2.log("deviation / cap:   %s / %s", deviation, _deviationCap());
        if (wait == 0) {
            console2.log("vault gate:         OPEN");
        } else {
            console2.log("vault gate:         CLOSED, about %s s (%s min) left", wait, wait / 60);
        }
    }
}
