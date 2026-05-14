// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces.sol";

//  ____  __    _____  ___
// (  _ \(  )  (  _  )/ __)
//  ) _ < )(__  )(_)( ( (_-.
// (____/(____)(_____)\___ /
//
/// @title BlogRegistry
/// @author @taayyohh
/// @notice On-chain blog post registry for the Praxis network. Posts are stored as events
///         for gas efficiency, with optional references to projects, portfolio items, or
///         other posts (replies).
/// @dev Reference types: 0=standalone, 1=project reference, 2=portfolio item, 3=reply
contract BlogRegistry {
    /// @notice Reference to the ArtistRegistry for registration checks
    IArtistRegistry public immutable REGISTRY;

    /// @notice Total number of posts created
    uint256 public postCount;

    /// @notice Emitted when a blog post is created
    /// @param postId The sequential post ID
    /// @param author The author's wallet address
    /// @param title Post title
    /// @param content Post content (markdown)
    /// @param timestamp Block timestamp of the post
    /// @param refType Reference type (0=standalone, 1=project, 2=portfolio, 3=reply)
    /// @param refId Reference ID (project ID, portfolio item ID, or parent post ID)
    event Posted(
        uint256 indexed postId,
        address indexed author,
        string title,
        string content,
        uint256 timestamp,
        uint8 refType,
        uint256 refId
    );

    /// @notice Deploy the BlogRegistry contract
    /// @param registry Address of the ArtistRegistry contract
    constructor(address registry) {
        REGISTRY = IArtistRegistry(registry);
    }

    /// @notice Create a standalone blog post
    /// @param title Post title (must be non-empty)
    /// @param content Post content (markdown)
    /// @return The new post ID
    function post(string calldata title, string calldata content) external returns (uint256) {
        return _post(title, content, 0, 0);
    }

    /// @notice Create a blog post with a reference to a project, portfolio item, or parent post
    /// @param title Post title (must be non-empty)
    /// @param content Post content (markdown)
    /// @param refType Reference type (0=standalone, 1=project, 2=portfolio, 3=reply)
    /// @param refId The referenced entity's ID
    /// @return The new post ID
    function postWithRef(
        string calldata title,
        string calldata content,
        uint8 refType,
        uint256 refId
    ) external returns (uint256) {
        return _post(title, content, refType, refId);
    }

    /// @notice Internal post creation logic
    /// @param title Post title (must be non-empty)
    /// @param content Post content
    /// @param refType Reference type
    /// @param refId Referenced entity ID
    /// @return The new post ID
    function _post(
        string calldata title,
        string calldata content,
        uint8 refType,
        uint256 refId
    ) internal returns (uint256) {
        require(REGISTRY.isUser(msg.sender), "not registered");
        require(bytes(title).length > 0, "empty title");

        uint256 id = postCount++;
        emit Posted(id, msg.sender, title, content, block.timestamp, refType, refId);
        return id;
    }

    // --- Migration functions (deployer-only, one-time use) ---

    /// @notice Whether migration has been permanently locked
    bool public migrationLocked;

    /// @notice Migrate a single blog post (deployer only, before lock)
    /// @param author The post author's wallet address
    /// @param title Post title
    /// @param content Post content (markdown)
    /// @param refType Reference type (0=standalone, 1=project, 2=portfolio, 3=reply, 5=amendment)
    /// @param refId Referenced entity ID
    function migratePost(
        address author,
        string calldata title,
        string calldata content,
        uint256 refType,
        uint256 refId
    ) external {
        require(msg.sender == REGISTRY.deployer(), "only deployer");
        require(!migrationLocked, "locked");

        uint256 postId = postCount++;
        emit Posted(postId, author, title, content, block.timestamp, uint8(refType), refId);
    }

    /// @notice Permanently lock migration functions
    function lockMigration() external {
        require(msg.sender == REGISTRY.deployer(), "only deployer");
        migrationLocked = true;
    }
}
