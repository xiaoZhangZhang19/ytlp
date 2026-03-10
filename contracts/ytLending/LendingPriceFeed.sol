// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/IYTAssetVault.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract LendingPriceFeed is OwnableUpgradeable, UUPSUpgradeable {
    address public usdcAddress;
    AggregatorV3Interface internal usdcPriceFeed;
    
    /// @notice 价格过期阈值（秒）
    uint256 public priceStalenesThreshold;

    error InvalidUsdcAddress();
    error InvalidUsdcPriceFeedAddress();
    error InvalidChainlinkPrice();
    error StalePrice();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _usdcAddress, address _usdcPriceFeed) external initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
        if (_usdcAddress == address(0)) revert InvalidUsdcAddress();
        if (_usdcPriceFeed == address(0)) revert InvalidUsdcPriceFeedAddress();
        usdcAddress = _usdcAddress;   
        usdcPriceFeed = AggregatorV3Interface(_usdcPriceFeed);
        priceStalenesThreshold = 3600; // 默认1小时
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function setUsdcAddress(address _usdcAddress) external onlyOwner {
        if (_usdcAddress == address(0)) revert InvalidUsdcAddress();
        usdcAddress = _usdcAddress;
    }
    
    /**
     * @notice 设置价格过期阈值
     * @param _threshold 阈值（秒），例如：3600 = 1小时，86400 = 24小时
     */
    function setPriceStalenessThreshold(uint256 _threshold) external onlyOwner {
        require(_threshold > 0 && _threshold <= 7 days, "Invalid threshold");
        priceStalenesThreshold = _threshold;
    }
    
    function getPrice(address _token) external view returns (uint256) {
        if (_token == usdcAddress) {
            return _getUSDCPrice();
        }
        return IYTAssetVault(_token).ytPrice();
    }

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
        
        return uint256(price) * 1e22; // 1e22 = 10^(30-8)
    }
}

