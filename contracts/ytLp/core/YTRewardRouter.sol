// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../interfaces/IYTPoolManager.sol";
import "../../interfaces/IYTVault.sol";

/**
 * @title YTRewardRouter
 * @notice 用户交互入口
 * @dev UUPS可升级合约
 */
contract YTRewardRouter is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    error Forbidden();
    error AlreadyInitialized();
    error InvalidAddress();
    error InvalidAmount();
    error InsufficientOutput();
    
    address public gov;
    address public usdy;
    address public ytLP;
    address public ytPoolManager;
    address public ytVault;
    
    event Swap(
        address indexed account,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    
    modifier onlyGov() {
        if (msg.sender != gov) revert Forbidden();
        _;
    }
    
    /**
     * @notice 初始化合约
     * @param _usdy USDY代币地址
     * @param _ytLP ytLP代币地址
     * @param _ytPoolManager YTPoolManager地址
     * @param _ytVault YTVault地址
     */
    function initialize(
        address _usdy,
        address _ytLP,
        address _ytPoolManager,
        address _ytVault
    ) external initializer {
        if (_usdy == address(0)) revert InvalidAddress();
        if (_ytLP == address(0)) revert InvalidAddress();
        if (_ytPoolManager == address(0)) revert InvalidAddress();
        if (_ytVault == address(0)) revert InvalidAddress();
        
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        
        gov = msg.sender;

        usdy = _usdy;
        ytLP = _ytLP;
        ytPoolManager = _ytPoolManager;
        ytVault = _ytVault;
    }
    
    /**
     * @notice 授权升级（仅gov可调用）
     * @param newImplementation 新实现合约地址
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyGov {}
    
    /**
     * @notice 暂停合约（仅gov可调用）
     * @dev 暂停后，所有资金流动操作将被禁止
     */
    function pause() external onlyGov {
        _pause();
    }
    
    /**
     * @notice 恢复合约（仅gov可调用）
     */
    function unpause() external onlyGov {
        _unpause();
    }
    
    /**
     * @notice 添加流动性
     * @param _token YT代币或USDC地址
     * @param _amount 代币数量
     * @param _minUsdy 最小USDY数量
     * @param _minYtLP 最小ytLP数量
     * @return ytLPAmount 获得的ytLP数量
     */
    function addLiquidity(
        address _token,
        uint256 _amount,
        uint256 _minUsdy,
        uint256 _minYtLP
    ) external nonReentrant whenNotPaused returns (uint256) {
        if (_amount == 0) revert InvalidAmount();
        
        address account = msg.sender;
        
        IERC20(_token).transferFrom(account, address(this), _amount);
        IERC20(_token).approve(ytPoolManager, _amount);
        
        uint256 ytLPAmount = IYTPoolManager(ytPoolManager).addLiquidityForAccount(
            address(this),
            account,
            _token,
            _amount,
            _minUsdy,
            _minYtLP
        );
        
        return ytLPAmount;
    }
    
    /**
     * @notice 移除流动性
     * @param _tokenOut 输出代币地址
     * @param _ytLPAmount ytLP数量
     * @param _minOut 最小输出数量
     * @param _receiver 接收地址
     * @return amountOut 获得的代币数量
     */
    function removeLiquidity(
        address _tokenOut,
        uint256 _ytLPAmount,
        uint256 _minOut,
        address _receiver
    ) external nonReentrant whenNotPaused returns (uint256) {
        if (_ytLPAmount == 0) revert InvalidAmount();
        
        address account = msg.sender;
        
        uint256 amountOut = IYTPoolManager(ytPoolManager).removeLiquidityForAccount(
            account,
            _tokenOut,
            _ytLPAmount,
            _minOut,
            _receiver
        );
        
        return amountOut;
    }
    
    /**
     * @notice YT代币互换
     * @param _tokenIn 输入代币地址
     * @param _tokenOut 输出代币地址
     * @param _amountIn 输入数量
     * @param _minOut 最小输出数量
     * @param _receiver 接收地址
     * @return amountOut 获得的代币数量
     */
    function swapYT(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _minOut,
        address _receiver
    ) external nonReentrant whenNotPaused returns (uint256) {
        if (_amountIn == 0) revert InvalidAmount();
        
        address account = msg.sender;
        
        IERC20(_tokenIn).transferFrom(account, ytVault, _amountIn);
        
        uint256 amountOut = IYTVault(ytVault).swap(_tokenIn, _tokenOut, _receiver);
        
        if (amountOut < _minOut) revert InsufficientOutput();
        
        emit Swap(account, _tokenIn, _tokenOut, _amountIn, amountOut);
        
        return amountOut;
    }
    
    /**
     * @notice 获取ytLP价格
     * @return ytLP价格（18位精度）
     */
    function getYtLPPrice() external view returns (uint256) {
        return IYTPoolManager(ytPoolManager).getPrice(true);
    }
    
    /**
     * @notice 获取账户价值
     * @param _account 账户地址
     * @return 账户持有的ytLP价值（USDY计价）
     */
    function getAccountValue(address _account) external view returns (uint256) {
        uint256 ytLPBalance = IERC20(ytLP).balanceOf(_account);
        uint256 ytLPPrice = IYTPoolManager(ytPoolManager).getPrice(true);
        return ytLPBalance * ytLPPrice / (10 ** 18);
    }
    
    /**
     * @dev 预留存储空间，用于未来升级时添加新的状态变量
     * 50个slot = 50 * 32 bytes = 1600 bytes
     */
    uint256[50] private __gap;
}

