// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {PermissionControl} from "./permission/PermissionControl.sol";
import {ABDKMath64x64} from "./libs/ABDKMath64x64.sol";
import {Vault} from "./libs/Vault.sol";

import {IDynamicFarm} from "./interfaces/IDynamicFarm.sol";
import {IStaticPool} from "./interfaces/IStaticPool.sol";
import {IFarmTokenProvider} from "./interfaces/IFarmTokenProvider.sol";
import {IEpoch} from "./interfaces/IEpoch.sol";
import {IERC20Burn} from "./interfaces/IERC20Burn.sol";
import {ISwapRouter} from "./swap/swap-interfaces/ISwapRouter.sol";

contract StaticPool is
    Initializable,
    PermissionControl,
    IFarmTokenProvider,
    IStaticPool
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // 用户信息.
    struct UserInfo {
        uint256 reward; // 累计未提取收益
        uint256 taked; // 累计已提取收益
        uint256 power; // 算力
        uint256 rewardDebt; // 债务率
    }
    // 投入资产
    struct Capital {
        address token;
        uint256 radio;
        uint256 minValueOnce;
        address[] buyPath;
        bool burnOrDead;
    }

    /// @notice 用户信息
    mapping(address => UserInfo) public userInfoOf;
    /// @notice 本金代币信息
    mapping(address => Capital) public tokenConfigOf;
    /// @notice 奖励代币
    address private rewardToken;
    /// @notice usdt地址
    address private usdt;
    /// @notice 时间节点
    address private epoch;
    /// @notice swap路由
    address private router;
    /// @notice pancke路由
    address private panckRouter;
    /// @notice 捐赠地址
    address private usdtReceiver;
    /// @notice 动态矿池
    address private dFarm;
    /// @notice 奖励金库
    address public override vault;

    /// @notice 矿池累计收益率
    uint256 private accTokenPerShare;
    /// @notice 总算力
    uint256 public override totalPower;
    /// @notice 奖励储备额度
    uint256 public reserve;

    bool private locked;

    event Deposit(
        address indexed user,
        address token,
        uint256 depostValue,
        uint256 liquidity,
        uint256 burnamount,
        uint256 power,
        uint256 time
    );

    event TakeReward(address indexed user, uint256 reward, uint256 time);

    function initialize(
        address _rewardToken,
        address _usdt,
        address _router,
        address _epoch,
        address _dFarm,
        address _usdtReceiver,
        address _panckRouter
    ) external initializer {
        __PermissionControl_init();
        rewardToken = _rewardToken;
        usdt = _usdt;
        router = _router;
        epoch = _epoch;
        dFarm = _dFarm;
        usdtReceiver = _usdtReceiver;
        panckRouter = _panckRouter;
        IERC20Upgradeable(usdt).approve(router, type(uint256).max);
        IERC20Upgradeable(rewardToken).approve(router, type(uint256).max);
        vault = address(new Vault(rewardToken));
    }

    modifier lock() {
        require(locked == false, "StaticPool: locked!");
        locked = true;
        _;
        locked = false;
    }

    /**
     * @notice 设置捐赠地址
     * @param _usdtReceiver 捐赠地址
     */
    function setUsdtReceiver(
        address _usdtReceiver
    ) external onlyRole(MANAGER_ROLE) {
        require(
            _usdtReceiver != address(0),
            "StaticPool: Invalid usdtReceiver!"
        );
        usdtReceiver = _usdtReceiver;
    }

    /**
     * @notice 设置动态矿池
     * @param _dFarm 动态矿池
     */
    function setDFarm(address _dFarm) external onlyRole(MANAGER_ROLE) {
        require(_dFarm != address(0), "StaticPool: Invalid dFarm!");
        dFarm = _dFarm;
    }

    /**
     * @notice 添加资产代币
     * @param token 代币地址
     * @param radio 投入代币占比 $amount:szabo
     * @param minValueOnce 单次投入最小总价值 $amount:ether
     * @param burnOrDead 是否可以函数销毁
     */
    function setTokenConfig(
        address token,
        uint256 radio,
        uint256 minValueOnce,
        bool burnOrDead
    ) external onlyRole(MANAGER_ROLE) {
        require(radio <= 0.9e12, "StaticPool: Invalid Radio!");
        require(token != address(0), "StaticPool: Invalid Token");
        Capital storage tokenConfig = tokenConfigOf[token];
        tokenConfig.token = token;
        tokenConfig.radio = radio;
        tokenConfig.minValueOnce = minValueOnce;
        tokenConfig.burnOrDead = burnOrDead;
        tokenConfig.buyPath = [usdt, token];
    }

    /**
     * @notice 删除资产代币
     * @param token 代币地址
     */
    function removeTokenConfig(address token) external onlyRole(MANAGER_ROLE) {
        delete tokenConfigOf[token];
    }

    /// @notice 分发奖励
    function distribute() external {
        require(msg.sender == epoch, "StaticPool: Only Epoch");

        uint256 totalReward = IERC20Upgradeable(rewardToken).balanceOf(vault) -
            reserve;

        if (totalReward > 0 && totalPower > 0) {
            accTokenPerShare += (totalReward * 1e12) / totalPower;
        }
        reserve += totalReward;
    }

    /**
     * @notice 用户可领取收益
     * @param account  用户地址
     * @return 用户未领取收益 $amount:ether
     */
    function earned(address account) public view returns (uint256) {
        UserInfo memory user = userInfoOf[account];
        return
            user.reward +
            (user.power * (accTokenPerShare - user.rewardDebt)) /
            1e12;
    }

    function getPowerByUSDT(uint256 amount) public view returns (uint256) {
        // 幂运算
        int128 float = ABDKMath64x64.divu(1.02e12, 1e12);
        int128 pow = ABDKMath64x64.pow(float, IEpoch(epoch).getCurrentEpoch());
        return ABDKMath64x64.mulu(pow, amount);
    }

    /**
     * @notice 获得一定数量usdt需要提供的token
     * @param token 卖出代币
     * @param volumeUSD 获得usdt数量
     */
    function needToken(
        address token,
        uint256 volumeUSD
    ) public view returns (uint256) {
        address[] memory tmpPath = new address[](2);
        tmpPath[0] = token;
        tmpPath[1] = usdt;
        uint256[] memory tokenOuts = ISwapRouter(panckRouter).getAmountsIn(
            volumeUSD,
            tmpPath
        );
        return tokenOuts[0];
    }

    /**
     * @notice 质押投入
     * @param token 质押主代币
     * @param totalVolumeUSD  质押总价值(usdt) $amount:ether
     */
    function deposit(address token, uint256 totalVolumeUSD) external lock {
        Capital memory tokenConfig = tokenConfigOf[token];
        require(token == tokenConfig.token, "StaticPool: INVALID_TOKEN!");
        require(
            totalVolumeUSD >= tokenConfig.minValueOnce,
            "StaticPool: Too Low"
        );
        uint256 usdtAmount = ((1e12 - tokenConfig.radio) * totalVolumeUSD) /
            1e12;

        uint256 liquidity;
        uint256 burnAmount;
        if (tokenConfig.radio > 0) {
            uint256 tokenAmount = needToken(
                token,
                (totalVolumeUSD * tokenConfig.radio) / 1e12
            );
            if (tokenAmount > 0) {
                IERC20Upgradeable(token).safeTransferFrom(
                    msg.sender,
                    address(this),
                    tokenAmount
                );
            }
        }

        if (usdtAmount > 0) {
            IERC20Upgradeable(usdt).safeTransferFrom(
                msg.sender,
                address(this),
                usdtAmount
            );
            uint256 usdtExpend = (usdtAmount * 6) / 10;
            ISwapRouter(router)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    usdtExpend,
                    0,
                    tokenConfig.buyPath,
                    address(this),
                    block.timestamp
                );
            (, , liquidity) = ISwapRouter(router).addLiquidity(
                usdt,
                token,
                usdtAmount - usdtExpend,
                IERC20Upgradeable(token).balanceOf(address(this)),
                usdtAmount - usdtExpend,
                0,
                epoch,
                block.timestamp
            );
        }

        burnAmount = IERC20Upgradeable(token).balanceOf(address(this));
        if (tokenConfig.burnOrDead) {
            IERC20Burn(token).burn(burnAmount);
        } else {
            IERC20Upgradeable(token).safeTransfer(address(0xdead), burnAmount);
        }
        uint256 power = getPowerByUSDT(totalVolumeUSD);
        _deposit(msg.sender, power);

        emit Deposit(
            msg.sender,
            token,
            totalVolumeUSD,
            liquidity,
            burnAmount,
            power,
            block.timestamp
        );
    }

    function _deposit(address account, uint256 amount) internal {
        UserInfo storage user = userInfoOf[account];
        if (user.power > 0) {
            user.reward +=
                (user.power * (accTokenPerShare - user.rewardDebt)) /
                1e12;
        }
        user.power += amount;
        totalPower += amount;
        user.rewardDebt = accTokenPerShare;
    }

    /// @notice 领取收益
    function takeReward() external {
        UserInfo storage user = userInfoOf[msg.sender];
        uint256 reward = user.reward +
            (user.power * (accTokenPerShare - user.rewardDebt)) /
            1e12;
        if (reward > 0) {
            user.reward = 0;
            user.rewardDebt = accTokenPerShare;
            user.taked += reward;
            reserve -= reward;
            IERC20Upgradeable(rewardToken).safeTransferFrom(
                vault,
                msg.sender,
                reward
            );
            IDynamicFarm(dFarm).addPowerA(msg.sender, reward);
            emit TakeReward(msg.sender, reward, block.timestamp);
        }
    }

    function ido(
        address account,
        uint256 amount
    ) external onlyRole(DELEGATE_ROLE) {
        _deposit(account, amount);
    }

    /**
     * @notice 卖出复投
     * @param amountIn 卖出的token数量
     * @param operator 操作者
     * @param to 倒账地址
     */
    function afterSell(
        uint256 amountIn,
        address operator,
        address to
    ) external override lock {
        amountIn;
        address[] memory tmpPath = new address[](2);
        tmpPath[0] = usdt;
        tmpPath[1] = rewardToken;

        uint256 usdtAmount = IERC20Upgradeable(usdt).balanceOf(address(this));
        require(usdtAmount > 0, "FarmSellProvider: NO_SELL");
        // 卖出所得usdt45%给用户
        IERC20Upgradeable(usdt).safeTransfer(to, (usdtAmount * 0.45e12) / 1e12);

        // 卖出所得usdt50%回购token销毁
        ISwapRouter(router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                (usdtAmount * 0.5e12) / 1e12,
                0,
                tmpPath,
                address(this),
                block.timestamp
            );
        uint256 amountToken = IERC20Upgradeable(rewardToken).balanceOf(
            address(this)
        );

        IERC20Burn(rewardToken).burn(amountToken);

        IERC20Upgradeable(usdt).safeTransfer(
            usdtReceiver,
            IERC20Upgradeable(usdt).balanceOf(address(this))
        );
        uint256 power = getPowerByUSDT((usdtAmount * 0.5e12) / 1e12);

        _deposit(operator, power);

        emit Deposit(
            msg.sender,
            rewardToken,
            (usdtAmount * 0.5e12) / 1e12,
            0,
            0,
            power,
            block.timestamp
        );
    }
}
