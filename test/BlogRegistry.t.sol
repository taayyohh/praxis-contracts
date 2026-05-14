// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../ArtistRegistry.sol";
import "../BlogRegistry.sol";

contract BlogRegistryTest is Test {
    event Posted(uint256 indexed postId, address indexed author, string title, string content, uint256 timestamp, uint8 refType, uint256 refId);

    ArtistRegistry registry;
    BlogRegistry blog;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address supporter1 = makeAddr("supporter1");
    address supporter2 = makeAddr("supporter2");
    address unregistered = makeAddr("unregistered");

    function setUp() public {
        registry = new ArtistRegistry();
        blog = new BlogRegistry(address(registry));

        registry.registerDirect(alice, "alice.xyz");
        registry.registerDirect(bob, "bob.xyz");

        // Register supporters
        vm.prank(supporter1);
        registry.registerSupporter("tobias");
        vm.prank(supporter2);
        registry.registerSupporter("moi");
    }

    function test_post_success() public {
        vm.expectEmit(true, true, false, true);
        emit Posted(0, alice, "hello world", "my first post", block.timestamp, 0, 0);

        vm.prank(alice);
        uint256 id = blog.post("hello world", "my first post");

        assertEq(id, 0);
        assertEq(blog.postCount(), 1);
    }

    function test_post_empty_title_reverts() public {
        vm.prank(alice);
        vm.expectRevert("empty title");
        blog.post("", "some content");
    }

    function test_post_unregistered_reverts() public {
        vm.prank(unregistered);
        vm.expectRevert("not registered");
        blog.post("title", "content");
    }

    function test_multiple_posts_same_author() public {
        vm.startPrank(alice);
        uint256 id1 = blog.post("post 1", "first");
        uint256 id2 = blog.post("post 2", "second");
        uint256 id3 = blog.post("post 3", "third");
        vm.stopPrank();

        assertEq(id1, 0);
        assertEq(id2, 1);
        assertEq(id3, 2);
        assertEq(blog.postCount(), 3);
    }

    function test_multiple_authors() public {
        vm.prank(alice);
        uint256 id1 = blog.post("alice post", "from alice");

        vm.prank(bob);
        uint256 id2 = blog.post("bob post", "from bob");

        assertEq(id1, 0);
        assertEq(id2, 1);
        assertEq(blog.postCount(), 2);
    }

    function test_post_with_project_reference() public {
        vm.prank(alice);
        uint256 id = blog.postWithRef("project update", "rehearsals going great", 1, 42);
        assertEq(id, 0);
        assertEq(blog.postCount(), 1);
    }

    function test_post_with_reply() public {
        vm.prank(alice);
        blog.post("original post", "content");

        vm.prank(bob);
        uint256 replyId = blog.postWithRef("re: original post", "great post", 3, 0);
        assertEq(replyId, 1);
    }

    function test_post_empty_content_allowed() public {
        vm.prank(alice);
        uint256 id = blog.post("title only", "");
        assertEq(id, 0);
    }

    // --- Supporter posting tests ---

    function test_supporter_can_post() public {
        vm.expectEmit(true, true, false, true);
        emit Posted(0, supporter1, "audience thoughts", "great album", block.timestamp, 0, 0);

        vm.prank(supporter1);
        uint256 id = blog.post("audience thoughts", "great album");

        assertEq(id, 0);
        assertEq(blog.postCount(), 1);
    }

    function test_supporter_can_post_with_ref() public {
        vm.prank(supporter1);
        uint256 id = blog.postWithRef("review", "amazing track", 3, 5);
        assertEq(id, 0);
        assertEq(blog.postCount(), 1);
    }

    function test_supporter_and_artist_can_both_post() public {
        vm.prank(alice);
        uint256 id1 = blog.post("artist post", "from the artist");

        vm.prank(supporter1);
        uint256 id2 = blog.post("supporter post", "from the audience");

        vm.prank(supporter2);
        uint256 id3 = blog.post("another supporter", "also from audience");

        assertEq(id1, 0);
        assertEq(id2, 1);
        assertEq(id3, 2);
        assertEq(blog.postCount(), 3);
    }

    function test_unregistered_still_reverts() public {
        vm.prank(unregistered);
        vm.expectRevert("not registered");
        blog.post("title", "content");
    }
}
