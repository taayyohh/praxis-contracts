// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../ArtistRegistry.sol";

contract SupporterRegistryTest is Test {
    event SupporterRegistered(address indexed wallet, string handle, uint256 timestamp);
    event SupporterUnregistered(address indexed wallet, string handle);
    event Followed(address indexed follower, address indexed followed);
    event Unfollowed(address indexed follower, address indexed followed);

    ArtistRegistry registry;

    uint256 orchKey = 0xA11CE;
    address orchAddr;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address supporter1 = makeAddr("supporter1");
    address supporter2 = makeAddr("supporter2");

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

    function _regArtist(address who, string memory domain) internal {
        bytes memory sig = _signRegister(who, domain);
        vm.prank(who);
        registry.register(domain, sig);
    }

    function _regSupporter(address who, string memory handle) internal {
        vm.prank(who);
        registry.registerSupporter(handle);
    }

    // --- Supporter Registration ---

    function test_registerSupporter_success() public {
        vm.expectEmit(true, false, false, true);
        emit SupporterRegistered(supporter1, "fanone", block.timestamp);

        _regSupporter(supporter1, "fanone");

        (string memory handle, uint256 registeredAt) = registry.supporters(supporter1);
        assertEq(handle, "fanone");
        assertGt(registeredAt, 0);
        assertEq(registry.supporterByHandle("fanone"), supporter1);
        assertEq(registry.totalSupporters(), 1);
    }

    function test_registerSupporter_handle_taken_reverts() public {
        _regSupporter(supporter1, "coolhandle");

        vm.prank(supporter2);
        vm.expectRevert("handle taken");
        registry.registerSupporter("coolhandle");
    }

    function test_registerSupporter_already_artist_reverts() public {
        _regArtist(alice, "alice.xyz");

        vm.prank(alice);
        vm.expectRevert("already registered");
        registry.registerSupporter("alice-fan");
    }

    function test_registerSupporter_already_supporter_reverts() public {
        _regSupporter(supporter1, "fanone");

        vm.prank(supporter1);
        vm.expectRevert("already registered");
        registry.registerSupporter("fanone-v2");
    }

    function test_registerSupporter_too_short_reverts() public {
        vm.prank(supporter1);
        vm.expectRevert("handle 3-32 chars");
        registry.registerSupporter("ab");
    }

    function test_registerSupporter_too_long_reverts() public {
        vm.prank(supporter1);
        vm.expectRevert("handle 3-32 chars");
        registry.registerSupporter("abcdefghijklmnopqrstuvwxyz1234567");
    }

    function test_registerSupporter_uppercase_reverts() public {
        vm.prank(supporter1);
        vm.expectRevert("invalid char");
        registry.registerSupporter("FanOne");
    }

    function test_registerSupporter_special_chars_reverts() public {
        vm.prank(supporter1);
        vm.expectRevert("invalid char");
        registry.registerSupporter("fan_one");
    }

    function test_registerSupporter_leading_hyphen_reverts() public {
        vm.prank(supporter1);
        vm.expectRevert("no leading/trailing hyphen");
        registry.registerSupporter("-fanone");
    }

    function test_registerSupporter_trailing_hyphen_reverts() public {
        vm.prank(supporter1);
        vm.expectRevert("no leading/trailing hyphen");
        registry.registerSupporter("fanone-");
    }

    function test_registerSupporter_hyphen_in_middle_ok() public {
        _regSupporter(supporter1, "fan-one");

        (string memory handle,) = registry.supporters(supporter1);
        assertEq(handle, "fan-one");
    }

    function test_registerSupporter_numbers_ok() public {
        _regSupporter(supporter1, "fan123");

        (string memory handle,) = registry.supporters(supporter1);
        assertEq(handle, "fan123");
    }

    function test_registerSupporter_min_length() public {
        _regSupporter(supporter1, "abc");

        (string memory handle,) = registry.supporters(supporter1);
        assertEq(handle, "abc");
    }

    function test_registerSupporter_max_length() public {
        _regSupporter(supporter1, "abcdefghijklmnopqrstuvwxyz123456");

        (string memory handle,) = registry.supporters(supporter1);
        assertEq(handle, "abcdefghijklmnopqrstuvwxyz123456");
    }

    // --- handleAvailable ---

    function test_handleAvailable_true() public view {
        assertTrue(registry.handleAvailable("coolhandle"));
    }

    function test_handleAvailable_false() public {
        _regSupporter(supporter1, "coolhandle");
        assertFalse(registry.handleAvailable("coolhandle"));
    }

    // --- isUser ---

    function test_isUser_artist() public {
        _regArtist(alice, "alice.xyz");
        assertTrue(registry.isUser(alice));
    }

    function test_isUser_supporter() public {
        _regSupporter(supporter1, "fanone");
        assertTrue(registry.isUser(supporter1));
    }

    function test_isUser_nobody() public view {
        assertFalse(registry.isUser(supporter1));
    }

    // --- Supporter can follow ---

    function test_supporter_follows_artist() public {
        _regArtist(alice, "alice.xyz");
        _regSupporter(supporter1, "fanone");

        vm.expectEmit(true, true, false, false);
        emit Followed(supporter1, alice);

        vm.prank(supporter1);
        registry.follow(alice);

        assertTrue(registry.isFollowing(supporter1, alice));
        assertEq(registry.followingCount(supporter1), 1);
        assertEq(registry.followerCount(alice), 1);
    }

    function test_artist_follows_supporter() public {
        _regArtist(alice, "alice.xyz");
        _regSupporter(supporter1, "fanone");

        vm.prank(alice);
        registry.follow(supporter1);

        assertTrue(registry.isFollowing(alice, supporter1));
    }

    function test_supporter_follows_supporter() public {
        _regSupporter(supporter1, "fanone");
        _regSupporter(supporter2, "fantwo");

        vm.prank(supporter1);
        registry.follow(supporter2);

        assertTrue(registry.isFollowing(supporter1, supporter2));
    }

    function test_supporter_mutual_follow() public {
        _regArtist(alice, "alice.xyz");
        _regSupporter(supporter1, "fanone");

        vm.prank(supporter1);
        registry.follow(alice);
        vm.prank(alice);
        registry.follow(supporter1);

        assertTrue(registry.isMutual(supporter1, alice));
    }

    function test_supporter_unfollow() public {
        _regArtist(alice, "alice.xyz");
        _regSupporter(supporter1, "fanone");

        vm.prank(supporter1);
        registry.follow(alice);

        vm.prank(supporter1);
        registry.unfollow(alice);

        assertFalse(registry.isFollowing(supporter1, alice));
        assertEq(registry.followingCount(supporter1), 0);
        assertEq(registry.followerCount(alice), 0);
    }

    // --- Unregister supporter ---

    function test_unregisterSupporter_success() public {
        _regSupporter(supporter1, "fanone");

        vm.expectEmit(true, false, false, true);
        emit SupporterUnregistered(supporter1, "fanone");

        vm.prank(supporter1);
        registry.unregisterSupporter();

        (string memory handle, uint256 registeredAt) = registry.supporters(supporter1);
        assertEq(bytes(handle).length, 0);
        assertEq(registeredAt, 0);
        assertEq(registry.supporterByHandle("fanone"), address(0));
        assertEq(registry.totalSupporters(), 0);
    }

    function test_unregisterSupporter_not_supporter_reverts() public {
        vm.prank(supporter1);
        vm.expectRevert("not a supporter");
        registry.unregisterSupporter();
    }

    function test_unregisterSupporter_lazy_deletion() public {
        _regArtist(alice, "alice.xyz");
        _regSupporter(supporter1, "fanone");

        vm.prank(supporter1);
        registry.follow(alice);
        vm.prank(alice);
        registry.follow(supporter1);

        assertTrue(registry.isMutual(supporter1, alice));

        vm.prank(supporter1);
        registry.unregisterSupporter();

        // follow data is stale (lazy deletion) — mappings still exist
        // but isUser(supporter1) is false so no new follows can be created
        assertFalse(registry.isUser(supporter1));
        assertEq(registry.totalSupporters(), 0);
    }

    function test_unregisterSupporter_can_reregister() public {
        _regSupporter(supporter1, "fanone");
        vm.prank(supporter1);
        registry.unregisterSupporter();

        _regSupporter(supporter1, "newfanone");
        (string memory handle,) = registry.supporters(supporter1);
        assertEq(handle, "newfanone");
    }

    function test_unregisterSupporter_frees_handle() public {
        _regSupporter(supporter1, "fanone");
        vm.prank(supporter1);
        registry.unregisterSupporter();

        // someone else can now take the handle
        _regSupporter(supporter2, "fanone");
        assertEq(registry.supporterByHandle("fanone"), supporter2);
    }

    function test_unregisterSupporter_swap_and_pop() public {
        _regSupporter(supporter1, "fanone");
        _regSupporter(supporter2, "fantwo");
        address supporter3 = makeAddr("supporter3");
        _regSupporter(supporter3, "fanthree");

        // remove middle (supporter2)
        vm.prank(supporter2);
        registry.unregisterSupporter();

        assertEq(registry.totalSupporters(), 2);
        assertEq(registry.registeredSupporters(0), supporter1);
        assertEq(registry.registeredSupporters(1), supporter3);
    }

    // --- Migration ---

    function test_migrateSupporters_success() public {
        address[] memory wallets = new address[](2);
        string[] memory handles = new string[](2);
        uint256[] memory timestamps = new uint256[](2);

        wallets[0] = supporter1; handles[0] = "fanone"; timestamps[0] = 1000;
        wallets[1] = supporter2; handles[1] = "fantwo"; timestamps[1] = 2000;

        registry.migrateSupporters(wallets, handles, timestamps);

        assertEq(registry.totalSupporters(), 2);
        (string memory h, uint256 t) = registry.supporters(supporter1);
        assertEq(h, "fanone");
        assertEq(t, 1000);
        assertEq(registry.supporterByHandle("fantwo"), supporter2);
    }

    function test_migrateSupporters_non_deployer_reverts() public {
        address[] memory w = new address[](1);
        string[] memory h = new string[](1);
        uint256[] memory t = new uint256[](1);
        w[0] = supporter1; h[0] = "fan"; t[0] = 1;

        vm.prank(supporter1);
        vm.expectRevert("not deployer");
        registry.migrateSupporters(w, h, t);
    }

    function test_migrateSupporters_already_artist_reverts() public {
        _regArtist(alice, "alice.xyz");

        address[] memory w = new address[](1);
        string[] memory h = new string[](1);
        uint256[] memory t = new uint256[](1);
        w[0] = alice; h[0] = "alice-fan"; t[0] = 1;

        vm.expectRevert("already registered");
        registry.migrateSupporters(w, h, t);
    }

    function test_migrateFollows_success() public {
        _regArtist(alice, "alice.xyz");
        _regArtist(bob, "bob.xyz");
        _regSupporter(supporter1, "fanone");

        address[] memory followers = new address[](2);
        address[] memory followeds = new address[](2);
        followers[0] = supporter1; followeds[0] = alice;
        followers[1] = alice; followeds[1] = bob;

        registry.migrateFollows(followers, followeds);

        assertTrue(registry.isFollowing(supporter1, alice));
        assertTrue(registry.isFollowing(alice, bob));
        assertEq(registry.followingCount(supporter1), 1);
        assertEq(registry.followerCount(alice), 1); // supporter1 follows alice
    }

    function test_migrateFollows_skips_duplicates() public {
        _regArtist(alice, "alice.xyz");
        _regArtist(bob, "bob.xyz");

        // alice already follows bob
        vm.prank(alice);
        registry.follow(bob);

        // migration includes same follow — should skip
        address[] memory followers = new address[](1);
        address[] memory followeds = new address[](1);
        followers[0] = alice; followeds[0] = bob;

        registry.migrateFollows(followers, followeds);

        // should still be just 1 follow, not duplicated
        assertEq(registry.followingCount(alice), 1);
        assertEq(registry.followerCount(bob), 1);
    }

    function test_migrateFollows_non_deployer_reverts() public {
        address[] memory f = new address[](1);
        address[] memory t = new address[](1);
        f[0] = alice; t[0] = bob;

        vm.prank(alice);
        vm.expectRevert("not deployer");
        registry.migrateFollows(f, t);
    }

    // --- allSupporters view ---

    function test_allSupporters_view() public {
        _regSupporter(supporter1, "fanone");
        _regSupporter(supporter2, "fantwo");

        (address[] memory wallets, string[] memory handles) = registry.allSupporters();
        assertEq(wallets.length, 2);
        assertEq(wallets[0], supporter1);
        assertEq(wallets[1], supporter2);
        assertEq(handles[0], "fanone");
        assertEq(handles[1], "fantwo");
    }
}
