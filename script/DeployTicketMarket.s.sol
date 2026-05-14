// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../PraxisTicketMarket.sol";

contract DeployTicketMarket is Script {
    function run() external {
        vm.startBroadcast();
        new PraxisTicketMarket(0xc36567Cc94E299C3Fee4486AF35145F14743D7c2);
        vm.stopBroadcast();
    }
}
