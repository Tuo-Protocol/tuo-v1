// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {HelperConfig} from "../../script/HelperConfig.s.sol";

/// @dev Only `token0` is implemented, which is the whole surface the shape guard reads off a
///      pool. `token1` is there because the deploy assertions read it later; the guard itself
///      never does.
contract PoolStub {
    address public token0;
    address public token1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }
}

/// @dev The guard is internal and its failure is a revert, so it needs a real call frame for
///      `vm.expectRevert` to see the revert below the cheatcode's own depth.
contract SepoliaPoolShapeHarness is HelperConfig {
    function requireSepoliaPoolShape(address[] memory pools) external view returns (address) {
        return _requireSepoliaPoolShape(pools);
    }
}

/// @title HelperConfigSepoliaPoolsTest - the two-pool shape, asserted where it is stated
/// @notice The Sepolia deployment allowlists one WETH/USDC pool and one WBTC/USDC pool, and
///         the WBTC one is where the deposit token is DERIVED from rather than read out of
///         `SEPOLIA_WBTC`.
///
///         `Deploy._assertDeployment` cannot police that. It sees two USDC-paired pools and
///         has no way to know which pairing was intended, so the WETH pool pasted into the
///         WBTC slot deploys a vault that can never price WBTC - and the derived deposit
///         token silently becomes WETH, so even that check passes. The pool allowlist has no
///         setter, so the mistake costs a redeploy. These tests pin the guard that catches
///         it first.
contract HelperConfigSepoliaPoolsTest is Test {
    address internal constant USDC = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal constant WETH = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;
    address internal constant WBTC = 0x2222222222222222222222222222222222222222;

    SepoliaPoolShapeHarness internal harness;
    address internal wethPool;
    address internal wbtcPool;

    function setUp() public {
        harness = new SepoliaPoolShapeHarness();

        wethPool = address(new PoolStub(WETH, USDC));
        wbtcPool = address(new PoolStub(WBTC, USDC));
    }

    function _pools(address first, address second) internal pure returns (address[] memory pools) {
        pools = new address[](2);
        pools[0] = first;
        pools[1] = second;
    }

    /// @dev The shape the Sepolia config declares, and the answer the deposit token is
    ///      derived from.
    function test_TheDeclaredShapeNamesTheWbtcPoolsToken0() public view {
        address named = harness.requireSepoliaPoolShape(_pools(wethPool, wbtcPool));

        assertEq(named, WBTC, "the WBTC deposit token comes from the WBTC pool");
    }

    /// @dev The mistake the whole guard exists for: the WETH pool address pasted into the
    ///      WBTC slot. Nothing downstream can see it - the derived deposit token becomes
    ///      WETH, which the constructor allowlists anyway - so the vault would deploy with
    ///      no way to price, swap into, or LP WBTC at all. It is also what catches one
    ///      address pasted into both env vars, which `Deploy` only sees as a duplicate.
    function test_RevertWhen_TheWbtcSlotHoldsTheWethPool() public {
        address[] memory pools = _pools(wethPool, wethPool);

        vm.expectRevert(bytes("HelperConfig: pool 0 must not be the WBTC pair"));
        harness.requireSepoliaPoolShape(pools);
    }

    /// @dev And the inverse: the WETH slot holding a WBTC pool. That would leave WETH with
    ///      no valuation pool, which `Deploy` does assert - but failing here names the cause
    ///      instead of reporting the symptom after a broadcast.
    function test_RevertWhen_TheWethSlotHoldsAWbtcPool() public {
        address[] memory pools = _pools(wbtcPool, wbtcPool);

        vm.expectRevert(bytes("HelperConfig: pool 0 must not be the WBTC pair"));
        harness.requireSepoliaPoolShape(pools);
    }

    /// @dev The shape is a property of the SET, not of any one entry: whatever the tokens,
    ///      the guard accepts exactly the sets where the two pools pair different tokens,
    ///      and it names the second one's.
    function testFuzz_TheGuardAcceptsExactlyTheDeclaredShape(address token0First, address token0Second) public {
        address[] memory pools =
            _pools(address(new PoolStub(token0First, USDC)), address(new PoolStub(token0Second, USDC)));

        if (token0First == token0Second) {
            vm.expectRevert(bytes("HelperConfig: pool 0 must not be the WBTC pair"));
            harness.requireSepoliaPoolShape(pools);
            return;
        }

        assertEq(harness.requireSepoliaPoolShape(pools), token0Second, "names the WBTC pool's token0");
    }
}
