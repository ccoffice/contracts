// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

interface IFamily {
    function makeRelation(address parent) external;

    function rootAddress() external view returns (address);

    function totalAddresses() external returns (uint256);

    function maxLayer() external returns (uint256);

    function depthOf(address user) external returns (uint256);

    function parentOf(address user) external view returns (address);

    function childrenOf(address owner) external view returns (address[] memory);

    function getForefathers(address user, uint256 depth)
        external
        returns (address[] memory);
}
