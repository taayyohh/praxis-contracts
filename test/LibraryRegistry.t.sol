// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../ArtistRegistry.sol";
import "../LibraryRegistry.sol";

contract LibraryRegistryTest is Test {
    event ItemAdded(uint256 indexed itemId, address indexed contributor, string title, string author, string ipfsCid, string url, string tags, uint256 timestamp);

    ArtistRegistry registry;
    LibraryRegistry library_;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address unregistered = makeAddr("unregistered");

    function setUp() public {
        registry = new ArtistRegistry();
        library_ = new LibraryRegistry(address(registry));

        registry.registerDirect(alice, "alice.xyz");
        registry.registerDirect(bob, "bob.xyz");
    }

    function test_addItem_ipfs() public {
        vm.expectEmit(true, true, false, true);
        emit ItemAdded(0, alice, "Theatre of the Oppressed", "Augusto Boal", "QmXyz123", "", "theater,politics,pedagogy", block.timestamp);

        vm.prank(alice);
        uint256 id = library_.addItem("Theatre of the Oppressed", "Augusto Boal", "QmXyz123", "", "theater,politics,pedagogy");
        assertEq(id, 0);
        assertEq(library_.itemCount(), 1);
    }

    function test_addItem_url() public {
        vm.prank(bob);
        uint256 id = library_.addItem("The Case for Reparations", "Ta-Nehisi Coates", "", "https://example.com/article", "politics,race,economics");
        assertEq(id, 0);
    }

    function test_addItem_empty_title_reverts() public {
        vm.prank(alice);
        vm.expectRevert("empty title");
        library_.addItem("", "Author", "QmXyz", "", "tag");
    }

    function test_addItem_no_source_reverts() public {
        vm.prank(alice);
        vm.expectRevert("need ipfs or url");
        library_.addItem("Title", "Author", "", "", "tag");
    }

    function test_addItem_unregistered_reverts() public {
        vm.prank(unregistered);
        vm.expectRevert("not registered");
        library_.addItem("Title", "Author", "QmXyz", "", "tag");
    }

    function test_multiple_items() public {
        vm.prank(alice);
        library_.addItem("Book 1", "Author 1", "Qm1", "", "tag1");
        vm.prank(bob);
        library_.addItem("Book 2", "Author 2", "Qm2", "", "tag2");
        vm.prank(alice);
        library_.addItem("Article 3", "Author 3", "", "https://example.com", "tag3");

        assertEq(library_.itemCount(), 3);
    }
}
