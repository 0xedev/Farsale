// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract WETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

event Deposited(address indexed user, uint256 amount);
event Withdrawn(address indexed user, uint256 amount);
    // Function to deposit Ether and mint WETH
    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit Deposited(msg.sender, msg.value);
    }

    // Function to burn WETH and withdraw Ether
    function withdraw(uint amount) public {
    require(balanceOf(msg.sender) >= amount, "Insufficient balance");
    _burn(msg.sender, amount);
    payable(msg.sender).transfer(amount);
    emit Withdrawn(msg.sender, amount);
}

    // Fallback function to handle direct Ether transfers
    receive() external payable {
        deposit();
    }
}
