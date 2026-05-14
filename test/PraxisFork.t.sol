// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../ArtistRegistry.sol";
import "../Praxis.sol";

// IPraxisInvites is now imported via Praxis.sol
// Extended interface for test-only read methods
interface IPraxisInvitesExt is IPraxisInvites {
    function invitesRemaining(address) external view returns (uint256);
    function invitedBy(address) external view returns (address);
    function createInvite(bytes32 codeHash) external;
    function useInvite(string calldata code, uint256 expiry, bytes32 nonce, bytes calldata orchSig) external;
    function deployer() external view returns (address);
    function praxisContract() external view returns (address);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface IBlogRegistry {
    function post(string calldata title, string calldata content) external returns (uint256);
    function postCount() external view returns (uint256);
}

interface IPraxisTicketMarket {
    function praxis() external view returns (address);
    function listingCount() external view returns (uint256);
    function listings(uint256 tokenId) external view returns (address seller, uint256 price, bool active);
    function pendingWithdrawals(address) external view returns (uint256);
    function list(uint256 tokenId, uint256 price) external;
    function purchase(uint256 tokenId) external payable;
    function cancel(uint256 tokenId) external;
    function updatePrice(uint256 tokenId, uint256 newPrice) external;
    function withdraw() external;
}

// Fork test — runs against real deployed contracts on Scroll
// Usage: forge test --match-contract PraxisForkTest --fork-url $RPC
contract PraxisForkTest is Test {
    // Contract addresses from CLAUDE.md (current deployments)
    ArtistRegistry registry = ArtistRegistry(0xE37C4f2278838016f81f68342f14B82Cb36d88Ef);
    Praxis praxis = Praxis(0xc36567Cc94E299C3Fee4486AF35145F14743D7c2);
    IPraxisInvitesExt invites = IPraxisInvitesExt(0x15f1E6c1675F2F80C2D74d6c3eF3A2A6874f380d);
    IBlogRegistry blog = IBlogRegistry(0x92e829369B33230F7a89a7d178aEbE778B9c0D61);
    IPraxisTicketMarket ticketMarket = IPraxisTicketMarket(0x155aBd410924afDEe49e26bD0938eE29dae4BaC8);

    // existing artists on-chain
    address milesxb = 0x46db55AD42dA6bA3c29a3C1522EBBF8e16960725;
    address plantmaterial = 0xc1951eF408265A3b90d07B0BE030e63CCc7da6c6;
    address fiction = 0x2bdf27dEEbf9Fb4A515E90f45496B695a67F45eA;

    // new test artists
    address newArtist = makeAddr("newArtist");
    address newArtist2 = makeAddr("newArtist2");

    // deployer address (fetched in setUp)
    address registryDeployer;
    address invitesDeployer;

    function setUp() public {
        // Skip fork tests when not running on a fork (no code at contract addresses)
        if (address(registry).code.length == 0) {
            vm.skip(true);
            return;
        }
        vm.deal(newArtist, 10 ether);
        vm.deal(newArtist2, 10 ether);
        vm.deal(milesxb, 10 ether);
        vm.deal(plantmaterial, 10 ether);
        vm.deal(fiction, 10 ether);
        registryDeployer = registry.deployer();
        invitesDeployer = invites.deployer();
        vm.deal(registryDeployer, 10 ether);
    }

    function test_fork_contracts_deployed() public view {
        // verify all contracts have code
        assertGt(address(registry).code.length, 0, "registry not deployed");
        assertGt(address(praxis).code.length, 0, "praxis not deployed");
        assertGt(address(invites).code.length, 0, "invites not deployed");
        assertGt(address(blog).code.length, 0, "blog not deployed");
        assertGt(address(ticketMarket).code.length, 0, "ticket market not deployed");
    }

    function test_fork_existing_artists() public view {
        // verify existing artists are registered
        (string memory d1,) = registry.artists(milesxb);
        assertEq(d1, "milesxb.bio");

        (string memory d2,) = registry.artists(fiction);
        assertEq(d2, "fiction.bio");

        // at least 3 artists registered (may grow over time)
        assertGe(registry.totalArtists(), 3);
    }

    function test_fork_invites_exist() public view {
        // verify existing artists have invites (may have used some)
        assertGe(invites.invitesRemaining(milesxb), 0);
        assertGe(invites.invitesRemaining(plantmaterial), 0);
        assertGe(invites.invitesRemaining(fiction), 0);
    }

    function test_fork_ticket_market_linked() public view {
        // verify ticket market points to the correct praxis contract
        assertEq(ticketMarket.praxis(), address(praxis));
    }

    function test_fork_blog_has_posts() public view {
        // at least 1 post exists
        assertGe(blog.postCount(), 1);
    }

    function test_fork_full_onboarding() public {
        // 1. grant invites to milesxb (in case they used them all)
        vm.prank(invitesDeployer);
        invites.grantInvites(milesxb, 10);

        // 2. milesxb creates an invite code
        string memory code = "test-invite-for-new-artist";
        bytes32 codeHash = keccak256(abi.encodePacked(code));

        vm.prank(milesxb);
        invites.createInvite(codeHash);

        // 3. new artist uses the invite
        vm.prank(newArtist);
        invites.useInvite(code, block.timestamp + 30 minutes, bytes32(0), "");
        assertEq(invites.invitedBy(newArtist), milesxb);
        assertEq(invites.invitesRemaining(newArtist), 10);

        // 4. deployer registers the new artist (registerDirect, no signature needed)
        vm.prank(registryDeployer);
        registry.registerDirect(newArtist, "newartist.bio");
        (string memory domain,) = registry.artists(newArtist);
        assertEq(domain, "newartist.bio");

        // 5. new artist follows milesxb
        vm.prank(newArtist);
        registry.follow(milesxb);
        assertTrue(registry.isFollowing(newArtist, milesxb));

        // 6. new artist writes a blog post
        uint256 countBefore = blog.postCount();
        vm.prank(newArtist);
        blog.post("my first post on praxis", "excited to be here");
        assertEq(blog.postCount(), countBefore + 1);
    }

    function test_fork_full_project_lifecycle() public {
        // setup: register new artists via invite + registerDirect
        vm.prank(invitesDeployer);
        invites.grantInvites(milesxb, 10);

        string memory code = "project-test-invite";
        bytes32 codeHash = keccak256(abi.encodePacked(code));
        vm.prank(milesxb);
        invites.createInvite(codeHash);
        vm.prank(newArtist);
        invites.useInvite(code, block.timestamp + 30 minutes, bytes32(0), "");
        vm.prank(registryDeployer);
        registry.registerDirect(newArtist, "projecttest.bio");

        // 1. propose project with tiers
        address[] memory collabs = new address[](2);
        collabs[0] = milesxb;
        collabs[1] = newArtist;
        uint256[] memory splits = new uint256[](2);
        splits[0] = 6000;
        splits[1] = 4000;

        string[] memory tierNames = new string[](2);
        tierNames[0] = "Audience";
        tierNames[1] = "Producer";
        uint256[] memory tierPrices = new uint256[](2);
        tierPrices[0] = 0.01 ether;
        tierPrices[1] = 0.5 ether;
        uint256[] memory tierSupplies = new uint256[](2);
        tierSupplies[0] = 100;
        tierSupplies[1] = 5;
        bool[] memory tierTransferable = new bool[](2);
        tierTransferable[0] = true;
        tierTransferable[1] = false;

        vm.prank(fiction);
        uint256 projectId = praxis.proposeProject(Praxis.ProposeProjectArgs({
            title: "Fork Test Show", description: "testing on forked Arbitrum",
            projectType: "show", metadataCid: "", collaborators: collabs, splits: splits,
            fundingGoal: 1 ether, deadline: block.timestamp + 30 days,
            tierNames: tierNames, tierPrices: tierPrices, tierMaxSupplies: tierSupplies,
            tierTransferable: tierTransferable, tierMetadataCids: new string[](tierNames.length), revenueSharePercent: 0, location: 0,
            disputeWindowDays: 3, autoComplete: false, confirmationMode: 3
        }));

        // 2. fund: buy ticket + producer credit
        vm.prank(newArtist);
        praxis.fundTier{value: 0.01 ether}(projectId, 0, 1); // ticket

        vm.prank(plantmaterial);
        praxis.fundTier{value: 0.5 ether}(projectId, 1, 1); // producer

        // verify tokens
        uint256 ticketId = praxis.generateTokenId(1, projectId, 0, 1);
        assertEq(praxis.balanceOf(newArtist, ticketId), 1);

        uint256 producerId = praxis.generateTokenId(2, projectId, 1, 1);
        assertEq(praxis.balanceOf(plantmaterial, producerId), 1);

        // 3. ticket is transferable
        vm.prank(newArtist);
        praxis.transfer(fiction, ticketId, 1);
        assertEq(praxis.balanceOf(fiction, ticketId), 1);

        // 4. producer credit is soulbound
        vm.prank(plantmaterial);
        vm.expectRevert("soulbound");
        praxis.transfer(fiction, producerId, 1);

        // 5. fund to goal
        vm.prank(milesxb);
        praxis.fundTier{value: 0.5 ether}(projectId, 1, 1);

        // 6. confirm: proposer + majority (both collabs = 100% > 50%)
        vm.prank(fiction); // proposer
        praxis.confirmProject(projectId);

        // verify hasConfirmed
        assertTrue(praxis.hasConfirmed(projectId, fiction));
        assertFalse(praxis.hasConfirmed(projectId, milesxb));

        vm.prank(milesxb);
        praxis.confirmProject(projectId);
        vm.prank(newArtist);
        praxis.confirmProject(projectId);

        // all confirmed
        assertTrue(praxis.hasConfirmed(projectId, fiction));
        assertTrue(praxis.hasConfirmed(projectId, milesxb));
        assertTrue(praxis.hasConfirmed(projectId, newArtist));

        // 7. complete -> dispute window
        vm.prank(fiction);
        praxis.completeProject(projectId);

        // 8. warp past dispute window
        vm.warp(block.timestamp + 3 days + 1);

        // 9. finalize
        praxis.finalizeProject(projectId);

        // 10. verify credentials minted
        uint256 contribId0 = praxis.generateTokenId(3, projectId, 0, 0);
        uint256 contribId1 = praxis.generateTokenId(3, projectId, 0, 1);
        assertEq(praxis.balanceOf(milesxb, contribId0), 1); // contributor
        assertEq(praxis.balanceOf(newArtist, contribId1), 1); // contributor

        // 11. verify funds in pending
        assertGt(praxis.pendingWithdrawals(milesxb), 0);
        assertGt(praxis.pendingWithdrawals(newArtist), 0);

        // 12. claim funds
        uint256 milesxbBefore = milesxb.balance;
        vm.prank(milesxb);
        praxis.claimFunds();
        assertGt(milesxb.balance, milesxbBefore);
    }

    function test_fork_ticket_market_lifecycle() public {
        // setup: register two new artists
        vm.prank(invitesDeployer);
        invites.grantInvites(milesxb, 10);

        string memory code1 = "ticket-market-invite-1";
        bytes32 codeHash1 = keccak256(abi.encodePacked(code1));
        vm.prank(milesxb);
        invites.createInvite(codeHash1);
        vm.prank(newArtist);
        invites.useInvite(code1, block.timestamp + 30 minutes, bytes32(0), "");
        vm.prank(registryDeployer);
        registry.registerDirect(newArtist, "tickettest1.bio");

        string memory code2 = "ticket-market-invite-2";
        bytes32 codeHash2 = keccak256(abi.encodePacked(code2));
        vm.prank(newArtist);
        invites.createInvite(codeHash2);
        vm.prank(newArtist2);
        invites.useInvite(code2, block.timestamp + 30 minutes, bytes32(0), "");
        vm.prank(registryDeployer);
        registry.registerDirect(newArtist2, "tickettest2.bio");

        // create project with transferable ticket tier
        address[] memory collabs = new address[](1);
        collabs[0] = milesxb;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;

        string[] memory tierNames = new string[](1);
        tierNames[0] = "Ticket";
        uint256[] memory tierPrices = new uint256[](1);
        tierPrices[0] = 0.01 ether;
        uint256[] memory tierSupplies = new uint256[](1);
        tierSupplies[0] = 10;
        bool[] memory tierTransferable = new bool[](1);
        tierTransferable[0] = true;

        vm.prank(fiction);
        uint256 projectId = praxis.proposeProject(Praxis.ProposeProjectArgs({
            title: "Ticket Market Test", description: "testing ticket resale",
            projectType: "show", metadataCid: "", collaborators: collabs, splits: splits,
            fundingGoal: 0.1 ether, deadline: block.timestamp + 30 days,
            tierNames: tierNames, tierPrices: tierPrices, tierMaxSupplies: tierSupplies,
            tierTransferable: tierTransferable, tierMetadataCids: new string[](tierNames.length), revenueSharePercent: 0, location: 0,
            disputeWindowDays: 3, autoComplete: false, confirmationMode: 3
        }));

        // fund — newArtist buys a ticket
        vm.prank(newArtist);
        praxis.fundTier{value: 0.01 ether}(projectId, 0, 1);
        uint256 ticketId = praxis.generateTokenId(1, projectId, 0, 1);
        assertEq(praxis.balanceOf(newArtist, ticketId), 1);

        // newArtist approves ticket market as operator
        vm.prank(newArtist);
        praxis.setOperator(address(ticketMarket), true);

        // list ticket for resale
        uint256 listingsBefore = ticketMarket.listingCount();
        vm.prank(newArtist);
        ticketMarket.list(ticketId, 0.05 ether);
        assertEq(ticketMarket.listingCount(), listingsBefore + 1);

        // verify listing
        (address seller, uint256 price, bool active) = ticketMarket.listings(ticketId);
        assertEq(seller, newArtist);
        assertEq(price, 0.05 ether);
        assertTrue(active);

        // update price
        vm.prank(newArtist);
        ticketMarket.updatePrice(ticketId, 0.03 ether);
        (, uint256 newPrice,) = ticketMarket.listings(ticketId);
        assertEq(newPrice, 0.03 ether);

        // newArtist2 purchases the ticket
        vm.prank(newArtist2);
        ticketMarket.purchase{value: 0.03 ether}(ticketId);

        // verify ownership transferred
        assertEq(praxis.balanceOf(newArtist2, ticketId), 1);
        assertEq(praxis.balanceOf(newArtist, ticketId), 0);

        // verify seller has pending withdrawal
        assertEq(ticketMarket.pendingWithdrawals(newArtist), 0.03 ether);

        // seller withdraws
        uint256 balBefore = newArtist.balance;
        vm.prank(newArtist);
        ticketMarket.withdraw();
        assertEq(newArtist.balance, balBefore + 0.03 ether);
        assertEq(ticketMarket.pendingWithdrawals(newArtist), 0);
    }

    function test_fork_ticket_market_cancel() public {
        // setup: register new artist
        vm.prank(invitesDeployer);
        invites.grantInvites(milesxb, 10);

        string memory code = "ticket-cancel-invite";
        bytes32 codeHash = keccak256(abi.encodePacked(code));
        vm.prank(milesxb);
        invites.createInvite(codeHash);
        vm.prank(newArtist);
        invites.useInvite(code, block.timestamp + 30 minutes, bytes32(0), "");
        vm.prank(registryDeployer);
        registry.registerDirect(newArtist, "canceltest.bio");

        // create project with ticket tier
        address[] memory collabs = new address[](1);
        collabs[0] = milesxb;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;

        string[] memory tierNames = new string[](1);
        tierNames[0] = "Ticket";
        uint256[] memory tierPrices = new uint256[](1);
        tierPrices[0] = 0.01 ether;
        uint256[] memory tierSupplies = new uint256[](1);
        tierSupplies[0] = 10;
        bool[] memory tierTransferable = new bool[](1);
        tierTransferable[0] = true;

        vm.prank(fiction);
        uint256 projectId = praxis.proposeProject(Praxis.ProposeProjectArgs({
            title: "Cancel Test", description: "testing cancel",
            projectType: "show", metadataCid: "", collaborators: collabs, splits: splits,
            fundingGoal: 0.1 ether, deadline: block.timestamp + 30 days,
            tierNames: tierNames, tierPrices: tierPrices, tierMaxSupplies: tierSupplies,
            tierTransferable: tierTransferable, tierMetadataCids: new string[](1), revenueSharePercent: 0, location: 0,
            disputeWindowDays: 3, autoComplete: false, confirmationMode: 3
        }));

        // fund and list
        vm.prank(newArtist);
        praxis.fundTier{value: 0.01 ether}(projectId, 0, 1);
        uint256 ticketId = praxis.generateTokenId(1, projectId, 0, 1);

        vm.prank(newArtist);
        praxis.setOperator(address(ticketMarket), true);

        vm.prank(newArtist);
        ticketMarket.list(ticketId, 0.05 ether);

        // cancel listing
        uint256 countBefore = ticketMarket.listingCount();
        vm.prank(newArtist);
        ticketMarket.cancel(ticketId);
        assertEq(ticketMarket.listingCount(), countBefore - 1);

        // verify listing is inactive
        (,, bool active) = ticketMarket.listings(ticketId);
        assertFalse(active);

        // verify seller still owns the ticket
        assertEq(praxis.balanceOf(newArtist, ticketId), 1);
    }
}
