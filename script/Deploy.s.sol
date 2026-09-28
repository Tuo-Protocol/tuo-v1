// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {TuoVault} from "../src/TuoVault.sol";
import {TuoVaultStorage} from "../src/TuoVaultStorage.sol";
import {ITuoVault} from "../src/interfaces/ITuoVault.sol";
import {TuoConstants} from "../src/libraries/TuoConstants.sol";
import {TuoRoles} from "../src/libraries/TuoRoles.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {OracleRing} from "./libraries/OracleRing.sol";

/// @title Deploy - one-shot system deployment with post-assertions
/// @notice The vault constructor deploys the NFT and swap router and wires all roles,
///         so the contracts land in a single transaction and there is no post-deploy
///         configuration window to attack. Before it, `run()` grows any pool's oracle
///         ring below MIN_OBSERVATION_CARDINALITY, CARDINALITY_STEP slots per transaction,
///         because the constructor refuses a shallow pool. DEFAULT_ADMIN_ROLE is never
///         granted; the assertions below prove it before the broadcast is accepted.
contract Deploy is Script {
    /// @dev Oracle slots provisioned per transaction: 1,000 cold writes are ~22.5M gas, one
    ///      call under the ArbOS 32M per-transaction cap.
    uint16 internal constant CARDINALITY_STEP = 1_000;

    function run() external returns (TuoVault vault) {
        HelperConfig helper = new HelperConfig();
        TuoVaultStorage.InitConfig memory cfg = helper.getConfig();

        vm.startBroadcast();
        _provisionOracleRings(cfg.pools);
        vault = new TuoVault(cfg);
        vm.stopBroadcast();

        _assertDeployment(vault, cfg);

        console2.log("TuoVault:        ", address(vault));
        console2.log("TuoPositionNFT:  ", address(vault.NFT()));
        console2.log("TuoSwapRouter:   ", address(vault.SWAP_ROUTER()));
        console2.log("chain id:        ", block.chainid);
        console2.log("deployer:        ", msg.sender);
        console2.log("deploy block:    ", block.number);
    }

    /// @notice Raise every pool's `observationCardinalityNext` to the vault's constructor floor.
    /// @dev Permissionless on the pool, and a no-op broadcast for a pool already there. The
    ///      live history is not grown by this; `_assertDeployment`'s `observe` probe checks it.
    function _provisionOracleRings(address[] memory pools) internal {
        for (uint256 i = 0; i < pools.length; i++) {
            OracleRing.grow(IUniswapV3Pool(pools[i]), TuoConstants.MIN_OBSERVATION_CARDINALITY, CARDINALITY_STEP);
        }
    }

    function _assertDeployment(TuoVault vault, TuoVaultStorage.InitConfig memory cfg) internal view {
        // Roles: exactly the configured holders, and no admin exists.
        require(vault.hasRole(TuoRoles.TREASURY_ROLE, cfg.treasury), "treasury role missing");
        require(vault.hasRole(TuoRoles.KEEPER_ROLE, cfg.keeper), "keeper role missing");
        require(vault.hasRole(TuoRoles.PAUSER_ROLE, cfg.pauser), "pauser role missing");
        require(!vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), msg.sender), "deployer must hold no admin");
        require(vault.getRoleAdmin(TuoRoles.KEEPER_ROLE) == TuoRoles.TREASURY_ROLE, "keeper admin wiring");
        require(vault.getRoleAdmin(TuoRoles.TREASURY_ROLE) == TuoRoles.TREASURY_ROLE, "treasury self-admin");
        // The treasury is also the seeded payee, and the seed is the only write to it that
        // no setter guarded until the constructor started checking it.
        require(vault.feeRecipient() == cfg.treasury, "fee recipient");

        // Custody wiring.
        require(vault.NFT().VAULT() == address(vault), "nft vault binding");
        require(vault.SWAP_ROUTER().VAULT() == address(vault), "router vault binding");
        // Every configured operator is allowlisted. This is a subset check, not an exact
        // match: the vault keeps no enumerable operator set (the counter that would have
        // made it exact did not fit under EIP-170), so what bounds the allowlist here is
        // that the constructor is its only writer at deploy time and `cfg` is its input.
        require(cfg.hlOperators.length != 0, "hl operators empty");
        for (uint256 i = 0; i < cfg.hlOperators.length; i++) {
            require(vault.isHlOperator(cfg.hlOperators[i]), "hl operator missing");
        }

        // The only exposure bound the vault enforces.
        require(vault.perNftCapUsdc() == cfg.perNftCapUsdc, "per-NFT cap");
        // The keeper's swap floor is the one tolerance the treasury tunes; the seed is a
        // guarded write, so reaching this line proves it is under the compiled ceiling.
        require(vault.keeperSwapSlippageBps() == cfg.keeperSwapSlippageBps, "keeper swap tolerance");

        // Pools registered, paired with USDC, and with an oracle array deep enough for
        // the 30-minute TWAP everything on-chain prices against.
        //
        // The provisioned floor is now enforced by the vault constructor, so reaching this
        // line already proves it. What the constructor CANNOT prove is that the live ring
        // has grown into the provisioned one: `increaseObservationCardinalityNext` only
        // raises the target, and the pool fills it as swaps write observations. So assert
        // the thing that actually matters by doing it - a real `observe` over the exact
        // window the vault will read. A pool that reverts `OLD` here would price nothing
        // and settle nothing, and the allowlist has no setter to correct it afterwards.
        uint32[] memory window = new uint32[](2);
        window[0] = TuoConstants.TWAP_WINDOW;
        for (uint256 i = 0; i < cfg.pools.length; i++) {
            require(vault.isPoolAllowlisted(cfg.pools[i]), "pool not allowlisted");
            // The constructor proves each pool PAIRS with USDC. Only this proves it ORDERS
            // with USDC second, which is a different and equally load-bearing fact: Engine
            // v25's frozen POOL_META is written for the volatile token as token0, its
            // `_position_tick_bounds` has no inversion branch for the other ordering, and
            // the keeper forwards engine ticks to `mintLp` verbatim. A USDC-first pool
            // therefore mints every range at the exact negative of the intended tick,
            // silently and on the wrong side of spot. `_allowedPools` has no setter, so this
            // is the last point in THIS SCRIPT at which it can be caught - the constructor
            // itself is strictly later and accepts either ordering, which is why any
            // deployment that does not go through this script is unguarded.
            //
            // It guards Arbitrum One as well as the testnet: the canonical addresses satisfy
            // it today (WBTC 0x2f2a.. and WETH 0x82aF.. both sort below USDC 0xaf88..), and
            // this is what stops a future chain's USDC from inverting every range the engine
            // prescribes.
            IUniswapV3Pool pool = IUniswapV3Pool(cfg.pools[i]);
            require(pool.token1() == cfg.usdc, "pool must sort USDC as token1");

            // Provenance. Nothing derives these addresses - they come straight from env on
            // Sepolia - so prove each one is a real factory pool for the pair and fee it
            // claims. A lookalike would be worse than a typo: `mintLp` records the CONFIGURED
            // pool while the position manager derives the real one from (token0, token1,
            // fee), so the LP would land in the genuine pool while every valuation read the
            // impostor's oracle.
            require(
                IUniswapV3Factory(pool.factory()).getPool(pool.token0(), pool.token1(), pool.fee()) == address(pool),
                "pool not from its own factory"
            );

            // Identity, which the ordering check above cannot see. Every configured pool is
            // the sole pool for its token, so each one must have BECOME that token's
            // valuation pool. The constructor's first-pool-wins rule is what makes this
            // catch anything: a second entry for a token already registered is a silent
            // no-op, so the pool it was meant to be is simply absent from a set with no
            // setter, and every other assertion here passes while it is.
            require(vault.valuationPoolOf(pool.token0()) == address(pool), "pool is not its token's valuation pool");
            // The one shape the check above cannot see, because a repeat of an address IS
            // its own valuation pool: the same value pasted into both pool env vars.
            for (uint256 j = 0; j < i; j++) {
                require(cfg.pools[j] != cfg.pools[i], "duplicate pool entry");
            }

            (,,,, uint16 cardinalityNext,,) = pool.slot0();
            require(cardinalityNext >= TuoConstants.MIN_OBSERVATION_CARDINALITY, "pool oracle cardinality");
            pool.observe(window);
        }

        // Every configured deposit token actually landed. USDC and WETH are NOT checked here:
        // the constructor sets both unconditionally from this same `cfg`, so asserting them
        // reads as a check and cannot fail. What is worth proving is that WETH can be priced
        // at all, which the constructor does not imply.
        require(vault.valuationPoolOf(cfg.weth) != address(0), "weth has no valuation pool");
        for (uint256 i = 0; i < cfg.depositTokens.length; i++) {
            require(vault.isDepositToken(cfg.depositTokens[i]), "deposit token missing");
        }

        // The product registry is what `deposit` enforces, so a wrong seed is a wrong
        // policy for every position opened afterwards - and it is add-only, so it cannot
        // be corrected in place.
        for (uint256 i = 0; i < cfg.products.length; i++) {
            TuoVaultStorage.ProductInit memory seed = cfg.products[i];
            ITuoVault.Product memory onchain = vault.productOf(seed.code);
            require(onchain.label == seed.label, "product label");
            require(onchain.openForDeposits, "product must open for deposits");
            require(onchain.maxHedgeBps == seed.maxHedgeBps, "product hedge cap");
            require(onchain.maxLpCount == seed.maxLpCount, "product lp cap");
        }
        require(vault.productOf(0).label == bytes32(0), "product code 0 must stay reserved");
    }
}
