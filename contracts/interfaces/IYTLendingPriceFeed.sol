// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IYTLendingPriceFeed {
    function getPrice(address _token) external view returns (uint256);
}