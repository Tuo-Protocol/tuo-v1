// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {TuoVault} from "../../src/TuoVault.sol";
import {TuoVaultStorage} from "../../src/TuoVaultStorage.sol";
import {TuoConstants} from "../../src/libraries/TuoConstants.sol";
import {Deploy} from "../../script/Deploy.s.sol";

contract ForkDeployHarness is Deploy {
    function provisionOracleRings(address[] memory pools) external {
        _provisionOracleRings(pools);
    }
}

/// @dev The Arbitrum One pool set as `HelperConfig` configures it. The WBTC/USDC ring was
///      provisioned to 1,000 slots against a constructor floor of 2,000, so the vault could
///      not be deployed against it. This pins that the deploy script raises the ring first
///      and that the live history already answers the TWAP window the post-deploy probe
///      reads. Skipped when ARBITRUM_RPC_URL is unset; honours ARBITRUM_FORK_BLOCK.
contract ForkDeployOracleRingTest is Test {
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address internal constant POOL_WETH_USDC = 0xC6962004f452bE9203591991D15f6b388e09E8D0;
    address internal constant POOL_WBTC_USDC = 0x0E4831319A50228B9e450861297aB92dee15B44F;

    bool internal forked;

    function setUp() public {
        string memory url = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        forked = true;

        uint256 forkBlock = vm.envOr("ARBITRUM_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, forkBlock);
    }

    function test_Fork_DeployProvisionsTheWbtcOracleRing() public {
        if (!forked) return vm.skip(true);

        address[] memory pools = new address[](2);
        pools[0] = POOL_WETH_USDC;
        pools[1] = POOL_WBTC_USDC;

        new ForkDeployHarness().provisionOracleRings(pools);

        for (uint256 i = 0; i < pools.length; i++) {
            (,,,, uint16 cardinalityNext,,) = IUniswapV3Pool(pools[i]).slot0();
            assertGe(cardinalityNext, TuoConstants.MIN_OBSERVATION_CARDINALITY, "ring below the vault's floor");
        }

        TuoVault vault = new TuoVault(_arbitrumOneConfig(pools));
        assertTrue(vault.isPoolAllowlisted(POOL_WBTC_USDC), "wbtc pool not allowlisted");

        uint32[] memory window = new uint32[](2);
        window[0] = TuoConstants.TWAP_WINDOW;
        IUniswapV3Pool(POOL_WBTC_USDC).observe(window);
    }

    function _arbitrumOneConfig(address[] memory pools) internal returns (TuoVaultStorage.InitConfig memory) {
        address[] memory hlOperators = new address[](1);
        hlOperators[0] = makeAddr("hlOperator");
        address[] memory aggregators = new address[](1);
        aggregators[0] = makeAddr("aggregator");
        TuoVaultStorage.ProductInit[] memory products = new TuoVaultStorage.ProductInit[](1);
        products[0] = TuoVaultStorage.ProductInit({code: 1, label: "BP_CORE", maxHedgeBps: 5_000, maxLpCount: 3});

        return TuoVaultStorage.InitConfig({
            usdc: USDC,
            weth: WETH,
            positionManager: NPM,
            hlOperators: hlOperators,
            treasury: makeAddr("treasury"),
            keeper: makeAddr("keeper"),
            pauser: makeAddr("pauser"),
            pools: pools,
            depositTokens: new address[](0),
            aggregators: aggregators,
            products: products,
            perNftCapUsdc: 25_000e6,
            keeperSwapSlippageBps: 100,
            nftBaseURI: "https://api.tuo.finance/nft/"
        });
    }
}
