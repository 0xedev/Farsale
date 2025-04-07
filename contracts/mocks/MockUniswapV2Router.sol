// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

abstract contract MockUniswapV2Router is IUniswapV2Router02 {
    constructor() {
        // No initialization needed
    }

    // Changed to view since it reads address(this)
    function factory() external pure override returns (address) {
        return address(0x1234567890abcdef1234567890abcdef12345678); // Simplified for testing
    }

    // WETH can remain pure since it’s a constant
    function WETH() external pure override returns (address) {
        return address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // Mock WETH
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256, // amountTokenMin
        uint256, // amountETHMin
        address, // to
        uint256 // deadline
    ) external payable override returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        IERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired);
        return (amountTokenDesired, msg.value, 1e18); // Mock liquidity amount
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256, // amountAMin
        uint256, // amountBMin
        address, // to
        uint256 // deadline
    ) external override returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        IERC20(tokenA).transferFrom(msg.sender, address(this), amountADesired);
        IERC20(tokenB).transferFrom(msg.sender, address(this), amountBDesired);
        return (amountADesired, amountBDesired, 1e18); // Mock liquidity amount
    }

    // Stub implementations for remaining IUniswapV2Router02 functions
    function swapExactTokensForTokens(
        uint256,
        uint256,
        address[] calldata,
        address,
        uint256
    ) external pure override returns (uint256[] memory) {
        revert("Not implemented");
    }

    function swapTokensForExactTokens(
        uint256,
        uint256,
        address[] calldata,
        address,
        uint256
    ) external pure override returns (uint256[] memory) {
        revert("Not implemented");
    }

    function quote(uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function getAmountOut(uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function getAmountIn(uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function getAmountsOut(uint256, address[] calldata) external pure override returns (uint256[] memory) {
        return new uint256[](0);
    }

    function getAmountsIn(uint256, address[] calldata) external pure override returns (uint256[] memory) {
        return new uint256[](0);
    }

    function removeLiquidity(
        address,
        address,
        uint256,
        uint256,
        uint256,
        address,
        uint256
    ) external pure override returns (uint256, uint256) {
        revert("Not implemented");
    }

    function removeLiquidityETH(
        address,
        uint256,
        uint256,
        uint256,
        address,
        uint256
    ) external pure override returns (uint256, uint256) {
        revert("Not implemented");
    }

    function swapExactETHForTokens(
        uint256,
        address[] calldata,
        address,
        uint256
    ) external payable override returns (uint256[] memory) {
        revert("Not implemented");
    }

    function swapTokensForExactETH(
        uint256,
        uint256,
        address[] calldata,
        address,
        uint256
    ) external pure override returns (uint256[] memory) {
        revert("Not implemented");
    }

    function swapExactTokensForETH(
        uint256,
        uint256,
        address[] calldata,
        address,
        uint256
    ) external pure override returns (uint256[] memory) {
        revert("Not implemented");
    }

    function swapETHForExactTokens(
        uint256,
        address[] calldata,
        address,
        uint256
    ) external payable override returns (uint256[] memory) {
        revert("Not implemented");
    }
}