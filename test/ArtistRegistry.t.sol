// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../ArtistRegistry.sol";

contract ArtistRegistryTest is Test {
    event Registered(address indexed wallet, string domain);
    event RegistrationTransferred(address indexed oldWallet, address indexed newWallet, string domain);
    event Followed(address indexed follower, address indexed followed);
    event Unfollowed(address indexed follower, address indexed followed);

    ArtistRegistry registry;

    // orchestrator key for signing
    uint256 orchKey = 0xA11CE;
    address orchAddr;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address dave = makeAddr("dave");

    function setUp() public {
        orchAddr = vm.addr(orchKey);
        registry = new ArtistRegistry();
        registry.setOrchestrator(orchAddr);
    }

    function _signRegister(address wallet, string memory domain) internal view returns (bytes memory) {
        uint256 nonce = registry.nonces(wallet);
        bytes32 messageHash = keccak256(abi.encodePacked(wallet, domain, nonce, block.chainid, address(registry)));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orchKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    // --- Registration ---

    function test_register_success() public {
        _reg(alice, "alice.xyz");

        (string memory domain, uint256 registeredAt) = registry.artists(alice);
        assertEq(domain, "alice.xyz");
        assertGt(registeredAt, 0);
    }

    function test_register_emits_event() public {
        vm.expectEmit(true, false, false, true);
        emit Registered(alice, "alice.xyz");
        _reg(alice, "alice.xyz");
    }

    function test_register_empty_domain_reverts() public {
        bytes memory sig = _signRegister(alice, "");
        vm.prank(alice);
        vm.expectRevert("empty domain");
        registry.register("", sig);
    }

    function test_register_double_reverts() public {
        _reg(alice, "alice.xyz");
        bytes memory sig = _signRegister(alice, "alice2.xyz");
        vm.prank(alice);
        vm.expectRevert("already registered");
        registry.register("alice2.xyz", sig);
    }

    function test_allArtists_view() public {
        _reg(alice, "alice.xyz");
        _reg(bob, "bob.xyz");

        (address[] memory wallets, string[] memory domains) = registry.allArtists();
        assertEq(wallets.length, 2);
        assertEq(wallets[0], alice);
        assertEq(wallets[1], bob);
        assertEq(domains[0], "alice.xyz");
        assertEq(domains[1], "bob.xyz");
    }

    function test_totalArtists_count() public {
        assertEq(registry.totalArtists(), 0);
        _reg(alice, "alice.xyz");
        assertEq(registry.totalArtists(), 1);
        _reg(bob, "bob.xyz");
        assertEq(registry.totalArtists(), 2);
    }

    // --- Migration ---

    function test_migrate_success() public {
        address[] memory wallets = new address[](3);
        string[] memory domains = new string[](3);
        uint256[] memory timestamps = new uint256[](3);

        wallets[0] = alice; domains[0] = "alice.xyz"; timestamps[0] = 1000;
        wallets[1] = bob; domains[1] = "bob.xyz"; timestamps[1] = 2000;
        wallets[2] = charlie; domains[2] = "charlie.xyz"; timestamps[2] = 3000;

        registry.migrateArtists(wallets, domains, timestamps);

        assertTrue(registry.migrated());
        assertEq(registry.totalArtists(), 3);

        (string memory d, uint256 t) = registry.artists(alice);
        assertEq(d, "alice.xyz");
        assertEq(t, 1000);
    }

    function test_migrate_non_deployer_reverts() public {
        address[] memory w = new address[](1);
        string[] memory d = new string[](1);
        uint256[] memory t = new uint256[](1);
        w[0] = alice; d[0] = "a.xyz"; t[0] = 1;

        vm.prank(alice);
        vm.expectRevert("not deployer");
        registry.migrateArtists(w, d, t);
    }

    function test_migrate_double_reverts() public {
        address[] memory w = new address[](1);
        string[] memory d = new string[](1);
        uint256[] memory t = new uint256[](1);
        w[0] = alice; d[0] = "a.xyz"; t[0] = 1;

        registry.migrateArtists(w, d, t);

        w[0] = bob; d[0] = "b.xyz";
        vm.expectRevert("already migrated");
        registry.migrateArtists(w, d, t);
    }

    function test_migrate_mismatched_arrays_reverts() public {
        address[] memory w = new address[](2);
        string[] memory d = new string[](1);
        uint256[] memory t = new uint256[](1);
        w[0] = alice; w[1] = bob;
        d[0] = "a.xyz"; t[0] = 1;

        vm.expectRevert("length mismatch");
        registry.migrateArtists(w, d, t);
    }

    function test_migrate_duplicate_wallet_reverts() public {
        address[] memory w = new address[](2);
        string[] memory d = new string[](2);
        uint256[] memory t = new uint256[](2);
        w[0] = alice; d[0] = "a.xyz"; t[0] = 1;
        w[1] = alice; d[1] = "a2.xyz"; t[1] = 2;

        vm.expectRevert("already registered");
        registry.migrateArtists(w, d, t);
    }

    function test_register_after_migration() public {
        address[] memory w = new address[](1);
        string[] memory d = new string[](1);
        uint256[] memory t = new uint256[](1);
        w[0] = alice; d[0] = "a.xyz"; t[0] = 1;
        registry.migrateArtists(w, d, t);

        // new registration still works after migration
        _reg(bob, "bob.xyz");
        assertEq(registry.totalArtists(), 2);
    }

    // --- Follow ---

    function test_follow_success() public {
        _registerAliceBob();

        vm.expectEmit(true, true, false, false);
        emit Followed(alice, bob);

        vm.prank(alice);
        registry.follow(bob);

        assertTrue(registry.isFollowing(alice, bob));
        assertEq(registry.followingCount(alice), 1);
        assertEq(registry.followerCount(bob), 1);

        address[] memory following = registry.getFollowing(alice);
        assertEq(following.length, 1);
        assertEq(following[0], bob);

        address[] memory followers = registry.getFollowers(bob);
        assertEq(followers.length, 1);
        assertEq(followers[0], alice);
    }

    function test_follow_self_reverts() public {
        _reg(alice, "alice.xyz");

        vm.prank(alice);
        vm.expectRevert("cannot follow self");
        registry.follow(alice);
    }

    function test_follow_unregistered_follower_reverts() public {
        _reg(bob, "bob.xyz");

        vm.prank(alice); // not registered
        vm.expectRevert("not registered");
        registry.follow(bob);
    }

    function test_follow_unregistered_target_reverts() public {
        _reg(alice, "alice.xyz");

        vm.prank(alice);
        vm.expectRevert("target not registered");
        registry.follow(bob); // bob not registered
    }

    function test_follow_already_following_reverts() public {
        _registerAliceBob();

        vm.prank(alice);
        registry.follow(bob);

        vm.prank(alice);
        vm.expectRevert("already following");
        registry.follow(bob);
    }

    // --- Unfollow ---

    function test_unfollow_success() public {
        _registerAliceBob();

        vm.prank(alice);
        registry.follow(bob);

        vm.expectEmit(true, true, false, false);
        emit Unfollowed(alice, bob);

        vm.prank(alice);
        registry.unfollow(bob);

        assertFalse(registry.isFollowing(alice, bob));
        assertEq(registry.followingCount(alice), 0);
        assertEq(registry.followerCount(bob), 0);
    }

    function test_unfollow_not_following_reverts() public {
        _registerAliceBob();

        vm.prank(alice);
        vm.expectRevert("not following");
        registry.unfollow(bob);
    }

    function test_unfollow_swap_and_pop_correctness() public {
        // register 3 artists
        _reg(alice, "alice.xyz");
        _reg(bob, "bob.xyz");
        _reg(charlie, "charlie.xyz");

        // alice follows A, B, C (bob, charlie, then we need a 3rd)
        _reg(dave, "dave.xyz");

        vm.startPrank(alice);
        registry.follow(bob);     // [bob]
        registry.follow(charlie); // [bob, charlie]
        registry.follow(dave);    // [bob, charlie, dave]

        // unfollow middle element (charlie)
        registry.unfollow(charlie);
        vm.stopPrank();

        // should be [bob, dave]
        address[] memory following = registry.getFollowing(alice);
        assertEq(following.length, 2);
        assertEq(following[0], bob);
        assertEq(following[1], dave);
        assertFalse(registry.isFollowing(alice, charlie));
    }

    // --- Views ---

    function test_isFollowing() public {
        _registerAliceBob();

        vm.prank(alice);
        registry.follow(bob);

        assertTrue(registry.isFollowing(alice, bob));
        assertFalse(registry.isFollowing(bob, alice));
    }

    function test_isMutual_both_directions() public {
        _registerAliceBob();

        vm.prank(alice);
        registry.follow(bob);
        vm.prank(bob);
        registry.follow(alice);

        assertTrue(registry.isMutual(alice, bob));
        assertTrue(registry.isMutual(bob, alice));
    }

    function test_isMutual_one_direction_false() public {
        _registerAliceBob();

        vm.prank(alice);
        registry.follow(bob);

        assertFalse(registry.isMutual(alice, bob));
        assertFalse(registry.isMutual(bob, alice));
    }

    function test_refollow_after_unfollow() public {
        _registerAliceBob();

        vm.startPrank(alice);
        registry.follow(bob);
        registry.unfollow(bob);
        registry.follow(bob);
        vm.stopPrank();

        assertTrue(registry.isFollowing(alice, bob));
        assertEq(registry.followingCount(alice), 1);
        assertEq(registry.followerCount(bob), 1);
    }

    // --- helpers ---

    function _reg(address who, string memory domain) internal {
        bytes memory sig = _signRegister(who, domain);
        vm.prank(who);
        registry.register(domain, sig);
    }

    function _registerAliceBob() internal {
        _reg(alice, "alice.xyz");
        _reg(bob, "bob.xyz");
    }

    // --- unregister tests ---

    function test_unregister_success() public {
        _reg(alice, "alice.xyz");
        (string memory domain,) = registry.artists(alice);
        assertEq(bytes(domain).length > 0, true);

        vm.prank(alice);
        registry.unregister();

        (string memory d2, uint256 t2) = registry.artists(alice);
        assertEq(bytes(d2).length, 0);
        assertEq(t2, 0);
        assertEq(registry.totalArtists(), 0);
    }

    function test_unregister_not_registered_reverts() public {
        vm.expectRevert("not registered");
        vm.prank(alice);
        registry.unregister();
    }

    function test_unregister_lazy_deletion() public {
        _reg(alice, "alice.xyz");
        _reg(bob, "bob.xyz");
        _reg(charlie, "charlie.xyz");

        // alice follows bob and charlie
        vm.prank(alice);
        registry.follow(bob);
        vm.prank(alice);
        registry.follow(charlie);
        // bob follows alice
        vm.prank(bob);
        registry.follow(alice);

        assertEq(registry.isFollowing(alice, bob), true);
        assertEq(registry.isFollowing(bob, alice), true);

        // alice unregisters
        vm.prank(alice);
        registry.unregister();

        // follow data is stale (lazy deletion) — mappings still exist
        // but isUser(alice) is false so no new follows can be created
        assertFalse(registry.isUser(alice));

        // bob and charlie still registered
        assertEq(registry.totalArtists(), 2);
    }

    function test_unregister_swap_and_pop_correctness() public {
        _reg(alice, "alice.xyz");
        _reg(bob, "bob.xyz");
        _reg(charlie, "charlie.xyz");

        // remove bob (middle) — charlie should swap into bob's slot
        vm.prank(bob);
        registry.unregister();

        assertEq(registry.totalArtists(), 2);
        assertEq(registry.registeredAddresses(0), alice);
        assertEq(registry.registeredAddresses(1), charlie);
    }

    function test_unregister_can_reregister() public {
        _reg(alice, "alice.xyz");
        vm.prank(alice);
        registry.unregister();

        // should be able to register again with a new domain
        _reg(alice, "newalice.xyz");
        (string memory domain,) = registry.artists(alice);
        assertEq(domain, "newalice.xyz");
    }

    // --- Transfer Registration ---

    function _signTransfer(address oldWallet, address newWallet) internal view returns (bytes memory) {
        uint256 nonce = registry.nonces(oldWallet);
        bytes32 messageHash = keccak256(abi.encodePacked(oldWallet, newWallet, nonce, block.chainid, address(registry)));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orchKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function test_transferRegistration_success() public {
        _reg(alice, "alice.xyz");
        address newAddr = makeAddr("alice-new");
        bytes memory sig = _signTransfer(alice, newAddr);

        vm.prank(alice);
        registry.transferRegistration(newAddr, sig);

        // old address cleared
        (string memory oldDomain, uint256 oldTime) = registry.artists(alice);
        assertEq(bytes(oldDomain).length, 0);
        assertEq(oldTime, 0);

        // new address has the data
        (string memory newDomain, uint256 newTime) = registry.artists(newAddr);
        assertEq(newDomain, "alice.xyz");
        assertGt(newTime, 0);

        // total count unchanged
        assertEq(registry.totalArtists(), 1);

        // registeredAddresses updated
        assertEq(registry.registeredAddresses(0), newAddr);
    }

    function test_transferRegistration_preserves_timestamp() public {
        _reg(alice, "alice.xyz");
        (, uint256 originalTime) = registry.artists(alice);

        address newAddr = makeAddr("alice-new");
        bytes memory sig = _signTransfer(alice, newAddr);
        vm.prank(alice);
        registry.transferRegistration(newAddr, sig);

        (, uint256 newTime) = registry.artists(newAddr);
        assertEq(newTime, originalTime);
    }

    function test_transferRegistration_preserves_follows() public {
        _reg(alice, "alice.xyz");
        _reg(bob, "bob.xyz");
        _reg(charlie, "charlie.xyz");

        // alice follows bob, charlie follows alice
        vm.prank(alice);
        registry.follow(bob);
        vm.prank(charlie);
        registry.follow(alice);

        address newAddr = makeAddr("alice-new");
        bytes memory sig = _signTransfer(alice, newAddr);
        vm.prank(alice);
        registry.transferRegistration(newAddr, sig);

        // newAddr still follows bob
        assertTrue(registry.isFollowing(newAddr, bob));
        assertEq(registry.followingCount(newAddr), 1);
        address[] memory following = registry.getFollowing(newAddr);
        assertEq(following[0], bob);

        // charlie still follows newAddr
        assertTrue(registry.isFollowing(charlie, newAddr));
        assertEq(registry.followerCount(newAddr), 1);
        address[] memory followers = registry.getFollowers(newAddr);
        assertEq(followers[0], charlie);

        // bob's followers updated to newAddr
        address[] memory bobFollowers = registry.getFollowers(bob);
        assertEq(bobFollowers[0], newAddr);

        // old address has no relationships
        assertFalse(registry.isFollowing(alice, bob));
        assertFalse(registry.isFollowing(charlie, alice));
        assertEq(registry.followingCount(alice), 0);
        assertEq(registry.followerCount(alice), 0);
    }

    function test_transferRegistration_mutual_follows() public {
        _reg(alice, "alice.xyz");
        _reg(bob, "bob.xyz");

        vm.prank(alice);
        registry.follow(bob);
        vm.prank(bob);
        registry.follow(alice);

        assertTrue(registry.isMutual(alice, bob));

        address newAddr = makeAddr("alice-new");
        bytes memory sig = _signTransfer(alice, newAddr);
        vm.prank(alice);
        registry.transferRegistration(newAddr, sig);

        // mutual follow preserved with new address
        assertTrue(registry.isFollowing(newAddr, bob));
        assertTrue(registry.isFollowing(bob, newAddr));
        assertTrue(registry.isMutual(newAddr, bob));
        assertFalse(registry.isMutual(alice, bob));
    }

    function test_transferRegistration_not_registered_reverts() public {
        address newAddr = makeAddr("new");
        bytes memory sig = _signTransfer(alice, newAddr);
        vm.prank(alice);
        vm.expectRevert("not registered");
        registry.transferRegistration(newAddr, sig);
    }

    function test_transferRegistration_target_registered_reverts() public {
        _reg(alice, "alice.xyz");
        _reg(bob, "bob.xyz");

        bytes memory sig = _signTransfer(alice, bob);
        vm.prank(alice);
        vm.expectRevert("target already registered");
        registry.transferRegistration(bob, sig);
    }

    function test_transferRegistration_invalid_signature_reverts() public {
        _reg(alice, "alice.xyz");
        address newAddr = makeAddr("new");

        // sign with wrong pair
        bytes memory badSig = _signTransfer(bob, newAddr);
        vm.prank(alice);
        vm.expectRevert("invalid signature");
        registry.transferRegistration(newAddr, badSig);
    }

    function test_transferRegistration_same_address_reverts() public {
        _reg(alice, "alice.xyz");

        bytes memory sig = _signTransfer(alice, alice);
        vm.prank(alice);
        vm.expectRevert("same address");
        registry.transferRegistration(alice, sig);
    }

    function test_transferRegistration_zero_address_reverts() public {
        _reg(alice, "alice.xyz");

        bytes memory sig = _signTransfer(alice, address(0));
        vm.prank(alice);
        vm.expectRevert("zero address");
        registry.transferRegistration(address(0), sig);
    }

    function test_transferRegistration_emits_event() public {
        _reg(alice, "alice.xyz");
        address newAddr = makeAddr("alice-new");

        bytes memory sig = _signTransfer(alice, newAddr);
        vm.expectEmit(true, true, false, true);
        emit RegistrationTransferred(alice, newAddr, "alice.xyz");

        vm.prank(alice);
        registry.transferRegistration(newAddr, sig);
    }

    // --- Deploy fee + treasury tests ---

    function test_register_with_fee() public {
        address treasuryAddr = makeAddr("treasury");
        registry.setTreasury(treasuryAddr);
        registry.setDeployFee(0.003 ether);

        bytes memory sig = _signRegister(alice, "alice.bio");
        vm.prank(alice);
        vm.deal(alice, 1 ether);
        registry.register{value: 0.003 ether}("alice.bio", sig);

        (string memory domain, ) = registry.artists(alice);
        assertEq(domain, "alice.bio");
    }

    function test_register_insufficient_fee_reverts() public {
        address treasuryAddr = makeAddr("treasury");
        registry.setTreasury(treasuryAddr);
        registry.setDeployFee(0.003 ether);

        bytes memory sig = _signRegister(alice, "alice.bio");
        vm.prank(alice);
        vm.deal(alice, 1 ether);
        vm.expectRevert("insufficient fee");
        registry.register{value: 0.001 ether}("alice.bio", sig);
    }

    function test_register_fee_sent_to_treasury() public {
        address treasuryAddr = makeAddr("treasury");
        registry.setTreasury(treasuryAddr);
        registry.setDeployFee(0.003 ether);

        bytes memory sig = _signRegister(alice, "alice.bio");
        vm.prank(alice);
        vm.deal(alice, 1 ether);
        uint256 balBefore = treasuryAddr.balance;
        registry.register{value: 0.003 ether}("alice.bio", sig);
        assertEq(treasuryAddr.balance - balBefore, 0.003 ether);
    }

    function test_register_zero_fee_still_works() public {
        bytes memory sig = _signRegister(alice, "alice.bio");
        vm.prank(alice);
        registry.register("alice.bio", sig);

        (string memory domain, ) = registry.artists(alice);
        assertEq(domain, "alice.bio");
    }

    function test_setTreasury_by_deployer() public {
        address newTreasury = makeAddr("newTreasury");
        registry.setTreasury(newTreasury);
        assertEq(registry.treasury(), newTreasury);
    }

    function test_setTreasury_by_non_deployer_reverts() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(alice);
        vm.expectRevert("not deployer");
        registry.setTreasury(newTreasury);
    }

    function test_setTreasury_zero_address_reverts() public {
        vm.expectRevert("zero address");
        registry.setTreasury(address(0));
    }

    function test_setDeployFee() public {
        registry.setDeployFee(0.005 ether);
        assertEq(registry.deployFee(), 0.005 ether);
    }

    function test_setDeployFee_by_non_deployer_reverts() public {
        vm.prank(alice);
        vm.expectRevert("not deployer");
        registry.setDeployFee(0.005 ether);
    }

    // --- Nonce replay protection tests ---

    function test_register_replay_old_signature_fails() public {
        // Get signature for nonce=0
        bytes memory sig0 = _signRegister(alice, "alice.xyz");
        vm.prank(alice);
        registry.register("alice.xyz", sig0);
        // nonce is now 1

        // Try to register again with same nonce=0 signature (different domain)
        vm.prank(alice);
        vm.expectRevert("already registered");
        registry.register("alice2.xyz", sig0);

        // Unregister and try to re-register with OLD signature
        vm.prank(alice);
        registry.unregister();
        vm.prank(alice);
        vm.expectRevert("invalid signature"); // nonce mismatch
        registry.register("alice2.xyz", sig0);

        // But a NEW signature with nonce=1 should work
        bytes memory sig1 = _signRegister(alice, "alice2.xyz");
        vm.prank(alice);
        registry.register("alice2.xyz", sig1);
        (string memory domain,) = registry.artists(alice);
        assertEq(domain, "alice2.xyz");
    }

    function test_register_signature_not_valid_for_updateDomain() public {
        _reg(alice, "alice.xyz");
        // Get a register signature for bob (would be nonce=0 for bob)
        bytes memory regSig = _signRegister(bob, "evil.xyz");
        // Try to use it as an updateDomain sig from alice (different function, different params)
        vm.prank(alice);
        vm.expectRevert("invalid signature");
        registry.updateDomain("evil.xyz", regSig);
    }

    function test_nonce_increments_across_functions() public {
        assertEq(registry.nonces(alice), 0);
        _reg(alice, "alice.xyz");
        assertEq(registry.nonces(alice), 1);
        // updateDomain uses nonce=1
        uint256 nonce = registry.nonces(alice);
        bytes32 msgHash = keccak256(abi.encodePacked(alice, "alice2.xyz", nonce, block.chainid, address(registry)));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orchKey, ethHash);
        vm.prank(alice);
        registry.updateDomain("alice2.xyz", abi.encodePacked(r, s, v));
        assertEq(registry.nonces(alice), 2);
    }

    function test_transferRegistration_no_follows() public {
        _reg(alice, "alice.xyz");
        address newAddr = makeAddr("alice-new");
        bytes memory sig = _signTransfer(alice, newAddr);
        vm.prank(alice);
        registry.transferRegistration(newAddr, sig);
        assertEq(registry.followingCount(newAddr), 0);
        assertEq(registry.followerCount(newAddr), 0);
        (string memory domain,) = registry.artists(newAddr);
        assertEq(domain, "alice.xyz");
    }

    function test_register_overpayment_refunded() public {
        address treasuryAddr = makeAddr("treasury");
        registry.setTreasury(treasuryAddr);
        registry.setDeployFee(0.003 ether);

        bytes memory sig = _signRegister(alice, "alice.bio");
        vm.prank(alice);
        vm.deal(alice, 1 ether);
        registry.register{value: 0.01 ether}("alice.bio", sig);
        // Treasury receives exactly deployFee
        assertEq(treasuryAddr.balance, 0.003 ether);
        // Overpayment refunded to sender
        assertEq(alice.balance, 1 ether - 0.003 ether);
    }
}
