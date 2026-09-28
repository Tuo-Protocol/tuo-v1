// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    /// @dev `IWETH9` in `src/` is deposit-only because the vault never unwraps. The Sepolia
    ///      fixture sweep does, so the mock carries the other half of WETH9's surface.
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "MockWETH: ETH transfer failed");
    }
}
