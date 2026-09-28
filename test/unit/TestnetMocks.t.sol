// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {TestnetUSDC} from "../../script/mocks/TestnetUSDC.sol";
import {TestnetWBTC} from "../../script/mocks/TestnetWBTC.sol";

/// @title TestnetMocksTest - the properties the Sepolia fixtures are load-bearing for
/// @notice Both mocks are pinned by more than their own behaviour. Their DECIMALS have to
///         match the frozen engine's `POOL_META` (`d0`/`d1`), because that is what converts
///         a price to a tick; and their CREATION CODE has to be constant and distinct,
///         because `SetupSepolia` mines a CREATE2 salt against its hash to fix each mock's
///         position in the token sort order.
contract TestnetMocksTest is Test {
    TestnetUSDC internal usdc;
    TestnetWBTC internal wbtc;

    function setUp() public {
        usdc = new TestnetUSDC();
        wbtc = new TestnetWBTC();
    }

    /// @dev `POOL_META['WETH/USDC']` and `['WBTC/USDC']` both carry `d1: 6`. A mock that
    ///      drifted from 6 would price every pool wrong while every unit test stayed green.
    function test_TestnetUsdcHasSixDecimals() public view {
        assertEq(usdc.decimals(), 6, "the engine's d1 for both USDC pools");
    }

    /// @dev `POOL_META['WBTC/USDC']` carries `d0: 8`.
    function test_TestnetWbtcHasEightDecimals() public view {
        assertEq(wbtc.decimals(), 8, "the engine's d0 for WBTC/USDC");
    }

    /// @dev The whole point of a testnet mock: anyone rehearsing can fund themselves past
    ///      `TuoConstants.MIN_DEPOSIT_USDC` without a faucet.
    function test_TestnetWbtcMintIsUnpermissioned() public {
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        wbtc.mint(stranger, 5e8);

        assertEq(wbtc.balanceOf(stranger), 5e8);
    }

    /// @dev The salts are mined per initcode hash. Two mocks with identical creation code
    ///      would mine to the SAME address, and the second deployment would revert inside
    ///      the deterministic deployer - so the distinctness is a precondition of the setup
    ///      script, not a triviality about ERC-20 metadata.
    function test_TestnetMocksHaveDistinctCreationCode() public pure {
        assertTrue(
            keccak256(type(TestnetUSDC).creationCode) != keccak256(type(TestnetWBTC).creationCode),
            "identical initcode would collide the two mines onto one address"
        );
    }

    /// @dev Under CREATE2 through the deterministic deployer, `msg.sender` inside a
    ///      constructor is the PROXY, not the deployer. A mock that minted a founder balance
    ///      to `msg.sender` would silently fund the proxy instead, so neither constructor
    ///      may allocate anything.
    function test_TestnetMocksMintNothingAtConstruction() public view {
        assertEq(usdc.totalSupply(), 0, "USDC must be minted explicitly, never in the constructor");
        assertEq(wbtc.totalSupply(), 0, "WBTC must be minted explicitly, never in the constructor");
    }
}
