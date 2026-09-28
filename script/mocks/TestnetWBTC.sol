// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestnetWBTC - freely mintable 8-decimal WBTC stand-in
/// @notice TESTNET ONLY. Arbitrum Sepolia has no WBTC market at all, and both MVP products
///         need one: BP Core runs two of its three sleeves on WBTC/USDC (`alpha_bu` at
///         rp 0.06 and `dyn_wbtc` at rp 0.20, told apart by range width), and DH Standalone
///         is `dyn_wbtc` alone, so without this token it can deploy nothing. This contract
///         must never be deployed to a production chain and is never referenced from `src/`.
///
/// @dev Three properties are load-bearing beyond the token's own behaviour, because
///      `SetupSepolia` mines a CREATE2 salt against this contract's creation code to fix
///      where it lands in the token sort order:
///
///      1. **No constructor arguments.** The creation code must equal the init code, or
///         `keccak256(type(TestnetWBTC).creationCode)` is not the hash the deployer uses.
///      2. **Nothing is minted at construction, and `msg.sender` is never read there.**
///         Under CREATE2 through the deterministic deployer `msg.sender` inside a
///         constructor is the PROXY, not the deployer, so a founder balance would silently
///         fund the proxy. Mint explicitly after deployment instead.
///      3. **The name and symbol are part of the creation code.** Changing either changes
///         the initcode hash, and therefore the mined salt and the deployed address. That is
///         fine - mining happens at runtime - but it means a recorded testnet address is only
///         valid for the exact committed source.
///
///      `foundry.toml` sets `bytecode_hash = "none"` and `cbor_metadata = false`, so the
///      creation code carries no metadata trailer and is stable across rebuilds. It is NOT
///      stable across compiler settings: `solc_version`, `optimizer_runs`, `via_ir` and
///      `evm_version` all move the initcode hash and therefore the address, so a recorded
///      address is only valid for the committed source AND the committed `foundry.toml`.
///
///      Decimals are 8 because that is `d0` for `WBTC/USDC` in the frozen engine's
///      `POOL_META`; the tick a price converts to depends on it.
contract TestnetWBTC is ERC20 {
    constructor() ERC20("Tuo Testnet Wrapped BTC", "WBTC") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
