// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../ArtistRegistry.sol";
import "../Praxis.sol";
import {PraxisInvites} from "../PraxisInvites.sol";
import "../PraxisTicketMarket.sol";

contract PraxisTicketMarketTest is Test {
    event TicketListed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event TicketPurchased(uint256 indexed tokenId, address indexed buyer, address indexed seller, uint256 price);
    event TicketCancelled(uint256 indexed tokenId, address indexed seller);
    event TicketPriceChanged(uint256 indexed tokenId, uint256 newPrice);
    event Withdrawn(address indexed seller, uint256 amount);

    ArtistRegistry registry;
    Praxis praxis;
    PraxisTicketMarket market;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address dave = makeAddr("dave");

    uint256 projectId;
    uint256 ticketTokenId;
    uint256 producerTokenId;

    function setUp() public {
        registry = new ArtistRegistry();
        PraxisInvites invites = new PraxisInvites(address(registry), bytes32(0));
        praxis = new Praxis(address(registry), address(invites));
        invites.setPraxisContract(address(praxis));
        market = new PraxisTicketMarket(address(praxis));

        registry.registerDirect(alice, "alice.xyz");
        registry.registerDirect(bob, "bob.xyz");
        registry.registerDirect(charlie, "charlie.xyz");
        registry.registerDirect(dave, "dave.xyz");

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
        vm.deal(dave, 100 ether);

        // Create a project with a transferable tier (TICKET) and a non-transferable tier (PRODUCER)
        address[] memory collaborators = new address[](1);
        collaborators[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;

        string[] memory tierNames = new string[](2);
        tierNames[0] = "General Admission";
        tierNames[1] = "Producer Credit";
        uint256[] memory tierPrices = new uint256[](2);
        tierPrices[0] = 0.1 ether;
        tierPrices[1] = 1 ether;
        uint256[] memory tierMaxSupplies = new uint256[](2);
        tierMaxSupplies[0] = 100;
        tierMaxSupplies[1] = 10;
        bool[] memory tierTransferable = new bool[](2);
        tierTransferable[0] = true;   // TICKET
        tierTransferable[1] = false;  // PRODUCER

        vm.prank(alice);
        projectId = praxis.proposeProject(Praxis.ProposeProjectArgs({
            title: "Test Show",
            description: "A test show",
            projectType: Praxis.ProjectType.SHOW,
            collaborators: collaborators,
            splits: splits,
            fundingGoal: 10 ether,
            deadline: block.timestamp + 30 days,
            tierNames: tierNames,
            tierPrices: tierPrices,
            tierMaxSupplies: tierMaxSupplies,
            tierTransferable: tierTransferable,
            revenueSharePercent: 0,
            location: 0,
            disputeWindowDays: 3,
            autoComplete: false,
            confirmationMode: 3
        }));

        // Charlie funds tier 0 (ticket) — gets a TICKET token
        vm.prank(charlie);
        praxis.fundTier{value: 0.1 ether}(projectId, 0, 1);

        // Dave funds tier 1 (producer) — gets a PRODUCER token (soulbound)
        vm.prank(dave);
        praxis.fundTier{value: 1 ether}(projectId, 1, 1);

        // Token IDs: type(8) | projectId(64) | tierId(32) | serial(152)
        ticketTokenId = praxis.generateTokenId(1, projectId, 0, 1);   // TICKET
        producerTokenId = praxis.generateTokenId(2, projectId, 1, 1); // PRODUCER

        // Verify ownership
        assertEq(praxis.balanceOf(charlie, ticketTokenId), 1);
        assertEq(praxis.balanceOf(dave, producerTokenId), 1);
    }

    // ===== list() success =====

    function test_list_success() public {
        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.expectEmit(true, true, false, true);
        emit TicketListed(ticketTokenId, charlie, 0.5 ether);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.5 ether);

        (address seller, uint256 price, bool active) = market.listings(ticketTokenId);
        assertEq(seller, charlie);
        assertEq(price, 0.5 ether);
        assertTrue(active);
        assertEq(market.listingCount(), 1);
    }

    function test_list_with_allowance() public {
        vm.prank(charlie);
        praxis.approve(address(market), ticketTokenId, 1);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.2 ether);

        (address seller,, bool active) = market.listings(ticketTokenId);
        assertEq(seller, charlie);
        assertTrue(active);
    }

    // ===== list() reverts =====

    function test_list_not_owner_reverts() public {
        vm.prank(bob);
        praxis.setOperator(address(market), true);

        vm.prank(bob);
        vm.expectRevert("not owner");
        market.list(ticketTokenId, 0.5 ether);
    }

    function test_list_not_ticket_reverts() public {
        vm.prank(dave);
        praxis.setOperator(address(market), true);

        vm.prank(dave);
        vm.expectRevert("not a ticket");
        market.list(producerTokenId, 0.5 ether);
    }

    function test_list_not_approved_reverts() public {
        // Charlie has not approved the market
        vm.prank(charlie);
        vm.expectRevert("not approved");
        market.list(ticketTokenId, 0.5 ether);
    }

    function test_list_zero_price_reverts() public {
        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        vm.expectRevert("zero price");
        market.list(ticketTokenId, 0);
    }

    function test_list_already_listed_reverts() public {
        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.5 ether);

        vm.prank(charlie);
        vm.expectRevert("already listed");
        market.list(ticketTokenId, 0.3 ether);
    }

    // ===== purchase() success =====

    function test_purchase_success() public {
        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.5 ether);

        vm.expectEmit(true, true, true, true);
        emit TicketPurchased(ticketTokenId, bob, charlie, 0.5 ether);

        vm.prank(bob);
        market.purchase{value: 0.5 ether}(ticketTokenId);

        // Token transferred
        assertEq(praxis.balanceOf(charlie, ticketTokenId), 0);
        assertEq(praxis.balanceOf(bob, ticketTokenId), 1);

        // Listing deactivated
        (,, bool active) = market.listings(ticketTokenId);
        assertFalse(active);

        // Pending withdrawal credited
        assertEq(market.pendingWithdrawals(charlie), 0.5 ether);
        assertEq(market.listingCount(), 0);
    }

    // ===== purchase() reverts =====

    function test_purchase_not_active_reverts() public {
        vm.prank(bob);
        vm.expectRevert("not active");
        market.purchase{value: 0.5 ether}(ticketTokenId);
    }

    function test_purchase_wrong_price_reverts() public {
        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.5 ether);

        vm.prank(bob);
        vm.expectRevert("wrong price");
        market.purchase{value: 0.4 ether}(ticketTokenId);
    }

    function test_purchase_overpay_reverts() public {
        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.5 ether);

        vm.prank(bob);
        vm.expectRevert("wrong price");
        market.purchase{value: 0.6 ether}(ticketTokenId);
    }

    // ===== cancel() success =====

    function test_cancel_success() public {
        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.5 ether);

        vm.expectEmit(true, true, false, false);
        emit TicketCancelled(ticketTokenId, charlie);

        vm.prank(charlie);
        market.cancel(ticketTokenId);

        (,, bool active) = market.listings(ticketTokenId);
        assertFalse(active);
        assertEq(market.listingCount(), 0);
    }

    // ===== cancel() reverts =====

    function test_cancel_not_active_reverts() public {
        vm.prank(charlie);
        vm.expectRevert("not active");
        market.cancel(ticketTokenId);
    }

    function test_cancel_not_seller_reverts() public {
        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.5 ether);

        vm.prank(bob);
        vm.expectRevert("not seller");
        market.cancel(ticketTokenId);
    }

    // ===== updatePrice() success =====

    function test_updatePrice_success() public {
        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.5 ether);

        vm.expectEmit(true, false, false, true);
        emit TicketPriceChanged(ticketTokenId, 0.8 ether);

        vm.prank(charlie);
        market.updatePrice(ticketTokenId, 0.8 ether);

        (, uint256 price,) = market.listings(ticketTokenId);
        assertEq(price, 0.8 ether);
    }

    // ===== updatePrice() reverts =====

    function test_updatePrice_not_active_reverts() public {
        vm.prank(charlie);
        vm.expectRevert("not active");
        market.updatePrice(ticketTokenId, 0.8 ether);
    }

    function test_updatePrice_not_seller_reverts() public {
        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.5 ether);

        vm.prank(bob);
        vm.expectRevert("not seller");
        market.updatePrice(ticketTokenId, 0.8 ether);
    }

    function test_updatePrice_zero_reverts() public {
        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.5 ether);

        vm.prank(charlie);
        vm.expectRevert("zero price");
        market.updatePrice(ticketTokenId, 0);
    }

    // ===== withdraw() success =====

    function test_withdraw_success() public {
        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.5 ether);

        vm.prank(bob);
        market.purchase{value: 0.5 ether}(ticketTokenId);

        uint256 balanceBefore = charlie.balance;

        vm.expectEmit(true, false, false, true);
        emit Withdrawn(charlie, 0.5 ether);

        vm.prank(charlie);
        market.withdraw();

        assertEq(charlie.balance, balanceBefore + 0.5 ether);
        assertEq(market.pendingWithdrawals(charlie), 0);
    }

    // ===== withdraw() reverts =====

    function test_withdraw_nothing_reverts() public {
        vm.prank(alice);
        vm.expectRevert("nothing to withdraw");
        market.withdraw();
    }

    // ===== Edge cases =====

    function test_purchase_then_relist() public {
        // Charlie lists, Bob buys, Bob relists
        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.5 ether);

        vm.prank(bob);
        market.purchase{value: 0.5 ether}(ticketTokenId);

        // Bob now owns the ticket — approve market and relist
        vm.prank(bob);
        praxis.setOperator(address(market), true);

        vm.prank(bob);
        market.list(ticketTokenId, 0.8 ether);

        (address seller, uint256 price, bool active) = market.listings(ticketTokenId);
        assertEq(seller, bob);
        assertEq(price, 0.8 ether);
        assertTrue(active);
        assertEq(market.listingCount(), 1);
    }

    function test_cancel_then_relist() public {
        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.5 ether);

        vm.prank(charlie);
        market.cancel(ticketTokenId);

        // Relist at a different price
        vm.prank(charlie);
        market.list(ticketTokenId, 0.3 ether);

        (address seller, uint256 price, bool active) = market.listings(ticketTokenId);
        assertEq(seller, charlie);
        assertEq(price, 0.3 ether);
        assertTrue(active);
        assertEq(market.listingCount(), 1);
    }

    function test_multiple_listings_count() public {
        // Fund a second ticket for charlie
        vm.prank(charlie);
        praxis.fundTier{value: 0.1 ether}(projectId, 0, 1);
        uint256 secondTicketId = praxis.generateTokenId(1, projectId, 0, 2);

        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.5 ether);

        vm.prank(charlie);
        market.list(secondTicketId, 0.6 ether);

        assertEq(market.listingCount(), 2);

        vm.prank(charlie);
        market.cancel(ticketTokenId);

        assertEq(market.listingCount(), 1);
    }

    function test_multiple_withdrawals_accumulate() public {
        // Charlie gets two tickets, lists both, both get purchased
        vm.prank(charlie);
        praxis.fundTier{value: 0.1 ether}(projectId, 0, 1);
        uint256 secondTicketId = praxis.generateTokenId(1, projectId, 0, 2);

        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.5 ether);

        vm.prank(charlie);
        market.list(secondTicketId, 0.3 ether);

        vm.prank(bob);
        market.purchase{value: 0.5 ether}(ticketTokenId);

        vm.prank(alice);
        market.purchase{value: 0.3 ether}(secondTicketId);

        assertEq(market.pendingWithdrawals(charlie), 0.8 ether);

        uint256 balanceBefore = charlie.balance;
        vm.prank(charlie);
        market.withdraw();
        assertEq(charlie.balance, balanceBefore + 0.8 ether);
    }

    function test_purchase_after_cancel_reverts() public {
        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.5 ether);

        vm.prank(charlie);
        market.cancel(ticketTokenId);

        vm.prank(bob);
        vm.expectRevert("not active");
        market.purchase{value: 0.5 ether}(ticketTokenId);
    }

    function test_updatePrice_then_purchase_at_new_price() public {
        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        market.list(ticketTokenId, 0.5 ether);

        vm.prank(charlie);
        market.updatePrice(ticketTokenId, 0.7 ether);

        // Old price fails
        vm.prank(bob);
        vm.expectRevert("wrong price");
        market.purchase{value: 0.5 ether}(ticketTokenId);

        // New price succeeds
        vm.prank(bob);
        market.purchase{value: 0.7 ether}(ticketTokenId);

        assertEq(praxis.balanceOf(bob, ticketTokenId), 1);
        assertEq(market.pendingWithdrawals(charlie), 0.7 ether);
    }
}
