// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract USDTToken is ERC20, Ownable {
    constructor() ERC20("USDT", "USDT") {
        _mint(msg.sender, 21000000 * 1e18);
    }
}
