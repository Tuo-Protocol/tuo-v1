// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {TuoConstants} from "../../src/libraries/TuoConstants.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {OracleRing} from "../../script/libraries/OracleRing.sol";

/// @dev Records what the growth loop actually asks the pool for, with the real monotonic
///      `Oracle.grow` semantics: a target at or below the current one is a no-op. Only
///      `slot0` and `increaseObservationCardinalityNext` are implemented, which is the
///      whole surface the loop touches.
contract RecordingPool {
    uint16 public observationCardinalityNext;
    uint16 public largestStep;
    uint256 public calls;

    constructor(uint16 initial) {
        observationCardinalityNext = initial;
    }

    function increaseObservationCardinalityNext(uint16 next) external {
        if (next <= observationCardinalityNext) return;
        uint16 jump = next - observationCardinalityNext;
        if (jump > largestStep) largestStep = jump;
        observationCardinalityNext = next;
        calls++;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, 0, 0, 0, observationCardinalityNext, 0, true);
    }
}

/// @dev The growth loop is internal and state-changing, so it needs a real call frame for
///      `vm.expectRevert` to see its revert at a lower depth than the cheatcode.
contract OracleRingHarness {
    function grow(IUniswapV3Pool pool, uint16 target, uint16 step) external {
        OracleRing.grow(pool, target, step);
    }
}

contract DeployHarness is Deploy {
    function provisionOracleRings(address[] memory pools) external {
        _provisionOracleRings(pools);
    }
}

/// @dev Pins what makes the stepped walk safe: the end state equals the one-shot call, and
///      no single transaction asks for more slots than the step.
contract OracleRingTest is Test {
    uint16 internal constant FLOOR = TuoConstants.MIN_OBSERVATION_CARDINALITY;

    OracleRingHarness internal harness;
    DeployHarness internal deployer;

    function setUp() public {
        harness = new OracleRingHarness();
        deployer = new DeployHarness();
    }

    function test_GrowOracleRingReachesTheProvisionedFloor() public {
        RecordingPool pool = new RecordingPool(1);

        harness.grow(IUniswapV3Pool(address(pool)), FLOOR, 400);

        assertEq(pool.observationCardinalityNext(), FLOOR, "ring must end at the floor");
        assertLe(pool.largestStep(), 400, "no transaction may exceed the step");
        assertEq(pool.calls(), 5, "2000 slots at 400 a time is five transactions");
    }

    function test_GrowOracleRingIsANoOpOnAnAlreadyProvisionedPool() public {
        RecordingPool pool = new RecordingPool(FLOOR);

        harness.grow(IUniswapV3Pool(address(pool)), FLOOR, 400);

        assertEq(pool.calls(), 0, "an already provisioned pool costs nothing to re-run");
    }

    /// @dev The recovery path when a growth transaction has already landed by hand: the
    ///      loop must resume from wherever the live ring got to, not restart.
    function test_GrowOracleRingResumesFromAPartiallyGrownRing() public {
        RecordingPool pool = new RecordingPool(1_600);

        harness.grow(IUniswapV3Pool(address(pool)), FLOOR, 400);

        assertEq(pool.observationCardinalityNext(), FLOOR, "ring must end at the floor");
        assertEq(pool.calls(), 1, "only the remaining 400 slots are worth a transaction");
    }

    /// @dev A step at or above the target is clamped rather than reverting on the
    ///      `target - step` bound, so an operator who sets it too high gets the one-shot
    ///      call they asked for instead of a failed script.
    function test_GrowOracleRingClampsAStepLargerThanTheFloor() public {
        RecordingPool pool = new RecordingPool(1);

        harness.grow(IUniswapV3Pool(address(pool)), FLOOR, type(uint16).max);

        assertEq(pool.observationCardinalityNext(), FLOOR, "clamped to the floor, not overshot");
        assertEq(pool.calls(), 1, "one transaction");
    }

    function test_RevertWhen_CardinalityStepIsZero() public {
        RecordingPool pool = new RecordingPool(1);

        vm.expectRevert(bytes("OracleRing: zero cardinality step"));
        harness.grow(IUniswapV3Pool(address(pool)), FLOOR, 0);
    }

    function testFuzz_GrowOracleRingHonoursTheStepFromAnyStartingRing(uint16 step, uint16 initial) public {
        step = uint16(bound(step, 50, FLOOR));
        initial = uint16(bound(initial, 1, FLOOR));
        RecordingPool pool = new RecordingPool(initial);

        harness.grow(IUniswapV3Pool(address(pool)), FLOOR, step);

        assertEq(pool.observationCardinalityNext(), FLOOR, "ring must end at the floor");
        assertLe(pool.largestStep(), step, "no transaction may exceed the step");
    }

    /// @dev `step` is floored at 1,000 only to bound the loop's iteration count in the fuzzer.
    function testFuzz_GrowOracleRingNeverOverflowsNearTheTypeMaximum(uint16 target, uint16 step, uint16 initial)
        public
    {
        target = uint16(bound(target, 1, type(uint16).max));
        step = uint16(bound(step, 1_000, type(uint16).max));
        initial = uint16(bound(initial, 1, type(uint16).max));
        RecordingPool pool = new RecordingPool(initial);

        harness.grow(IUniswapV3Pool(address(pool)), target, step);

        uint16 expected = initial > target ? initial : target;
        assertEq(pool.observationCardinalityNext(), expected, "ring must end at max(initial, target)");
        assertLe(pool.largestStep(), step, "no transaction may exceed the step");
    }

    function test_GrowOracleRingReachesTheTypeMaximum() public {
        RecordingPool pool = new RecordingPool(type(uint16).max - 1);

        harness.grow(IUniswapV3Pool(address(pool)), type(uint16).max, 1_000);

        assertEq(pool.observationCardinalityNext(), type(uint16).max, "ring must end at the type maximum");
        assertEq(pool.calls(), 1, "one transaction");
    }

    /// @dev The Arbitrum One shape: WBTC/USDC sits at 1,000 slots and WETH/USDC at 9,000.
    ///      The vault constructor rejects the first, so the deploy must raise it in one
    ///      call and must not touch the second.
    function test_ProvisionOracleRingsGrowsOnlyTheShallowPool() public {
        RecordingPool shallow = new RecordingPool(1_000);
        RecordingPool deep = new RecordingPool(9_000);
        address[] memory pools = new address[](2);
        pools[0] = address(deep);
        pools[1] = address(shallow);

        deployer.provisionOracleRings(pools);

        assertEq(shallow.observationCardinalityNext(), FLOOR, "shallow pool must reach the floor");
        assertEq(shallow.calls(), 1, "1000 missing slots fit one transaction");
        assertEq(deep.observationCardinalityNext(), 9_000, "a deeper ring is never shrunk");
        assertEq(deep.calls(), 0, "a provisioned pool costs no transaction");
    }

    function test_ProvisionOracleRingsFromAFreshPoolStaysUnderTheStep() public {
        RecordingPool fresh = new RecordingPool(1);
        address[] memory pools = new address[](1);
        pools[0] = address(fresh);

        deployer.provisionOracleRings(pools);

        assertEq(fresh.observationCardinalityNext(), FLOOR, "fresh pool must reach the floor");
        assertLe(fresh.largestStep(), 1_000, "no deploy transaction may exceed 1000 slots");
        assertEq(fresh.calls(), 2, "1999 missing slots take two transactions");
    }
}
