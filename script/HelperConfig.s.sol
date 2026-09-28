// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {TuoVaultStorage} from "../src/TuoVaultStorage.sol";

/// @title HelperConfig - per-chain deployment inputs
/// @notice Arbitrum One addresses are pinned constants (verify against the checklist
///         in the deploy runbook before broadcasting). Arbitrum Sepolia has no deep
///         canonical pools, so its config is env-driven and intended for tx-plumbing
///         rehearsals; economic behavior is validated on mainnet forks.
contract HelperConfig is Script {
    // ----------------------------------------------------------- Arbitrum One
    address internal constant ARB1_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // native USDC
    address internal constant ARB1_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant ARB1_WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address internal constant ARB1_NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address internal constant ARB1_POOL_WETH_USDC_005 = 0xC6962004f452bE9203591991D15f6b388e09E8D0;
    address internal constant ARB1_POOL_WBTC_USDC_005 = 0x0E4831319A50228B9e450861297aB92dee15B44F;
    // 0x AllowanceHolder (v2 allowance-holder flow) and 1inch AggregationRouter v6.
    address internal constant ARB1_0X_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    address internal constant ARB1_1INCH_V6 = 0x111111125421cA6dc452d289314280a0f8842A65;
    // Tether's Arbitrum USDT is deliberately NOT allowlisted. `deposit` routes the amount
    // it was told to expect rather than the balance delta it actually received, so a token
    // that can ever take a cut on transfer would spend other positions' idle balance to
    // cover the shortfall. USDT's fee switch is dormant, not absent. Any token added to the
    // deposit set must be verified to have no fee-on-transfer, rebasing, or ERC-777 hook
    // behaviour, AND must have an allowlisted USDC pool: a token the vault cannot price is
    // entry-only, because `withdraw` reverts `TokenNotAllowlisted` rather than pay out in it.

    // Guarded-launch cap: $25k per NFT. The vault keeps no aggregate cap and
    // deposits are open to any wallet, so this per-position ceiling is the only exposure
    // bound the chain enforces.
    uint256 internal constant LAUNCH_PER_NFT_CAP = 25_000e6;

    // Tolerance under the 30-minute mean quote for the keeper's idle swaps. The fill happens
    // at spot, so the tolerance has to cover the spot-to-mean drift the deviation gate
    // permits plus the route's own cost (about 12 bps on the deepest configured route): at
    // 100 bps an honest fill stays reachable to about 88 adverse ticks, well past the 40
    // that a trending market shows against a 30-minute mean. Treasury-tunable up to
    // TuoConstants.MAX_KEEPER_SWAP_SLIPPAGE_BPS; the owner's exit floor does not follow it.
    uint16 internal constant LAUNCH_KEEPER_SWAP_SLIPPAGE_BPS = 100;

    /// @dev The two MVP products, seeded into the vault's on-chain registry at
    ///      construction. `maxLpCount` follows the strategy (BP Core runs up to three
    ///      concentrated ranges, DH Standalone holds one) up to `TuoConstants.MAX_LP_COUNT`,
    ///      which BP Core sits exactly at - a wider product needs that compiled ceiling
    ///      raised, so it needs a redeploy, not a treasury call. `maxHedgeBps` bounds how
    ///      much of a position's basis may sit on Hyperliquid at once, which is the only
    ///      bound on the leg the vault cannot measure (D6). Both are proposed values
    ///      pending Tuo sign-off, like the other policy constants.
    function _mvpProducts() internal pure returns (TuoVaultStorage.ProductInit[] memory products) {
        products = new TuoVaultStorage.ProductInit[](2);
        products[0] = TuoVaultStorage.ProductInit({code: 1, label: "BP_CORE", maxHedgeBps: 5_000, maxLpCount: 3});
        products[1] = TuoVaultStorage.ProductInit({code: 2, label: "DH_STANDALONE", maxHedgeBps: 9_000, maxLpCount: 1});
    }

    function getConfig() public view returns (TuoVaultStorage.InitConfig memory cfg) {
        if (block.chainid == 42161) return _arbitrumOne();
        if (block.chainid == 421614) return _arbitrumSepolia();
        revert("HelperConfig: unsupported chain");
    }

    function _arbitrumOne() internal view returns (TuoVaultStorage.InitConfig memory cfg) {
        address[] memory pools = new address[](2);
        pools[0] = ARB1_POOL_WETH_USDC_005;
        pools[1] = ARB1_POOL_WBTC_USDC_005;

        address[] memory depositTokens = new address[](1);
        depositTokens[0] = ARB1_WBTC;

        address[] memory aggregators = new address[](2);
        aggregators[0] = ARB1_0X_ALLOWANCE_HOLDER;
        aggregators[1] = ARB1_1INCH_V6;

        cfg = TuoVaultStorage.InitConfig({
            usdc: ARB1_USDC,
            weth: ARB1_WETH,
            positionManager: ARB1_NPM,
            hlOperators: vm.envAddress("HL_OPERATOR_ADDRESSES", ","),
            treasury: vm.envAddress("TREASURY_ADDRESS"),
            keeper: vm.envAddress("KEEPER_ADDRESS"),
            pauser: vm.envAddress("PAUSER_ADDRESS"),
            pools: pools,
            depositTokens: depositTokens,
            aggregators: aggregators,
            products: _mvpProducts(),
            perNftCapUsdc: LAUNCH_PER_NFT_CAP,
            keeperSwapSlippageBps: LAUNCH_KEEPER_SWAP_SLIPPAGE_BPS,
            nftBaseURI: vm.envOr("NFT_BASE_URI", string("https://api.tuo.finance/nft/"))
        });
    }

    /// @dev Everything env-driven: Sepolia pools/tokens are mock-grade and change.
    ///
    ///      Two pools, mirroring `_arbitrumOne`. Engine v25's products need exactly these -
    ///      BP Core runs `alpha_eu` on WETH/USDC plus `alpha_bu` and `dyn_wbtc` on ONE
    ///      shared WBTC/USDC pool (told apart by RANGE WIDTH, not by a second pool), and DH
    ///      Standalone is `dyn_wbtc` alone, so it is WBTC-only and could deploy nothing
    ///      while the vault allowlisted the WETH pool alone. The allowlist has no setter, so
    ///      the pool set is fixed for the life of the deployment.
    function _arbitrumSepolia() internal view returns (TuoVaultStorage.InitConfig memory cfg) {
        address[] memory pools = new address[](2);
        pools[0] = vm.envAddress("SEPOLIA_POOL_WETH_USDC");
        pools[1] = vm.envAddress("SEPOLIA_POOL_WBTC_USDC");

        address wbtc = _requireSepoliaPoolShape(pools);

        // The mock WBTC, mirroring `_arbitrumOne`'s ARB1_WBTC. USDC and WETH are seeded by
        // the constructor itself, so this is the only entry - and it costs nothing, since
        // `TestnetWBTC.mint` is unpermissioned and a tester funds themselves. The off-chain
        // token registry must list it too, or the client never offers it.
        //
        // DERIVED from the pool rather than read from `SEPOLIA_WBTC`, and that is the point.
        // The deposit-token set has no setter either, so a stale env value would permanently
        // allowlist a dead token and permanently refuse the live one - and no assertion in
        // `Deploy` looks at it, because the pool checks only ever see the USDC side. The pool
        // is proven to sort USDC as token1 immediately below, so token0 IS the paired WBTC by
        // construction and the two facts cannot disagree.
        address[] memory depositTokens = new address[](1);
        depositTokens[0] = wbtc;

        address[] memory aggregators = new address[](1);
        aggregators[0] = vm.envAddress("SEPOLIA_AGGREGATOR");

        cfg = TuoVaultStorage.InitConfig({
            usdc: vm.envAddress("SEPOLIA_USDC"),
            weth: vm.envAddress("SEPOLIA_WETH"),
            positionManager: vm.envAddress("SEPOLIA_NPM"),
            hlOperators: vm.envAddress("HL_OPERATOR_ADDRESSES", ","),
            treasury: vm.envAddress("TREASURY_ADDRESS"),
            keeper: vm.envAddress("KEEPER_ADDRESS"),
            pauser: vm.envAddress("PAUSER_ADDRESS"),
            pools: pools,
            depositTokens: depositTokens,
            aggregators: aggregators,
            products: _mvpProducts(),
            perNftCapUsdc: LAUNCH_PER_NFT_CAP,
            keeperSwapSlippageBps: LAUNCH_KEEPER_SWAP_SLIPPAGE_BPS,
            nftBaseURI: vm.envOr("NFT_BASE_URI", string("https://staging.tuo.finance/nft/"))
        });
    }

    /// @notice Prove the Sepolia pool set is the shape this config claims, and name the WBTC
    ///         it prices against.
    /// @dev One WETH/USDC pool followed by one WBTC/USDC pool, pairing DIFFERENT tokens.
    ///      `Deploy._assertDeployment` cannot check this: it sees two USDC-paired pools and
    ///      has no way to know which pairing was intended. So the WETH pool pasted into the
    ///      WBTC slot would deploy a vault that can never price, swap into or LP WBTC - and
    ///      the deposit token, which is DERIVED from `pools[1].token0()`, would silently
    ///      become WETH again, so even that check would pass. The pool allowlist has no
    ///      setter, so the mistake costs a redeploy.
    ///
    ///      Taking `pools` as an argument rather than reading the environment is what makes
    ///      it testable. `vm.setEnv` writes to the PROCESS environment, which no EVM
    ///      snapshot reverts and which forge's concurrent test execution shares, so an
    ///      env-driven test of this passes or fails on the order the suite happened to run
    ///      in. By argument it is deterministic.
    /// @param pools the configured pool set, in the order the vault constructor will see it
    /// @return wbtc `pools[1]`'s token0 - the token the WBTC pool prices, which the vault
    ///         makes `valuationPoolOf(WBTC)` under its first-pool-wins rule
    function _requireSepoliaPoolShape(address[] memory pools) internal view returns (address wbtc) {
        wbtc = IUniswapV3Pool(pools[1]).token0();
        require(IUniswapV3Pool(pools[0]).token0() != wbtc, "HelperConfig: pool 0 must not be the WBTC pair");
    }
}
