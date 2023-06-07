// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;
enum RewardType {
    share,
    lNode,
    hNode
}

interface IEpoch {
    function getCurrentEpoch() external view returns (uint256);
}
