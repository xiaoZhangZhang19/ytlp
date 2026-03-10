// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../../interfaces/IYTAssetVault.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title YTPriceFeed
 * @notice 价格读取器，直接从YT合约读取价格变量（带保护机制和价差）
 * @dev UUPS可升级合约
 */
contract YTPriceFeed is Initializable, UUPSUpgradeable {

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    error Forbidden();
    error MaxChangeTooHigh();
    error PriceChangeTooLarge();
    error SpreadTooHigh();
    error InvalidAddress();
    error InvalidChainlinkPrice();
    error StalePrice();
    
    address public gov;
    
    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant MAX_SPREAD_BASIS_POINTS = 200; // 最大2%价差
    
    address public usdcAddress;
    
    // 价格保护参数
    uint256 public maxPriceChangeBps; // 5% 最大价格变动
    uint256 public priceStalenesThreshold; // 价格过期阈值（秒）

    /// @notice USDC价格Feed
    AggregatorV3Interface internal usdcPriceFeed;
    
    // 价差配置（每个代币可以有不同的价差）
    mapping(address => uint256) public spreadBasisPoints;
    
    // 价格历史记录
    mapping(address => uint256) public lastPrice;
    
    // 价格更新权限
    mapping(address => bool) public isKeeper;
    
    event PriceUpdate(address indexed token, uint256 oldPrice, uint256 newPrice, uint256 timestamp);
    event SpreadUpdate(address indexed token, uint256 spreadBps);
    event KeeperSet(address indexed keeper, bool isActive);
    
    modifier onlyGov() {
        if (msg.sender != gov) revert Forbidden();
        _;
    }
    
    modifier onlyKeeper() {
        if (!isKeeper[msg.sender] && msg.sender != gov) revert Forbidden();
        _;
    }
    
    /**
     * @notice 初始化合约
     */
    function initialize(address _usdcAddress, address _usdcPriceFeed) external initializer {
        __UUPSUpgradeable_init();
        if (_usdcAddress == address(0)) revert InvalidAddress();
        usdcAddress = _usdcAddress;
        usdcPriceFeed = AggregatorV3Interface(_usdcPriceFeed);
        gov = msg.sender;
        maxPriceChangeBps = 500; // 5% 最大价格变动
        priceStalenesThreshold = 3600; // 默认1小时
    }

    /**
     * @notice 授权升级（仅gov可调用）
     * @param newImplementation 新实现合约地址
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyGov {}

    /**
     * @notice 设置USDC地址
     * @param _usdcAddress USDC地址
     */
    function setUSDCAddress(address _usdcAddress) external onlyGov {
        if (_usdcAddress == address(0)) revert InvalidAddress();
        usdcAddress = _usdcAddress;
    }

    /**
     * @notice 设置USDC价格Feed
     * @param _usdcPriceFeed USDC价格Feed地址
     */
    function setUSDCPriceFeed(address _usdcPriceFeed) external onlyGov {
        usdcPriceFeed = AggregatorV3Interface(_usdcPriceFeed);
    }
    
    /**
     * @notice 设置keeper权限
     * @param _keeper keeper地址
     * @param _isActive 是否激活
     */
    function setKeeper(address _keeper, bool _isActive) external onlyGov {
        isKeeper[_keeper] = _isActive;
        emit KeeperSet(_keeper, _isActive);
    }
    
    /**
     * @notice 设置最大价格变动百分比
     * @param _maxPriceChangeBps 最大变动（基点）
     */
    function setMaxPriceChangeBps(uint256 _maxPriceChangeBps) external onlyGov {
        if (_maxPriceChangeBps > 2000) revert MaxChangeTooHigh(); // 最大20%
        maxPriceChangeBps = _maxPriceChangeBps;
    }
    
    /**
     * @notice 设置价格过期阈值
     * @param _threshold 阈值（秒），例如：3600 = 1小时，86400 = 24小时
     */
    function setPriceStalenessThreshold(uint256 _threshold) external onlyGov {
        require(_threshold > 0 && _threshold <= 7 days, "Invalid threshold");
        priceStalenesThreshold = _threshold;
    }
    
    /**
     * @notice 设置代币价差
     * @param _token 代币地址
     * @param _spreadBasisPoints 价差（基点）例如：10 = 0.1%, 100 = 1%
     */
    function setSpreadBasisPoints(address _token, uint256 _spreadBasisPoints) external onlyGov {
        if (_spreadBasisPoints > MAX_SPREAD_BASIS_POINTS) revert SpreadTooHigh();
        spreadBasisPoints[_token] = _spreadBasisPoints;
        emit SpreadUpdate(_token, _spreadBasisPoints);
    }
    
    /**
     * @notice 批量设置代币价差
     * @param _tokens 代币地址数组
     * @param _spreadBasisPoints 价差数组
     */
    function setSpreadBasisPointsForMultiple(
        address[] calldata _tokens,
        uint256[] calldata _spreadBasisPoints
    ) external onlyGov {
        require(_tokens.length == _spreadBasisPoints.length, "length mismatch");
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (_spreadBasisPoints[i] > MAX_SPREAD_BASIS_POINTS) revert SpreadTooHigh();
            spreadBasisPoints[_tokens[i]] = _spreadBasisPoints[i];
            emit SpreadUpdate(_tokens[i], _spreadBasisPoints[i]);
        }
    }

    /**
     * @notice 更新并缓存代币价格（keeper调用）
     * @param _token 代币地址
     * @return 更新后的价格
     */
    function updatePrice(address _token) external onlyKeeper returns (uint256) {
        if (_token == usdcAddress) {
            return _getUSDCPrice();
        }
        
        uint256 oldPrice = lastPrice[_token];
        uint256 newPrice = _getRawPrice(_token);
        
        // 价格波动检查
        _validatePriceChange(_token, newPrice);
        
        // 更新缓存价格
        lastPrice[_token] = newPrice;
        
        emit PriceUpdate(_token, oldPrice, newPrice, block.timestamp);
        
        return newPrice;
    }
    
    /**
     * @notice 强制更新价格（紧急情况）
     * @param _token 代币地址
     * @param _price 新价格
     */
    function forceUpdatePrice(address _token, uint256 _price) external onlyGov {
        uint256 oldPrice = lastPrice[_token];
        lastPrice[_token] = _price;
        emit PriceUpdate(_token, oldPrice, _price, block.timestamp);
    }
    
    /**
     * @notice 获取YT代币价格（带波动保护和价差）
     * @param _token 代币地址
     * @param _maximise true=最大价格（上浮价差，对协议有利）, false=最小价格（下压价差，对协议有利）
     * @return 价格（30位精度）
     * 
     * 使用场景：
     * - 添加流动性时AUM计算：_maximise=true（高估AUM，用户获得较少LP）
     * - 移除流动性时AUM计算：_maximise=false（低估AUM，用户获得较少代币）
     * - buyUSDY时（用户卖代币）：_maximise=false（低估用户代币价值）
     * - sellUSDY时（用户买代币）：_maximise=true（高估需支付的代币价值）
     * - swap时tokenIn：_maximise=false（低估输入）
     * - swap时tokenOut：_maximise=true（高估输出）
     */
    function getPrice(address _token, bool _maximise) external view returns (uint256) {
        if (_token == usdcAddress) {
            return _getUSDCPrice();
        }
        
        uint256 basePrice = _getRawPrice(_token);
        
        // 价格波动检查
        _validatePriceChange(_token, basePrice);
        
        // 应用价差
        return _applySpread(_token, basePrice, _maximise);
    }
    
    /**
     * @notice 直接读取YT代币的ytPrice变量
     */
    function _getRawPrice(address _token) private view returns (uint256) {
        return IYTAssetVault(_token).ytPrice();
    }

    /**
     * @notice 获取并验证USDC价格（从Chainlink）
     * @return 返回uint256格式的USDC价格，精度为1e30
     */
    function _getUSDCPrice() internal view returns (uint256) {
        (
            uint80 roundId,
            int256 price,
            /* uint256 startedAt */,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = usdcPriceFeed.latestRoundData();
        
        // 价格有效性检查
        if (price <= 0) revert InvalidChainlinkPrice();
        
        // 新鲜度检查：确保价格数据不过期
        if (updatedAt == 0) revert StalePrice();
        if (answeredInRound < roundId) revert StalePrice();
        if (block.timestamp - updatedAt > priceStalenesThreshold) revert StalePrice();
        
        return uint256(price) * 1e22; // 1e22 = 10^(30-8)
    }

    /**
     * @notice 应用价差
     * @param _token 代币地址
     * @param _basePrice 基础价格
     * @param _maximise true=上浮价格，false=下压价格
     * @return 应用价差后的价格
     */
    function _applySpread(
        address _token,
        uint256 _basePrice,
        bool _maximise
    ) private view returns (uint256) {
        uint256 spread = spreadBasisPoints[_token];
        
        // 如果没有设置价差，直接返回基础价格
        if (spread == 0) {
            return _basePrice;
        }
        
        if (_maximise) {
            // 上浮价格：basePrice * (1 + spread%)
            return _basePrice * (BASIS_POINTS_DIVISOR + spread) / BASIS_POINTS_DIVISOR;
        } else {
            // 下压价格：basePrice * (1 - spread%)
            return _basePrice * (BASIS_POINTS_DIVISOR - spread) / BASIS_POINTS_DIVISOR;
        }
    }
    
    /**
     * @notice 验证价格变动是否在允许范围内
     */
    function _validatePriceChange(address _token, uint256 _newPrice) private view {
        uint256 oldPrice = lastPrice[_token];
        
        // 首次设置价格，跳过检查
        if (oldPrice == 0) {
            return;
        }
        
        // 计算价格变动百分比
        uint256 priceDiff = _newPrice > oldPrice ? _newPrice - oldPrice : oldPrice - _newPrice;
        uint256 maxDiff = oldPrice * maxPriceChangeBps / BASIS_POINTS_DIVISOR;
        
        if (priceDiff > maxDiff) revert PriceChangeTooLarge();
    }
    
    /**
     * @notice 获取价格详细信息
     */
    function getPriceInfo(address _token) external view returns (
        uint256 currentPrice,
        uint256 cachedPrice,
        uint256 maxPrice,
        uint256 minPrice,
        uint256 spread
    ) {
        if (_token == usdcAddress) {
            uint256 usdcPrice = _getUSDCPrice();
            currentPrice = usdcPrice;
            cachedPrice = usdcPrice;
            maxPrice = usdcPrice;
            minPrice = usdcPrice;
            spread = 0;
        } else {
            currentPrice = _getRawPrice(_token);
            cachedPrice = lastPrice[_token];
            spread = spreadBasisPoints[_token];
            maxPrice = _applySpread(_token, currentPrice, true);
            minPrice = _applySpread(_token, currentPrice, false);
        }
    }
    
    /**
     * @notice 获取最大价格（上浮价差）
     */
    function getMaxPrice(address _token) external view returns (uint256) {
        if (_token == usdcAddress) {
            // USDC通常不需要价差，直接返回原价格
            return _getUSDCPrice();
        }
        uint256 basePrice = _getRawPrice(_token);
        _validatePriceChange(_token, basePrice);
        return _applySpread(_token, basePrice, true);
    }
    
    /**
     * @notice 获取最小价格（下压价差）
     */
    function getMinPrice(address _token) external view returns (uint256) {
        if (_token == usdcAddress) {
            // USDC通常不需要价差，直接返回原价格
            return _getUSDCPrice();
        }
        uint256 basePrice = _getRawPrice(_token);
        _validatePriceChange(_token, basePrice);
        return _applySpread(_token, basePrice, false);
    }
    
    /**
     * @dev 预留存储空间，用于未来升级时添加新的状态变量
     * 50个slot = 50 * 32 bytes = 1600 bytes
     */
    uint256[50] private __gap;
}
