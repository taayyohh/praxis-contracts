// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../ArtistRegistry.sol";
import "../PraxisMedia.sol";

contract PraxisMediaTest is Test {
    event Listed(uint256 indexed mediaId, address indexed artist, string title, string ipfsCid, uint256 price, uint256 maxSupply);
    event Purchased(uint256 indexed mediaId, address indexed buyer, uint256 tokenId, uint256 price);
    event PriceChanged(uint256 indexed mediaId, uint256 newPrice);
    event SupplyChanged(uint256 indexed mediaId, uint256 newMaxSupply);
    event Withdrawn(address indexed artist, uint256 amount);
    event Transfer(address caller, address indexed sender, address indexed receiver, uint256 indexed id, uint256 amount);

    ArtistRegistry registry;
    PraxisMedia pm;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address dave = makeAddr("dave"); // non-registered buyer

    function setUp() public {
        registry = new ArtistRegistry();
        pm = new PraxisMedia(address(registry));

        registry.registerDirect(alice, "alice.xyz");
        registry.registerDirect(bob, "bob.xyz");
        registry.registerDirect(charlie, "charlie.xyz");

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
        vm.deal(dave, 100 ether);
    }

    // --- list() solo ---

    function test_list_success() public {
        vm.prank(alice);
        uint256 id = pm.list("Song A", "QmABC123", "QmMETA456", 0.01 ether, 100);

        assertEq(id, 0);
        assertEq(pm.mediaCount(), 1);

        (address artist, string memory title,,,uint256 price, uint256 maxSupply, uint256 totalMinted) = pm.media(0);
        assertEq(artist, alice);
        assertEq(keccak256(bytes(title)), keccak256("Song A"));
        assertEq(price, 0.01 ether);
        assertEq(maxSupply, 100);
        assertEq(totalMinted, 0);
    }

    function test_list_non_registered_reverts() public {
        vm.prank(dave);
        vm.expectRevert("not registered");
        pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 10);
    }

    function test_list_empty_title_reverts() public {
        vm.prank(alice);
        vm.expectRevert("empty title");
        pm.list("", "QmABC", "QmMETA", 0.01 ether, 10);
    }

    function test_list_empty_ipfs_reverts() public {
        vm.prank(alice);
        vm.expectRevert("empty ipfsCid");
        pm.list("Song", "", "QmMETA", 0.01 ether, 10);
    }

    function test_list_free_mint() public {
        vm.prank(alice);
        uint256 id = pm.list("Free Track", "QmFREE", "QmMETA", 0, 0);

        (,,,,uint256 price, uint256 maxSupply,) = pm.media(id);
        assertEq(price, 0);
        assertEq(maxSupply, 0); // unlimited
    }

    function test_list_unlimited_supply() public {
        vm.prank(alice);
        uint256 id = pm.list("Unlimited", "QmUNL", "QmMETA", 0.05 ether, 0);

        (,,,,,uint256 maxSupply,) = pm.media(id);
        assertEq(maxSupply, 0);
    }

    // --- purchase() ---

    function test_purchase_correct_price() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 100);

        vm.prank(dave);
        pm.purchase{value: 0.01 ether}(mediaId);

        uint256 tokenId = (mediaId << 128) | 1;
        assertEq(pm.balanceOf(dave, tokenId), 1);

        (,,,,,,uint256 totalMinted) = pm.media(mediaId);
        assertEq(totalMinted, 1);
    }

    function test_purchase_free_mint() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Free", "QmFREE", "QmMETA", 0, 50);

        vm.prank(dave);
        pm.purchase{value: 0}(mediaId);

        uint256 tokenId = (mediaId << 128) | 1;
        assertEq(pm.balanceOf(dave, tokenId), 1);
    }

    function test_purchase_overpay_refund() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 100);

        uint256 daveBefore = dave.balance;
        vm.prank(dave);
        pm.purchase{value: 0.05 ether}(mediaId);

        // dave paid 0.05, refunded 0.04, net cost 0.01
        assertEq(daveBefore - dave.balance, 0.01 ether);
    }

    function test_purchase_insufficient_payment_reverts() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 100);

        vm.prank(dave);
        vm.expectRevert("insufficient payment");
        pm.purchase{value: 0.005 ether}(mediaId);
    }

    function test_purchase_supply_limit() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Limited", "QmLTD", "QmMETA", 0.01 ether, 2);

        vm.prank(dave);
        pm.purchase{value: 0.01 ether}(mediaId);

        vm.prank(bob);
        pm.purchase{value: 0.01 ether}(mediaId);

        // third purchase should revert
        vm.prank(charlie);
        vm.expectRevert("sold out");
        pm.purchase{value: 0.01 ether}(mediaId);
    }

    function test_purchase_unlimited_supply() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Unlimited", "QmUNL", "QmMETA", 0.01 ether, 0);

        // many purchases should all succeed
        for (uint256 i = 0; i < 10; i++) {
            address buyer = address(uint160(1000 + i));
            vm.deal(buyer, 1 ether);
            vm.prank(buyer);
            pm.purchase{value: 0.01 ether}(mediaId);
        }

        (,,,,,,uint256 totalMinted) = pm.media(mediaId);
        assertEq(totalMinted, 10);
    }

    function test_purchase_nonexistent_media_reverts() public {
        vm.prank(dave);
        vm.expectRevert("media not found");
        pm.purchase{value: 0.01 ether}(999);
    }

    function test_purchase_serial_increments() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 100);

        vm.prank(dave);
        pm.purchase{value: 0.01 ether}(mediaId);

        vm.prank(bob);
        pm.purchase{value: 0.01 ether}(mediaId);

        uint256 token1 = (mediaId << 128) | 1;
        uint256 token2 = (mediaId << 128) | 2;
        assertEq(pm.balanceOf(dave, token1), 1);
        assertEq(pm.balanceOf(bob, token2), 1);
    }

    // --- setPrice() ---

    function test_setPrice_by_artist() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 100);

        vm.prank(alice);
        pm.setPrice(mediaId, 0.05 ether);

        (,,,,uint256 price,,) = pm.media(mediaId);
        assertEq(price, 0.05 ether);
    }

    function test_setPrice_non_artist_reverts() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 100);

        vm.prank(bob);
        vm.expectRevert("not artist");
        pm.setPrice(mediaId, 0.05 ether);
    }

    function test_setPrice_to_zero() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 100);

        vm.prank(alice);
        pm.setPrice(mediaId, 0);

        (,,,,uint256 price,,) = pm.media(mediaId);
        assertEq(price, 0);
    }

    // --- setMaxSupply() ---

    function test_setMaxSupply_increase() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 10);

        vm.prank(alice);
        pm.setMaxSupply(mediaId, 50);

        (,,,,,uint256 maxSupply,) = pm.media(mediaId);
        assertEq(maxSupply, 50);
    }

    function test_setMaxSupply_to_unlimited() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 10);

        vm.prank(alice);
        pm.setMaxSupply(mediaId, 0);

        (,,,,,uint256 maxSupply,) = pm.media(mediaId);
        assertEq(maxSupply, 0);
    }

    function test_setMaxSupply_below_minted_reverts() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 100);

        // mint 3
        for (uint256 i = 0; i < 3; i++) {
            address buyer = address(uint160(2000 + i));
            vm.deal(buyer, 1 ether);
            vm.prank(buyer);
            pm.purchase{value: 0.01 ether}(mediaId);
        }

        vm.prank(alice);
        vm.expectRevert("below minted");
        pm.setMaxSupply(mediaId, 2); // 2 < 3 minted

        // setting to exactly minted should work
        vm.prank(alice);
        pm.setMaxSupply(mediaId, 3);
        (,,,,,uint256 maxSupply,) = pm.media(mediaId);
        assertEq(maxSupply, 3);
    }

    function test_setMaxSupply_non_artist_reverts() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 10);

        vm.prank(bob);
        vm.expectRevert("not artist");
        pm.setMaxSupply(mediaId, 50);
    }

    // --- withdraw() ---

    function test_withdraw_correct_amount() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 100);

        vm.prank(dave);
        pm.purchase{value: 0.01 ether}(mediaId);

        vm.prank(bob);
        pm.purchase{value: 0.01 ether}(mediaId);

        assertEq(pm.pendingWithdrawals(alice), 0.02 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        pm.withdraw();

        assertEq(alice.balance - aliceBefore, 0.02 ether);
        assertEq(pm.pendingWithdrawals(alice), 0);
    }

    function test_withdraw_zero_balance_reverts() public {
        vm.prank(alice);
        vm.expectRevert("nothing to withdraw");
        pm.withdraw();
    }

    function test_withdraw_multiple_media() public {
        vm.prank(alice);
        uint256 id1 = pm.list("Song 1", "QmA", "QmM1", 0.01 ether, 100);
        vm.prank(alice);
        uint256 id2 = pm.list("Song 2", "QmB", "QmM2", 0.02 ether, 100);

        vm.prank(dave);
        pm.purchase{value: 0.01 ether}(id1);
        vm.prank(dave);
        pm.purchase{value: 0.02 ether}(id2);

        assertEq(pm.pendingWithdrawals(alice), 0.03 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        pm.withdraw();
        assertEq(alice.balance - aliceBefore, 0.03 ether);
    }

    // --- soulbound enforcement ---

    function test_transfer_reverts() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 100);

        vm.prank(dave);
        pm.purchase{value: 0.01 ether}(mediaId);

        uint256 tokenId = (mediaId << 128) | 1;

        vm.prank(dave);
        vm.expectRevert("soulbound");
        pm.transfer(bob, tokenId, 1);
    }

    function test_transferFrom_reverts() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 100);

        vm.prank(dave);
        pm.purchase{value: 0.01 ether}(mediaId);

        uint256 tokenId = (mediaId << 128) | 1;

        vm.prank(dave);
        vm.expectRevert("soulbound");
        pm.transferFrom(dave, bob, tokenId, 1);
    }

    // --- balanceOf ---

    function test_balanceOf_after_purchase() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 100);

        uint256 tokenId1 = (mediaId << 128) | 1;
        assertEq(pm.balanceOf(dave, tokenId1), 0);

        vm.prank(dave);
        pm.purchase{value: 0.01 ether}(mediaId);

        assertEq(pm.balanceOf(dave, tokenId1), 1);
    }

    function test_balanceOf_multiple_purchases_same_buyer() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Song", "QmABC", "QmMETA", 0.01 ether, 100);

        vm.prank(dave);
        pm.purchase{value: 0.01 ether}(mediaId);
        vm.prank(dave);
        pm.purchase{value: 0.01 ether}(mediaId);

        uint256 tokenId1 = (mediaId << 128) | 1;
        uint256 tokenId2 = (mediaId << 128) | 2;
        assertEq(pm.balanceOf(dave, tokenId1), 1);
        assertEq(pm.balanceOf(dave, tokenId2), 1);
    }

    // --- getMediaByArtist ---

    function test_getMediaByArtist_returns_ids() public {
        vm.prank(alice);
        pm.list("Song 1", "QmA", "QmM1", 0.01 ether, 10);
        vm.prank(alice);
        pm.list("Song 2", "QmB", "QmM2", 0.02 ether, 20);
        vm.prank(alice);
        pm.list("Song 3", "QmC", "QmM3", 0.03 ether, 30);

        uint256[] memory ids = pm.getMediaByArtist(alice);
        assertEq(ids.length, 3);
        assertEq(ids[0], 0);
        assertEq(ids[1], 1);
        assertEq(ids[2], 2);
    }

    function test_getMediaByArtist_empty() public view {
        uint256[] memory ids = pm.getMediaByArtist(dave);
        assertEq(ids.length, 0);
    }

    // --- multiple artists ---

    function test_multiple_artists_listing() public {
        vm.prank(alice);
        uint256 id1 = pm.list("Alice Song", "QmA", "QmMA", 0.01 ether, 10);

        vm.prank(bob);
        uint256 id2 = pm.list("Bob Song", "QmB", "QmMB", 0.02 ether, 20);

        vm.prank(charlie);
        uint256 id3 = pm.list("Charlie Song", "QmC", "QmMC", 0.03 ether, 30);

        assertEq(id1, 0);
        assertEq(id2, 1);
        assertEq(id3, 2);
        assertEq(pm.mediaCount(), 3);

        uint256[] memory aliceMedia = pm.getMediaByArtist(alice);
        uint256[] memory bobMedia = pm.getMediaByArtist(bob);
        uint256[] memory charlieMedia = pm.getMediaByArtist(charlie);

        assertEq(aliceMedia.length, 1);
        assertEq(bobMedia.length, 1);
        assertEq(charlieMedia.length, 1);
        assertEq(aliceMedia[0], 0);
        assertEq(bobMedia[0], 1);
        assertEq(charlieMedia[0], 2);
    }

    function test_multiple_artists_withdraw_independently() public {
        vm.prank(alice);
        uint256 id1 = pm.list("Alice Song", "QmA", "QmMA", 0.01 ether, 100);
        vm.prank(bob);
        uint256 id2 = pm.list("Bob Song", "QmB", "QmMB", 0.02 ether, 100);

        vm.prank(dave);
        pm.purchase{value: 0.01 ether}(id1);
        vm.prank(dave);
        pm.purchase{value: 0.02 ether}(id2);

        assertEq(pm.pendingWithdrawals(alice), 0.01 ether);
        assertEq(pm.pendingWithdrawals(bob), 0.02 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        pm.withdraw();
        assertEq(alice.balance - aliceBefore, 0.01 ether);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        pm.withdraw();
        assertEq(bob.balance - bobBefore, 0.02 ether);
    }

    // --- supply exhausted ---

    function test_purchase_supply_exhausted_reverts() public {
        vm.prank(alice);
        uint256 mediaId = pm.list("Limited Edition", "QmLTD", "QmMETA", 0.01 ether, 1);

        vm.prank(dave);
        pm.purchase{value: 0.01 ether}(mediaId);

        vm.prank(bob);
        vm.expectRevert("sold out");
        pm.purchase{value: 0.01 ether}(mediaId);
    }

    // --- ERC-6909 approve/setOperator ---

    function test_approve() public {
        vm.prank(dave);
        bool ok = pm.approve(alice, 42, 100);
        assertTrue(ok);
        assertEq(pm.allowance(dave, alice, 42), 100);
    }

    function test_setOperator() public {
        vm.prank(dave);
        bool ok = pm.setOperator(alice, true);
        assertTrue(ok);
        assertTrue(pm.isOperator(dave, alice));

        vm.prank(dave);
        pm.setOperator(alice, false);
        assertFalse(pm.isOperator(dave, alice));
    }

    // =========================================================================
    // Collaborator splits tests
    // =========================================================================

    // --- list with splits ---

    function test_list_with_splits() public {
        address[] memory collabs = new address[](2);
        collabs[0] = alice;
        collabs[1] = bob;

        uint256[] memory splits = new uint256[](2);
        splits[0] = 6000; // 60%
        splits[1] = 4000; // 40%

        vm.prank(alice);
        uint256 mediaId = pm.list("Collab Track", "QmCOLLAB", "QmMETA", 0.1 ether, 50, collabs, splits);

        assertEq(mediaId, 0);
        assertEq(pm.mediaCount(), 1);

        (address artist, string memory title,,,uint256 price, uint256 maxSupply,) = pm.media(mediaId);
        assertEq(artist, alice);
        assertEq(keccak256(bytes(title)), keccak256("Collab Track"));
        assertEq(price, 0.1 ether);
        assertEq(maxSupply, 50);

        // verify collaborators stored correctly
        (address[] memory storedCollabs, uint256[] memory storedSplits) = pm.getCollaborators(mediaId);
        assertEq(storedCollabs.length, 2);
        assertEq(storedCollabs[0], alice);
        assertEq(storedCollabs[1], bob);
        assertEq(storedSplits[0], 6000);
        assertEq(storedSplits[1], 4000);

        // both should be indexed
        uint256[] memory aliceMedia = pm.getMediaByArtist(alice);
        uint256[] memory bobMedia = pm.getMediaByArtist(bob);
        assertEq(aliceMedia.length, 1);
        assertEq(aliceMedia[0], mediaId);
        assertEq(bobMedia.length, 1);
        assertEq(bobMedia[0], mediaId);
    }

    function test_purchase_distributes_splits() public {
        address[] memory collabs = new address[](2);
        collabs[0] = alice;
        collabs[1] = bob;

        uint256[] memory splits = new uint256[](2);
        splits[0] = 6000; // 60%
        splits[1] = 4000; // 40%

        vm.prank(alice);
        uint256 mediaId = pm.list("Collab Track", "QmCOLLAB", "QmMETA", 1 ether, 100, collabs, splits);

        vm.prank(dave);
        pm.purchase{value: 1 ether}(mediaId);

        // alice gets 60% = 0.6 ether, bob gets 40% = 0.4 ether
        assertEq(pm.pendingWithdrawals(alice), 0.6 ether);
        assertEq(pm.pendingWithdrawals(bob), 0.4 ether);
    }

    function test_splits_must_sum_to_10000() public {
        address[] memory collabs = new address[](2);
        collabs[0] = alice;
        collabs[1] = bob;

        uint256[] memory splits = new uint256[](2);
        splits[0] = 5000;
        splits[1] = 3000; // sum = 8000, not 10000

        vm.prank(alice);
        vm.expectRevert("splits must sum to 10000");
        pm.list("Bad Split", "QmBAD", "QmMETA", 0.1 ether, 10, collabs, splits);
    }

    function test_splits_length_mismatch_reverts() public {
        address[] memory collabs = new address[](2);
        collabs[0] = alice;
        collabs[1] = bob;

        uint256[] memory splits = new uint256[](3);
        splits[0] = 3000;
        splits[1] = 3000;
        splits[2] = 4000;

        vm.prank(alice);
        vm.expectRevert("length mismatch");
        pm.list("Mismatch", "QmMIS", "QmMETA", 0.1 ether, 10, collabs, splits);
    }

    function test_too_many_collaborators_reverts() public {
        address[] memory collabs = new address[](201);
        uint256[] memory splits = new uint256[](201);

        for (uint256 i = 0; i < 201; i++) {
            collabs[i] = address(uint160(5000 + i));
            splits[i] = (i < 200) ? uint256(49) : uint256(200); // sums to 49*200 + 200 = 10000
        }

        vm.prank(alice);
        vm.expectRevert("too many collaborators");
        pm.list("Too Many", "QmTOO", "QmMETA", 0.1 ether, 10, collabs, splits);
    }

    function test_three_way_split() public {
        address[] memory collabs = new address[](3);
        collabs[0] = alice;
        collabs[1] = bob;
        collabs[2] = charlie;

        uint256[] memory splits = new uint256[](3);
        splits[0] = 5000; // 50%
        splits[1] = 3000; // 30%
        splits[2] = 2000; // 20%

        vm.prank(alice);
        uint256 mediaId = pm.list("Trio Track", "QmTRIO", "QmMETA", 1 ether, 100, collabs, splits);

        vm.prank(dave);
        pm.purchase{value: 1 ether}(mediaId);

        assertEq(pm.pendingWithdrawals(alice), 0.5 ether);
        assertEq(pm.pendingWithdrawals(bob), 0.3 ether);
        assertEq(pm.pendingWithdrawals(charlie), 0.2 ether);
    }

    function test_bandmates_both_see_media() public {
        address[] memory collabs = new address[](2);
        collabs[0] = alice;
        collabs[1] = bob;

        uint256[] memory splits = new uint256[](2);
        splits[0] = 5000;
        splits[1] = 5000;

        vm.prank(alice);
        uint256 mediaId = pm.list("Duo Track", "QmDUO", "QmMETA", 0.1 ether, 50, collabs, splits);

        // both collaborators see the media in their artist index
        uint256[] memory aliceMedia = pm.getMediaByArtist(alice);
        uint256[] memory bobMedia = pm.getMediaByArtist(bob);

        assertEq(aliceMedia.length, 1);
        assertEq(aliceMedia[0], mediaId);
        assertEq(bobMedia.length, 1);
        assertEq(bobMedia[0], mediaId);

        // charlie should have none
        uint256[] memory charlieMedia = pm.getMediaByArtist(charlie);
        assertEq(charlieMedia.length, 0);
    }

    function test_withdraw_after_split() public {
        address[] memory collabs = new address[](2);
        collabs[0] = alice;
        collabs[1] = bob;

        uint256[] memory splits = new uint256[](2);
        splits[0] = 7000; // 70%
        splits[1] = 3000; // 30%

        vm.prank(alice);
        uint256 mediaId = pm.list("Split Track", "QmSPLIT", "QmMETA", 1 ether, 100, collabs, splits);

        // two purchases
        vm.prank(dave);
        pm.purchase{value: 1 ether}(mediaId);
        vm.prank(charlie);
        pm.purchase{value: 1 ether}(mediaId);

        // alice: 2 * 0.7 = 1.4 ether, bob: 2 * 0.3 = 0.6 ether
        assertEq(pm.pendingWithdrawals(alice), 1.4 ether);
        assertEq(pm.pendingWithdrawals(bob), 0.6 ether);

        // alice withdraws first
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        pm.withdraw();
        assertEq(alice.balance - aliceBefore, 1.4 ether);
        assertEq(pm.pendingWithdrawals(alice), 0);

        // bob's balance should be unaffected by alice's withdrawal
        assertEq(pm.pendingWithdrawals(bob), 0.6 ether);

        // bob withdraws independently
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        pm.withdraw();
        assertEq(bob.balance - bobBefore, 0.6 ether);
        assertEq(pm.pendingWithdrawals(bob), 0);
    }

    // --- v2: purchaseBatch ---

    function test_v2_purchaseBatch_three_items_one_tx() public {
        // alice lists three tracks of the same album
        vm.startPrank(alice);
        uint256 t1 = pm.list("Track 1", "QmT1", "QmM", 0.01 ether, 100);
        uint256 t2 = pm.list("Track 2", "QmT2", "QmM", 0.02 ether, 100);
        uint256 t3 = pm.list("Track 3", "QmT3", "QmM", 0.03 ether, 100);
        vm.stopPrank();

        uint256[] memory ids = new uint256[](3);
        ids[0] = t1; ids[1] = t2; ids[2] = t3;

        uint256 totalCost = 0.06 ether;
        vm.prank(dave);
        pm.purchaseBatch{value: totalCost}(ids);

        // Each token minted to dave
        assertEq(pm.balanceOf(dave, (t1 << 128) | 1), 1);
        assertEq(pm.balanceOf(dave, (t2 << 128) | 1), 1);
        assertEq(pm.balanceOf(dave, (t3 << 128) | 1), 1);
        // Alice receives all three items' revenue (sole collaborator)
        assertEq(pm.pendingWithdrawals(alice), totalCost);
    }

    function test_v2_purchaseBatch_refunds_overpayment() public {
        vm.prank(alice);
        uint256 id = pm.list("Solo", "QmS", "QmM", 0.05 ether, 100);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        uint256 daveBefore = dave.balance;
        vm.prank(dave);
        pm.purchaseBatch{value: 0.1 ether}(ids); // overpay by 0.05

        // dave only out 0.05 ether
        assertEq(daveBefore - dave.balance, 0.05 ether);
    }

    function test_v2_purchaseBatch_underpay_reverts() public {
        vm.prank(alice);
        uint256 id = pm.list("Solo", "QmS", "QmM", 0.05 ether, 100);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(dave);
        vm.expectRevert("insufficient payment");
        pm.purchaseBatch{value: 0.04 ether}(ids);
    }

    function test_v2_purchaseBatch_empty_reverts() public {
        uint256[] memory ids = new uint256[](0);
        vm.prank(dave);
        vm.expectRevert("empty batch");
        pm.purchaseBatch{value: 0}(ids);
    }

    function test_v2_purchaseBatch_too_large_reverts() public {
        // Create 21 items (cap is 20)
        vm.startPrank(alice);
        uint256[] memory ids = new uint256[](21);
        for (uint256 i = 0; i < 21; i++) {
            ids[i] = pm.list("T", "QmX", "QmM", 0, 100);
        }
        vm.stopPrank();
        vm.prank(dave);
        vm.expectRevert("batch too large");
        pm.purchaseBatch{value: 0}(ids);
    }

    function test_v2_purchaseBatch_sold_out_reverts_whole_batch() public {
        vm.startPrank(alice);
        uint256 t1 = pm.list("Limited", "QmL", "QmM", 0.01 ether, 1);
        uint256 t2 = pm.list("Open", "QmO", "QmM", 0.01 ether, 100);
        vm.stopPrank();

        // Sell out t1 first
        vm.prank(charlie);
        pm.purchase{value: 0.01 ether}(t1);

        uint256[] memory ids = new uint256[](2);
        ids[0] = t1; ids[1] = t2;
        vm.prank(dave);
        vm.expectRevert("sold out");
        pm.purchaseBatch{value: 0.02 ether}(ids);

        // t2 still has its original supply unchanged
        (,,,,,, uint256 minted) = pm.media(t2);
        assertEq(minted, 0);
    }

    function test_v2_purchaseBatch_delisted_reverts() public {
        vm.startPrank(alice);
        uint256 t1 = pm.list("Free", "QmF", "QmM", 0, 100);
        // Use the proper delist function
        pm.delist(t1);
        vm.stopPrank();

        uint256[] memory ids = new uint256[](1);
        ids[0] = t1;
        vm.prank(dave);
        vm.expectRevert("delisted");
        pm.purchaseBatch{value: 0}(ids);
    }

    function test_delist_prevents_single_purchase() public {
        vm.startPrank(alice);
        uint256 t1 = pm.list("Song", "QmS", "QmM", 0.01 ether, 100);
        pm.delist(t1);
        vm.stopPrank();

        vm.prank(dave);
        vm.expectRevert("delisted");
        pm.purchase{value: 0.01 ether}(t1);
    }

    function test_delist_only_artist() public {
        vm.prank(alice);
        uint256 t1 = pm.list("Song", "QmS", "QmM", 0.01 ether, 100);

        vm.prank(bob);
        vm.expectRevert("not artist");
        pm.delist(t1);
    }

    function test_delist_already_delisted_reverts() public {
        vm.startPrank(alice);
        uint256 t1 = pm.list("Song", "QmS", "QmM", 0.01 ether, 100);
        pm.delist(t1);
        vm.expectRevert("already delisted");
        pm.delist(t1);
        vm.stopPrank();
    }

    function test_v2_purchaseBatch_with_collaborator_splits() public {
        // alice lists with a 70/30 split to bob
        address[] memory collabs = new address[](2);
        uint256[] memory splits = new uint256[](2);
        collabs[0] = alice; collabs[1] = bob;
        splits[0] = 7000; splits[1] = 3000;

        vm.prank(alice);
        uint256 id = pm.list("Collab", "QmC", "QmM", 0.1 ether, 100, collabs, splits);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.prank(dave);
        pm.purchaseBatch{value: 0.1 ether}(ids);

        assertEq(pm.pendingWithdrawals(alice), 0.07 ether);
        assertEq(pm.pendingWithdrawals(bob), 0.03 ether);
    }

    // --- v2: listBatch ---

    function test_v2_listBatch_three_solo_tracks() public {
        PraxisMedia.ListEntry[] memory entries = new PraxisMedia.ListEntry[](3);
        for (uint256 i = 0; i < 3; i++) {
            entries[i] = PraxisMedia.ListEntry({
                title: "Track",
                ipfsCid: "QmX",
                metadataCid: "QmM",
                price: 0.01 ether,
                maxSupply: 100,
                collaborators: new address[](0),
                splits: new uint256[](0)
            });
        }

        vm.prank(alice);
        uint256[] memory ids = pm.listBatch(entries);

        assertEq(ids.length, 3);
        assertEq(pm.mediaCount(), 3);
        for (uint256 i = 0; i < 3; i++) {
            (address artist,,,,uint256 p,,) = pm.media(ids[i]);
            assertEq(artist, alice);
            assertEq(p, 0.01 ether);
        }
    }

    function test_v2_listBatch_with_per_item_collaborators() public {
        PraxisMedia.ListEntry[] memory entries = new PraxisMedia.ListEntry[](2);

        // First item: solo
        entries[0] = PraxisMedia.ListEntry({
            title: "Solo",
            ipfsCid: "QmS",
            metadataCid: "QmMa",
            price: 0.01 ether,
            maxSupply: 100,
            collaborators: new address[](0),
            splits: new uint256[](0)
        });

        // Second item: alice + bob 60/40
        address[] memory duoCollabs = new address[](2);
        duoCollabs[0] = alice; duoCollabs[1] = bob;
        uint256[] memory duoSplits = new uint256[](2);
        duoSplits[0] = 6000; duoSplits[1] = 4000;
        entries[1] = PraxisMedia.ListEntry({
            title: "Duo",
            ipfsCid: "QmD",
            metadataCid: "QmMb",
            price: 0.02 ether,
            maxSupply: 100,
            collaborators: duoCollabs,
            splits: duoSplits
        });

        vm.prank(alice);
        uint256[] memory ids = pm.listBatch(entries);
        assertEq(ids.length, 2);

        // Buy the duo and verify split
        vm.prank(dave);
        pm.purchase{value: 0.02 ether}(ids[1]);
        assertEq(pm.pendingWithdrawals(alice), 0.012 ether);
        assertEq(pm.pendingWithdrawals(bob), 0.008 ether);
    }

    function test_v2_listBatch_empty_reverts() public {
        PraxisMedia.ListEntry[] memory entries = new PraxisMedia.ListEntry[](0);
        vm.prank(alice);
        vm.expectRevert("empty batch");
        pm.listBatch(entries);
    }

    function test_v2_listBatch_non_registered_reverts() public {
        PraxisMedia.ListEntry[] memory entries = new PraxisMedia.ListEntry[](1);
        entries[0] = PraxisMedia.ListEntry({
            title: "T",
            ipfsCid: "QmX",
            metadataCid: "",
            price: 0,
            maxSupply: 0,
            collaborators: new address[](0),
            splits: new uint256[](0)
        });
        vm.prank(dave);
        vm.expectRevert("not registered");
        pm.listBatch(entries);
    }

    function test_v2_listBatch_atomic_failure_no_partial() public {
        // Item 0 valid, item 1 has empty title → whole batch reverts
        PraxisMedia.ListEntry[] memory entries = new PraxisMedia.ListEntry[](2);
        entries[0] = PraxisMedia.ListEntry({
            title: "OK",
            ipfsCid: "QmX",
            metadataCid: "",
            price: 0,
            maxSupply: 0,
            collaborators: new address[](0),
            splits: new uint256[](0)
        });
        entries[1] = PraxisMedia.ListEntry({
            title: "", // empty — should revert
            ipfsCid: "QmY",
            metadataCid: "",
            price: 0,
            maxSupply: 0,
            collaborators: new address[](0),
            splits: new uint256[](0)
        });
        vm.prank(alice);
        vm.expectRevert("empty title");
        pm.listBatch(entries);
        // mediaCount unchanged
        assertEq(pm.mediaCount(), 0);
    }
}
