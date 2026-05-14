// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../ArtistRegistry.sol";
import "../PraxisInvites.sol";

contract PraxisInvitesTest is Test {
    event InviteCreated(address indexed inviter, bytes32 indexed codeHash);
    event InviteUsed(address indexed invitee, address indexed inviter, bytes32 indexed codeHash);

    ArtistRegistry registry;
    PraxisInvites invites;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    uint256 orchestratorPk = 0xA11CE;
    address orchestratorAddr;

    bytes32 constant USE_INVITE_TYPEHASH =
        keccak256("UseInvite(bytes32 codeHash,address invitee,uint256 expiry,bytes32 nonce)");

    function setUp() public {
        registry = new ArtistRegistry();
        invites = new PraxisInvites(address(registry), bytes32(0));
        orchestratorAddr = vm.addr(orchestratorPk);
        registry.setOrchestrator(orchestratorAddr);

        registry.registerDirect(alice, "alice.xyz");
    }

    /// @dev Sign a UseInvite EIP-712 authorization for `invitee`
    function _signUse(string memory code, address invitee)
        internal
        view
        returns (uint256 expiry, bytes32 nonce, bytes memory sig)
    {
        expiry = block.timestamp + 30 minutes;
        nonce = keccak256(abi.encodePacked(code, invitee, expiry, block.number));
        bytes32 codeHash = keccak256(abi.encodePacked(code));
        bytes32 structHash = keccak256(abi.encode(USE_INVITE_TYPEHASH, codeHash, invitee, expiry, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", invites.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orchestratorPk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _useInvite(string memory code, address invitee) internal {
        (uint256 expiry, bytes32 nonce, bytes memory sig) = _signUse(code, invitee);
        vm.prank(invitee);
        invites.useInvite(code, expiry, nonce, sig);
    }

    // --- Grant invites ---

    function test_grantInvites() public {
        invites.grantInvites(alice, 10);
        assertEq(invites.invitesRemaining(alice), 10);
    }

    function test_grantInvites_non_deployer_reverts() public {
        vm.prank(alice);
        vm.expectRevert("not authorized");
        invites.grantInvites(alice, 10);
    }

    // --- Create invite ---

    function test_createInvite() public {
        invites.grantInvites(alice, 10);

        bytes32 codeHash = keccak256(abi.encodePacked("praxis-abc123"));

        vm.expectEmit(true, true, false, false);
        emit InviteCreated(alice, codeHash);

        vm.prank(alice);
        invites.createInvite(codeHash);

        assertEq(invites.invitesRemaining(alice), 9);
        assertEq(invites.inviteCodeOwner(codeHash), alice);
    }

    function test_createInvite_no_invites_reverts() public {
        // alice has 0 invites
        bytes32 codeHash = keccak256(abi.encodePacked("test"));

        vm.prank(alice);
        vm.expectRevert("no invites");
        invites.createInvite(codeHash);
    }

    function test_createInvite_unregistered_reverts() public {
        invites.grantInvites(bob, 10);
        bytes32 codeHash = keccak256(abi.encodePacked("test"));

        vm.prank(bob); // not registered
        vm.expectRevert("not registered");
        invites.createInvite(codeHash);
    }

    function test_createInvite_duplicate_reverts() public {
        invites.grantInvites(alice, 10);
        bytes32 codeHash = keccak256(abi.encodePacked("test"));

        vm.prank(alice);
        invites.createInvite(codeHash);

        vm.prank(alice);
        vm.expectRevert("code exists");
        invites.createInvite(codeHash);
    }

    // --- Use invite ---

    function test_useInvite() public {
        invites.grantInvites(alice, 10);

        string memory code = "praxis-abc123";
        bytes32 codeHash = keccak256(abi.encodePacked(code));

        vm.prank(alice);
        invites.createInvite(codeHash);

        vm.expectEmit(true, true, true, false);
        emit InviteUsed(bob, alice, codeHash);

        _useInvite(code, bob);

        assertTrue(invites.codeUsed(codeHash));
        assertEq(invites.invitedBy(bob), alice);
        assertEq(invites.invitesRemaining(bob), 10); // new member gets 10
    }

    function test_useInvite_invalid_code_reverts() public {
        (uint256 expiry, bytes32 nonce, bytes memory sig) = _signUse("nonexistent", bob);
        vm.prank(bob);
        vm.expectRevert("invalid code");
        invites.useInvite("nonexistent", expiry, nonce, sig);
    }

    function test_useInvite_already_used_reverts() public {
        invites.grantInvites(alice, 10);
        string memory code = "test-code";
        bytes32 codeHash = keccak256(abi.encodePacked(code));

        vm.prank(alice);
        invites.createInvite(codeHash);

        _useInvite(code, bob);

        (uint256 expiry, bytes32 nonce, bytes memory sig) = _signUse(code, charlie);
        vm.prank(charlie);
        vm.expectRevert("code used");
        invites.useInvite(code, expiry, nonce, sig);
    }

    // --- EIP-712 hardening for useInvite ---

    function test_useInvite_invalid_signer_reverts() public {
        invites.grantInvites(alice, 10);
        string memory code = "badsig";
        vm.prank(alice);
        invites.createInvite(keccak256(abi.encodePacked(code)));

        uint256 expiry = block.timestamp + 30 minutes;
        bytes32 nonce = keccak256("nonce-badsig");
        bytes32 codeHash = keccak256(abi.encodePacked(code));
        bytes32 structHash = keccak256(abi.encode(USE_INVITE_TYPEHASH, codeHash, bob, expiry, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", invites.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBEEF, digest);

        vm.prank(bob);
        vm.expectRevert("invalid orch sig");
        invites.useInvite(code, expiry, nonce, abi.encodePacked(r, s, v));
    }

    function test_useInvite_recipient_substitution_reverts() public {
        invites.grantInvites(alice, 10);
        string memory code = "frontrun";
        vm.prank(alice);
        invites.createInvite(keccak256(abi.encodePacked(code)));

        // sig binds bob; charlie tries to steal
        (uint256 expiry, bytes32 nonce, bytes memory sig) = _signUse(code, bob);
        vm.prank(charlie);
        vm.expectRevert("invalid orch sig");
        invites.useInvite(code, expiry, nonce, sig);
    }

    function test_useInvite_paused_reverts() public {
        invites.grantInvites(alice, 10);
        string memory code = "pausedcode";
        vm.prank(alice);
        invites.createInvite(keccak256(abi.encodePacked(code)));

        invites.setPaused(true);

        (uint256 expiry, bytes32 nonce, bytes memory sig) = _signUse(code, bob);
        vm.prank(bob);
        vm.expectRevert("paused");
        invites.useInvite(code, expiry, nonce, sig);
    }

    // --- claimInitialInvites: trustless self-claim for the missing-grant gap ---

    function test_claimInitialInvites_grants_10() public {
        // alice is registered (via setUp). She has 0 invites because nobody granted any.
        assertEq(invites.invitesRemaining(alice), 0);

        vm.prank(alice);
        invites.claimInitialInvites();

        assertEq(invites.invitesRemaining(alice), 10);
        assertTrue(invites.initialClaimed(alice));
    }

    function test_claimInitialInvites_unregistered_reverts() public {
        // bob is not registered
        vm.prank(bob);
        vm.expectRevert("not registered");
        invites.claimInitialInvites();
    }

    function test_claimInitialInvites_double_reverts() public {
        vm.prank(alice);
        invites.claimInitialInvites();
        vm.prank(alice);
        vm.expectRevert("already claimed");
        invites.claimInitialInvites();
    }

    function test_claimInitialInvites_stacks_with_grants() public {
        // alice gets a deployer grant first, then claims initial — both should accumulate
        invites.grantInvites(alice, 50);
        assertEq(invites.invitesRemaining(alice), 50);

        vm.prank(alice);
        invites.claimInitialInvites();

        assertEq(invites.invitesRemaining(alice), 60);
    }

    function test_claimInitialInvites_respects_invitesPerRegistration() public {
        // Change the per-registration count
        invites.setInvitesPerRegistration(25);

        vm.prank(alice);
        invites.claimInitialInvites();

        assertEq(invites.invitesRemaining(alice), 25);
    }

    function test_useInvite_nonce_replay_reverts() public {
        invites.grantInvites(alice, 10);
        vm.startPrank(alice);
        invites.createInvite(keccak256(abi.encodePacked("rp1")));
        invites.createInvite(keccak256(abi.encodePacked("rp2")));
        vm.stopPrank();

        uint256 expiry = block.timestamp + 30 minutes;
        bytes32 nonce = keccak256("shared-nonce");

        bytes32 ch1 = keccak256(abi.encodePacked("rp1"));
        bytes32 sh1 = keccak256(abi.encode(USE_INVITE_TYPEHASH, ch1, bob, expiry, nonce));
        bytes32 d1 = keccak256(abi.encodePacked("\x19\x01", invites.DOMAIN_SEPARATOR(), sh1));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(orchestratorPk, d1);
        vm.prank(bob);
        invites.useInvite("rp1", expiry, nonce, abi.encodePacked(r1, s1, v1));

        bytes32 ch2 = keccak256(abi.encodePacked("rp2"));
        bytes32 sh2 = keccak256(abi.encode(USE_INVITE_TYPEHASH, ch2, charlie, expiry, nonce));
        bytes32 d2 = keccak256(abi.encodePacked("\x19\x01", invites.DOMAIN_SEPARATOR(), sh2));
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(orchestratorPk, d2);
        vm.prank(charlie);
        vm.expectRevert("nonce used");
        invites.useInvite("rp2", expiry, nonce, abi.encodePacked(r2, s2, v2));
    }

    // --- Batch create ---

    function test_batchCreateInvites() public {
        invites.grantInvites(alice, 10);

        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = keccak256(abi.encodePacked("code1"));
        hashes[1] = keccak256(abi.encodePacked("code2"));
        hashes[2] = keccak256(abi.encodePacked("code3"));

        vm.prank(alice);
        invites.createInvites(hashes);

        assertEq(invites.invitesRemaining(alice), 7);
        assertEq(invites.inviteCodeOwner(hashes[0]), alice);
        assertEq(invites.inviteCodeOwner(hashes[1]), alice);
        assertEq(invites.inviteCodeOwner(hashes[2]), alice);
    }

    function test_batchCreate_not_enough_reverts() public {
        invites.grantInvites(alice, 2);

        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = keccak256(abi.encodePacked("a"));
        hashes[1] = keccak256(abi.encodePacked("b"));
        hashes[2] = keccak256(abi.encodePacked("c"));

        vm.prank(alice);
        vm.expectRevert("not enough invites");
        invites.createInvites(hashes);
    }

    // --- Integration ---

    function test_invite_chain() public {
        // alice invites bob, bob invites charlie
        invites.grantInvites(alice, 10);

        string memory code1 = "invite-bob";
        vm.prank(alice);
        invites.createInvite(keccak256(abi.encodePacked(code1)));

        // bob uses invite and registers
        _useInvite(code1, bob);
        registry.registerDirect(bob, "bob.xyz");

        // bob now has 10 invites, creates one for charlie
        string memory code2 = "invite-charlie";
        vm.prank(bob);
        invites.createInvite(keccak256(abi.encodePacked(code2)));

        _useInvite(code2, charlie);

        // verify chain
        assertEq(invites.invitedBy(bob), alice);
        assertEq(invites.invitedBy(charlie), bob);
        assertEq(invites.invitesRemaining(bob), 9);
        assertEq(invites.invitesRemaining(charlie), 10);
    }
}
