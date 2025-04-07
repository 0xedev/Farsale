// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol"; // Added for pair address
import {IPresale} from "./interfaces/IPresale.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LiquidityLocker} from "./LiquidityLocker.sol";


contract Presale is IPresale, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for ERC20; // Ensure SafeERC20 works with ERC20
    using Address for address payable;

    uint256 public constant BASIS_POINTS = 10_000;
    bool public paused;
    bool public whitelistEnabled;
    uint256 public claimDeadline;
    uint256 public ownerBalance;

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
        address currency; // ERC20 or address(0) for ETH
    }

    struct Pool {
        ERC20 token;
        IUniswapV2Router02 uniswapV2Router02;
        address factory; // Added for pair address calculation
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

    error ContractPaused();
    error ETHNotAccepted();
    error StablecoinNotAccepted();
    error NotActive();
    error ClaimPeriodExpired();
    error NoTokensToClaim();
    error InsufficientTokenBalance();
    error NoFundsToRefund();
    error InsufficientContractBalance();
    error InvalidContributorAddress();
    error HardCapExceeded();
    error BelowMinimumContribution();
    error ExceedsMaximumContribution();
    error NotWhitelisted();
    error InvalidAddress();
    error CannotRescuePresaleTokens();
    error AlreadyPaused();
    error NotPaused();
    error ZeroTokensForContribution();
    error InvalidInitialization();

    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event Withdrawn(address indexed owner, uint256 amount);
    event WhitelistToggled(bool enabled);
    event WhitelistUpdated(address indexed contributor, bool added);

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier onlyRefundable() {
        if (!(pool.state == 3 || (block.timestamp > pool.options.end && pool.weiRaised < pool.options.softCap))) 
            revert NotRefundable();
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
        if (_weth == address(0) || _token == address(0) || _uniswapV2Router02 == address(0) || _liquidityLocker == address(0)) 
            revert InvalidInitialization();
        _prevalidatePool(_options);

        liquidityLocker = LiquidityLocker(_liquidityLocker);
        pool = Pool({
            token: ERC20(_token),
            uniswapV2Router02: IUniswapV2Router02(_uniswapV2Router02),
            factory: IUniswapV2Router02(_uniswapV2Router02).factory(), // Initialize factory
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
        if (pool.options.currency != address(0)) revert ETHNotAccepted();
        if (pool.state != 2) revert NotActive();
        uint256 tokenAmount = userTokens(msg.sender) + ((msg.value * pool.options.presaleRate * 10**pool.token.decimals()) / 10**18);
        if (tokenAmount == 0) revert ZeroTokensForContribution();
        _purchase(msg.sender, msg.value);
    }

    function contributeStablecoin(uint256 _amount) external whenNotPaused {
        if (pool.options.currency == address(0)) revert StablecoinNotAccepted();
        if (pool.state != 2) revert NotActive();
        IERC20(pool.options.currency).safeTransferFrom(msg.sender, address(this), _amount);
        _purchase(msg.sender, _amount);
    }

    function deposit() external onlyOwner whenNotPaused returns (uint256) {
        if (pool.state != 1) revert InvalidState(pool.state);
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
        if (pool.state != 2) revert InvalidState(pool.state);
        if (pool.weiRaised < pool.options.softCap) revert SoftCapNotReached();

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
        if (pool.state > 2) revert InvalidState(pool.state);
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
        if (pool.state != 4) revert InvalidState(pool.state);
        if (block.timestamp > claimDeadline) revert ClaimPeriodExpired();
        uint256 amount = userTokens(msg.sender);
        if (amount == 0) revert NoTokensToClaim();
        if (pool.tokenBalance < amount) revert InsufficientTokenBalance();

        pool.tokenBalance -= amount;
        contributions[msg.sender] = 0;
        pool.token.safeTransfer(msg.sender, amount);
        emit TokenClaim(msg.sender, amount, block.timestamp);
        return amount;
    }

    function refund() external nonReentrant onlyRefundable returns (uint256) {
        uint256 amount = contributions[msg.sender];
        if (amount == 0) revert NoFundsToRefund();
        if (pool.options.currency == address(0) ? address(this).balance < amount : IERC20(pool.options.currency).balanceOf(address(this)) < amount)
            revert InsufficientContractBalance();

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
        if (amount == 0) revert NoFundsToRefund();
        ownerBalance = 0;
        if (pool.options.currency == address(0)) {
            payable(msg.sender).sendValue(amount);
        } else {
            IERC20(pool.options.currency).safeTransfer(msg.sender, amount);
        }
        emit Withdrawn(msg.sender, amount);
    }

    function rescueTokens(address _token, address _to, uint256 _amount) external onlyOwner {
        if (_to == address(0)) revert InvalidAddress();
        if (_token == address(pool.token) && pool.state < 3) revert CannotRescuePresaleTokens();
        IERC20(_token).safeTransfer(_to, _amount);
        emit TokensRescued(_token, _to, _amount);
    }

    function toggleWhitelist(bool _enabled) external onlyOwner {
        whitelistEnabled = _enabled;
        emit WhitelistToggled(_enabled);
    }

    function updateWhitelist(address[] calldata _addresses, bool _add) external onlyOwner {
        for (uint256 i = 0; i < _addresses.length; i++) {
            if (_addresses[i] == address(0)) revert InvalidAddress();
            whitelist[_addresses[i]] = _add;
            emit WhitelistUpdated(_addresses[i], _add);
        }
    }

    function pause() external onlyOwner {
        if (paused) revert AlreadyPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        if (!paused) revert NotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    function calculateTotalTokensNeeded() external view returns (uint256) {
        uint256 currencyDecimals = pool.options.currency == address(0) ? 18 : ERC20(pool.options.currency).decimals(); // Fixed to ERC20
        uint256 tokenDecimals = pool.token.decimals();
        uint256 presaleTokens = (pool.options.hardCap * pool.options.presaleRate * 10**tokenDecimals) /
            10**currencyDecimals;
        uint256 liquidityTokens = ((pool.options.hardCap * pool.options.liquidityBps / BASIS_POINTS) *
            pool.options.listingRate *
            10**tokenDecimals) / 10**currencyDecimals;
        return presaleTokens + liquidityTokens;
    }

    function _purchase(address _beneficiary, uint256 _amount) private {
        _prevalidatePurchase(_beneficiary, _amount);
        if (whitelistEnabled && !whitelist[_beneficiary]) revert NotWhitelisted();
        pool.weiRaised += _amount;
        contributions[_beneficiary] += _amount;
        emit Purchase(_beneficiary, _amount);
    }

    function _liquify(uint256 _currencyAmount, uint256 _tokenAmount) private {
        uint256 minToken = _tokenAmount * (BASIS_POINTS - pool.options.slippageBps) / BASIS_POINTS;
        uint256 minCurrency = _currencyAmount * (BASIS_POINTS - pool.options.slippageBps) / BASIS_POINTS;

        pool.token.approve(address(pool.uniswapV2Router02), _tokenAmount); // Fixed with SafeERC20 for ERC20
        address pair = IUniswapV2Factory(pool.factory).getPair(
            address(pool.token),
            pool.options.currency == address(0) ? pool.weth : pool.options.currency
        );
        if (pair == address(0)) {
            pair = IUniswapV2Factory(pool.factory).createPair(
                address(pool.token),
                pool.options.currency == address(0) ? pool.weth : pool.options.currency
            );
        }

        if (pool.options.currency == address(0)) {
            (uint256 amountToken, uint256 amountETH, uint256 liquidity) = pool.uniswapV2Router02.addLiquidityETH{value: _currencyAmount}(
                address(pool.token),
                _tokenAmount,
                minToken,
                minCurrency,
                address(this),
                block.timestamp + 600
            );
        } else {
            ERC20(pool.options.currency).approve(address(pool.uniswapV2Router02), _currencyAmount); // Fixed with ERC20
            (uint256 amountA, uint256 amountB, uint256 liquidity) = pool.uniswapV2Router02.addLiquidity(
                address(pool.token),
                pool.options.currency,
                _tokenAmount,
                _currencyAmount,
                minToken,
                minCurrency,
                address(this),
                block.timestamp + 600
            );
            ERC20(pool.options.currency).approve(address(pool.uniswapV2Router02), 0); // Reset approval
        }
        pool.token.approve(address(pool.uniswapV2Router02), 0); // Reset approval

        IERC20 lpToken = IERC20(pair);
        uint256 lpAmount = lpToken.balanceOf(address(this));
        if (lpAmount == 0) revert LiquificationFailed();
        uint256 unlockTime = block.timestamp + pool.options.lockupDuration;

        lpToken.approve(address(liquidityLocker), lpAmount);
        liquidityLocker.lock(pair, lpAmount, unlockTime, owner());
    }

    function _prevalidatePurchase(address _beneficiary, uint256 _amount) private view {
        PresaleOptions memory opts = pool.options;
        if (pool.state != 2) revert InvalidState(pool.state);
        if (_beneficiary == address(0)) revert InvalidContributorAddress();
        if (block.timestamp < opts.start || block.timestamp > opts.end) revert NotInPurchasePeriod();
        if (pool.weiRaised + _amount > opts.hardCap) revert HardCapExceeded();
        if (_amount < opts.min) revert BelowMinimumContribution();
        if (contributions[_beneficiary] + _amount > opts.max) revert ExceedsMaximumContribution();
    }

    function _prevalidatePool(PresaleOptions memory _options) private view {
        if (_options.tokenDeposit == 0) revert InvalidInitialization();
        if (_options.hardCap == 0 || _options.softCap < _options.hardCap / 4) revert InvalidInitialization();
        if (_options.max == 0 || _options.min == 0 || _options.min > _options.max) revert InvalidInitialization();
        if (_options.liquidityBps < 5100 || _options.liquidityBps > BASIS_POINTS) revert InvalidInitialization();
        if (_options.slippageBps > 500) revert InvalidInitialization();
        if (_options.presaleRate == 0 || _options.listingRate == 0 || _options.listingRate >= _options.presaleRate) 
            revert InvalidInitialization();
        if (_options.start < block.timestamp || _options.end <= _options.start) revert InvalidInitialization();
        if (_options.lockupDuration == 0) revert InvalidInitialization();
    }

    function userTokens(address _contributor) public view returns (uint256) {
        if (pool.weiRaised == 0) return 0;
        uint256 currencyDecimals = pool.options.currency == address(0) ? 18 : ERC20(pool.options.currency).decimals(); // Fixed to ERC20
        uint256 tokenDecimals = pool.token.decimals();
        return (contributions[_contributor] * pool.options.presaleRate * 10**tokenDecimals) / 10**currencyDecimals;
    }

    function _tokensForLiquidity() private view returns (uint256) {
        uint256 currencyDecimals = pool.options.currency == address(0) ? 18 : ERC20(pool.options.currency).decimals(); // Fixed to ERC20
        uint256 tokenDecimals = pool.token.decimals();
        return ((pool.options.hardCap * pool.options.liquidityBps / BASIS_POINTS) * pool.options.listingRate * 10**tokenDecimals) / 10**currencyDecimals;
    }

    function _tokensForPresale() private view returns (uint256) {
        uint256 currencyDecimals = pool.options.currency == address(0) ? 18 : ERC20(pool.options.currency).decimals(); // Fixed to ERC20
        uint256 tokenDecimals = pool.token.decimals();
        return (pool.options.hardCap * pool.options.presaleRate * 10**tokenDecimals) / 10**currencyDecimals;
    }

    function _weiForLiquidity() private view returns (uint256) {
        return (pool.weiRaised * pool.options.liquidityBps) / BASIS_POINTS;
    }
}