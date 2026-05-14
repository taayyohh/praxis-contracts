// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../ArtistRegistry.sol";
import "../BlogRegistry.sol";
import "../LibraryRegistry.sol";
import "../PraxisMedia.sol";
import "../Praxis.sol";
import "../PraxisInvites.sol";
import "../ArtistSponsoredInvites.sol";
import "../PraxisTicketMarket.sol";
import "../PraxisOrganization.sol";

/// @title DeployAll
/// @notice Full redeploy of all 10 Praxis contracts on Optimism.
///         Compiled with FOUNDRY_PROFILE=no-ir for Etherscan verification.
/// @dev Reads DEPLOYER_PRIVATE_KEY from env. Treasury uses Optimism addresses.
contract DeployAll is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address broadcaster = vm.addr(pk);

        vm.startBroadcast(pk);

        // 1. ArtistRegistry — root contract, no dependencies
        ArtistRegistry registry = new ArtistRegistry();
        // Set orchestrator to deployer initially (will be updated to the orchestrator API address)
        registry.setOrchestrator(broadcaster);

        // 2. BlogRegistry — depends on registry
        BlogRegistry blog = new BlogRegistry(address(registry));

        // 3. LibraryRegistry — depends on registry
        LibraryRegistry library_ = new LibraryRegistry(address(registry));

        // 4. PraxisMedia — depends on registry
        PraxisMedia media = new PraxisMedia(address(registry));

        // 5. PraxisInvites — depends on registry, no migration root (fresh deploy)
        PraxisInvites invites = new PraxisInvites(address(registry), bytes32(0));

        // 6. Praxis — depends on registry + invites
        Praxis praxis = new Praxis(address(registry), address(invites));

        // 7. Wire invites -> praxis
        invites.setPraxisContract(address(praxis));

        // 8. ArtistSponsoredInvites — depends on registry
        ArtistSponsoredInvites sponsored = new ArtistSponsoredInvites(address(registry));

        // 9. PraxisTicketMarket — depends on praxis
        PraxisTicketMarket tickets = new PraxisTicketMarket(address(praxis));

        // PraxisTreasury — keep existing deployment (no vulnerabilities found, already verified)
        address treasury = 0xE37C4f2278838016f81f68342f14B82Cb36d88Ef;
        registry.setTreasury(treasury);

        // 11. PraxisOrganization — depends on registry
        PraxisOrganization org = new PraxisOrganization(address(registry));

        vm.stopBroadcast();

        // --- Post-deploy assertions ---
        require(registry.deployer() == broadcaster, "registry deployer mismatch");
        require(address(blog.REGISTRY()) == address(registry), "blog registry mismatch");
        require(address(invites.REGISTRY()) == address(registry), "invites registry mismatch");
        require(address(praxis.REGISTRY()) == address(registry), "praxis registry mismatch");
        require(invites.praxisContract() == address(praxis), "invites praxis mismatch");
        require(address(sponsored.REGISTRY()) == address(registry), "sponsored registry mismatch");
        require(address(tickets.praxis()) == address(praxis), "tickets praxis mismatch");

        // Log all addresses
        console2.log("=== FULL DEPLOY COMPLETE ===");
        console2.log("ArtistRegistry       ", address(registry));
        console2.log("BlogRegistry         ", address(blog));
        console2.log("LibraryRegistry      ", address(library_));
        console2.log("PraxisMedia          ", address(media));
        console2.log("PraxisInvites        ", address(invites));
        console2.log("Praxis               ", address(praxis));
        console2.log("ArtistSponsoredInvites", address(sponsored));
        console2.log("PraxisTicketMarket   ", address(tickets));
        console2.log("PraxisTreasury (kept)", treasury);
        console2.log("PraxisOrganization   ", address(org));
        console2.log("============================");
    }
}
