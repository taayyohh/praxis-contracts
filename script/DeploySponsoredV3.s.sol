// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../ArtistSponsoredInvites.sol";
import "../interfaces.sol";

/// @title DeploySponsoredV3
/// @notice Single-contract redeploy of ArtistSponsoredInvites for the v3 upgrade
///         that adds optional per-slot domain budget. No other contracts are touched.
/// @dev Reads two env vars:
///       - REGISTRY_ADDRESS:    the existing ArtistRegistry (unchanged)
///       - DEPLOYER_PRIVATE_KEY: the EOA broadcasting the tx
///       - SPONSOR_MAX_DOMAIN_BUDGET (optional): override the default cap (wei)
contract DeploySponsoredV3 is Script {
    function run() external {
        address registry = vm.envAddress("REGISTRY_ADDRESS");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Sanity: registry must be a contract — defends against typos
        require(registry.code.length > 0, "REGISTRY_ADDRESS has no code");

        address broadcaster = vm.addr(pk);
        // The setMaxDomainBudget setter is gated on `registry.deployer() == msg.sender`,
        // so the broadcaster MUST equal the registry deployer or we won't be able to
        // tune the cap on-chain after deploy.
        require(
            IArtistRegistry(registry).deployer() == broadcaster,
            "broadcaster != registry.deployer()"
        );

        vm.startBroadcast(pk);

        ArtistSponsoredInvites sponsored = new ArtistSponsoredInvites(registry);

        // Optional: override the default cap (0.0025 ETH ≈ $10) at deploy time
        uint256 capOverride = vm.envOr("SPONSOR_MAX_DOMAIN_BUDGET", uint256(0));
        if (capOverride > 0) {
            sponsored.setMaxDomainBudget(capOverride);
        }

        vm.stopBroadcast();

        require(address(sponsored.REGISTRY()) == registry, "sponsor.REGISTRY mismatch");
        require(sponsored.gasBuffer() == 0.001 ether, "gas buffer mismatch");

        console.log("ArtistSponsoredInvites v3 deployed at:", address(sponsored));
        console.log("REGISTRY:", address(sponsored.REGISTRY()));
        console.log("maxDomainBudget (wei):", sponsored.maxDomainBudget());
    }
}
