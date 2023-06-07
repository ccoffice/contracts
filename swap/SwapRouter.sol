// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ISwapRouter} from "./swap-interfaces/ISwapRouter.sol";
import {ISwapPair} from "./swap-interfaces/ISwapPair.sol";
import {ISwapFactory} from "./swap-interfaces/ISwapFactory.sol";
import {IFarmTokenProvider} from "../interfaces/IFarmTokenProvider.sol";
import {IWETH} from "./swap-interfaces/IWETH.sol";
import {SafeMath} from "./swap-libs/SafeMath.sol";
import {TransferHelper} from "./swap-libs/TransferHelper.sol";
import {SwapLibrary} from "./swap-libs/SwapLibrary.sol";

contract SwapRouter is ISwapRouter, Ownable {
    using SafeMath for uint;

    address public override factory;
    address public override WETH;

    /// @notice 是否是农场币
    mapping(address => bool) public isFarmToken;
    /// @notice 农场币卖出模型
    mapping(address => address) private farmTokenProvider;
    /// @notice 农场币卖出最大销毁量
    mapping(address => uint) public farmTokenMinTotal;
    /// @notice 农场币卖出销毁比例
    mapping(address => uint) public farmTokenSellBurnRadio;
    /// @notice 农场币 白名单(允许购买)
    mapping(address => mapping(address => bool)) public isGuardOf;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, "SwapRouter: EXPIRED");
        _;
    }

    constructor(address _factory, address _WETH) {
        factory = _factory;
        WETH = _WETH;
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    function _isBuy(address[] calldata path) internal view returns (bool) {
        return isFarmToken[path[1]];
    }

    function _isFarmSwap(address pair) internal view returns (bool) {
        return farmTokenProvider[pair] != address(0);
    }

    function removeFarmToken(address token) external onlyOwner {
        isFarmToken[token] = false;
    }

    function removeFarmProvider(address pair) external onlyOwner {
        farmTokenProvider[pair] = address(0);
    }

    function setFarmProvider(
        address pair,
        address provider
    ) external onlyOwner {
        farmTokenProvider[pair] = provider;
    }

    function addFarmTokenAndProvider(
        address pair,
        address token,
        address provider
    ) external onlyOwner {
        isFarmToken[token] = true;
        farmTokenProvider[pair] = provider;
    }

    function addFarmPairSellGuard(
        address pair,
        address account
    ) external onlyOwner {
        isGuardOf[pair][account] = true;
    }

    function removeFarmPairSellGuard(
        address pair,
        address account
    ) external onlyOwner {
        isGuardOf[pair][account] = false;
    }

    function setFarmTokenMinTotal(
        address pair,
        uint256 minTotal
    ) external onlyOwner {
        farmTokenMinTotal[pair] = minTotal;
    }

    function setFarmTokenSellBurnRadio(
        address pair,
        uint256 burnRadio
    ) external onlyOwner {
        require(burnRadio <= 1e12, "SwapRouter: INVALID_BURNRADIO");
        farmTokenSellBurnRadio[pair] = burnRadio;
    }

    // **** ADD LIQUIDITY ****
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal returns (uint amountA, uint amountB) {
        // create the pair if it doesn't exist yet
        if (ISwapFactory(factory).getPair(tokenA, tokenB) == address(0)) {
            ISwapFactory(factory).createPair(tokenA, tokenB);
        }
        (uint reserveA, uint reserveB) = SwapLibrary.getReserves(
            factory,
            tokenA,
            tokenB
        );
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint amountBOptimal = SwapLibrary.quote(
                amountADesired,
                reserveA,
                reserveB
            );
            if (amountBOptimal <= amountBDesired) {
                require(
                    amountBOptimal >= amountBMin,
                    "SwapRouter: INSUFFICIENT_B_AMOUNT"
                );
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint amountAOptimal = SwapLibrary.quote(
                    amountBDesired,
                    reserveB,
                    reserveA
                );
                assert(amountAOptimal <= amountADesired);
                require(
                    amountAOptimal >= amountAMin,
                    "SwapRouter: INSUFFICIENT_A_AMOUNT"
                );
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    )
        external
        override
        ensure(deadline)
        returns (uint amountA, uint amountB, uint liquidity)
    {
        (amountA, amountB) = _addLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );
        address pair = SwapLibrary.pairFor(factory, tokenA, tokenB);
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = ISwapPair(pair).mint(to);
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public override ensure(deadline) returns (uint amountA, uint amountB) {
        address pair = SwapLibrary.pairFor(factory, tokenA, tokenB);
        ISwapPair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        (uint amount0, uint amount1) = ISwapPair(pair).burn(to);
        (address token0, ) = SwapLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0
            ? (amount0, amount1)
            : (amount1, amount0);
        require(amountA >= amountAMin, "SwapRouter: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "SwapRouter: INSUFFICIENT_B_AMOUNT");
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(
        uint[] memory amounts,
        address[] memory path,
        address _to
    ) internal {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = SwapLibrary.sortTokens(input, output);
            uint amountOut = amounts[i + 1];
            (uint amount0Out, uint amount1Out) = input == token0
                ? (uint(0), amountOut)
                : (amountOut, uint(0));
            address to = i < path.length - 2
                ? SwapLibrary.pairFor(factory, output, path[i + 2])
                : _to;
            ISwapPair(SwapLibrary.pairFor(factory, input, output)).swap(
                amount0Out,
                amount1Out,
                to,
                new bytes(0)
            );
        }
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    function _swapSupportingFeeOnTransferTokens(
        address[] memory path,
        address _to
    ) internal returns (uint) {
        (address input, address output) = (path[0], path[1]);
        (address token0, ) = SwapLibrary.sortTokens(input, output);
        ISwapPair pair = ISwapPair(SwapLibrary.pairFor(factory, input, output));
        uint amountInput;
        uint amountOutput;
        {
            // scope to avoid stack too deep errors
            (uint reserve0, uint reserve1, ) = pair.getReserves();
            (uint reserveInput, uint reserveOutput) = input == token0
                ? (reserve0, reserve1)
                : (reserve1, reserve0);
            amountInput = IERC20(input).balanceOf(address(pair)).sub(
                reserveInput
            );
            amountOutput = SwapLibrary.getAmountOut(
                amountInput,
                reserveInput,
                reserveOutput
            );
        }
        (uint amount0Out, uint amount1Out) = input == token0
            ? (uint(0), amountOutput)
            : (amountOutput, uint(0));

        pair.swap(amount0Out, amount1Out, _to, new bytes(0));
        return amountInput;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external override ensure(deadline) {
        require(path.length == 2, "SwapRouter: ERROR_SWAP");
        address pair = SwapLibrary.pairFor(factory, path[0], path[1]);
        if (_isFarmSwap(pair) && _isBuy(path)) {
            require(isGuardOf[pair][msg.sender], "SwapRouter: BUY_DISABLED");
        }
        address shouldTo = _isFarmSwap(pair) && !_isBuy(path)
            ? farmTokenProvider[pair]
            : to;
        TransferHelper.safeTransferFrom(path[0], msg.sender, pair, amountIn);
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(shouldTo);

        uint amountInput = _swapSupportingFeeOnTransferTokens(path, shouldTo);

        require(
            IERC20(path[path.length - 1]).balanceOf(shouldTo).sub(
                balanceBefore
            ) >= amountOutMin,
            "SwapRouter: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        if (_isFarmSwap(pair) && !_isBuy(path)) {
            _burnPairToken(path, pair, amountInput);
            IFarmTokenProvider(farmTokenProvider[pair]).afterSell(
                amountInput,
                msg.sender,
                to
            );
        }
    }

    function _burnPairToken(
        address[] calldata path,
        address pair,
        uint amountInput
    ) internal {
        uint totalSupply = IERC20(path[0]).totalSupply();

        uint burnAmount = (amountInput * farmTokenSellBurnRadio[pair]) / 1e12;
        if (
            burnAmount > 0 &&
            totalSupply >= farmTokenMinTotal[pair] + burnAmount
        ) {
            if (totalSupply.sub(burnAmount) < farmTokenMinTotal[pair]) {
                burnAmount = totalSupply.sub(farmTokenMinTotal[pair]);
            }
            if (burnAmount > 0) {
                ISwapPair(pair).burnToken(path[0], burnAmount);
            }
        }
    }

    // **** LIBRARY FUNCTIONS ****
    function quote(
        uint amountA,
        uint reserveA,
        uint reserveB
    ) public pure override returns (uint amountB) {
        return SwapLibrary.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    ) public pure override returns (uint amountOut) {
        return SwapLibrary.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(
        uint amountOut,
        uint reserveIn,
        uint reserveOut
    ) public pure returns (uint amountIn) {
        return SwapLibrary.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts) {
        return SwapLibrary.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(
        uint256 amountOut,
        address[] calldata path
    ) external view returns (uint256[] memory amounts) {
        return SwapLibrary.getAmountsIn(factory, amountOut, path);
    }
}
