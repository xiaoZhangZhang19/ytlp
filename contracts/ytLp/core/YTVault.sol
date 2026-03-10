// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../interfaces/IUSDY.sol";
import "../../interfaces/IYTPriceFeed.sol";

/**
 * @title YTVault
 * @notice 核心资金池，处理YT代币的存储、交换和动态手续费
 * @dev UUPS可升级合约
 */
contract YTVault is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    error Forbidden();
    error OnlyPoolManager();
    error NotSwapper();
    error EmergencyMode();
    error InvalidAddress();
    error TokenNotWhitelisted();
    error InvalidFee();
    error NotInEmergency();
    error SlippageTooHigh();
    error SwapDisabled();
    error InvalidAmount();
    error InsufficientPool();
    error SameToken();
    error AmountExceedsLimit();
    error MaxUSDYExceeded();
    error InsufficientUSDYAmount();
    error InvalidPoolAmount();
    error DailyLimitExceeded();
    
    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant USDY_DECIMALS = 18;
    
    address public gov;
    address public ytPoolManager;
    address public priceFeed;
    address public usdy;
    
    mapping(address => bool) public isSwapper; // 授权的swap调用者
    
    bool public isSwapEnabled;
    bool public emergencyMode;
    
    // 代币白名单
    address[] public allWhitelistedTokens;
    mapping(address => bool) public whitelistedTokens;
    mapping(address => bool) public stableTokens;  // 稳定币标记
    mapping(address => uint256) public tokenDecimals;
    mapping(address => uint256) public tokenWeights;
    uint256 public totalTokenWeights;
    
    // 池子资产
    mapping(address => uint256) public poolAmounts;
    mapping(address => uint256) public tokenBalances; // 跟踪实际代币余额
    
    // USDY债务追踪（用于动态手续费）
    mapping(address => uint256) public usdyAmounts;
    mapping(address => uint256) public maxUsdyAmounts;
    
    // 手续费配置
    uint256 public swapFeeBasisPoints;
    uint256 public stableSwapFeeBasisPoints;
    uint256 public taxBasisPoints;
    uint256 public stableTaxBasisPoints;
    bool public hasDynamicFees;
    
    // 全局滑点保护
    uint256 public maxSwapSlippageBps; // 10% 最大滑点
    
    // 单笔交易限额
    mapping(address => uint256) public maxSwapAmount;
    
    event Swap(
        address indexed account,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeBasisPoints
    );
    event AddLiquidity(
        address indexed account,
        address indexed token,
        uint256 amount,
        uint256 usdyAmount
    );
    event RemoveLiquidity(
        address indexed account,
        address indexed token,
        uint256 usdyAmount,
        uint256 amountOut
    );
    event EmergencyModeSet(bool enabled);
    event SwapEnabledSet(bool enabled);
    event GovChanged(address indexed oldGov, address indexed newGov);
    event PoolManagerChanged(address indexed oldManager, address indexed newManager);
    
    modifier onlyGov() {
        if (msg.sender != gov) revert Forbidden();
        _;
    }
    
    modifier onlyPoolManager() {
        if (msg.sender != ytPoolManager) revert OnlyPoolManager();
        _;
    }
    
    modifier onlySwapper() {
        if (!isSwapper[msg.sender] && msg.sender != ytPoolManager) revert NotSwapper();
        _;
    }
    
    modifier notInEmergency() {
        if (emergencyMode) revert EmergencyMode();
        _;
    }
    
    /**
     * @notice 初始化合约
     * @param _usdy USDY代币地址
     * @param _priceFeed 价格预言机地址
     */
    function initialize(address _usdy, address _priceFeed) external initializer {
        if (_usdy == address(0) || _priceFeed == address(0)) revert InvalidAddress();
        
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        gov = msg.sender;
        usdy = _usdy;
        priceFeed = _priceFeed;
        
        // 初始化默认值
        isSwapEnabled = true;
        emergencyMode = false;
        swapFeeBasisPoints = 30;
        stableSwapFeeBasisPoints = 4;
        taxBasisPoints = 50;
        stableTaxBasisPoints = 20;
        hasDynamicFees = true;
        maxSwapSlippageBps = 1000; // 10% 最大滑点
        
        // 将 USDY 标记为稳定币，这样 USDY ↔ 稳定币的互换可以享受低费率
        stableTokens[_usdy] = true;
    }
    
    /**
     * @notice 授权升级（仅gov可调用）
     * @param newImplementation 新实现合约地址
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyGov {}
    
    function setGov(address _gov) external onlyGov {
        if (_gov == address(0)) revert InvalidAddress();
        address oldGov = gov;
        gov = _gov;
        emit GovChanged(oldGov, _gov);
    }
    
    function setPoolManager(address _manager) external onlyGov {
        if (_manager == address(0)) revert InvalidAddress();
        address oldManager = ytPoolManager;
        ytPoolManager = _manager;
        emit PoolManagerChanged(oldManager, _manager);
    }
    
    function setSwapper(address _swapper, bool _isActive) external onlyGov {
        if (_swapper == address(0)) revert InvalidAddress();
        isSwapper[_swapper] = _isActive;
    }
    
    function setWhitelistedToken(
        address _token,
        uint256 _decimals,
        uint256 _weight,
        uint256 _maxUsdyAmount,
        bool _isStable
    ) external onlyGov {
        if (_token == address(0)) revert InvalidAddress();
        
        if (!whitelistedTokens[_token]) {
            allWhitelistedTokens.push(_token);
            whitelistedTokens[_token] = true;
        }
        
        totalTokenWeights = totalTokenWeights - tokenWeights[_token] + _weight;
        tokenDecimals[_token] = _decimals;
        tokenWeights[_token] = _weight;
        maxUsdyAmounts[_token] = _maxUsdyAmount;
        stableTokens[_token] = _isStable;
    }

    function setSwapFees(
        uint256 _swapFee,
        uint256 _stableSwapFee,
        uint256 _taxBasisPoints,
        uint256 _stableTaxBasisPoints
    ) external onlyGov {
        if (_swapFee > 100 || _stableSwapFee > 50) revert InvalidFee();
        swapFeeBasisPoints = _swapFee;
        stableSwapFeeBasisPoints = _stableSwapFee;
        taxBasisPoints = _taxBasisPoints;
        stableTaxBasisPoints = _stableTaxBasisPoints;
    }
    
    function setDynamicFees(bool _hasDynamicFees) external onlyGov {
        hasDynamicFees = _hasDynamicFees;
    }
    
    function setEmergencyMode(bool _emergencyMode) external onlyGov {
        emergencyMode = _emergencyMode;
        emit EmergencyModeSet(_emergencyMode);
    }
    
    function setSwapEnabled(bool _isSwapEnabled) external onlyGov {
        isSwapEnabled = _isSwapEnabled;
        emit SwapEnabledSet(_isSwapEnabled);
    }
    
    function setMaxSwapSlippageBps(uint256 _slippageBps) external onlyGov {
        if (_slippageBps > 2000) revert SlippageTooHigh(); // 最大20%
        maxSwapSlippageBps = _slippageBps;
    }
    
    function setMaxSwapAmount(address _token, uint256 _amount) external onlyGov {
        maxSwapAmount[_token] = _amount;
    }
    
    /**
     * @notice 用YT代币购买USDY（添加流动性时调用）
     * @param _token YT代币地址
     * @param _receiver USDY接收地址
     * @return usdyAmountAfterFees 实际获得的USDY数量
     */
    function buyUSDY(address _token, address _receiver) 
        external 
        onlyPoolManager 
        nonReentrant 
        notInEmergency
        returns (uint256) 
    {
        if (!whitelistedTokens[_token]) revert TokenNotWhitelisted();
        if (!isSwapEnabled) revert SwapDisabled();
        
        uint256 tokenAmount = _transferIn(_token);
        if (tokenAmount == 0) revert InvalidAmount();
        
        uint256 price = _getPrice(_token, false);
        uint256 usdyAmount = tokenAmount * price / PRICE_PRECISION;
        usdyAmount = _adjustForDecimals(usdyAmount, _token, usdy);
        if (usdyAmount == 0) revert InvalidAmount();
        
        uint256 feeBasisPoints = _getSwapFeeBasisPoints(_token, usdy, usdyAmount);
        uint256 feeAmount = tokenAmount * feeBasisPoints / BASIS_POINTS_DIVISOR;
        uint256 amountAfterFees = tokenAmount - feeAmount;
        
        uint256 usdyAmountAfterFees = amountAfterFees * price / PRICE_PRECISION;
        usdyAmountAfterFees = _adjustForDecimals(usdyAmountAfterFees, _token, usdy);
        
        // 手续费直接留在池子中：全部代币加入poolAmount，但只铸造扣费后的USDY
        _increasePoolAmount(_token, tokenAmount);
        _increaseUsdyAmount(_token, usdyAmountAfterFees);
        
        IUSDY(usdy).mint(_receiver, usdyAmountAfterFees);
        
        emit AddLiquidity(_receiver, _token, tokenAmount, usdyAmountAfterFees);
        
        return usdyAmountAfterFees;
    }
    
    /**
     * @notice 用USDY卖出换取YT代币（移除流动性时调用）
     * @param _token YT代币地址
     * @param _receiver YT代币接收地址
     * @return amountOutAfterFees 实际获得的YT代币数量
     */
    function sellUSDY(address _token, address _receiver) 
        external 
        onlyPoolManager 
        nonReentrant 
        notInEmergency
        returns (uint256) 
    {
        if (!whitelistedTokens[_token]) revert TokenNotWhitelisted();
        if (!isSwapEnabled) revert SwapDisabled();
        
        uint256 usdyAmount = _transferIn(usdy);
        if (usdyAmount == 0) revert InvalidAmount();
        
        uint256 price = _getPrice(_token, true);
        
        // 计算赎回金额（扣费前）
        uint256 redemptionAmount = usdyAmount * PRICE_PRECISION / price;
        redemptionAmount = _adjustForDecimals(redemptionAmount, usdy, _token);
        if (redemptionAmount == 0) revert InvalidAmount();
        
        // 计算手续费和实际转出金额
        uint256 feeBasisPoints = _getSwapFeeBasisPoints(usdy, _token, redemptionAmount);
        uint256 amountOut = redemptionAmount * (BASIS_POINTS_DIVISOR - feeBasisPoints) / BASIS_POINTS_DIVISOR;
        if (amountOut == 0) revert InvalidAmount();
        if (poolAmounts[_token] < amountOut) revert InsufficientPool();
        
        // 计算实际转出的代币对应的USDY价值（用于减少usdyAmount记账）
        uint256 usdyAmountOut = amountOut * price / PRICE_PRECISION;
        usdyAmountOut = _adjustForDecimals(usdyAmountOut, _token, usdy);
        
        // 手续费留在池子：只减少实际转出的部分
        _decreasePoolAmount(_token, amountOut);
        _decreaseUsdyAmount(_token, usdyAmountOut);
        
        // 销毁USDY
        IUSDY(usdy).burn(address(this), usdyAmount);
        
        // 转出代币
        IERC20(_token).safeTransfer(_receiver, amountOut);
        _updateTokenBalance(_token);
        
        emit RemoveLiquidity(_receiver, _token, usdyAmount, amountOut);
        
        return amountOut;
    }
    
    /**
     * @notice YT代币互换
     * @param _tokenIn 输入代币地址
     * @param _tokenOut 输出代币地址
     * @param _receiver 接收地址
     * @return amountOutAfterFees 实际获得的输出代币数量
     */
    function swap(
        address _tokenIn,
        address _tokenOut,
        address _receiver
    ) external onlySwapper nonReentrant notInEmergency returns (uint256) {
        if (!isSwapEnabled) revert SwapDisabled();
        if (!whitelistedTokens[_tokenIn]) revert TokenNotWhitelisted();
        if (!whitelistedTokens[_tokenOut]) revert TokenNotWhitelisted();
        if (_tokenIn == _tokenOut) revert SameToken();
        
        uint256 amountIn = _transferIn(_tokenIn);
        if (amountIn == 0) revert InvalidAmount();
        
        // 检查单笔交易限额
        if (maxSwapAmount[_tokenIn] > 0) {
            if (amountIn > maxSwapAmount[_tokenIn]) revert AmountExceedsLimit();
        }
        
        uint256 priceIn = _getPrice(_tokenIn, false);
        uint256 priceOut = _getPrice(_tokenOut, true);
        
        uint256 usdyAmount = amountIn * priceIn / PRICE_PRECISION;
        usdyAmount = _adjustForDecimals(usdyAmount, _tokenIn, usdy);
        
        uint256 amountOut = usdyAmount * PRICE_PRECISION / priceOut;
        amountOut = _adjustForDecimals(amountOut, usdy, _tokenOut);
        
        uint256 feeBasisPoints = _getSwapFeeBasisPoints(_tokenIn, _tokenOut, usdyAmount);
        uint256 amountOutAfterFees = amountOut * (BASIS_POINTS_DIVISOR - feeBasisPoints) / BASIS_POINTS_DIVISOR;
        
        if (amountOutAfterFees == 0) revert InvalidAmount();
        if (poolAmounts[_tokenOut] < amountOutAfterFees) revert InsufficientPool();
        
        // 全局滑点保护（10%）
        _validateSwapSlippage(amountIn, amountOutAfterFees, priceIn, priceOut);
        
        _increasePoolAmount(_tokenIn, amountIn);
        _decreasePoolAmount(_tokenOut, amountOutAfterFees);
        
        _increaseUsdyAmount(_tokenIn, usdyAmount);
        _decreaseUsdyAmount(_tokenOut, usdyAmount);
        
        IERC20(_tokenOut).safeTransfer(_receiver, amountOutAfterFees);
        _updateTokenBalance(_tokenOut);
        
        emit Swap(msg.sender, _tokenIn, _tokenOut, amountIn, amountOutAfterFees, feeBasisPoints);
        
        return amountOutAfterFees;
    }

    function clearWhitelistedToken(address _token) external onlyGov {
        if (!whitelistedTokens[_token]) revert TokenNotWhitelisted();
        totalTokenWeights = totalTokenWeights - tokenWeights[_token];
        delete whitelistedTokens[_token];
        delete stableTokens[_token];
        delete tokenDecimals[_token];
        delete tokenWeights[_token];
        delete maxUsdyAmounts[_token];
    }

    function withdrawToken(address _token, address _receiver, uint256 _amount) external onlyGov {
        if (!emergencyMode) revert NotInEmergency();
        IERC20(_token).safeTransfer(_receiver, _amount);
        _updateTokenBalance(_token);
    }
    
    /**
     * @notice 获取代币价格（带价差）
     * @param _token 代币地址
     * @param _maximise true=最大价格, false=最小价格
     * @return 价格（30位精度）
     */
    function getPrice(address _token, bool _maximise) external view returns (uint256) {
        return _getPrice(_token, _maximise);
    }
    
    /**
     * @notice 获取最大价格
     */
    function getMaxPrice(address _token) external view returns (uint256) {
        return _getPrice(_token, true);
    }
    
    /**
     * @notice 获取最小价格
     */
    function getMinPrice(address _token) external view returns (uint256) {
        return _getPrice(_token, false);
    }
    
    function getAllPoolTokens() external view returns (address[] memory) {
        return allWhitelistedTokens;
    }
    
    /**
     * @notice 获取池子总价值
     * @param _maximise true=使用最大价格(对协议有利), false=使用最小价格(对用户有利)
     * @return 池子总价值（USDY计价）
     */
    function getPoolValue(bool _maximise) external view returns (uint256) {
        uint256 totalValue = 0;
        for (uint256 i = 0; i < allWhitelistedTokens.length; i++) {
            address token = allWhitelistedTokens[i];
            if (!whitelistedTokens[token]) continue;
            
            uint256 amount = poolAmounts[token];
            uint256 price = _getPrice(token, _maximise);
            uint256 value = amount * price / PRICE_PRECISION;
            value = _adjustForDecimals(value, token, usdy);
            totalValue += value;
        }
        return totalValue;
    }
    
    function getTargetUsdyAmount(address _token) public view returns (uint256) {
        uint256 supply = IERC20(usdy).totalSupply();
        if (supply == 0) { return 0; }
        uint256 weight = tokenWeights[_token];
        return weight * supply / totalTokenWeights;
    }
    
    function _increaseUsdyAmount(address _token, uint256 _amount) private {
        usdyAmounts[_token] = usdyAmounts[_token] + _amount;
        uint256 maxUsdyAmount = maxUsdyAmounts[_token];
        if (maxUsdyAmount != 0) {
            if (usdyAmounts[_token] > maxUsdyAmount) revert MaxUSDYExceeded();
        }
    }
    
    function _decreaseUsdyAmount(address _token, uint256 _amount) private {
        uint256 value = usdyAmounts[_token];
        if (value < _amount) revert InsufficientUSDYAmount();
        usdyAmounts[_token] = value - _amount;
    }
    
    /**
     * @notice 获取swap手续费率（公开方法，供前端调用）
     * @param _tokenIn 输入代币
     * @param _tokenOut 输出代币
     * @param _usdyAmount USDY数量
     * @return 手续费率（basis points）
     */
    function getSwapFeeBasisPoints(
        address _tokenIn,
        address _tokenOut,
        uint256 _usdyAmount
    ) public view returns (uint256) {
        return _getSwapFeeBasisPoints(_tokenIn, _tokenOut, _usdyAmount);
    }
    
    /**
     * @notice 获取赎回手续费率（sellUSDY时使用）
     * @param _token 代币地址
     * @param _usdyAmount USDY数量
     * @return 手续费率（basis points）
     */
    function getRedemptionFeeBasisPoints(
        address _token,
        uint256 _usdyAmount
    ) public view returns (uint256) {
        return _getSwapFeeBasisPoints(usdy, _token, _usdyAmount);
    }

    /**
     * @notice 预估swap输出数量
     * @param _tokenIn 输入代币地址
     * @param _tokenOut 输出代币地址
     * @param _amountIn 输入数量
     * @return amountOut 扣费前输出量
     * @return amountOutAfterFees 扣费后实际输出量
     * @return feeBasisPoints 动态手续费率
     */
    function getSwapAmountOut(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external view returns (
        uint256 amountOut,
        uint256 amountOutAfterFees,
        uint256 feeBasisPoints
    ) {
        if (_amountIn == 0) revert InvalidAmount();
        if (!whitelistedTokens[_tokenIn]) revert TokenNotWhitelisted();
        if (!whitelistedTokens[_tokenOut]) revert TokenNotWhitelisted();
        if (_tokenIn == _tokenOut) revert SameToken();

        uint256 priceIn  = _getPrice(_tokenIn, false);
        uint256 priceOut = _getPrice(_tokenOut, true);

        uint256 usdyAmount = _amountIn * priceIn / PRICE_PRECISION;
        usdyAmount = _adjustForDecimals(usdyAmount, _tokenIn, usdy);

        amountOut = usdyAmount * PRICE_PRECISION / priceOut;
        amountOut = _adjustForDecimals(amountOut, usdy, _tokenOut);

        feeBasisPoints = _getSwapFeeBasisPoints(_tokenIn, _tokenOut, usdyAmount);
        amountOutAfterFees = amountOut * (BASIS_POINTS_DIVISOR - feeBasisPoints) / BASIS_POINTS_DIVISOR;
    }
    
    function _getSwapFeeBasisPoints(
        address _tokenIn,
        address _tokenOut,
        uint256 _usdyAmount
    ) private view returns (uint256) {
        // 稳定币交换是指两个代币都是稳定币（如 USDC <-> USDT）
        bool isStableSwap = stableTokens[_tokenIn] && stableTokens[_tokenOut];
        uint256 baseBps = isStableSwap ? stableSwapFeeBasisPoints : swapFeeBasisPoints;
        uint256 taxBps = isStableSwap ? stableTaxBasisPoints : taxBasisPoints;
        
        if (!hasDynamicFees) {
            return baseBps;
        }
        
        uint256 feesBasisPoints0 = getFeeBasisPoints(_tokenIn, _usdyAmount, baseBps, taxBps, true);
        uint256 feesBasisPoints1 = getFeeBasisPoints(_tokenOut, _usdyAmount, baseBps, taxBps, false);
        
        return feesBasisPoints0 > feesBasisPoints1 ? feesBasisPoints0 : feesBasisPoints1;
    }

    function getFeeBasisPoints(
        address _token,
        uint256 _usdyDelta,
        uint256 _feeBasisPoints,
        uint256 _taxBasisPoints,
        bool _increment
    ) public view returns (uint256) {
        if (!hasDynamicFees) { return _feeBasisPoints; }
        
        uint256 initialAmount = usdyAmounts[_token];
        uint256 nextAmount = initialAmount + _usdyDelta;
        if (!_increment) {
            nextAmount = _usdyDelta > initialAmount ? 0 : initialAmount - _usdyDelta;
        }
        
        uint256 targetAmount = getTargetUsdyAmount(_token);
        if (targetAmount == 0) { return _feeBasisPoints; }
        
        uint256 initialDiff = initialAmount > targetAmount 
            ? initialAmount - targetAmount 
            : targetAmount - initialAmount;
        uint256 nextDiff = nextAmount > targetAmount 
            ? nextAmount - targetAmount 
            : targetAmount - nextAmount;
        
        // 改善平衡 → 降低手续费
        if (nextDiff < initialDiff) {
            uint256 rebateBps = _taxBasisPoints * initialDiff / targetAmount;
            return rebateBps > _feeBasisPoints ? 0 : _feeBasisPoints - rebateBps;
        }
        
        // 恶化平衡 → 提高手续费
        // taxBps = tax * (a + b) / (2 * target)
        uint256 sumDiff = initialDiff + nextDiff;
        if (sumDiff / 2 > targetAmount) {
            sumDiff = targetAmount * 2;
        }
        uint256 taxBps = _taxBasisPoints * sumDiff / (targetAmount * 2);
        return _feeBasisPoints + taxBps;
    }
    
    function _transferIn(address _token) private returns (uint256) {
        uint256 prevBalance = tokenBalances[_token];
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;
        return nextBalance - prevBalance;
    }
    
    function _updateTokenBalance(address _token) private {
        tokenBalances[_token] = IERC20(_token).balanceOf(address(this));
    }
    
    function _increasePoolAmount(address _token, uint256 _amount) private {
        poolAmounts[_token] += _amount;
        _validatePoolAmount(_token);
    }
    
    function _decreasePoolAmount(address _token, uint256 _amount) private {
        if (poolAmounts[_token] < _amount) revert InsufficientPool();
        poolAmounts[_token] -= _amount;
    }
    
    function _validatePoolAmount(address _token) private view {
        if (poolAmounts[_token] > tokenBalances[_token]) revert InvalidPoolAmount();
    }
    
    function _validateSwapSlippage(
        uint256 _amountIn,
        uint256 _amountOut,
        uint256 _priceIn,
        uint256 _priceOut
    ) private view {
        // 计算预期输出（不含手续费）
        uint256 expectedOut = _amountIn * _priceIn / _priceOut;
        
        // 计算实际滑点
        if (expectedOut > _amountOut) {
            uint256 slippage = (expectedOut - _amountOut) * BASIS_POINTS_DIVISOR / expectedOut;
            if (slippage > maxSwapSlippageBps) revert SlippageTooHigh();
        }
    }
    
    function _getPrice(address _token, bool _maximise) private view returns (uint256) {
        return IYTPriceFeed(priceFeed).getPrice(_token, _maximise);
    }
    
    function _adjustForDecimals(
        uint256 _amount,
        address _tokenFrom,
        address _tokenTo
    ) private view returns (uint256) {
        uint256 decimalsFrom = _tokenFrom == usdy ? USDY_DECIMALS : tokenDecimals[_tokenFrom];
        uint256 decimalsTo = _tokenTo == usdy ? USDY_DECIMALS : tokenDecimals[_tokenTo];
        
        if (decimalsFrom == decimalsTo) {
            return _amount;
        }
        
        if (decimalsFrom > decimalsTo) {
            return _amount / (10 ** (decimalsFrom - decimalsTo));
        }
        
        return _amount * (10 ** (decimalsTo - decimalsFrom));
    }
    
    /**
     * @dev 预留存储空间，用于未来升级时添加新的状态变量
     * 50个slot = 50 * 32 bytes = 1600 bytes
     */
    uint256[50] private __gap;
}

