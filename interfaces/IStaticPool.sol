// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

interface IStaticPool {
    function vault() external returns (address);

    function distribute() external;

    function ido(address account, uint256 amount) external;

    function totalPower() external returns (uint256);
}
