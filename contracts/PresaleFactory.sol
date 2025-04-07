// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Presale} from "./Presale.sol";
import {LiquidityLocker} from "./LiquidityLocker.sol";

contract PresaleFactory is Ownable {
    using SafeERC20 for IERC20;
    using Address for address payable;


    uint256 public creationFee;
    address public feeToken;
    address[] public presales;
    LiquidityLocker public liquidityLocker;

    // Custom errors
    error InsufficientFee();
    error ZeroFee();

    event PresaleCreated(address indexed creator, address indexed presale);

    constructor(uint256 _creationFee, address _feeToken) Ownable(msg.sender) {
        creationFee = _creationFee;
        feeToken = _feeToken;
        liquidityLocker = new LiquidityLocker();
        liquidityLocker.transferOwnership(address(this));
    }

    function createPresale(
        Presale.PresaleOptions memory _options,
        address _token,
        address _weth,
        address _router
    ) external payable {
        if (feeToken == address(0)) {
            if (msg.value < creationFee) revert InsufficientFee();
        } else {
            IERC20(feeToken).safeTransferFrom(msg.sender, address(this), creationFee);
        }

        Presale presale = new Presale(
            _weth,
            _token,
            _router,
            _options,
            msg.sender,
            address(liquidityLocker)
        );
        presales.push(address(presale));
        emit PresaleCreated(msg.sender, address(presale));
    }

    function setCreationFee(uint256 _fee) external onlyOwner {
        if (_fee == 0) revert ZeroFee();
        creationFee = _fee;
    }

    function withdrawFees() external onlyOwner {
        if (feeToken == address(0)) {
            uint256 balance = address(this).balance;
            if (balance > 0) {
                payable(owner()).sendValue(balance);
            }
        } else {
            uint256 balance = IERC20(feeToken).balanceOf(address(this));
            if (balance > 0) {
                IERC20(feeToken).safeTransfer(owner(), balance);
            }
        }
    }

    function getPresaleCount() external view returns (uint256) {
        return presales.length;
    }
}