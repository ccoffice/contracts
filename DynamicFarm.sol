// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {Initializable, PermissionControl} from "./permission/PermissionControl.sol";
import {IFarmTokenProvider} from "./interfaces/IFarmTokenProvider.sol";

import {IFamily} from "./interfaces/IFamily.sol";
import {IEpoch, RewardType} from "./interfaces/IEpoch.sol";
import {IDynamicFarm} from "./interfaces/IDynamicFarm.sol";

contract DynamicFarm is Initializable, PermissionControl, IDynamicFarm {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    struct UserInfo {
        uint256 lastEpoch;
        mapping(uint256 => uint256) powerA;
        mapping(uint256 => uint256) powerB;
        mapping(uint256 => uint256) powerT;
        mapping(uint256 => uint256) powerN;
    }
    struct NodeData {
        uint256 totalPower;
        uint256 avePower;
        uint256 userCount;
    }

    struct RewardData {
        uint256 totalPower;
        uint256 totalReward;
    }

    struct NodeRadio {
        uint256 epoch;
        uint256 radio;
    }

    /// @notice 每期 N值分布情况
    mapping(uint256 => NodeData) public nodeInfoOf;
    /// @notice 每期布道总奖励
    mapping(uint256 => RewardData) public override shareRewardOfEpoch;
    /// @notice 每期低节点总奖励
    mapping(uint256 => RewardData) public override lNodeRewardOfEpoch;
    /// @notice 每期高节总奖励
    mapping(uint256 => RewardData) public override hNodeRewardOfEpoch;

    /// @notice 进入低节点要求的最低N值比例(比例 = 当期powerN / 上期avePower)
    NodeRadio[] private lNradios;
    /// @notice 进入高节点要求的最低N值比例(比例 = 当期powerN / 上期avePower)
    NodeRadio[] private hNradios;

    address private rewardToken;
    mapping(address => UserInfo) private userInfoOf;

    address private family;
    /// @notice 时间节点
    address private epoch;

    bool private locked;

    uint256 private reserve;

    mapping(address => uint256) public userTakedOf;

    event TakeReward(address indexed user, uint256 reward, uint256 time);

    function initialize(
        address _rewardToken,
        address _family,
        address _epoch
    ) external initializer {
        __PermissionControl_init();
        rewardToken = _rewardToken;
        family = _family;
        epoch = _epoch;
        lNradios.push(NodeRadio({epoch: 0, radio: 1e12}));
        hNradios.push(NodeRadio({epoch: 0, radio: 3e12}));
    }

    modifier lock() {
        require(locked == false, "DynamicFarm: locked!");
        locked = true;
        _;
        locked = false;
    }

    function distribute(RewardType rewardType, uint256 currentEpoch) external {
        require(msg.sender == epoch, "LeaguePool: Only Epoch");

        uint256 totalReward = IERC20Upgradeable(rewardToken).balanceOf(
            address(this)
        ) - reserve;
        if (rewardType == RewardType.share) {
            shareRewardOfEpoch[currentEpoch].totalReward += totalReward;
        }

        if (rewardType == RewardType.lNode) {
            lNodeRewardOfEpoch[currentEpoch].totalReward += totalReward;
        }

        if (rewardType == RewardType.hNode) {
            hNodeRewardOfEpoch[currentEpoch].totalReward += totalReward;
        }
        reserve += totalReward;
    }

    /**
     * @notice 添加新的低节点N值门槛
     * @param radio 进入低节点要求的最低N值比例(比例 = 当期powerN / 上期avePower) $amount:szabo
     */
    function addLNRadio(uint256 radio) external onlyRole(MANAGER_ROLE) {
        uint256 currentEpoch = IEpoch(epoch).getCurrentEpoch();
        lNradios.push(NodeRadio({epoch: currentEpoch + 1, radio: radio}));
    }

    /**
     * @notice 添加新的高节点N值门槛
     * @param radio 进入高节点要求的最低N值比例(比例 = 当期powerN / 上期avePower) $amount:szabo
     */
    function addHNRadio(uint256 radio) external onlyRole(MANAGER_ROLE) {
        uint256 currentEpoch = IEpoch(epoch).getCurrentEpoch();
        hNradios.push(NodeRadio({epoch: currentEpoch + 1, radio: radio}));
    }

    /**
     *
     * @param account 用户地址
     * @param amount 用户A值增量
     */
    function addPowerA(
        address account,
        uint256 amount
    ) external onlyRole(DELEGATE_ROLE) {
        require(amount > 0, "DynamicFarm: Invalid Amount");
        require(account != address(0), "DynamicFarm: Invalid Account");
        _addPowerA(account, amount);
    }

    function _addPowerA(address account, uint256 amount) internal {
        uint256 currentEpoch = IEpoch(epoch).getCurrentEpoch();
        UserInfo storage user = userInfoOf[account];
        // 自己的A增加
        user.powerA[currentEpoch] += amount;
        // 自己的T增加
        updatePowerT(user, account, currentEpoch);
        // 上级的变化
        address parentAddress = IFamily(family).parentOf(account);
        if (parentAddress != address(0)) {
            // 上级的B增加
            UserInfo storage parent = userInfoOf[parentAddress];
            parent.powerB[currentEpoch] += amount;
            // 上级的T变化
            updatePowerT(parent, parentAddress, currentEpoch);
        }
    }

    function updatePowerT(
        UserInfo storage user,
        address userAddress,
        uint256 currentEpoch
    ) internal {
        uint256 oldT = user.powerT[currentEpoch];
        user.powerT[currentEpoch] =
            (user.powerB[currentEpoch] *
                (1e12 +
                    (user.powerA[currentEpoch] * 1e12) /
                    (user.powerA[currentEpoch] + user.powerB[currentEpoch]))) /
            1e12;
        bool isGt = user.powerT[currentEpoch] > oldT;
        uint256 diff = isGt
            ? user.powerT[currentEpoch] - oldT
            : oldT - user.powerT[currentEpoch];
        if (isGt) {
            shareRewardOfEpoch[currentEpoch].totalPower += diff;
        } else {
            shareRewardOfEpoch[currentEpoch].totalPower -= diff;
        }
        address parent = IFamily(family).parentOf(userAddress);
        // 上级的N变化
        if (parent != address(0)) {
            // 更新上级的N值 以及全网N的统计结果
            NodeData storage node = nodeInfoOf[currentEpoch];
            uint256 oldN = userInfoOf[parent].powerN[currentEpoch];
            if (isGt) {
                if (oldN == 0) {
                    node.userCount++;
                }
                userInfoOf[parent].powerN[currentEpoch] += diff;
                node.totalPower += diff;
            } else {
                require(oldN >= diff, "DynamicFarm: Error Diff");
                userInfoOf[parent].powerN[currentEpoch] -= diff;
                node.totalPower -= diff;
            }
            if (node.userCount > 0) {
                node.avePower = node.totalPower / node.userCount;
            }
            // 上级用户是否可以进入 节点分红
            if (currentEpoch > 0) {
                uint256 lastLAvePower = (nodeInfoOf[currentEpoch - 1].avePower *
                    getRadio(lNradios, currentEpoch)) / 1e12;
                uint256 lastHAvePower = (nodeInfoOf[currentEpoch - 1].avePower *
                    getRadio(hNradios, currentEpoch)) / 1e12;
                uint256 newN = userInfoOf[parent].powerN[currentEpoch];
                // 低节点分红
                if (newN > lastLAvePower) {
                    if (oldN > lastLAvePower) {
                        lNodeRewardOfEpoch[currentEpoch].totalPower -= oldN;
                        lNodeRewardOfEpoch[currentEpoch].totalPower += newN;
                    } else {
                        lNodeRewardOfEpoch[currentEpoch].totalPower += newN;
                    }
                } else {
                    if (oldN > lastLAvePower) {
                        lNodeRewardOfEpoch[currentEpoch].totalPower -= oldN;
                    }
                }
                // 高节点分红
                if (newN > lastHAvePower) {
                    if (oldN > lastHAvePower) {
                        hNodeRewardOfEpoch[currentEpoch].totalPower -= oldN;
                        hNodeRewardOfEpoch[currentEpoch].totalPower += newN;
                    } else {
                        hNodeRewardOfEpoch[currentEpoch].totalPower += newN;
                    }
                } else {
                    if (oldN > lastHAvePower) {
                        hNodeRewardOfEpoch[currentEpoch].totalPower -= oldN;
                    }
                }
            }
        }
    }

    /**
     * @notice 用户数据
     * @param account 用户地址
     * @param _epoch 指定期数
     * @return powerA 用户当期领取币量 $amount:ether
     * @return powerB 用户当期直接邀请人领取币量 $amount:ether
     * @return powerT 用户当期布道算力 $amount:ether
     * @return powerN 用户当期节点算力 $amount:ether
     */
    function userDataOfEpoch(
        address account,
        uint256 _epoch
    )
        external
        view
        returns (uint256 powerA, uint256 powerB, uint256 powerT, uint256 powerN)
    {
        UserInfo storage user = userInfoOf[account];
        powerA = user.powerA[_epoch];
        powerB = user.powerB[_epoch];
        powerT = user.powerT[_epoch];
        powerN = user.powerN[_epoch];
    }

    /**
     *
     * @notice 30期内 用户布道奖励列表
     * @param account 用户地址
     * @return rewards 奖励额度列表
     * @return selfPower 自身算力列表
     * @return totalPower 总算力列表
     * @return totalReward 总奖励列表
     */
    function earnShare(
        address account
    )
        external
        view
        returns (
            uint256[] memory rewards,
            uint256[] memory selfPower,
            uint256[] memory totalPower,
            uint256[] memory totalReward
        )
    {
        uint256 currentEpoch = IEpoch(epoch).getCurrentEpoch();
        UserInfo storage user = userInfoOf[account];
        if (currentEpoch > user.lastEpoch) {
            uint256 length = currentEpoch - user.lastEpoch;
            length = length > 30 ? 30 : length;
            rewards = new uint256[](length);
            selfPower = new uint256[](length);
            totalPower = new uint256[](length);
            totalReward = new uint256[](length);
            for (uint i = user.lastEpoch; i < length; i++) {
                if (shareRewardOfEpoch[user.lastEpoch + i].totalPower > 0) {
                    rewards[i] =
                        (user.powerT[user.lastEpoch + i] *
                            shareRewardOfEpoch[user.lastEpoch + i]
                                .totalReward) /
                        shareRewardOfEpoch[user.lastEpoch + i].totalPower;
                }

                selfPower[i] = user.powerT[user.lastEpoch + i];
                totalPower[i] = shareRewardOfEpoch[user.lastEpoch + i]
                    .totalPower;
                totalReward[i] = shareRewardOfEpoch[user.lastEpoch + i]
                    .totalReward;
            }
        }
    }

    /**
     * @notice 30期内用户普通节点奖励列表
     * @param account 用户地址
     * @return rewards 奖励列表
     * @return selfPower 自身算力列表
     * @return totalPower 总算力列表
     * @return minPower 普通节点准入门槛列表
     */
    function earnLNode(
        address account
    )
        external
        view
        returns (
            uint256[] memory rewards,
            uint256[] memory selfPower,
            uint256[] memory totalPower,
            uint256[] memory minPower
        )
    {
        uint256 currentEpoch = IEpoch(epoch).getCurrentEpoch();
        UserInfo storage user = userInfoOf[account];
        if (currentEpoch > user.lastEpoch) {
            uint256 length = currentEpoch - user.lastEpoch;
            length = length > 30 ? 30 : length;
            rewards = new uint256[](length);
            selfPower = new uint256[](length);
            totalPower = new uint256[](length);
            minPower = new uint256[](length);
            for (uint i = user.lastEpoch; i < length; i++) {
                if (user.lastEpoch + i > 0) {
                    minPower[i] =
                        (nodeInfoOf[user.lastEpoch + i - 1].avePower *
                            getRadio(lNradios, user.lastEpoch + i)) /
                        1e12;
                    if (
                        user.powerN[user.lastEpoch + i] > minPower[i] &&
                        lNodeRewardOfEpoch[user.lastEpoch + i].totalPower > 0
                    ) {
                        rewards[i] =
                            (user.powerN[user.lastEpoch + i] *
                                lNodeRewardOfEpoch[user.lastEpoch + i]
                                    .totalReward) /
                            lNodeRewardOfEpoch[user.lastEpoch + i].totalPower;
                    }
                    selfPower[i] = user.powerN[user.lastEpoch + i];
                    totalPower[i] = lNodeRewardOfEpoch[user.lastEpoch + i]
                        .totalPower;
                }
            }
        }
    }

    /**
     * @notice 30期内用户超级节点奖励列表
     * @param account 用户地址
     * @return rewards 奖励额度列表
     * @return selfPower 自身算力列表
     * @return totalPower 总算力列表
     * @return minPower 超级节点准入门槛列表
     */
    function earnHNode(
        address account
    )
        external
        view
        returns (
            uint256[] memory rewards,
            uint256[] memory selfPower,
            uint256[] memory totalPower,
            uint256[] memory minPower
        )
    {
        uint256 currentEpoch = IEpoch(epoch).getCurrentEpoch();
        UserInfo storage user = userInfoOf[account];
        if (currentEpoch > user.lastEpoch) {
            uint256 length = currentEpoch - user.lastEpoch;
            length = length > 30 ? 30 : length;
            rewards = new uint256[](length);
            selfPower = new uint256[](length);
            totalPower = new uint256[](length);
            minPower = new uint256[](length);
            for (uint i = user.lastEpoch; i < length; i++) {
                if (user.lastEpoch + i > 0) {
                    minPower[i] =
                        (nodeInfoOf[user.lastEpoch + i - 1].avePower *
                            getRadio(hNradios, user.lastEpoch + i)) /
                        1e12;
                    if (
                        user.powerN[user.lastEpoch + i] > minPower[i] &&
                        hNodeRewardOfEpoch[user.lastEpoch + i].totalPower > 0
                    ) {
                        rewards[i] =
                            (user.powerN[user.lastEpoch + i] *
                                hNodeRewardOfEpoch[user.lastEpoch + i]
                                    .totalReward) /
                            hNodeRewardOfEpoch[user.lastEpoch + i].totalPower;
                    }
                    selfPower[i] = user.powerN[user.lastEpoch + i];
                    totalPower[i] = hNodeRewardOfEpoch[user.lastEpoch + i]
                        .totalPower;
                }
            }
        }
    }

    /**
     * @notice 上期节收益
     * @param account 用户地址
     * @return lNodeShare 上期普通节点收益
     * @return hNodeShare 上期超级节点收益
     */
    function lastEpochData(
        address account
    ) external view returns (uint256 lNodeShare, uint256 hNodeShare) {
        uint256 currentEpoch = IEpoch(epoch).getCurrentEpoch();
        if (currentEpoch > 1) {
            currentEpoch -= 1;
            UserInfo storage user = userInfoOf[account];
            uint256 hminPower = (nodeInfoOf[currentEpoch - 1].avePower *
                getRadio(hNradios, currentEpoch)) / 1e12;
            if (
                user.powerN[currentEpoch] > hminPower &&
                hNodeRewardOfEpoch[currentEpoch].totalPower > 0
            ) {
                hNodeShare =
                    (user.powerN[currentEpoch] *
                        hNodeRewardOfEpoch[currentEpoch].totalReward) /
                    hNodeRewardOfEpoch[currentEpoch].totalPower;
            }

            uint256 lminPower = (nodeInfoOf[currentEpoch - 1].avePower *
                getRadio(lNradios, currentEpoch)) / 1e12;
            if (
                user.powerN[currentEpoch] > lminPower &&
                lNodeRewardOfEpoch[currentEpoch].totalPower > 0
            ) {
                lNodeShare =
                    (user.powerN[currentEpoch] *
                        lNodeRewardOfEpoch[currentEpoch].totalReward) /
                    lNodeRewardOfEpoch[currentEpoch].totalPower;
            }
        }
    }

    /**
     * @notice 用户奖励可领的推广收益
     * @param account 用户地址
     * @return 用户累计未领取奖励 $amount:ether
     */
    function shareEarn(address account) external view returns (uint256) {
        uint256 currentEpoch = IEpoch(epoch).getCurrentEpoch();
        UserInfo storage user = userInfoOf[account];
        if (currentEpoch <= user.lastEpoch) {
            return 0;
        }
        uint256 length = currentEpoch - user.lastEpoch;
        length = length > 30 ? user.lastEpoch + 30 : currentEpoch;
        uint256 reward;
        for (uint i = user.lastEpoch; i < length; i++) {
            if (shareRewardOfEpoch[i].totalPower > 0) {
                reward +=
                    (user.powerT[i] * shareRewardOfEpoch[i].totalReward) /
                    shareRewardOfEpoch[i].totalPower;
            }
        }
        return reward;
    }

    /**
     * @notice 用户奖励可领取奖励
     * @param account 用户地址
     * @return 用户累计未领取奖励 $amount:ether
     */
    function earned(address account) external view returns (uint256) {
        uint256 currentEpoch = IEpoch(epoch).getCurrentEpoch();
        UserInfo storage user = userInfoOf[account];
        if (currentEpoch <= user.lastEpoch) {
            return 0;
        }
        uint256 length = currentEpoch - user.lastEpoch;
        length = length > 30 ? user.lastEpoch + 30 : currentEpoch;
        uint256 reward;
        for (uint i = user.lastEpoch; i < length; i++) {
            if (shareRewardOfEpoch[i].totalPower > 0) {
                reward +=
                    (user.powerT[i] * shareRewardOfEpoch[i].totalReward) /
                    shareRewardOfEpoch[i].totalPower;
            }

            if (i > 0) {
                if (
                    user.powerN[i] >
                    (nodeInfoOf[i - 1].avePower * getRadio(lNradios, i)) /
                        1e12 &&
                    lNodeRewardOfEpoch[i].totalPower > 0
                ) {
                    reward +=
                        (user.powerN[i] * lNodeRewardOfEpoch[i].totalReward) /
                        lNodeRewardOfEpoch[i].totalPower;
                }

                if (
                    user.powerN[i] >
                    (nodeInfoOf[i - 1].avePower * getRadio(hNradios, i)) /
                        1e12 &&
                    hNodeRewardOfEpoch[i].totalPower > 0
                ) {
                    reward +=
                        (user.powerN[i] * hNodeRewardOfEpoch[i].totalReward) /
                        hNodeRewardOfEpoch[i].totalPower;
                }
            }
        }
        return reward;
    }

    /// @notice 领取奖励
    function takeReward() external {
        uint256 currentEpoch = IEpoch(epoch).getCurrentEpoch();
        UserInfo storage user = userInfoOf[msg.sender];
        require(currentEpoch > user.lastEpoch, "DynamicFarm: It is not time!");
        uint256 length = currentEpoch - user.lastEpoch;
        length = length > 30 ? user.lastEpoch + 30 : currentEpoch;
        uint256 reward;
        for (uint i = user.lastEpoch; i < length; i++) {
            if (shareRewardOfEpoch[i].totalPower > 0) {
                reward +=
                    (user.powerT[i] * shareRewardOfEpoch[i].totalReward) /
                    shareRewardOfEpoch[i].totalPower;
            }
            if (i > 0) {
                if (
                    user.powerN[i] >
                    (nodeInfoOf[i - 1].avePower * getRadio(lNradios, i)) /
                        1e12 &&
                    lNodeRewardOfEpoch[i].totalPower > 0
                ) {
                    reward +=
                        (user.powerN[i] * lNodeRewardOfEpoch[i].totalReward) /
                        lNodeRewardOfEpoch[i].totalPower;
                }

                if (
                    user.powerN[i] >
                    (nodeInfoOf[i - 1].avePower * getRadio(hNradios, i)) /
                        1e12 &&
                    hNodeRewardOfEpoch[i].totalPower > 0
                ) {
                    reward +=
                        (user.powerN[i] * hNodeRewardOfEpoch[i].totalReward) /
                        hNodeRewardOfEpoch[i].totalPower;
                }
            }
        }
        user.lastEpoch = length;
        if (reward > 0) {
            _addPowerA(msg.sender, reward);
            reserve -= reward;
            userTakedOf[msg.sender] += reward;
            IERC20Upgradeable(rewardToken).safeTransfer(msg.sender, reward);
            emit TakeReward(msg.sender, reward, block.timestamp);
        }
    }

    function getRadio(
        NodeRadio[] storage data,
        uint256 currentEpoch
    ) internal view returns (uint256 radio) {
        uint256 length = data.length;
        for (uint i = 0; i < length; i++) {
            if (currentEpoch >= data[i].epoch) {
                radio = data[i].radio;
            }
        }
    }
}
