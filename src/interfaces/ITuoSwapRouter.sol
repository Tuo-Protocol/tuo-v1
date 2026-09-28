// SPDX-License-Identifier: LicenseRef-BUSL-1.1
pragma solidity 0.8.26;

/// @title ITuoSwapRouter - vault-only DEX-aggregator execution wrapper
/// @author Tuo Team
/// @notice Executes 0x/1inch-style aggregator calldata against a treasury-maintained
///         allowlist of aggregator routers, seeded at construction. The router holds no
///         funds between calls: it pulls `amountIn` from the vault, grants the aggregator
///         an exact-amount approval, executes, verifies the received amount on balance
///         deltas, sweeps the proceeds back to the vault, and clears any approval residue.
interface ITuoSwapRouter {
    /// @notice An aggregator swap completed and the proceeds were swept to the vault.
    /// @param aggregator the aggregator router that was called
    /// @param tokenIn token sold
    /// @param tokenOut token bought
    /// @param amountIn exact amount of `tokenIn` spent
    /// @param amountOut amount of `tokenOut` received, measured on the balance delta
    event SwapExecuted(
        address indexed aggregator,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice An aggregator was added to the allowlist.
    /// @param aggregator the newly allowlisted router
    event AggregatorAdded(address indexed aggregator);

    /// @notice An aggregator was retired from the allowlist. In-flight routes through it
    ///         revert from this block; nothing already swapped is affected.
    /// @param aggregator the retired router
    event AggregatorRemoved(address indexed aggregator);

    /// @notice The caller is not the vault. The router has exactly one permitted caller.
    error OnlyVault();

    /// @notice The aggregator is not on the allowlist. This is the constraint that makes
    ///         executing untrusted calldata safe: the call target is bounded even though
    ///         the payload is not.
    /// @param aggregator the rejected router
    error AggregatorNotAllowlisted(address aggregator);

    /// @notice The swap delivered less than the vault's floor.
    /// @param amountOut what the route actually delivered
    /// @param minAmountOut the floor it had to clear
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);

    /// @notice The low-level call into the aggregator reverted.
    error SwapCallFailed();

    /// @notice The route spent less than `amountIn` and left a residue. Refunding is not
    ///         an option: the vault has already debited idle by exactly `amountIn`, so a
    ///         partial spend would silently desynchronize accounting. The keeper retries
    ///         with fresh calldata instead.
    /// @param leftover the unspent input remaining on the router
    error InputNotFullySpent(uint256 leftover);

    /// @notice `tokenIn` and `tokenOut` are the same token.
    error SameToken();

    /// @notice An address that must be set was the zero address. Allowlisting address(0)
    ///         would make the empty-account call "succeed", leaving only the full-spend
    ///         check to catch a broken route.
    error ZeroAddress();

    /// @notice The aggregator is already on the allowlist.
    /// @param aggregator the duplicate router
    error AggregatorAlreadyAllowlisted(address aggregator);

    /// @notice Execute an aggregator swap. Vault-only.
    /// @param aggregator the aggregator router to call (must be allowlisted)
    /// @param tokenIn input token, pulled from the vault
    /// @param tokenOut output token, swept back to the vault
    /// @param amountIn exact input amount
    /// @param minAmountOut revert floor, enforced on tokenOut balance delta
    /// @param data aggregator calldata built off-chain
    /// @return amountOut amount of `tokenOut` swept back to the vault
    function swap(
        address aggregator,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external returns (uint256 amountOut);

    /// @notice Allowlist another aggregator. Vault-only, and reached through
    ///         `TuoVault.addAggregator`, which is TREASURY_ROLE-gated.
    /// @dev An aggregator version rotation must never require redeploying the system and
    ///      migrating customer positions, which is why the set is mutable at all.
    /// @param aggregator the router to allowlist
    function addAggregator(address aggregator) external;

    /// @notice Retire an aggregator from the allowlist. Vault-only, and reached through
    ///         `TuoVault.removeAggregator`, which is TREASURY_ROLE-gated.
    /// @dev This allowlist was add-only until the depositor allowlist was removed. The old
    ///      argument was that a bad aggregator is handled by not building calldata for it -
    ///      which held only while Tuo controlled who could reach `swap`. `deposit` and
    ///      `withdraw` both take caller-supplied `swapData`, so any address can now route
    ///      through any allowlisted aggregator, and the only thing that can stop an
    ///      aggregator later found exploitable is taking it off this list. `withdraw` is
    ///      deliberately not pausable, so there is no other lever on that leg.
    ///
    ///      The counter-risk is real and accepted: a compromised treasury can retire every
    ///      aggregator but one and force each swap through a venue it controls. That is a
    ///      strictly smaller power than the KEEPER_ROLE it already administers, and it
    ///      cannot touch `TuoVault.emergencyWithdraw`, which pays in kind and needs no
    ///      swap. A floor on the list is worse than no floor, because it would pin a
    ///      compromised aggregator in place, so emptying stays permitted. Its cost is
    ///      wider than the swap legs, though: it also stops `TuoVault.swapIdle`, the only
    ///      way a pool token becomes the idle USDC `TuoVault.withdraw` debits from, so a
    ///      position still holding WETH or WBTC reverts InsufficientIdle in USDC too. The
    ///      counterweight is operational - the treasury batches the replacement into the
    ///      removal's own transaction, and sends anyone caught in between out in kind.
    /// @param aggregator the router to retire; must currently be allowlisted
    function removeAggregator(address aggregator) external;

    /// @notice The TuoVault that deployed this router and is its only permitted caller.
    /// @dev SCREAMING_SNAKE to match the implementation's `immutable`, whose auto-generated
    ///      getter is the function that satisfies this declaration.
    /// @return vault the vault address, fixed at construction
    // forge-lint: disable-next-line(mixed-case-function)
    function VAULT() external view returns (address vault);

    /// @notice Whether an aggregator is on the allowlist.
    /// @param aggregator the router to check
    /// @return allowlisted whether `swap` will route through it
    function isAggregator(address aggregator) external view returns (bool allowlisted);
}
