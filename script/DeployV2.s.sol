// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../Praxis.sol";
import "../PraxisInvites.sol";
import "../ArtistSponsoredInvites.sol";
import "../PraxisTicketMarket.sol";
import "../interfaces.sol";

/// @title DeployV2
/// @notice Deploys the partial-redeploy v2 contract set: Praxis, PraxisInvites,
///         ArtistSponsoredInvites, PraxisTicketMarket. The keeper contracts
///         (ArtistRegistry, BlogRegistry, LibraryRegistry, PraxisMedia,
///         PraxisTreasury) are NOT touched — they keep their existing addresses.
/// @dev Reads three env vars:
///       - REGISTRY_ADDRESS:  the existing ArtistRegistry (unchanged)
///       - MIGRATION_ROOT:    Merkle root from scripts/snapshot-invites.js
///       - DEPLOYER_PRIVATE_KEY: the EOA broadcasting the txs
contract DeployV2 is Script {
    function run() external {
        address registry = vm.envAddress("REGISTRY_ADDRESS");
        bytes32 migrationRoot = vm.envBytes32("MIGRATION_ROOT");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Sanity: registry must be a contract (not EOA, not zero) — defends against
        // accidentally pointing at a stale address.
        require(registry.code.length > 0, "REGISTRY_ADDRESS has no code");

        // Sanity: registry.deployer() should equal the broadcaster — otherwise we
        // won't be authorized to call setPraxisContract / setPaused later.
        address broadcaster = vm.addr(pk);
        require(IArtistRegistry(registry).deployer() == broadcaster, "broadcaster != registry.deployer()");
        require(IArtistRegistry(registry).orchestrator() != address(0), "registry orchestrator unset");

        vm.startBroadcast(pk);

        // 1. PraxisInvites — needs registry + migration Merkle root
        PraxisInvites invites = new PraxisInvites(registry, migrationRoot);

        // 2. Praxis — needs registry + invites
        Praxis praxis = new Praxis(registry, address(invites));

        // 3. ArtistSponsoredInvites — needs registry only
        ArtistSponsoredInvites sponsoredInvites = new ArtistSponsoredInvites(registry);

        // 4. PraxisTicketMarket — needs new Praxis address
        PraxisTicketMarket ticketMarket = new PraxisTicketMarket(address(praxis));

        // 5. Wire one-shot setter: invites learns who Praxis is so grantInvites works
        invites.setPraxisContract(address(praxis));

        vm.stopBroadcast();

        // --- Post-deploy assertions ---
        require(address(invites.REGISTRY()) == registry, "invites.REGISTRY mismatch");
        require(address(praxis.REGISTRY()) == registry, "praxis.REGISTRY mismatch");
        require(address(praxis.INVITES()) == address(invites), "praxis.INVITES mismatch");
        require(address(sponsoredInvites.REGISTRY()) == registry, "sponsor.REGISTRY mismatch");
        require(address(ticketMarket.praxis()) == address(praxis), "ticketMarket.praxis mismatch");
        require(invites.praxisContract() == address(praxis), "invites.praxisContract not set");
        require(invites.migrationRoot() == migrationRoot, "migrationRoot mismatch");
        require(invites.migrationDeadline() >= block.timestamp + 7 days - 60, "deadline wrong");
        require(invites.deployer() == broadcaster, "invites.deployer wrong");
        require(praxis.projectCount() == 0, "praxis.projectCount nonzero");

        // Emit logs the user can grep from the broadcast output
        console2.log("===============================================");
        console2.log("v2 deploy complete (existing contracts kept):");
        console2.log("  ArtistRegistry        ", registry);
        console2.log("  PraxisInvites         ", address(invites));
        console2.log("  Praxis                ", address(praxis));
        console2.log("  ArtistSponsoredInvites", address(sponsoredInvites));
        console2.log("  PraxisTicketMarket    ", address(ticketMarket));
        console2.log("===============================================");
        console2.log("migrationRoot:");
        console2.logBytes32(migrationRoot);
        console2.log("migrationDeadline (unix):", invites.migrationDeadline());
    }
}
