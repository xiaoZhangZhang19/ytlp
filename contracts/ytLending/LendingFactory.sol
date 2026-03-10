// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./Lending.sol";
import "./LendingConfiguration.sol";

contract LendingFactory is LendingConfiguration, Ownable {

    constructor() Ownable(msg.sender) {}
    
    event LendingDeployed(address indexed lending);
    
    /**
     * @notice 部署新的 Lending 实现合约
     * @return 新 Lending 合约地址
     */
    function deploy() external onlyOwner returns (address) {
        Lending lending = new Lending();
        emit LendingDeployed(address(lending));
        return address(lending);
    }
}

