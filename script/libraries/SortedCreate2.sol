// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title SortedCreate2 - deploy a testnet mock at an address that sorts where we need it
/// @notice Uniswap V3 decides `token0` by raw address comparison, and Engine v25's frozen
///         `POOL_META` is written for the volatile token as token0 and USDC as token1
///         (`d0`/`d1` of 18/6 for WETH/USDC and 8/6 for WBTC/USDC). The engine's
///         `_position_tick_bounds` has no inversion branch for the other ordering, and the
///         keeper forwards its ticks to `mintLp` verbatim - so a mock USDC that happens to
///         sort first does not merely drift, it mints every range at the exact negative of
///         the intended tick.
///
///         On mainnet the ordering is a fact of the canonical addresses. On a testnet where
///         USDC is a mock it is whatever the deployer's nonce produced, which is a coin
///         flip the deploy has already lost once. This library replaces the coin flip with
///         a search: pick the CREATE2 salt that lands the mock on the side the engine
///         already assumes it is on.
///
/// @dev TESTNET TOOLING. Nothing in `src/` references this, and mainnet uses canonical
///      token addresses that need no mining.
///
///      Functions are `internal` on purpose: they inline into the caller, so the library
///      needs no deployment transaction of its own and no link step.
library SortedCreate2 {
    /// @notice Arachnid's deterministic deployment proxy.
    /// @dev This is the deployer `forge script` routes `new C{salt: s}()` through inside a
    ///      broadcast, and the one `vm.computeCreate2Address(salt, hash)` assumes. It
    ///      mirrors forge-std's own `CommonBase.CREATE2_FACTORY`;
    ///      `SortedCreate2.t.sol::test_DeterministicDeployerMatchesForgeStdCreate2Factory`
    ///      asserts the two are equal, because a drift here would make every predicted
    ///      address wrong while every other test still passed.
    address internal constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Candidate salts `mineBetween` will try before giving up.
    /// @dev A bound, not a target. The bounds used by `SetupSepolia` straddle roughly 40% of
    ///      the address space each, so the search returns in about two iterations and the
    ///      budget costs nothing in the happy path. What it buys is that an impossible
    ///      constraint fails with a named revert instead of running until the script's gas
    ///      limit stops it.
    uint256 internal constant DEFAULT_MAX_TRIES = 100_000;

    /// @notice The address `DETERMINISTIC_DEPLOYER` would produce for `salt` and `initCodeHash`.
    /// @param salt the CREATE2 salt
    /// @param initCodeHash keccak256 of the contract's creation code
    /// @return the address that deployment would land at
    function addressOf(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        bytes32 digest = keccak256(abi.encodePacked(bytes1(0xff), DETERMINISTIC_DEPLOYER, salt, initCodeHash));
        // EIP-1014 DEFINES the created address as the low 20 bytes of that digest, so the
        // truncation is the specification rather than a lossy cast. Cross-checked against
        // `vm.computeCreate2Address` and against a real CREATE2 in SortedCreate2.t.sol.
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(uint256(digest)));
    }

    /// @notice The LOWEST salt whose CREATE2 address sorts strictly inside
    ///         `(floorExclusive, ceilingExclusive)`.
    /// @dev Hand-rolls the EIP-1014 derivation rather than calling
    ///      `vm.computeCreate2Address`: a keccak256 over 85 bytes is roughly 150 gas against
    ///      a cheatcode staticcall's ~2,600, and that ratio is what makes a five-figure try
    ///      budget affordable inside a `forge script` run.
    ///
    ///      **`pure`, and deliberately blind to whether the address is already occupied.**
    ///      The search depends on nothing but its arguments, so the same committed source
    ///      always yields the same salt - which is what lets a `SetupSepolia` dry run print the
    ///      exact addresses a later broadcast will produce, and lets an operator verify the
    ///      token sort order before spending gas.
    ///
    ///      An earlier version skipped occupied candidates so that a second run would not
    ///      revert inside the deterministic deployer (which reverts when its inner CREATE2
    ///      returns the zero address). That bought a run that does not fail, NOT idempotence:
    ///      it mined PAST the addresses the first run used and deployed a whole second
    ///      generation of mocks, which silently orphans the first generation's pools and
    ///      inventories. Occupancy is the caller's business, and the correct response is to
    ///      **adopt** - an address here is keccak-bound to this exact deployer, salt and
    ///      initcode, so code sitting at it is that contract and nothing else. See
    ///      `SetupSepolia._deployOrAdopt`.
    /// @param initCodeHash keccak256 of the contract's creation code
    /// @param floorExclusive the address the result must sort strictly above
    /// @param ceilingExclusive the address the result must sort strictly below
    /// @param maxTries candidate salts to try before reverting
    /// @return salt the winning salt, `bytes32(i)` for the lowest qualifying `i` from zero
    /// @return predicted the address that salt lands at
    function mineBetween(bytes32 initCodeHash, address floorExclusive, address ceilingExclusive, uint256 maxTries)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        require(floorExclusive < ceilingExclusive, "SortedCreate2: bad bounds");
        require(maxTries != 0, "SortedCreate2: zero try budget");

        for (uint256 i = 0; i < maxTries; i++) {
            salt = bytes32(i);
            predicted = addressOf(salt, initCodeHash);
            if (predicted > floorExclusive && predicted < ceilingExclusive) {
                return (salt, predicted);
            }
        }
        revert("SortedCreate2: salt search exhausted");
    }
}
