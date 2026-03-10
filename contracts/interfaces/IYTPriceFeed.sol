// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IYTPriceFeed {
    function getPrice(address _token, bool _maximise) external view returns (uint256);
}

