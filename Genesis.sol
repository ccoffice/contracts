// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {PermissionControl} from "./permission/PermissionControl.sol";
import {ABDKMath64x64} from "./libs/ABDKMath64x64.sol";
import {IStaticPool} from "./interfaces/IStaticPool.sol";

contract Genesis is Initializable, PermissionControl {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    address private usdt;

    /// @notice usdt接受地址
    address private usdtReceiver;
    address private staticPool;

    /// @notice 总限额
    uint256 public totalQuota;
    /// @notice 已认购总量
    uint256 public totalBought;
    /// @notice 用户已购买量
    mapping(address => uint256) public boughtOf;

    uint256 private period;
    uint256 public startTime;
    bool private isOpened;

    event Subscribe(address indexed user, uint256 amount, uint256 time);

    function initialize(
        address _usdt,
        address _staticPool,
        address _usdtReceiver,
        uint256 _totalQuota
    ) external initializer {
        __PermissionControl_init();
        usdt = _usdt;
        staticPool = _staticPool;
        usdtReceiver = _usdtReceiver;
        totalQuota = _totalQuota;
        period = 1 days;
    }

    /// @notice 开启IDO
    function start() external onlyRole(MANAGER_ROLE) {
        require(startTime == 0, "it is started");
        startTime = block.timestamp;
    }

    /// @notice 开启认购
    function openSubscribe() external onlyRole(MANAGER_ROLE) {
        isOpened = true;
    }

    /// @notice 关闭认购
    function closeSubscribe() external onlyRole(MANAGER_ROLE) {
        isOpened = false;
    }

    /**
     * @notice 设置限额
     * @param amount 总限额 $amount:ether
     */
    function setTotalQuota(uint256 amount) external onlyRole(MANAGER_ROLE) {
        totalQuota = amount;
    }

    function test() external view returns (uint256) {
        uint256 epoch = (block.timestamp - startTime) / period;
        uint256 tmp = epoch <= 15 ? 15 - epoch : 0;
        return tmp;
    }

    /**
     * @notice 获得算力
     * @param amount usdt数量
     * @return 对应算力 $amount:ether
     */
    function getPowerByUSDT(uint256 amount) public view returns (uint256) {
        uint256 epoch = (block.timestamp - startTime) / period;
        uint256 tmp = epoch <= 15 ? 15 - epoch : 0;
        // 幂运算
        int128 float = ABDKMath64x64.divu(1.02e12, 1e12);
        int128 pow = ABDKMath64x64.pow(float, tmp);
        return ABDKMath64x64.mulu(pow, amount);
    }

    /**
     * @notice 创世认购
     * @param amount 愿意支付的usdt数量
     */
    function subscribe(uint256 amount) external {
        require(
            block.timestamp >= startTime && startTime > 0,
            "it is not started"
        );
        require(isOpened, "it is closed");
        require(amount >= 100e18, "too low!");
        require(boughtOf[msg.sender] + amount <= 2000e18, "too most!");
        require(totalBought + amount <= totalQuota, "have no quota!");
        boughtOf[msg.sender] += amount;
        totalBought += amount;
        IStaticPool(staticPool).ido(msg.sender, getPowerByUSDT(amount));
        IERC20Upgradeable(usdt).safeTransferFrom(
            msg.sender,
            usdtReceiver,
            amount
        );
        emit Subscribe(msg.sender, amount, block.timestamp);
    }
}
