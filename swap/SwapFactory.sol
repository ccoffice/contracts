// SPDX-License-Identifier: MIT

pragma solidity 0.8.10;

import {ISwapFactory} from "./swap-interfaces/ISwapFactory.sol";
import {ISwapRouter} from "./swap-interfaces/ISwapRouter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SwapPair, ISwapPair} from "./SwapPair.sol";
import {SafeMath} from "./swap-libs/SafeMath.sol";

contract SwapFactory is Ownable, ISwapFactory {
    bytes32 public constant INIT_CODE_PAIR_HASH =
        keccak256(abi.encodePacked(type(SwapPair).creationCode));

    address public feeTo;
    address public feeToSetter;
    address public router;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
    }

    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "router can not be address 0");
        require(
            ISwapRouter(_router).factory() == address(this),
            "invalid router"
        );
        router = _router;
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair) {
        require(tokenA != tokenB, "Pancake: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "Pancake: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "Pancake: PAIR_EXISTS"); // single check is sufficient
        bytes memory bytecode = type(SwapPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        ISwapPair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, "Pancake: FORBIDDEN");
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, "Pancake: FORBIDDEN");
        feeToSetter = _feeToSetter;
    }
}
