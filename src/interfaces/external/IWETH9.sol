// SPDX-License-Identifier: GPL-2.0-or-later
// The floating pragma mirrors the upstream WETH9 interface verbatim so it stays diffable against
// the source. It binds nothing: this file has no bytecode, and foundry.toml pins the compile to
// solc 0.8.26 for the whole workspace.
// solhint-disable-next-line compiler-version
pragma solidity >=0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Minimal WETH9 interface (deposit-only; the vault never unwraps)
interface IWETH9 is IERC20 {
    function deposit() external payable;
}
