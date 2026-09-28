// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {TuoVault} from "../../src/TuoVault.sol";
import {TuoVaultStorage} from "../../src/TuoVaultStorage.sol";
import {TuoPositionNFT} from "../../src/TuoPositionNFT.sol";
import {TuoSwapRouter} from "../../src/TuoSwapRouter.sol";
import {TuoConstants} from "../../src/libraries/TuoConstants.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPositionManager} from "../mocks/MockPositionManager.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

/// @dev Full-system fixture on mocks: two allowlisted pools (WETH/USDC, WBTC/USDC) at
///      TWAP tick 0 (1:1 in raw units - accounting tests care about flows, not
///      economics; real price math is covered by the library unit tests and the fork
///      suite). The test contract itself is not privileged; actors are pranked.
abstract contract VaultTestBase is Test {
    MockERC20 internal usdc;
    MockWETH internal weth;
    MockERC20 internal wbtc;
    MockERC20 internal dai;
    MockUniswapV3Pool internal wethPool;
    MockUniswapV3Pool internal wbtcPool;
    MockPositionManager internal npm;
    MockAggregator internal aggregator;

    TuoVault internal vault;
    TuoPositionNFT internal nft;
    TuoSwapRouter internal router;

    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal pauser = makeAddr("pauser");
    /// @dev Two operators throughout, because one cannot prove the properties that matter:
    ///      that a position binds to the operator it bridged to, that a keeper cannot move
    ///      it to the other one, and that retiring one does not strand it.
    address internal hlOperator = makeAddr("hlOperator");
    address internal hlOperatorB = makeAddr("hlOperatorB");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal mallory = makeAddr("mallory");

    /// @dev Product labels as bytes32 constants: an inline `bytes32("...")` cast is a
    ///      lint finding, and these are compared in several suites.
    bytes32 internal constant LABEL_BP_CORE = "BP_CORE";
    bytes32 internal constant LABEL_DH_STANDALONE = "DH_STANDALONE";

    uint256 internal constant PER_NFT_CAP = 25_000e6;
    /// @dev The launch value is 100 bps; the fixture keeps the original 50 so every fill
    ///      and charge asserted across the suites stays where it was measured.
    uint16 internal constant KEEPER_SWAP_SLIPPAGE_BPS = 50;

    function setUp() public virtual {
        vm.warp(30 days);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockWETH();
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        dai = new MockERC20("Dai", "DAI", 18);
        npm = new MockPositionManager();
        aggregator = new MockAggregator();

        wethPool = _newPool(address(weth), address(usdc));
        wbtcPool = _newPool(address(wbtc), address(usdc));

        address[] memory pools = new address[](2);
        pools[0] = address(wethPool);
        pools[1] = address(wbtcPool);
        address[] memory depositTokens = new address[](2);
        depositTokens[0] = address(wbtc);
        depositTokens[1] = address(dai);
        address[] memory aggregators = new address[](1);
        aggregators[0] = address(aggregator);
        TuoVaultStorage.ProductInit[] memory products = _mvpProducts();
        address[] memory hlOperators = new address[](2);
        hlOperators[0] = hlOperator;
        hlOperators[1] = hlOperatorB;

        vault = new TuoVault(
            TuoVaultStorage.InitConfig({
                usdc: address(usdc),
                weth: address(weth),
                positionManager: address(npm),
                hlOperators: hlOperators,
                treasury: treasury,
                keeper: keeper,
                pauser: pauser,
                pools: pools,
                depositTokens: depositTokens,
                aggregators: aggregators,
                products: products,
                perNftCapUsdc: PER_NFT_CAP,
                keeperSwapSlippageBps: KEEPER_SWAP_SLIPPAGE_BPS,
                nftBaseURI: "https://api.tuo.finance/nft/"
            })
        );
        nft = vault.NFT();
        router = vault.SWAP_ROUTER();

        // Both HL operators pre-approve the vault for inbound margin pulls.
        vm.prank(hlOperator);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(hlOperatorB);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @dev The two MVP products, matching script/HelperConfig's seed.
    function _mvpProducts() internal pure returns (TuoVaultStorage.ProductInit[] memory products) {
        products = new TuoVaultStorage.ProductInit[](2);
        products[0] = TuoVaultStorage.ProductInit({code: 1, label: LABEL_BP_CORE, maxHedgeBps: 5_000, maxLpCount: 3});
        products[1] =
            TuoVaultStorage.ProductInit({code: 2, label: LABEL_DH_STANDALONE, maxHedgeBps: 9_000, maxLpCount: 1});
    }

    function _newPool(address a, address b) internal returns (MockUniswapV3Pool pool) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        pool = new MockUniswapV3Pool(t0, t1, 500);
        pool.setTwapTick(0);
        pool.setSpotTick(0);
        // The NPM mock derives every amount from the pool's live price, so it has to know
        // which pool a (token0, token1, fee) triple belongs to.
        npm.setPool(t0, t1, 500, address(pool));
    }

    /// @dev Vault swap parameter blob: abi.encode(aggregator, aggregator calldata).
    function _swapData(address tokenIn, address tokenOut, uint256 spend, uint256 payout)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(address(aggregator), abi.encodeCall(MockAggregator.fill, (tokenIn, tokenOut, spend, payout)));
    }

    /// @dev `bps` of `amount`, rounded up: the vault's protective floors round up, so a fill
    ///      "at the floor" built with floor division lands one unit under it.
    function _ceilBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps + TuoConstants.BPS_DENOMINATOR - 1) / TuoConstants.BPS_DENOMINATOR;
    }

    function _depositUsdc(address who, uint256 amount) internal returns (uint256 nftId) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        nftId = vault.deposit(address(usdc), amount, 1, 0, "", 0);
        vm.stopPrank();
    }

    /// @dev A complete Hyperliquid round trip through `hlOperator`: `bridged` out, `returned`
    ///      back as the keeper's FINAL return, so settlement is open afterwards. A final
    ///      return needs an armed request, so this leaves a full one pending for `owner`.
    function _hedgeRoundTrip(uint256 nftId, address owner, uint256 bridged, uint256 returned) internal {
        vm.prank(keeper);
        vault.bridgeToHl(nftId, bridged, hlOperator);
        if (returned > bridged) usdc.mint(hlOperator, returned - bridged);
        vm.prank(owner);
        vault.requestWithdraw(nftId, 10_000);
        vm.prank(keeper);
        vault.markBridgeInboundComplete(nftId, returned, true);
    }

    /// @dev Sweep the accrued fee pool to the fee recipient. Fees are pull-payment, so a
    ///      test that wants to assert on the treasury's balance has to claim first,
    ///      exactly as operations will.
    function _claimFees() internal returns (uint256 amountUsdc) {
        vm.prank(treasury);
        amountUsdc = vault.claimFees();
    }

    /// @dev Idle USDC -> WETH via the keeper so LP tests have both legs funded.
    function _keeperSwapToWeth(uint256 nftId, uint256 usdcIn, uint256 wethOut) internal {
        vm.prank(keeper);
        vault.swapIdle(
            nftId,
            address(usdc),
            address(weth),
            usdcIn,
            wethOut,
            _swapData(address(usdc), address(weth), usdcIn, wethOut)
        );
    }

    /// @dev Order a (USDC, WETH) amount pair into the WETH/USDC pool's token slots.
    function _pair(uint256 usdcAmount, uint256 wethAmount) internal view returns (uint256 amount0, uint256 amount1) {
        bool usdcIsToken0 = wethPool.token0() == address(usdc);
        amount0 = usdcIsToken0 ? usdcAmount : wethAmount;
        amount1 = usdcIsToken0 ? wethAmount : usdcAmount;
    }

    /// @dev Mint an LP for the position from its idle balances.
    function _keeperMintLp(uint256 nftId, uint256 usdcAmount, uint256 wethAmount) internal returns (uint256 lpId) {
        (uint256 amount0, uint256 amount1) = _pair(usdcAmount, wethAmount);
        vm.prank(keeper);
        (lpId,) = vault.mintLp(nftId, address(wethPool), -600, 600, amount0, amount1);
    }
}
