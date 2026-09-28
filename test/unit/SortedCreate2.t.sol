// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {SortedCreate2} from "../../script/libraries/SortedCreate2.sol";
import {TestnetUSDC} from "../../script/mocks/TestnetUSDC.sol";

/// @dev The miner is internal and the exhaustion path is a revert, so it needs a real call
///      frame for `vm.expectRevert` to see the revert below the cheatcode's own depth.
contract SortedCreate2Harness {
    function addressOf(bytes32 salt, bytes32 initCodeHash) external pure returns (address) {
        return SortedCreate2.addressOf(salt, initCodeHash);
    }

    function mineBetween(bytes32 initCodeHash, address floorExclusive, address ceilingExclusive, uint256 maxTries)
        external
        pure
        returns (bytes32, address)
    {
        return SortedCreate2.mineBetween(initCodeHash, floorExclusive, ceilingExclusive, maxTries);
    }
}

/// @title SortedCreate2Test - the address ordering the frozen engine depends on
/// @notice Engine v25's `POOL_META` is frozen with the volatile token as token0 and USDC as
///         token1, and it has no inversion branch for the other ordering. Uniswap decides
///         token0 by raw address comparison, so on a testnet where USDC is a mock the
///         ordering is whatever the deployer's nonce happened to produce - and the previous
///         `TestnetUSDC` landed below WETH9, which made every pool tick the exact negative
///         of the engine tick. This library removes the coin flip: it picks the salt that
///         puts the mock where the engine already assumes it is.
///
/// @dev What these tests pin, in order of importance: the derivation agrees with the
///      cheatcode and with a real CREATE2 (so a predicted address is the deployed one), the
///      result is inside the requested bounds, the search returns the LOWEST such salt, and
///      an occupied address is skipped (which is what makes `SetupSepolia` re-runnable,
///      since the salts are pure functions of constants and the deterministic deployer
///      reverts on a collision).
contract SortedCreate2Test is Test {
    /// @dev Canonical Arbitrum Sepolia WETH9 - the real pivot the fixtures mine around.
    address internal constant WETH9 = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;
    address internal constant MAX_ADDRESS = address(type(uint160).max);

    SortedCreate2Harness internal harness;
    bytes32 internal usdcInitCodeHash;

    function setUp() public {
        harness = new SortedCreate2Harness();
        usdcInitCodeHash = keccak256(type(TestnetUSDC).creationCode);
    }

    // ------------------------------------------------------------- the derivation

    /// @dev `forge script` routes `new C{salt: s}()` through ITS OWN notion of the
    ///      deterministic deployer. If our constant ever drifted from that one, every
    ///      predicted address would be wrong while every test here still passed.
    function test_DeterministicDeployerMatchesForgeStdCreate2Factory() public pure {
        assertEq(SortedCreate2.DETERMINISTIC_DEPLOYER, CREATE2_FACTORY, "deployer constant drifted from forge's");
    }

    function test_AddressOfMatchesTheComputeCreate2AddressCheatcode() public view {
        bytes32 salt = bytes32(uint256(7));

        assertEq(
            harness.addressOf(salt, usdcInitCodeHash),
            vm.computeCreate2Address(salt, usdcInitCodeHash),
            "hand-rolled EIP-1014 must agree with the cheatcode"
        );
    }

    function testFuzz_AddressOfMatchesTheComputeCreate2AddressCheatcode(bytes32 salt, bytes32 initCodeHash)
        public
        view
    {
        assertEq(harness.addressOf(salt, initCodeHash), vm.computeCreate2Address(salt, initCodeHash));
    }

    /// @dev The cheatcode could in principle share a bug with us. A real CREATE2 through the
    ///      real proxy cannot. This etches Arachnid's deployed runtime at the canonical
    ///      address and drives it exactly as `forge script` does - `salt ++ initcode` as raw
    ///      calldata - then checks the address it actually produced against our derivation.
    ///      Without this, nothing in the suite exercises `addressOf` against an EVM CREATE2.
    function test_AddressOfPredictsARealDeploymentThroughTheDeterministicDeployer() public {
        // The verbatim runtime of 0x4e59b448..., read off Arbitrum Sepolia with `cast code`.
        vm.etch(
            SortedCreate2.DETERMINISTIC_DEPLOYER,
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
        );
        bytes32 salt = bytes32(uint256(42));

        (bool ok, bytes memory ret) =
            SortedCreate2.DETERMINISTIC_DEPLOYER.call(abi.encodePacked(salt, type(TestnetUSDC).creationCode));

        assertTrue(ok, "the deterministic deployer must accept the deployment");
        assertEq(ret.length, 20, "the proxy returns the created address");
        // The proxy returns exactly the 20 address bytes, which the assertion on `ret.length`
        // above has already pinned - so this reads the whole return value rather than
        // truncating it.
        // forge-lint: disable-next-line(unsafe-typecast)
        address created = address(bytes20(ret));
        assertEq(
            created,
            harness.addressOf(salt, usdcInitCodeHash),
            "our EIP-1014 derivation must equal what a real CREATE2 produced"
        );
    }

    // --------------------------------------------------------------- the ordering

    function test_MinedSaltSortsStrictlyAboveTheFloor() public view {
        (, address predicted) = harness.mineBetween(usdcInitCodeHash, WETH9, MAX_ADDRESS, 4_096);

        assertGt(uint160(predicted), uint160(WETH9), "USDC must sort above WETH9, or it becomes token0");
    }

    function test_MinedSaltSortsStrictlyBelowTheCeiling() public view {
        (, address predicted) = harness.mineBetween(usdcInitCodeHash, address(0), WETH9, 4_096);

        assertLt(uint160(predicted), uint160(WETH9), "the WBTC direction: below the pivot");
    }

    /// @dev "Lowest" is half the contract: it is what makes the search reproducible across
    ///      runs and machines, so a `SetupSepolia` dry run predicts what the broadcast produces.
    function test_MinedSaltIsTheLowestThatSatisfiesTheBounds() public view {
        (bytes32 salt, address predicted) = harness.mineBetween(usdcInitCodeHash, WETH9, MAX_ADDRESS, 4_096);

        for (uint256 i = 0; i < uint256(salt); i++) {
            address candidate = harness.addressOf(bytes32(i), usdcInitCodeHash);
            bool inside = candidate > WETH9 && candidate < MAX_ADDRESS;
            assertFalse(inside, "a lower salt already satisfied the bounds");
        }
        assertGt(uint160(predicted), uint160(WETH9));
    }

    function test_MineIsDeterministicForTheSameInputs() public view {
        (bytes32 firstSalt, address firstAddress) = harness.mineBetween(usdcInitCodeHash, WETH9, MAX_ADDRESS, 4_096);
        (bytes32 secondSalt, address secondAddress) = harness.mineBetween(usdcInitCodeHash, WETH9, MAX_ADDRESS, 4_096);

        assertEq(firstSalt, secondSalt, "the search must not depend on chain state");
        assertEq(firstAddress, secondAddress);
    }

    /// @dev The idempotence property, and it is the opposite of what an earlier version of
    ///      this library did. The search must IGNORE occupancy so that a second
    ///      `SetupSepolia` run lands on the same address and the caller can adopt what is there.
    ///      Skipping the occupied candidate instead would mine PAST it and deploy a whole
    ///      second generation of mocks at new addresses - which orphans the first
    ///      generation's pools, seeds and every environment value already exported, while
    ///      still reporting success.
    ///
    ///      Adoption is sound because EIP-1014 binds the address to this deployer, this salt
    ///      and this initcode hash, so code sitting there is that exact contract.
    function test_MinedSaltIsUnchangedByCodeAtItsAddress() public {
        (bytes32 firstSalt, address firstAddress) = harness.mineBetween(usdcInitCodeHash, WETH9, MAX_ADDRESS, 4_096);

        vm.etch(firstAddress, hex"6000");
        (bytes32 secondSalt, address secondAddress) = harness.mineBetween(usdcInitCodeHash, WETH9, MAX_ADDRESS, 4_096);

        assertEq(secondSalt, firstSalt, "an occupied address must NOT move the search");
        assertEq(secondAddress, firstAddress, "a re-run must land on the same address to adopt");
    }

    function testFuzz_MinedSaltAlwaysSortsAboveAnyFloor(uint160 floorSeed) public view {
        // Bounded to the lower half so the search stays a handful of iterations; the
        // ordering property is what is under test, not the tail of the geometric.
        address floorExclusive = address(uint160(bound(floorSeed, 0, type(uint160).max / 2)));

        (, address predicted) = harness.mineBetween(usdcInitCodeHash, floorExclusive, MAX_ADDRESS, 4_096);

        assertGt(uint160(predicted), uint160(floorExclusive));
    }

    // ----------------------------------------------------------------- the bounds

    function test_RevertWhen_SaltSearchIsExhausted() public {
        vm.expectRevert(bytes("SortedCreate2: salt search exhausted"));
        // A one-address window nothing realistically lands in, and a budget small enough
        // that the loop gives up rather than hanging.
        harness.mineBetween(usdcInitCodeHash, address(uint160(MAX_ADDRESS) - 1), MAX_ADDRESS, 64);
    }

    function test_RevertWhen_FloorIsNotBelowCeiling() public {
        vm.expectRevert(bytes("SortedCreate2: bad bounds"));
        harness.mineBetween(usdcInitCodeHash, WETH9, WETH9, 4_096);
    }

    function test_RevertWhen_TryBudgetIsZero() public {
        vm.expectRevert(bytes("SortedCreate2: zero try budget"));
        harness.mineBetween(usdcInitCodeHash, WETH9, MAX_ADDRESS, 0);
    }
}
