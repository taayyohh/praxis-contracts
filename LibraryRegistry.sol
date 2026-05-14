// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces.sol";

//  __    ____  ____  ____    __    ____  _  _
// (  )  (_  _)(  _ \(  _ \  /__\  (  _ \( \/ )
//  )(__  _)(_  ) _ < )   / /(__)\  )   / \  /
// (____)(____)( ____/(_)\_)(__)(__)(_)\_)  \/
//
/// @title LibraryRegistry
/// @author @taayyohh
/// @notice Shared on-chain library for the Praxis network. Artists contribute PDFs, articles,
///         essays, and other resources with optional IPFS hosting and tagging.
/// @dev Items are stored as events for gas efficiency. Only the contributor can update tags.
contract LibraryRegistry {
    /// @notice Reference to the ArtistRegistry for registration checks
    IArtistRegistry public immutable REGISTRY;

    /// @notice Total number of library items added
    uint256 public itemCount;

    /// @notice Emitted when a new library item is added
    /// @param itemId The sequential item ID
    /// @param contributor The contributor's wallet address
    /// @param title Item title
    /// @param author Item author (free text, may differ from contributor)
    /// @param ipfsCid IPFS content identifier (empty if URL-only)
    /// @param url External URL (empty if IPFS-only)
    /// @param tags Comma-separated tags for discoverability
    /// @param timestamp Block timestamp of the addition
    event ItemAdded(
        uint256 indexed itemId,
        address indexed contributor,
        string title,
        string author,
        string ipfsCid,
        string url,
        string tags,
        uint256 timestamp
    );

    /// @notice Emitted when tags are added to an existing library item
    /// @param itemId The item ID being tagged
    /// @param tagger The contributor updating the tags
    /// @param tags New comma-separated tags to append
    /// @param timestamp Block timestamp of the tag update
    event TagsAdded(
        uint256 indexed itemId,
        address indexed tagger,
        string tags,
        uint256 timestamp
    );

    /// @notice Deploy the LibraryRegistry contract
    /// @param registry Address of the ArtistRegistry contract
    constructor(address registry) {
        REGISTRY = IArtistRegistry(registry);
    }

    /// @notice Add a new item to the shared library
    /// @dev At least one of ipfsCid or url must be provided. Caller must be a registered artist.
    /// @param title Item title (must be non-empty)
    /// @param author Item author (free text)
    /// @param ipfsCid IPFS content identifier (can be empty if url is provided)
    /// @param url External URL (can be empty if ipfsCid is provided)
    /// @param tags Comma-separated tags for discoverability
    /// @return The new item ID
    function addItem(
        string calldata title,
        string calldata author,
        string calldata ipfsCid,
        string calldata url,
        string calldata tags
    ) external returns (uint256) {
        (, uint256 registeredAt) = REGISTRY.artists(msg.sender);
        require(registeredAt > 0, "not registered");
        require(bytes(title).length > 0, "empty title");
        require(bytes(ipfsCid).length > 0 || bytes(url).length > 0, "need ipfs or url");

        uint256 id = itemCount++;
        itemContributor[id] = msg.sender;
        emit ItemAdded(id, msg.sender, title, author, ipfsCid, url, tags, block.timestamp);
        return id;
    }

    /// @notice Maps item ID to its original contributor address
    mapping(uint256 => address) public itemContributor;

    /// @notice Whether migration has been permanently locked
    bool public migrationLocked;

    /// @notice Migrate a single library item (deployer only, before lock)
    /// @param contributor The original contributor's wallet address
    /// @param title Item title
    /// @param ipfsCid IPFS content identifier
    function migrateLibraryItem(
        address contributor, string calldata title, string calldata author, string calldata ipfsCid, string calldata url, string calldata tags
    ) external {
        require(msg.sender == REGISTRY.deployer(), "only deployer");
        require(!migrationLocked, "locked");
        uint256 id = itemCount++;
        itemContributor[id] = contributor;
        emit ItemAdded(id, contributor, title, author, ipfsCid, url, tags, block.timestamp);
    }

    /// @notice Permanently lock migration functions
    function lockMigration() external {
        require(msg.sender == REGISTRY.deployer(), "only deployer");
        migrationLocked = true;
    }

    /// @notice Add additional tags to an existing library item (contributor only)
    /// @param itemId The item ID to tag (must exist)
    /// @param tags Comma-separated tags to append (must be non-empty)
    function tagItem(uint256 itemId, string calldata tags) external {
        require(itemId < itemCount, "item does not exist");
        require(itemContributor[itemId] == msg.sender, "not the contributor");
        require(bytes(tags).length > 0, "empty tags");

        emit TagsAdded(itemId, msg.sender, tags, block.timestamp);
    }

}
