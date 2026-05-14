// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../PraxisTreasury.sol";

contract DeployTreasury is Script {
    function run() external {
        // Scroll mainnet addresses
        address syncSwapRouter    = 0x80e38291e06339d10AAB483C65695D004dBD5C69;
        address syncSwapPool      = 0x814A23B053FD0f102AEEda0459215C2444799C70; // ETH/USDC classic pool
        address etherFiCashAccount = 0x306d8252a60558742656D7a7d83260052862279e; // EtherFi Cash (USDC spendable via card)
        address weth              = 0x5300000000000000000000000000000000000004; // WETH on Scroll
        address usdc              = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4; // USDC on Scroll
        uint256 slippageBps       = 50; // 0.5% (max 100 bps = 1%)

        vm.startBroadcast();
        new PraxisTreasury(
            syncSwapRouter,
            syncSwapPool,
            etherFiCashAccount,
            weth,
            usdc,
            slippageBps
        );
        vm.stopBroadcast();
    }
}
