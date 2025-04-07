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
        require(_token != address(0), "Invalid token address");
        require(_amount > 0, "Amount must be positive");
        require(_unlockTime > block.timestamp, "Unlock time must be in future");
        require(_owner != address(0), "Invalid owner address");

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
        require(_lockId < locks.length, "Invalid lock ID");
        Lock storage lock = locks[_lockId];
        require(msg.sender == lock.owner, "Not lock owner");
        require(block.timestamp >= lock.unlockTime, "Tokens still locked");
        require(lock.amount > 0, "No tokens to withdraw");

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
        require(_lockId < locks.length, "Invalid lock ID");
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