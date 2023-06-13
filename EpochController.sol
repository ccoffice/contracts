// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable, PermissionControl} from "./permission/PermissionControl.sol";
import {IEpoch, RewardType} from "./interfaces/IEpoch.sol";
import {IDynamicFarm} from "./interfaces/IDynamicFarm.sol";
import {IStaticPool} from "./interfaces/IStaticPool.sol";
import {ISwapRouter} from "./swap/swap-interfaces/ISwapRouter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract EpochController is Ownable, IEpoch {
    using SafeERC20 for IERC20;
    address private staticPool;
    address private leaguePool;
    address private dynamicFarm;
    address private foundationAddress;
    address private operationAddress;
    address private technicalAddress;

    address private router;
    address private rewardToken;
    address private usdt;
    address private pair;
    address[] private buyPath;

    uint256 private period;
    uint256 private startTime;
    uint256 private lastExecutedAt;

    uint256 private initRemoveRadio;

    uint256 private currentEpoch;

    event ShareOutBonus(
        uint256 indexed epach,
        uint256 totalLiquidity,
        uint256 totalToken,
        uint256 time
    );

    constructor(
        address _rewardToken,
        address _usdt,
        address _router,
        address _pair,
        address _foundationAddress,
        address _operationAddress,
        address _technicalAddress
    ) {
        rewardToken = _rewardToken;
        router = _router;
        usdt = _usdt;
        pair = _pair;
        foundationAddress = _foundationAddress;
        operationAddress = _operationAddress;
        technicalAddress = _technicalAddress;
        IERC20(usdt).approve(router, type(uint256).max);
        IERC20(rewardToken).approve(router, type(uint256).max);
        IERC20(pair).approve(router, type(uint256).max);
        buyPath = [usdt, rewardToken];
        period = 1 days;
        initRemoveRadio = 0.003e12;
    }

    modifier checkStartTime() {
        require(
            block.timestamp >= startTime && startTime > 0,
            "Epoch: not started yet"
        );

        _;
    }

    modifier checkEpoch() {
        require(callable(), "Epoch: not allowed");

        _;

        lastExecutedAt += period;
        currentEpoch++;
    }

    function startEpoch() external onlyOwner {
        require(startTime == 0, "Epoch: it is started");
        startTime = block.timestamp;
        lastExecutedAt = block.timestamp;
    }

    function setPool(
        address _staticPool,
        address _leaguePool,
        address _dynamicFarm
    ) external onlyOwner {
        staticPool = _staticPool;
        leaguePool = _leaguePool;
        dynamicFarm = _dynamicFarm;
    }

    function shareOutBonus() external checkStartTime checkEpoch {
        uint256 removeRadio = initRemoveRadio + getLastEpoch() * 0.0002e12;
        if (removeRadio > 0.01e12) {
            removeRadio = 0.01e12;
        }
        uint256 _epoch = currentEpoch;
        uint256 totalLiquidity = (IERC20(pair).balanceOf(address(this)) *
            removeRadio) / 1e12;
        ISwapRouter(router).removeLiquidity(
            rewardToken,
            usdt,
            totalLiquidity,
            0,
            0,
            address(this),
            block.timestamp
        );
        ISwapRouter(router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                IERC20(usdt).balanceOf(address(this)),
                0,
                buyPath,
                address(this),
                block.timestamp
            );
        uint256 rewardTokenBalance = IERC20(rewardToken).balanceOf(
            address(this)
        );
        IERC20(rewardToken).safeTransfer(
            foundationAddress,
            (0.03e12 * rewardTokenBalance) / 1e12
        );
        IERC20(rewardToken).safeTransfer(
            operationAddress,
            (0.02e12 * rewardTokenBalance) / 1e12
        );
        IERC20(rewardToken).safeTransfer(
            technicalAddress,
            (0.02e12 * rewardTokenBalance) / 1e12
        );
        // 静态
        if (IStaticPool(staticPool).totalPower() > 0) {
            IERC20(rewardToken).safeTransfer(
                IStaticPool(staticPool).vault(),
                (0.5e12 * rewardTokenBalance) / 1e12
            );
            IStaticPool(staticPool).distribute();
        }

        // 联盟
        if (IStaticPool(leaguePool).totalPower() > 0) {
            IERC20(rewardToken).safeTransfer(
                leaguePool,
                (0.06e12 * rewardTokenBalance) / 1e12
            );
            IStaticPool(leaguePool).distribute();
        }
        if (_epoch > 0) {
            (uint256 shareTotalPower, ) = IDynamicFarm(dynamicFarm)
                .shareRewardOfEpoch(_epoch);
            (uint256 lNodeTotalPower, ) = IDynamicFarm(dynamicFarm)
                .lNodeRewardOfEpoch(_epoch);
            (uint256 hNodeTotalPower, ) = IDynamicFarm(dynamicFarm)
                .hNodeRewardOfEpoch(_epoch);
            // 布道
            if (shareTotalPower > 0) {
                IERC20(rewardToken).safeTransfer(
                    dynamicFarm,
                    (0.25e12 * rewardTokenBalance) / 1e12
                );
                IDynamicFarm(dynamicFarm).distribute(RewardType.share, _epoch);
            }

            // 低节点
            if (lNodeTotalPower > 0) {
                IERC20(rewardToken).safeTransfer(
                    dynamicFarm,
                    (0.04e12 * rewardTokenBalance) / 1e12
                );
                IDynamicFarm(dynamicFarm).distribute(RewardType.lNode, _epoch);
            }
            // 高节点
            if (hNodeTotalPower > 0) {
                IERC20(rewardToken).safeTransfer(
                    dynamicFarm,
                    (0.08e12 * rewardTokenBalance) / 1e12
                );
                IDynamicFarm(dynamicFarm).distribute(RewardType.hNode, _epoch);
            }
        }

        emit ShareOutBonus(
            _epoch,
            totalLiquidity,
            rewardTokenBalance,
            block.timestamp
        );
    }

    function callable() public view returns (bool) {
        return (block.timestamp - lastExecutedAt) / period >= 1;
    }

    function getLastEpoch() public view returns (uint256) {
        return (lastExecutedAt - startTime) / period;
    }

    function getNextEpoch() public view returns (uint256) {
        return currentEpoch + 1;
    }

    function getCurrentEpoch() public view returns (uint256) {
        return currentEpoch;
    }
}
