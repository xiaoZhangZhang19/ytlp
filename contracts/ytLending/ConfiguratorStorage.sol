// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./LendingConfiguration.sol";

/**
 * @title ConfiguratorStorage
 * @notice Configurator 存储定义
 */
abstract contract ConfiguratorStorage is LendingConfiguration {
    // Lending 代理地址 => 工厂合约地址
    mapping(address => address) public factory;
    
    // Lending 代理地址 => 配置参数
    mapping(address => Configuration) public configuratorParams;
}

