// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {TuoVault} from "../../src/TuoVault.sol";
import {TuoVaultStorage} from "../../src/TuoVaultStorage.sol";
import {ITuoVault} from "../../src/interfaces/ITuoVault.sol";
import {TuoConstants} from "../../src/libraries/TuoConstants.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev Deployment-time validation and the read surface. The constructor wires the
///      whole system in one transaction with no post-deploy configuration window, so
///      its rejections ARE the safety model - a config that lands wrong cannot be
///      fixed afterwards, it has to be redeployed. The deploy script's
///      post-assertions check the happy path; these check that the bad paths abort.
contract TuoVaultConfigTest is VaultTestBase {
    bytes32 internal constant LABEL_NEW = "NEW";

    /// @dev A valid config, so each test can corrupt exactly one field.
    function _baseConfig() internal view returns (TuoVaultStorage.InitConfig memory cfg) {
        address[] memory pools = new address[](1);
        pools[0] = address(wethPool);
        address[] memory depositTokens = new address[](1);
        depositTokens[0] = address(wbtc);
        address[] memory aggregators = new address[](1);
        aggregators[0] = address(aggregator);
        address[] memory hlOperators = new address[](2);
        hlOperators[0] = hlOperator;
        hlOperators[1] = hlOperatorB;

        cfg = TuoVaultStorage.InitConfig({
            usdc: address(usdc),
            weth: address(weth),
            positionManager: address(npm),
            hlOperators: hlOperators,
            treasury: treasury,
            keeper: keeper,
            pauser: pauser,
            pools: pools,
            depositTokens: depositTokens,
            aggregators: aggregators,
            products: _mvpProducts(),
            perNftCapUsdc: PER_NFT_CAP,
            keeperSwapSlippageBps: KEEPER_SWAP_SLIPPAGE_BPS,
            nftBaseURI: "https://api.tuo.finance/nft/"
        });
    }

    // -------------------------------------------------- construction: rejections

    function test_RevertWhen_ConstructorGetsZeroAddressInARequiredSlot() public {
        // Every slot below is immutable or role-granting; a zero here is unrecoverable.
        for (uint256 i = 0; i < 7; i++) {
            TuoVaultStorage.InitConfig memory cfg = _baseConfig();
            if (i == 0) cfg.usdc = address(0);
            else if (i == 1) cfg.weth = address(0);
            else if (i == 2) cfg.positionManager = address(0);
            // A zero anywhere INSIDE the operator array, not just a zero array.
            else if (i == 3) cfg.hlOperators[1] = address(0);
            else if (i == 4) cfg.treasury = address(0);
            else if (i == 5) cfg.keeper = address(0);
            else cfg.pauser = address(0);

            vm.expectRevert(ITuoVault.ZeroAddress.selector);
            new TuoVault(cfg);
        }
    }

    /// @dev A vault with an empty operator set is live but cannot ever hedge: the first
    ///      `bridgeToHl` would revert with nothing an admin call could fix except adding
    ///      an operator after the fact. The constructor refuses instead.
    function test_RevertWhen_ConstructorGetsNoHlOperators() public {
        TuoVaultStorage.InitConfig memory cfg = _baseConfig();
        cfg.hlOperators = new address[](0);

        vm.expectRevert(ITuoVault.ZeroAddress.selector);
        new TuoVault(cfg);
    }

    /// @dev A seed can name a protocol-owned address as readily as a later setter call can:
    ///      all three are CREATE-derived and so predictable before the deployment lands, the
    ///      NFT and the router being the vault's first and second CREATE. This is what pins
    ///      the seed loop below both `new`s - run it before them and `NFT` and `SWAP_ROUTER`
    ///      are still zero, so two of these three would seed through. A reverted CREATE still
    ///      consumes the creator's nonce, hence the recompute per iteration.
    function test_RevertWhen_ConstructorSeedsAProtocolOwnedHlOperator() public {
        for (uint256 i = 0; i < 3; i++) {
            address futureVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
            address seeded = i == 0 ? futureVault : vm.computeCreateAddress(futureVault, i);

            TuoVaultStorage.InitConfig memory cfg = _baseConfig();
            cfg.hlOperators[1] = seeded;

            vm.expectRevert(abi.encodeWithSelector(ITuoVault.ProtocolOwnedAddress.selector, seeded));
            new TuoVault(cfg);
        }
    }

    /// @dev The seeded fee recipient is the one constructor-written payee that never passes
    ///      through {ITuoVault.setFeeRecipient}, and so never through its protocol-owned
    ///      refusal. The treasury also takes TREASURY_ROLE, so a protocol-owned value here
    ///      leaves a vault nobody can administer at all: the constructor refuses rather than
    ///      deploy it, and {Deploy}'s post-assertion proves the recipient that landed.
    function test_RevertWhen_ConstructorSeedsAProtocolOwnedFeeRecipient() public {
        for (uint256 i = 0; i < 3; i++) {
            address futureVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
            address seeded = i == 0 ? futureVault : vm.computeCreateAddress(futureVault, i);

            TuoVaultStorage.InitConfig memory cfg = _baseConfig();
            cfg.treasury = seeded;

            vm.expectRevert(abi.encodeWithSelector(ITuoVault.ProtocolOwnedAddress.selector, seeded));
            new TuoVault(cfg);
        }
    }

    function test_ConstructorSeedsEveryHlOperator() public view {
        assertTrue(vault.isHlOperator(hlOperator), "operator A seeded");
        assertTrue(vault.isHlOperator(hlOperatorB), "operator B seeded");
        assertFalse(vault.isHlOperator(mallory), "nothing else is an operator");
    }

    function test_RevertWhen_ConstructorPoolIsNotPairedWithUsdc() public {
        // Valuation reads a pool's TWAP as "the token's USDC price", so a pool that
        // does not trade against USDC would silently produce a nonsense NAV.
        MockUniswapV3Pool wethWbtc = _newPool(address(weth), address(wbtc));
        TuoVaultStorage.InitConfig memory cfg = _baseConfig();
        cfg.pools[0] = address(wethWbtc);

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.PoolNotAllowlisted.selector, address(wethWbtc)));
        new TuoVault(cfg);
    }

    /// @dev A pool whose observation ring cannot span TWAP_WINDOW answers no valuation at
    ///      all, which brakes every keeper path and both exits. The pool allowlist is
    ///      constructor-fixed with no setter, so this has to abort the deployment rather
    ///      than be caught later - and it has to be checked here, not only in the deploy
    ///      script, because the script is not what the chain enforces.
    function test_RevertWhen_ConstructorPoolOracleIsTooShallow() public {
        MockUniswapV3Pool shallow = _newPool(address(weth), address(usdc));
        shallow.setObservationCardinalityNext(TuoConstants.MIN_OBSERVATION_CARDINALITY - 1);

        TuoVaultStorage.InitConfig memory cfg = _baseConfig();
        cfg.pools[0] = address(shallow);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITuoVault.PoolOracleTooShallow.selector, address(shallow), TuoConstants.MIN_OBSERVATION_CARDINALITY - 1
            )
        );
        new TuoVault(cfg);
    }

    function test_RevertWhen_ConstructorDepositTokenIsZero() public {
        TuoVaultStorage.InitConfig memory cfg = _baseConfig();
        cfg.depositTokens[0] = address(0);

        vm.expectRevert(ITuoVault.ZeroAddress.selector);
        new TuoVault(cfg);
    }

    /// @dev The product registry is add-only and the ceiling is a compiled constant, so a
    ///      deployment that seeds a product wider than the guaranteed exit can unwind has
    ///      no in-place correction - it has to abort here rather than ship.
    function test_RevertWhen_ConstructorProductExceedsTheLpCeiling() public {
        TuoVaultStorage.InitConfig memory cfg = _baseConfig();
        cfg.products[0].maxLpCount = TuoConstants.MAX_LP_COUNT + 1;

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.InvalidProductCode.selector, uint16(1)));
        new TuoVault(cfg);
    }

    function test_RevertWhen_ConstructorPerNftCapIsZero() public {
        TuoVaultStorage.InitConfig memory cfg = _baseConfig();
        cfg.perNftCapUsdc = 0;
        vm.expectRevert(ITuoVault.InvalidCap.selector);
        new TuoVault(cfg);
    }

    function test_RevertWhen_ConstructorKeeperSwapSlippageExceedsTheCeiling() public {
        TuoVaultStorage.InitConfig memory cfg = _baseConfig();
        cfg.keeperSwapSlippageBps = TuoConstants.MAX_KEEPER_SWAP_SLIPPAGE_BPS + 1;
        vm.expectRevert(ITuoVault.InvalidKeeperSwapSlippage.selector);
        new TuoVault(cfg);
    }

    // ---------------------------------------------------- construction: wiring

    function test_ConstructorFirstPoolPerTokenBecomesItsValuationPool() public {
        MockUniswapV3Pool secondWethPool = _newPool(address(weth), address(usdc));
        TuoVaultStorage.InitConfig memory cfg = _baseConfig();
        cfg.pools = new address[](2);
        cfg.pools[0] = address(wethPool);
        cfg.pools[1] = address(secondWethPool);

        TuoVault fresh = new TuoVault(cfg);

        assertTrue(fresh.isPoolAllowlisted(address(wethPool)));
        assertTrue(fresh.isPoolAllowlisted(address(secondWethPool)));
        assertEq(fresh.valuationPoolOf(address(weth)), address(wethPool), "first pool listed wins");
    }

    /// @dev The registry has no setter and no enumerable getter, so these logs are the whole
    ///      on-chain record of it: `isPoolAllowlisted` and `valuationPoolOf` only answer for an
    ///      address the caller already holds. Every entry is emitted, not only the ones that
    ///      won valuation, because a second pool for a registered token is still allowlisted
    ///      and still mintable - the flag is the only place that distinction is visible. It is
    ///      also what names the token behind `LpMinted`'s ordered amounts for an indexer
    ///      reading events alone.
    function test_ConstructorRegistersEveryAllowedPoolAndFlagsTheValuationOne() public {
        MockUniswapV3Pool secondWethPool = _newPool(address(weth), address(usdc));
        TuoVaultStorage.InitConfig memory cfg = _baseConfig();
        cfg.pools = new address[](2);
        cfg.pools[0] = address(wethPool);
        cfg.pools[1] = address(secondWethPool);

        // The emitter is a vault that does not exist yet. `_newPool` above performs a CREATE,
        // so the nonce is read after it, as the protocol-owned seed tests above do.
        address futureVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(futureVault);
        emit ITuoVault.PoolRegistered(address(wethPool), address(weth), true);
        vm.expectEmit(futureVault);
        emit ITuoVault.PoolRegistered(address(secondWethPool), address(weth), false);

        assertEq(address(new TuoVault(cfg)), futureVault);
    }

    /// @dev The tolerance is seeded through the same guarded write the setter uses, so the
    ///      deployment transaction announces it the way every later change is announced.
    function test_ConstructorSeedsTheKeeperSwapTolerance() public {
        TuoVaultStorage.InitConfig memory cfg = _baseConfig();
        cfg.keeperSwapSlippageBps = 100;

        address futureVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(futureVault);
        emit ITuoVault.KeeperSwapSlippageUpdated(100);

        TuoVault fresh = new TuoVault(cfg);
        assertEq(address(fresh), futureVault);
        assertEq(fresh.keeperSwapSlippageBps(), 100);
    }

    // ------------------------------------------------------------ read surface

    function test_GettersReportTheConfiguredAllowlists() public view {
        assertTrue(vault.isPoolAllowlisted(address(wethPool)));
        assertTrue(vault.isPoolAllowlisted(address(wbtcPool)));
        assertFalse(vault.isPoolAllowlisted(address(npm)));

        // USDC and WETH are implicit; the config only names the extras.
        assertTrue(vault.isDepositToken(address(usdc)));
        assertTrue(vault.isDepositToken(address(weth)));
        assertTrue(vault.isDepositToken(address(wbtc)));
        assertTrue(vault.isDepositToken(address(dai)));
        assertFalse(vault.isDepositToken(address(npm)));

        assertEq(vault.valuationPoolOf(address(weth)), address(wethPool));
        assertEq(vault.valuationPoolOf(address(wbtc)), address(wbtcPool));
        assertEq(vault.valuationPoolOf(address(dai)), address(0), "dai has no pool");
    }

    // --------------------------------------------------------- NFT transfers

    /// @dev The armed-withdrawal state rides along with the token, and the transferee - not
    ///      the transferor - is who `withdraw` pays. A buyer of a position therefore inherits
    ///      a request they did not make and must re-check it; `requestWithdraw(nftId, 0)`
    ///      cancels. Pinned here because free transferability makes a secondary market
    ///      possible, and a stale request is the sharpest edge on it.
    function test_ArmedWithdrawalSurvivesATransferAndPaysTheNewOwner() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);

        vm.startPrank(alice);
        vault.requestWithdraw(nftId, 10_000);
        nft.transferFrom(alice, mallory, nftId);
        vm.stopPrank();

        assertEq(vault.getPosition(nftId).withdrawalSharesBps, 10_000, "the request rides with the token");

        vm.expectRevert(ITuoVault.NotPositionOwner.selector);
        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");

        vm.prank(mallory);
        vault.withdraw(nftId, address(usdc), 0, "");
        assertEq(usdc.balanceOf(mallory), 10_000e6);
        assertEq(usdc.balanceOf(alice), 0, "the transferor keeps nothing");
    }

    /// @dev Regression guard through the real vault: a full withdrawal burns the NFT via
    ///      the ERC-721 `_update` hook, so the owner-can-always-exit invariant depends on
    ///      that hook staying unconditional.
    function test_FullWithdrawalBurnsTheNft() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);

        vm.startPrank(alice);
        vault.requestWithdraw(nftId, 10_000);
        vault.withdraw(nftId, address(usdc), 0, "");
        vm.stopPrank();

        // The position record survives for the indexer; the NFT itself is burned.
        assertFalse(vault.getPosition(nftId).active);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, nftId));
        nft.ownerOf(nftId);
        assertEq(usdc.balanceOf(alice), 10_000e6, "principal returns fee-free");
    }

    function test_RevertWhen_SettlementNavPositionIsUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.UnknownPosition.selector, uint256(42)));
        vault.settlementNav(42);
    }

    function test_RevertWhen_PreviewWithdrawHasNoRequest() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.UnknownPosition.selector, uint256(42)));
        vault.previewWithdraw(42);

        vm.expectRevert(ITuoVault.WithdrawalNotRequested.selector);
        vault.previewWithdraw(nftId);

        vm.prank(alice);
        vault.requestWithdraw(nftId, 10_000);
        (uint256 gross, uint256 fee, uint256 net) = vault.previewWithdraw(nftId);
        assertEq(gross, 10_000e6);
        assertEq(fee, 0, "no profit, no fee");
        assertEq(net, 10_000e6);
    }

    function test_KeeperActionsTodayCountsAndRollsOverAtUtcMidnight() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        assertEq(vault.keeperActionsToday(nftId), 0);

        _keeperSwapToWeth(nftId, 1_000e6, 1e18);
        assertEq(vault.keeperActionsToday(nftId), 1);

        // The budget is per UTC day, not a rolling window.
        vm.warp(((block.timestamp / 1 days) + 1) * 1 days);
        assertEq(vault.keeperActionsToday(nftId), 0, "budget resets on the day boundary");
    }

    function test_VaultAcceptsErc721SoTheNpmCanSafeTransferLpPositions() public view {
        assertEq(vault.onERC721Received(address(npm), address(vault), 1, ""), IERC721Receiver.onERC721Received.selector);
    }

    function test_NftSupportsTheStandardInterfaces() public view {
        assertTrue(nft.supportsInterface(type(IERC165).interfaceId));
        assertTrue(nft.supportsInterface(type(IERC721).interfaceId));
        assertTrue(nft.supportsInterface(type(IERC721Metadata).interfaceId));
        assertFalse(nft.supportsInterface(bytes4(0xdeadbeef)));
    }

    // -------------------------------------------------------- product registry

    function test_ConstructorSeedsTheProductRegistry() public view {
        ITuoVault.Product memory bpCore = vault.productOf(1);
        assertEq(bpCore.label, LABEL_BP_CORE);
        assertTrue(bpCore.openForDeposits);
        assertEq(bpCore.maxHedgeBps, 5_000);
        assertEq(bpCore.maxLpCount, 3);
        // Separately from BP Core's own strategy choice: no seeded product may sit above
        // the compiled ceiling, whatever that ceiling is later raised to.
        assertLe(bpCore.maxLpCount, TuoConstants.MAX_LP_COUNT, "no product above the ceiling");

        ITuoVault.Product memory dh = vault.productOf(2);
        assertEq(dh.label, LABEL_DH_STANDALONE);
        assertEq(dh.maxLpCount, 1);

        // Code 0 is the top-up sentinel and must never resolve to a product.
        assertEq(vault.productOf(0).label, bytes32(0));
        assertEq(vault.productOf(3).label, bytes32(0));
    }

    function test_RegisterProductIsAddOnlyAndTreasuryGated() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, mallory, keccak256("TREASURY_ROLE")
            )
        );
        vm.prank(mallory);
        vault.registerProduct(3, "NEW", 1_000, 2);

        // Registered at exactly the ceiling, so the accepted end of the bound is pinned on
        // the treasury path too and a `>=` typo in the check cannot pass this suite.
        vm.expectEmit(address(vault));
        emit ITuoVault.ProductRegistered(3, "NEW", 1_000, TuoConstants.MAX_LP_COUNT);
        vm.prank(treasury);
        vault.registerProduct(3, "NEW", 1_000, TuoConstants.MAX_LP_COUNT);
        assertEq(vault.productOf(3).label, LABEL_NEW);
        assertEq(vault.productOf(3).maxLpCount, TuoConstants.MAX_LP_COUNT);

        // Add-only: an existing product's policy can never be rewritten under a live
        // position.
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.ProductAlreadyRegistered.selector, uint16(3)));
        vm.prank(treasury);
        vault.registerProduct(3, "OTHER", 1, 1);
    }

    function test_RevertWhen_RegisterProductIsMalformed() public {
        vm.startPrank(treasury);
        // Code 0 is reserved forever: deposit uses it as the top-up sentinel.
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.InvalidProductCode.selector, uint16(0)));
        vault.registerProduct(0, "ZERO", 1_000, 1);

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.InvalidProductCode.selector, uint16(9)));
        vault.registerProduct(9, bytes32(0), 1_000, 1);

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.InvalidProductCode.selector, uint16(9)));
        vault.registerProduct(9, "TOO_HEDGED", 10_001, 1);

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.InvalidProductCode.selector, uint16(9)));
        vault.registerProduct(9, "NO_LPS", 1_000, 0);

        // The ceiling on the other end is the guaranteed exit's: `emergencyWithdraw`
        // closes every open LP in one transaction and each closure scans the LP array, so
        // a treasury that could name any uint8 could make that exit uncallable.
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.InvalidProductCode.selector, uint16(9)));
        vault.registerProduct(9, "TOO_MANY_LPS", 1_000, TuoConstants.MAX_LP_COUNT + 1);

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.InvalidProductCode.selector, uint16(9)));
        vault.registerProduct(9, "ALL_THE_LPS", 1_000, type(uint8).max);
        vm.stopPrank();
    }

    /// @dev The property the point cases above sample: the accepted LP counts are exactly
    ///      `[1, MAX_LP_COUNT]`, across the whole uint8 domain a treasury could name.
    function testFuzz_RegisterProductRejectsAnLpCountAboveTheCeiling(uint8 lpCount) public {
        lpCount = uint8(bound(lpCount, uint256(TuoConstants.MAX_LP_COUNT) + 1, type(uint8).max));

        vm.expectRevert(abi.encodeWithSelector(ITuoVault.InvalidProductCode.selector, uint16(9)));
        vm.prank(treasury);
        vault.registerProduct(9, "TOO_MANY_LPS", 1_000, lpCount);
    }

    function testFuzz_RegisterProductAcceptsAnLpCountInsideTheCeiling(uint8 lpCount) public {
        lpCount = uint8(bound(lpCount, 1, TuoConstants.MAX_LP_COUNT));

        vm.prank(treasury);
        vault.registerProduct(9, "INSIDE", 1_000, lpCount);
        assertEq(vault.productOf(9).maxLpCount, lpCount);
    }

    function test_SetProductOpenBlocksNewPositionsOnly() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);

        vm.expectEmit(address(vault));
        emit ITuoVault.ProductOpenUpdated(1, false);
        vm.prank(treasury);
        vault.setProductOpen(1, false);

        usdc.mint(bob, 10_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 10_000e6);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.ProductClosedForDeposits.selector, uint16(1)));
        vault.deposit(address(usdc), 10_000e6, 1, 0, "", 0);
        vm.stopPrank();

        // The existing position keeps working, including top-ups and its exits.
        usdc.mint(alice, 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 5_000e6);
        vault.deposit(address(usdc), 5_000e6, 0, 0, "", nftId);
        vault.requestWithdraw(nftId, 10_000);
        vault.withdraw(nftId, address(usdc), 0, "");
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 15_000e6);

        // The label survives retirement - it is the registered flag.
        assertEq(vault.productOf(1).label, LABEL_BP_CORE);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.UnknownProduct.selector, uint16(7)));
        vm.prank(treasury);
        vault.setProductOpen(7, false);
    }

    function test_RevertWhen_DepositUsesAnUnregisteredProductCode() public {
        usdc.mint(bob, 10_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 10_000e6);
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.InvalidProductCode.selector, uint16(3)));
        vault.deposit(address(usdc), 10_000e6, 3, 0, "", 0);
        // The top-up sentinel cannot open a position either.
        vm.expectRevert(abi.encodeWithSelector(ITuoVault.InvalidProductCode.selector, uint16(0)));
        vault.deposit(address(usdc), 10_000e6, 0, 0, "", 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- fee claims

    function test_ClaimFeesSweepsToTheCurrentRecipientAndIsTreasuryOnly() public {
        uint256 nftId = _depositUsdc(alice, 10_000e6);
        _hedgeRoundTrip(nftId, alice, 4_000e6, 7_000e6);
        vm.prank(alice);
        vault.withdraw(nftId, address(usdc), 0, "");
        assertEq(vault.accruedFeesUsdc(), 900e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, mallory, keccak256("TREASURY_ROLE")
            )
        );
        vm.prank(mallory);
        vault.claimFees();

        // The sweep follows the current recipient, not the one at accrual time.
        vm.prank(treasury);
        vault.setFeeRecipient(bob);
        vm.expectEmit(address(vault));
        emit ITuoVault.FeesClaimed(bob, 900e6);
        vm.prank(treasury);
        assertEq(vault.claimFees(), 900e6);
        assertEq(usdc.balanceOf(bob), 900e6);
        assertEq(vault.accruedFeesUsdc(), 0);
    }

    function test_RevertWhen_ClaimFeesHasNothingToClaim() public {
        vm.expectRevert(ITuoVault.ZeroAmount.selector);
        vm.prank(treasury);
        vault.claimFees();
    }

    /// @dev The in-kind fee pool the emergency exit fills carries the same guard as the
    ///      USDC one. A second claim entry point is a second place to get the role wrong.
    function test_ClaimTokenFeesIsTreasuryOnly() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, mallory, keccak256("TREASURY_ROLE")
            )
        );
        vm.prank(mallory);
        vault.claimTokenFees(address(weth));

        vm.expectRevert(ITuoVault.ZeroAmount.selector);
        vm.prank(treasury);
        vault.claimTokenFees(address(weth));
    }

    /// @dev The self-call helper the guaranteed exit uses to make its fee oracle-optional
    ///      must not become an unguarded mid-update value read; that is precisely what
    ///      `_noReentrantRead` closes on the other value views.
    function test_RevertWhen_IdleValueUsdcIsCalledExternally() public {
        vm.expectRevert(ITuoVault.OnlySelf.selector);
        vault.idleValueUsdc(1);
    }

    // ------------------------------------------------------- pause the deposits

    function test_PauseDepositsIsPauserOnlyAndEmitsBothWays() public {
        vm.expectEmit(address(vault));
        emit ITuoVault.DepositsPauseUpdated(true);
        vm.prank(pauser);
        vault.pauseDeposits();
        assertTrue(vault.paused());

        vm.expectEmit(address(vault));
        emit ITuoVault.DepositsPauseUpdated(false);
        vm.prank(pauser);
        vault.unpauseDeposits();
        assertFalse(vault.paused());
    }

    // ---------------------------------------------- LP registry bookkeeping

    function test_BurnLpRemovesTheRightIdWhenAPositionHoldsSeveral() public {
        // Swap-and-pop removal: burning a non-last LP moves the tail into its slot.
        // Getting this wrong would orphan an LP from its position - an attribution
        // break, not just a cosmetic one - and only shows up with 3+ open LPs.
        uint256 nftId = _depositUsdc(alice, 24_000e6);
        _keeperSwapToWeth(nftId, 6_000e6, 6_000e6);
        uint256 lp0 = _keeperMintLp(nftId, 1_000e6, 1_000e6);
        uint256 lp1 = _keeperMintLp(nftId, 2_000e6, 2_000e6);
        uint256 lp2 = _keeperMintLp(nftId, 3_000e6, 3_000e6);
        assertEq(vault.getPosition(nftId).lpTokenIds.length, 3);

        vm.prank(keeper);
        vault.burnLp(nftId, lp1);

        uint256[] memory remaining = vault.getPosition(nftId).lpTokenIds;
        assertEq(remaining.length, 2);
        assertEq(remaining[0], lp0, "head is untouched");
        assertEq(remaining[1], lp2, "tail was swapped into the hole");
        assertEq(vault.lpOwnerOf(lp1), 0, "burnt LP is unlinked from its position");
        assertEq(vault.lpPoolOf(lp1), address(0));
        assertEq(vault.lpOwnerOf(lp2), nftId, "the moved LP keeps its owner");
    }
}
