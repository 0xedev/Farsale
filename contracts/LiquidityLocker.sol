// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract LiquidityLocker is Ownable {
    using SafeERC20 for IERC20;

    struct Lock {
        address token;
        uint256 amount;
        uint256 unlockTime;
        address owner;
    }

    Lock[] public locks;

    event LiquidityLocked(address indexed token, uint256 amount, uint256 unlockTime, address indexed owner);
    event LiquidityWithdrawn(address indexed token, uint256 amount, address indexed owner);

    error InvalidTokenAddress();
    error ZeroAmount();
    error InvalidUnlockTime();
    error InvalidOwnerAddress();
    error InvalidLockId();
    error NotLockOwner();
    error TokensStillLocked();
    error NoTokensToWithdraw();

    constructor() Ownable(msg.sender) {}

    function lock(
        address _token,
        uint256 _amount,
        uint256 _unlockTime,
        address _owner
    ) external onlyOwner {
        if (_token == address(0)) revert InvalidTokenAddress();
        if (_amount == 0) revert ZeroAmount();
        if (_unlockTime <= block.timestamp) revert InvalidUnlockTime();
        if (_owner == address(0)) revert InvalidOwnerAddress();

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        locks.push(Lock({
            token: _token,
            amount: _amount,
            unlockTime: _unlockTime,
            owner: _owner
        }));

        emit LiquidityLocked(_token, _amount, _unlockTime, _owner);
    }

    function withdraw(uint256 _lockId) external {
        if (_lockId >= locks.length) revert InvalidLockId();
        Lock storage lockData = locks[_lockId]; // Renamed from 'lock'
        if (msg.sender != lockData.owner) revert NotLockOwner();
        if (block.timestamp < lockData.unlockTime) revert TokensStillLocked();
        if (lockData.amount == 0) revert NoTokensToWithdraw();

        uint256 amount = lockData.amount;
        address token = lockData.token;
        lockData.amount = 0;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit LiquidityWithdrawn(token, amount, msg.sender);
    }

    function getLock(uint256 _lockId) external view returns (address, uint256, uint256, address) {
        if (_lockId >= locks.length) revert InvalidLockId();
        Lock memory lockInfo = locks[_lockId]; // Renamed from 'lock'
        return (lockInfo.token, lockInfo.amount, lockInfo.unlockTime, lockInfo.owner);
    }

    function lockCount() external view returns (uint256) {
        return locks.length;
    }
}