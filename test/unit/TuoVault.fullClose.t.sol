// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {INonfungiblePositionManager} from "../../src/interfaces/external/INonfungiblePositionManager.sol";
import {ITuoVault} from "../../src/interfaces/ITuoVault.sol";
import {PoolTwap} from "../../src/libraries/PoolTwap.sol";
import {PositionValuation} from "../../src/libraries/PositionValuation.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev A 100% withdraw burns the NFT, and nothing reaches a burned position afterwards.
///      Holdings the mean tick values at zero sit outside the settlement NAV, so idle USDC
///      covers the close with them still attached: an LP has to be gone first, and a
///      pool-token balance goes back to the owner in kind.
contract TuoVaultFullCloseTest is VaultTestBase {
    /// @dev About 0.001 raw USDC per raw unit of the other token, so one raw unit quotes at
    ///      zero. The sign depends on which side of the pool USDC sorts to.
    int24 internal constant UNPRICED_TICK = 69_081;

    // ---------------------------------------------------------------- LP gate

    /// @dev An LP whose legs floor to zero at the mean tick adds nothing to settlement NAV,
    ///      so idle USDC alone would cover the close.
    function test_RevertWhen_FullCloseLeavesAnUnpricedLp() public {
        (uint256 nftId,) = _positionWithAnUnpricedLp();
        assertEq(vault.settlementNav(nftId), vault.idleBalance(nftId, address(usdc)), "idle USDC covers the close");

        vm.startPrank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vm.expectRevert(ITuoVault.LpsOutstanding.selector);
        vault.withdraw(nftId, address(usdc), 0, "");
        vm.stopPrank();
    }

    /// @dev The gate runs before settlement is valued, so a priced LP that idle USDC cannot
    ///      cover still reports the LP rather than the shortfall.
    function test_RevertWhen_FullCloseLeavesAPricedLp() public {
        uint256 nftId = _depositUsdc(alice, 20_000e6);
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        _keeperMintLp(nftId, 4_000e6, 3_000e6);

        vm.startPrank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vm.expectRevert(ITuoVault.LpsOutstanding.selector);
        vault.withdraw(nftId, address(usdc), 0, "");
        vm.stopPrank();
    }

    /// @dev The keeper's `burnLp` is what opens the close, and it clears the registry, so
    ///      nothing is left pointing at the burned position.
    function test_FullCloseSettlesAfterTheKeeperBurnsTheLp() public {
        (uint256 nftId, uint256 lpId) = _positionWithAnUnpricedLp();
        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);

        vm.prank(keeper);
        vault.burnLp(nftId, lpId);
        _keeperSellAll(nftId, address(weth));

        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");

        assertEq(vault.lpOwnerOf(lpId), 0, "the registry no longer names the LP");
        assertEq(vault.lpPoolOf(lpId), address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, nftId));
        nft.ownerOf(nftId);
    }

    /// @dev A partial exit keeps the position alive, so an open LP stays its own.
    function test_PartialWithdrawIsNotGatedByAnOpenLp() public {
        (uint256 nftId,) = _positionWithAnUnpricedLp();

        vm.startPrank(alice);
        vault.requestWithdraw(nftId, 9_999);
        vault.withdraw(nftId, address(usdc), 0, "");
        vm.stopPrank();

        assertTrue(vault.getPosition(nftId).active);
    }

    // ------------------------------------------------------ in-kind residue

    /// @dev The close debits the whole settlement NAV from idle USDC, so a pool-token
    ///      balance still idle is one the mean tick quotes at zero. It owes no fee: the
    ///      USDC fee is the whole charge on the profit.
    function test_FullClosePaysAnUnpricedResidueInKind() public {
        uint256 nftId = _depositUsdc(alice, 20_000e6);
        _leaveOneUnpricedRawUnit(nftId, wethPool, address(weth), 1_000e6);
        assertEq(vault.settlementNav(nftId), vault.idleBalance(nftId, address(usdc)), "the residue is outside the NAV");

        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);
        (, uint256 fee, uint256 net) = vault.previewWithdraw(nftId);
        assertEq(fee, 300e6, "30% of the 1,000 USDC profit");

        vm.expectEmit(address(vault));
        emit ITuoVault.EmergencyTokenPaid(nftId, address(weth), 1);
        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");

        assertEq(weth.balanceOf(alice), 1, "the residue reaches the owner in kind");
        assertEq(usdc.balanceOf(alice), net);
        assertEq(vault.idleBalance(nftId, address(weth)), 0, "nothing is left on the burned position");
        assertEq(vault.idleBalance(nftId, address(usdc)), 0);
        assertEq(vault.accruedTokenFees(address(weth)), 0, "the residue is fee-free");
        assertEq(vault.accruedFeesUsdc(), fee, "the USDC fee is the whole charge");
    }

    /// @dev Every pool token is swept, not only the first one.
    function test_FullClosePaysEveryUnpricedResidue() public {
        uint256 nftId = _depositUsdc(alice, 20_000e6);
        _leaveOneUnpricedRawUnit(nftId, wethPool, address(weth), 0);
        _leaveOneUnpricedRawUnit(nftId, wbtcPool, address(wbtc), 0);

        vm.startPrank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vm.expectEmit(address(vault));
        emit ITuoVault.EmergencyTokenPaid(nftId, address(weth), 1);
        vm.expectEmit(address(vault));
        emit ITuoVault.EmergencyTokenPaid(nftId, address(wbtc), 1);
        vault.withdraw(nftId, address(usdc), 0, "");
        vm.stopPrank();

        assertEq(weth.balanceOf(alice), 1);
        assertEq(wbtc.balanceOf(alice), 1);
        assertEq(vault.idleBalance(nftId, address(weth)), 0);
        assertEq(vault.idleBalance(nftId, address(wbtc)), 0);
    }

    /// @dev Paid out in the residue's own token, the owner gets both: the exit swap's
    ///      output, which is what `withdraw` returns, and the residue beside it.
    function test_FullCloseInTheResidueTokenPaysBoth() public {
        uint256 nftId = _depositUsdc(alice, 20_000e6);
        int24 tick = _leaveOneUnpricedRawUnit(nftId, wethPool, address(weth), 0);

        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);
        (,, uint256 net) = vault.previewWithdraw(nftId);
        uint256 wethOut = PoolTwap.quoteFromUsdcAtTick(tick, address(weth), address(usdc), net);

        vm.prank(alice);
        uint256 out = vault.withdraw(nftId, address(weth), 0, _swapData(address(usdc), address(weth), net, wethOut));

        assertEq(out, wethOut, "the return value is the swap output alone");
        assertEq(weth.balanceOf(alice), wethOut + 1, "the residue is paid beside it");
        assertEq(vault.idleBalance(nftId, address(weth)), 0);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev A position holding a dust LP and only USDC idle, at the fixture's 1:1 tick.
    function _positionWithAnUnpricedLp() internal returns (uint256 nftId, uint256 lpId) {
        nftId = _depositUsdc(alice, 20_000e6);
        _keeperSwapToWeth(nftId, 5_000e6, 5_000e6);
        lpId = _keeperMintLp(nftId, 1, 1);
        assertEq(
            PositionValuation.valueLpUsdc(
                INonfungiblePositionManager(address(npm)), address(wethPool), lpId, address(usdc)
            ),
            0,
            "the LP books at zero against the mean tick"
        );
        _keeperSellAll(nftId, address(weth));
    }

    /// @dev Move `pool` to a tick where one raw unit of `token` quotes at zero, buy `token`
    ///      with 5,000 USDC, and sell back all of it but one raw unit for `profitUsdc` more
    ///      than was spent.
    function _leaveOneUnpricedRawUnit(uint256 nftId, MockUniswapV3Pool pool, address token, uint256 profitUsdc)
        internal
        returns (int24 tick)
    {
        tick = pool.token0() == token ? -UNPRICED_TICK : UNPRICED_TICK;
        pool.setTwapTick(tick);
        pool.setSpotTick(tick);

        uint256 bought = PoolTwap.quoteFromUsdcAtTick(tick, token, address(usdc), 5_000e6);
        vm.startPrank(keeper);
        vault.swapIdle(nftId, address(usdc), token, 5_000e6, 0, _swapData(address(usdc), token, 5_000e6, bought));
        vault.swapIdle(
            nftId,
            token,
            address(usdc),
            bought - 1,
            0,
            _swapData(token, address(usdc), bought - 1, 5_000e6 + profitUsdc)
        );
        vm.stopPrank();

        assertEq(vault.idleBalance(nftId, token), 1, "one raw unit left behind");
        assertEq(PoolTwap.quoteToUsdcAtTick(tick, token, address(usdc), 1), 0, "and it quotes at zero");
    }

    function _keeperSellAll(uint256 nftId, address token) internal {
        uint256 balance = vault.idleBalance(nftId, token);
        if (balance == 0) return;
        vm.prank(keeper);
        vault.swapIdle(nftId, token, address(usdc), balance, 0, _swapData(token, address(usdc), balance, balance));
    }
}
