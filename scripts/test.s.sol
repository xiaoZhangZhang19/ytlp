// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge script scripts/test.s.sol:TestFun \
//   --fork-url https://data-seed-prebsc-1-s1.binance.org:8545 \
//   -vvvvv

import "forge-std/Script.sol";
import "forge-std/console.sol";

contract TestFun is Script {
    function run() external {

        address from = 0xa013422A5918CD099C63c8CC35283EACa99a705d; 
        address to   = 0x5af5A51F7702024E7387bba7497DC9965C00F16E; 

        bytes memory data = hex"8fed0b2c000000000000000000000000939cf46f7a4d05da2a37213e7379a8b04528f59000000000000000000000000000000000000000000000000053444835ec5800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a013422a5918cd099c63c8cc35283eaca99a705d";

        vm.startPrank(from);

        (bool ok, bytes memory ret) = to.call(data);

        vm.stopPrank();

        console.log("Call success:", ok);
        console.logBytes(ret);

    }
}
