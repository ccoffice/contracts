// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Vault {
    constructor(address _token) {
        require(IERC20(_token).approve(msg.sender, type(uint256).max));
    }
}
