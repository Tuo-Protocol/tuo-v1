// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {TuoVault} from "../../src/TuoVault.sol";
import {TuoVaultStorage} from "../../src/TuoVaultStorage.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/external/INonfungiblePositionManager.sol";
import {PoolTwap} from "../../src/libraries/PoolTwap.sol";
import {PositionValuation} from "../../src/libraries/PositionValuation.sol";
import {TuoConstants} from "../../src/libraries/TuoConstants.sol";
import {ForkAggregator} from "./helpers/ForkAggregator.sol";
import {TestnetPoolPoker} from "../../script/mocks/TestnetPoolPoker.sol";

/// @dev Arbitrum One fork tests: real NPM, real WETH/USDC 0.05% pool, real TWAP
///      observations. Skipped when ARBITRUM_RPC_URL is unset. Pin ARBITRUM_FORK_BLOCK for
///      reproducibility (defaults to latest).
///
///      The suite deliberately covers BOTH LP shapes. A single-sided range strictly below
///      spot is the one configuration where the amounts are tick-invariant, which is
///      precisely why the original fork rehearsal passed while the LP slippage floors were
///      broken; the in-range two-sided test below is the one that would have caught it,
///      and the PoolPoker is what lets the burn leg see a moved price at all.
contract ForkVaultLifecycleTest is Test {
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address internal constant POOL_WETH_USDC = 0xC6962004f452bE9203591991D15f6b388e09E8D0;

    TuoVault internal vault;
    ForkAggregator internal aggregator;
    TestnetPoolPoker internal poker;
    bool internal forked;

    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal pauser = makeAddr("pauser");
    address internal hlOperator = makeAddr("hlOperator");
    address internal alice = makeAddr("alice");

    function setUp() public {
        string memory url = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        forked = true;

        uint256 forkBlock = vm.envOr("ARBITRUM_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, forkBlock);

        aggregator = new ForkAggregator();
        poker = new TestnetPoolPoker();

        address[] memory pools = new address[](1);
        pools[0] = POOL_WETH_USDC;
        address[] memory depositTokens = new address[](0);
        address[] memory aggregators = new address[](1);
        aggregators[0] = address(aggregator);
        TuoVaultStorage.ProductInit[] memory products = new TuoVaultStorage.ProductInit[](2);
        products[0] = TuoVaultStorage.ProductInit({code: 1, label: "BP_CORE", maxHedgeBps: 5_000, maxLpCount: 3});
        products[1] = TuoVaultStorage.ProductInit({code: 2, label: "DH_STANDALONE", maxHedgeBps: 9_000, maxLpCount: 1});

        address[] memory hlOperators = new address[](1);
        hlOperators[0] = hlOperator;

        vault = new TuoVault(
            TuoVaultStorage.InitConfig({
                usdc: USDC,
                weth: WETH,
                positionManager: NPM,
                hlOperators: hlOperators,
                treasury: treasury,
                keeper: keeper,
                pauser: pauser,
                pools: pools,
                depositTokens: depositTokens,
                aggregators: aggregators,
                products: products,
                perNftCapUsdc: 25_000e6,
                keeperSwapSlippageBps: 100,
                nftBaseURI: "https://api.tuo.finance/nft/"
            })
        );

        // Inventory for the aggregator (both legs) and for the poker's swaps.
        deal(USDC, address(aggregator), 5_000_000e6);
        deal(WETH, address(aggregator), 2_000 ether);
        deal(USDC, address(poker), 50_000_000e6);
        deal(WETH, address(poker), 20_000 ether);
    }

    function test_Fork_TwapTracksSpotInCalmMarkets() public {
        if (!forked) return vm.skip(true);
        (, int24 spotTick,,,,,) = IUniswapV3Pool(POOL_WETH_USDC).slot0();
        int24 meanTick = PoolTwap.twapTick(POOL_WETH_USDC);
        int256 delta = int256(spotTick) - int256(meanTick);
        if (delta < 0) delta = -delta;
        assertLt(delta, 200, "spot vs 30-min TWAP unusually wide; pick a calmer fork block");
    }

    function test_Fork_FullLifecycleDepositMintBurnWithdraw() public {
        if (!forked) return vm.skip(true);

        // --- deposit ------------------------------------------------------
        deal(USDC, alice, 10_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), 10_000e6);
        uint256 nftId = vault.deposit(USDC, 10_000e6, 1, 0, "", 0);
        vm.stopPrank();
        assertEq(vault.settlementNav(nftId), 10_000e6);

        // --- mint a single-sided USDC range below spot ---------------------
        (, int24 spotTick,,,,,) = IUniswapV3Pool(POOL_WETH_USDC).slot0();
        int24 spacing = IUniswapV3Pool(POOL_WETH_USDC).tickSpacing();
        // Deliberate divide-then-multiply: this rounds the tick DOWN to a multiple of
        // tickSpacing, which is exactly what the NPM requires. Multiplying first would
        // defeat the alignment.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 tickUpper = ((spotTick - 2 * spacing) / spacing) * spacing;
        int24 tickLower = tickUpper - 50 * spacing;

        // WETH (token0) < USDC (token1) on Arbitrum: below-spot ranges are all-USDC.
        vm.prank(keeper);
        (uint256 lpId, uint128 liquidity) = vault.mintLp(nftId, POOL_WETH_USDC, tickLower, tickUpper, 0, 5_000e6);
        assertGt(liquidity, 0);

        // Real-NPM mint consumes nearly all desired USDC; idle + LP value must still
        // equal the deposit within rounding.
        uint256 nav = vault.settlementNav(nftId);
        assertApproxEqRel(nav, 10_000e6, 0.001e18, "NAV must survive the mint");

        // --- burn the LP back to idle --------------------------------------
        vm.prank(keeper);
        (uint256 out0, uint256 out1) = vault.burnLp(nftId, lpId);
        assertEq(out0, 0, "no WETH from an all-USDC range");
        assertApproxEqRel(out1, 5_000e6, 0.001e18);
        assertEq(vault.getPosition(nftId).lpTokenIds.length, 0);

        // --- withdraw everything -------------------------------------------
        vm.startPrank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vault.withdraw(nftId, USDC, 0, "");
        vm.stopPrank();

        // Rounding dust aside, the full deposit returns; no profit -> no fee.
        assertApproxEqAbs(IERC20(USDC).balanceOf(alice), 10_000e6, 10, "principal returns");
        assertEq(vault.accruedFeesUsdc(), 0, "no fee without profit");
    }

    function test_Fork_MintLpRespectsPerNftAttribution() public {
        if (!forked) return vm.skip(true);

        deal(USDC, alice, 20_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), 20_000e6);
        uint256 a = vault.deposit(USDC, 10_000e6, 1, 0, "", 0);
        uint256 b = vault.deposit(USDC, 10_000e6, 2, 0, "", 0);
        vm.stopPrank();

        (, int24 spotTick,,,,,) = IUniswapV3Pool(POOL_WETH_USDC).slot0();
        int24 spacing = IUniswapV3Pool(POOL_WETH_USDC).tickSpacing();
        // Deliberate divide-then-multiply: this rounds the tick DOWN to a multiple of
        // tickSpacing, which is exactly what the NPM requires. Multiplying first would
        // defeat the alignment.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 tickUpper = ((spotTick - 2 * spacing) / spacing) * spacing;

        vm.prank(keeper);
        vault.mintLp(a, POOL_WETH_USDC, tickUpper - 50 * spacing, tickUpper, 0, 8_000e6);

        // Position B's idle is untouched by position A's mint.
        assertEq(vault.idleBalance(b, USDC), 10_000e6);
        assertApproxEqRel(vault.settlementNav(a), 10_000e6, 0.001e18);
        assertEq(vault.settlementNav(b), 10_000e6);
    }

    // -------------------------------------- the tick-sensitive configuration

    /// @notice An in-range two-sided mint with DELIBERATELY non-ratio amounts, a real
    ///         price move, then a burn and the protected exit. Every one of those steps
    ///         reverted against the original contract: the mint because its share-of-desired
    ///         floors demanded the keeper's offered ratio match the pool's (the mint now
    ///         carries no per-leg floor at all), the burn because the per-leg floors were
    ///         computed at the mean tick while `decreaseLiquidity` returns amounts at spot,
    ///         and `withdraw` because with the LP stuck it hit `InsufficientIdle` and left
    ///         `emergencyWithdraw` as the only door.
    function test_Fork_InRangeTwoSidedMintBurnWithdraw() public {
        if (!forked) return vm.skip(true);

        deal(USDC, alice, 10_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), 10_000e6);
        uint256 nftId = vault.deposit(USDC, 10_000e6, 1, 0, "", 0);
        vm.stopPrank();
        uint256 navBefore = vault.settlementNav(nftId);

        // 1. Fund the WETH leg through the real swapIdle path: router, aggregator, and
        //    the vault's own TWAP floor, which passes on merit because we quote at TWAP.
        _keeperSwapAtTwap(nftId, USDC, WETH, 4_000e6);

        // 2. Straddle spot with amounts that are nowhere near the pool's ratio - all the
        //    WETH the position holds, plus 3,000 USDC.
        int24 spacing = IUniswapV3Pool(POOL_WETH_USDC).tickSpacing();
        int24 center = _alignedSpotTick(spacing);
        (uint256 lpId, uint128 liquidity) =
            _keeperMint(nftId, center - 20 * spacing, center + 20 * spacing, vault.idleBalance(nftId, WETH), 3_000e6);
        assertGt(liquidity, 0, "in-range two-sided mint must not revert");
        assertApproxEqRel(vault.settlementNav(nftId), navBefore, 0.01e18, "NAV across the mint");
        assertTrue(
            vault.idleBalance(nftId, USDC) > 0 || vault.idleBalance(nftId, WETH) > 0, "refund path credited idle"
        );

        // 3. Move spot ~120 ticks, inside the band checkDeviation permits.
        (, int24 spotTick,,,,,) = IUniswapV3Pool(POOL_WETH_USDC).slot0();
        poker.pokeTo(IUniswapV3Pool(POOL_WETH_USDC), spotTick + 120);

        // 4. Burn. Against the pre-fix contract this reverted "Price slippage check".
        vm.prank(keeper);
        vault.burnLp(nftId, lpId);
        assertEq(vault.getPosition(nftId).lpTokenIds.length, 0);

        // 5. The protected exit must be reachable - why the burn floor is on combined value.
        _keeperSwapAtTwap(nftId, WETH, USDC, vault.idleBalance(nftId, WETH));
        vm.startPrank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vault.withdraw(nftId, USDC, 0, "");
        vm.stopPrank();
        assertApproxEqRel(IERC20(USDC).balanceOf(alice), 10_000e6, 0.02e18, "principal returns");
    }

    function test_Fork_RevertWhen_MintLpIsBeyondTheDeviationBand() public {
        if (!forked) return vm.skip(true);

        deal(USDC, alice, 10_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), 10_000e6);
        uint256 nftId = vault.deposit(USDC, 10_000e6, 1, 0, "", 0);
        vm.stopPrank();

        int24 spacing = IUniswapV3Pool(POOL_WETH_USDC).tickSpacing();
        int24 center = _alignedSpotTick(spacing);
        poker.pokeTo(
            IUniswapV3Pool(POOL_WETH_USDC),
            PoolTwap.twapTick(POOL_WETH_USDC) + TuoConstants.MAX_TWAP_DEVIATION_TICKS + 300
        );

        vm.expectRevert(abi.encodeWithSelector(PoolTwap.TwapDeviationTooHigh.selector, POOL_WETH_USDC));
        vm.prank(keeper);
        vault.mintLp(nftId, POOL_WETH_USDC, center - 20 * spacing, center + 20 * spacing, 0, 5_000e6);
    }

    /// @dev The real pool's sort order and decimals: WETH is token0, so it is cheap against
    ///      USDC BELOW the mean. Spot is poked to the edge of the gate on that side and the
    ///      keeper's counterparty fills at the 30-minute mean. The mean pair alone reads that
    ///      fill as value-neutral; the vault charges what it gives up against the spot pair.
    function test_Fork_SwapIdleChargesTheSpotMeasuredLossAtTheBandEdge() public {
        if (!forked) return vm.skip(true);

        deal(USDC, alice, 25_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), 25_000e6);
        uint256 nftId = vault.deposit(USDC, 25_000e6, 1, 0, "", 0);
        vm.stopPrank();

        // One tick inside the edge: a downward poke can settle a tick below its target.
        int24 meanTick = PoolTwap.twapTick(POOL_WETH_USDC);
        poker.pokeTo(IUniswapV3Pool(POOL_WETH_USDC), meanTick - TuoConstants.MAX_TWAP_DEVIATION_TICKS + 1);
        (, int24 spotTick,,,,,) = IUniswapV3Pool(POOL_WETH_USDC).slot0();

        uint256 amountIn = 10_000e6;
        uint256 meanQuote = PoolTwap.quoteFromUsdcAtTick(meanTick, WETH, USDC, amountIn);
        uint256 expected = amountIn - PoolTwap.quoteToUsdcAtTick(spotTick, WETH, USDC, meanQuote);
        assertApproxEqRel(expected, 198e6, 0.02e18, "about 198 bps of the leg");

        bytes memory data =
            abi.encode(address(aggregator), abi.encodeCall(ForkAggregator.fill, (USDC, WETH, amountIn, meanQuote)));
        vm.prank(keeper);
        vault.swapIdle(nftId, USDC, WETH, amountIn, 0, data);

        (, uint256 loss,) = vault.keeperBudgetOf(nftId);
        assertEq(loss, expected, "charged at the spot tick, not the mean");
    }

    /// @dev The mint-side twin of the swap test above. Spot is poked to the edge of the gate
    ///      ABOVE the mean, so the narrowest range at or below spot is funded in USDC alone
    ///      (WETH is token0 on Arbitrum). Valued at the mean that liquidity is worth less than
    ///      the USDC that went in, and the vault charges exactly that gap, which is also the
    ///      drop its own settlement NAV books across the mint.
    function test_Fork_MintLpChargesTheMeanMeasuredGapAtTheBandEdge() public {
        if (!forked) return vm.skip(true);

        deal(USDC, alice, 25_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), 25_000e6);
        uint256 nftId = vault.deposit(USDC, 25_000e6, 1, 0, "", 0);
        vm.stopPrank();

        // One tick inside the edge: a poke can settle a tick past its target.
        int24 meanTick = PoolTwap.twapTick(POOL_WETH_USDC);
        poker.pokeTo(IUniswapV3Pool(POOL_WETH_USDC), meanTick + TuoConstants.MAX_TWAP_DEVIATION_TICKS - 1);

        int24 spacing = IUniswapV3Pool(POOL_WETH_USDC).tickSpacing();
        int24 tickUpper = _alignedSpotTick(spacing);
        (, int24 spotTick,,,,,) = IUniswapV3Pool(POOL_WETH_USDC).slot0();
        if (tickUpper > spotTick) tickUpper -= spacing;
        int24 tickLower = tickUpper - TuoConstants.MIN_LP_TICK_WIDTH;

        uint256 navBefore = vault.settlementNav(nftId);
        vm.prank(keeper);
        vault.mintLp(nftId, POOL_WETH_USDC, tickLower, tickUpper, 0, 25_000e6);

        (, uint256 loss, uint256 ceiling) = vault.keeperBudgetOf(nftId);
        assertEq(loss, navBefore - vault.settlementNav(nftId), "charged exactly the NAV drop the mint booked");
        assertGt(loss, ceiling / 2, "one edge mint costs more than half the daily ceiling");
        assertApproxEqRel(loss, 231e6, 0.05e18, "about 92 bps of the position");
    }

    /// @notice Cyfrin issue 49. The NPM writes `tokensOwed` only when a position is touched,
    ///         so a range that has traded reports zero fees owed. The live valuation has to
    ///         compute them from the pool's fee growth instead: the real NPM's `collect`
    ///         checkpoints the range and pays exactly those fees, so pulling them out of the
    ///         position must lower NAV by exactly their value, and by nothing else.
    function test_Fork_LiveLpValuationIncludesUncollectedFees() public {
        if (!forked) return vm.skip(true);

        deal(USDC, alice, 20_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), 20_000e6);
        uint256 nftId = vault.deposit(USDC, 20_000e6, 1, 0, "", 0);
        vm.stopPrank();
        _keeperSwapAtTwap(nftId, USDC, WETH, 3_000e6);

        int24 spacing = IUniswapV3Pool(POOL_WETH_USDC).tickSpacing();
        int24 center = _alignedSpotTick(spacing);
        (uint256 lpId, uint128 liquidity) =
            _keeperMint(nftId, center - 20 * spacing, center + 20 * spacing, vault.idleBalance(nftId, WETH), 3_000e6);
        assertGt(liquidity, 0, "in-range two-sided mint");

        // Trade back and forth inside the range. The fees land in the pool's accumulators.
        _pokeTo(center + 8 * spacing);
        _pokeTo(center - 8 * spacing);
        _pokeTo(center);

        (,,,,,,,,,, uint128 owed0, uint128 owed1) = INonfungiblePositionManager(NPM).positions(lpId);
        assertEq(owed0, 0, "nothing in the vault's flow writes tokensOwed0");
        assertEq(owed1, 0, "nothing in the vault's flow writes tokensOwed1");
        uint256 navLive = vault.settlementNav(nftId);

        // The vault owns the NPM token, so it can collect. The proceeds land in the vault
        // untracked, which is the point: they leave the valuation and nothing else moves.
        vm.prank(address(vault));
        (uint256 fees0, uint256 fees1) = INonfungiblePositionManager(NPM)
            .collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: lpId,
                    recipient: address(vault),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
        assertTrue(fees0 > 0 || fees1 > 0, "the range earned");

        uint256 feesUsdc =
            PositionValuation.pairValueUsdcAtTick(PoolTwap.twapTick(POOL_WETH_USDC), WETH, USDC, fees0, fees1, USDC);
        assertApproxEqAbs(navLive - vault.settlementNav(nftId), feesUsdc, 2, "NAV drops by exactly the fees collected");
    }

    /// @notice A skipped fork suite is a silent gate failure, so make the skip visible. This
    ///         cannot assert "some other test ran": Foundry reverts state between test functions,
    ///         so a flag one test sets is never readable here. What it can prove is the condition
    ///         every other test in the file depends on - that setUp really selected an Arbitrum
    ///         One fork instead of returning early or pointing at the wrong chain. When there is
    ///         no RPC this skips like its neighbours, and contracts-fork.yml's Success count is
    ///         what turns a wholly-skipped suite into a red build.
    function test_Fork_ForkTargetsArbitrumOne() public {
        if (!forked) return vm.skip(true);
        assertEq(block.chainid, 42161, "ARBITRUM_RPC_URL does not point at Arbitrum One");
    }

    // ----------------------------------------------------------------- helpers

    /// @dev Round spot DOWN to a multiple of tickSpacing. Deliberate divide-then-multiply.
    function _alignedSpotTick(int24 spacing) internal view returns (int24) {
        (, int24 spotTick,,,,,) = IUniswapV3Pool(POOL_WETH_USDC).slot0();
        // forge-lint: disable-next-line(divide-before-multiply)
        return (spotTick / spacing) * spacing;
    }

    /// @dev A keeper swap priced exactly at the pool TWAP, so `_twapFloor` is exercised as
    ///      a pass rather than accidentally routed around.
    function _keeperSwapAtTwap(uint256 nftId, address tokenIn, address tokenOut, uint256 amountIn) internal {
        uint256 amountOut = tokenIn == USDC
            ? PoolTwap.quoteFromUsdc(POOL_WETH_USDC, tokenOut, USDC, amountIn)
            : PoolTwap.quoteToUsdc(POOL_WETH_USDC, tokenIn, USDC, amountIn);
        bytes memory data = abi.encode(
            address(aggregator), abi.encodeCall(ForkAggregator.fill, (tokenIn, tokenOut, amountIn, amountOut))
        );
        vm.prank(keeper);
        vault.swapIdle(nftId, tokenIn, tokenOut, amountIn, 0, data);
    }

    /// @dev The poker passes the target tick's sqrt ratio as the swap's price limit, and the
    ///      pool rejects a limit equal to its current price ("SPL"). Nothing to move then.
    function _pokeTo(int24 tick) internal {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(POOL_WETH_USDC).slot0();
        if (TickMath.getSqrtRatioAtTick(tick) == sqrtPriceX96) return;
        poker.pokeTo(IUniswapV3Pool(POOL_WETH_USDC), tick);
    }

    /// @dev WETH is token0 and USDC token1 on Arbitrum's 0.05% pool.
    function _keeperMint(uint256 nftId, int24 tickLower, int24 tickUpper, uint256 wethAmount, uint256 usdcAmount)
        internal
        returns (uint256 lpId, uint128 liquidity)
    {
        vm.prank(keeper);
        (lpId, liquidity) = vault.mintLp(nftId, POOL_WETH_USDC, tickLower, tickUpper, wethAmount, usdcAmount);
    }
}
