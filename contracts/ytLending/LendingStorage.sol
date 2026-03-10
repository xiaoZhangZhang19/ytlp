// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./LendingConfiguration.sol";

/**
 * @title LendingStorage
 * @notice 借贷池存储变量定义
 */
abstract contract LendingStorage is LendingConfiguration {
    
    // 市场配置
    address public baseToken;
    address public lendingPriceSource;
    
    // 利率参数（每秒利率，已从年化利率转换）
    uint64 public supplyKink;
    uint64 public supplyPerSecondInterestRateSlopeLow;
    uint64 public supplyPerSecondInterestRateSlopeHigh;
    uint64 public supplyPerSecondInterestRateBase;
    
    uint64 public borrowKink;
    uint64 public borrowPerSecondInterestRateSlopeLow;
    uint64 public borrowPerSecondInterestRateSlopeHigh;
    uint64 public borrowPerSecondInterestRateBase;
    
    // 清算参数
    uint64 public storeFrontPriceFactor;
    uint104 public baseBorrowMin;
    uint104 public targetReserves;
    
    // 资产映射
    mapping(address => AssetConfig) public assetConfigs;
    address[] public assetList;
    
    // 用户账户信息
    struct UserBasic {
        int104 principal;  // 本金（正数=存款本金，负数=借款本金）
    }
    mapping(address => UserBasic) public userBasic;
    
    // 用户抵押品余额
    mapping(address => mapping(address => uint256)) public userCollateral;
    
    // 总存款本金和总借款本金
    uint104 public totalSupplyBase;
    uint104 public totalBorrowBase;
    
    // 利息索引
    uint256 public supplyIndex;
    uint256 public borrowIndex;
    uint256 public lastAccrualTime;
    
    // 清算后的抵押品库存（不同于 reserves！）
    // reserves 通过公式动态计算：balance - totalSupply + totalBorrow
    mapping(address => uint256) public collateralReserves;
}

