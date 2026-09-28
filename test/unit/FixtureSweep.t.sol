// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {FixtureSweep} from "../../script/libraries/FixtureSweep.sol";
import {TestnetAggregator} from "../../script/mocks/TestnetAggregator.sol";
import {TestnetPoolPoker} from "../../script/mocks/TestnetPoolPoker.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

/// @dev The library is `internal`, so it inlines into whoever calls it - which is the whole
///      point here. Both fixtures pay their CALLER, so under `vm.startBroadcast` the script
///      hands the funds to the deployer EOA, and under this harness it hands them to the
///      harness. Testing through the harness therefore tests the exact code path the script
///      broadcasts.
contract FixtureSweepHarness {
    function fromAggregator(address aggregator, address token) external returns (uint256) {
        return FixtureSweep.fromAggregator(aggregator, token);
    }

    function fromPoker(address poker, address token) external returns (uint256) {
        return FixtureSweep.fromPoker(poker, token);
    }

    function unwrap(address weth, uint256 amount) external {
        FixtureSweep.unwrap(weth, amount);
    }

    receive() external payable {}
}

/// @title FixtureSweepTest - recovering the value stranded in the Sepolia fixtures
/// @notice `TestnetAggregator` and `TestnetPoolPoker` have no owner and no sweep function, so
///         every rehearsal generation leaves its WETH inventory behind - and that inventory is
///         wrapped real testnet ETH, the only asset in the setup that is not freely mintable.
///         Recovery leans on what each fixture already exposes to anybody: the aggregator pays
///         `amountOut` to its caller for whatever `amountIn` it is told to take, and the poker's
///         swap callback is unauthenticated. Both are drain vectors, which is exactly why this
///         library must never point at anything outside `script/mocks`.
contract FixtureSweepTest is Test {
    FixtureSweepHarness internal sweeper;
    TestnetAggregator internal aggregator;
    TestnetPoolPoker internal poker;
    MockWETH internal weth;
    MockERC20 internal usdc;

    uint256 internal constant WETH_INVENTORY = 5.1 ether;
    uint256 internal constant USDC_INVENTORY = 1_000_000e6;

    function setUp() public {
        sweeper = new FixtureSweepHarness();
        aggregator = new TestnetAggregator();
        poker = new TestnetPoolPoker();
        weth = new MockWETH();
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // The wrapper is dealt the ETH its own balance sheet claims, so `withdraw` can pay it
        // out; the WETH itself is minted straight to each holder rather than wrapped and
        // transferred, which keeps the fixtures' starting state out of the assertions.
        vm.deal(address(weth), WETH_INVENTORY * 2);
        weth.mint(address(aggregator), WETH_INVENTORY);
        usdc.mint(address(aggregator), USDC_INVENTORY);
    }

    /// @dev The headline case: the aggregator's WETH is real ETH and the next generation needs
    ///      it back.
    function test_SweepsTheAggregatorsWholeInventory() public {
        uint256 swept = sweeper.fromAggregator(address(aggregator), address(weth));

        assertEq(swept, WETH_INVENTORY, "reports what it took");
        assertEq(weth.balanceOf(address(sweeper)), WETH_INVENTORY, "the caller receives it");
        assertEq(weth.balanceOf(address(aggregator)), 0, "the fixture is emptied");
    }

    /// @dev `fill` takes `amountIn` of `tokenIn` from the caller, so a sweep that named a
    ///      different token in would have to hold one. Naming the swept token itself with an
    ///      `amountIn` of zero is what makes the recovery free, and this pins it: the sweeper
    ///      starts with nothing and still ends up funded.
    function test_AggregatorSweepPaysNothingIn() public {
        assertEq(usdc.balanceOf(address(sweeper)), 0, "precondition: the sweeper is empty");

        sweeper.fromAggregator(address(aggregator), address(usdc));

        assertEq(usdc.balanceOf(address(sweeper)), USDC_INVENTORY);
        assertEq(usdc.balanceOf(address(aggregator)), 0);
    }

    /// @dev The poker holds the seed it swaps pools with. Its callback pays `msg.sender` the
    ///      deltas it is handed, and nothing in it checks that a pool is calling.
    function test_SweepsThePokersWholeBalance() public {
        usdc.mint(address(poker), USDC_INVENTORY);
        weth.mint(address(poker), 1 ether);

        uint256 sweptWeth = sweeper.fromPoker(address(poker), address(weth));
        uint256 sweptUsdc = sweeper.fromPoker(address(poker), address(usdc));

        assertEq(sweptWeth, 1 ether);
        assertEq(sweptUsdc, USDC_INVENTORY);
        assertEq(weth.balanceOf(address(poker)), 0, "the fixture is emptied");
        assertEq(usdc.balanceOf(address(poker)), 0, "the fixture is emptied");
        assertEq(weth.balanceOf(address(sweeper)), 1 ether);
        assertEq(usdc.balanceOf(address(sweeper)), USDC_INVENTORY);
    }

    /// @dev A generation that never funded a fixture, or a second sweep of the same one, must
    ///      cost nothing rather than broadcasting a transaction that reverts mid-run.
    ///      `mockCallRevert` is the assertion: it fails the test if the call is made at all.
    function test_AggregatorSweepOfAnEmptyInventoryMakesNoCall() public {
        vm.mockCallRevert(
            address(aggregator), abi.encodeWithSelector(TestnetAggregator.fill.selector), "swept an empty inventory"
        );

        MockERC20 unfunded = new MockERC20("Unfunded", "UNF", 18);

        assertEq(sweeper.fromAggregator(address(aggregator), address(unfunded)), 0, "nothing to take");
    }

    /// @dev Same property on the poker leg.
    function test_PokerSweepOfAnEmptyBalanceMakesNoCall() public {
        vm.mockCallRevert(
            address(poker),
            abi.encodeWithSelector(TestnetPoolPoker.uniswapV3SwapCallback.selector),
            "swept an empty balance"
        );

        assertEq(sweeper.fromPoker(address(poker), address(weth)), 0, "nothing to take");
    }

    /// @dev `SetupSepolia` wraps its aggregator seed out of the deployer's NATIVE ETH
    ///      (`IWETH9.deposit{value: ...}`), so WETH recovered and left wrapped cannot fund the
    ///      next generation. Unwrapping is what closes the loop.
    function test_UnwrapsWethToNativeEth() public {
        sweeper.fromAggregator(address(aggregator), address(weth));
        uint256 ethBefore = address(sweeper).balance;

        sweeper.unwrap(address(weth), WETH_INVENTORY);

        assertEq(weth.balanceOf(address(sweeper)), 0, "the wrapper is emptied");
        assertEq(address(sweeper).balance, ethBefore + WETH_INVENTORY, "the ETH lands on the caller");
    }

    /// @dev A zero unwrap is the normal case on a generation whose aggregator was never given
    ///      a WETH seed (`SEPOLIA_AGGREGATOR_WETH_WEI` defaults to 0).
    function test_UnwrapOfZeroMakesNoCall() public {
        vm.mockCallRevert(address(weth), abi.encodeWithSelector(MockWETH.withdraw.selector), "unwrapped zero");

        sweeper.unwrap(address(weth), 0);
    }
}
