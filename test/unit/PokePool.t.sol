// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {TuoConstants} from "../../src/libraries/TuoConstants.sol";
import {PokePool} from "../../script/PokePool.s.sol";
import {TestnetPoolPoker} from "../../script/mocks/TestnetPoolPoker.sol";
import {TestnetUSDC} from "../../script/mocks/TestnetUSDC.sol";
import {TestnetWBTC} from "../../script/mocks/TestnetWBTC.sol";

/// @dev The pool surface `PokePool` and `TestnetPoolPoker` actually touch, and nothing else.
///      `test/mocks/MockUniswapV3Pool.sol` is the VAULT's stand-in, has neither `swap` nor
///      `liquidity`, and ten other suites depend on its exact shape, so this suite carries its
///      own stub the way `SetupSepoliaOracleRing.t.sol` carries `RecordingPool`.
///
///      `swap` lands on `landingTick` rather than on the price limit, so the arrival assertion
///      can be shown a pool that under-delivers.
contract PokeStubPool {
    int24 public spotTick;
    int24 public landingTick;
    int24 public meanTick;
    uint128 public liquidity;
    address public token0;
    address public token1;
    uint32 public lastObservationAt;
    bool public oracleReady = true;

    constructor(address token0_, address token1_, int24 spotTick_) {
        token0 = token0_;
        token1 = token1_;
        spotTick = spotTick_;
        landingTick = spotTick_;
        meanTick = spotTick_;
    }

    function setLiquidity(uint128 liquidity_) external {
        liquidity = liquidity_;
    }

    function setLandingTick(int24 landingTick_) external {
        landingTick = landingTick_;
    }

    function setMeanTick(int24 meanTick_) external {
        meanTick = meanTick_;
    }

    function setOracleReady(bool ready) external {
        oracleReady = ready;
    }

    function setLastObservationAt(uint32 at) external {
        lastObservationAt = at;
    }

    function tickSpacing() external pure returns (int24) {
        return 10;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, spotTick, 0, 1, 2000, 0, true);
    }

    function observations(uint256) external view returns (uint32, int56, uint160, bool) {
        return (lastObservationAt, 0, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidity)
    {
        require(oracleReady, "OLD");
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidity = new uint160[](secondsAgos.length);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(meanTick) * int56(uint56(TuoConstants.TWAP_WINDOW));
    }

    function swap(address, bool, int256, uint160, bytes calldata data) external returns (int256, int256) {
        TestnetPoolPoker(msg.sender).uniswapV3SwapCallback(0, 0, data);
        spotTick = landingTick;
        return (0, 0);
    }
}

/// @dev The guards are internal, so they need a real call frame for `vm.expectRevert` to see
///      the revert below the cheatcode's own depth.
///
///      `_loadPoker` is deliberately absent: reaching it needs `vm.setEnv`, and forge's
///      environment is process-global, so a write here leaks into every other suite in the same
///      run. That is why `_preflight` takes the poker as a parameter - the branch that matters,
///      a poker that cannot pay, is covered without touching the environment at all.
contract PokePoolHarness is PokePool {
    function preflight(address pool, address poker, int24 targetTick) external view returns (PokePlan memory) {
        return _preflight(pool, poker, targetTick);
    }

    function assertArrived(int24 spotBefore, int24 spotAfter, int24 targetTick, bool zeroForOne) external pure {
        _assertArrived(spotBefore, spotAfter, targetTick, zeroForOne);
    }

    function secondsUntilGateOpens(uint256 deviation, uint256 secondsSinceLastObservation)
        external
        pure
        returns (uint256)
    {
        return _secondsUntilGateOpens(deviation, secondsSinceLastObservation);
    }

    function owedToken(IUniswapV3Pool pool, int24 targetTick, int24 spotTick) external view returns (address, bool) {
        return _owedToken(pool, targetTick, spotTick);
    }

    function twapReady(IUniswapV3Pool pool) external view returns (bool) {
        return _twapReady(pool);
    }
}

contract PokePoolTest is Test {
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    /// @dev The live WBTC/USDC realignment: tick 69081 to 64712, a 4369-tick move down.
    int24 internal constant SPOT = 69081;
    int24 internal constant TARGET = 64712;
    uint256 internal constant MOVE = 4369;

    PokePoolHarness internal harness;
    TestnetPoolPoker internal poker;
    TestnetUSDC internal usdc;
    TestnetWBTC internal wbtc;
    PokeStubPool internal pool;

    function setUp() public {
        vm.chainId(ARBITRUM_SEPOLIA);
        harness = new PokePoolHarness();
        poker = new TestnetPoolPoker();
        usdc = new TestnetUSDC();
        wbtc = new TestnetWBTC();
        // WBTC as token0 and USDC as token1 is the order `SetupSepolia` mines for.
        pool = new PokeStubPool(address(wbtc), address(usdc), SPOT);
    }

    // ------------------------------------------------------- the gate estimate

    function test_GateEstimateIsZeroWithinTheDeviationBand() public view {
        assertEq(harness.secondsUntilGateOpens(0, 0), 0);
        assertEq(harness.secondsUntilGateOpens(uint256(uint24(TuoConstants.MAX_TWAP_DEVIATION_TICKS)), 0), 0);
    }

    function test_GateEstimateIsZeroOnceTheWindowHasRolled() public view {
        assertEq(harness.secondsUntilGateOpens(MOVE, TuoConstants.TWAP_WINDOW), 0);
        assertEq(harness.secondsUntilGateOpens(MOVE, TuoConstants.TWAP_WINDOW * 2), 0);
    }

    /// @dev Rounded UP, because an under-stated wait sends the operator back to a shut gate.
    function test_GateEstimateMatchesTheWbtcMove() public view {
        assertEq(harness.secondsUntilGateOpens(MOVE, 0), 1718);
    }

    /// @dev Halfway through the window the mean has absorbed half the move, so the deviation
    ///      reads 2184 and the estimate must name the same wall-clock moment as the one taken
    ///      at the poke.
    function test_GateEstimateShrinksConsistentlyAsTheWindowRolls() public view {
        uint256 halfway = harness.secondsUntilGateOpens(MOVE / 2, TuoConstants.TWAP_WINDOW / 2);
        assertEq(halfway + TuoConstants.TWAP_WINDOW / 2, harness.secondsUntilGateOpens(MOVE, 0));
    }

    /// @dev The returned second is the SMALLEST one that clears the gate, which is the property
    ///      the closed form is meant to have.
    function testFuzz_GateEstimateIsTheSmallestSecondThatClears(uint256 deviation) public view {
        uint256 cap = uint256(uint24(TuoConstants.MAX_TWAP_DEVIATION_TICKS));
        deviation = bound(deviation, cap + 1, 800_000);
        uint256 window = TuoConstants.TWAP_WINDOW;
        uint256 wait = harness.secondsUntilGateOpens(deviation, 0);

        assertLe(wait, window);
        assertLe(deviation * (window - wait), cap * window);
        assertGt(deviation * (window - wait + 1), cap * window);
    }

    // ------------------------------------------------------------ which token

    function test_OwedTokenIsToken0WhenTheTargetIsBelowSpot() public view {
        (address token, bool zeroForOne) = harness.owedToken(IUniswapV3Pool(address(pool)), TARGET, SPOT);
        assertEq(token, address(wbtc));
        assertTrue(zeroForOne);
    }

    function test_OwedTokenIsToken1WhenTheTargetIsAboveSpot() public view {
        (address token, bool zeroForOne) = harness.owedToken(IUniswapV3Pool(address(pool)), SPOT + 100, SPOT);
        assertEq(token, address(usdc));
        assertFalse(zeroForOne);
    }

    // -------------------------------------------------------------- preflight

    function test_PreflightNeedsNoInventoryWhenThePoolHasNoLiquidity() public view {
        PokePool.PokePlan memory plan = harness.preflight(address(pool), address(poker), TARGET);
        assertEq(plan.poker, address(poker));
        assertEq(plan.spotTick, SPOT);
        assertEq(plan.owedToken, address(wbtc));
        assertEq(plan.pokerBalance, 0);
        assertEq(plan.poolLiquidity, 0);
    }

    function test_PreflightAcceptsAFundedPokerOnAPoolWithLiquidity() public {
        pool.setLiquidity(1e18);
        wbtc.mint(address(poker), 10e8);
        PokePool.PokePlan memory plan = harness.preflight(address(pool), address(poker), TARGET);
        assertEq(plan.pokerBalance, 10e8);
    }

    /// @dev A realignment moves past the deviation band by definition, so preflight must allow it.
    function test_PreflightAllowsAMoveFarBeyondTheDeviationBand() public view {
        PokePool.PokePlan memory plan = harness.preflight(address(pool), address(poker), TARGET);
        assertGt(
            SafeCast.toUint256(int256(SPOT) - int256(plan.targetTick)),
            SafeCast.toUint256(int256(TuoConstants.MAX_TWAP_DEVIATION_TICKS))
        );
    }

    /// @dev A pool price is not a position boundary, so alignment is not required.
    function test_PreflightAllowsATargetOffTheTickSpacing() public view {
        PokePool.PokePlan memory plan = harness.preflight(address(pool), address(poker), SPOT - 7);
        assertEq(plan.targetTick, SPOT - 7);
    }

    function test_RevertWhen_WrongChain() public {
        vm.chainId(1);
        vm.expectRevert("PokePool: wrong chain");
        harness.preflight(address(pool), address(poker), TARGET);
    }

    function test_RevertWhen_PoolHasNoCode() public {
        vm.expectRevert("PokePool: pool has no code");
        harness.preflight(address(0xdead), address(poker), TARGET);
    }

    /// @dev MIN_SQRT_RATIO is the ratio AT MIN_TICK and the pool wants the limit strictly above
    ///      it, so the extreme tick itself reverts `SPL` with no reason string.
    function test_RevertWhen_TargetTickIsAtMinTick() public {
        vm.expectRevert("PokePool: target tick outside the pool's usable range");
        harness.preflight(address(pool), address(poker), TickMath.MIN_TICK);
    }

    function test_RevertWhen_TargetTickIsAtMaxTick() public {
        vm.expectRevert("PokePool: target tick outside the pool's usable range");
        harness.preflight(address(pool), address(poker), TickMath.MAX_TICK);
    }

    function test_RevertWhen_TargetEqualsSpot() public {
        vm.expectRevert("PokePool: target tick equals spot; nothing to poke");
        harness.preflight(address(pool), address(poker), SPOT);
    }

    function test_RevertWhen_PoolHoldsLiquidityAndThePokerCannotPay() public {
        pool.setLiquidity(1e18);
        vm.expectRevert("PokePool: poker holds none of the token this direction owes");
        harness.preflight(address(pool), address(poker), TARGET);
    }

    // ---------------------------------------------------------- the twap probe

    /// @dev A staticcall to a codeless address succeeds with no data, and here the pool is an
    ///      arbitrary command-line argument rather than a validated env value.
    function test_TwapReadyIsFalseForAnAddressWithNoCode() public view {
        assertFalse(harness.twapReady(IUniswapV3Pool(address(0xdead))));
    }

    function test_TwapReadyIsTrueForAPoolWhoseRingSpansTheWindow() public view {
        assertTrue(harness.twapReady(IUniswapV3Pool(address(pool))));
    }

    function test_TwapReadyIsFalseForAPoolWhoseRingIsTooYoung() public {
        pool.setOracleReady(false);
        assertFalse(harness.twapReady(IUniswapV3Pool(address(pool))));
    }

    // ------------------------------------------------------------- the arrival

    function test_PokeMovesTheStubPoolToTheTarget() public {
        pool.setLandingTick(TARGET);
        poker.pokeTo(IUniswapV3Pool(address(pool)), TARGET);
        assertEq(pool.spotTick(), TARGET);
        harness.assertArrived(SPOT, pool.spotTick(), TARGET, true);
    }

    /// @dev When the limit lands on a tick the loop was already stepping to, the pool sets
    ///      `tick = tickNext - 1` for a downward swap instead of re-deriving it from the price.
    function test_ArrivalAcceptsTheOneTickBoundaryArtifactSwappingDown() public view {
        harness.assertArrived(SPOT, TARGET - 1, TARGET, true);
    }

    function test_RevertWhen_TheOneTickArtifactAppearsSwappingUp() public {
        vm.expectRevert("PokePool: poke stopped short of the target");
        harness.assertArrived(SPOT, SPOT + 99, SPOT + 100, false);
    }

    function test_RevertWhen_ThePokeStopsShortOfTheTarget() public {
        vm.expectRevert("PokePool: poke stopped short of the target");
        harness.assertArrived(SPOT, TARGET + 40, TARGET, true);
    }

    function test_RevertWhen_ThePokeOvershootsTheTarget() public {
        vm.expectRevert("PokePool: poke stopped short of the target");
        harness.assertArrived(SPOT, TARGET - 2, TARGET, true);
    }

    function test_RevertWhen_ThePokeDidNotMoveSpot() public {
        vm.expectRevert("PokePool: the poke did not move spot");
        harness.assertArrived(SPOT, SPOT, TARGET, true);
    }
}
