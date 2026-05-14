// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../ArtistRegistry.sol";
import "../PraxisOrganization.sol";

contract PraxisOrganizationTest is Test {
    // Mirror events from PraxisOrganization
    event OrgCreated(uint256 indexed orgId, address indexed admin, string name, string metadataCid);
    event MemberInvited(uint256 indexed orgId, address indexed wallet);
    event InviteAccepted(uint256 indexed orgId, address indexed wallet);
    event InviteDeclined(uint256 indexed orgId, address indexed wallet);
    event InviteRevoked(uint256 indexed orgId, address indexed wallet);
    event MemberRemoved(uint256 indexed orgId, address indexed wallet);
    event MemberLeft(uint256 indexed orgId, address indexed wallet);
    event MetadataUpdated(uint256 indexed orgId, string oldCid, string newCid);
    event AdminTransferred(uint256 indexed orgId, address indexed oldAdmin, address indexed newAdmin);
    event DomainUpdated(uint256 indexed orgId, string domain);
    event OrgDissolved(uint256 indexed orgId);

    ArtistRegistry registry;
    PraxisOrganization org;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address supporter1 = makeAddr("supporter1");
    address unregistered = makeAddr("unregistered");

    function setUp() public {
        registry = new ArtistRegistry();
        org = new PraxisOrganization(address(registry));

        registry.registerDirect(alice, "alice.xyz");
        registry.registerDirect(bob, "bob.xyz");
        registry.registerDirect(carol, "carol.xyz");
        registry.registerDirect(dave, "dave.xyz");

        vm.prank(supporter1);
        registry.registerSupporter("supporter1");
    }

    // ========== createOrg ==========

    function test_createOrg_success() public {
        vm.expectEmit(true, true, false, true);
        emit OrgCreated(0, alice, "My Label", "QmCid123");

        vm.prank(alice);
        uint256 id = org.createOrg("My Label", "QmCid123");

        assertEq(id, 0);
        assertEq(org.orgCount(), 1);
        (string memory name,, string memory metadataCid, address admin, uint256 createdAt, bool dissolved) = org.orgs(0);
        assertEq(name, "My Label");
        assertEq(metadataCid, "QmCid123");
        assertEq(admin, alice);
        assertGt(createdAt, 0);
        assertFalse(dissolved);
    }

    function test_createOrg_admin_is_first_member() public {
        vm.prank(alice);
        org.createOrg("Label", "");

        assertEq(org.memberCount(0), 1);
        assertTrue(org.isMember(0, alice));
        address[] memory members = org.getMembers(0);
        assertEq(members.length, 1);
        assertEq(members[0], alice);
    }

    function test_createOrg_empty_metadata() public {
        vm.prank(alice);
        uint256 id = org.createOrg("Minimal Org", "");
        assertEq(id, 0);
    }

    function test_createOrg_supporter_can_create() public {
        vm.prank(supporter1);
        uint256 id = org.createOrg("Fan Club", "");
        assertEq(id, 0);
        (, , , address admin, , ) = org.orgs(0);
        assertEq(admin, supporter1);
    }

    function test_createOrg_multiple_orgs() public {
        vm.prank(alice);
        uint256 id1 = org.createOrg("Org A", "");
        vm.prank(bob);
        uint256 id2 = org.createOrg("Org B", "");

        assertEq(id1, 0);
        assertEq(id2, 1);
        assertEq(org.orgCount(), 2);
    }

    function test_createOrg_unregistered_reverts() public {
        vm.prank(unregistered);
        vm.expectRevert(PraxisOrganization.NotUser.selector);
        org.createOrg("Bad Org", "");
    }

    function test_createOrg_emptyName_reverts() public {
        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.EmptyName.selector);
        org.createOrg("", "QmCid");
    }

    function test_createOrg_nameTooLong_reverts() public {
        // 257 bytes
        bytes memory longName = new bytes(257);
        for (uint256 i = 0; i < 257; i++) longName[i] = "A";

        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.NameTooLong.selector);
        org.createOrg(string(longName), "");
    }

    function test_createOrg_name256bytes_succeeds() public {
        bytes memory maxName = new bytes(256);
        for (uint256 i = 0; i < 256; i++) maxName[i] = "B";

        vm.prank(alice);
        uint256 id = org.createOrg(string(maxName), "");
        assertEq(id, 0);
    }

    function test_createOrg_cidTooLong_reverts() public {
        bytes memory longCid = new bytes(129);
        for (uint256 i = 0; i < 129; i++) longCid[i] = "C";

        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.CidTooLong.selector);
        org.createOrg("Ok Name", string(longCid));
    }

    function test_createOrg_cid128bytes_succeeds() public {
        bytes memory maxCid = new bytes(128);
        for (uint256 i = 0; i < 128; i++) maxCid[i] = "D";

        vm.prank(alice);
        uint256 id = org.createOrg("Ok Name", string(maxCid));
        assertEq(id, 0);
    }

    // ========== dissolveOrg ==========

    function test_dissolveOrg_success() public {
        vm.prank(alice);
        org.createOrg("To Dissolve", "");

        vm.expectEmit(true, false, false, false);
        emit OrgDissolved(0);

        vm.prank(alice);
        org.dissolveOrg(0);

        (, , , , , bool dissolved) = org.orgs(0);
        assertTrue(dissolved);
    }

    function test_dissolveOrg_nonAdmin_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(bob);
        vm.expectRevert(PraxisOrganization.NotAdmin.selector);
        org.dissolveOrg(0);
    }

    function test_dissolveOrg_alreadyDissolved_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(alice);
        org.dissolveOrg(0);

        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.OrgNotActive.selector);
        org.dissolveOrg(0);
    }

    function test_dissolveOrg_withMembers() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        // Invite and accept bob
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);

        assertEq(org.memberCount(0), 2);

        // Dissolve still works with members present
        vm.prank(alice);
        org.dissolveOrg(0);
        (, , , , , bool dissolved) = org.orgs(0);
        assertTrue(dissolved);
    }

    // ========== inviteMember ==========

    function test_inviteMember_success() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.expectEmit(true, true, false, false);
        emit MemberInvited(0, bob);

        vm.prank(alice);
        org.inviteMember(0, bob);

        assertTrue(org.isInvited(0, bob));
    }

    function test_inviteMember_nonAdmin_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(bob);
        vm.expectRevert(PraxisOrganization.NotAdmin.selector);
        org.inviteMember(0, carol);
    }

    function test_inviteMember_unregistered_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.NotUser.selector);
        org.inviteMember(0, unregistered);
    }

    function test_inviteMember_alreadyMember_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        // alice is already a member (admin)
        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.AlreadyMember.selector);
        org.inviteMember(0, alice);
    }

    function test_inviteMember_doubleInvite_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(alice);
        org.inviteMember(0, bob);

        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.AlreadyInvited.selector);
        org.inviteMember(0, bob);
    }

    function test_inviteMember_dissolved_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.dissolveOrg(0);

        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.OrgNotActive.selector);
        org.inviteMember(0, bob);
    }

    function test_inviteMember_supporter() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(alice);
        org.inviteMember(0, supporter1);
        assertTrue(org.isInvited(0, supporter1));
    }

    // ========== revokeInvite ==========

    function test_revokeInvite_success() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.inviteMember(0, bob);

        vm.expectEmit(true, true, false, false);
        emit InviteRevoked(0, bob);

        vm.prank(alice);
        org.revokeInvite(0, bob);

        assertFalse(org.isInvited(0, bob));
    }

    function test_revokeInvite_notInvited_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.NotInvited.selector);
        org.revokeInvite(0, bob);
    }

    function test_revokeInvite_nonAdmin_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.inviteMember(0, bob);

        vm.prank(carol);
        vm.expectRevert(PraxisOrganization.NotAdmin.selector);
        org.revokeInvite(0, bob);
    }

    function test_revokeInvite_thenReinvite() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(alice);
        org.revokeInvite(0, bob);

        // Can re-invite after revoking
        vm.prank(alice);
        org.inviteMember(0, bob);
        assertTrue(org.isInvited(0, bob));
    }

    // ========== acceptInvite ==========

    function test_acceptInvite_success() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.inviteMember(0, bob);

        vm.expectEmit(true, true, false, false);
        emit InviteAccepted(0, bob);

        vm.prank(bob);
        org.acceptInvite(0);

        assertTrue(org.isMember(0, bob));
        assertFalse(org.isInvited(0, bob));
        assertEq(org.memberCount(0), 2);
    }

    function test_acceptInvite_notInvited_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(bob);
        vm.expectRevert(PraxisOrganization.NotInvited.selector);
        org.acceptInvite(0);
    }

    function test_acceptInvite_dissolved_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(alice);
        org.dissolveOrg(0);

        vm.prank(bob);
        vm.expectRevert(PraxisOrganization.OrgNotActive.selector);
        org.acceptInvite(0);
    }

    // ========== declineInvite ==========

    function test_declineInvite_success() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.inviteMember(0, bob);

        vm.expectEmit(true, true, false, false);
        emit InviteDeclined(0, bob);

        vm.prank(bob);
        org.declineInvite(0);

        assertFalse(org.isInvited(0, bob));
        assertFalse(org.isMember(0, bob));
    }

    function test_declineInvite_notInvited_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(bob);
        vm.expectRevert(PraxisOrganization.NotInvited.selector);
        org.declineInvite(0);
    }

    function test_declineInvite_thenReinviteAndAccept() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.declineInvite(0);

        // Re-invite and accept
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);

        assertTrue(org.isMember(0, bob));
    }

    // ========== leaveOrg ==========

    function test_leaveOrg_success() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);

        vm.expectEmit(true, true, false, false);
        emit MemberLeft(0, bob);

        vm.prank(bob);
        org.leaveOrg(0);

        assertFalse(org.isMember(0, bob));
        assertEq(org.memberCount(0), 1);
    }

    function test_leaveOrg_notMember_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(bob);
        vm.expectRevert(PraxisOrganization.NotMember.selector);
        org.leaveOrg(0);
    }

    function test_leaveOrg_adminCannotLeave() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.CannotRemoveAdmin.selector);
        org.leaveOrg(0);
    }

    function test_leaveOrg_updatesReverseIndex() public {
        vm.prank(alice);
        org.createOrg("Org A", "");
        vm.prank(alice);
        org.createOrg("Org B", "");

        // Bob joins both orgs
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);

        vm.prank(alice);
        org.inviteMember(1, bob);
        vm.prank(bob);
        org.acceptInvite(1);

        uint256[] memory bobOrgs = org.getOrgsByMember(bob);
        assertEq(bobOrgs.length, 2);

        // Leave org 0
        vm.prank(bob);
        org.leaveOrg(0);

        bobOrgs = org.getOrgsByMember(bob);
        assertEq(bobOrgs.length, 1);
        assertEq(bobOrgs[0], 1);
    }

    // ========== removeMember ==========

    function test_removeMember_success() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);

        vm.expectEmit(true, true, false, false);
        emit MemberRemoved(0, bob);

        vm.prank(alice);
        org.removeMember(0, bob);

        assertFalse(org.isMember(0, bob));
        assertEq(org.memberCount(0), 1);
    }

    function test_removeMember_nonAdmin_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);

        vm.prank(bob);
        vm.expectRevert(PraxisOrganization.NotAdmin.selector);
        org.removeMember(0, bob);
    }

    function test_removeMember_notMember_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.NotMember.selector);
        org.removeMember(0, bob);
    }

    function test_removeMember_cannotRemoveAdmin() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.CannotRemoveAdmin.selector);
        org.removeMember(0, alice);
    }

    function test_removeMember_thenReinvite() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);

        vm.prank(alice);
        org.removeMember(0, bob);

        // Can re-invite after removal
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);

        assertTrue(org.isMember(0, bob));
        assertEq(org.memberCount(0), 2);
    }

    // ========== updateMetadata ==========

    function test_updateMetadata_success() public {
        vm.prank(alice);
        org.createOrg("Org", "QmOld");

        vm.expectEmit(true, false, false, true);
        emit MetadataUpdated(0, "QmOld", "QmNew");

        vm.prank(alice);
        org.updateMetadata(0, "QmNew");

        (, , string memory cid, , , ) = org.orgs(0);
        assertEq(cid, "QmNew");
    }

    function test_updateMetadata_nonAdmin_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(bob);
        vm.expectRevert(PraxisOrganization.NotAdmin.selector);
        org.updateMetadata(0, "QmNew");
    }

    function test_updateMetadata_cidTooLong_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        bytes memory longCid = new bytes(129);
        for (uint256 i = 0; i < 129; i++) longCid[i] = "X";

        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.CidTooLong.selector);
        org.updateMetadata(0, string(longCid));
    }

    function test_updateMetadata_dissolved_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.dissolveOrg(0);

        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.OrgNotActive.selector);
        org.updateMetadata(0, "QmNew");
    }

    function test_updateMetadata_emptyCid() public {
        vm.prank(alice);
        org.createOrg("Org", "QmSomething");

        vm.prank(alice);
        org.updateMetadata(0, "");

        (, , string memory cid, , , ) = org.orgs(0);
        assertEq(cid, "");
    }

    // ========== updateDomain ==========

    function test_updateDomain_success() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.expectEmit(true, false, false, true);
        emit DomainUpdated(0, "mylabel.xyz");

        vm.prank(alice);
        org.updateDomain(0, "mylabel.xyz");

        (, string memory domain, , , , ) = org.orgs(0);
        assertEq(domain, "mylabel.xyz");
    }

    function test_updateDomain_nonAdmin_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(bob);
        vm.expectRevert(PraxisOrganization.NotAdmin.selector);
        org.updateDomain(0, "evil.xyz");
    }

    function test_updateDomain_tooLong_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        bytes memory longDomain = new bytes(254);
        for (uint256 i = 0; i < 254; i++) longDomain[i] = "a";

        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.DomainTooLong.selector);
        org.updateDomain(0, string(longDomain));
    }

    function test_updateDomain_253bytes_succeeds() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        bytes memory maxDomain = new bytes(253);
        for (uint256 i = 0; i < 253; i++) maxDomain[i] = "z";

        vm.prank(alice);
        org.updateDomain(0, string(maxDomain));

        (, string memory domain, , , , ) = org.orgs(0);
        assertEq(bytes(domain).length, 253);
    }

    function test_updateDomain_emptyClears() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.updateDomain(0, "example.com");

        vm.prank(alice);
        org.updateDomain(0, "");

        (, string memory domain, , , , ) = org.orgs(0);
        assertEq(domain, "");
    }

    function test_updateDomain_dissolved_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.dissolveOrg(0);

        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.OrgNotActive.selector);
        org.updateDomain(0, "dead.xyz");
    }

    // ========== transferAdmin ==========

    function test_transferAdmin_success() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);

        vm.expectEmit(true, true, true, false);
        emit AdminTransferred(0, alice, bob);

        vm.prank(alice);
        org.transferAdmin(0, bob);

        (, , , address admin, , ) = org.orgs(0);
        assertEq(admin, bob);
    }

    function test_transferAdmin_nonAdmin_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);

        vm.prank(bob);
        vm.expectRevert(PraxisOrganization.NotAdmin.selector);
        org.transferAdmin(0, bob);
    }

    function test_transferAdmin_toNonMember_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.NotMember.selector);
        org.transferAdmin(0, bob);
    }

    function test_transferAdmin_newAdminCanAct() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);

        vm.prank(alice);
        org.transferAdmin(0, bob);

        // Bob (new admin) can invite
        vm.prank(bob);
        org.inviteMember(0, carol);
        assertTrue(org.isInvited(0, carol));

        // Alice (old admin) cannot invite
        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.NotAdmin.selector);
        org.inviteMember(0, dave);
    }

    function test_transferAdmin_oldAdminCanLeave() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);

        vm.prank(alice);
        org.transferAdmin(0, bob);

        // Old admin (alice) is no longer admin, so she can leave
        vm.prank(alice);
        org.leaveOrg(0);

        assertFalse(org.isMember(0, alice));
        assertEq(org.memberCount(0), 1);
    }

    function test_transferAdmin_dissolved_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);
        vm.prank(alice);
        org.dissolveOrg(0);

        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.OrgNotActive.selector);
        org.transferAdmin(0, bob);
    }

    // ========== getMembers / memberCount ==========

    function test_getMembers_empty_after_all_leave() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);

        // Transfer admin to bob so alice can leave
        vm.prank(alice);
        org.transferAdmin(0, bob);
        vm.prank(alice);
        org.leaveOrg(0);

        assertEq(org.memberCount(0), 1);
        address[] memory members = org.getMembers(0);
        assertEq(members.length, 1);
        assertEq(members[0], bob);
    }

    function test_memberCount_multipleMembers() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);

        vm.prank(alice);
        org.inviteMember(0, carol);
        vm.prank(carol);
        org.acceptInvite(0);

        vm.prank(alice);
        org.inviteMember(0, dave);
        vm.prank(dave);
        org.acceptInvite(0);

        assertEq(org.memberCount(0), 4);
        address[] memory members = org.getMembers(0);
        assertEq(members.length, 4);
    }

    function test_getMembers_swapAndPop_integrity() public {
        // Test that swap-and-pop removal keeps array consistent
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);

        vm.prank(alice);
        org.inviteMember(0, carol);
        vm.prank(carol);
        org.acceptInvite(0);

        vm.prank(alice);
        org.inviteMember(0, dave);
        vm.prank(dave);
        org.acceptInvite(0);

        // Remove bob (index 1, middle element) — swap-and-pop
        vm.prank(alice);
        org.removeMember(0, bob);

        assertEq(org.memberCount(0), 3);
        assertFalse(org.isMember(0, bob));
        assertTrue(org.isMember(0, alice));
        assertTrue(org.isMember(0, carol));
        assertTrue(org.isMember(0, dave));
    }

    // ========== getOrgsByMember ==========

    function test_getOrgsByMember_admin() public {
        vm.prank(alice);
        org.createOrg("Org A", "");
        vm.prank(alice);
        org.createOrg("Org B", "");

        uint256[] memory aliceOrgs = org.getOrgsByMember(alice);
        assertEq(aliceOrgs.length, 2);
        assertEq(aliceOrgs[0], 0);
        assertEq(aliceOrgs[1], 1);
    }

    function test_getOrgsByMember_multipleOrgs() public {
        vm.prank(alice);
        org.createOrg("Org A", "");
        vm.prank(bob);
        org.createOrg("Org B", "");

        // Carol joins both
        vm.prank(alice);
        org.inviteMember(0, carol);
        vm.prank(carol);
        org.acceptInvite(0);

        vm.prank(bob);
        org.inviteMember(1, carol);
        vm.prank(carol);
        org.acceptInvite(1);

        uint256[] memory carolOrgs = org.getOrgsByMember(carol);
        assertEq(carolOrgs.length, 2);
    }

    function test_getOrgsByMember_emptyForNonMember() public {
        uint256[] memory orgs_ = org.getOrgsByMember(unregistered);
        assertEq(orgs_.length, 0);
    }

    function test_getOrgsByMember_afterLeaving() public {
        vm.prank(alice);
        org.createOrg("Org", "");

        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);

        uint256[] memory bobOrgs = org.getOrgsByMember(bob);
        assertEq(bobOrgs.length, 1);

        vm.prank(bob);
        org.leaveOrg(0);

        bobOrgs = org.getOrgsByMember(bob);
        assertEq(bobOrgs.length, 0);
    }

    // ========== Edge cases ==========

    function test_operations_on_dissolved_org() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(bob);
        org.acceptInvite(0);

        vm.prank(alice);
        org.dissolveOrg(0);

        // Cannot invite after dissolve
        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.OrgNotActive.selector);
        org.inviteMember(0, carol);

        // Cannot remove after dissolve
        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.OrgNotActive.selector);
        org.removeMember(0, bob);

        // Cannot update metadata after dissolve
        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.OrgNotActive.selector);
        org.updateMetadata(0, "QmNew");

        // Cannot update domain after dissolve
        vm.prank(alice);
        vm.expectRevert(PraxisOrganization.OrgNotActive.selector);
        org.updateDomain(0, "dead.xyz");
    }

    function test_acceptInvite_after_revoke_reverts() public {
        vm.prank(alice);
        org.createOrg("Org", "");
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(alice);
        org.revokeInvite(0, bob);

        vm.prank(bob);
        vm.expectRevert(PraxisOrganization.NotInvited.selector);
        org.acceptInvite(0);
    }

    function test_fullLifecycle() public {
        // Create
        vm.prank(alice);
        uint256 id = org.createOrg("Theatre Co", "QmTheatre");
        assertEq(id, 0);

        // Invite bob and carol
        vm.prank(alice);
        org.inviteMember(0, bob);
        vm.prank(alice);
        org.inviteMember(0, carol);

        // Bob accepts, carol declines
        vm.prank(bob);
        org.acceptInvite(0);
        vm.prank(carol);
        org.declineInvite(0);

        assertEq(org.memberCount(0), 2);
        assertTrue(org.isMember(0, bob));
        assertFalse(org.isMember(0, carol));

        // Update metadata
        vm.prank(alice);
        org.updateMetadata(0, "QmTheatreV2");

        // Update domain
        vm.prank(alice);
        org.updateDomain(0, "theatre.co");

        // Transfer admin to bob
        vm.prank(alice);
        org.transferAdmin(0, bob);

        // Alice leaves
        vm.prank(alice);
        org.leaveOrg(0);
        assertEq(org.memberCount(0), 1);

        // Bob (new admin) invites dave
        vm.prank(bob);
        org.inviteMember(0, dave);
        vm.prank(dave);
        org.acceptInvite(0);
        assertEq(org.memberCount(0), 2);

        // Bob dissolves
        vm.prank(bob);
        org.dissolveOrg(0);
        (, , , , , bool dissolved) = org.orgs(0);
        assertTrue(dissolved);
    }

    function test_immutableRegistry() public view {
        assertEq(address(org.REGISTRY()), address(registry));
    }

    function test_orgCount_starts_at_zero() public view {
        assertEq(org.orgCount(), 0);
    }
}
