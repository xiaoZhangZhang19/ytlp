// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title YTAssetVault
 * @notice 基于价格的资产金库，用户根据USDC和YT代币价格进行兑换
 * @dev UUPS可升级合约，YT是份额代币
 */
contract YTAssetVault is 
    Initializable, 
    ERC20Upgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable 
{
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    error Forbidden();
    error HardCapExceeded();
    error InvalidAmount();
    error InvalidHardCap();
    error InvalidPrice();
    error InsufficientUSDC();
    error InsufficientYTA();
    error StillInLockPeriod();
    error RequestNotFound();
    error RequestAlreadyProcessed();
    error InvalidBatchSize();
    error InvalidPriceFeed();
    error InvalidChainlinkPrice();
    error StalePrice();
    
    /// @notice 工厂合约地址
    address public factory;
    
    /// @notice 管理员地址
    address public manager;
    
    /// @notice YT代币硬顶（最大可铸造的YT数量）
    uint256 public hardCap;
    
    /// @notice 已提取用于管理的USDC数量
    uint256 public managedAssets;
    
    /// @notice USDC代币地址
    address public usdcAddress;
    
    /// @notice USDC代币精度（从代币合约读取）
    uint8 public usdcDecimals;
    
    /// @notice YT价格（精度1e30）
    uint256 public ytPrice;
    
    /// @notice 价格精度
    uint256 public constant PRICE_PRECISION = 1e30;
    
    /// @notice Chainlink价格精度
    uint256 public constant CHAINLINK_PRICE_PRECISION = 1e8;
    
    /// @notice 价格过期阈值（秒）
    uint256 public priceStalenesThreshold;
    
    /// @notice 下一个赎回开放时间（所有用户统一）
    uint256 public nextRedemptionTime;

    /// @notice USDC价格Feed
    AggregatorV3Interface internal usdcPriceFeed;
    
    /// @notice 提现请求结构体
    struct WithdrawRequest {
        address user;           // 用户地址
        uint256 ytAmount;       // YT数量
        uint256 usdcAmount;     // 应得USDC数量
        uint256 requestTime;    // 请求时间
        uint256 queueIndex;     // 队列位置
        bool processed;         // 是否已处理
    }
    
    /// @notice 请求ID => 请求详情
    mapping(uint256 => WithdrawRequest) public withdrawRequests;
    
    /// @notice 用户地址 => 用户的所有请求ID列表
    mapping(address => uint256[]) private userRequestIds;
    
    /// @notice 请求ID计数器
    uint256 public requestIdCounter;
    
    /// @notice 已处理到的队列位置
    uint256 public processedUpToIndex;
    
    /// @notice 当前待处理的请求数量（实时维护，避免循环计算）
    uint256 public pendingRequestsCount;
    
    event HardCapSet(uint256 newHardCap);
    event ManagerSet(address indexed newManager);
    event AssetsWithdrawn(address indexed to, uint256 amount);
    event AssetsDeposited(uint256 amount);
    event PriceUpdated(uint256 ytPrice, uint256 timestamp);
    event Buy(address indexed user, uint256 usdcAmount, uint256 ytAmount);
    event Sell(address indexed user, uint256 ytAmount, uint256 usdcAmount);
    event NextRedemptionTimeSet(uint256 newRedemptionTime);
    event WithdrawRequestCreated(uint256 indexed requestId, address indexed user, uint256 ytAmount, uint256 usdcAmount, uint256 queueIndex);
    event WithdrawRequestProcessed(uint256 indexed requestId, address indexed user, uint256 usdcAmount);
    event BatchProcessed(uint256 startIndex, uint256 endIndex, uint256 processedCount, uint256 totalUsdcDistributed);
    
    modifier onlyFactory() {
        if (msg.sender != factory) revert Forbidden();
        _;
    }
    
    modifier onlyManager() {
        if (msg.sender != manager) revert Forbidden();
        _;
    }
    
    /**
     * @notice 初始化金库
     * @param _name YT代币名称
     * @param _symbol YT代币符号
     * @param _manager 管理员地址
     * @param _hardCap 硬顶限制
     * @param _usdc USDC代币地址
     * @param _redemptionTime 赎回时间（Unix时间戳）
     * @param _initialYtPrice 初始YT价格（精度1e30，传0则使用默认值1.0）
     */
    function initialize(
        string memory _name,
        string memory _symbol,
        address _manager,
        uint256 _hardCap,
        address _usdc,
        uint256 _redemptionTime,
        uint256 _initialYtPrice,
        address _usdcPriceFeed
    ) external initializer {
        __ERC20_init(_name, _symbol);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        if (_usdcPriceFeed == address(0)) revert InvalidPriceFeed();
        usdcPriceFeed = AggregatorV3Interface(_usdcPriceFeed);
        usdcAddress = _usdc;
        
        // 获取USDC的decimals
        usdcDecimals = IERC20Metadata(usdcAddress).decimals();
        
        factory = msg.sender;
        manager = _manager;
        hardCap = _hardCap;
        
        // 使用传入的初始价格，如果为0则使用默认值1.0
        ytPrice = _initialYtPrice == 0 ? PRICE_PRECISION : _initialYtPrice;
        
        // 设置赎回时间
        nextRedemptionTime = _redemptionTime;
        
        // 设置默认价格过期阈值（1小时）
        priceStalenesThreshold = 3600;
    }
    
    /**
     * @notice 授权升级（仅factory可调用）
     * @param newImplementation 新实现合约地址
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyFactory {}
    
    /**
     * @notice 设置硬顶
     * @param _hardCap 新的硬顶值
     */
    function setHardCap(uint256 _hardCap) external onlyFactory {
        if (_hardCap < totalSupply()) revert InvalidHardCap();
        hardCap = _hardCap;
        emit HardCapSet(_hardCap);
    }
    
    /**
     * @notice 设置管理员
     * @param _manager 新管理员地址
     */
    function setManager(address _manager) external onlyFactory {
        manager = _manager;
        emit ManagerSet(_manager);
    }
    
    /**
     * @notice 设置价格过期阈值
     * @param _threshold 阈值（秒），例如：3600 = 1小时，86400 = 24小时
     */
    function setPriceStalenessThreshold(uint256 _threshold) external onlyFactory {
        require(_threshold > 0 && _threshold <= 7 days, "Invalid threshold");
        priceStalenesThreshold = _threshold;
    }
    
    /**
     * @notice 设置下一个赎回开放时间（仅factory可调用）
     * @param _nextRedemptionTime 下一个赎回时间（Unix时间戳）
     * @dev 所有用户统一在此时间后才能赎回，类似基金的赎回日
     */
    function setNextRedemptionTime(uint256 _nextRedemptionTime) external onlyFactory {
        nextRedemptionTime = _nextRedemptionTime;
        emit NextRedemptionTimeSet(_nextRedemptionTime);
    }
    
    /**
     * @notice 更新价格（仅manager可调用）
     * @param _ytPrice YT价格（精度1e30）
     */
    function updatePrices(uint256 _ytPrice) external onlyFactory {
        if (_ytPrice == 0) revert InvalidPrice();
        
        ytPrice = _ytPrice;
        
        emit PriceUpdated(_ytPrice, block.timestamp);
    }
    
    /**
     * @notice 用USDC购买YT
     * @param _usdcAmount 支付的USDC数量
     * @return ytAmount 实际获得的YT数量
     * @dev 首次购买时，YT价格 = USDC价格（1:1兑换）
     */
    function depositYT(uint256 _usdcAmount) 
        external
        nonReentrant 
        whenNotPaused
        returns (uint256 ytAmount) 
    {
        if (_usdcAmount == 0) revert InvalidAmount();

        uint256 usdcPrice = _getUSDCPrice();
        uint256 conversionFactor = _getPriceConversionFactor();
        
        // 计算可以购买的YT数量
        // ytAmount = _usdcAmount * usdcPrice * conversionFactor / ytPrice
        ytAmount = (_usdcAmount * usdcPrice * conversionFactor) / ytPrice;
        
        // 检查硬顶
        if (hardCap > 0 && totalSupply() + ytAmount > hardCap) {
            revert HardCapExceeded();
        }
        
        // 转入USDC
        IERC20(usdcAddress).transferFrom(msg.sender, address(this), _usdcAmount);
        
        // 铸造YT
        _mint(msg.sender, ytAmount);
        
        emit Buy(msg.sender, _usdcAmount, ytAmount);
    }
    
    /**
     * @notice 提交YT提现请求（需要等到统一赎回时间）
     * @param _ytAmount 卖出的YT数量
     * @return requestId 提现请求ID
     * @dev 用户提交请求后，YT会立即销毁
     */
    function withdrawYT(uint256 _ytAmount) 
        external 
        nonReentrant 
        whenNotPaused
        returns (uint256 requestId) 
    {
        if (_ytAmount == 0) revert InvalidAmount();
        if (balanceOf(msg.sender) < _ytAmount) revert InsufficientYTA();
        
        // 检查是否到达统一赎回时间
        if (block.timestamp < nextRedemptionTime) {
            revert StillInLockPeriod();
        }

        uint256 usdcPrice = _getUSDCPrice();
        uint256 conversionFactor = _getPriceConversionFactor();
        
        // 计算可以换取的USDC数量
        // usdcAmount = _ytAmount * ytPrice / (usdcPrice * conversionFactor)
        uint256 usdcAmount = (_ytAmount * ytPrice) / (usdcPrice * conversionFactor);
        
        // 销毁YT代币
        _burn(msg.sender, _ytAmount);
        
        // 创建提现请求
        requestId = requestIdCounter;
        withdrawRequests[requestId] = WithdrawRequest({
            user: msg.sender,
            ytAmount: _ytAmount,
            usdcAmount: usdcAmount,
            requestTime: block.timestamp,
            queueIndex: requestId,
            processed: false
        });
        
        // 记录用户的请求ID
        userRequestIds[msg.sender].push(requestId);
        
        // 递增计数器
        requestIdCounter++;
        
        // 增加待处理请求计数
        pendingRequestsCount++;
        
        emit WithdrawRequestCreated(requestId, msg.sender, _ytAmount, usdcAmount, requestId);
    }
    
    /**
     * @notice 批量处理提现请求（仅manager或factory可调用）
     * @param _batchSize 本批次最多处理的请求数量
     * @return processedCount 实际处理的请求数量
     * @return totalDistributed 实际分发的USDC总量
     * @dev 按照请求ID顺序（即时间先后）依次处理，遇到资金不足时停止
     */
    function processBatchWithdrawals(uint256 _batchSize) 
        external 
        nonReentrant 
        whenNotPaused
        onlyManager
        returns (uint256 processedCount, uint256 totalDistributed) 
    {
        if (_batchSize == 0) revert InvalidBatchSize();
        
        uint256 availableUSDC = IERC20(usdcAddress).balanceOf(address(this));
        uint256 startIndex = processedUpToIndex;
        
        for (uint256 i = processedUpToIndex; i < requestIdCounter && processedCount < _batchSize; i++) {
            WithdrawRequest storage request = withdrawRequests[i];
            
            // 跳过已处理的请求
            if (request.processed) {
                continue;
            }
            
            // 检查是否有足够的USDC
            if (availableUSDC >= request.usdcAmount) {
                // 转账USDC给用户
                IERC20(usdcAddress).safeTransfer(request.user, request.usdcAmount);
                
                // 标记为已处理
                request.processed = true;
                
                // 更新统计
                availableUSDC -= request.usdcAmount;
                totalDistributed += request.usdcAmount;
                processedCount++;
                
                // 减少待处理请求计数
                pendingRequestsCount--;
                
                emit WithdrawRequestProcessed(i, request.user, request.usdcAmount);
            } else {
                // USDC不足，停止处理
                break;
            }
        }
        
        // 更新处理进度（跳到下一个未处理的位置）
        if (processedCount > 0) {
            // 找到下一个未处理的位置
            for (uint256 i = processedUpToIndex; i < requestIdCounter; i++) {
                if (!withdrawRequests[i].processed) {
                    processedUpToIndex = i;
                    break;
                }
                // 如果所有请求都已处理完
                if (i == requestIdCounter - 1) {
                    processedUpToIndex = requestIdCounter;
                }
            }
        }
        
        emit BatchProcessed(startIndex, processedUpToIndex, processedCount, totalDistributed);
    }

    /**
     * @notice 提取USDC用于外部投资
     * @param _to 接收地址
     * @param _amount 提取数量
     */
    function withdrawForManagement(address _to, uint256 _amount) external onlyManager nonReentrant whenNotPaused {
        if (_amount == 0) revert InvalidAmount();
        
        uint256 availableAssets = IERC20(usdcAddress).balanceOf(address(this));
        if (_amount > availableAssets) revert InvalidAmount();
        
        managedAssets += _amount;
        IERC20(usdcAddress).safeTransfer(_to, _amount);
        
        emit AssetsWithdrawn(_to, _amount);
    }
    
    /**
     * @notice 将管理的资产归还到金库（可以归还更多，产生收益）
     * @param _amount 归还数量
     */
    function depositManagedAssets(uint256 _amount) external onlyManager nonReentrant whenNotPaused {
        if (_amount == 0) revert InvalidAmount();
        
        // 先更新状态（遵循CEI模式）
        if (_amount >= managedAssets) {
            // 归还金额 >= 已管理资产，managedAssets归零，多余部分是收益
            managedAssets = 0;
        } else {
            // 归还金额 < 已管理资产，部分归还
            managedAssets -= _amount;
        }
        
        // 从manager转入USDC到合约
        IERC20(usdcAddress).transferFrom(msg.sender, address(this), _amount);
        
        emit AssetsDeposited(_amount);
    }

    /**
     * @notice 暂停合约（仅factory可调用）
     * @dev 暂停后，所有资金流动操作将被禁止
     */
    function pause() external onlyFactory {
        _pause();
    }
    
    /**
     * @notice 恢复合约（仅factory可调用）
     */
    function unpause() external onlyFactory {
        _unpause();
    }

    /**
     * @notice 获取并验证USDC价格（从Chainlink）
     * @return 返回uint256格式的USDC价格，精度为1e8
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
        
        return uint256(price);
    }
    
    /**
     * @notice 计算价格转换因子
     * @dev 转换因子 = 10^(ytDecimals) * PRICE_PRECISION / (10^(usdcDecimals) * CHAINLINK_PRICE_PRECISION)
     * @return 价格转换因子
     */
    function _getPriceConversionFactor() internal view returns (uint256) {
        uint8 ytDecimals = decimals();
        
        // 分子: 10^ytDecimals * PRICE_PRECISION (1e30)
        uint256 numerator = (10 ** ytDecimals) * PRICE_PRECISION;
        
        // 分母: 10^usdcDecimals * CHAINLINK_PRICE_PRECISION (1e8)
        uint256 denominator = (10 ** usdcDecimals) * CHAINLINK_PRICE_PRECISION;
        
        // 返回转换因子
        return numerator / denominator;
    }
    
    /**
     * @notice 查询用户的所有提现请求ID
     * @param _user 用户地址
     * @return 用户的所有请求ID数组
     */
    function getUserRequestIds(address _user) external view returns (uint256[] memory) {
        return userRequestIds[_user];
    }
    
    /**
     * @notice 查询指定请求的详情
     * @param _requestId 请求ID
     * @return request 请求详情
     */
    function getRequestDetails(uint256 _requestId) external view returns (WithdrawRequest memory request) {
        if (_requestId >= requestIdCounter) revert RequestNotFound();
        return withdrawRequests[_requestId];
    }
    
    /**
     * @notice 获取待处理的请求数量
     * @return 待处理的请求总数
     * @dev 使用实时维护的计数器，O(1)复杂度，避免gas爆炸
     */
    function getPendingRequestsCount() external view returns (uint256) {
        return pendingRequestsCount;
    }
    
    /**
     * @notice 获取用户待处理的请求
     * @param _user 用户地址
     * @return pendingRequests 用户待处理的请求详情数组
     */
    function getUserPendingRequests(address _user) external view returns (WithdrawRequest[] memory pendingRequests) {
        uint256[] memory requestIds = userRequestIds[_user];
        
        // 先计算有多少待处理的请求
        uint256 pendingCount = 0;
        for (uint256 i = 0; i < requestIds.length; i++) {
            if (!withdrawRequests[requestIds[i]].processed) {
                pendingCount++;
            }
        }
        
        // 构造返回数组
        pendingRequests = new WithdrawRequest[](pendingCount);
        uint256 index = 0;
        for (uint256 i = 0; i < requestIds.length; i++) {
            uint256 requestId = requestIds[i];
            if (!withdrawRequests[requestId].processed) {
                pendingRequests[index] = withdrawRequests[requestId];
                index++;
            }
        }
    }
    
    /**
     * @notice 获取队列处理进度
     * @return currentIndex 当前处理到的位置
     * @return totalRequests 总请求数
     * @return pendingRequests 待处理请求数
     * @dev 使用实时维护的计数器，避免循环计算
     */
    function getQueueProgress() external view returns (
        uint256 currentIndex,
        uint256 totalRequests,
        uint256 pendingRequests
    ) {
        currentIndex = processedUpToIndex;
        totalRequests = requestIdCounter;
        pendingRequests = pendingRequestsCount;
    }
    
    /**
     * @notice 查询距离下次赎回开放还需等待多久
     * @return remainingTime 剩余时间（秒），0表示可以赎回
     */
    function getTimeUntilNextRedemption() external view returns (uint256 remainingTime) {
        if (block.timestamp >= nextRedemptionTime) {
            return 0;
        }
        return nextRedemptionTime - block.timestamp;
    }
    
    /**
     * @notice 检查当前是否可以赎回
     * @return 是否可以赎回
     */
    function canRedeemNow() external view returns (bool) {
        return block.timestamp >= nextRedemptionTime;
    }
    
    /**
     * @notice 获取总资产（包含被管理的资产）
     * @return 总资产 = 合约余额 + 被管理的资产
     */
    function totalAssets() public view returns (uint256) {
        return IERC20(usdcAddress).balanceOf(address(this)) + managedAssets;
    }
    
    /**
     * @notice 获取空闲资产（可用于提取的资产）
     * @return 合约中实际持有的USDC数量
     */
    function idleAssets() public view returns (uint256) {
        return IERC20(usdcAddress).balanceOf(address(this));
    }
    
    /**
     * @notice 预览购买：计算支付指定USDC可获得的YT数量
     * @param _usdcAmount 支付的USDC数量
     * @return ytAmount 可获得的YT数量
     */
    function previewBuy(uint256 _usdcAmount) external view returns (uint256 ytAmount) {
        uint256 usdcPrice = _getUSDCPrice();
        uint256 conversionFactor = _getPriceConversionFactor();
        ytAmount = (_usdcAmount * usdcPrice * conversionFactor) / ytPrice;
    }
    
    /**
     * @notice 预览卖出：计算卖出指定YT可获得的USDC数量
     * @param _ytAmount 卖出的YT数量
     * @return usdcAmount 可获得的USDC数量
     */
    function previewSell(uint256 _ytAmount) external view returns (uint256 usdcAmount) {
        uint256 usdcPrice = _getUSDCPrice();
        uint256 conversionFactor = _getPriceConversionFactor();
        usdcAmount = (_ytAmount * ytPrice) / (usdcPrice * conversionFactor);
    }
    
    /**
     * @notice 获取金库信息
     */
    function getVaultInfo() external view returns (
        uint256 _totalAssets,
        uint256 _idleAssets,
        uint256 _managedAssets,
        uint256 _totalSupply,
        uint256 _hardCap,
        uint256 _usdcPrice,
        uint256 _ytPrice,
        uint256 _nextRedemptionTime
    ) {
        _usdcPrice = _getUSDCPrice();
        _totalAssets = totalAssets();
        _idleAssets = idleAssets();
        _managedAssets = managedAssets;
        _totalSupply = totalSupply();
        _hardCap = hardCap;
        _ytPrice = ytPrice;
        _nextRedemptionTime = nextRedemptionTime;
    }
    
    /**
     * @dev 预留存储空间，用于未来升级时添加新的状态变量
     * 50个slot = 50 * 32 bytes = 1600 bytes
     */
    uint256[50] private __gap;
}
