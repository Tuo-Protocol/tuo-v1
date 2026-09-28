// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {TestnetAggregator} from "../mocks/TestnetAggregator.sol";
import {TestnetPoolPoker} from "../mocks/TestnetPoolPoker.sol";

/// @title FixtureSweep - recover the balances stranded in the Sepolia testnet fixtures
/// @notice `TestnetAggregator` and `TestnetPoolPoker` are seeded and then abandoned: neither
///         has an owner and neither has a sweep function, so every rehearsal generation leaves
///         its inventory behind. Most of that inventory is mock USDC and mock WBTC, which mint
///         without permission and are worth nothing. The WETH is not - it is wrapped real
///         testnet ETH (`SEPOLIA_AGGREGATOR_WETH_WEI`), the one asset in the whole setup that a
///         faucet cannot replace, and at the intended 15,000 USDC of swap volume it runs to
///         several ETH.
///
/// @dev TESTNET TOOLING. Nothing in `src/` references this.
///
///      Recovery uses what each fixture already exposes to anybody:
///
///      - `TestnetAggregator.fill(tokenIn, tokenOut, amountIn, amountOut)` pays `amountOut` to
///        its caller out of inventory and takes `amountIn` in return, with no price of its own
///        and no access control. Naming the SWEPT token as `tokenIn` with an `amountIn` of zero
///        is what makes the recovery free: the zero-value `transferFrom` is a no-op on both a
///        6-decimal OZ mock and canonical WETH9, so the sweeper needs to hold nothing.
///      - `TestnetPoolPoker.uniswapV3SwapCallback` transfers the deltas it is handed to
///        `msg.sender` and never checks that a pool is calling it. Passing the same token as
///        both `token0` and `token1` with a zero `amount1Delta` sweeps one token per call.
///
///      Both are drain vectors that any Sepolia address can use, which is the reason to run the
///      sweep promptly rather than a reason to trust the fixtures - and the reason this library
///      must never be pointed at anything outside `script/mocks`.
library FixtureSweep {
    /// @notice Take the aggregator's whole `token` inventory, paying nothing for it.
    /// @param aggregator the `TestnetAggregator` to empty
    /// @param token the ERC-20 to recover
    /// @return amount the balance transferred to the caller; zero if there was none
    function fromAggregator(address aggregator, address token) internal returns (uint256 amount) {
        amount = IERC20(token).balanceOf(aggregator);
        if (amount == 0) return 0;
        TestnetAggregator(aggregator).fill(token, token, 0, amount);
    }

    /// @notice Take the poker's whole `token` balance through its unauthenticated callback.
    /// @param poker the `TestnetPoolPoker` to empty
    /// @param token the ERC-20 to recover
    /// @return amount the balance transferred to the caller; zero if there was none
    function fromPoker(address poker, address token) internal returns (uint256 amount) {
        amount = IERC20(token).balanceOf(poker);
        if (amount == 0) return 0;
        // The callback pays `token0` then `token1`; naming one token twice with a zero second
        // delta keeps each call to a single transfer.
        TestnetPoolPoker(poker).uniswapV3SwapCallback(SafeCast.toInt256(amount), 0, abi.encode(token, token));
    }

    /// @notice Unwrap `amount` of the caller's WETH9 into native ETH.
    /// @dev `SetupSepolia` wraps its aggregator seed out of native ETH
    ///      (`IWETH9.deposit{value: ...}`), so WETH left wrapped cannot fund the next
    ///      generation. `IWETH9` in `src/` is deposit-only on purpose - the vault never unwraps
    ///      - hence the local interface below.
    /// @param weth the WETH9 deployment
    /// @param amount wei to unwrap; zero is a no-op
    function unwrap(address weth, uint256 amount) internal {
        if (amount == 0) return;
        IWETH9Unwrap(weth).withdraw(amount);
    }
}

/// @notice The half of WETH9 that `src/interfaces/external/IWETH9.sol` deliberately omits.
interface IWETH9Unwrap {
    function withdraw(uint256 amount) external;
}
