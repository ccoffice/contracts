// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PermissionControl} from "../permission/PermissionControl.sol";

contract Family is Initializable, PermissionControl {
    /// @notice 根地址
    address public rootAddress;

    /// @notice 地址总数
    uint256 public totalAddresses;

    /// @notice 上级检索
    mapping(address => address) public parentOf;

    /// @notice 深度记录
    mapping(address => uint256) public depthOf;

    // 下级检索-直推
    mapping(address => address[]) internal _childrenMapping;

    function initialize(address _rootAddress) public initializer {
        __PermissionControl_init();
        require(_rootAddress != address(0), "invalid _rootAddress");
        rootAddress = _rootAddress;
        //初始树形
        depthOf[_rootAddress] = 1;
        parentOf[_rootAddress] = address(0);
        _childrenMapping[address(0)].push(rootAddress);
    }

    /**
     * @notice 直系家族(父辈)
     *
     * @param owner 查询的用户地址
     * @param depth 查询深度 $number
     *
     * @return 地址列表(从下至上)
     *
     */
    function getForefathers(
        address owner,
        uint256 depth
    ) external view returns (address[] memory) {
        address[] memory forefathers = new address[](depth);
        for (
            (address parent, uint256 i) = (parentOf[owner], 0);
            i < depth && parent != address(0);
            (i++, parent = parentOf[parent])
        ) {
            forefathers[i] = parent;
        }

        return forefathers;
    }

    /// @notice 获取直推列表
    function childrenOf(
        address owner
    ) external view returns (address[] memory) {
        return _childrenMapping[owner];
    }

    /// @notice 下级添加上级
    function makeRelation(address parent) external {
        require(_childrenMapping[parent].length < 65, "parent can not do it");
        _makeRelationFrom(parent, msg.sender);
    }

    function _makeRelationFrom(address parent, address child) internal {
        require(depthOf[parent] > 0, "invalid parent");
        require(depthOf[child] == 0, "invalid child");

        // 累加数量
        totalAddresses++;

        // 上级检索
        parentOf[child] = parent;

        // 深度记录
        depthOf[child] = depthOf[parent] + 1;

        // 下级检索
        _childrenMapping[parent].push(child);
    }
}
