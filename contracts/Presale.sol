// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IPresale} from "./interfaces/IPresale.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {LiquidityLocker} from "./LiquidityLocker.sol";

/**
 * @title Presale
 * @notice A contract for conducting a token presale with automatic liquidity locking
 * @dev Supports ETH or stablecoin contributions, whitelisting, and refunds on failure
 */
contract Presale is IPresale, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address payable;

    uint256 public constant BASIS_POINTS = 10_000;
    bool public paused;
    bool public whitelistEnabled;
    uint256 public claimDeadline;
    uint256 public ownerBalance;

    /// @notice Liquidity locker contract for automatic locking
    LiquidityLocker public immutable liquidityLocker;

    struct PresaleOptions {
        uint256 tokenDeposit;
        uint256 hardCap;
        uint256 softCap;
        uint256 max;
        uint256 min;
        uint256 start;
        uint256 end;
        uint256 liquidityBps;
        uint256 slippageBps;
        uint256 presaleRate;
        uint256 listingRate;
        uint256 lockupDuration;
        address currency;
    }

    struct Pool {
        IERC20 token;
        IUniswapV2Router02 uniswapV2Router02;
        uint256 tokenBalance;
        uint256 tokensClaimable;
        uint256 tokensLiquidity;
        uint256 weiRaised;
        address weth;
        uint8 state;
        PresaleOptions options;
    }

    mapping(address => uint256) public contributions;
    mapping(address => bool) public whitelist;
    Pool public pool;

    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event Withdrawn(address indexed owner, uint256 amount);
    event WhitelistToggled(bool enabled);
    event WhitelistUpdated(address indexed contributor, bool added);

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    modifier onlyRefundable() {
        require(
            pool.state == 3 || (block.timestamp > pool.options.end && pool.weiRaised < pool.options.softCap),
            "Not refundable"
        );
        _;
    }

    constructor(
        address _weth,
        address _token,
        address _uniswapV2Router02,
        PresaleOptions memory _options,
        address _creator,
        address _liquidityLocker
    ) Ownable(_creator) {
        require(_weth != address(0), "WETH address cannot be zero");
        require(_token != address(0), "Token address cannot be zero");
        require(_uniswapV2Router02 != address(0), "Router address cannot be zero");
        require(_liquidityLocker != address(0), "Locker address cannot be zero");
        _prevalidatePool(_options);

        liquidityLocker = LiquidityLocker(_liquidityLocker);
        pool = Pool({
            token: IERC20(_token),
            uniswapV2Router02: IUniswapV2Router02(_uniswapV2Router02),
            tokenBalance: 0,
            tokensClaimable: 0,
            tokensLiquidity: 0,
            weiRaised: 0,
            weth: _weth,
            state: 1,
            options: _options
        });
    }

    receive() external payable whenNotPaused {
        require(pool.options.currency == address(0), "ETH not accepted");
        require(pool.state == 2, "Presale not active");
        _purchase(msg.sender, msg.value);
    }

    function contributeStablecoin(uint256 _amount) external whenNotPaused {
        require(pool.options.currency != address(0), "Stablecoin not accepted");
        require(pool.state == 2, "Presale not active");
        IERC20(pool.options.currency).safeTransferFrom(msg.sender, address(this), _amount);
        _purchase(msg.sender, _amount);
    }

    function deposit() external onlyOwner whenNotPaused returns (uint256) {
        require(pool.state == 1, "Presale must be initialized");
        uint256 amount = pool.options.tokenDeposit;
        pool.token.safeTransferFrom(msg.sender, address(this), amount);
        pool.state = 2;
        pool.tokenBalance = amount;
        pool.tokensClaimable = _tokensForPresale();
        pool.tokensLiquidity = _tokensForLiquidity();
        emit Deposit(msg.sender, amount, block.timestamp);
        return amount;
    }

    function finalize() external onlyOwner whenNotPaused returns (bool) {
        require(pool.state == 2, "Presale must be active");
        require(pool.weiRaised >= pool.options.softCap, "Soft cap not reached");

        pool.state = 4;
        uint256 liquidityAmount = _weiForLiquidity();
        _liquify(liquidityAmount, pool.tokensLiquidity);
        pool.tokenBalance -= pool.tokensLiquidity;
        ownerBalance = pool.weiRaised - liquidityAmount;
        claimDeadline = block.timestamp + 90 days;

        emit Finalized(msg.sender, pool.weiRaised, block.timestamp);
        return true;
    }

    function cancel() external nonReentrant onlyOwner whenNotPaused returns (bool) {
        require(pool.state <= 2, "Cannot cancel after finalization");
        pool.state = 3;
        if (pool.tokenBalance > 0) {
            uint256 amount = pool.tokenBalance;
            pool.tokenBalance = 0;
            pool.token.safeTransfer(msg.sender, amount);
        }
        emit Cancel(msg.sender, block.timestamp);
        return true;
    }

    function claim() external nonReentrant whenNotPaused returns (uint256) {
        require(pool.state == 4, "Presale must be finalized");
        require(block.timestamp <= claimDeadline, "Claim period expired");
        uint256 amount = userTokens(msg.sender);
        require(amount > 0, "No tokens to claim");
        require(pool.tokenBalance >= amount, "Insufficient token balance");

        pool.tokenBalance -= amount;
        contributions[msg.sender] = 0;
        pool.token.safeTransfer(msg.sender, amount);
        emit TokenClaim(msg.sender, amount, block.timestamp);
        return amount;
    }

    function refund() external nonReentrant onlyRefundable returns (uint256) {
        uint256 amount = contributions[msg.sender];
        require(amount > 0, "No funds to refund");
        require(
            pool.options.currency == address(0)
                ? address(this).balance >= amount
                : IERC20(pool.options.currency).balanceOf(address(this)) >= amount,
            "Insufficient balance"
        );

        contributions[msg.sender] = 0;
        if (pool.options.currency == address(0)) {
            payable(msg.sender).sendValue(amount);
        } else {
            IERC20(pool.options.currency).safeTransfer(msg.sender, amount);
        }
        emit Refund(msg.sender, amount, block.timestamp);
        return amount;
    }

    function withdraw() external onlyOwner {
        uint256 amount = ownerBalance;
        require(amount > 0, "No funds to withdraw");
        ownerBalance = 0;
        if (pool.options.currency == address(0)) {
            payable(msg.sender).sendValue(amount);
        } else {
            IERC20(pool.options.currency).safeTransfer(msg.sender, amount);
        }
        emit Withdrawn(msg.sender, amount);
    }

    function rescueTokens(address _token, address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Cannot rescue to zero address");
        require(_token != address(pool.token) || pool.state >= 3, "Cannot rescue presale tokens before cancellation");
        IERC20(_token).safeTransfer(_to, _amount);
        emit TokensRescued(_token, _to, _amount);
    }

    function toggleWhitelist(bool _enabled) external onlyOwner {
        whitelistEnabled = _enabled;
        emit WhitelistToggled(_enabled);
    }

    function updateWhitelist(address[] calldata _addresses, bool _add) external onlyOwner {
        for (uint256 i = 0; i < _addresses.length; i++) {
            require(_addresses[i] != address(0), "Invalid address");
            whitelist[_addresses[i]] = _add;
            emit WhitelistUpdated(_addresses[i], _add);
        }
    }

    function pause() external onlyOwner {
        require(!paused, "Already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        require(paused, "Not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    function calculateTotalTokensNeeded() external view returns (uint256) {
        uint256 currencyDecimals = pool.options.currency == address(0) ? 18 : IERC20(pool.options.currency).decimals();
        uint256 tokenDecimals = IERC20(pool.token).decimals();
        uint256 presaleTokens = (pool.options.hardCap * pool.options.presaleRate * 10**tokenDecimals) /
            10**currencyDecimals;
        uint256 liquidityTokens = ((pool.options.hardCap * pool.options.liquidityBps / BASIS_POINTS) *
            pool.options.listingRate *
            10**tokenDecimals) / 10**currencyDecimals;
        return presaleTokens + liquidityTokens;
    }

    function _purchase(address _beneficiary, uint256 _amount) private {
        _prevalidatePurchase(_beneficiary, _amount);
        if (whitelistEnabled) require(whitelist[_beneficiary], "Not whitelisted");
        pool.weiRaised += _amount;
        contributions[_beneficiary] += _amount;
        emit Purchase(_beneficiary, _amount);
    }

    function _liquify(uint256 _currencyAmount, uint256 _tokenAmount) private {
        uint256 minToken = _tokenAmount * (BASIS_POINTS - pool.options.slippageBps) / BASIS_POINTS;
        uint256 minCurrency = _currencyAmount * (BASIS_POINTS - pool.options.slippageBps) / BASIS_POINTS;

        pool.token.safeApprove(address(pool.uniswapV2Router02), _tokenAmount);
        address pair;
        if (pool.options.currency == address(0)) {
            (, , pair) = pool.uniswapV2Router02.addLiquidityETH{value: _currencyAmount}(
                address(pool.token),
                _tokenAmount,
                minToken,
                minCurrency,
                address(this),
                block.timestamp + 600
            );
        } else {
            IERC20(pool.options.currency).safeApprove(address(pool.uniswapV2Router02), _currencyAmount);
            (, , pair) = pool.uniswapV2Router02.addLiquidity(
                address(pool.token),
                pool.options.currency,
                _tokenAmount,
                _currencyAmount,
                minToken,
                minCurrency,
                address(this),
                block.timestamp + 600
            );
            IERC20(pool.options.currency).safeApprove(address(pool.uniswapV2Router02), 0);
        }
        pool.token.safeApprove(address(pool.uniswapV2Router02), 0);
        require(pair != address(0), "LiquificationFailed");

        // Lock LP tokens with LiquidityLocker
        IERC20 lpToken = IERC20(pair);
        uint256 lpAmount = lpToken.balanceOf(address(this));
        require(lpAmount > 0, "No LP tokens to lock");
        uint256 unlockTime = block.timestamp + pool.options.lockupDuration;

        lpToken.safeApprove(address(liquidityLocker), lpAmount);
        liquidityLocker.lock(pair, lpAmount, unlockTime, owner());
    }

    function _prevalidatePurchase(address _beneficiary, uint256 _amount) private view {
        PresaleOptions memory opts = pool.options;
        require(pool.state == 2, "Presale must be active");
        require(_beneficiary != address(0), "Invalid contributor address");
        require(block.timestamp >= opts.start && block.timestamp <= opts.end, "Not in purchase period");
        require(pool.weiRaised + _amount <= opts.hardCap, "Hard cap exceeded");
        require(_amount >= opts.min, "Below minimum contribution");
        require(contributions[_beneficiary] + _amount <= opts.max, "Exceeds maximum contribution");
    }

    function _prevalidatePool(PresaleOptions memory _options) private view {
        require(_options.tokenDeposit > 0, "Token deposit must be positive");
        require(_options.hardCap > 0 && _options.softCap >= _options.hardCap / 4, "Soft cap must be >= 25% of hard cap");
        require(_options.max > 0 && _options.min > 0 && _options.min <= _options.max, "Invalid contribution limits");
        require(_options.liquidityBps >= 5100 && _options.liquidityBps <= BASIS_POINTS, "Liquidity must be 51-100%");
        require(_options.slippageBps <= 500, "Slippage must be <= 5%");
        require(_options.presaleRate > 0 && _options.listingRate > 0 && _options.listingRate < _options.presaleRate, "Invalid rates");
        require(_options.start >= block.timestamp && _options.end > _options.start, "Invalid timestamps");
        require(_options.lockupDuration > 0, "Lockup duration must be positive");
    }

    function userTokens(address _contributor) public view returns (uint256) {
        if (pool.weiRaised == 0) return 0;
        uint256 currencyDecimals = pool.options.currency == address(0) ? 18 : IERC20(pool.options.currency).decimals();
        uint256 tokenDecimals = IERC20(pool.token).decimals();
        return (contributions[_contributor] * pool.options.presaleRate * 10**tokenDecimals) / 10**currencyDecimals;
    }

   function _tokensForLiquidity() private view returns (uint256) {
    uint256 currencyDecimals = pool.options.currency == address(0) ? 18 : IERC20(pool.options.currency).decimals();
    uint256 tokenDecimals = IERC20(pool.token).decimals();
    return ((pool.options.hardCap * pool.options.liquidityBps / BASIS_POINTS) * pool.options.listingRate * 10**tokenDecimals) / 10**currencyDecimals;
}

    function _tokensForPresale() private view returns (uint256) {
        uint256 currencyDecimals = pool.options.currency == address(0) ? 18 : IERC20(pool.options.currency).decimals();
        uint256 tokenDecimals = IERC20(pool.token).decimals();
        return (pool.options.hardCap * pool.options.presaleRate * 10**tokenDecimals) / 10**currencyDecimals;
    }

    function _weiForLiquidity() private view returns (uint256) {
        return (pool.weiRaised * pool.options.liquidityBps) / BASIS_POINTS;
    }
}