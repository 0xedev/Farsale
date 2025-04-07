// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LiquidityLocker
 * @notice Locks LP tokens for a specified duration
 * @dev Used by Presale contract to automatically lock liquidity
 */
contract LiquidityLocker is Ownable {
    using SafeERC20 for IERC20;

    struct Lock {
        address token;        // LP token address
        uint256 amount;       // Amount locked
        uint256 unlockTime;   // Timestamp when tokens can be withdrawn
        address owner;        // Owner who can withdraw after unlock
    }

    /// @notice Array of all locks
    Lock[] public locks;

    /// @notice Emitted when liquidity is locked
    event LiquidityLocked(address indexed token, uint256 amount, uint256 unlockTime, address indexed owner);
    /// @notice Emitted when liquidity is withdrawn
    event LiquidityWithdrawn(address indexed token, uint256 amount, address indexed owner);

    // Custom errors
    error InvalidTokenAddress();
    error ZeroAmount();
    error InvalidUnlockTime();
    error InvalidOwnerAddress();
    error InvalidLockId();
    error NotLockOwner();
    error TokensStillLocked();
    error NoTokensToWithdraw();

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Locks LP tokens until a specified time
     * @param _token LP token address
     * @param _amount Amount to lock
     * @param _unlockTime Timestamp when tokens can be unlocked
     * @param _owner Address that can withdraw after unlock
     */
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

    /**
     * @notice Withdraws unlocked LP tokens
     * @param _lockId Index of the lock to withdraw
     */
    function withdraw(uint256 _lockId) external {
        if (_lockId >= locks.length) revert InvalidLockId();
        Lock storage lock = locks[_lockId];
        if (msg.sender != lock.owner) revert NotLockOwner();
        if (block.timestamp < lock.unlockTime) revert TokensStillLocked();
        if (lock.amount == 0) revert NoTokensToWithdraw();

        uint256 amount = lock.amount;
        address token = lock.token;
        lock.amount = 0; // Prevent reentrancy
        IERC20(token).safeTransfer(msg.sender, amount);

        emit LiquidityWithdrawn(token, amount, msg.sender);
    }

    /**
     * @notice Returns lock details
     * @param _lockId Index of the lock
     * @return token, amount, unlockTime, owner
     */
    function getLock(uint256 _lockId) external view returns (address, uint256, uint256, address) {
        if (_lockId >= locks.length) revert InvalidLockId();
        Lock memory lock = locks[_lockId];
        return (lock.token, lock.amount, lock.unlockTime, lock.owner);
    }

    /**
     * @notice Returns the number of locks
     * @return Number of locks
     */
    function lockCount() external view returns (uint256) {
        return locks.length;
    }
}