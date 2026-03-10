// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title YTLPToken
 * @notice LP代币，代表用户在池子中的份额
 * @dev 只有授权的Minter（YTPoolManager）可以铸造和销毁，UUPS可升级合约
 */
contract YTLPToken is Initializable, ERC20Upgradeable, OwnableUpgradeable, UUPSUpgradeable {

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    error NotMinter();
    error InvalidMinter();
    error InvalidPoolManager();
    
    mapping(address => bool) public isMinter;
    
    address public poolManager;
    
    event MinterSet(address indexed minter, bool isActive);
    
    /**
     * @notice 初始化合约
     */
    function initialize() external initializer {
        __ERC20_init("YT Liquidity Provider", "ytLP");
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }
    
    /**
     * @notice 授权升级（仅owner可调用）
     * @param newImplementation 新实现合约地址
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    modifier onlyMinter() {
        if (!isMinter[msg.sender]) revert NotMinter();
        _;
    }
    
    /**
     * @notice 设置铸造权限
     * @param _minter 铸造者地址
     * @param _isActive 是否激活
     */
    function setMinter(address _minter, bool _isActive) external onlyOwner {
        if (_minter == address(0)) revert InvalidMinter();
        isMinter[_minter] = _isActive;
        emit MinterSet(_minter, _isActive);
    }
    
    /**
     * @notice 设置 PoolManager 地址
     * @param _poolManager PoolManager 合约地址
     * @dev 用于在转账时通知 PoolManager 更新冷却时间
     */
    function setPoolManager(address _poolManager) external onlyOwner {
        if (_poolManager == address(0)) revert InvalidPoolManager();
        poolManager = _poolManager;
    }
    
    /**
     * @notice 铸造ytLP代币
     * @param _to 接收地址
     * @param _amount 铸造数量
     */
    function mint(address _to, uint256 _amount) external onlyMinter {
        _mint(_to, _amount);
    }
    
    /**
     * @notice 销毁ytLP代币
     * @param _from 销毁地址
     * @param _amount 销毁数量
     */
    function burn(address _from, uint256 _amount) external onlyMinter {
        _burn(_from, _amount);
    }
    
    /**
     * @notice 重写 _update 函数，在转账时更新冷却时间
     * @dev 当 LP 代币转账时，接收方继承发送方的冷却时间，防止绕过冷却期
     */
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        
        // 只在实际转账时触发（不包括 mint 和 burn）
        if (from != address(0) && to != address(0) && poolManager != address(0)) {
            // 通知 PoolManager 更新接收方的冷却时间
            (bool success, ) = poolManager.call(
                abi.encodeWithSignature("onLPTransfer(address,address)", from, to)
            );
            require(success, "Failed to call onLPTransfer");
        }
    }
    
    /**
     * @dev 预留存储空间，用于未来升级时添加新的状态变量
     * 50个slot = 50 * 32 bytes = 1600 bytes
     */
    uint256[50] private __gap;
}

