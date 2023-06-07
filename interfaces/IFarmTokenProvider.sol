// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

interface IFarmTokenProvider {
    function afterSell(uint256 amountIn, address operator, address to) external;
}
