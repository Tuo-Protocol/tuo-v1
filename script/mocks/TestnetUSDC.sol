// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestnetUSDC - freely mintable 6-decimal USDC stand-in
/// @notice TESTNET ONLY. `mint` is deliberately unpermissioned so anyone rehearsing the
///         deposit flow can reach `TuoConstants.MIN_DEPOSIT_USDC` (2,500e6); Circle's
///         Arbitrum Sepolia faucet caps out far below that. This contract must never be
///         deployed to a production chain and is never referenced from `src/`.
contract TestnetUSDC is ERC20 {
    constructor() ERC20("Tuo Testnet USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
