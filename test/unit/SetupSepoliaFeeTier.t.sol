// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {SetupSepolia} from "../../script/SetupSepolia.s.sol";

/// @dev Only `feeAmountTickSpacing` is implemented, which is the whole surface the guard
///      reads. A tier the test never enables reads back as 0, exactly as a real factory
///      reports one governance has not turned on.
contract FactoryStub {
    mapping(uint24 fee => int24) public feeAmountTickSpacing;

    function enable(uint24 fee, int24 spacing) external {
        feeAmountTickSpacing[fee] = spacing;
    }
}

/// @dev The guard is internal and its failure is a revert, so it needs a real call frame
///      for `vm.expectRevert` to see the revert below the cheatcode's own depth.
contract FeeTierHarness is SetupSepolia {
    function requireEngineCompatibleFee(address factory, uint24 fee) external view {
        _requireEngineCompatibleFee(factory, fee);
    }

    function engineTickSpacing() external pure returns (int24) {
        return ENGINE_TICK_SPACING;
    }
}

/// @title SetupSepoliaFeeTierTest - which fee tiers a Tuo pool may use, and why
/// @notice `SEPOLIA_POOL_FEE` and `SEPOLIA_POOL_FEE_WBTC` make the fee tier an operator
///         choice, and the constraint on that choice is not visible from the vault: Engine
///         v25 rounds every range to a multiple of its frozen `tick_spacing` of 10, and the
///         keeper hands those ticks to `mintLp` verbatim. The position manager then reverts
///         unless both ticks are multiples of the POOL's spacing.
///
///         So a pool is usable only when its spacing DIVIDES 10. The 0.3% tier (spacing 60)
///         and the 1% tier (spacing 200) do not, and they fail in the worst possible way:
///         `createPool` succeeds, `Deploy._assertDeployment` passes every check, and the
///         first `mintLp` reverts 30 minutes later against a pool allowlist that has no
///         setter. These tests pin the guard that refuses them before any gas is spent.
contract SetupSepoliaFeeTierTest is Test {
    FeeTierHarness internal harness;
    FactoryStub internal factory;

    function setUp() public {
        harness = new FeeTierHarness();
        factory = new FactoryStub();
    }

    /// @dev The two tiers a Tuo deployment may actually use: 0.01% and 0.05%.
    function test_TiersWhoseSpacingDividesTheEngineSpacingPass() public {
        factory.enable(100, 1);
        factory.enable(500, 10);

        harness.requireEngineCompatibleFee(address(factory), 100);
        harness.requireEngineCompatibleFee(address(factory), 500);
    }

    /// @dev The 0.01% tier is enabled by governance rather than at factory deployment, so it
    ///      is present on Arbitrum One and not guaranteed on a testnet factory. Without this
    ///      the failure is a bare `createPool` revert several transactions into a broadcast.
    function test_RevertWhen_FeeTierIsNotEnabledOnTheFactory() public {
        vm.expectRevert(bytes("SetupSepolia: fee tier not enabled on this factory"));
        harness.requireEngineCompatibleFee(address(factory), 100);
    }

    function test_RevertWhen_TickSpacingIsCoarserThanTheEngineSpacing() public {
        factory.enable(3_000, 60);

        vm.expectRevert(bytes("SetupSepolia: tick spacing must divide 10"));
        harness.requireEngineCompatibleFee(address(factory), 3_000);
    }

    /// @dev The 1% tier, kept separate from the 0.3% one because an operator reaching past
    ///      the shipped default is as likely to pick either.
    function test_RevertWhen_TickSpacingIsTheOnePercentTier() public {
        factory.enable(10_000, 200);

        vm.expectRevert(bytes("SetupSepolia: tick spacing must divide 10"));
        harness.requireEngineCompatibleFee(address(factory), 10_000);
    }

    /// @dev The property behind the four cases above, stated once: divisibility is the whole
    ///      rule, and it is what keeps this correct if Uniswap ever enables another tier.
    function testFuzz_ATierPassesExactlyWhenItsSpacingDividesTheEngineSpacing(uint24 fee, int24 spacing) public {
        spacing = int24(bound(int256(spacing), 1, 500));
        bool usable = harness.engineTickSpacing() % spacing == 0;
        factory.enable(fee, spacing);

        if (!usable) {
            vm.expectRevert(bytes("SetupSepolia: tick spacing must divide 10"));
        }
        harness.requireEngineCompatibleFee(address(factory), fee);
    }
}
