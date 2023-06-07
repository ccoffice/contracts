// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {PermissionControl} from "./permission/PermissionControl.sol";

contract LeaguePool is Initializable, PermissionControl {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // 用户信息.
    struct UserInfo {
        uint256 reward; // 累计未提取收益
        uint256 taked; // 累计已提取收益
        uint256 power; // 算力
        uint256 rewardDebt; // 债务率
    }

    /// @notice 用户信息
    mapping(address => UserInfo) public userPoolInfo;
    /// @notice 奖励储备额度
    uint256 public reserve;
    /// @notice 总算力
    uint256 public totalPower;
    /// @notice 总用户数量
    uint256 public userCounts;

    /// @notice 奖励代币
    address private rewardToken;
    /// @notice 投入资产
    address private depositToken;
    /// 单次投入量
    uint256 public onceSupply;
    /// @notice 矿池累计收益率
    uint256 private accTokenPerShare;

    /// @notice usdt接受地址
    address private usdtReceiver;

    /// @notice 时间节点
    address private epoch;

    uint256 public maxUserCount;

    bool private locked;

    event Deposit(address indexed user, uint256 amount, uint256 time);

    event TakeReward(address indexed user, uint256 reward, uint256 time);

    function initialize(
        address _depositToken,
        uint256 _onceSupply,
        address _usdtReceiver
    ) external initializer {
        __PermissionControl_init();
        depositToken = _depositToken;
        onceSupply = _onceSupply;
        maxUserCount = 100;
        usdtReceiver = _usdtReceiver;
    }

    modifier lock() {
        require(locked == false, "StaticPool: locked!");
        locked = true;
        _;
        locked = false;
    }

    function setUsdtReceiver(
        address _usdtReceiver
    ) external onlyRole(MANAGER_ROLE) {
        usdtReceiver = _usdtReceiver;
    }

    function setConfig(
        address _rewardToken,
        address _epoch
    ) external onlyRole(MANAGER_ROLE) {
        rewardToken = _rewardToken;
        epoch = _epoch;
    }

    /**
     * @notice 设置最大用户量
     * @param _maxUserCount 最大用户量
     */
    function setMaxUserCount(
        uint256 _maxUserCount
    ) external onlyRole(MANAGER_ROLE) {
        require(_maxUserCount > 0, "StaticPool: Invalid MaxUserCount!");
        maxUserCount = _maxUserCount;
    }

    /// @notice 分发奖励
    function distribute() external {
        require(msg.sender == epoch, "LeaguePool: Only Epoch");

        uint256 totalReward = IERC20Upgradeable(rewardToken).balanceOf(
            address(this)
        ) - reserve;

        if (totalReward > 0 && totalPower > 0) {
            accTokenPerShare += (totalReward * 1e12) / totalPower;
        }
        reserve += totalReward;
    }

    /// @notice 用户收益
    function earned(address account) public view returns (uint256) {
        UserInfo memory user = userPoolInfo[account];

        return (user.power * (accTokenPerShare - user.rewardDebt)) / 1e12;
    }

    /// @notice 投入
    function deposit() external {
        UserInfo storage user = userPoolInfo[msg.sender];
        require(user.power == 0, "LeaguePool: Only Once!");
        require(++userCounts <= maxUserCount, "LeaguePool: Only 100!");
        user.power += onceSupply;
        totalPower += onceSupply;
        user.rewardDebt = accTokenPerShare;
        IERC20Upgradeable(depositToken).safeTransferFrom(
            msg.sender,
            usdtReceiver,
            onceSupply
        );
        emit Deposit(msg.sender, onceSupply, block.timestamp);
    }

    /// @notice 领取收益
    function takeReward() external {
        UserInfo storage user = userPoolInfo[msg.sender];
        uint256 reward = (user.power * (accTokenPerShare - user.rewardDebt)) /
            1e12;
        if (reward > 0) {
            user.rewardDebt = accTokenPerShare;
            user.taked += reward;
            reserve -= reward;
            IERC20Upgradeable(rewardToken).safeTransfer(msg.sender, reward);
            emit TakeReward(msg.sender, reward, block.timestamp);
        }
    }
}
