// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../ArtistRegistry.sol";
import "../ArtistSponsoredInvites.sol";

contract ArtistSponsoredInvitesTest is Test {
    ArtistRegistry registry;
    ArtistSponsoredInvites sponsor;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    // Orchestrator EOA used to sign EIP-712 redemption authorizations
    uint256 orchestratorPk = 0xA11CE;
    address orchestratorAddr;

    uint256 FEE = 0.005 ether;
    uint256 GAS_BUF = 0.001 ether;
    uint256 AMOUNT = FEE + GAS_BUF;

    bytes32 constant REDEEM_TYPEHASH =
        keccak256("Redeem(bytes32 codeHash,address recipient,uint256 expiry,bytes32 nonce)");

    function setUp() public {
        registry = new ArtistRegistry();
        registry.setDeployFee(0.005 ether); // Set deploy fee so sponsor amount works
        sponsor = new ArtistSponsoredInvites(address(registry));

        // Wire the orchestrator on the registry so the contract verifies our sigs
        orchestratorAddr = vm.addr(orchestratorPk);
        registry.setOrchestrator(orchestratorAddr);

        registry.registerDirect(alice, "alice.xyz");
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    /// @dev Build EIP-712 digest + sign with orchestratorPk; returns args for redeem()
    function _signRedeem(string memory code, address recipient)
        internal
        view
        returns (uint256 expiry, bytes32 nonce, bytes memory sig)
    {
        expiry = block.timestamp + 30 minutes;
        nonce = keccak256(abi.encodePacked(code, recipient, expiry, block.number));
        bytes32 codeHash = keccak256(abi.encodePacked(code));
        bytes32 structHash = keccak256(abi.encode(REDEEM_TYPEHASH, codeHash, recipient, expiry, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", sponsor.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orchestratorPk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _redeem(string memory code, address recipient) internal {
        (uint256 expiry, bytes32 nonce, bytes memory sig) = _signRedeem(code, recipient);
        vm.prank(recipient);
        sponsor.redeem(code, expiry, nonce, sig);
    }

    // --- Deposit ---

    function test_deposit() public {
        vm.prank(alice);
        sponsor.deposit{value: AMOUNT * 3}(3, 0);
        assertEq(sponsor.availableSlots(alice), 3);
        assertEq(address(sponsor).balance, AMOUNT * 3);
    }

    function test_deposit_wrong_value_reverts() public {
        vm.prank(alice);
        vm.expectRevert("wrong value");
        sponsor.deposit{value: 0.01 ether}(3, 0);
    }

    function test_deposit_zero_count_reverts() public {
        vm.prank(alice);
        vm.expectRevert("count must be > 0");
        sponsor.deposit{value: 0}(0, 0);
    }

    function test_deposit_non_artist_reverts() public {
        vm.prank(bob);
        vm.expectRevert("not registered artist");
        sponsor.deposit{value: AMOUNT}(1, 0);
    }

    // --- Sponsor invite ---

    function test_sponsorInvite() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        bytes32 hash = keccak256(abi.encodePacked("testcode123"));
        sponsor.sponsorInvite(hash);
        vm.stopPrank();

        assertEq(sponsor.availableSlots(alice), 0);
        assertEq(sponsor.sponsorOf(hash), alice);
    }

    function test_sponsorInvite_no_slots_reverts() public {
        vm.prank(alice);
        vm.expectRevert("no slots");
        sponsor.sponsorInvite(keccak256("code"));
    }

    function test_sponsorInvite_duplicate_reverts() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT * 2}(2, 0);
        bytes32 hash = keccak256("code");
        sponsor.sponsorInvite(hash);
        vm.expectRevert("already sponsored");
        sponsor.sponsorInvite(hash);
        vm.stopPrank();
    }

    // --- Batch sponsor ---

    function test_sponsorInvites_batch() public {
        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = keccak256("a");
        hashes[1] = keccak256("b");
        hashes[2] = keccak256("c");

        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT * 3}(3, 0);
        sponsor.sponsorInvites(hashes);
        vm.stopPrank();

        assertEq(sponsor.availableSlots(alice), 0);
        assertEq(sponsor.sponsorOf(hashes[0]), alice);
        assertEq(sponsor.sponsorOf(hashes[1]), alice);
        assertEq(sponsor.sponsorOf(hashes[2]), alice);
    }

    function test_sponsorInvites_batch_too_large_reverts() public {
        // Cap is 100 — 101 should revert
        bytes32[] memory hashes = new bytes32[](101);
        for (uint256 i = 0; i < 101; i++) {
            hashes[i] = keccak256(abi.encodePacked("k", i));
        }
        vm.prank(alice);
        vm.expectRevert("batch out of range");
        sponsor.sponsorInvites(hashes);
    }

    function test_sponsorInvites_batch_empty_reverts() public {
        bytes32[] memory hashes = new bytes32[](0);
        vm.prank(alice);
        vm.expectRevert("batch out of range");
        sponsor.sponsorInvites(hashes);
    }

    // --- Redeem ---

    function test_redeem() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        bytes32 hash = keccak256(abi.encodePacked("mycode"));
        sponsor.sponsorInvite(hash);
        vm.stopPrank();

        uint256 bobBefore = bob.balance;

        // Recipient redeems (sends to msg.sender) — orchestrator-signed
        _redeem("mycode", bob);

        assertEq(bob.balance, bobBefore + AMOUNT);
        assertTrue(sponsor.redeemed(hash));
        assertEq(address(sponsor).balance, 0);
    }

    function test_redeem_not_sponsored_reverts() public {
        (uint256 expiry, bytes32 nonce, bytes memory sig) = _signRedeem("unknown", address(this));
        vm.expectRevert("not sponsored");
        sponsor.redeem("unknown", expiry, nonce, sig);
    }

    function test_redeem_double_reverts() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        sponsor.sponsorInvite(keccak256(abi.encodePacked("code2")));
        vm.stopPrank();

        _redeem("code2", bob);

        // Second redemption attempt: charlie needs their own signature.
        (uint256 expiry, bytes32 nonce, bytes memory sig) = _signRedeem("code2", charlie);
        vm.prank(charlie);
        vm.expectRevert("already redeemed");
        sponsor.redeem("code2", expiry, nonce, sig);
    }

    function test_redeem_zero_recipient_reverts() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        sponsor.sponsorInvite(keccak256(abi.encodePacked("code3")));
        vm.stopPrank();

        // redeem now sends to msg.sender, so no zero-recipient test needed
        // instead test that non-sponsored code reverts
        (uint256 expiry, bytes32 nonce, bytes memory sig) = _signRedeem("nonexistent", address(this));
        vm.expectRevert("not sponsored");
        sponsor.redeem("nonexistent", expiry, nonce, sig);
    }

    // --- EIP-712 redemption hardening ---

    function test_redeem_invalid_signer_reverts() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        sponsor.sponsorInvite(keccak256(abi.encodePacked("badsig")));
        vm.stopPrank();

        // Sign with a wrong key (not the orchestrator)
        uint256 expiry = block.timestamp + 30 minutes;
        bytes32 nonce = keccak256("nonce-badsig");
        bytes32 codeHash = keccak256(abi.encodePacked("badsig"));
        bytes32 structHash = keccak256(abi.encode(REDEEM_TYPEHASH, codeHash, bob, expiry, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", sponsor.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBEEF, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(bob);
        vm.expectRevert("invalid orch sig");
        sponsor.redeem("badsig", expiry, nonce, sig);
    }

    function test_redeem_recipient_substitution_reverts() public {
        // Front-run protection: orchestrator signs for bob, eve cannot use the sig.
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        sponsor.sponsorInvite(keccak256(abi.encodePacked("frontrun")));
        vm.stopPrank();

        (uint256 expiry, bytes32 nonce, bytes memory sig) = _signRedeem("frontrun", bob);

        vm.prank(charlie); // mempool watcher
        vm.expectRevert("invalid orch sig");
        sponsor.redeem("frontrun", expiry, nonce, sig);
    }

    function test_redeem_expired_reverts() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        sponsor.sponsorInvite(keccak256(abi.encodePacked("expiredcode")));
        vm.stopPrank();

        (uint256 expiry, bytes32 nonce, bytes memory sig) = _signRedeem("expiredcode", bob);
        vm.warp(expiry + 1);
        vm.prank(bob);
        vm.expectRevert("expired");
        sponsor.redeem("expiredcode", expiry, nonce, sig);
    }

    function test_redeem_nonce_replay_reverts() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT * 2}(2, 0);
        sponsor.sponsorInvite(keccak256(abi.encodePacked("replay1")));
        sponsor.sponsorInvite(keccak256(abi.encodePacked("replay2")));
        vm.stopPrank();

        // Redeem replay1 successfully with a fixed nonce
        uint256 expiry = block.timestamp + 30 minutes;
        bytes32 nonce = keccak256("shared-nonce");
        bytes32 codeHash1 = keccak256(abi.encodePacked("replay1"));
        bytes32 sh1 = keccak256(abi.encode(REDEEM_TYPEHASH, codeHash1, bob, expiry, nonce));
        bytes32 d1 = keccak256(abi.encodePacked("\x19\x01", sponsor.DOMAIN_SEPARATOR(), sh1));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(orchestratorPk, d1);

        vm.prank(bob);
        sponsor.redeem("replay1", expiry, nonce, abi.encodePacked(r1, s1, v1));

        // Now attempt to reuse the same nonce on replay2 (different sig but same nonce)
        bytes32 codeHash2 = keccak256(abi.encodePacked("replay2"));
        bytes32 sh2 = keccak256(abi.encode(REDEEM_TYPEHASH, codeHash2, charlie, expiry, nonce));
        bytes32 d2 = keccak256(abi.encodePacked("\x19\x01", sponsor.DOMAIN_SEPARATOR(), sh2));
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(orchestratorPk, d2);

        vm.prank(charlie);
        vm.expectRevert("nonce used");
        sponsor.redeem("replay2", expiry, nonce, abi.encodePacked(r2, s2, v2));
    }

    function test_redeem_expiry_too_far_reverts() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        sponsor.sponsorInvite(keccak256(abi.encodePacked("farfuture")));
        vm.stopPrank();

        uint256 expiry = block.timestamp + 2 hours; // > MAX_VALIDITY (1h)
        bytes32 nonce = keccak256("nonce-farfuture");
        bytes32 codeHash = keccak256(abi.encodePacked("farfuture"));
        bytes32 structHash = keccak256(abi.encode(REDEEM_TYPEHASH, codeHash, bob, expiry, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", sponsor.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orchestratorPk, digest);

        vm.prank(bob);
        vm.expectRevert("expiry too far");
        sponsor.redeem("farfuture", expiry, nonce, abi.encodePacked(r, s, v));
    }

    function test_setPaused_blocks_redeem() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        sponsor.sponsorInvite(keccak256(abi.encodePacked("paused")));
        vm.stopPrank();

        // deployer of sponsor is `address(this)` (the test contract). registry.deployer()
        // is also address(this) since the test deployed the registry. Sponsor uses
        // REGISTRY.deployer() for auth, so we are authorized.
        sponsor.setPaused(true);
        assertTrue(sponsor.paused());

        (uint256 expiry, bytes32 nonce, bytes memory sig) = _signRedeem("paused", bob);
        vm.prank(bob);
        vm.expectRevert("paused");
        sponsor.redeem("paused", expiry, nonce, sig);

        // Unpause and confirm it works again
        sponsor.setPaused(false);
        vm.prank(bob);
        sponsor.redeem("paused", expiry, nonce, sig);
    }

    function test_setPaused_unauthorized_reverts() public {
        vm.prank(bob);
        vm.expectRevert("not authorized");
        sponsor.setPaused(true);
    }

    // --- activeSponsor view ---

    function test_activeSponsor() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        bytes32 hash = keccak256(abi.encodePacked("viewtest"));
        sponsor.sponsorInvite(hash);
        vm.stopPrank();

        assertEq(sponsor.activeSponsor(hash), alice);

        // after redemption, returns zero
        _redeem("viewtest", bob);
        assertEq(sponsor.activeSponsor(hash), address(0));
    }

    // --- Refund slots ---

    function test_refundSlots() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT * 5}(5, 0);

        uint256 balBefore = alice.balance;
        sponsor.refundSlots(3);

        assertEq(sponsor.availableSlots(alice), 2);
        assertEq(alice.balance, balBefore + AMOUNT * 3);
        vm.stopPrank();
    }

    function test_refundSlots_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert("invalid count");
        sponsor.refundSlots(0);
    }

    function test_refundSlots_over_available_reverts() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        vm.expectRevert("invalid count");
        sponsor.refundSlots(2);
        vm.stopPrank();
    }

    // --- Revoke invite ---

    function test_revokeInvite() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        bytes32 hash = keccak256("revokeme");
        sponsor.sponsorInvite(hash);

        uint256 balBefore = alice.balance;
        sponsor.revokeInvite(hash);

        assertEq(sponsor.sponsorOf(hash), address(0));
        assertEq(alice.balance, balBefore + AMOUNT);
        vm.stopPrank();
    }

    function test_revokeInvite_not_yours_reverts() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        bytes32 hash = keccak256("notbobs");
        sponsor.sponsorInvite(hash);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert("not your invite");
        sponsor.revokeInvite(hash);
    }

    function test_revokeInvite_already_redeemed_reverts() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        bytes32 hash = keccak256(abi.encodePacked("redeemed"));
        sponsor.sponsorInvite(hash);
        vm.stopPrank();

        _redeem("redeemed", bob);

        vm.prank(alice);
        vm.expectRevert("already redeemed");
        sponsor.revokeInvite(hash);
    }

    // --- Zero hash protection ---

    function test_sponsorInvite_zero_hash_reverts() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        vm.expectRevert("zero hash");
        sponsor.sponsorInvite(bytes32(0));
        vm.stopPrank();
    }

    function test_sponsorInvites_batch_zero_hash_reverts() public {
        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = keccak256("a");
        hashes[1] = bytes32(0); // zero hash in the middle
        hashes[2] = keccak256("c");

        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT * 3}(3, 0);
        vm.expectRevert("zero hash");
        sponsor.sponsorInvites(hashes);
        vm.stopPrank();
    }

    // --- Full flow: deposit → sponsor → redeem ---

    function test_full_flow() public {
        // Alice deposits for 2 invites
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT * 2}(2, 0);

        bytes32 hash1 = keccak256(abi.encodePacked("invite1"));
        bytes32 hash2 = keccak256(abi.encodePacked("invite2"));
        sponsor.sponsorInvite(hash1);
        sponsor.sponsorInvite(hash2);
        vm.stopPrank();

        assertEq(sponsor.availableSlots(alice), 0);
        assertEq(address(sponsor).balance, AMOUNT * 2);

        // Bob redeems invite1
        uint256 bobBefore = bob.balance;
        _redeem("invite1", bob);
        assertEq(bob.balance, bobBefore + AMOUNT);

        // Alice revokes invite2 (unused)
        vm.prank(alice);
        uint256 aliceBefore = alice.balance;
        sponsor.revokeInvite(hash2);
        assertEq(alice.balance, aliceBefore + AMOUNT);

        // Contract should be empty
        assertEq(address(sponsor).balance, 0);
    }

    // --- v3: Domain budget ---

    uint256 constant DOMAIN_BUDGET = 0.0025 ether; // ~$10 at 4000 USD/ETH

    function test_v3_default_max_domain_budget() public view {
        assertEq(sponsor.maxDomainBudget(), 0.0025 ether);
    }

    function test_v3_setMaxDomainBudget_deployer_only() public {
        vm.prank(alice); // not the deployer
        vm.expectRevert("not authorized");
        sponsor.setMaxDomainBudget(0.005 ether);
    }

    function test_v3_setMaxDomainBudget_capped_at_005_ether() public {
        // The deployer is `address(this)` because the test contract called `new`
        vm.expectRevert("out of range");
        sponsor.setMaxDomainBudget(0.06 ether);
    }

    function test_v3_setMaxDomainBudget_can_set_zero() public {
        sponsor.setMaxDomainBudget(0);
        assertEq(sponsor.maxDomainBudget(), 0);
    }

    event MaxDomainBudgetSet(uint256 newMax);

    function test_v3_setMaxDomainBudget_event() public {
        vm.expectEmit(false, false, false, true);
        emit MaxDomainBudgetSet(0.003 ether);
        sponsor.setMaxDomainBudget(0.003 ether);
    }

    function test_v3_deposit_with_domain_budget() public {
        uint256 perSlot = AMOUNT + DOMAIN_BUDGET;
        vm.prank(alice);
        sponsor.deposit{value: perSlot * 2}(2, DOMAIN_BUDGET);
        assertEq(sponsor.availableSlots(alice), 2);
        assertEq(address(sponsor).balance, perSlot * 2);
        assertEq(sponsor.depositedSponsorAmount(alice), perSlot);
    }

    function test_v3_deposit_with_zero_budget_still_works() public {
        // Pre-v3 behavior must remain identical when domainBudgetPerSlot=0
        vm.prank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        assertEq(sponsor.availableSlots(alice), 1);
        assertEq(sponsor.depositedSponsorAmount(alice), AMOUNT);
    }

    function test_v3_deposit_above_cap_reverts() public {
        // Default cap is 0.0025 ether; try 0.003
        vm.prank(alice);
        vm.expectRevert("domain budget too high");
        sponsor.deposit{value: (AMOUNT + 0.003 ether)}(1, 0.003 ether);
    }

    function test_v3_deposit_at_exact_cap_works() public {
        uint256 cap = sponsor.maxDomainBudget();
        vm.prank(alice);
        sponsor.deposit{value: AMOUNT + cap}(1, cap);
        assertEq(sponsor.availableSlots(alice), 1);
    }

    function test_v3_deposit_disabled_when_cap_zero() public {
        sponsor.setMaxDomainBudget(0);
        vm.prank(alice);
        vm.expectRevert("domain budget too high");
        sponsor.deposit{value: AMOUNT + 1}(1, 1);
        // But zero-budget deposits still work
        vm.prank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        assertEq(sponsor.availableSlots(alice), 1);
    }

    function test_v3_deposit_wrong_value_reverts() public {
        // Mismatched msg.value vs (count * (sponsorAmount + budget))
        vm.prank(alice);
        vm.expectRevert("wrong value");
        sponsor.deposit{value: AMOUNT}(1, DOMAIN_BUDGET);
    }

    function test_v3_redeem_pays_full_per_slot_including_budget() public {
        uint256 perSlot = AMOUNT + DOMAIN_BUDGET;
        vm.startPrank(alice);
        sponsor.deposit{value: perSlot}(1, DOMAIN_BUDGET);
        bytes32 hash = keccak256(abi.encodePacked("budgetcode"));
        sponsor.sponsorInvite(hash);
        vm.stopPrank();

        uint256 bobBefore = bob.balance;
        _redeem("budgetcode", bob);
        // Bob receives the full per-slot amount (deploy fee + gas + domain budget)
        assertEq(bob.balance, bobBefore + perSlot);
        assertEq(address(sponsor).balance, 0);
    }

    function test_v3_revoke_returns_full_per_slot_including_budget() public {
        uint256 perSlot = AMOUNT + DOMAIN_BUDGET;
        vm.startPrank(alice);
        sponsor.deposit{value: perSlot}(1, DOMAIN_BUDGET);
        bytes32 hash = keccak256(abi.encodePacked("revokecode"));
        sponsor.sponsorInvite(hash);

        uint256 aliceBefore = alice.balance;
        sponsor.revokeInvite(hash);
        assertEq(alice.balance, aliceBefore + perSlot);
        vm.stopPrank();
        assertEq(address(sponsor).balance, 0);
    }

    function test_v3_refundSlots_returns_full_per_slot() public {
        uint256 perSlot = AMOUNT + DOMAIN_BUDGET;
        vm.startPrank(alice);
        sponsor.deposit{value: perSlot * 3}(3, DOMAIN_BUDGET);

        uint256 aliceBefore = alice.balance;
        sponsor.refundSlots(2);
        assertEq(alice.balance, aliceBefore + perSlot * 2);
        assertEq(sponsor.availableSlots(alice), 1);
        vm.stopPrank();
    }

    function test_v3_weighted_average_across_mixed_budget_deposits() public {
        // First deposit: 2 slots at AMOUNT (no budget)
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT * 2}(2, 0);
        assertEq(sponsor.depositedSponsorAmount(alice), AMOUNT);

        // Second deposit: 2 slots at AMOUNT + DOMAIN_BUDGET
        uint256 fullSlot = AMOUNT + DOMAIN_BUDGET;
        sponsor.deposit{value: fullSlot * 2}(2, DOMAIN_BUDGET);

        // Weighted average: (2*AMOUNT + 2*fullSlot) / 4 = AMOUNT + DOMAIN_BUDGET/2
        uint256 expectedAvg = (AMOUNT * 2 + fullSlot * 2) / 4;
        assertEq(sponsor.depositedSponsorAmount(alice), expectedAvg);
        assertEq(sponsor.availableSlots(alice), 4);
        vm.stopPrank();
    }
}
