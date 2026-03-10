// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title LendingConfiguration
 * @notice 借贷池配置结构体定义
 */
contract LendingConfiguration {
    struct AssetConfig {
        address asset;                      // 资产地址
        uint8 decimals;                     // 小数位数
        uint64 borrowCollateralFactor;     // 借款抵押率
        uint64 liquidateCollateralFactor;  // 清算抵押率
        uint64 liquidationFactor;           // 清算折扣
        uint128 supplyCap;                  // 供应上限
    }

    struct Configuration {
        address baseToken;                              // 基础资产
        address lendingPriceSource;                     // 借贷价格源
        
        // 利率模型参数
        uint64 supplyKink;                              // 供应拐点利用率
        uint64 supplyPerYearInterestRateSlopeLow;       // 供应拐点前斜率
        uint64 supplyPerYearInterestRateSlopeHigh;      // 供应拐点后斜率
        uint64 supplyPerYearInterestRateBase;           // 供应基础利率
        
        uint64 borrowKink;                              // 借款拐点利用率
        uint64 borrowPerYearInterestRateSlopeLow;       // 借款拐点前斜率
        uint64 borrowPerYearInterestRateSlopeHigh;      // 借款拐点后斜率
        uint64 borrowPerYearInterestRateBase;           // 借款基础利率
        
        // 其他核心参数
        uint64 storeFrontPriceFactor;                   // 清算价格折扣
        uint104 baseBorrowMin;                          // 最小借款额
        uint104 targetReserves;                         // 目标储备金
        
        AssetConfig[] assetConfigs;                     // 抵押资产配置数组
    }
}

