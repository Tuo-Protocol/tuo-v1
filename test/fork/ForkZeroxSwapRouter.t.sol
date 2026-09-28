// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TuoSwapRouter} from "../../src/TuoSwapRouter.sol";
import {ITuoSwapRouter} from "../../src/interfaces/ITuoSwapRouter.sol";

/// @dev Arbitrum One fork test: genuine 0x AllowanceHolder Settler calldata driven through
///      TuoSwapRouter. Every other swap test drives MockAggregator or ForkAggregator, which pay a
///      fixed amount out of pre-funded inventory - no routing, no partial fill, no surplus refund -
///      so nothing until now exercised the approve / raw-call / balance-delta / full-spend contract
///      against a real aggregator. Skipped when ARBITRUM_RPC_URL is unset; it must be an ARCHIVE
///      node.
///
///      The quote and its block are one unit, so FORK_BLOCK is a constant here and deliberately NOT
///      ARBITRUM_FORK_BLOCK: that variable pins a different block for ForkVaultLifecycle, and
///      letting it move one half of the pair would leave the other half lying.
///
///      The quote is valid only for TAKER. AllowanceHolder pulls sellToken from msg.sender, and
///      Settler pays buyToken to the taker baked into the calldata; `swap` measures amountOut as
///      its OWN balance delta and never forwards a recipient. Quoting for the vault instead - the
///      mistake the backend's ZeroExAdapter documents - therefore delivers nothing here.
///
///      TAKER is CREATE(makeAddr("tuoVaultStandIn"), 0) = keccak(rlp([deployer, nonce])), a
///      function of the deployer and nonce alone. Editing TuoSwapRouter, bumping solc or changing
///      its constructor arguments all leave it in place, so the committed quote survives changes to
///      src/. setUp asserts it rather than trusting it.
///
///      To refresh, one response fills all four constants below - blockNumber, transaction.data,
///      minBuyAmount, buyAmount:
///
///        curl -sS -G 'https://api.0x.org/swap/allowance-holder/quote' \
///          -H "0x-api-key: $ZERO_EX_API_KEY" -H '0x-version: v2' \
///          -d chainId=42161 \
///          -d sellToken=0xaf88d065e77c8cC2239327C5EDb3A432268e5831 \
///          -d buyToken=0x82aF49447D8a07e3bd95BD0d56f35241523fBab1 \
///          -d sellAmount=1000000 \
///          -d taker=0xDd5995D53e5eA76B261B1aB57b2B1B50f7AEcE77 \
///          -d excludedSources=0x_RFQ
///
///      excludedSources drops RFQ, whose market-maker orders are signed against a taker and an
///      expiry and will not replay at a pinned block. transaction.to must come back as
///      ALLOWANCE_HOLDER: this router approves the same address it calls, which is what makes the
///      allowance-holder flow the only 0x flow it can execute.
contract ForkZeroxSwapRouterTest is Test {
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    address internal constant TAKER = 0xDd5995D53e5eA76B261B1aB57b2B1B50f7AEcE77;

    uint256 internal constant SELL_AMOUNT = 1_000_000;

    // ---------------------------------------------------- pinned 0x quote, refresh together
    uint256 internal constant FORK_BLOCK = 496638728;
    uint256 internal constant EXPECTED_BUY_AMOUNT = 430750230954938;
    uint256 internal constant MIN_BUY_AMOUNT = 426442728640500;
    bytes internal constant ZEROX_CALLDATA =
        hex"2213bc0b000000000000000000000000feea2a79d7d3d36753c8917af744d71f13c9b02a000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e583100000000000000000000000000000000000000000000000000000000000f4240000000000000000000000000feea2a79d7d3d36753c8917af744d71f13c9b02a00000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000005a41fff991f000000000000000000000000dd5995d53e5ea76b261b1ab57b2b1b50f7aece7700000000000000000000000082af49447d8a07e3bd95bd0d56f35241523fbab1000000000000000000000000000000000000000000000000000183d8ef5b8ff400000000000000000000000000000000000000000000000000000000000000a0e7836c618cc6d51c80ab310000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000001a00000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000042000000000000000000000000000000000000000000000000000000000000000e4c1fb425e000000000000000000000000feea2a79d7d3d36753c8917af744d71f13c9b02a000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e583100000000000000000000000000000000000000000000000000000000000f42400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006a876e7a00000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000012438c9c147000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e5831000000000000000000000000000000000000000000000000000000000000000f000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e5831000000000000000000000000000000000000000000000000000000000000002400000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000044a9059cbb000000000000000000000000ad01c20d5886137e056775af56915de824c8fce50000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e48d68a156000000000000000000000000feea2a79d7d3d36753c8917af744d71f13c9b02a0000000000000000000000000000000000000000000000000000000000002710000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000040af88d065e77c8cc2239327c5edb3a432268e583100000064fffd8963efd1fc6a506488495d951d5263988d2582af49447d8a07e3bd95bd0d56f35241523fbab100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008434ee90ca000000000000000000000000f5c4f3dc02c3fb9279495a8fef7b0741da95615700000000000000000000000082af49447d8a07e3bd95bd0d56f35241523fbab1000000000000000000000000000000000000000000000000000187f9978d92fa00000000000000000000000000000000000000000000000000000000000027100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    TuoSwapRouter internal router;
    bool internal forked;

    address internal vaultStandIn = makeAddr("tuoVaultStandIn");
    address internal otherVaultStandIn = makeAddr("otherVaultStandIn");

    function setUp() public {
        string memory url = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        forked = true;

        require(ZEROX_CALLDATA.length != 0, "no 0x quote pinned; see this contract's NatSpec");
        vm.createSelectFork(url, FORK_BLOCK);

        router = _deployRouter(vaultStandIn);
        assertEq(address(router), TAKER, "router moved; refetch the 0x quote for the new taker");

        _fund(vaultStandIn, address(router));
    }

    function test_Fork_ZeroxAllowanceHolderSwapSweepsProceedsToVault() public {
        if (!forked) return vm.skip(true);

        // amountOut is whatever the pool pays at this block, so the event's data is checked
        // through the return value and the balance assertions below instead of a literal.
        vm.expectEmit(true, true, true, false, address(router));
        emit ITuoSwapRouter.SwapExecuted(ALLOWANCE_HOLDER, USDC, WETH, SELL_AMOUNT, 0);

        vm.prank(vaultStandIn);
        uint256 amountOut = router.swap(ALLOWANCE_HOLDER, USDC, WETH, SELL_AMOUNT, MIN_BUY_AMOUNT, ZEROX_CALLDATA);

        assertGe(amountOut, MIN_BUY_AMOUNT, "real route must clear its own floor");
        assertApproxEqRel(amountOut, EXPECTED_BUY_AMOUNT, 0.01e18, "delivered far from the quote");
        assertEq(IERC20(WETH).balanceOf(vaultStandIn), amountOut, "output must land on the vault");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router keeps nothing");
        // The full-spend check passing on merit: Settler consumed the whole input.
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "router keeps nothing");
        assertEq(IERC20(USDC).allowance(address(router), ALLOWANCE_HOLDER), 0, "approval cleared");
    }

    function test_Fork_RevertWhen_ZeroxRouteMissesTheVaultFloor() public {
        if (!forked) return vm.skip(true);

        vm.expectPartialRevert(ITuoSwapRouter.SlippageExceeded.selector);
        vm.prank(vaultStandIn);
        router.swap(ALLOWANCE_HOLDER, USDC, WETH, SELL_AMOUNT, EXPECTED_BUY_AMOUNT * 2, ZEROX_CALLDATA);
    }

    /// @notice The taker binding, proven with the same quote. A second router spends its own input
    ///         - AllowanceHolder pulls from whoever calls it - but Settler pays the WETH to the
    ///         taker encoded in the calldata, which is the first router. The second measures a zero
    ///         output delta and dies on its floor, so a route cannot be replayed into a different
    ///         router than it was quoted for.
    function test_Fork_RevertWhen_ZeroxRouteIsExecutedByANonTakerRouter() public {
        if (!forked) return vm.skip(true);

        TuoSwapRouter other = _deployRouter(otherVaultStandIn);
        assertTrue(address(other) != TAKER, "the second router must not be the taker");
        _fund(otherVaultStandIn, address(other));

        vm.expectRevert(abi.encodeWithSelector(ITuoSwapRouter.SlippageExceeded.selector, 0, MIN_BUY_AMOUNT));
        vm.prank(otherVaultStandIn);
        other.swap(ALLOWANCE_HOLDER, USDC, WETH, SELL_AMOUNT, MIN_BUY_AMOUNT, ZEROX_CALLDATA);
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

    /// @dev resetNonce, not setNonce(0), which reverts when the account already has a nonce.
    function _deployRouter(address standIn) internal returns (TuoSwapRouter deployed) {
        vm.resetNonce(standIn);
        address[] memory aggregators = new address[](1);
        aggregators[0] = ALLOWANCE_HOLDER;
        vm.prank(standIn);
        deployed = new TuoSwapRouter(aggregators);
    }

    function _fund(address standIn, address spender) internal {
        deal(USDC, standIn, SELL_AMOUNT);
        vm.prank(standIn);
        IERC20(USDC).approve(spender, SELL_AMOUNT);
    }
}
