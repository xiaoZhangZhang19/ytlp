// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./YTAssetVault.sol";

/**
 * @title YTAssetFactory
 * @notice 用于批量创建和管理YT资产金库合约的工厂
 * @dev UUPS可升级合约
 */
contract YTAssetFactory is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    
    error InvalidAddress();
    error VaultNotExists();
    error InvalidHardCap();
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /// @notice YTAssetVault实现合约地址
    address public vaultImplementation;
    
    /// @notice 所有创建的vault地址列表
    address[] public allVaults;
    
    /// @notice vault地址 => 是否存在
    mapping(address => bool) public isVault;
    
    /// @notice 默认硬顶值（0表示无限制）
    uint256 public defaultHardCap;
    
    event VaultCreated(
        address indexed vault,
        address indexed manager,
        string name,
        string symbol,
        uint256 hardCap,
        uint256 index
    );
    event VaultImplementationUpdated(address indexed newImplementation);
    event DefaultHardCapSet(uint256 newDefaultHardCap);
    event HardCapSet(address indexed vault, uint256 newHardCap);
    event PricesUpdated(address indexed vault, uint256 ytPrice);
    event NextRedemptionTimeSet(address indexed vault, uint256 redemptionTime);
    
    /**
     * @notice 初始化工厂
     * @param _vaultImplementation YTAssetVault实现合约地址
     * @param _defaultHardCap 默认硬顶值
     */
    function initialize(
        address _vaultImplementation,
        uint256 _defaultHardCap
    ) external initializer {
        if (_vaultImplementation == address(0)) revert InvalidAddress();
        
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        
        vaultImplementation = _vaultImplementation;
        defaultHardCap = _defaultHardCap;
    }
    
    /**
     * @notice 授权升级（仅owner可调用）
     * @param newImplementation 新实现合约地址
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    /**
     * @notice 更新YTAssetVault实现合约
     * @param _newImplementation 新的实现合约地址
     */
    function setVaultImplementation(address _newImplementation) external onlyOwner {
        if (_newImplementation == address(0)) revert InvalidAddress();
        vaultImplementation = _newImplementation;
        emit VaultImplementationUpdated(_newImplementation);
    }
    
    /**
     * @notice 设置默认硬顶
     * @param _defaultHardCap 新的默认硬顶值
     */
    function setDefaultHardCap(uint256 _defaultHardCap) external onlyOwner {
        defaultHardCap = _defaultHardCap;
        emit DefaultHardCapSet(_defaultHardCap);
    }

    /**
     * @notice 设置指定vault的硬顶
     * @param _vault vault地址
     * @param _hardCap 新的硬顶值
     */
    function setHardCap(address _vault, uint256 _hardCap) external onlyOwner {
        if (!isVault[_vault]) revert VaultNotExists();
        
        YTAssetVault(_vault).setHardCap(_hardCap);
        emit HardCapSet(_vault, _hardCap);
    }
    
    /**
     * @notice 批量设置硬顶
     * @param _vaults vault地址数组
     * @param _hardCaps 硬顶值数组
     */
    function setHardCapBatch(
        address[] memory _vaults,
        uint256[] memory _hardCaps
    ) external onlyOwner {
        require(_vaults.length == _hardCaps.length, "Length mismatch");
        
        for (uint256 i = 0; i < _vaults.length; i++) {
            if (!isVault[_vaults[i]]) revert VaultNotExists();
            YTAssetVault(_vaults[i]).setHardCap(_hardCaps[i]);
            emit HardCapSet(_vaults[i], _hardCaps[i]);
        }
    }
    
    /**
     * @notice 设置vault的管理员
     * @param _vault vault地址
     * @param _manager 新管理员地址
     */
    function setVaultManager(address _vault, address _manager) external onlyOwner {
        if (!isVault[_vault]) revert VaultNotExists();
        if (_manager == address(0)) revert InvalidAddress();
        
        YTAssetVault(_vault).setManager(_manager);
    }
    
    /**
     * @notice 设置vault的价格过期阈值
     * @param _vault vault地址
     * @param _threshold 阈值（秒）
     */
    function setPriceStalenessThreshold(address _vault, uint256 _threshold) external onlyOwner {
        if (!isVault[_vault]) revert VaultNotExists();
        
        YTAssetVault(_vault).setPriceStalenessThreshold(_threshold);
    }
    
    /**
     * @notice 设置vault的下一个赎回时间
     * @param _vault vault地址
     * @param _nextRedemptionTime 赎回时间（Unix时间戳）
     */
    function setVaultNextRedemptionTime(address _vault, uint256 _nextRedemptionTime) external onlyOwner {
        if (!isVault[_vault]) revert VaultNotExists();
        
        YTAssetVault(_vault).setNextRedemptionTime(_nextRedemptionTime);
        emit NextRedemptionTimeSet(_vault, _nextRedemptionTime);
    }
    
    /**
     * @notice 批量设置赎回时间
     * @param _vaults vault地址数组
     * @param _nextRedemptionTime 统一的赎回时间
     */
    function setVaultNextRedemptionTimeBatch(
        address[] memory _vaults,
        uint256 _nextRedemptionTime
    ) external onlyOwner {
        for (uint256 i = 0; i < _vaults.length; i++) {
            if (!isVault[_vaults[i]]) revert VaultNotExists();
            YTAssetVault(_vaults[i]).setNextRedemptionTime(_nextRedemptionTime);
            emit NextRedemptionTimeSet(_vaults[i], _nextRedemptionTime);
        }
    }
    
    /**
     * @notice 创建新的YTAssetVault
     * @param _name YT代币名称
     * @param _symbol YT代币符号
     * @param _manager 管理员地址
     * @param _hardCap 硬顶限制（0表示使用默认值）
     * @param _usdc USDC代币地址（传0使用默认地址）
     * @param _redemptionTime 赎回时间（Unix时间戳）
     * @param _initialYtPrice 初始YT价格（精度1e30，传0则使用默认值1.0）
     * @param _usdcPriceFeed Chainlink USDC价格Feed地址
     * @return vault 新创建的vault地址
     */
    function createVault(
        string memory _name,
        string memory _symbol,
        address _manager,
        uint256 _hardCap,
        address _usdc,
        uint256 _redemptionTime,
        uint256 _initialYtPrice,
        address _usdcPriceFeed
    ) external onlyOwner returns (address vault) {
        if (_manager == address(0)) revert InvalidAddress();
        
        // 如果传入0，使用默认硬顶
        uint256 actualHardCap = _hardCap == 0 ? defaultHardCap : _hardCap;
        
        // 编码初始化数据
        bytes memory initData = abi.encodeWithSelector(
            YTAssetVault.initialize.selector,
            _name,
            _symbol,
            _manager,
            actualHardCap,
            _usdc,
            _redemptionTime,
            _initialYtPrice,
            _usdcPriceFeed
        );
        
        // 部署代理合约
        vault = address(new ERC1967Proxy(vaultImplementation, initData));
        
        // 记录vault信息
        allVaults.push(vault);
        isVault[vault] = true;
        
        emit VaultCreated(
            vault,
            _manager,
            _name,
            _symbol,
            actualHardCap,
            allVaults.length - 1
        );
    }
    
    /**
     * @notice 批量创建vault
     * @param _names YT代币名称数组
     * @param _symbols YT代币符号数组
     * @param _managers 管理员地址数组
     * @param _hardCaps 硬顶数组
     * @param _usdc USDC代币地址（传0使用默认地址）
     * @param _redemptionTimes 赎回时间数组（Unix时间戳）
     * @param _initialYtPrices 初始YT价格数组（精度1e30）
     * @param _usdcPriceFeed Chainlink USDC价格Feed地址
     * @return vaults 创建的vault地址数组
     */
    function createVaultBatch(
        string[] memory _names,
        string[] memory _symbols,
        address[] memory _managers,
        uint256[] memory _hardCaps,
        address _usdc,
        uint256[] memory _redemptionTimes,
        uint256[] memory _initialYtPrices,
        address _usdcPriceFeed
    ) external onlyOwner returns (address[] memory vaults) {
        require(
            _names.length == _symbols.length &&
            _names.length == _managers.length &&
            _names.length == _hardCaps.length &&
            _names.length == _redemptionTimes.length &&
            _names.length == _initialYtPrices.length,
            "Length mismatch"
        );
        
        vaults = new address[](_names.length);
        
        for (uint256 i = 0; i < _names.length; i++) {
            vaults[i] = this.createVault(
                _names[i],
                _symbols[i],
                _managers[i],
                _hardCaps[i],
                _usdc,
                _redemptionTimes[i],
                _initialYtPrices[i],
                _usdcPriceFeed
            );
        }
    }
    
    /**
     * @notice 暂停vault（紧急情况）
     * @param _vault vault地址
     */
    function pauseVault(address _vault) external onlyOwner {
        if (!isVault[_vault]) revert VaultNotExists();
        
        YTAssetVault(_vault).pause();
    }
    
    /**
     * @notice 恢复vault
     * @param _vault vault地址
     */
    function unpauseVault(address _vault) external onlyOwner {
        if (!isVault[_vault]) revert VaultNotExists();
        
        YTAssetVault(_vault).unpause();
    }
    
    /**
     * @notice 批量暂停vaults
     * @param _vaults vault地址数组
     */
    function pauseVaultBatch(address[] memory _vaults) external onlyOwner {
        for (uint256 i = 0; i < _vaults.length; i++) {
            if (!isVault[_vaults[i]]) revert VaultNotExists();
            YTAssetVault(_vaults[i]).pause();
        }
    }
    
    /**
     * @notice 批量恢复vaults
     * @param _vaults vault地址数组
     */
    function unpauseVaultBatch(address[] memory _vaults) external onlyOwner {
        for (uint256 i = 0; i < _vaults.length; i++) {
            if (!isVault[_vaults[i]]) revert VaultNotExists();
            YTAssetVault(_vaults[i]).unpause();
        }
    }
    
    /**
     * @notice 更新vault价格
     * @param _vault vault地址
     * @param _ytPrice YT价格（精度1e30）
     */
    function updateVaultPrices(
        address _vault,
        uint256 _ytPrice
    ) external onlyOwner {
        if (!isVault[_vault]) revert VaultNotExists();
        
        YTAssetVault(_vault).updatePrices(_ytPrice);
        emit PricesUpdated(_vault, _ytPrice);
    }
    
    /**
     * @notice 批量更新价格
     * @param _vaults vault地址数组
     * @param _ytPrices YT价格数组（精度1e30）
     */
    function updateVaultPricesBatch(
        address[] memory _vaults,
        uint256[] memory _ytPrices
    ) external onlyOwner {
        require(_vaults.length == _ytPrices.length, "Length mismatch");
        
        for (uint256 i = 0; i < _vaults.length; i++) {
            if (!isVault[_vaults[i]]) revert VaultNotExists();
            YTAssetVault(_vaults[i]).updatePrices(_ytPrices[i]);
            emit PricesUpdated(_vaults[i], _ytPrices[i]);
        }
    }
    
    /**
     * @notice 升级指定vault
     * @param _vault vault地址
     * @param _newImplementation 新实现地址
     */
    function upgradeVault(address _vault, address _newImplementation) external onlyOwner {
        if (!isVault[_vault]) revert VaultNotExists();
        if (_newImplementation == address(0)) revert InvalidAddress();
        
        YTAssetVault(_vault).upgradeToAndCall(_newImplementation, "");
    }
    
    /**
     * @notice 批量升级vault
     * @param _vaults vault地址数组
     * @param _newImplementation 新实现地址
     */
    function upgradeVaultBatch(
        address[] memory _vaults,
        address _newImplementation
    ) external onlyOwner {
        if (_newImplementation == address(0)) revert InvalidAddress();
        
        for (uint256 i = 0; i < _vaults.length; i++) {
            if (!isVault[_vaults[i]]) revert VaultNotExists();
            YTAssetVault(_vaults[i]).upgradeToAndCall(_newImplementation, "");
        }
    }
    
    /**
     * @notice 获取所有vault数量
     */
    function getVaultCount() external view returns (uint256) {
        return allVaults.length;
    }
    
    /**
     * @notice 获取指定范围的vault地址
     * @param _start 起始索引
     * @param _end 结束索引（不包含）
     */
    function getVaults(uint256 _start, uint256 _end) 
        external 
        view 
        returns (address[] memory vaults) 
    {
        require(_start < _end && _end <= allVaults.length, "Invalid range");
        
        vaults = new address[](_end - _start);
        for (uint256 i = _start; i < _end; i++) {
            vaults[i - _start] = allVaults[i];
        }
    }
    
    /**
     * @notice 获取所有vault地址
     */
    function getAllVaults() external view returns (address[] memory) {
        return allVaults;
    }
    
    /**
     * @notice 获取vault详细信息
     * @param _vault vault地址
     */
    function getVaultInfo(address _vault) external view returns (
        bool exists,
        uint256 totalAssets,
        uint256 idleAssets,
        uint256 managedAssets,
        uint256 totalSupply,
        uint256 hardCap,
        uint256 usdcPrice,
        uint256 ytPrice,
        uint256 nextRedemptionTime
    ) {
        exists = isVault[_vault];
        if (!exists) return (false, 0, 0, 0, 0, 0, 0, 0, 0);
        (
            totalAssets,
            idleAssets,
            managedAssets,
            totalSupply,
            hardCap,
            usdcPrice,
            ytPrice,
            nextRedemptionTime
        ) = YTAssetVault(_vault).getVaultInfo();
    }
    
    /**
     * @dev 预留存储空间，用于未来升级时添加新的状态变量
     * 50个slot = 50 * 32 bytes = 1600 bytes
     */
    uint256[50] private __gap;
}
