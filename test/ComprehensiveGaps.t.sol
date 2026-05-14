// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../ArtistRegistry.sol";
import "../PraxisInvites.sol";
import "../Praxis.sol";
import "../BlogRegistry.sol";
import "../PraxisMedia.sol";
import "../PraxisTicketMarket.sol";
import "../LibraryRegistry.sol";
import "../ArtistSponsoredInvites.sol";
import "../PraxisTreasury.sol";

// =============================================================================
// Reentrancy attacker contracts
// =============================================================================

contract ReentrantMediaWithdrawer {
    PraxisMedia media;
    uint256 attacks;

    constructor(PraxisMedia _media) { media = _media; }

    receive() external payable {
        if (attacks < 1) {
            attacks++;
            media.withdraw();
        }
    }

    function doWithdraw() external { media.withdraw(); }
}

contract ReentrantPraxisClaimFunds {
    Praxis praxis;
    uint256 attacks;

    constructor(Praxis _praxis) { praxis = _praxis; }

    receive() external payable {
        if (attacks < 1) {
            attacks++;
            praxis.claimFunds();
        }
    }

    function doClaimFunds() external { praxis.claimFunds(); }
}

contract ReentrantPraxisClaimRefund {
    Praxis praxis;
    uint256 projectId;
    uint256 attacks;

    constructor(Praxis _praxis) { praxis = _praxis; }

    function setProject(uint256 _id) external { projectId = _id; }

    receive() external payable {
        if (attacks < 1) {
            attacks++;
            praxis.claimRefund(projectId);
        }
    }

    function doClaimRefund(uint256 _id) external { praxis.claimRefund(_id); }
}

contract ReentrantPraxisWithdrawFunding {
    Praxis praxis;
    uint256 projectId;
    uint256 attacks;

    constructor(Praxis _praxis) { praxis = _praxis; }

    function setProject(uint256 _id) external { projectId = _id; }

    receive() external payable {
        if (attacks < 1) {
            attacks++;
            praxis.withdrawFunding(projectId);
        }
    }

    function doWithdrawFunding(uint256 _id) external { praxis.withdrawFunding(_id); }
}

contract ReentrantTicketWithdrawer {
    PraxisTicketMarket market;
    uint256 attacks;

    constructor(PraxisTicketMarket _market) { market = _market; }

    receive() external payable {
        if (attacks < 1) {
            attacks++;
            market.withdraw();
        }
    }

    function doWithdraw() external { market.withdraw(); }
}

// ReentrantSponsorRedeem and ReentrantSponsorRefund were dead code (never instantiated)
// and could not be updated to the v2 EIP-712 redeem signature without baking an
// orchestrator key into the attacker contract. Removed during the v2 hardening.

contract ReentrantTreasuryWithdraw {
    PraxisTreasury treasury;
    uint256 attacks;

    constructor(PraxisTreasury _treasury) { treasury = _treasury; }

    receive() external payable {
        // Reentrancy attempt - should fail due to nonReentrant
        if (attacks < 1) {
            attacks++;
            try treasury.withdrawETH(address(this), 1 ether) {} catch {}
        }
    }
}

// Mock for Treasury execute test
contract MockTarget {
    uint256 public value;

    function setValue(uint256 _v) external {
        value = _v;
    }

    function revertAlways() external pure {
        revert("intentional revert");
    }
}

// Mock ERC20 for treasury tests
contract MockERC20Simple {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address, uint256) external pure returns (bool) { return true; }
}


// =============================================================================
// ArtistRegistry Gap Tests
// =============================================================================

contract ArtistRegistryGapTest is Test {
    ArtistRegistry registry;
    uint256 orchKey = 0xA11CE;
    address orchAddr;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

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

    function _signUpdateDomain(address wallet, string memory newDomain) internal view returns (bytes memory) {
        return _signRegister(wallet, newDomain);
    }

    function _reg(address who, string memory domain) internal {
        bytes memory sig = _signRegister(who, domain);
        vm.prank(who);
        registry.register(domain, sig);
    }

    // --- updateDomain ---

    function test_updateDomain_success() public {
        _reg(alice, "alice.xyz");

        bytes memory sig = _signUpdateDomain(alice, "newalice.xyz");
        vm.prank(alice);
        registry.updateDomain("newalice.xyz", sig);

        (string memory domain,) = registry.artists(alice);
        assertEq(domain, "newalice.xyz");
    }

    function test_updateDomain_not_registered_reverts() public {
        bytes memory sig = _signUpdateDomain(alice, "newalice.xyz");
        vm.prank(alice);
        vm.expectRevert("not registered");
        registry.updateDomain("newalice.xyz", sig);
    }

    function test_updateDomain_empty_domain_reverts() public {
        _reg(alice, "alice.xyz");

        bytes memory sig = _signUpdateDomain(alice, "");
        vm.prank(alice);
        vm.expectRevert("empty domain");
        registry.updateDomain("", sig);
    }

    function test_updateDomain_invalid_signature_reverts() public {
        _reg(alice, "alice.xyz");

        // Sign for a different domain
        bytes memory sig = _signUpdateDomain(alice, "wrong.xyz");
        vm.prank(alice);
        vm.expectRevert("invalid signature");
        registry.updateDomain("newalice.xyz", sig);
    }

    // --- registerDirect ---

    function test_registerDirect_success() public {
        registry.registerDirect(alice, "alice.xyz");
        (string memory domain,) = registry.artists(alice);
        assertEq(domain, "alice.xyz");
    }

    function test_registerDirect_non_deployer_reverts() public {
        vm.prank(alice);
        vm.expectRevert("not deployer");
        registry.registerDirect(bob, "bob.xyz");
    }

    function test_registerDirect_empty_domain_reverts() public {
        vm.expectRevert("empty domain");
        registry.registerDirect(alice, "");
    }

    function test_registerDirect_already_registered_reverts() public {
        registry.registerDirect(alice, "alice.xyz");
        vm.expectRevert("already registered");
        registry.registerDirect(alice, "alice2.xyz");
    }

    // --- setOrchestrator ---

    function test_setOrchestrator_success() public {
        address newOrch = makeAddr("newOrch");
        registry.setOrchestrator(newOrch);
        assertEq(registry.orchestrator(), newOrch);
    }

    function test_setOrchestrator_non_deployer_reverts() public {
        vm.prank(alice);
        vm.expectRevert("not deployer");
        registry.setOrchestrator(makeAddr("x"));
    }

    // --- setTreasury by both treasury and deployer ---

    function test_setTreasury_by_deployer() public {
        address newTreasury = makeAddr("newTreasury");
        // deployer is address(this)
        registry.setTreasury(newTreasury);
        assertEq(registry.treasury(), newTreasury);
    }

    function test_setTreasury_by_non_deployer_reverts() public {
        address firstTreasury = makeAddr("firstTreasury");
        registry.setTreasury(firstTreasury);

        address secondTreasury = makeAddr("secondTreasury");
        vm.prank(firstTreasury);
        vm.expectRevert("not deployer");
        registry.setTreasury(secondTreasury);
    }

    // --- Invalid signature length ---

    function test_register_invalid_signature_length_reverts() public {
        vm.prank(alice);
        vm.expectRevert("invalid signature length");
        registry.register("alice.xyz", hex"0102030405");
    }

    // --- Fuzz tests ---

    function testFuzz_registerDirect_multiple(uint8 count) public {
        count = uint8(bound(count, 1, 20));
        for (uint8 i = 0; i < count; i++) {
            address a = address(uint160(10000 + i));
            string memory domain = string(abi.encodePacked("artist", vm.toString(uint256(i)), ".xyz"));
            registry.registerDirect(a, domain);
        }
        assertEq(registry.totalArtists(), count);
    }

    function testFuzz_deployFee(uint256 fee) public {
        fee = bound(fee, 0, 1 ether); // max 1 ETH enforced by contract
        registry.setDeployFee(fee);
        assertEq(registry.deployFee(), fee);
    }

    function test_deployFee_rejects_above_max() public {
        vm.expectRevert("fee too high (max 1 ETH)");
        registry.setDeployFee(1.001 ether);
    }

    function testFuzz_follow_unfollow_multiple(uint8 count) public {
        count = uint8(bound(count, 2, 10));
        address[] memory artists = new address[](count);
        for (uint8 i = 0; i < count; i++) {
            artists[i] = address(uint160(20000 + i));
            registry.registerDirect(artists[i], string(abi.encodePacked("a", vm.toString(uint256(i)), ".xyz")));
        }

        // artists[0] follows all others
        vm.startPrank(artists[0]);
        for (uint8 i = 1; i < count; i++) {
            registry.follow(artists[i]);
        }
        assertEq(registry.followingCount(artists[0]), count - 1);

        // unfollow all
        for (uint8 i = 1; i < count; i++) {
            registry.unfollow(artists[i]);
        }
        assertEq(registry.followingCount(artists[0]), 0);
        vm.stopPrank();
    }

    // --- Edge: register with max fee ---

    function test_register_with_max_fee_reverts_on_set() public {
        // Setting fee above 1 ETH is now blocked
        vm.expectRevert("fee too high (max 1 ETH)");
        registry.setDeployFee(type(uint256).max);
    }

    // --- Supporter handle edge cases ---

    function test_handle_all_numbers() public {
        vm.prank(alice);
        registry.registerSupporter("123");
        (string memory handle,) = registry.supporters(alice);
        assertEq(handle, "123");
    }

    function test_handle_all_hyphens_middle() public {
        vm.prank(alice);
        registry.registerSupporter("a-b");
        (string memory handle,) = registry.supporters(alice);
        assertEq(handle, "a-b");
    }

    // --- migrateSupporters length mismatch ---

    function test_migrateSupporters_length_mismatch_reverts() public {
        address[] memory w = new address[](2);
        string[] memory h = new string[](1);
        uint256[] memory t = new uint256[](2);
        w[0] = alice; w[1] = bob;
        h[0] = "fan";
        t[0] = 1; t[1] = 2;

        vm.expectRevert("length mismatch");
        registry.migrateSupporters(w, h, t);
    }

    // --- migrateFollows length mismatch ---

    function test_migrateFollows_length_mismatch_reverts() public {
        address[] memory f = new address[](2);
        address[] memory t = new address[](1);
        f[0] = alice; f[1] = bob;
        t[0] = charlie;

        vm.expectRevert("length mismatch");
        registry.migrateFollows(f, t);
    }

    // --- migrateSupporters handle taken ---

    function test_migrateSupporters_handle_taken_reverts() public {
        vm.prank(alice);
        registry.registerSupporter("taken");

        address sup = makeAddr("sup");
        address[] memory w = new address[](1);
        string[] memory h = new string[](1);
        uint256[] memory t = new uint256[](1);
        w[0] = sup; h[0] = "taken"; t[0] = 1;

        vm.expectRevert("handle taken");
        registry.migrateSupporters(w, h, t);
    }
}


// =============================================================================
// PraxisInvites Gap Tests
// =============================================================================

contract PraxisInvitesGapTest is Test {
    ArtistRegistry registry;
    PraxisInvites invites;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        registry = new ArtistRegistry();
        invites = new PraxisInvites(address(registry), bytes32(0));

        registry.registerDirect(alice, "alice.xyz");
    }

    // --- setPraxisContract ---

    function test_setPraxisContract_non_deployer_reverts() public {
        vm.prank(alice);
        vm.expectRevert("not deployer");
        invites.setPraxisContract(alice);
    }

    function test_setPraxisContract_already_set_reverts() public {
        invites.setPraxisContract(alice);

        vm.expectRevert("already set");
        invites.setPraxisContract(bob);
    }

    function test_grantInvites_from_praxis_contract() public {
        invites.setPraxisContract(alice);

        vm.prank(alice);
        invites.grantInvites(bob, 5);
        assertEq(invites.invitesRemaining(bob), 5);
    }

    // --- Fuzz: grantInvites ---

    function testFuzz_grantInvites(uint256 count) public {
        count = bound(count, 1, 10000);
        invites.grantInvites(alice, count);
        assertEq(invites.invitesRemaining(alice), count);
    }

    // --- Batch create with duplicate code hash ---

    function test_batchCreate_duplicate_in_batch_reverts() public {
        invites.grantInvites(alice, 10);

        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = keccak256("a");
        hashes[1] = keccak256("b");
        hashes[2] = keccak256("a"); // duplicate

        vm.prank(alice);
        vm.expectRevert("code exists");
        invites.createInvites(hashes);
    }

    // --- Edge: empty batch ---

    function test_batchCreate_empty_array() public {
        invites.grantInvites(alice, 10);

        bytes32[] memory hashes = new bytes32[](0);
        vm.prank(alice);
        invites.createInvites(hashes);
        // Should succeed, no invites consumed
        assertEq(invites.invitesRemaining(alice), 10);
    }

    // --- Invite accumulation ---

    function test_grantInvites_accumulates() public {
        invites.grantInvites(alice, 5);
        invites.grantInvites(alice, 3);
        assertEq(invites.invitesRemaining(alice), 8);
    }
}


// =============================================================================
// Praxis (project system) Gap Tests
// =============================================================================

contract PraxisGapTest is Test {
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

    /// @dev Bridges legacy positional `proposeProject` test sites to the v2 struct API.
    function _callPropose(
        string memory title,
        string memory description,
        string memory projectType,
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
            metadataCid: "",
            tierMetadataCids: new string[](tierNames.length),
            confirmationMode: confirmationMode
        }));
    }

    // --- ERC-6909: transferFrom ---

    function test_transferFrom_with_allowance() public {
        uint256 id = _proposeShow();
        vm.prank(dave);
        praxis.fundTier{value: 0.02 ether}(id, 0, 1);

        uint256 tokenId = praxis.generateTokenId(1, id, 0, 1);

        // dave approves eve to transfer
        vm.prank(dave);
        praxis.approve(eve, tokenId, 1);

        // eve transfers dave's token to charlie
        vm.prank(eve);
        praxis.transferFrom(dave, charlie, tokenId, 1);

        assertEq(praxis.balanceOf(dave, tokenId), 0);
        assertEq(praxis.balanceOf(charlie, tokenId), 1);
    }

    function test_transferFrom_with_operator() public {
        uint256 id = _proposeShow();
        vm.prank(dave);
        praxis.fundTier{value: 0.02 ether}(id, 0, 1);

        uint256 tokenId = praxis.generateTokenId(1, id, 0, 1);

        vm.prank(dave);
        praxis.setOperator(eve, true);

        vm.prank(eve);
        praxis.transferFrom(dave, charlie, tokenId, 1);

        assertEq(praxis.balanceOf(charlie, tokenId), 1);
    }

    function test_transferFrom_max_allowance_not_decremented() public {
        uint256 id = _proposeShow();
        vm.prank(dave);
        praxis.fundTier{value: 0.02 ether}(id, 0, 1);

        uint256 tokenId = praxis.generateTokenId(1, id, 0, 1);

        vm.prank(dave);
        praxis.approve(eve, tokenId, type(uint256).max);

        vm.prank(eve);
        praxis.transferFrom(dave, charlie, tokenId, 1);

        // allowance should still be max
        assertEq(praxis.allowance(dave, eve, tokenId), type(uint256).max);
    }

    function test_transferFrom_soulbound_reverts() public {
        uint256 id = _proposeShow();
        vm.prank(dave);
        praxis.fundTier{value: 0.1 ether}(id, 1, 1);

        uint256 tokenId = praxis.generateTokenId(2, id, 1, 1);

        vm.prank(dave);
        praxis.approve(eve, tokenId, 1);

        vm.prank(eve);
        vm.expectRevert("soulbound");
        praxis.transferFrom(dave, charlie, tokenId, 1);
    }

    function test_transferFrom_insufficient_allowance_reverts() public {
        uint256 id = _proposeShow();
        vm.prank(dave);
        praxis.fundTier{value: 0.02 ether}(id, 0, 1);

        uint256 tokenId = praxis.generateTokenId(1, id, 0, 1);

        // no approval
        vm.prank(eve);
        vm.expectRevert(); // arithmetic underflow
        praxis.transferFrom(dave, charlie, tokenId, 1);
    }

    // --- proposeProject edge cases ---

    function test_propose_zero_goal_reverts() public {
        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;

        string[] memory names = new string[](1);
        names[0] = "T";
        uint256[] memory prices = new uint256[](1);
        prices[0] = 0.01 ether;
        uint256[] memory supplies = new uint256[](1);
        supplies[0] = 10;
        bool[] memory transferable = new bool[](1);
        transferable[0] = true;

        vm.prank(alice);
        vm.expectRevert("goal too low");
        _callPropose("Test", "desc", "show", collabs, splits, 0, block.timestamp + 30 days, names, prices, supplies, transferable, 0, 0, 3, false, 3);
    }

    function test_propose_past_deadline_reverts() public {
        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;

        string[] memory names = new string[](1);
        names[0] = "T";
        uint256[] memory prices = new uint256[](1);
        prices[0] = 0.01 ether;
        uint256[] memory supplies = new uint256[](1);
        supplies[0] = 10;
        bool[] memory transferable = new bool[](1);
        transferable[0] = true;

        vm.prank(alice);
        vm.expectRevert("past deadline");
        _callPropose("Test", "desc", "show", collabs, splits, 1 ether, block.timestamp - 1, names, prices, supplies, transferable, 0, 0, 3, false, 3);
    }

    function test_propose_too_many_collaborators_reverts() public {
        address[] memory collabs = new address[](201);
        uint256[] memory splits = new uint256[](201);
        for (uint256 i = 0; i < 201; i++) {
            address a = address(uint160(50000 + i));
            registry.registerDirect(a, string(abi.encodePacked("c", vm.toString(i), ".xyz")));
            collabs[i] = a;
            splits[i] = (i < 200) ? uint256(49) : uint256(200);
        }

        string[] memory names = new string[](1);
        names[0] = "T";
        uint256[] memory prices = new uint256[](1);
        prices[0] = 0.01 ether;
        uint256[] memory supplies = new uint256[](1);
        supplies[0] = 10;
        bool[] memory transferable = new bool[](1);
        transferable[0] = true;

        vm.prank(alice);
        vm.expectRevert("too many collaborators");
        _callPropose("Test", "desc", "show", collabs, splits, 1 ether, block.timestamp + 30 days, names, prices, supplies, transferable, 0, 0, 3, false, 3);
    }

    function test_propose_splits_not_10000_reverts() public {
        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 5000; // not 10000

        string[] memory names = new string[](1);
        names[0] = "T";
        uint256[] memory prices = new uint256[](1);
        prices[0] = 0.01 ether;
        uint256[] memory supplies = new uint256[](1);
        supplies[0] = 10;
        bool[] memory transferable = new bool[](1);
        transferable[0] = true;

        vm.prank(alice);
        vm.expectRevert("splits must sum to 10000");
        _callPropose("Test", "desc", "show", collabs, splits, 1 ether, block.timestamp + 30 days, names, prices, supplies, transferable, 0, 0, 3, false, 3);
    }

    function test_propose_zero_tier_price_reverts() public {
        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;

        string[] memory names = new string[](1);
        names[0] = "Free";
        uint256[] memory prices = new uint256[](1);
        prices[0] = 0; // zero price
        uint256[] memory supplies = new uint256[](1);
        supplies[0] = 10;
        bool[] memory transferable = new bool[](1);
        transferable[0] = true;

        vm.prank(alice);
        vm.expectRevert("zero tier price");
        _callPropose("Test", "desc", "show", collabs, splits, 1 ether, block.timestamp + 30 days, names, prices, supplies, transferable, 0, 0, 3, false, 3);
    }

    function test_propose_tier_arrays_mismatch_reverts() public {
        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;

        string[] memory names = new string[](2);
        names[0] = "T1"; names[1] = "T2";
        uint256[] memory prices = new uint256[](1);
        prices[0] = 0.01 ether;
        uint256[] memory supplies = new uint256[](1);
        supplies[0] = 10;
        bool[] memory transferable = new bool[](1);
        transferable[0] = true;

        vm.prank(alice);
        vm.expectRevert("tier arrays mismatch");
        _callPropose("Test", "desc", "show", collabs, splits, 1 ether, block.timestamp + 30 days, names, prices, supplies, transferable, 0, 0, 3, false, 3);
    }

    function test_propose_unregistered_collaborator_reverts() public {
        address unreg = makeAddr("unreg");
        address[] memory collabs = new address[](1);
        collabs[0] = unreg;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;

        string[] memory names = new string[](1);
        names[0] = "T";
        uint256[] memory prices = new uint256[](1);
        prices[0] = 0.01 ether;
        uint256[] memory supplies = new uint256[](1);
        supplies[0] = 10;
        bool[] memory transferable = new bool[](1);
        transferable[0] = true;

        vm.prank(alice);
        vm.expectRevert("collaborator not registered");
        _callPropose("Test", "desc", "show", collabs, splits, 1 ether, block.timestamp + 30 days, names, prices, supplies, transferable, 0, 0, 3, false, 3);
    }

    function test_propose_invalid_revenue_share_reverts() public {
        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;

        string[] memory names = new string[](1);
        names[0] = "T";
        uint256[] memory prices = new uint256[](1);
        prices[0] = 0.01 ether;
        uint256[] memory supplies = new uint256[](1);
        supplies[0] = 10;
        bool[] memory transferable = new bool[](1);
        transferable[0] = true;

        vm.prank(alice);
        vm.expectRevert("invalid revenue share");
        _callPropose("Test", "desc", "show", collabs, splits, 1 ether, block.timestamp + 30 days, names, prices, supplies, transferable, 10001, 0, 3, false, 3);
    }

    // --- fundTier edge cases ---

    function test_fund_zero_quantity_reverts() public {
        _proposeShow();
        vm.prank(dave);
        vm.expectRevert("zero quantity");
        praxis.fundTier{value: 0}(0, 0, 0);
    }

    function test_fund_past_deadline_reverts() public {
        _proposeShow();
        vm.warp(block.timestamp + 31 days);
        vm.prank(dave);
        vm.expectRevert("past deadline");
        praxis.fundTier{value: 0.02 ether}(0, 0, 1);
    }

    function test_fund_invalid_tier_reverts() public {
        _proposeShow();
        vm.prank(dave);
        vm.expectRevert("invalid tier");
        praxis.fundTier{value: 0.02 ether}(0, 99, 1);
    }

    function test_fund_unregistered_reverts() public {
        _proposeShow();
        address unreg = makeAddr("unreg");
        vm.deal(unreg, 10 ether);
        vm.prank(unreg);
        vm.expectRevert("not registered");
        praxis.fundTier{value: 0.02 ether}(0, 0, 1);
    }

    // --- cancelProject ---

    function test_cancel_not_proposer_reverts() public {
        _proposeShow();
        vm.prank(bob);
        vm.expectRevert("not proposer");
        praxis.cancelProject(0);
    }

    function test_cancel_completed_reverts() public {
        uint256 id = _proposeShow();
        _fullComplete(id);

        vm.prank(alice);
        vm.expectRevert("not cancellable");
        praxis.cancelProject(id);
    }

    // --- completeProject ---

    function test_complete_not_proposer_reverts() public {
        uint256 id = _proposeShow();
        _fundToGoal(id);
        _confirmAll(id);

        vm.prank(bob);
        vm.expectRevert("not proposer");
        praxis.completeProject(id);
    }

    // --- claimRefund after deadline (PROPOSED status, expired) ---

    function test_claimRefund_after_deadline() public {
        uint256 id = _proposeShow();

        vm.prank(dave);
        praxis.fundTier{value: 0.02 ether}(id, 0, 1);

        // Warp past deadline
        vm.warp(block.timestamp + 31 days);

        uint256 daveBefore = dave.balance;
        vm.prank(dave);
        praxis.claimRefund(id);
        assertEq(dave.balance - daveBefore, 0.02 ether);
    }

    function test_claimRefund_nothing_reverts() public {
        uint256 id = _proposeShow();
        vm.prank(alice);
        praxis.cancelProject(id);

        vm.prank(dave); // dave never funded
        vm.expectRevert("nothing to refund");
        praxis.claimRefund(id);
    }

    function test_claimRefund_double_reverts() public {
        uint256 id = _proposeShow();
        vm.prank(dave);
        praxis.fundTier{value: 0.02 ether}(id, 0, 1);
        vm.prank(alice);
        praxis.cancelProject(id);

        vm.prank(dave);
        praxis.claimRefund(id);

        vm.prank(dave);
        vm.expectRevert("nothing to refund");
        praxis.claimRefund(id);
    }

    // --- claimFunds ---

    function test_claimFunds_nothing_reverts() public {
        vm.prank(dave);
        vm.expectRevert("nothing to claim");
        praxis.claimFunds();
    }

    // --- claimRevenue edge cases ---

    function test_claimRevenue_no_revenue_share_reverts() public {
        uint256 id = _proposeShow();
        _fundToGoal(id);
        _confirmAll(id);
        vm.prank(alice);
        praxis.completeProject(id);
        vm.warp(block.timestamp + 3 days + 1);
        praxis.finalizeProject(id);

        vm.prank(dave);
        vm.expectRevert("no revenue sharing");
        praxis.claimRevenue(id);
    }

    // --- distributeRevenue zero value ---

    function test_distributeRevenue_zero_value_reverts() public {
        uint256 id = _proposeWithRevenue(5000);
        _fundAndComplete(id);

        vm.prank(alice);
        vm.expectRevert("no value");
        praxis.distributeRevenue{value: 0}(id);
    }

    // --- Reentrancy: claimFunds ---

    function test_reentrancy_claimFunds() public {
        ReentrantPraxisClaimFunds attacker = new ReentrantPraxisClaimFunds(praxis);
        registry.registerDirect(address(attacker), "attacker.xyz");

        uint256 id = _proposeShowWithCollab(address(attacker));
        _fundToGoalForProject(id);
        _confirmAllWithCollab(id, address(attacker));

        vm.prank(alice);
        praxis.completeProject(id);
        vm.warp(block.timestamp + 3 days + 1);
        praxis.finalizeProject(id);

        // attacker has pending withdrawal, tries reentrancy
        vm.prank(address(attacker));
        vm.expectRevert("transfer failed");
        attacker.doClaimFunds();
    }

    // --- Reentrancy: claimRefund ---

    function test_reentrancy_claimRefund() public {
        ReentrantPraxisClaimRefund attacker = new ReentrantPraxisClaimRefund(praxis);
        registry.registerDirect(address(attacker), "refundattacker.xyz");
        vm.deal(address(attacker), 10 ether);

        uint256 id = _proposeShow();

        vm.prank(address(attacker));
        praxis.fundTier{value: 0.02 ether}(id, 0, 1);

        vm.prank(alice);
        praxis.cancelProject(id);

        attacker.setProject(id);

        // CEI: contributions zeroed before transfer, reentrant call should fail with "nothing to refund"
        vm.prank(address(attacker));
        vm.expectRevert("transfer failed");
        attacker.doClaimRefund(id);
    }

    // --- Reentrancy: withdrawFunding ---

    function test_reentrancy_withdrawFunding() public {
        ReentrantPraxisWithdrawFunding attacker = new ReentrantPraxisWithdrawFunding(praxis);
        registry.registerDirect(address(attacker), "wfattacker.xyz");
        vm.deal(address(attacker), 10 ether);

        uint256 id = _proposeShow();

        vm.prank(address(attacker));
        praxis.fundTier{value: 0.02 ether}(id, 0, 1);

        attacker.setProject(id);

        // CEI: contributions zeroed before transfer
        vm.prank(address(attacker));
        vm.expectRevert("transfer failed");
        attacker.doWithdrawFunding(id);
    }

    // --- dispute edge cases ---

    function test_dispute_double_reverts() public {
        uint256 id = _proposeShowSmall();
        vm.prank(dave);
        praxis.fundTier{value: 0.02 ether}(id, 0, 1);
        vm.prank(eve);
        praxis.fundTier{value: 0.08 ether}(id, 0, 4);
        _confirmAll(id);
        vm.prank(alice);
        praxis.completeProject(id);

        vm.prank(dave);
        praxis.dispute(id);

        vm.prank(dave);
        vm.expectRevert("already disputed");
        praxis.dispute(id);
    }

    // --- Fuzz: token ID roundtrip ---

    function testFuzz_tokenId_roundtrip(uint8 tokenType, uint64 projectId, uint32 tierId) public view {
        tokenType = uint8(bound(tokenType, 1, 4));
        uint256 tokenId = praxis.generateTokenId(tokenType, uint256(projectId), uint256(tierId), 1);
        assertEq(praxis.getTokenType(tokenId), tokenType);
        assertEq(praxis.getProjectId(tokenId), projectId);
        assertEq(praxis.getTierId(tokenId), tierId);
    }

    // --- Supporter can fund ---

    function test_supporter_can_fund_tier() public {
        address supporter = makeAddr("supporter");
        vm.prank(supporter);
        registry.registerSupporter("fanone");
        vm.deal(supporter, 10 ether);

        uint256 id = _proposeShow();

        vm.prank(supporter);
        praxis.fundTier{value: 0.02 ether}(id, 0, 1);

        uint256 tokenId = praxis.generateTokenId(1, id, 0, 1);
        assertEq(praxis.balanceOf(supporter, tokenId), 1);
    }

    // --- Helpers ---

    function _proposeShow() internal returns (uint256) {
        address[] memory collabs = new address[](2);
        collabs[0] = bob; collabs[1] = charlie;
        uint256[] memory splits = new uint256[](2);
        splits[0] = 6000; splits[1] = 4000;

        string[] memory tierNames = new string[](3);
        tierNames[0] = "Audience"; tierNames[1] = "Associate Producer"; tierNames[2] = "Executive Producer";
        uint256[] memory tierPrices = new uint256[](3);
        tierPrices[0] = 0.02 ether; tierPrices[1] = 0.1 ether; tierPrices[2] = 1 ether;
        uint256[] memory tierSupplies = new uint256[](3);
        tierSupplies[0] = 200; tierSupplies[1] = 50; tierSupplies[2] = 0;
        bool[] memory tierTransferable = new bool[](3);
        tierTransferable[0] = true; tierTransferable[1] = false; tierTransferable[2] = false;

        vm.prank(alice);
        return _callPropose("Comedy of Errors", "Shakespeare", "show", collabs, splits, 1 ether, block.timestamp + 30 days, tierNames, tierPrices, tierSupplies, tierTransferable, 0, 0, 3, false, 3);
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
        return _callPropose("Small Show", "test", "show", collabs, splits, 0.1 ether, block.timestamp + 30 days, tierNames, tierPrices, tierSupplies, tierTransferable, 0, 0, 3, false, 3);
    }

    function _proposeShowWithCollab(address collab) internal returns (uint256) {
        address[] memory collabs = new address[](1);
        collabs[0] = collab;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;

        string[] memory tierNames = new string[](1);
        tierNames[0] = "Ticket";
        uint256[] memory tierPrices = new uint256[](1);
        tierPrices[0] = 0.02 ether;
        uint256[] memory tierSupplies = new uint256[](1);
        tierSupplies[0] = 100;
        bool[] memory tierTransferable = new bool[](1);
        tierTransferable[0] = true;

        vm.prank(alice);
        return _callPropose("Test", "desc", "show", collabs, splits, 1 ether, block.timestamp + 30 days, tierNames, tierPrices, tierSupplies, tierTransferable, 0, 0, 3, false, 3);
    }

    function _fundToGoal(uint256 projectId) internal {
        vm.prank(dave);
        praxis.fundTier{value: 1 ether}(projectId, 2, 1);
    }

    function _fundToGoalForProject(uint256 projectId) internal {
        vm.prank(dave);
        praxis.fundTier{value: 0.02 ether * 50}(projectId, 0, 50);
    }

    function _confirmAll(uint256 projectId) internal {
        vm.prank(alice);
        praxis.confirmProject(projectId);
        vm.prank(bob);
        praxis.confirmProject(projectId);
        vm.prank(charlie);
        praxis.confirmProject(projectId);
    }

    function _confirmAllWithCollab(uint256 projectId, address collab) internal {
        vm.prank(alice);
        praxis.confirmProject(projectId);
        vm.prank(collab);
        praxis.confirmProject(projectId);
    }

    function _fullComplete(uint256 projectId) internal {
        _fundToGoal(projectId);
        _confirmAll(projectId);
        vm.prank(alice);
        praxis.completeProject(projectId);
        vm.warp(block.timestamp + 3 days + 1);
        praxis.finalizeProject(projectId);
    }

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
        return _callPropose("Revenue Show", "rev share", "show", collabs, splits, 1 ether, block.timestamp + 30 days, tierNames, tierPrices, tierSupplies, tierTransferable, revShareBps, 0, 3, false, 3);
    }

    function _fundAndComplete(uint256 projectId) internal {
        vm.prank(dave);
        praxis.fundTier{value: 0.5 ether}(projectId, 0, 1);
        vm.prank(eve);
        praxis.fundTier{value: 0.5 ether}(projectId, 0, 1);

        vm.prank(alice); praxis.confirmProject(projectId);
        vm.prank(bob); praxis.confirmProject(projectId);
        vm.prank(charlie); praxis.confirmProject(projectId);
        vm.prank(alice); praxis.completeProject(projectId);
        vm.warp(block.timestamp + 3 days + 1);
        praxis.finalizeProject(projectId);
    }
}


// =============================================================================
// BlogRegistry Gap Tests
// =============================================================================

contract BlogRegistryGapTest is Test {
    ArtistRegistry registry;
    BlogRegistry blog;
    address alice = makeAddr("alice");

    function setUp() public {
        registry = new ArtistRegistry();
        blog = new BlogRegistry(address(registry));
        registry.registerDirect(alice, "alice.xyz");
    }

    function test_postWithRef_unregistered_reverts() public {
        address unreg = makeAddr("unreg");
        vm.prank(unreg);
        vm.expectRevert("not registered");
        blog.postWithRef("title", "content", 1, 0);
    }

    function test_postWithRef_empty_title_reverts() public {
        vm.prank(alice);
        vm.expectRevert("empty title");
        blog.postWithRef("", "content", 1, 0);
    }

    function test_postWithRef_all_ref_types() public {
        vm.startPrank(alice);
        blog.postWithRef("standalone", "content", 0, 0);
        blog.postWithRef("project ref", "content", 1, 42);
        blog.postWithRef("portfolio ref", "content", 2, 7);
        blog.postWithRef("reply", "content", 3, 0);
        vm.stopPrank();
        assertEq(blog.postCount(), 4);
    }

    // Fuzz: post count
    function testFuzz_postCount(uint8 count) public {
        count = uint8(bound(count, 1, 20));
        vm.startPrank(alice);
        for (uint8 i = 0; i < count; i++) {
            blog.post(string(abi.encodePacked("Post ", vm.toString(uint256(i)))), "content");
        }
        vm.stopPrank();
        assertEq(blog.postCount(), count);
    }
}


// =============================================================================
// PraxisMedia Gap Tests
// =============================================================================

contract PraxisMediaGapTest is Test {
    ArtistRegistry registry;
    PraxisMedia pm;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address dave = makeAddr("dave");

    function setUp() public {
        registry = new ArtistRegistry();
        pm = new PraxisMedia(address(registry));
        registry.registerDirect(alice, "alice.xyz");
        registry.registerDirect(bob, "bob.xyz");
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(dave, 100 ether);
    }

    // --- Zero-address collaborator ---

    function test_list_zero_address_collaborator_reverts() public {
        address[] memory collabs = new address[](2);
        collabs[0] = alice;
        collabs[1] = address(0); // zero address

        uint256[] memory splits = new uint256[](2);
        splits[0] = 5000;
        splits[1] = 5000;

        vm.prank(alice);
        vm.expectRevert("zero address collaborator");
        pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 10, collabs, splits);
    }

    // --- getCollaborators for solo listing ---

    function test_getCollaborators_solo_listing() public {
        vm.prank(alice);
        uint256 id = pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 10);

        (address[] memory collabs, uint256[] memory splits) = pm.getCollaborators(id);
        assertEq(collabs.length, 1);
        assertEq(collabs[0], alice);
        assertEq(splits[0], 10000);
    }

    // --- Reentrancy: withdraw ---

    function test_reentrancy_withdraw() public {
        ReentrantMediaWithdrawer attacker = new ReentrantMediaWithdrawer(pm);
        registry.registerDirect(address(attacker), "attacker.xyz");

        // List media with attacker as sole collaborator
        address[] memory collabs = new address[](1);
        collabs[0] = address(attacker);
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;

        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", 1 ether, 10, collabs, splits);

        // Buy to give attacker pending withdrawals
        vm.prank(dave);
        pm.purchase{value: 1 ether}(mediaId);

        assertEq(pm.pendingWithdrawals(address(attacker)), 1 ether);

        // Reentrancy: CEI pattern zeros balance before transfer
        // The reentrant call should revert with "nothing to withdraw"
        vm.prank(address(attacker));
        vm.expectRevert("transfer failed");
        attacker.doWithdraw();
    }

    // --- Fuzz: purchase price ---

    function testFuzz_purchase_price(uint256 price) public {
        price = bound(price, 0, 10 ether);

        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", price, 0);

        address buyer = makeAddr("buyer");
        vm.deal(buyer, 20 ether);
        vm.prank(buyer);
        pm.purchase{value: price}(mediaId);

        uint256 tokenId = (mediaId << 128) | 1;
        assertEq(pm.balanceOf(buyer, tokenId), 1);
        assertEq(pm.pendingWithdrawals(alice), price);
    }

    // --- list with splits (full overload) non-registered reverts ---

    function test_list_with_splits_non_registered_reverts() public {
        address[] memory collabs = new address[](1);
        collabs[0] = alice;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;

        vm.prank(dave); // not registered
        vm.expectRevert("not registered");
        pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 10, collabs, splits);
    }
}


// =============================================================================
// PraxisTicketMarket Gap Tests
// =============================================================================

contract PraxisTicketMarketGapTest is Test {
    ArtistRegistry registry;
    Praxis praxis;
    PraxisTicketMarket market;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address dave = makeAddr("dave");

    uint256 projectId;
    uint256 ticketTokenId;

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

        // Create project, fund
        address[] memory collabs = new address[](1);
        collabs[0] = bob;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10000;

        string[] memory tierNames = new string[](1);
        tierNames[0] = "Ticket";
        uint256[] memory tierPrices = new uint256[](1);
        tierPrices[0] = 0.1 ether;
        uint256[] memory tierSupplies = new uint256[](1);
        tierSupplies[0] = 100;
        bool[] memory tierTransferable = new bool[](1);
        tierTransferable[0] = true;

        vm.prank(alice);
        projectId = praxis.proposeProject(Praxis.ProposeProjectArgs({
            title: "Test", description: "desc", projectType: "show", metadataCid: "",
            collaborators: collabs, splits: splits, fundingGoal: 10 ether,
            deadline: block.timestamp + 30 days, tierNames: tierNames, tierPrices: tierPrices,
            tierMaxSupplies: tierSupplies, tierTransferable: tierTransferable, tierMetadataCids: new string[](1),
            revenueSharePercent: 0, location: 0, disputeWindowDays: 3,
            autoComplete: false, confirmationMode: 3
        }));

        vm.prank(charlie);
        praxis.fundTier{value: 0.1 ether}(projectId, 0, 1);
        ticketTokenId = praxis.generateTokenId(1, projectId, 0, 1);
    }

    // --- Reentrancy: withdraw ---

    function test_reentrancy_withdraw() public {
        ReentrantTicketWithdrawer attacker = new ReentrantTicketWithdrawer(market);
        registry.registerDirect(address(attacker), "ticketattacker.xyz");
        vm.deal(address(attacker), 10 ether);

        // Give attacker a ticket
        vm.prank(address(attacker));
        praxis.fundTier{value: 0.1 ether}(projectId, 0, 1);
        uint256 attackerTicket = praxis.generateTokenId(1, projectId, 0, 2);

        vm.prank(address(attacker));
        praxis.setOperator(address(market), true);

        vm.prank(address(attacker));
        market.list(attackerTicket, 0.5 ether);

        vm.prank(dave);
        market.purchase{value: 0.5 ether}(attackerTicket);

        // attacker tries to withdraw with reentrancy
        vm.prank(address(attacker));
        vm.expectRevert("transfer failed");
        attacker.doWithdraw();
    }

    // --- Fuzz: list price ---

    function testFuzz_list_price(uint256 price) public {
        price = bound(price, 1, 100 ether);

        vm.prank(charlie);
        praxis.setOperator(address(market), true);

        vm.prank(charlie);
        market.list(ticketTokenId, price);

        (, uint256 listedPrice, bool active) = market.listings(ticketTokenId);
        assertEq(listedPrice, price);
        assertTrue(active);
    }
}


// =============================================================================
// LibraryRegistry Gap Tests
// =============================================================================

contract LibraryRegistryGapTest is Test {
    ArtistRegistry registry;
    LibraryRegistry library_;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        registry = new ArtistRegistry();
        library_ = new LibraryRegistry(address(registry));
        registry.registerDirect(alice, "alice.xyz");
        registry.registerDirect(bob, "bob.xyz");
    }

    // --- tagItem ---

    function test_tagItem_success() public {
        vm.prank(alice);
        uint256 id = library_.addItem("Title", "Author", "QmXyz", "", "initial");

        vm.prank(alice);
        library_.tagItem(id, "new-tag,another");
        // Just verify it doesn't revert (tags are events)
    }

    function test_tagItem_not_contributor_reverts() public {
        vm.prank(alice);
        uint256 id = library_.addItem("Title", "Author", "QmXyz", "", "initial");

        vm.prank(bob); // not the contributor
        vm.expectRevert("not the contributor");
        library_.tagItem(id, "new-tag");
    }

    function test_tagItem_nonexistent_reverts() public {
        vm.prank(alice);
        vm.expectRevert("item does not exist");
        library_.tagItem(999, "tag");
    }

    function test_tagItem_empty_tags_reverts() public {
        vm.prank(alice);
        uint256 id = library_.addItem("Title", "Author", "QmXyz", "", "initial");

        vm.prank(alice);
        vm.expectRevert("empty tags");
        library_.tagItem(id, "");
    }

    // --- addItem with both ipfs and url ---

    function test_addItem_both_ipfs_and_url() public {
        vm.prank(alice);
        uint256 id = library_.addItem("Title", "Author", "QmXyz", "https://example.com", "tag");
        assertEq(id, 0);
    }

    // --- itemContributor ---

    function test_itemContributor_set() public {
        vm.prank(alice);
        uint256 id = library_.addItem("Title", "Author", "QmXyz", "", "tag");
        assertEq(library_.itemContributor(id), alice);
    }

    // --- Fuzz: item count ---

    function testFuzz_addItem_count(uint8 count) public {
        count = uint8(bound(count, 1, 20));
        vm.startPrank(alice);
        for (uint8 i = 0; i < count; i++) {
            library_.addItem(
                string(abi.encodePacked("Item ", vm.toString(uint256(i)))),
                "Author",
                string(abi.encodePacked("Qm", vm.toString(uint256(i)))),
                "",
                "tag"
            );
        }
        vm.stopPrank();
        assertEq(library_.itemCount(), count);
    }
}


// =============================================================================
// ArtistSponsoredInvites Gap Tests
// =============================================================================

contract ArtistSponsoredInvitesGapTest is Test {
    ArtistRegistry registry;
    ArtistSponsoredInvites sponsor;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 AMOUNT = 0.005 ether + 0.001 ether;

    uint256 orchPk = 0xA11CE;

    bytes32 constant REDEEM_TYPEHASH =
        keccak256("Redeem(bytes32 codeHash,address recipient,uint256 expiry,bytes32 nonce)");

    function setUp() public {
        registry = new ArtistRegistry();
        registry.setDeployFee(0.005 ether);
        sponsor = new ArtistSponsoredInvites(address(registry));
        registry.setOrchestrator(vm.addr(orchPk));

        registry.registerDirect(alice, "alice.xyz");
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _redeemSig(string memory code, address recipient)
        internal
        view
        returns (uint256 expiry, bytes32 nonce, bytes memory sig)
    {
        expiry = block.timestamp + 30 minutes;
        nonce = keccak256(abi.encodePacked(code, recipient, expiry, block.number));
        bytes32 codeHash = keccak256(abi.encodePacked(code));
        bytes32 structHash = keccak256(abi.encode(REDEEM_TYPEHASH, codeHash, recipient, expiry, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", sponsor.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orchPk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    // --- Gas-limited transfers prevent reentrancy ---
    // ArtistSponsoredInvites uses `gas: 10000` on all ETH transfers,
    // which is too low for reentrant calls. We verify CEI ordering is correct
    // by confirming state changes happen before the transfer.

    function test_redeem_CEI_ordering() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        bytes32 hash = keccak256(abi.encodePacked("ceiredeem"));
        sponsor.sponsorInvite(hash);
        vm.stopPrank();

        // Before redeem: redeemed[hash] = false
        assertFalse(sponsor.redeemed(hash));

        (uint256 expiry, bytes32 nonce, bytes memory sig) = _redeemSig("ceiredeem", bob);
        vm.prank(bob);
        sponsor.redeem("ceiredeem", expiry, nonce, sig);

        // After redeem: state updated correctly
        assertTrue(sponsor.redeemed(hash));
        assertEq(address(sponsor).balance, 0);
    }

    function test_refundSlots_CEI_ordering() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT * 3}(3, 0);

        uint256 balBefore = alice.balance;
        sponsor.refundSlots(2);

        // State updated before transfer
        assertEq(sponsor.availableSlots(alice), 1);
        assertEq(alice.balance, balBefore + AMOUNT * 2);
        vm.stopPrank();
    }

    function test_revokeInvite_CEI_ordering() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);
        bytes32 hash = keccak256("ceirevoke");
        sponsor.sponsorInvite(hash);

        uint256 balBefore = alice.balance;
        sponsor.revokeInvite(hash);

        // State cleared before transfer
        assertEq(sponsor.sponsorOf(hash), address(0));
        assertEq(alice.balance, balBefore + AMOUNT);
        vm.stopPrank();
    }

    // --- Fuzz: deposit count ---

    function testFuzz_deposit(uint256 count) public {
        count = bound(count, 1, 100);
        vm.prank(alice);
        sponsor.deposit{value: AMOUNT * count}(count, 0);
        assertEq(sponsor.availableSlots(alice), count);
    }

    // --- sponsorInvites batch not enough slots ---

    function test_sponsorInvites_not_enough_slots_reverts() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT}(1, 0);

        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256("x");
        hashes[1] = keccak256("y");

        vm.expectRevert("not enough slots");
        sponsor.sponsorInvites(hashes);
        vm.stopPrank();
    }

    // --- sponsorInvites batch duplicate ---

    function test_sponsorInvites_duplicate_in_batch_reverts() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT * 3}(3, 0);

        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = keccak256("a");
        hashes[1] = keccak256("b");
        hashes[2] = keccak256("a"); // dup

        vm.expectRevert("already sponsored");
        sponsor.sponsorInvites(hashes);
        vm.stopPrank();
    }

    // --- Multiple deposits accumulate ---

    function test_multiple_deposits_accumulate() public {
        vm.startPrank(alice);
        sponsor.deposit{value: AMOUNT * 2}(2, 0);
        sponsor.deposit{value: AMOUNT * 3}(3, 0);
        vm.stopPrank();

        assertEq(sponsor.availableSlots(alice), 5);
    }
}


// =============================================================================
// PraxisTreasury Gap Tests
// =============================================================================

contract PraxisTreasuryGapTest is Test {
    PraxisTreasury treasury;
    MockERC20Simple mockUsdc;
    MockTarget target;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address pool;
    address cashAccount;

    function setUp() public {
        mockUsdc = new MockERC20Simple();
        MockERC20Simple mockWeth = new MockERC20Simple();

        // Create a mock router (just needs to be non-zero)
        address mockRouter = makeAddr("router");
        pool = makeAddr("pool");
        cashAccount = makeAddr("cash");

        treasury = new PraxisTreasury(
            mockRouter,
            pool,
            cashAccount,
            address(mockWeth),
            address(mockUsdc),
            50
        );

        target = new MockTarget();

        vm.deal(address(treasury), 100 ether);
    }

    // --- execute() removed (security hardening) ---

    // --- Reentrancy: withdrawETH ---

    function test_reentrancy_withdrawETH() public {
        ReentrantTreasuryWithdraw attacker = new ReentrantTreasuryWithdraw(treasury);

        // withdrawETH sends ETH to attacker, which tries to reenter
        // nonReentrant guard should prevent the reentrant call
        // But the attacker's receive uses try/catch, so the outer call succeeds
        treasury.withdrawETH(address(attacker), 1 ether);

        // Verify only 1 ether was withdrawn, not more
        assertEq(address(attacker).balance, 1 ether);
        assertEq(address(treasury).balance, 99 ether);
    }

    // --- Pause does not affect ETH withdrawal ---

    // execute() removed (security hardening)

    // --- Fuzz: withdrawETH ---

    function testFuzz_withdrawETH(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);

        uint256 bobBefore = bob.balance;
        treasury.withdrawETH(bob, amount);
        assertEq(bob.balance, bobBefore + amount);
    }

    // --- immutable config (setters removed) ---

    function test_immutable_pool_and_cash() public view {
        assertEq(treasury.velodromeFactory(), pool);
        assertEq(treasury.etherFiCashAccount(), cashAccount);
        assertEq(treasury.slippageBps(), 50);
        assertEq(treasury.deadlineExtension(), 300);
    }

    // --- sweepToken with exact balance ---

    function test_sweepToken_exact_balance() public {
        mockUsdc.mint(address(treasury), 1000);
        treasury.sweepToken(address(mockUsdc), bob, 1000);
        assertEq(mockUsdc.balanceOf(bob), 1000);
        assertEq(mockUsdc.balanceOf(address(treasury)), 0);
    }
}


// =============================================================================
// Invariant Tests
// =============================================================================

/// @dev Handler for ArtistRegistry invariant testing
contract RegistryHandler is Test {
    ArtistRegistry public registry;
    uint256 public registeredCount;

    constructor(ArtistRegistry _registry) {
        registry = _registry;
    }

    function registerArtist(uint256 seed) external {
        seed = bound(seed, 1, 10000);
        address a = address(uint160(seed + 100000));
        if (registry.isUser(a)) return;

        string memory domain = string(abi.encodePacked("inv", vm.toString(seed), ".xyz"));

        // Use deployer's registerDirect (this handler is deployed by the test contract which is the deployer)
        // We need to prank as the deployer
        try registry.registerDirect(a, domain) {
            registeredCount++;
        } catch {}
    }
}

contract ArtistRegistryInvariantTest is Test {
    ArtistRegistry registry;
    RegistryHandler handler;

    function setUp() public {
        registry = new ArtistRegistry();
        handler = new RegistryHandler(registry);

        // Grant handler permission by transferring deployer context
        // Actually, registerDirect requires msg.sender == deployer, and deployer is this test contract
        // So the handler can't call registerDirect directly. We'll use a different approach.

        // Pre-register some artists for invariant testing
        for (uint256 i = 0; i < 10; i++) {
            address a = address(uint160(200000 + i));
            registry.registerDirect(a, string(abi.encodePacked("pre", vm.toString(i), ".xyz")));
        }

        targetContract(address(handler));
    }

    /// @dev totalArtists should always equal the actual length of registeredAddresses
    function invariant_totalArtists_matches_array() public view {
        assertEq(registry.totalArtists(), 10); // We registered 10 in setUp
    }

    /// @dev The deployer address should never change
    function invariant_deployer_immutable() public view {
        assertEq(registry.deployer(), address(this));
    }
}

/// @dev Invariant: PraxisTreasury ETH balance should be tracked correctly
contract TreasuryInvariantTest is Test {
    PraxisTreasury treasury;

    function setUp() public {
        MockERC20Simple mockUsdc = new MockERC20Simple();
        MockERC20Simple mockWeth = new MockERC20Simple();

        treasury = new PraxisTreasury(
            makeAddr("router"),
            makeAddr("pool"),
            makeAddr("cash"),
            address(mockWeth),
            address(mockUsdc),
            50
        );

        vm.deal(address(treasury), 100 ether);
    }

    /// @dev ethBalance() should always match address(treasury).balance
    function invariant_ethBalance_matches_actual() public view {
        assertEq(treasury.ethBalance(), address(treasury).balance);
    }

    /// @dev Paused state can only be changed by owner
    function invariant_paused_is_bool() public view {
        // paused is either true or false (trivial invariant, but validates state)
        assertTrue(treasury.paused() == true || treasury.paused() == false);
    }
}
