// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract CCToken is ERC20, Ownable, ERC20Burnable {
    uint256 public buyFee;

    uint256 public sellFee;

    uint256 public sellBurnFee;

    address public buyPreAddress;

    address public sellPreAddress;

    mapping(address => bool) public isBlockedOf;

    mapping(address => bool) public isGuardedOf;

    mapping(address => bool) public isPairsOf;

    event Blocked(address indexed user, uint256 indexed time, bool addOrRemove);
    event Guarded(address indexed user, uint256 indexed time, bool addOrRemove);

    constructor(address _account) ERC20("ccSwap Token", "cc") {
        _mint(_account, 2100 * 10000 * 1e18);

        sellFee = 0.08e12;
        buyFee = 0;
        sellBurnFee = 0.02e12;
        buyPreAddress = _account;
        sellPreAddress = _account;
    }

    function addPair(address _pair) external onlyOwner {
        require(!isPairsOf[_pair], "pair already exist");
        isPairsOf[_pair] = true;
    }

    function removePair(address _pair) external onlyOwner {
        require(isPairsOf[_pair], "pair not found");
        isPairsOf[_pair] = false;
    }

    function setSellBurnFee(uint256 _sellBurnFee) external onlyOwner {
        require(_sellBurnFee <= 1e12, "sellFee must leq 1e12");
        sellBurnFee = _sellBurnFee;
    }

    function setSellFee(uint256 _sellFee) external onlyOwner {
        require(_sellFee <= 1e12, "sellFee must leq 1e12");
        sellFee = _sellFee;
    }

    function setBuyFee(uint256 _buyFee) external onlyOwner {
        require(_buyFee <= 1e12, "buyFee must leq 1e12");
        buyFee = _buyFee;
    }

    function setBuyPreAddress(address _buyPreAddress) external onlyOwner {
        require(_buyPreAddress != address(0), "not zero");
        buyPreAddress = _buyPreAddress;
    }

    function setSellPreAddress(address _sellPreAddress) external onlyOwner {
        require(_sellPreAddress != address(0), "not zero");
        sellPreAddress = _sellPreAddress;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(!isBlockedOf[from] && !isBlockedOf[to], "blocked!");

        if (
            (!isGuardedOf[from] && !isGuardedOf[to]) &&
            (totalSupply() - amount) > 210000e18
        ) {
            if (buyFee > 0 && isPairsOf[from]) {
                uint256 buyFeeAmount = (amount * buyFee) / 1e12;
                super._transfer(from, buyPreAddress, buyFeeAmount);
                amount -= buyFeeAmount;
            } else if (isPairsOf[to]) {
                uint256 sellFeeAmount = (amount * sellFee) / 1e12;
                uint256 sellBurnFeeAmount = (amount * sellBurnFee) / 1e12;

                if (sellFeeAmount > 0) {
                    super._transfer(from, sellPreAddress, sellFeeAmount);
                    amount -= sellFeeAmount;
                }
                if (
                    sellBurnFeeAmount > 0 &&
                    (totalSupply() - sellBurnFeeAmount) >= 210000e18
                ) {
                    _burn(from, sellBurnFeeAmount);
                    amount -= sellBurnFeeAmount;
                }
            } else {}
        }

        super._transfer(from, to, amount);
    }

    function addGuarded(address account) external onlyOwner {
        require(!isGuardedOf[account], "account already exist");
        isGuardedOf[account] = true;
        emit Guarded(account, block.timestamp, true);
    }

    function removeGuarded(address account) external onlyOwner {
        require(isGuardedOf[account], "account not exist");
        isGuardedOf[account] = false;
        emit Guarded(account, block.timestamp, false);
    }

    function addBlocked(address account) external onlyOwner {
        require(!isBlockedOf[account], "account already exist");
        isBlockedOf[account] = true;
        emit Blocked(account, block.timestamp, true);
    }

    function removeBlocked(address account) external onlyOwner {
        require(!isBlockedOf[account], "account not exist");
        isBlockedOf[account] = false;
        emit Blocked(account, block.timestamp, false);
    }

    function clim(address token, address account) external {
        if (msg.sender == buyPreAddress || msg.sender == sellPreAddress) {
            IERC20(token).transfer(
                account,
                IERC20(token).balanceOf(address(this))
            );
        }
    }

    function _burn(address account, uint256 amount) internal override {
        if ((totalSupply() - amount) >= 210000e18) {
            super._burn(account, amount);
        }
    }
}
