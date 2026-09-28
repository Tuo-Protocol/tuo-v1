// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IWETH9} from "../src/interfaces/external/IWETH9.sol";
import {TuoConstants} from "../src/libraries/TuoConstants.sol";
import {OracleRing} from "./libraries/OracleRing.sol";
import {SortedCreate2} from "./libraries/SortedCreate2.sol";
import {TestnetAggregator} from "./mocks/TestnetAggregator.sol";
import {TestnetPoolPoker} from "./mocks/TestnetPoolPoker.sol";
import {TestnetUSDC} from "./mocks/TestnetUSDC.sol";
import {TestnetWBTC} from "./mocks/TestnetWBTC.sol";

/// @title SetupSepolia - build the Arbitrum Sepolia environment the vault deploys into
/// @notice Arbitrum Sepolia has the canonical Uniswap V3 factory, position manager and
///         WETH9, but no usable USDC market and no WBTC at all: Circle's testnet USDC
///         faucet dispenses far less than the 2,500e6 deposit floor, and the one existing
///         WETH/USDC 0.05% pool holds dust at a nonsense tick. So this script mints the
///         missing pieces - a freely mintable USDC and WBTC, an inventory-backed
///         aggregator, and two fresh pools at sane prices - and leaves the canonical
///         factory / NPM / WETH9 in place so the LP and native-ETH deposit legs exercise
///         real Uniswap code.
///
/// @dev **Two pools, and exactly two: WETH/USDC and WBTC/USDC.** That is the whole of what
///      Engine v25's products address - BP Core runs `alpha_eu` on WETH/USDC plus
///      `alpha_bu` and `dyn_wbtc` on ONE shared WBTC/USDC pool (told apart by RANGE WIDTH,
///      not by a second pool), and DH Standalone is `dyn_wbtc` alone, so it is WBTC-only
///      and would hold a basis and deploy nothing against the WETH pool alone. A second
///      WBTC/USDC fee tier would therefore be a pool no signal can ever name: the frozen
///      engine addresses a pool by a label (`WBTC/USDC`) and has exactly one per pair. The
///      engine's own third pool, WBTC/WETH, stays structurally out of scope too - the vault
///      constructor requires every allowlisted pool to pair its token with USDC.
///
/// @dev **The mocks are deployed with mined CREATE2 salts, and that is the point.**
///      Uniswap decides `token0` by raw address comparison, and the frozen engine's
///      `POOL_META` is written for the volatile token as token0 and USDC as token1 (`d0`/
///      `d1` of 18/6 and 8/6). `_position_tick_bounds` has no inversion branch for the
///      other ordering and the keeper forwards its ticks to `mintLp` verbatim, so a mock
///      USDC that sorts first makes every pool tick the exact negative of the engine tick.
///      The first Sepolia deployment lost that coin flip. `SortedCreate2` replaces it with
///      a search: WBTC is mined below canonical WETH9 and USDC above it, so both pools
///      inherit the mainnet ordering. See `_requireUsdcIsToken1`.
///
/// @dev Run BEFORE `Deploy.s.sol` and export the printed `SEPOLIA_*` lines into the
///      deploy environment (and the `POOL_MAP_JSON` line into the backend's). The vault
///      constructor only reads `token0()/token1()` off each pool, so the deploy can follow
///      immediately - but `TuoConstants.TWAP_WINDOW` is 30 minutes and
///      `OracleLibrary.consult` reverts `OLD` until a pool's oldest observation is that
///      old, so the first `mintLp` / `burnLp` must wait 30 minutes after the `initialize`
///      transactions below. Both pools are initialized in the same broadcast, so ONE
///      wait covers them. The same window gates the backend's testnet swap quote, which is
///      priced off `observe`, so a non-USDC deposit from the client waits too. Deposits and
///      withdrawals in USDC need no TWAP and work at once.
///
///      No pool is seeded with liquidity: `mintLp` adds its own, swaps route through
///      the aggregator rather than the pool, and valuation only reads the oracle - so no
///      vault path depends on pre-existing depth, and the rehearsal costs nothing beyond
///      gas.
contract SetupSepolia is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    /// @dev Canonical Arbitrum Sepolia deployments (verified on-chain: the position
    ///      manager reports this factory and this WETH9).
    address internal constant DEFAULT_FACTORY = 0x248AB79Bbb9bC29bB72f7Cd42F17e054Fc40188e;
    address internal constant DEFAULT_NPM = 0x6b2937Bde17889EDCf8fbD8dE31C3C2a70Bc4d65;
    address internal constant DEFAULT_WETH9 = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;

    /// @dev USDC's decimals, and `d1` for both pairs in the frozen engine's `POOL_META`.
    uint8 internal constant USDC_DECIMALS = 6;
    uint8 internal constant WETH_DECIMALS = 18;
    uint8 internal constant WBTC_DECIMALS = 8;

    /// @dev The tick spacing the frozen engine's `POOL_META` assumes (`tick_spacing: 10`
    ///      for both USDC pairs), which is what `SEPOLIA_POOL_FEE` and
    ///      `SEPOLIA_POOL_FEE_WBTC` are chosen to match.
    ///
    ///      It is NOT what makes a mint legal, and an earlier version of this comment had
    ///      that backwards. `_position_tick_bounds` does not round: it returns
    ///      `int(log(p) / log(1.0001))` raw, so roughly nine ranges in ten are off ANY
    ///      grid. The position manager reverts unless both ticks are multiples of the
    ///      POOL's spacing, and it does so inside `TickBitmap.flipTick` on a bare
    ///      `require` with no reason string - after `TuoVault` has already charged one of
    ///      the position's ten daily keeper actions.
    ///
    ///      The backend closes that gap: it reads the pool's live `tickSpacing()` and
    ///      snaps each range outward before it builds the call. Alignment therefore no longer
    ///      constrains which fee tier is usable here; this constant remains the engine's
    ///      own assumption, not a correctness bound.
    int24 internal constant ENGINE_TICK_SPACING = 10;

    /// @dev Provisioned straight from the vault's own floor so the two can never drift: a
    ///      pool below it is rejected by the constructor, so a testnet pool seeded any
    ///      shallower simply cannot be deployed against.
    uint16 internal constant OBSERVATION_CARDINALITY = TuoConstants.MIN_OBSERVATION_CARDINALITY;

    /// @dev Slots to provision per transaction. `increaseObservationCardinalityNext`
    ///      writes one cold slot per new observation (~22k gas), so asking for all 2000 at
    ///      once is ~43M gas - over what ArbOS accepts in a single transaction, which is
    ///      why the one-shot call could never have landed on a fresh pool. 400 slots is
    ///      ~9M, comfortably inside the ceiling, and one ring costs five transactions.
    ///      Two pools therefore cost ten. Override with SEPOLIA_CARDINALITY_STEP if a
    ///      chain disagrees.
    uint16 internal constant DEFAULT_CARDINALITY_STEP = 400;

    /// @dev Seed balances minted to the deployer so the rehearsal can deposit immediately,
    ///      in either token.
    uint256 internal constant DEPLOYER_USDC_SEED = 1_000_000e6;
    uint256 internal constant DEPLOYER_WBTC_SEED = 100e8;

    /// @dev Inventory the aggregator pays swap outputs from.
    uint256 internal constant AGGREGATOR_USDC_SEED = 1_000_000e6;

    /// @dev The aggregator's WBTC inventory, which every USDC -> WBTC fill is paid from and
    ///      which no swap ever refills. Unlike the WETH leg this costs no real testnet ETH
    ///      (`TestnetWBTC.mint` is unpermissioned), so it is sized for headroom rather than
    ///      frugality. Override with SEPOLIA_AGGREGATOR_WBTC.
    uint256 internal constant AGGREGATOR_WBTC_SEED = 20e8;

    /// @dev What the poker pays the pool from when it moves a price.
    ///
    ///      `pokeTo` sets `zeroForOne = target < current`, and a `zeroForOne` swap sells
    ///      token0 while the other direction sells token1. With USDC mined ABOVE both
    ///      volatile tokens, USDC is token1 in both pools - so a USDC-funded poke pushes
    ///      spot UP.
    ///
    ///      Only the WBTC pool can be poked in both directions: pushing it DOWN spends
    ///      token0 = WBTC, which is freely mintable. Pushing the WETH pool down would spend
    ///      WETH, which has to be bought with real testnet ETH, so an operator who wants to
    ///      push it down has to hand the poker WETH first.
    uint256 internal constant POKER_USDC_SEED = 100_000e6;
    uint256 internal constant POKER_WBTC_SEED = 10e8;

    struct Result {
        TestnetUSDC usdc;
        TestnetWBTC wbtc;
        TestnetAggregator aggregator;
        TestnetPoolPoker poker;
        address poolWethUsdc;
        address poolWbtcUsdc;
        uint24 feeWeth;
        uint24 feeWbtc;
        bytes32 usdcSalt;
        bytes32 wbtcSalt;
    }

    function run() external returns (Result memory result) {
        require(block.chainid == ARBITRUM_SEPOLIA, "SetupSepolia: wrong chain");

        address weth = vm.envOr("SEPOLIA_WETH", DEFAULT_WETH9);
        address factory = vm.envOr("SEPOLIA_FACTORY", DEFAULT_FACTORY);
        uint24 feeWeth = uint24(vm.envOr("SEPOLIA_POOL_FEE", uint256(500)));
        uint24 feeWbtc = uint24(vm.envOr("SEPOLIA_POOL_FEE_WBTC", uint256(500)));
        uint256 usdcPerEth = vm.envOr("SEPOLIA_INIT_USDC_PER_ETH", uint256(3_000));
        uint256 usdcPerWbtc = vm.envOr("SEPOLIA_INIT_USDC_PER_WBTC", uint256(100_000));
        uint256 aggregatorWethWei = vm.envOr("SEPOLIA_AGGREGATOR_WETH_WEI", uint256(0));
        uint256 aggregatorWbtc = vm.envOr("SEPOLIA_AGGREGATOR_WBTC", AGGREGATOR_WBTC_SEED);
        uint16 cardinalityStep = uint16(vm.envOr("SEPOLIA_CARDINALITY_STEP", uint256(DEFAULT_CARDINALITY_STEP)));
        require(usdcPerEth != 0, "SetupSepolia: zero init price");
        require(usdcPerWbtc != 0, "SetupSepolia: zero init WBTC price");

        // Mined before the broadcast: the search is pure, so this records no transaction and
        // the predicted addresses are the ones a later broadcast will produce.
        address wbtcPredicted;
        address usdcPredicted;
        (result.wbtcSalt, wbtcPredicted, result.usdcSalt, usdcPredicted) = _mineFixtureSalts(weth);
        // Checked before anything is spent: this is the property the whole mining exists for,
        // and the vault's pool allowlist has no setter to correct it afterwards.
        require(wbtcPredicted < weth && weth < usdcPredicted, "SetupSepolia: token sort order");

        vm.startBroadcast();

        result.wbtc = TestnetWBTC(wbtcPredicted);
        if (wbtcPredicted.code.length == 0) {
            result.wbtc = new TestnetWBTC{salt: result.wbtcSalt}();
            // CREATE2 introduces a seam between the simulation that mined the salt and the
            // broadcast that spends it. Close it here rather than discovering a wrong address
            // two transactions later.
            require(address(result.wbtc) == wbtcPredicted, "SetupSepolia: WBTC address drift");
        }
        result.usdc = TestnetUSDC(usdcPredicted);
        if (usdcPredicted.code.length == 0) {
            result.usdc = new TestnetUSDC{salt: result.usdcSalt}();
            require(address(result.usdc) == usdcPredicted, "SetupSepolia: USDC address drift");
        }

        result.aggregator = new TestnetAggregator();
        // Neither pool is seeded, so nothing else on Sepolia can move a price - and a
        // mint/burn round trip at an unchanged tick exercises neither the burn-side value
        // floor nor the TWAP deviation gate. The poker is what lets a rehearsal swap
        // against the vault's own freshly minted liquidity, which is where the depth comes
        // from.
        result.poker = new TestnetPoolPoker();
        result.feeWeth = feeWeth;
        result.feeWbtc = feeWbtc;

        result.usdc.mint(msg.sender, DEPLOYER_USDC_SEED);
        result.usdc.mint(address(result.aggregator), AGGREGATOR_USDC_SEED);
        result.usdc.mint(address(result.poker), POKER_USDC_SEED);
        result.wbtc.mint(msg.sender, DEPLOYER_WBTC_SEED);
        result.wbtc.mint(address(result.aggregator), aggregatorWbtc);
        result.wbtc.mint(address(result.poker), POKER_WBTC_SEED);

        // The WETH leg of the aggregator's inventory costs real testnet ETH, so it is
        // opt-in: only a USDC -> WETH swap needs it. The WBTC leg above is minted, so it
        // has no equivalent switch.
        if (aggregatorWethWei != 0) {
            IWETH9(weth).deposit{value: aggregatorWethWei}();
            IERC20(weth).safeTransfer(address(result.aggregator), aggregatorWethWei);
        }

        result.poolWethUsdc = _createInitializeAndGrow(
            factory, address(result.usdc), weth, WETH_DECIMALS, feeWeth, usdcPerEth, cardinalityStep
        );
        result.poolWbtcUsdc = _createInitializeAndGrow(
            factory, address(result.usdc), address(result.wbtc), WBTC_DECIMALS, feeWbtc, usdcPerWbtc, cardinalityStep
        );

        vm.stopBroadcast();

        _report(result, weth, usdcPerEth, usdcPerWbtc);
    }

    /// @notice The CREATE2 salts that put each mock on the side of WETH9 the engine assumes.
    /// @dev WETH9 is the only address here we cannot choose, so it is the pivot both mines
    ///      work against: WBTC below it, USDC above it, giving `wbtc < weth < usdc` and
    ///      therefore USDC as token1 of both pools.
    ///
    ///      Mining BOTH rather than letting WBTC fall out of a plain CREATE is deliberate.
    ///      WETH9 sits at roughly 59% of the address space, so each search succeeds in about
    ///      two tries. With a nonce-derived WBTC the USDC floor would be `max(WETH9, U)` for
    ///      a uniform `U`, whose expected search cost DIVERGES - a WBTC that happened to
    ///      land near the top of the space would cost tens of thousands of tries, which is a
    ///      coin flip the operator has no way to influence. Mining both also makes every
    ///      address a pure function of committed source, so a `SetupSepolia` dry run predicts
    ///      exactly what the broadcast will produce and the ordering can be verified before
    ///      any gas is spent.
    ///
    ///      The search ignores whether an address is occupied, and `run()` **adopts**
    ///      what it finds there rather than mining onward. That is what makes a re-run
    ///      idempotent: an address is keccak-bound to this deployer, this salt and this
    ///      initcode hash, so code sitting at it is that exact contract. Mining past it would
    ///      instead deploy a second generation of mocks at new addresses, orphaning the first
    ///      generation's pools, seeds and every environment value already exported.
    function _mineFixtureSalts(address weth)
        internal
        view
        returns (bytes32 wbtcSalt, address wbtcPredicted, bytes32 usdcSalt, address usdcPredicted)
    {
        // `new C{salt: s}()` inside a broadcast is routed through Arachnid's deterministic
        // deployer. On a chain without it forge deploys nothing and every downstream address
        // is wrong, so fail here rather than three transactions in.
        require(SortedCreate2.DETERMINISTIC_DEPLOYER.code.length != 0, "SetupSepolia: no CREATE2 deployer");

        uint256 tries = vm.envOr("SEPOLIA_SALT_TRIES", SortedCreate2.DEFAULT_MAX_TRIES);
        (wbtcSalt, wbtcPredicted) =
            SortedCreate2.mineBetween(keccak256(type(TestnetWBTC).creationCode), address(0), weth, tries);
        (usdcSalt, usdcPredicted) = SortedCreate2.mineBetween(
            keccak256(type(TestnetUSDC).creationCode), weth, address(type(uint160).max), tries
        );
    }

    /// @notice Create the pool if it does not exist, initialize it if it has no price, and
    ///         walk its observation ring to the vault's floor.
    /// @dev One helper for both pools so they cannot drift apart in fee tier, price
    ///      derivation, ordering guard or oracle depth. Every step is idempotent, so a
    ///      re-run against a partially built environment resumes rather than restarting.
    function _createInitializeAndGrow(
        address factory,
        address usdc,
        address token,
        uint8 tokenDecimals,
        uint24 fee,
        uint256 usdcPerToken,
        uint16 cardinalityStep
    ) internal returns (address pool) {
        _requireEngineCompatibleFee(factory, fee);

        pool = IUniswapV3Factory(factory).getPool(usdc, token, fee);
        if (pool == address(0)) pool = IUniswapV3Factory(factory).createPool(usdc, token, fee);
        // Before `initialize`, so a pool that sorts the wrong way costs nothing to abandon.
        // Guarding the `getPool` branch too is the point: an operator re-running against a
        // pool that already existed (Sepolia's dust WETH/USDC pool, say) is refused rather
        // than silently adopting it.
        _requireUsdcIsToken1(pool, usdc);

        uint160 want = _initialSqrtPriceX96(usdc, token, usdcPerToken, tokenDecimals);
        (uint160 existingSqrtPrice,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (existingSqrtPrice == 0) {
            IUniswapV3Pool(pool).initialize(want);
        }

        // The adoption branch above is the hole this closes. `createPool` and `initialize`
        // touch no tokens and are permissionless, and the mock addresses are a pure function
        // of committed source - which this script advertises and a dry run prints - so anyone
        // can create and price these two pools first. The run would then skip `initialize`,
        // grow the ring on the attacker's pool, and hand the vault an oracle at a tick of
        // their choosing, permanently, since the pool allowlist has no setter.
        //
        // The band is wide (a factor of two) because a legitimate re-run adopts a pool that has
        // already been poked; the poke is bounded to MAX_TWAP_DEVIATION_TICKS,
        // about 2% of price, so it is nowhere near this. What the band rejects is a price
        // that was never the one we asked for.
        (uint160 got,,,,,,) = IUniswapV3Pool(pool).slot0();
        require(got >= want / 2 && got <= want * 2, "SetupSepolia: adopted pool is not at our price");

        OracleRing.grow(IUniswapV3Pool(pool), OBSERVATION_CARDINALITY, cardinalityStep);
    }

    /// @notice Refuse a fee tier the factory does not know, or whose tick spacing the engine
    ///         cannot address.
    /// @dev Two failures, both of which would otherwise surface far from their cause.
    ///
    ///      An unknown tier makes `createPool` revert with no reason string, several
    ///      transactions into a broadcast - the 0.01% tier in particular is enabled by
    ///      governance rather than at deployment, so it is present on Arbitrum One and is
    ///      not guaranteed on every testnet factory.
    ///
    ///      A spacing that does not DIVIDE the engine's 10 is worse, because it deploys
    ///      cleanly and passes every assertion in `Deploy`. The engine rounds its bounds to
    ///      multiples of 10, the keeper forwards them to `mintLp` verbatim, and the position
    ///      manager then reverts on a tick that is not a multiple of the pool's spacing. So
    ///      the 0.3% (60) and 1% (200) tiers are structurally unusable here, and the failure
    ///      would arrive as an unexplained `mintLp` revert 30 minutes after a deploy that
    ///      cannot be corrected - the pool allowlist has no setter.
    function _requireEngineCompatibleFee(address factory, uint24 fee) internal view {
        int24 spacing = IUniswapV3Factory(factory).feeAmountTickSpacing(fee);
        require(spacing != 0, "SetupSepolia: fee tier not enabled on this factory");
        require(ENGINE_TICK_SPACING % spacing == 0, "SetupSepolia: tick spacing must divide 10");
    }

    /// @notice Refuse a pool that does not sort USDC as token1.
    /// @dev Engine v25 is byte-immutable and its `POOL_META` is frozen with the volatile
    ///      token as token0 and USDC as token1. `_position_tick_bounds` has exactly one
    ///      inversion branch and it guards WBTC/WETH, a pool that is out of scope here; for
    ///      a USDC-first pool there is none. The keeper hands engine ticks to `mintLp`
    ///      verbatim, so such a pool does not drift - it mints every range at the exact
    ///      negative of the intended tick, on the wrong side of spot, and no unit test
    ///      anywhere would see it.
    ///
    ///      The vault's pool allowlist has no setter, so an inverted pool can only be
    ///      corrected by redeploying the whole vault. That is why the check is here and
    ///      again in `Deploy._assertDeployment`, rather than at first use.
    function _requireUsdcIsToken1(address pool, address usdc) internal view {
        require(IUniswapV3Pool(pool).token1() == usdc, "SetupSepolia: USDC must be token1");
    }

    /// @notice sqrtPriceX96 for "1 whole `token` = `usdcPerToken` whole USDC", whichever way
    ///         the pool happens to order the two.
    /// @dev Token order is not knowable ahead of time - the mock addresses come out of a
    ///      CREATE2 in this very script - so the price is derived rather than hardcoded.
    ///      The mining now guarantees `token < usdc`, but the other branch is kept: it is
    ///      the property the fuzz test pins, and it keeps this correct if an operator
    ///      repoints `SEPOLIA_WETH`.
    ///
    ///      `sqrtPriceX96 = sqrt(amount1 / amount0) * 2**96`, computed as
    ///      `sqrt(amount1 * 2**192 / amount0)` with FullMath's 512-bit intermediate.
    /// @param usdcPerToken whole USDC per whole token (3,000 for WETH, 100,000 for WBTC)
    /// @param tokenDecimals the token's ERC-20 decimals (18 for WETH, 8 for WBTC)
    function _initialSqrtPriceX96(address usdc, address token, uint256 usdcPerToken, uint8 tokenDecimals)
        internal
        pure
        returns (uint160)
    {
        uint256 usdcRaw = usdcPerToken * 10 ** USDC_DECIMALS;
        uint256 tokenRaw = 10 ** tokenDecimals;
        (uint256 amount0, uint256 amount1) = usdc < token ? (usdcRaw, tokenRaw) : (tokenRaw, usdcRaw);
        uint256 ratioX192 = FullMath.mulDiv(amount1, 1 << 192, amount0);
        // The narrowing is unconditionally safe: `sqrt(x) < 2**128` for every `x < 2**256`,
        // and 2**128 fits a uint160 with 32 bits to spare. An out-of-range price cannot reach
        // here silently either - it reverts inside `FullMath.mulDiv` rather than truncating.
        return uint160(Math.sqrt(ratioX192));
    }

    function _report(Result memory result, address weth, uint256 usdcPerEth, uint256 usdcPerWbtc) internal view {
        console2.log("--- export into the deploy environment --------------------------");
        console2.log("SEPOLIA_USDC=%s", address(result.usdc));
        console2.log("SEPOLIA_WBTC=%s", address(result.wbtc));
        console2.log("SEPOLIA_WETH=%s", weth);
        // Resolved the same way HelperConfig will read it back, so an operator who
        // overrides SEPOLIA_NPM is not told to paste a different address than the
        // deploy script requires.
        console2.log("SEPOLIA_NPM=%s", vm.envOr("SEPOLIA_NPM", DEFAULT_NPM));
        console2.log("SEPOLIA_POOL_WETH_USDC=%s", result.poolWethUsdc);
        console2.log("SEPOLIA_POOL_WBTC_USDC=%s", result.poolWbtcUsdc);
        console2.log("SEPOLIA_AGGREGATOR=%s", address(result.aggregator));
        console2.log("SEPOLIA_POOL_POKER=%s", address(result.poker));

        // The backend resolves an engine pool LABEL to an address through POOL_MAP_JSON and
        // has no other source for it, so an operator has been hand-assembling this line.
        // Print it: the labels are the frozen engine's own, and the addresses are the ones
        // just deployed. One entry per pool, and the labels are the engine's own - it names
        // a pool by its pair, so an invented label is dropped by `PoolRegistry` rather than
        // guessed at.
        console2.log("--- paste into the BACKEND environment --------------------------");
        console2.log(
            string.concat(
                "POOL_MAP_JSON={\"WETH/USDC\":\"",
                vm.toString(result.poolWethUsdc),
                "\",\"WBTC/USDC\":\"",
                vm.toString(result.poolWbtcUsdc),
                "\"}"
            )
        );
        console2.log("AGGREGATOR_KIND=testnet-mock");
        console2.log("AGGREGATOR_ADDRESS=%s", address(result.aggregator));
        console2.log("----------------------------------------------------------------");

        // The whole reason the mocks are mined. A human reading the log can catch an
        // inversion here without knowing the tick formula.
        console2.log("token sort order (must be ascending):");
        console2.log("  WBTC %s", address(result.wbtc));
        console2.log("  WETH %s", weth);
        console2.log("  USDC %s", address(result.usdc));
        console2.log("mined salts: wbtc %s  usdc %s", uint256(result.wbtcSalt), uint256(result.usdcSalt));

        _reportPool("WETH/USDC", result.poolWethUsdc, result.feeWeth, usdcPerEth, WETH_DECIMALS);
        _reportPool("WBTC/USDC", result.poolWbtcUsdc, result.feeWbtc, usdcPerWbtc, WBTC_DECIMALS);

        console2.log("chain id:        ", block.chainid);
        console2.log("deployer:        ", msg.sender);
        console2.log("setup block:     ", block.number);
        console2.log("setup timestamp: ", block.timestamp);
        console2.log("mintLp/burnLp unlock at (timestamp, BOTH pools): ", block.timestamp + 30 minutes);
    }

    /// @dev The expected tick sign is DERIVED, not passed in as a flag. With USDC as token1
    ///      the pool price is `usdcRaw / tokenRaw`, so the tick is negative exactly when a
    ///      whole token is worth fewer raw USDC units than it has raw units of itself - true
    ///      for WETH (3e9 vs 1e18) and false for WBTC (1e11 vs 1e8) at the default prices. A
    ///      hardcoded flag would start lying at an unusual `SEPOLIA_INIT_USDC_PER_*`, and this
    ///      is the one line the runbook tells a human to eyeball. Asserted as well as printed:
    ///      a wrong sign here is the inverted-ordering bug, and the pool allowlist has no
    ///      setter.
    function _reportPool(string memory label, address pool, uint24 fee, uint256 usdcPerToken, uint8 tokenDecimals)
        internal
        view
    {
        (, int24 tick,,, uint16 cardinalityNext,,) = IUniswapV3Pool(pool).slot0();
        bool expectNegativeTick = usdcPerToken * 10 ** USDC_DECIMALS < 10 ** tokenDecimals;

        console2.log("--- %s -----------------------------------------------", label);
        console2.log("pool:              ", pool);
        console2.log("token0 / token1:   %s / %s", IUniswapV3Pool(pool).token0(), IUniswapV3Pool(pool).token1());
        console2.log("fee:               ", uint256(fee));
        console2.log("init USDC per unit:", usdcPerToken);
        console2.log(expectNegativeTick ? "init tick (expect NEGATIVE):" : "init tick (expect POSITIVE):", int256(tick));
        // The vault constructor rejects the pool unless this reaches the floor, so it is
        // the one line to check per pool before running the deploy.
        console2.log("cardinalityNext:  %s (floor %s)", uint256(cardinalityNext), uint256(OBSERVATION_CARDINALITY));

        require(expectNegativeTick ? tick < 0 : tick > 0, "SetupSepolia: init tick sign");
    }
}
