// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract WrappedCoin is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function deposit() external payable {
        require(msg.value > 0);
        _mint(msg.sender, msg.value);
    }

    function depositTo(address to) external payable {
        require(msg.value > 0);
        _mint(to, msg.value);
    }

    function withdraw(uint256 _amount) external {
        require(_amount > 0);
        _burn(msg.sender, _amount);
        payable(msg.sender).transfer(_amount);
    }

    function withdrawTo(address payable to, uint256 _amount) external {
        require(_amount > 0);
        _burn(msg.sender, _amount);
        to.transfer(_amount);
    }
}
