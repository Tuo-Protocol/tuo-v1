// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {TuoSwapRouter} from "../../src/TuoSwapRouter.sol";
import {ITuoSwapRouter} from "../../src/interfaces/ITuoSwapRouter.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev The test contract deploys the router, so it plays the vault role
///      (router.vault == deployer).
contract TuoSwapRouterTest is Test {
    TuoSwapRouter internal router;
    MockAggregator internal aggregator;
    MockAggregator internal rogueAggregator;
    MockERC20 internal usdc;
    MockERC20 internal weth;

    function setUp() public {
        aggregator = new MockAggregator();
        rogueAggregator = new MockAggregator();

        address[] memory allowed = new address[](1);
        allowed[0] = address(aggregator);
        router = new TuoSwapRouter(allowed);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(router), type(uint256).max);
    }

    function _fillData(uint256 spend, uint256 payout) internal view returns (bytes memory) {
        return abi.encodeCall(MockAggregator.fill, (address(usdc), address(weth), spend, payout));
    }

    function test_VaultIsDeployer() public view {
        assertEq(router.VAULT(), address(this));
        assertTrue(router.isAggregator(address(aggregator)));
        assertFalse(router.isAggregator(address(rogueAggregator)));
    }

    /// @dev A zero in the constructor list used to allowlist `address(0)`. The call to
    ///      an empty account then "succeeds", so nothing failed until
    ///      `InputNotFullySpent` happened to catch it - safe by accident, which is not
    ///      safe.
    function test_RevertWhen_ConstructorAggregatorIsZero() public {
        address[] memory allowed = new address[](2);
        allowed[0] = address(aggregator);
        allowed[1] = address(0);
        vm.expectRevert(ITuoSwapRouter.ZeroAddress.selector);
        new TuoSwapRouter(allowed);
    }

    function test_SwapSweepsOutputToVault() public {
        vm.expectEmit(address(router));
        emit ITuoSwapRouter.SwapExecuted(address(aggregator), address(usdc), address(weth), 10_000e6, 3e18);

        uint256 amountOut =
            router.swap(address(aggregator), address(usdc), address(weth), 10_000e6, 3e18, _fillData(10_000e6, 3e18));

        assertEq(amountOut, 3e18);
        assertEq(weth.balanceOf(address(this)), 3e18, "output must land on the vault");
        assertEq(weth.balanceOf(address(router)), 0, "router keeps nothing");
        assertEq(usdc.balanceOf(address(router)), 0, "router keeps nothing");
        assertEq(usdc.allowance(address(router), address(aggregator)), 0, "approval must be cleared");
    }

    function test_RevertWhen_SwapCallerIsNotVault() public {
        vm.expectRevert(ITuoSwapRouter.OnlyVault.selector);
        vm.prank(makeAddr("intruder"));
        router.swap(address(aggregator), address(usdc), address(weth), 1e6, 0, "");
    }

    function test_RevertWhen_SwapAggregatorIsNotAllowlisted() public {
        vm.expectRevert(
            abi.encodeWithSelector(ITuoSwapRouter.AggregatorNotAllowlisted.selector, address(rogueAggregator))
        );
        router.swap(address(rogueAggregator), address(usdc), address(weth), 1e6, 0, "");
    }

    function test_RevertWhen_SwapTokensAreIdentical() public {
        vm.expectRevert(ITuoSwapRouter.SameToken.selector);
        router.swap(address(aggregator), address(usdc), address(usdc), 1e6, 0, "");
    }

    function test_RevertWhen_SwapOutputIsBelowMinimum() public {
        vm.expectRevert(abi.encodeWithSelector(ITuoSwapRouter.SlippageExceeded.selector, 2e18, 3e18));
        router.swap(address(aggregator), address(usdc), address(weth), 10_000e6, 3e18, _fillData(10_000e6, 2e18));
    }

    function test_RevertWhen_SwapInputIsNotFullySpent() public {
        vm.expectRevert(abi.encodeWithSelector(ITuoSwapRouter.InputNotFullySpent.selector, 4_000e6));
        router.swap(address(aggregator), address(usdc), address(weth), 10_000e6, 1e18, _fillData(6_000e6, 1e18));
    }

    function test_RevertWhen_AggregatorCallFails() public {
        vm.expectRevert(ITuoSwapRouter.SwapCallFailed.selector);
        router.swap(
            address(aggregator), address(usdc), address(weth), 1e6, 0, abi.encodeCall(MockAggregator.alwaysReverts, ())
        );
    }
}
