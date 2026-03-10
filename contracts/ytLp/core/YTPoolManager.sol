// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../interfaces/IYTVault.sol";
import "../../interfaces/IYTLPToken.sol";
import "../../interfaces/IUSDY.sol";

/**
 * @title YTPoolManager
 * @notice 管理ytLP的铸造和赎回，计算池子AUM
 * @dev UUPS可升级合约
 */
contract YTPoolManager is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    error Forbidden();
    error InvalidAddress();
    error InvalidDuration();
    error PrivateMode();
    error InvalidAmount();
    error InsufficientOutput();
    error CooldownNotPassed();
    
    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant YTLP_PRECISION = 10 ** 18;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant MAX_COOLDOWN_DURATION = 48 hours;
    
    address public gov;
    address public ytVault;
    address public usdy;
    address public ytLP;
    
    uint256 public cooldownDuration;
    mapping(address => uint256) public lastAddedAt;

    mapping(address => bool) public isHandler;
    
    uint256 public aumAddition;
    uint256 public aumDeduction;
    
    event AddLiquidity(
        address indexed account,
        address indexed token,
        uint256 amount,
        uint256 aumInUsdy,
        uint256 ytLPSupply,
        uint256 usdyAmount,
        uint256 mintAmount
    );
    event RemoveLiquidity(
        address indexed account,
        address indexed token,
        uint256 ytLPAmount,
        uint256 aumInUsdy,
        uint256 ytLPSupply,
        uint256 usdyAmount,
        uint256 amountOut
    );
    event CooldownDurationSet(uint256 duration);
    event HandlerSet(address indexed handler, bool isActive);
    event GovChanged(address indexed oldGov, address indexed newGov);
    event AumAdjustmentChanged(uint256 addition, uint256 deduction);
    event CooldownInherited(address indexed from, address indexed to, uint256 cooldownTime);
    
    modifier onlyGov() {
        if (msg.sender != gov) revert Forbidden();
        _;
    }
    
    modifier onlyHandler() {
        if (!isHandler[msg.sender] && msg.sender != gov) revert Forbidden();
        _;
    }
    
    /**
     * @notice 初始化合约
     * @param _ytVault YTVault合约地址
     * @param _usdy USDY代币地址
     * @param _ytLP ytLP代币地址
     * @param _cooldownDuration 冷却时间（秒）
     */
    function initialize(
        address _ytVault,
        address _usdy,
        address _ytLP,
        uint256 _cooldownDuration
    ) external initializer {
        if (_ytVault == address(0) || _usdy == address(0) || _ytLP == address(0)) revert InvalidAddress();
        if (_cooldownDuration > MAX_COOLDOWN_DURATION) revert InvalidDuration();
        
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        gov = msg.sender;
        ytVault = _ytVault;
        usdy = _usdy;
        ytLP = _ytLP;
        cooldownDuration = _cooldownDuration;
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
    
    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
        emit HandlerSet(_handler, _isActive);
    }
    
    function setCooldownDuration(uint256 _duration) external onlyGov {
        if (_duration > MAX_COOLDOWN_DURATION) revert InvalidDuration();
        cooldownDuration = _duration;
        emit CooldownDurationSet(_duration);
    }
    
    function setAumAdjustment(uint256 _addition, uint256 _deduction) external onlyGov {
        aumAddition = _addition;
        aumDeduction = _deduction;
        emit AumAdjustmentChanged(_addition, _deduction);
    }
    
    /**
     * @notice LP 代币转账时的回调函数
     * @param _from 发送方地址
     * @param _to 接收方地址
     * @dev 当 LP 代币转账时，接收方继承发送方的冷却时间，防止绕过冷却期
     */
    function onLPTransfer(address _from, address _to) external {
        // 只允许 ytLP 代币合约调用
        if (msg.sender != ytLP) revert Forbidden();
        
        // 如果发送方有冷却时间记录，且接收方的冷却时间更早（或没有记录）
        // 则将发送方的冷却时间继承给接收方
        if (lastAddedAt[_from] > 0 && lastAddedAt[_to] < lastAddedAt[_from]) {
            lastAddedAt[_to] = lastAddedAt[_from];
            emit CooldownInherited(_from, _to, lastAddedAt[_from]);
        }
    }
    
    /**
     * @notice 为指定账户添加流动性（Handler调用）
     */
    function addLiquidityForAccount(
        address _fundingAccount,
        address _account,
        address _token,
        uint256 _amount,
        uint256 _minUsdy,
        uint256 _minYtLP
    ) external onlyHandler nonReentrant returns (uint256) {
        return _addLiquidity(_fundingAccount, _account, _token, _amount, _minUsdy, _minYtLP);
    }
    
    function _addLiquidity(
        address _fundingAccount,
        address _account,
        address _token,
        uint256 _amount,
        uint256 _minUsdy,
        uint256 _minYtLP
    ) private returns (uint256) {
        if (_amount == 0) revert InvalidAmount();
        
        uint256 aumInUsdy = getAumInUsdy(true);
        uint256 ytLPSupply = IERC20(ytLP).totalSupply();
        
        IERC20(_token).transferFrom(_fundingAccount, ytVault, _amount);
        uint256 usdyAmount = IYTVault(ytVault).buyUSDY(_token, address(this));
        if (usdyAmount < _minUsdy) revert InsufficientOutput();
        
        uint256 mintAmount;
        if (ytLPSupply == 0) {
            mintAmount = usdyAmount;
        } else {
            mintAmount = usdyAmount * ytLPSupply / aumInUsdy;
        }
        
        if (mintAmount < _minYtLP) revert InsufficientOutput();
        
        IYTLPToken(ytLP).mint(_account, mintAmount);
        lastAddedAt[_account] = block.timestamp;
        
        emit AddLiquidity(_account, _token, _amount, aumInUsdy, ytLPSupply, usdyAmount, mintAmount);
        
        return mintAmount;
    }
    
    /**
     * @notice 为指定账户移除流动性（Handler调用）
     */
    function removeLiquidityForAccount(
        address _account,
        address _tokenOut,
        uint256 _ytLPAmount,
        uint256 _minOut,
        address _receiver
    ) external onlyHandler nonReentrant returns (uint256) {
        return _removeLiquidity(_account, _tokenOut, _ytLPAmount, _minOut, _receiver);
    }
    
    function _removeLiquidity(
        address _account,
        address _tokenOut,
        uint256 _ytLPAmount,
        uint256 _minOut,
        address _receiver
    ) private returns (uint256) {
        if (_ytLPAmount == 0) revert InvalidAmount();
        
        if (lastAddedAt[_account] + cooldownDuration > block.timestamp) revert CooldownNotPassed();
        
        uint256 aumInUsdy = getAumInUsdy(false);
        uint256 ytLPSupply = IERC20(ytLP).totalSupply();
        
        uint256 usdyAmount = _ytLPAmount * aumInUsdy / ytLPSupply;
        
        // 先销毁ytLP
        IYTLPToken(ytLP).burn(_account, _ytLPAmount);
        
        // 检查余额，只铸造差额部分
        uint256 usdyBalance = IERC20(usdy).balanceOf(address(this));
        if (usdyAmount > usdyBalance) {
            IUSDY(usdy).mint(address(this), usdyAmount - usdyBalance);
        }
        
        // 转账USDY到Vault并换回代币
        IERC20(usdy).safeTransfer(ytVault, usdyAmount);
        uint256 amountOut = IYTVault(ytVault).sellUSDY(_tokenOut, _receiver);
        
        if (amountOut < _minOut) revert InsufficientOutput();
        
        emit RemoveLiquidity(_account, _tokenOut, _ytLPAmount, aumInUsdy, ytLPSupply, usdyAmount, amountOut);
        
        return amountOut;
    }
    
    /**
     * @notice 获取ytLP价格
     * @param _maximise 是否取最大值
     * @return ytLP价格（18位精度）
     */
    function getPrice(bool _maximise) external view returns (uint256) {
        uint256 aum = getAumInUsdy(_maximise);
        uint256 supply = IERC20(ytLP).totalSupply();
        
        if (supply == 0) return YTLP_PRECISION;
        
        return aum * YTLP_PRECISION / supply;
    }
    
    /**
     * @notice 获取池子总价值（AUM）
     * @param _maximise true=使用最大价格(添加流动性时), false=使用最小价格(移除流动性时)
     * @return USDY计价的总价值
     */
    function getAumInUsdy(bool _maximise) public view returns (uint256) {
        uint256 aum = IYTVault(ytVault).getPoolValue(_maximise);
        
        aum += aumAddition;  // aumAddition是协议额外增加的AUM，用来“预留风险缓冲 / 扣除潜在负债”
        if (aum > aumDeduction) {
            aum -= aumDeduction;
        } else {
            aum = 0;
        }
        
        return aum;
    }
    
    /**
     * @notice 预估添加流动性能获得的 ytLP 数量
     * @param _token 存入的 token 地址
     * @param _amount 存入的 token 数量
     * @return usdyAmount 扣除手续费后实际得到的 USDY 数量
     * @return ytLPMintAmount 预计铸造的 ytLP 数量
     */
    function getAddLiquidityOutput(
        address _token,
        uint256 _amount
    ) external view returns (uint256 usdyAmount, uint256 ytLPMintAmount) {
        // 模拟 buyUSDY：token → USDY（含动态手续费）
        uint256 price = IYTVault(ytVault).getMinPrice(_token);
        uint256 rawUsdyAmount = _amount * price / PRICE_PRECISION;
        uint256 feeBasisPoints = IYTVault(ytVault).getSwapFeeBasisPoints(_token, usdy, rawUsdyAmount);
        uint256 amountAfterFees = _amount - (_amount * feeBasisPoints / BASIS_POINTS_DIVISOR);
        usdyAmount = amountAfterFees * price / PRICE_PRECISION;

        // 模拟 _addLiquidity：USDY → ytLP mint 数量
        uint256 aumInUsdy = getAumInUsdy(true);
        uint256 ytLPSupply = IERC20(ytLP).totalSupply();
        if (ytLPSupply == 0) {
            ytLPMintAmount = usdyAmount;
        } else {
            ytLPMintAmount = usdyAmount * ytLPSupply / aumInUsdy;
        }
    }

    /**
     * @notice 预估移除流动性能获得的 token 数量
     * @param _tokenOut 取出的 token 地址
     * @param _ytLPAmount 销毁的 ytLP 数量
     * @return usdyAmount ytLP 对应的 USDY 价值
     * @return amountOut 扣除手续费后实际获得的 token 数量
     */
    function getRemoveLiquidityOutput(
        address _tokenOut,
        uint256 _ytLPAmount
    ) external view returns (uint256 usdyAmount, uint256 amountOut) {
        // 模拟 _removeLiquidity：ytLP → USDY
        uint256 aumInUsdy = getAumInUsdy(false);
        uint256 ytLPSupply = IERC20(ytLP).totalSupply();
        usdyAmount = _ytLPAmount * aumInUsdy / ytLPSupply;

        // 模拟 sellUSDY：USDY → token（含动态手续费）
        uint256 price = IYTVault(ytVault).getMaxPrice(_tokenOut);
        uint256 redemptionAmount = usdyAmount * PRICE_PRECISION / price;
        uint256 feeBasisPoints = IYTVault(ytVault).getRedemptionFeeBasisPoints(_tokenOut, redemptionAmount);
        amountOut = redemptionAmount * (BASIS_POINTS_DIVISOR - feeBasisPoints) / BASIS_POINTS_DIVISOR;
    }

    /**
     * @dev 预留存储空间，用于未来升级时添加新的状态变量
     * 50个slot = 50 * 32 bytes = 1600 bytes
     */
    uint256[50] private __gap;
}