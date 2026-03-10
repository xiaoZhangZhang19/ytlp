// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./ConfiguratorStorage.sol";
import "./LendingFactory.sol";

/**
 * @title Configurator
 * @notice 借贷池配置管理合约
 */
contract Configurator is 
    ConfiguratorStorage, 
    UUPSUpgradeable,
    OwnableUpgradeable 
{
    event SetFactory(address indexed lendingProxy, address indexed oldFactory, address indexed newFactory);
    event SetConfiguration(address indexed lendingProxy, Configuration oldConfiguration, Configuration newConfiguration);
    event AddAsset(address indexed lendingProxy, AssetConfig assetConfig);
    event UpdateAsset(address indexed lendingProxy, AssetConfig oldAssetConfig, AssetConfig newAssetConfig);
    event LendingDeployed(address indexed lendingProxy, address indexed newLending);

    error AlreadyInitialized();
    error AssetDoesNotExist();
    error ConfigurationAlreadyExists();
    error InvalidAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
    }

    /**
     * @dev 授权升级函数 - 只有 owner 可以升级
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice 设置工厂合约地址
     * @param lendingProxy Lending 代理地址
     * @param newFactory 新工厂地址
     */
    function setFactory(address lendingProxy, address newFactory) external onlyOwner {
        if (newFactory == address(0)) revert InvalidAddress();
        
        address oldFactory = factory[lendingProxy];
        factory[lendingProxy] = newFactory;
        emit SetFactory(lendingProxy, oldFactory, newFactory);
    }

    /**
     * @notice 设置市场配置
     * @param lendingProxy Lending 代理地址
     * @param newConfiguration 新配置
     */
    function setConfiguration(address lendingProxy, Configuration calldata newConfiguration) 
        external 
        onlyOwner 
    {
        Configuration memory oldConfiguration = configuratorParams[lendingProxy];
        
        // 防止修改不可变参数
        if (oldConfiguration.baseToken != address(0) &&
            oldConfiguration.baseToken != newConfiguration.baseToken)
            revert ConfigurationAlreadyExists();

        // 删除旧的资产配置
        delete configuratorParams[lendingProxy];
        
        // 设置新配置
        configuratorParams[lendingProxy].baseToken = newConfiguration.baseToken;
        configuratorParams[lendingProxy].lendingPriceSource = newConfiguration.lendingPriceSource;
        configuratorParams[lendingProxy].supplyKink = newConfiguration.supplyKink;
        configuratorParams[lendingProxy].supplyPerYearInterestRateSlopeLow = newConfiguration.supplyPerYearInterestRateSlopeLow;
        configuratorParams[lendingProxy].supplyPerYearInterestRateSlopeHigh = newConfiguration.supplyPerYearInterestRateSlopeHigh;
        configuratorParams[lendingProxy].supplyPerYearInterestRateBase = newConfiguration.supplyPerYearInterestRateBase;
        configuratorParams[lendingProxy].borrowKink = newConfiguration.borrowKink;
        configuratorParams[lendingProxy].borrowPerYearInterestRateSlopeLow = newConfiguration.borrowPerYearInterestRateSlopeLow;
        configuratorParams[lendingProxy].borrowPerYearInterestRateSlopeHigh = newConfiguration.borrowPerYearInterestRateSlopeHigh;
        configuratorParams[lendingProxy].borrowPerYearInterestRateBase = newConfiguration.borrowPerYearInterestRateBase;
        configuratorParams[lendingProxy].storeFrontPriceFactor = newConfiguration.storeFrontPriceFactor;
        configuratorParams[lendingProxy].baseBorrowMin = newConfiguration.baseBorrowMin;
        configuratorParams[lendingProxy].targetReserves = newConfiguration.targetReserves;
        
        // 复制资产配置
        for (uint i = 0; i < newConfiguration.assetConfigs.length; i++) {
            configuratorParams[lendingProxy].assetConfigs.push(newConfiguration.assetConfigs[i]);
        }
        
        emit SetConfiguration(lendingProxy, oldConfiguration, newConfiguration);
    }

    /**
     * @notice 添加抵押资产
     * @param lendingProxy Lending 代理地址
     * @param assetConfig 资产配置
     */
    function addAsset(address lendingProxy, AssetConfig calldata assetConfig) 
        external 
        onlyOwner 
    {
        configuratorParams[lendingProxy].assetConfigs.push(assetConfig);
        emit AddAsset(lendingProxy, assetConfig);
    }

    /**
     * @notice 更新资产配置
     * @param lendingProxy Lending 代理地址
     * @param newAssetConfig 新资产配置
     */
    function updateAsset(address lendingProxy, AssetConfig calldata newAssetConfig) 
        external 
        onlyOwner 
    {
        uint assetIndex = getAssetIndex(lendingProxy, newAssetConfig.asset);
        AssetConfig memory oldAssetConfig = configuratorParams[lendingProxy].assetConfigs[assetIndex];
        configuratorParams[lendingProxy].assetConfigs[assetIndex] = newAssetConfig;
        emit UpdateAsset(lendingProxy, oldAssetConfig, newAssetConfig);
    }

    /**
     * @notice 更新资产抵押率
     * @param lendingProxy Lending 代理地址
     * @param asset 资产地址
     * @param newBorrowCF 新借款抵押率
     */
    function updateAssetBorrowCollateralFactor(
        address lendingProxy, 
        address asset, 
        uint64 newBorrowCF
    ) 
        external 
        onlyOwner 
    {
        uint assetIndex = getAssetIndex(lendingProxy, asset);
        configuratorParams[lendingProxy].assetConfigs[assetIndex].borrowCollateralFactor = newBorrowCF;
    }

    /**
     * @notice 更新资产供应上限
     * @param lendingProxy Lending 代理地址
     * @param asset 资产地址
     * @param newSupplyCap 新供应上限
     */
    function updateAssetSupplyCap(
        address lendingProxy, 
        address asset, 
        uint128 newSupplyCap
    ) 
        external 
        onlyOwner 
    {
        uint assetIndex = getAssetIndex(lendingProxy, asset);
        configuratorParams[lendingProxy].assetConfigs[assetIndex].supplyCap = newSupplyCap;
    }

    /**
     * @notice 部署新的 Lending 实现
     * @param lendingProxy Lending 代理地址
     * @return 新实现合约地址
     */
    function deploy(address lendingProxy) external onlyOwner returns (address) {
        address newLending = LendingFactory(factory[lendingProxy]).deploy();
        emit LendingDeployed(lendingProxy, newLending);
        return newLending;
    }

    /**
     * @notice 获取资产索引
     * @param lendingProxy Lending 代理地址
     * @param asset 资产地址
     * @return 资产在配置数组中的索引
     */
    function getAssetIndex(address lendingProxy, address asset) public view returns (uint) {
        AssetConfig[] memory assetConfigs = configuratorParams[lendingProxy].assetConfigs;
        uint numAssets = assetConfigs.length;
        for (uint i = 0; i < numAssets; ) {
            if (assetConfigs[i].asset == asset) {
                return i;
            }
            unchecked { i++; }
        }
        revert AssetDoesNotExist();
    }

    /**
     * @notice 获取市场配置
     * @param lendingProxy Lending 代理地址
     * @return 配置信息
     */
    function getConfiguration(address lendingProxy) external view returns (Configuration memory) {
        return configuratorParams[lendingProxy];
    }

    /**
     * @dev 预留存储空间，用于未来升级时添加新的状态变量
     * 50个slot = 50 * 32 bytes = 1600 bytes
     */
    uint256[50] private __gap;
}

