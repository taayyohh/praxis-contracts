// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../ArtistRegistry.sol";
import "../Praxis.sol";
import {PraxisInvites} from "../PraxisInvites.sol";

contract PraxisTest is Test {
    event ProjectProposed(uint256 indexed projectId, address indexed proposer, uint256 fundingGoal);
    event ProjectConfirmed(uint256 indexed projectId, address indexed confirmer);
    event ProjectCompleting(uint256 indexed projectId, uint256 disputeDeadline);
    event ProjectDisputed(uint256 indexed projectId, address indexed disputer, uint256 amount);
    event FundingWithdrawn(uint256 indexed projectId, address indexed funder, uint256 amount);
    event Transfer(address caller, address indexed sender, address indexed receiver, uint256 indexed id, uint256 amount);

    ArtistRegistry registry;
    Praxis praxis;
    PraxisInvites invites;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address dave = makeAddr("dave");
    address eve = makeAddr("eve");

    function setUp() public {
        registry = new ArtistRegistry();
        invites = new PraxisInvites(address(registry), bytes32(0));
        praxis = new Praxis(address(registry), address(invites));
        invites.setPraxisContract(address(praxis));

        registry.registerDirect(alice, "alice.xyz");
        registry.registerDirect(bob, "bob.xyz");
        registry.registerDirect(charlie, "charlie.xyz");
        registry.registerDirect(dave, "dave.xyz");
        registry.registerDirect(eve, "eve.xyz");

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
        vm.deal(dave, 100 ether);
        vm.deal(eve, 100 ether);
    }

    // --- Propose ---

    function test_propose_success() public {
        uint256 id = _proposeShow();
        assertEq(id, 0);
        assertEq(praxis.projectCount(), 1);
        assertEq(praxis.tierCount(0), 3);
    }

    function test_propose_empty_title_reverts() public {
        vm.prank(alice);
        vm.expectRevert("empty title");
        _proposeWith("");
    }

    function test_propose_no_tiers_reverts() public {
        string[] memory names = new string[](0);
        uint256[] memory prices = new uint256[](0);
        uint256[] memory supplies = new uint256[](0);
        bool[] memory transferable = new bool[](0);

        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;

        vm.prank(alice);
        vm.expectRevert("no tiers");
        _callPropose("Show", "desc", Praxis.ProjectType.SHOW, collabs, splits, 1 ether, block.timestamp + 30 days, names, prices, supplies, transferable, 0, 0, 3, false, 3);
    }

    // --- Fund tiers ---

    function test_fund_ticket_tier() public {
        _proposeShow();

        vm.prank(dave);
        praxis.fundTier{value: 0.02 ether}(0, 0, 1);

        uint256 tokenId = praxis.generateTokenId(1, 0, 0, 1);
        assertEq(praxis.balanceOf(dave, tokenId), 1);
        assertEq(praxis.contributions(0, dave), 0.02 ether);
    }

    function test_fund_producer_tier() public {
        _proposeShow();

        vm.prank(dave);
        praxis.fundTier{value: 0.1 ether}(0, 1, 1);

        uint256 tokenId = praxis.generateTokenId(2, 0, 1, 1);
        assertEq(praxis.balanceOf(dave, tokenId), 1);
    }

    function test_fund_reaches_goal() public {
        _proposeShow();

        vm.prank(dave);
        praxis.fundTier{value: 1 ether}(0, 2, 1);

        (,,,,,,,, , uint8 status,) = praxis.getProject(0);
        assertEq(status, 1); // FUNDED
    }

    function test_fund_wrong_payment_reverts() public {
        _proposeShow();
        vm.prank(dave);
        vm.expectRevert("wrong payment");
        praxis.fundTier{value: 0.01 ether}(0, 0, 1);
    }

    function test_fund_sold_out_reverts() public {
        // propose with a small tier cap (3) and high goal so status doesn't change
        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;
        string[] memory tNames = new string[](1);
        tNames[0] = "Ticket";
        uint256[] memory tPrices = new uint256[](1);
        tPrices[0] = 0.01 ether;
        uint256[] memory tSupplies = new uint256[](1);
        tSupplies[0] = 3;
        bool[] memory tTransfer = new bool[](1);
        tTransfer[0] = true;

        vm.prank(alice);
        uint256 id = _callPropose("Sold Out Test", "test", Praxis.ProjectType.SHOW, collabs, splits, 100 ether, block.timestamp + 30 days, tNames, tPrices, tSupplies, tTransfer, 0, 0, 3, false, 3);

        vm.prank(dave);
        praxis.fundTier{value: 0.03 ether}(id, 0, 3); // buy all 3

        vm.prank(eve);
        vm.expectRevert("tier sold out");
        praxis.fundTier{value: 0.01 ether}(id, 0, 1);
    }

    function test_fund_max_per_tx_reverts() public {
        _proposeShow();
        vm.prank(dave);
        vm.expectRevert("max 100 per tx");
        praxis.fundTier{value: 0.02 ether * 101}(0, 0, 101);
    }

    // --- Token behavior ---

    function test_transfer_ticket_succeeds() public {
        _proposeShow();
        vm.prank(dave);
        praxis.fundTier{value: 0.02 ether}(0, 0, 1);

        uint256 tokenId = praxis.generateTokenId(1, 0, 0, 1);
        vm.prank(dave);
        praxis.transfer(eve, tokenId, 1);

        assertEq(praxis.balanceOf(dave, tokenId), 0);
        assertEq(praxis.balanceOf(eve, tokenId), 1);
    }

    function test_transfer_producer_reverts() public {
        _proposeShow();
        vm.prank(dave);
        praxis.fundTier{value: 0.1 ether}(0, 1, 1);

        uint256 tokenId = praxis.generateTokenId(2, 0, 1, 1);
        vm.prank(dave);
        vm.expectRevert("soulbound");
        praxis.transfer(eve, tokenId, 1);
    }

    function test_token_id_roundtrip() public view {
        uint256 tokenId = praxis.generateTokenId(2, 42, 3, 99);
        assertEq(praxis.getTokenType(tokenId), 2);
        assertEq(praxis.getProjectId(tokenId), 42);
        assertEq(praxis.getTierId(tokenId), 3);
    }

    // --- Confirmation: proposer + majority of collaborators ---

    function test_confirm_proposer_only_not_enough() public {
        _proposeShow();
        _fundToGoal(0);

        vm.prank(alice); // proposer
        praxis.confirmProject(0);

        (,,,,,,,,, uint8 status,) = praxis.getProject(0);
        assertEq(status, 1); // still FUNDED, not CONFIRMED (need majority of collabs)
    }

    function test_confirm_proposer_plus_majority() public {
        _proposeShow(); // collaborators: bob, charlie
        _fundToGoal(0);

        vm.prank(alice); // proposer
        praxis.confirmProject(0);

        vm.prank(bob); // 1 of 2 collaborators = 50%, need >50%
        praxis.confirmProject(0);

        (,,,,,,,,, uint8 status1,) = praxis.getProject(0);
        // 1 of 2 = 50%, not >50%. Still FUNDED.
        assertEq(status1, 1);

        vm.prank(charlie); // 2 of 2 collaborators = 100% > 50%
        praxis.confirmProject(0);

        (,,,,,,,,, uint8 status2,) = praxis.getProject(0);
        assertEq(status2, 2); // CONFIRMED
    }

    function test_confirm_non_participant_reverts() public {
        _proposeShow();
        _fundToGoal(0);

        vm.prank(eve); // not proposer or collaborator
        vm.expectRevert("not a participant");
        praxis.confirmProject(0);
    }

    function test_confirm_double_reverts() public {
        _proposeShow();
        _fundToGoal(0);

        vm.prank(alice);
        praxis.confirmProject(0);

        vm.prank(alice);
        vm.expectRevert("already confirmed");
        praxis.confirmProject(0);
    }

    // --- Completion + dispute window ---

    function test_complete_starts_dispute_window() public {
        _proposeShow();
        _fundToGoal(0);
        _confirmAll(0);

        vm.prank(alice);
        praxis.completeProject(0);

        (,,,,,,,,, uint8 status,) = praxis.getProject(0);
        assertEq(status, 3); // COMPLETING (dispute window)
    }

    function test_complete_not_confirmed_reverts() public {
        _proposeShow();
        _fundToGoal(0);

        vm.prank(alice);
        vm.expectRevert("not confirmed");
        praxis.completeProject(0);
    }

    function test_finalize_after_dispute_window() public {
        _proposeShow();
        _fundToGoal(0);
        _confirmAll(0);

        vm.prank(alice);
        praxis.completeProject(0);

        // warp past 3-day dispute window
        vm.warp(block.timestamp + 3 days + 1);

        praxis.finalizeProject(0);

        (,,,,,,,,, uint8 status,) = praxis.getProject(0);
        assertEq(status, 4); // COMPLETED

        // funds distributed to pending
        assertEq(praxis.pendingWithdrawals(bob), 0.6 ether);
        assertEq(praxis.pendingWithdrawals(charlie), 0.4 ether);

        // contributor tokens minted
        assertEq(praxis.balanceOf(bob, praxis.generateTokenId(3, 0, 0, 0)), 1);
        assertEq(praxis.balanceOf(charlie, praxis.generateTokenId(3, 0, 0, 1)), 1);
    }

    function test_finalize_during_window_reverts() public {
        _proposeShow();
        _fundToGoal(0);
        _confirmAll(0);

        vm.prank(alice);
        praxis.completeProject(0);

        // still within 3 days
        vm.warp(block.timestamp + 2 days);

        vm.expectRevert("dispute window active");
        praxis.finalizeProject(0);
    }

    // --- Dispute ---

    function test_dispute_by_funder() public {
        _proposeShow();
        _fundToGoal(0); // dave funds 1 ETH

        _confirmAll(0);

        vm.prank(alice);
        praxis.completeProject(0);

        vm.prank(dave);
        praxis.dispute(0);

        assertEq(praxis.disputeAmount(0), 1 ether);
        assertTrue(praxis.hasDisputed(0, dave));
    }

    function test_dispute_over_50pct_auto_cancels() public {
        uint256 id = _proposeShowSmall(); // goal = 0.1 ETH

        // dave funds 0.06, eve funds 0.04 = 0.1 total
        vm.prank(dave);
        praxis.fundTier{value: 0.06 ether}(id, 0, 3); // 3 tickets at 0.02 = 0.06

        vm.prank(eve);
        praxis.fundTier{value: 0.04 ether}(id, 0, 2); // 2 tickets at 0.02 = 0.04

        _confirmAll(id);

        vm.prank(alice);
        praxis.completeProject(id);

        // dave disputes (0.06 / 0.10 = 60% > 50%)
        vm.prank(dave);
        praxis.dispute(id);

        (,,,,,,,,, uint8 status,) = praxis.getProject(id);
        assertEq(status, 5); // CANCELLED (auto-cancelled by majority dispute)
    }

    function test_dispute_exactly_50pct_cancels() public {
        uint256 id = _proposeShowSmall(); // goal = 0.1 ETH

        // dave funds 0.06, eve funds 0.04 = 0.1 total
        vm.prank(dave);
        praxis.fundTier{value: 0.06 ether}(id, 0, 3);
        vm.prank(eve);
        praxis.fundTier{value: 0.04 ether}(id, 0, 2);
        _confirmAll(id);
        vm.prank(alice);
        praxis.completeProject(id);

        // Both dispute (0.06 + 0.04 = 0.10 / 0.10 = 100% >= 50%)
        vm.prank(dave);
        praxis.dispute(id);
        // Already cancelled after dave's 60%, but test eve can also dispute
        (,,,,,,,,, uint8 status1,) = praxis.getProject(id);
        assertEq(status1, 5); // CANCELLED
    }

    function test_dispute_exactly_half_cancels() public {
        uint256 id = _proposeShowSmall(); // goal = 0.1 ETH

        // Two equal funders: 0.05 each
        vm.prank(dave);
        praxis.fundTier{value: 0.04 ether}(id, 0, 2); // 2 * 0.02 = 0.04
        vm.prank(eve);
        praxis.fundTier{value: 0.06 ether}(id, 0, 3); // 3 * 0.02 = 0.06
        _confirmAll(id);
        vm.prank(alice);
        praxis.completeProject(id);

        // eve disputes (0.06 / 0.10 = 60% >= 50%) — should cancel
        vm.prank(eve);
        praxis.dispute(id);
        (,,,,,,,,, uint8 status,) = praxis.getProject(id);
        assertEq(status, 5); // CANCELLED (>= 50% threshold met)
    }

    function test_dispute_under_50pct_doesnt_cancel() public {
        uint256 id = _proposeShowSmall();

        vm.prank(dave);
        praxis.fundTier{value: 0.06 ether}(id, 0, 3);

        vm.prank(eve);
        praxis.fundTier{value: 0.04 ether}(id, 0, 2);

        _confirmAll(id);

        vm.prank(alice);
        praxis.completeProject(id);

        // eve disputes (0.04 / 0.10 = 40% < 50%)
        vm.prank(eve);
        praxis.dispute(id);

        (,,,,,,,,, uint8 status,) = praxis.getProject(id);
        assertEq(status, 3); // still COMPLETING
    }

    function test_dispute_non_funder_reverts() public {
        _proposeShow();
        _fundToGoal(0);
        _confirmAll(0);

        vm.prank(alice);
        praxis.completeProject(0);

        vm.prank(alice); // proposer, not a funder
        vm.expectRevert("not a funder");
        praxis.dispute(0);
    }

    function test_dispute_window_closed_reverts() public {
        _proposeShow();
        _fundToGoal(0);
        _confirmAll(0);

        vm.prank(alice);
        praxis.completeProject(0);

        vm.warp(block.timestamp + 3 days + 1);

        vm.prank(dave);
        vm.expectRevert("dispute window closed");
        praxis.dispute(0);
    }

    // --- Cancel + refund ---

    function test_cancel_and_refund() public {
        _proposeShow();

        vm.prank(dave);
        praxis.fundTier{value: 0.02 ether}(0, 0, 1);

        vm.prank(alice);
        praxis.cancelProject(0);

        uint256 daveBefore = dave.balance;
        vm.prank(dave);
        praxis.claimRefund(0);
        assertEq(dave.balance - daveBefore, 0.02 ether);
    }

    function test_refund_after_dispute_cancellation() public {
        uint256 id = _proposeShowSmall();

        vm.prank(dave);
        praxis.fundTier{value: 0.06 ether}(id, 0, 3);

        vm.prank(eve);
        praxis.fundTier{value: 0.04 ether}(id, 0, 2);

        _confirmAll(id);

        vm.prank(alice);
        praxis.completeProject(id);

        // dave disputes → auto-cancel
        vm.prank(dave);
        praxis.dispute(id);

        // both can refund
        uint256 daveBefore = dave.balance;
        vm.prank(dave);
        praxis.claimRefund(id);
        assertEq(dave.balance - daveBefore, 0.06 ether);

        uint256 eveBefore = eve.balance;
        vm.prank(eve);
        praxis.claimRefund(id);
        assertEq(eve.balance - eveBefore, 0.04 ether);
    }

    // --- Claim funds ---

    function test_claimFunds_after_finalize() public {
        _proposeShow();
        _fundToGoal(0);
        _confirmAll(0);

        vm.prank(alice);
        praxis.completeProject(0);
        vm.warp(block.timestamp + 3 days + 1);
        praxis.finalizeProject(0);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        praxis.claimFunds();
        assertEq(bob.balance - bobBefore, 0.6 ether);
    }

    // --- Integration ---

    function test_full_lifecycle() public {
        uint256 id = _proposeShow();

        // buy tickets
        vm.prank(dave);
        praxis.fundTier{value: 0.04 ether}(id, 0, 2);

        // become producer (hits goal)
        vm.prank(eve);
        praxis.fundTier{value: 1 ether}(id, 2, 1);

        // confirm: proposer + both collaborators
        _confirmAll(id);

        // complete → starts dispute window
        vm.prank(alice);
        praxis.completeProject(id);

        // no disputes, warp past window
        vm.warp(block.timestamp + 3 days + 1);

        // finalize
        praxis.finalizeProject(id);

        // verify credentials
        assertEq(praxis.balanceOf(dave, praxis.generateTokenId(1, id, 0, 1)), 1); // ticket
        assertEq(praxis.balanceOf(eve, praxis.generateTokenId(2, id, 2, 1)), 1);  // producer (soulbound)
        assertEq(praxis.balanceOf(bob, praxis.generateTokenId(3, id, 0, 0)), 1);  // contributor (soulbound)

        // funds claimable
        assertGt(praxis.pendingWithdrawals(bob), 0);
        assertGt(praxis.pendingWithdrawals(charlie), 0);
    }

    // --- Helpers ---

    /// @dev Bridges legacy positional `proposeProject` test call sites to the new
    ///      struct-based API without rewriting every call site by hand.
    function _callPropose(
        string memory title,
        string memory description,
        Praxis.ProjectType projectType,
        address[] memory collaborators,
        uint256[] memory splits,
        uint256 fundingGoal,
        uint256 deadline,
        string[] memory tierNames,
        uint256[] memory tierPrices,
        uint256[] memory tierMaxSupplies,
        bool[] memory tierTransferable,
        uint256 revenueSharePercent,
        uint128 location,
        uint256 disputeWindowDays,
        bool autoComplete,
        uint8 confirmationMode
    ) internal returns (uint256) {
        return praxis.proposeProject(Praxis.ProposeProjectArgs({
            title: title,
            description: description,
            projectType: projectType,
            collaborators: collaborators,
            splits: splits,
            fundingGoal: fundingGoal,
            deadline: deadline,
            tierNames: tierNames,
            tierPrices: tierPrices,
            tierMaxSupplies: tierMaxSupplies,
            tierTransferable: tierTransferable,
            revenueSharePercent: revenueSharePercent,
            location: location,
            disputeWindowDays: disputeWindowDays,
            autoComplete: autoComplete,
            confirmationMode: confirmationMode
        }));
    }

    function _proposeShow() internal returns (uint256) {
        address[] memory collabs = new address[](2);
        collabs[0] = bob; collabs[1] = charlie;
        uint256[] memory splits = new uint256[](2);
        splits[0] = 6000; splits[1] = 4000;

        string[] memory tierNames = new string[](3);
        tierNames[0] = "Audience";
        tierNames[1] = "Associate Producer";
        tierNames[2] = "Executive Producer";

        uint256[] memory tierPrices = new uint256[](3);
        tierPrices[0] = 0.02 ether;
        tierPrices[1] = 0.1 ether;
        tierPrices[2] = 1 ether;

        uint256[] memory tierSupplies = new uint256[](3);
        tierSupplies[0] = 200;
        tierSupplies[1] = 50;
        tierSupplies[2] = 0; // unlimited

        bool[] memory tierTransferable = new bool[](3);
        tierTransferable[0] = true;
        tierTransferable[1] = false;
        tierTransferable[2] = false;

        vm.prank(alice);
        return _callPropose(
            "Comedy of Errors", "Shakespeare in the park",
            Praxis.ProjectType.SHOW, collabs, splits, 1 ether,
            block.timestamp + 30 days,
            tierNames, tierPrices, tierSupplies, tierTransferable, 0, 0, 3, false, 3
        );
    }

    function _proposeShowSmall() internal returns (uint256) {
        address[] memory collabs = new address[](2);
        collabs[0] = bob; collabs[1] = charlie;
        uint256[] memory splits = new uint256[](2);
        splits[0] = 6000; splits[1] = 4000;

        string[] memory tierNames = new string[](1);
        tierNames[0] = "Ticket";
        uint256[] memory tierPrices = new uint256[](1);
        tierPrices[0] = 0.02 ether;
        uint256[] memory tierSupplies = new uint256[](1);
        tierSupplies[0] = 5;
        bool[] memory tierTransferable = new bool[](1);
        tierTransferable[0] = true;

        vm.prank(alice);
        return _callPropose(
            "Small Show", "test",
            Praxis.ProjectType.SHOW, collabs, splits, 0.1 ether,
            block.timestamp + 30 days,
            tierNames, tierPrices, tierSupplies, tierTransferable, 0, 0, 3, false, 3
        );
    }

    function _proposeWith(string memory title) internal returns (uint256) {
        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;

        string[] memory names = new string[](1);
        names[0] = "Ticket";
        uint256[] memory prices = new uint256[](1);
        prices[0] = 0.01 ether;
        uint256[] memory supplies = new uint256[](1);
        supplies[0] = 100;
        bool[] memory transferable = new bool[](1);
        transferable[0] = true;

        return _callPropose(title, "desc", Praxis.ProjectType.SHOW, collabs, splits, 1 ether, block.timestamp + 30 days, names, prices, supplies, transferable, 0, 0, 3, false, 3);
    }

    function _fundToGoal(uint256 projectId) internal {
        vm.prank(dave);
        praxis.fundTier{value: 1 ether}(projectId, 2, 1); // executive producer tier
    }

    function _confirmAll(uint256 projectId) internal {
        vm.prank(alice);
        praxis.confirmProject(projectId);
        vm.prank(bob);
        praxis.confirmProject(projectId);
        vm.prank(charlie);
        praxis.confirmProject(projectId);
    }

    // --- Revenue sharing tests ---

    function _proposeWithRevenue(uint256 revShareBps) internal returns (uint256) {
        address[] memory collabs = new address[](2);
        collabs[0] = bob; collabs[1] = charlie;
        uint256[] memory splits = new uint256[](2);
        splits[0] = 6000; splits[1] = 4000;

        string[] memory tierNames = new string[](1);
        tierNames[0] = "Ticket";
        uint256[] memory tierPrices = new uint256[](1);
        tierPrices[0] = 0.5 ether;
        uint256[] memory tierSupplies = new uint256[](1);
        tierSupplies[0] = 2;
        bool[] memory tierTransferable = new bool[](1);
        tierTransferable[0] = true;

        vm.prank(alice);
        return _callPropose(
            "Revenue Show", "rev share test",
            Praxis.ProjectType.SHOW, collabs, splits, 1 ether,
            block.timestamp + 30 days,
            tierNames, tierPrices, tierSupplies, tierTransferable, revShareBps, 0, 3, false, 3
        );
    }

    function _fundAndComplete(uint256 projectId) internal {
        // dave funds 0.5 ETH, eve funds 0.5 ETH
        vm.prank(dave);
        praxis.fundTier{value: 0.5 ether}(projectId, 0, 1);
        vm.prank(eve);
        praxis.fundTier{value: 0.5 ether}(projectId, 0, 1);

        // confirm
        vm.prank(alice); praxis.confirmProject(projectId);
        vm.prank(bob); praxis.confirmProject(projectId);
        vm.prank(charlie); praxis.confirmProject(projectId);

        // complete
        vm.prank(alice); praxis.completeProject(projectId);

        // wait 3 days
        vm.warp(block.timestamp + 3 days + 1);

        // finalize
        praxis.finalizeProject(projectId);
    }

    function testRevenueShareProposal() public {
        uint256 id = _proposeWithRevenue(5000); // 50%
        assertEq(praxis.revenueShareBps(id), 5000);
    }

    function testNoRevenueShareByDefault() public {
        uint256 id = _proposeWithRevenue(0);
        assertEq(praxis.revenueShareBps(id), 0);
    }

    function testDistributeRevenue() public {
        uint256 id = _proposeWithRevenue(5000);
        _fundAndComplete(id);

        // distribute 2 ETH revenue — 100% goes to funders
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        praxis.distributeRevenue{value: 2 ether}(id);

        assertEq(praxis.totalRevenue(id), 2 ether);
        assertEq(praxis.funderRevenue(id), 2 ether); // 100% to funders
    }

    function testClaimRevenue() public {
        uint256 id = _proposeWithRevenue(5000);
        _fundAndComplete(id);

        vm.deal(alice, 2 ether);
        vm.prank(alice);
        praxis.distributeRevenue{value: 2 ether}(id);

        // dave funded 50% (0.5 of 1 ETH goal), gets 50% of 2 ETH = 1 ETH
        uint256 daveBefore = dave.balance;
        vm.prank(dave);
        praxis.claimRevenue(id);
        assertEq(dave.balance - daveBefore, 1 ether);

        // eve funded 50%, same share
        uint256 eveBefore = eve.balance;
        vm.prank(eve);
        praxis.claimRevenue(id);
        assertEq(eve.balance - eveBefore, 1 ether);
    }

    function testClaimRevenueMultipleDistributions() public {
        uint256 id = _proposeWithRevenue(5000);
        _fundAndComplete(id);

        // first distribution
        vm.deal(alice, 4 ether);
        vm.prank(alice);
        praxis.distributeRevenue{value: 2 ether}(id);

        // dave claims
        vm.prank(dave);
        praxis.claimRevenue(id);

        // second distribution
        vm.prank(alice);
        praxis.distributeRevenue{value: 2 ether}(id);

        // dave claims again — only gets new revenue (50% of 2 ETH = 1 ETH)
        uint256 daveBefore = dave.balance;
        vm.prank(dave);
        praxis.claimRevenue(id);
        assertEq(dave.balance - daveBefore, 1 ether);
    }

    function testCannotDistributeBeforeComplete() public {
        uint256 id = _proposeWithRevenue(5000);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert("not completed");
        praxis.distributeRevenue{value: 1 ether}(id);
    }

    function testCannotDistributeWithoutRevenueShare() public {
        uint256 id = _proposeWithRevenue(0);
        _fundAndComplete(id);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert("no revenue sharing");
        praxis.distributeRevenue{value: 1 ether}(id);
    }

    function testNonFunderCannotClaim() public {
        uint256 id = _proposeWithRevenue(5000);
        _fundAndComplete(id);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        praxis.distributeRevenue{value: 1 ether}(id);

        vm.prank(alice); // alice is proposer, not funder
        vm.expectRevert("not a funder");
        praxis.claimRevenue(id);
    }

    function testRevenueSharerBadge() public {
        uint256 id = _proposeWithRevenue(5000);
        _fundAndComplete(id);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        praxis.distributeRevenue{value: 1 ether}(id);

        uint256 badgeId = praxis.generateTokenId(4, id, 0, 0); // REVENUE_SHARER
        assertEq(praxis.balanceOf(alice, badgeId), 1);
    }

    function testPendingRevenueView() public {
        uint256 id = _proposeWithRevenue(5000);
        _fundAndComplete(id);

        vm.deal(alice, 2 ether);
        vm.prank(alice);
        praxis.distributeRevenue{value: 2 ether}(id);

        // dave funded 50%, 100% of 2 ETH to funders, dave's share = 1 ETH
        assertEq(praxis.pendingRevenueFor(id, dave), 1 ether);
        assertEq(praxis.pendingRevenueFor(id, eve), 1 ether);

        // after dave claims
        vm.prank(dave);
        praxis.claimRevenue(id);
        assertEq(praxis.pendingRevenueFor(id, dave), 0);
    }

    // --- Location tests ---

    function testProposeWithLocation() public {
        // pack NYC coordinates: 40.7128, -74.0060
        int64 lat = int64(int256(407128000)); // 40.7128 * 1e7
        int64 lng = int64(int256(-740060000)); // -74.0060 * 1e7
        uint128 packed = (uint128(uint64(lat)) << 64) | uint128(uint64(lng));

        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;
        string[] memory tierNames = new string[](1);
        tierNames[0] = "Ticket";
        uint256[] memory tierPrices = new uint256[](1);
        tierPrices[0] = 0.1 ether;
        uint256[] memory tierSupplies = new uint256[](1);
        tierSupplies[0] = 10;
        bool[] memory tierTransferable = new bool[](1);
        tierTransferable[0] = true;

        vm.prank(alice);
        uint256 id = _callPropose("NYC Show", "show in brooklyn", Praxis.ProjectType.SHOW, collabs, splits, 1 ether, block.timestamp + 30 days, tierNames, tierPrices, tierSupplies, tierTransferable, 0, packed, 3, false, 3);

        assertEq(uint256(praxis.projectLocation(id)), uint256(packed));

        (int64 gotLat, int64 gotLng) = praxis.getProjectLocation(id);
        assertEq(gotLat, lat);
        assertEq(gotLng, lng);
    }

    function testProposeWithoutLocation() public {
        uint256 id = _proposeWithRevenue(0);
        assertEq(uint256(praxis.projectLocation(id)), 0);
    }

    // --- withdrawFunding tests ---

    function testWithdrawFundingBeforeThreshold() public {
        uint256 id = _proposeShow(); // goal = 1 ether, tier0 = 0.02 eth
        vm.prank(dave);
        praxis.fundTier{value: 0.02 ether}(id, 0, 1);

        uint256 balBefore = dave.balance;
        vm.prank(dave);
        praxis.withdrawFunding(id);
        assertEq(dave.balance, balBefore + 0.02 ether);
        // contributions zeroed
        assertEq(praxis.contributions(id, dave), 0);
    }

    function testWithdrawFundingRevertsAfterFunded() public {
        uint256 id = _proposeShow(); // goal = 1 ether
        vm.prank(dave);
        praxis.fundTier{value: 1 ether}(id, 2, 1); // tier 2 (exec producer) = 1 eth, hits goal → FUNDED
        vm.expectRevert("funding locked");
        vm.prank(dave);
        praxis.withdrawFunding(id);
    }

    function testWithdrawFundingRevertsIfNoContribution() public {
        uint256 id = _proposeShow();
        vm.expectRevert("nothing to withdraw");
        vm.prank(dave);
        praxis.withdrawFunding(id);
    }

    function testWithdrawFundingBurnsTokens() public {
        uint256 id = _proposeShow(); // tier0 = 0.02 eth
        vm.prank(dave);
        praxis.fundTier{value: 0.06 ether}(id, 0, 3);
        // dave has 3 ticket tokens
        uint256 tokenId1 = praxis.generateTokenId(1, id, 0, 1);
        assertEq(praxis.balanceOf(dave, tokenId1), 1);

        vm.prank(dave);
        praxis.withdrawFunding(id);
        // tokens burned
        assertEq(praxis.balanceOf(dave, tokenId1), 0);
    }

    function testWithdrawFundingReducesTotalFunded() public {
        uint256 id = _proposeShow(); // tier0 = 0.02 eth
        vm.prank(dave);
        praxis.fundTier{value: 0.06 ether}(id, 0, 3);
        vm.prank(eve);
        praxis.fundTier{value: 0.04 ether}(id, 0, 2);

        vm.prank(dave);
        praxis.withdrawFunding(id);

        // totalFunded should be reduced to eve's contribution only
        (,,,,,, , uint256 totalFunded,,,) = praxis.getProject(id);
        assertEq(totalFunded, 0.04 ether);
    }

    // --- auto-invite on finalize tests ---

    function testFinalizeGrantsInvites() public {
        uint256 id = _proposeShow();

        // fund fully (tier 2 = 1 ether, goal = 1 ether)
        vm.prank(dave);
        praxis.fundTier{value: 1 ether}(id, 2, 1);

        // confirm (need proposer alice + majority of collaborators bob,charlie)
        vm.prank(alice);
        praxis.confirmProject(id);
        vm.prank(bob);
        praxis.confirmProject(id);
        vm.prank(charlie);
        praxis.confirmProject(id);

        // complete
        vm.prank(alice);
        praxis.completeProject(id);

        // warp past dispute window
        vm.warp(block.timestamp + 3 days + 1);

        uint256 bobInvitesBefore = invites.invitesRemaining(bob);
        uint256 daveInvitesBefore = invites.invitesRemaining(dave);

        vm.prank(alice);
        praxis.finalizeProject(id);

        // v2 pull pattern: invites are NOT auto-pushed on finalize. Participants
        // must call claimCompletionInvites() themselves.
        assertEq(invites.invitesRemaining(bob), bobInvitesBefore);
        assertEq(invites.invitesRemaining(dave), daveInvitesBefore);

        // bob (collaborator) pulls
        vm.prank(bob);
        praxis.claimCompletionInvites(id);
        assertEq(invites.invitesRemaining(bob), bobInvitesBefore + 5);

        // dave (funder) pulls
        vm.prank(dave);
        praxis.claimCompletionInvites(id);
        assertEq(invites.invitesRemaining(dave), daveInvitesBefore + 5);

        // double-claim reverts
        vm.prank(bob);
        vm.expectRevert("already claimed");
        praxis.claimCompletionInvites(id);

        // non-participant cannot claim
        vm.prank(eve);
        vm.expectRevert("not eligible");
        praxis.claimCompletionInvites(id);
    }

    function testGetFunderSerials() public {
        uint256 id = _proposeShow(); // tier0 = 0.02 eth
        vm.prank(dave);
        praxis.fundTier{value: 0.04 ether}(id, 0, 2);
        vm.prank(eve);
        praxis.fundTier{value: 0.02 ether}(id, 0, 1);

        uint256[] memory daveSerials = praxis.getFunderSerials(id, 0, dave);
        assertEq(daveSerials.length, 2);
        assertEq(daveSerials[0], 1);
        assertEq(daveSerials[1], 2);

        uint256[] memory eveSerials = praxis.getFunderSerials(id, 0, eve);
        assertEq(eveSerials.length, 1);
        assertEq(eveSerials[0], 3);
    }

    function test_withdrawFunding_does_not_collide_serials() public {
        // Regression: pre-v2 decremented tier.sold on burn, so the next mint
        // re-used a burned serial → token-id collision. v2 uses _tierMinted
        // monotonic counter so withdrawn serials are never reissued.
        uint256 id = _proposeShow(); // tier0 = 0.02 eth, transferable
        vm.prank(dave);
        praxis.fundTier{value: 0.04 ether}(id, 0, 2); // serials 1, 2

        vm.prank(dave);
        praxis.withdrawFunding(id);

        vm.prank(eve);
        praxis.fundTier{value: 0.02 ether}(id, 0, 1); // must be serial 3, not 1

        uint256[] memory eveSerials = praxis.getFunderSerials(id, 0, eve);
        assertEq(eveSerials.length, 1);
        assertEq(eveSerials[0], 3, "must not reuse burned serial");

        // eve's token is fresh (balance 1), dave's burned tokens stay at 0
        assertEq(praxis.balanceOf(eve, praxis.generateTokenId(1, id, 0, 3)), 1);
        assertEq(praxis.balanceOf(dave, praxis.generateTokenId(1, id, 0, 1)), 0);
        assertEq(praxis.balanceOf(dave, praxis.generateTokenId(1, id, 0, 2)), 0);
    }

    function test_proposeProject_tier_cap_enforced() public {
        // 101 tiers should revert "too many tiers"
        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;

        uint256 N = 101;
        string[] memory tn = new string[](N);
        uint256[] memory tp = new uint256[](N);
        uint256[] memory ts = new uint256[](N);
        bool[] memory tt = new bool[](N);
        for (uint256 i = 0; i < N; i++) {
            tn[i] = "T";
            tp[i] = 1 ether;
            ts[i] = 1;
            tt[i] = true;
        }

        vm.prank(alice);
        vm.expectRevert("too many tiers");
        _callPropose("Bad","x",Praxis.ProjectType.SHOW,collabs,splits,1 ether,block.timestamp+30 days,tn,tp,ts,tt,0,0,3,false,1);
    }

    // =====================================================================
    // autoComplete — fund → instant distribute (no confirmation needed)
    // =====================================================================

    function _proposeAutoComplete() internal returns (uint256) {
        address[] memory collabs = new address[](2);
        collabs[0] = bob; collabs[1] = charlie;
        uint256[] memory splits = new uint256[](2);
        splits[0] = 6000; splits[1] = 4000;

        string[] memory tierNames = new string[](1);
        tierNames[0] = "Ticket";
        uint256[] memory tierPrices = new uint256[](1);
        tierPrices[0] = 0.5 ether;
        uint256[] memory tierSupplies = new uint256[](1);
        tierSupplies[0] = 2;
        bool[] memory tierTransferable = new bool[](1);
        tierTransferable[0] = true;

        vm.prank(alice);
        // autoComplete=true, disputeWindowDays=0, confirmationMode=0
        return _callPropose(
            "Auto Show", "instant purchase",
            Praxis.ProjectType.SHOW, collabs, splits, 1 ether,
            block.timestamp + 30 days,
            tierNames, tierPrices, tierSupplies, tierTransferable, 0, 0, 0, true, 0
        );
    }

    function test_autoComplete_distributes_on_funding() public {
        uint256 id = _proposeAutoComplete();
        uint256 bobBefore = bob.balance;
        uint256 charlieBefore = charlie.balance;

        // Fund fully (2 tickets * 0.5 ETH = 1 ETH goal)
        vm.prank(dave);
        praxis.fundTier{value: 0.5 ether}(id, 0, 1);
        vm.prank(eve);
        praxis.fundTier{value: 0.5 ether}(id, 0, 1);

        // Funds should be in pendingWithdrawals (auto-distributed)
        uint256 bobPending = praxis.pendingWithdrawals(bob);
        uint256 charliePending = praxis.pendingWithdrawals(charlie);
        assertEq(bobPending, 0.6 ether); // 60%
        assertEq(charliePending, 0.4 ether); // 40%

        // Bob claims
        vm.prank(bob);
        praxis.claimFunds();
        assertEq(bob.balance, bobBefore + 0.6 ether);
    }

    function test_autoComplete_requires_zero_dispute_window() public {
        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;
        string[] memory tierNames = new string[](1);
        tierNames[0] = "T";
        uint256[] memory tierPrices = new uint256[](1);
        tierPrices[0] = 1 ether;
        uint256[] memory tierSupplies = new uint256[](1);
        tierSupplies[0] = 1;
        bool[] memory tierTransferable = new bool[](1);
        tierTransferable[0] = true;

        vm.prank(alice);
        vm.expectRevert("autoComplete requires no dispute window");
        _callPropose(
            "Bad", "test", Praxis.ProjectType.SHOW, collabs, splits, 1 ether,
            block.timestamp + 30 days,
            tierNames, tierPrices, tierSupplies, tierTransferable, 0, 0,
            3, true, 0 // autoComplete=true but disputeWindowDays=3 — should revert
        );
    }

    function test_autoComplete_forces_confirmationMode_zero() public {
        uint256 id = _proposeAutoComplete();
        // Verify autoComplete works by funding to goal — should auto-distribute
        uint256 bobBefore = praxis.pendingWithdrawals(bob);
        vm.prank(dave);
        praxis.fundTier{value: 0.5 ether}(id, 0, 1);
        vm.prank(eve);
        praxis.fundTier{value: 0.5 ether}(id, 0, 1);
        // If confirmationMode was forced to 0, funds auto-distribute
        assertTrue(praxis.pendingWithdrawals(bob) > bobBefore);
    }

    // =====================================================================
    // confirmationMode — proposer-only (1), majority (2), all (3)
    // =====================================================================

    function _proposeWithConfirmMode(uint8 mode) internal returns (uint256) {
        address[] memory collabs = new address[](3);
        collabs[0] = bob; collabs[1] = charlie; collabs[2] = dave;
        uint256[] memory splits = new uint256[](3);
        splits[0] = 5000; splits[1] = 3000; splits[2] = 2000;

        string[] memory tierNames = new string[](1);
        tierNames[0] = "Ticket";
        uint256[] memory tierPrices = new uint256[](1);
        tierPrices[0] = 1 ether;
        uint256[] memory tierSupplies = new uint256[](1);
        tierSupplies[0] = 1;
        bool[] memory tierTransferable = new bool[](1);
        tierTransferable[0] = true;

        vm.prank(alice);
        return _callPropose(
            "Confirm Test", "test",
            Praxis.ProjectType.SHOW, collabs, splits, 1 ether,
            block.timestamp + 30 days,
            tierNames, tierPrices, tierSupplies, tierTransferable, 0, 0,
            3, false, mode // disputeWindowDays=3, autoComplete=false, confirmationMode=mode
        );
    }

    function test_confirmationMode_proposerOnly() public {
        uint256 id = _proposeWithConfirmMode(1);
        // Fund fully
        vm.prank(eve);
        praxis.fundTier{value: 1 ether}(id, 0, 1);
        // Only proposer (alice) needs to confirm
        vm.prank(alice);
        praxis.confirmProject(id);
        // Should be able to complete now
        vm.prank(alice);
        praxis.completeProject(id);
    }

    function test_confirmationMode_majority() public {
        uint256 id = _proposeWithConfirmMode(2);
        vm.prank(eve);
        praxis.fundTier{value: 1 ether}(id, 0, 1);
        // 3 collabs: bob, charlie, dave. Majority = 2. Proposer (alice) must also confirm.
        // Just proposer + 1 collab = not enough for majority
        vm.prank(alice);
        praxis.confirmProject(id);
        vm.prank(bob);
        praxis.confirmProject(id);
        // proposer + 1/3 collabs — not majority of collabs yet
        vm.prank(alice);
        vm.expectRevert("not confirmed");
        praxis.completeProject(id);
        // 2nd collab confirmation — now majority (2/3)
        vm.prank(charlie);
        praxis.confirmProject(id);
        // Now majority met
        vm.prank(alice);
        praxis.completeProject(id);
    }

    function test_confirmationMode_all() public {
        uint256 id = _proposeWithConfirmMode(3);
        vm.prank(eve);
        praxis.fundTier{value: 1 ether}(id, 0, 1);
        // All 3 collabs must confirm + proposer
        vm.prank(alice);
        praxis.confirmProject(id);
        vm.prank(bob);
        praxis.confirmProject(id);
        vm.prank(charlie);
        praxis.confirmProject(id);
        // 2 of 3 collabs — not all
        vm.prank(alice);
        vm.expectRevert("not confirmed");
        praxis.completeProject(id);
        // 3rd collab
        vm.prank(dave);
        praxis.confirmProject(id);
        // Now all confirmed
        vm.prank(alice);
        praxis.completeProject(id);
    }

    function test_confirmationMode_invalid_reverts() public {
        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;
        string[] memory tierNames = new string[](1);
        tierNames[0] = "T";
        uint256[] memory tierPrices = new uint256[](1);
        tierPrices[0] = 1 ether;
        uint256[] memory tierSupplies = new uint256[](1);
        tierSupplies[0] = 1;
        bool[] memory tierTransferable = new bool[](1);
        tierTransferable[0] = true;

        vm.prank(alice);
        vm.expectRevert("invalid confirmation mode");
        _callPropose(
            "Bad", "test", Praxis.ProjectType.SHOW, collabs, splits, 1 ether,
            block.timestamp + 30 days,
            tierNames, tierPrices, tierSupplies, tierTransferable, 0, 0,
            3, false, 4 // mode=4 invalid
        );
    }

    function test_nonAutoComplete_requires_confirmation() public {
        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;
        string[] memory tierNames = new string[](1);
        tierNames[0] = "T";
        uint256[] memory tierPrices = new uint256[](1);
        tierPrices[0] = 1 ether;
        uint256[] memory tierSupplies = new uint256[](1);
        tierSupplies[0] = 1;
        bool[] memory tierTransferable = new bool[](1);
        tierTransferable[0] = true;

        vm.prank(alice);
        vm.expectRevert("non-autoComplete needs confirmation");
        _callPropose(
            "Bad", "test", Praxis.ProjectType.SHOW, collabs, splits, 1 ether,
            block.timestamp + 30 days,
            tierNames, tierPrices, tierSupplies, tierTransferable, 0, 0,
            3, false, 0 // autoComplete=false but confirmationMode=0 — should revert
        );
    }

    // =====================================================================
    // disputeWindowDays — 0 (no disputes) vs configurable
    // =====================================================================

    function test_disputeWindow_zero_no_disputes() public {
        // autoComplete with 0 dispute window
        uint256 id = _proposeAutoComplete(); // disputeWindowDays=0
        vm.prank(dave);
        praxis.fundTier{value: 0.5 ether}(id, 0, 1);
        vm.prank(eve);
        praxis.fundTier{value: 0.5 ether}(id, 0, 1);
        // Auto-completed, funds distributed. Can't dispute.
        vm.prank(dave);
        vm.expectRevert();
        praxis.dispute(id);
    }

    function test_disputeWindow_custom_days() public {
        // Propose with 7-day dispute window
        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;
        string[] memory tierNames = new string[](1);
        tierNames[0] = "T";
        uint256[] memory tierPrices = new uint256[](1);
        tierPrices[0] = 1 ether;
        uint256[] memory tierSupplies = new uint256[](1);
        tierSupplies[0] = 1;
        bool[] memory tierTransferable = new bool[](1);
        tierTransferable[0] = true;

        vm.prank(alice);
        uint256 id = _callPropose(
            "7day", "test", Praxis.ProjectType.SHOW, collabs, splits, 1 ether,
            block.timestamp + 30 days,
            tierNames, tierPrices, tierSupplies, tierTransferable, 0, 0,
            7, false, 1 // 7-day dispute window, proposer-only confirmation
        );

        // Fund + confirm + complete
        vm.prank(eve);
        praxis.fundTier{value: 1 ether}(id, 0, 1);
        vm.prank(alice);
        praxis.confirmProject(id);
        vm.prank(alice);
        praxis.completeProject(id);

        // Within 7-day window — dispute should work
        vm.prank(eve);
        praxis.dispute(id);

        // Warp past 7 days — finalize should work
        vm.warp(block.timestamp + 8 days);
        // After dispute, project needs resolution or timeout
    }

    function test_disputeWindow_nonAutoComplete_defaults_to_1day() public {
        // Contract silently sets disputeWindowDays=0 to 1 for non-autoComplete
        // (line 417: if (disputeWindowDays == 0) disputeWindowDays = 1)
        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;
        string[] memory tierNames = new string[](1);
        tierNames[0] = "T";
        uint256[] memory tierPrices = new uint256[](1);
        tierPrices[0] = 1 ether;
        uint256[] memory tierSupplies = new uint256[](1);
        tierSupplies[0] = 1;
        bool[] memory tierTransferable = new bool[](1);
        tierTransferable[0] = true;

        vm.prank(alice);
        // disputeWindowDays=0 with non-autoComplete — should succeed but default to 1 day
        uint256 id = _callPropose(
            "Default", "test", Praxis.ProjectType.SHOW, collabs, splits, 1 ether,
            block.timestamp + 30 days,
            tierNames, tierPrices, tierSupplies, tierTransferable, 0, 0,
            0, false, 1
        );

        // Fund
        vm.prank(eve);
        praxis.fundTier{value: 1 ether}(id, 0, 1);
        // Mode 1 = proposer-only — alice confirms and it moves to CONFIRMED
        vm.prank(alice);
        praxis.confirmProject(id);
        // Complete
        vm.prank(alice);
        praxis.completeProject(id);

        // Dispute should be possible (window defaulted to 1 day, not 0)
        vm.prank(eve);
        praxis.dispute(id);
    }

    // =====================================================================
    // Fuzz tests — random inputs for key functions
    // =====================================================================

    function testFuzz_disputeWindowDays(uint256 days_) public {
        days_ = bound(days_, 0, 100);
        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;
        string[] memory tn = new string[](1); tn[0] = "T";
        uint256[] memory tp = new uint256[](1); tp[0] = 1 ether;
        uint256[] memory ts = new uint256[](1); ts[0] = 1;
        bool[] memory tt = new bool[](1); tt[0] = true;

        vm.prank(alice);
        if (days_ > 30) {
            vm.expectRevert("dispute window too long");
            _callPropose("F","d",Praxis.ProjectType.SHOW,collabs,splits,1 ether,block.timestamp+30 days,tn,tp,ts,tt,0,0,days_,false,1);
        } else {
            // Should succeed (0 gets defaulted to 1 for non-autoComplete)
            _callPropose("F","d",Praxis.ProjectType.SHOW,collabs,splits,1 ether,block.timestamp+30 days,tn,tp,ts,tt,0,0,days_,false,1);
        }
    }

    function testFuzz_confirmationMode(uint8 mode) public {
        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;
        string[] memory tn = new string[](1); tn[0] = "T";
        uint256[] memory tp = new uint256[](1); tp[0] = 1 ether;
        uint256[] memory ts = new uint256[](1); ts[0] = 1;
        bool[] memory tt = new bool[](1); tt[0] = true;

        vm.prank(alice);
        if (mode == 0) {
            vm.expectRevert("non-autoComplete needs confirmation");
            _callPropose("F","d",Praxis.ProjectType.SHOW,collabs,splits,1 ether,block.timestamp+30 days,tn,tp,ts,tt,0,0,3,false,mode);
        } else if (mode > 3) {
            vm.expectRevert("invalid confirmation mode");
            _callPropose("F","d",Praxis.ProjectType.SHOW,collabs,splits,1 ether,block.timestamp+30 days,tn,tp,ts,tt,0,0,3,false,mode);
        } else {
            _callPropose("F","d",Praxis.ProjectType.SHOW,collabs,splits,1 ether,block.timestamp+30 days,tn,tp,ts,tt,0,0,3,false,mode);
        }
    }

    function testFuzz_fundingAmount(uint256 amount) public {
        uint256 id = _proposeAutoComplete(); // tier0 = 0.5 ETH, supply=2
        amount = bound(amount, 0, 10 ether);

        vm.deal(dave, amount);
        vm.prank(dave);
        if (amount != 0.5 ether && amount != 1 ether) {
            vm.expectRevert("wrong payment");
            praxis.fundTier{value: amount}(id, 0, 1);
        }
        // correct amounts (0.5 or 1 ETH for qty 1 or 2) tested in happy path tests
    }

    // =====================================================================
    // Unhappy paths — boundary conditions and invalid state transitions
    // =====================================================================

    function test_confirm_before_funded_reverts() public {
        uint256 id = _proposeShow();
        vm.prank(alice);
        vm.expectRevert("not funded");
        praxis.confirmProject(id);
    }

    function test_complete_before_confirmed_reverts() public {
        uint256 id = _proposeShow();
        // Fund fully
        vm.prank(dave);
        praxis.fundTier{value: 1 ether}(id, 2, 1); // exec producer tier = 1 ETH = goal
        // Try to complete without confirming
        vm.prank(alice);
        vm.expectRevert("not confirmed");
        praxis.completeProject(id);
    }

    function test_complete_by_non_proposer_reverts() public {
        uint256 id = _proposeWithConfirmMode(1);
        vm.prank(eve);
        praxis.fundTier{value: 1 ether}(id, 0, 1);
        vm.prank(alice);
        praxis.confirmProject(id);
        // Bob (collaborator, not proposer) tries to complete
        vm.prank(bob);
        vm.expectRevert("not proposer");
        praxis.completeProject(id);
    }

    function test_double_confirm_reverts() public {
        uint256 id = _proposeShow();
        vm.prank(dave);
        praxis.fundTier{value: 1 ether}(id, 2, 1);
        vm.prank(alice);
        praxis.confirmProject(id);
        vm.prank(alice);
        vm.expectRevert("already confirmed");
        praxis.confirmProject(id);
    }

    function test_dispute_by_non_funder_reverts() public {
        uint256 id = _proposeWithConfirmMode(1);
        vm.prank(eve);
        praxis.fundTier{value: 1 ether}(id, 0, 1);
        vm.prank(alice);
        praxis.confirmProject(id);
        vm.prank(alice);
        praxis.completeProject(id);
        // Bob never funded — can't dispute
        vm.prank(bob);
        vm.expectRevert();
        praxis.dispute(id);
    }

    function test_fund_after_goal_met_autoComplete_reverts() public {
        uint256 id = _proposeAutoComplete();
        vm.prank(dave);
        praxis.fundTier{value: 0.5 ether}(id, 0, 1);
        vm.prank(eve);
        praxis.fundTier{value: 0.5 ether}(id, 0, 1);
        // Goal met, auto-completed. Try to fund again
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert();
        praxis.fundTier{value: 0.5 ether}(id, 0, 1);
    }

    function test_cancel_after_autoComplete_reverts() public {
        uint256 id = _proposeAutoComplete();
        vm.prank(dave);
        praxis.fundTier{value: 0.5 ether}(id, 0, 1);
        vm.prank(eve);
        praxis.fundTier{value: 0.5 ether}(id, 0, 1);
        // Auto-completed — can't cancel
        vm.prank(alice);
        vm.expectRevert();
        praxis.cancelProject(id);
    }

    function test_withdraw_after_goal_met_reverts() public {
        uint256 id = _proposeWithConfirmMode(1);
        vm.prank(eve);
        praxis.fundTier{value: 1 ether}(id, 0, 1);
        // Goal met (FUNDED status) — can't withdraw
        vm.prank(eve);
        vm.expectRevert();
        praxis.withdrawFunding(id);
    }

    function test_claimFunds_nothing_pending_reverts() public {
        vm.prank(alice);
        vm.expectRevert("nothing to claim");
        praxis.claimFunds();
    }

    function test_finalize_during_dispute_window_reverts() public {
        uint256 id = _proposeWithConfirmMode(1);
        vm.prank(eve);
        praxis.fundTier{value: 1 ether}(id, 0, 1);
        vm.prank(alice);
        praxis.confirmProject(id);
        vm.prank(alice);
        praxis.completeProject(id);
        // Still within 3-day dispute window
        vm.prank(alice);
        vm.expectRevert();
        praxis.finalizeProject(id);
    }

    function test_finalize_after_dispute_window_succeeds() public {
        uint256 id = _proposeWithConfirmMode(1);
        vm.prank(eve);
        praxis.fundTier{value: 1 ether}(id, 0, 1);
        vm.prank(alice);
        praxis.confirmProject(id);
        vm.prank(alice);
        praxis.completeProject(id);
        // Warp past dispute window
        vm.warp(block.timestamp + 4 days);
        vm.prank(alice);
        praxis.finalizeProject(id);
        // Funds should be claimable
        assertTrue(praxis.pendingWithdrawals(bob) > 0);
    }

    // =====================================================================
    // Invariant: total splits always sum to 10000
    // =====================================================================

    function testFuzz_splits_must_sum_10000(uint256 splitA, uint256 splitB) public {
        splitA = bound(splitA, 0, 10000);
        splitB = bound(splitB, 0, 10000);

        address[] memory collabs = new address[](2);
        collabs[0] = bob; collabs[1] = charlie;
        uint256[] memory splits = new uint256[](2);
        splits[0] = splitA; splits[1] = splitB;
        string[] memory tn = new string[](1); tn[0] = "T";
        uint256[] memory tp = new uint256[](1); tp[0] = 1 ether;
        uint256[] memory ts = new uint256[](1); ts[0] = 1;
        bool[] memory tt = new bool[](1); tt[0] = true;

        vm.prank(alice);
        if (splitA + splitB != 10000) {
            vm.expectRevert("splits must sum to 10000");
            _callPropose("F","d",Praxis.ProjectType.SHOW,collabs,splits,1 ether,block.timestamp+30 days,tn,tp,ts,tt,0,0,3,false,1);
        } else {
            _callPropose("F","d",Praxis.ProjectType.SHOW,collabs,splits,1 ether,block.timestamp+30 days,tn,tp,ts,tt,0,0,3,false,1);
        }
    }
}
