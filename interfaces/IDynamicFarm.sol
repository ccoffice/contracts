// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import {RewardType} from "./IEpoch.sol";

interface IDynamicFarm {
    function addPowerA(address account, uint256 amount) external;

    function distribute(RewardType, uint256) external;

    function shareRewardOfEpoch(
        uint256
    ) external view returns (uint256, uint256);

    function lNodeRewardOfEpoch(
        uint256
    ) external view returns (uint256, uint256);

    function hNodeRewardOfEpoch(
        uint256
    ) external view returns (uint256, uint256);
}
