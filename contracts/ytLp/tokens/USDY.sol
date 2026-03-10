// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title USDY Token
 * @notice 统一计价代币
 * @dev 只有授权的Vault可以铸造和销毁，UUPS可升级合约
 */
contract USDY is Initializable, ERC20Upgradeable, OwnableUpgradeable, UUPSUpgradeable {
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    error Forbidden();
    error InvalidVault();
    
    mapping(address => bool) public vaults;
    
    event VaultAdded(address indexed vault);
    event VaultRemoved(address indexed vault);
    
    modifier onlyVault() {
        if (!vaults[msg.sender]) revert Forbidden();
        _;
    }
    
    /**
     * @notice 初始化合约
     */
    function initialize() external initializer {
        __ERC20_init("YT USD", "USDY");
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }
    
    /**
     * @notice 授权升级（仅owner可调用）
     * @param newImplementation 新实现合约地址
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    /**
     * @notice 添加授权的Vault地址
     * @param _vault Vault合约地址
     */
    function addVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert InvalidVault();
        vaults[_vault] = true;
        emit VaultAdded(_vault);
    }
    
    /**
     * @notice 移除授权的Vault地址
     * @param _vault Vault合约地址
     */
    function removeVault(address _vault) external onlyOwner {
        vaults[_vault] = false;
        emit VaultRemoved(_vault);
    }
    
    /**
     * @notice 铸造USDY代币
     * @param _account 接收地址
     * @param _amount 铸造数量
     */
    function mint(address _account, uint256 _amount) external onlyVault {
        _mint(_account, _amount);
    }
    
    /**
     * @notice 销毁USDY代币
     * @param _account 销毁地址
     * @param _amount 销毁数量
     */
    function burn(address _account, uint256 _amount) external onlyVault {
        _burn(_account, _amount);
    }
    
    /**
     * @dev 预留存储空间，用于未来升级时添加新的状态变量
     * 50个slot = 50 * 32 bytes = 1600 bytes
     */
    uint256[50] private __gap;
}

