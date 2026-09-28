// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {SortedCreate2} from "../../script/libraries/SortedCreate2.sol";
import {SetupSepolia} from "../../script/SetupSepolia.s.sol";
import {TestnetUSDC} from "../../script/mocks/TestnetUSDC.sol";
import {TestnetWBTC} from "../../script/mocks/TestnetWBTC.sol";

/// @dev Only `token0()` / `token1()` are implemented, which is the whole surface the guard
///      reads.
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
contract TokenOrderHarness is SetupSepolia {
    function requireUsdcIsToken1(address pool, address usdc) external view {
        _requireUsdcIsToken1(pool, usdc);
    }

    function weth9() external pure returns (address) {
        return DEFAULT_WETH9;
    }
}

/// @title SetupSepoliaTokenOrderTest - the regression that closes the inverted-pool bug
/// @notice Engine v25 is byte-immutable and its `POOL_META` is written for the volatile
///         token as token0 and USDC as token1. `_position_tick_bounds` has no inversion
///         branch for the other ordering, and the keeper hands its ticks to `mintLp`
///         verbatim - so a pool that sorts USDC first does not drift, it mints every range
///         at the exact negative of the intended tick, on the wrong side of spot.
///
///         The first Sepolia deployment shipped exactly that: `TestnetUSDC` landed at
///         `0x7ac62f44...`, below canonical WETH9 `0x980B62Da...`. Circle's faucet USDC
///         fails the same test. Since the vault's pool allowlist has no setter, an inverted
///         pool can only be corrected by redeploying the vault - which is why the guard runs
///         at setup time and again in `Deploy._assertDeployment`, not at first use.
contract SetupSepoliaTokenOrderTest is Test {
    address internal constant USDC = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal constant WETH = 0x1111111111111111111111111111111111111111;
    address internal constant DAI = 0x2222222222222222222222222222222222222222;

    TokenOrderHarness internal harness;

    function setUp() public {
        harness = new TokenOrderHarness();
    }

    function test_UsdcAsToken1Passes() public {
        PoolStub pool = new PoolStub(WETH, USDC);

        harness.requireUsdcIsToken1(address(pool), USDC);
    }

    function test_RevertWhen_UsdcIsToken0() public {
        PoolStub pool = new PoolStub(USDC, WETH);

        vm.expectRevert(bytes("SetupSepolia: USDC must be token1"));
        harness.requireUsdcIsToken1(address(pool), USDC);
    }

    /// @dev The guard is an ORDERING check, not a pairing check. The vault constructor
    ///      already refuses a pool that does not hold USDC at all; this one has to refuse
    ///      the same pool for its own reason rather than passing it through.
    function test_RevertWhen_PoolDoesNotHoldUsdcAtAll() public {
        PoolStub pool = new PoolStub(WETH, DAI);

        vm.expectRevert(bytes("SetupSepolia: USDC must be token1"));
        harness.requireUsdcIsToken1(address(pool), USDC);
    }

    /// @dev Fix 1 end to end, deterministically and with no chain: run the two real mines
    ///      against the real creation-code hashes and the real WETH9 constant, and assert
    ///      the ordering both pools will inherit. If this fails, the deploy would ship
    ///      inverted pools again.
    function test_MinedFixtureSaltsSortWbtcBelowWeth9AndUsdcAbove() public view {
        address weth = harness.weth9();

        (, address wbtc) = SortedCreate2.mineBetween(
            keccak256(type(TestnetWBTC).creationCode), address(0), weth, SortedCreate2.DEFAULT_MAX_TRIES
        );
        (, address usdc) = SortedCreate2.mineBetween(
            keccak256(type(TestnetUSDC).creationCode), weth, address(type(uint160).max), SortedCreate2.DEFAULT_MAX_TRIES
        );

        assertLt(uint160(wbtc), uint160(weth), "WBTC must be token0 of WBTC/USDC");
        assertLt(uint160(weth), uint160(usdc), "WETH must be token0 of WETH/USDC");
        assertLt(uint160(wbtc), uint160(usdc), "and USDC must be token1 of both");
    }

    /// @dev A pool created from the mined addresses passes the guard by construction. This
    ///      is the join between the mining and the assertion: each is sound alone, and this
    ///      says they agree about which side of the pivot is which.
    function test_MinedFixtureAddressesPassTheGuard() public {
        address weth = harness.weth9();
        (, address usdc) = SortedCreate2.mineBetween(
            keccak256(type(TestnetUSDC).creationCode), weth, address(type(uint160).max), SortedCreate2.DEFAULT_MAX_TRIES
        );
        (, address wbtc) = SortedCreate2.mineBetween(
            keccak256(type(TestnetWBTC).creationCode), address(0), weth, SortedCreate2.DEFAULT_MAX_TRIES
        );

        // Uniswap orders a pool's tokens by raw address, so this is exactly what the factory
        // would produce for each pair.
        harness.requireUsdcIsToken1(address(new PoolStub(weth, usdc)), usdc);
        harness.requireUsdcIsToken1(address(new PoolStub(wbtc, usdc)), usdc);
    }
}
