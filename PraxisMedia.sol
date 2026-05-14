// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces.sol";

//  __  __  ____  ____  ____    __
// (  \/  )( ___)(  _ \(_  _)  /__\
//  )    (  )__)  )(_) ) )(   /(__)\
// (_/\/\_)(____)(____/ (__) (__)(__)
//
/// @title PraxisMedia
/// @author @taayyohh
/// @notice Soulbound ERC-6909 media marketplace for the Praxis network. Artists list
///         media with optional collaborator revenue splits. Buyers receive non-transferable
///         proof-of-purchase tokens.
/// @dev Implements a subset of ERC-6909 (all tokens are soulbound -- transfers revert).
///      Revenue is distributed to collaborators via pull payments.
contract PraxisMedia {
    // --- Types ---

    /// @notice Represents a listed media item
    /// @param artist The primary artist who listed the media
    /// @param title Display title
    /// @param ipfsCid IPFS content identifier for the media file
    /// @param metadataCid IPFS content identifier for metadata JSON
    /// @param price Purchase price in wei (0 = free)
    /// @param maxSupply Maximum editions (0 = unlimited)
    /// @param totalMinted Number of editions minted so far
    /// @param collaborators Array of revenue recipients
    /// @param splits Revenue split per collaborator in basis points (sum to 10000)
    struct Media {
        address artist;
        string title;
        string ipfsCid;
        string metadataCid;
        uint256 price;
        uint256 maxSupply;
        uint256 totalMinted;
        address[] collaborators;
        uint256[] splits;
        bool delisted;
    }

    /// @notice Parameters for listing media (used to avoid stack-too-deep)
    struct ListParams {
        string title;
        string ipfsCid;
        string metadataCid;
        uint256 price;
        uint256 maxSupply;
        address[] collaborators;
        uint256[] splits;
    }

    // --- State ---

    /// @notice Reference to the ArtistRegistry for registration checks
    IArtistRegistry public immutable REGISTRY;

    /// @notice Total number of media items listed
    uint256 public mediaCount;

    /// @dev Internal media storage
    mapping(uint256 => Media) internal _media;

    /// @dev Media IDs associated with each artist/collaborator address
    mapping(address => uint256[]) internal _artistMedia;

    /// @notice Pull-payment balances for collaborators
    mapping(address => uint256) public pendingWithdrawals;

    /// @notice ERC-6909 token balances: balanceOf[owner][tokenId]
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    /// @notice ERC-6909 per-token allowances (unused for soulbound but part of the standard)
    mapping(address => mapping(address => mapping(uint256 => uint256))) public allowance;

    /// @notice ERC-6909 operator approvals (unused for soulbound but part of the standard)
    mapping(address => mapping(address => bool)) public isOperator;

    // --- Events ---

    /// @notice Emitted when new media is listed
    /// @param mediaId The new media ID
    /// @param artist The listing artist
    /// @param title Media title
    /// @param ipfsCid IPFS content identifier
    /// @param price Purchase price in wei
    /// @param maxSupply Maximum editions (0 = unlimited)
    event Listed(uint256 indexed mediaId, address indexed artist, string title, string ipfsCid, uint256 price, uint256 maxSupply);

    /// @notice Emitted when media is purchased
    /// @param mediaId The purchased media ID
    /// @param buyer The buyer's address
    /// @param tokenId The minted soulbound token ID
    /// @param price The price paid in wei
    event Purchased(uint256 indexed mediaId, address indexed buyer, uint256 tokenId, uint256 price);

    /// @notice Emitted when the price of a media item is changed
    /// @param mediaId The media ID
    /// @param newPrice The new price in wei
    event PriceChanged(uint256 indexed mediaId, uint256 newPrice);

    /// @notice Emitted when the max supply of a media item is changed
    /// @param mediaId The media ID
    /// @param newMaxSupply The new max supply (0 = unlimited)
    event SupplyChanged(uint256 indexed mediaId, uint256 newMaxSupply);

    /// @notice Emitted when a media item is delisted
    /// @param mediaId The media ID
    event Delisted(uint256 indexed mediaId);

    /// @notice Emitted when an artist withdraws their pending earnings
    /// @param artist The artist's address
    /// @param amount The amount withdrawn in wei
    event Withdrawn(address indexed artist, uint256 amount);

    /// @notice ERC-6909 transfer event
    event Transfer(address caller, address indexed sender, address indexed receiver, uint256 indexed id, uint256 amount);

    /// @notice ERC-6909 approval event
    event Approval(address indexed owner, address indexed spender, uint256 indexed id, uint256 amount);

    /// @notice ERC-6909 operator approval event
    event OperatorSet(address indexed owner, address indexed spender, bool approved);

    // --- Modifiers ---

    /// @notice Restricts function access to registered artists only
    modifier onlyRegistered() {
        (, uint256 registeredAt) = REGISTRY.artists(msg.sender);
        require(registeredAt > 0, "not registered");
        _;
    }

    // --- Constructor ---

    /// @notice Deploy the PraxisMedia contract
    /// @param registry Address of the ArtistRegistry contract
    constructor(address registry) {
        REGISTRY = IArtistRegistry(registry);
    }

    // --- Media lifecycle ---

    /// @notice List media with collaborator revenue splits (struct version, avoids stack-too-deep)
    /// @param p Listing parameters
    /// @return The new media ID
    function listMedia(ListParams calldata p) external onlyRegistered returns (uint256) {
        return _doList(p.title, p.ipfsCid, p.metadataCid, p.price, p.maxSupply, p.collaborators, p.splits);
    }

    /// @notice List media with optional collaborator revenue splits
    /// @dev 7-parameter version for backward compatibility. Delegates to internal _doList.
    function list(
        string calldata title,
        string calldata ipfsCid,
        string calldata metadataCid,
        uint256 price,
        uint256 maxSupply,
        address[] calldata collaborators,
        uint256[] calldata splits
    ) external onlyRegistered returns (uint256) {
        return _doList(title, ipfsCid, metadataCid, price, maxSupply, collaborators, splits);
    }

    /// @dev Internal listing logic
    function _doList(
        string memory title,
        string memory ipfsCid,
        string memory metadataCid,
        uint256 price,
        uint256 maxSupply,
        address[] memory collaborators,
        uint256[] memory splits
    ) internal returns (uint256) {
        require(bytes(title).length > 0, "empty title");
        require(bytes(ipfsCid).length > 0, "empty ipfsCid");
        require(collaborators.length == splits.length, "length mismatch");
        require(collaborators.length <= 200, "too many collaborators");

        uint256 mediaId = mediaCount++;
        Media storage m = _media[mediaId];
        m.artist = msg.sender;
        m.title = title;
        m.ipfsCid = ipfsCid;
        m.metadataCid = metadataCid;
        m.price = price;
        m.maxSupply = maxSupply;

        if (collaborators.length == 0) {
            m.collaborators.push(msg.sender);
            m.splits.push(10000);
            _artistMedia[msg.sender].push(mediaId);
        } else {
            uint256 total;
            for (uint256 i = 0; i < splits.length; i++) {
                total += splits[i];
                require(collaborators[i] != address(0), "zero address collaborator");
                m.collaborators.push(collaborators[i]);
                m.splits.push(splits[i]);
                _artistMedia[collaborators[i]].push(mediaId);
            }
            require(total == 10000, "splits must sum to 10000");
        }

        emit Listed(mediaId, msg.sender, title, ipfsCid, price, maxSupply);
        return mediaId;
    }

    /// @notice List solo media without specifying collaborators (100% to the artist)
    /// @param title Media title (must be non-empty)
    /// @param ipfsCid IPFS content identifier (must be non-empty)
    /// @param metadataCid IPFS metadata identifier
    /// @param price Purchase price in wei
    /// @param maxSupply Maximum editions (0 = unlimited)
    /// @return The new media ID
    function list(
        string calldata title,
        string calldata ipfsCid,
        string calldata metadataCid,
        uint256 price,
        uint256 maxSupply
    ) external onlyRegistered returns (uint256) {
        require(bytes(title).length > 0, "empty title");
        require(bytes(ipfsCid).length > 0, "empty ipfsCid");

        uint256 mediaId = mediaCount++;
        Media storage m = _media[mediaId];
        m.artist = msg.sender;
        m.title = title;
        m.ipfsCid = ipfsCid;
        m.metadataCid = metadataCid;
        m.price = price;
        m.maxSupply = maxSupply;
        m.collaborators.push(msg.sender);
        m.splits.push(10000);

        _artistMedia[msg.sender].push(mediaId);

        emit Listed(mediaId, msg.sender, title, ipfsCid, price, maxSupply);
        return mediaId;
    }

    /// @notice v2: Purchase multiple media editions in a single transaction
    /// @dev Atomic batch buy. Loops through `mediaIds`, requires `msg.value` to equal
    ///      the SUM of all item prices, distributes revenue per-item per existing
    ///      pull-payment rules, refunds any excess. Caps the batch at 50 items to
    ///      bound gas usage and prevent griefing. If any item is sold out the entire
    ///      batch reverts (atomicity > best-effort: either the buyer collects the
    ///      whole album or nothing).
    /// @param mediaIds The media items to purchase in one tx
    function purchaseBatch(uint256[] calldata mediaIds) external payable {
        uint256 n = mediaIds.length;
        require(n > 0, "empty batch");
        // 20-item cap. Each item can have up to 200 collaborators → worst case
        // 4000 SSTOREs to pendingWithdrawals plus token mints. 20 items keeps
        // us safely under Scroll's block gas limit even at the pathological
        // collaborator-density ceiling.
        require(n <= 20, "batch too large");

        // First pass: verify availability + sum total cost
        uint256 totalCost = 0;
        for (uint256 i = 0; i < n; i++) {
            Media storage m = _media[mediaIds[i]];
            require(m.artist != address(0), "media not found");
            require(!m.delisted, "delisted");
            require(m.maxSupply == 0 || m.totalMinted < m.maxSupply, "sold out");
            totalCost += m.price;
        }
        require(msg.value >= totalCost, "insufficient payment");

        // Second pass: mint + distribute (effects before interactions)
        for (uint256 i = 0; i < n; i++) {
            uint256 mediaId = mediaIds[i];
            Media storage m = _media[mediaId];
            m.totalMinted++;
            uint256 serial = m.totalMinted;
            uint256 tokenId = (mediaId << 128) | serial;

            balanceOf[msg.sender][tokenId] += 1;
            emit Transfer(msg.sender, address(0), msg.sender, tokenId, 1);

            // distribute this item's price across its collaborators
            uint256 remaining = m.price;
            uint256 cLen = m.collaborators.length;
            for (uint256 j = 0; j < cLen; j++) {
                uint256 share = (m.price * m.splits[j]) / 10000;
                if (j == cLen - 1) share = remaining; // last collaborator absorbs dust
                pendingWithdrawals[m.collaborators[j]] += share;
                remaining -= share;
            }

            emit Purchased(mediaId, msg.sender, tokenId, m.price);
        }

        // Refund any overpayment after all state changes
        uint256 excess = msg.value - totalCost;
        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            require(ok, "refund failed");
        }
    }

    /// @notice v2: List multiple media items in a single transaction
    /// @dev Each entry becomes an independent listing with its own collaborators
    ///      and splits. Capped at 20 items per batch to bound gas. Returns the array
    ///      of new media ids in the same order as the input. All-or-nothing — any
    ///      validation failure reverts the whole batch. Uses a struct param so the
    ///      function compiles without `via_ir` (Etherscan-family verifiers produce
    ///      non-deterministic bytecode for via_ir contracts on solc 0.8.20).
    /// @param entries Array of ListEntry structs (one per item)
    /// @return ids The new media ids (length == entries.length)
    struct ListEntry {
        string title;
        string ipfsCid;
        string metadataCid;
        uint256 price;
        uint256 maxSupply;
        address[] collaborators;
        uint256[] splits;
    }

    function listBatch(ListEntry[] calldata entries) external onlyRegistered returns (uint256[] memory ids) {
        uint256 n = entries.length;
        require(n > 0, "empty batch");
        // 20-item cap, same reasoning as purchaseBatch — bounds total
        // SSTOREs across the batch's collaborator/split push loops.
        require(n <= 20, "batch too large");

        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            // Per-item collaborator cap for the batch path: 50 (vs 200 for the
            // single-item list()). Keeps total batch SSTOREs bounded.
            require(entries[i].collaborators.length <= 50, "too many collaborators in batch item");
            ids[i] = _listOne(entries[i]);
        }
    }

    /// @dev Internal helper that takes a single struct so it stays under the stack-
    ///      too-deep ceiling without needing via_ir. Used by both `list()` and
    ///      `listBatch()`. The struct is in calldata so no extra memory allocation
    ///      happens beyond what list() would do anyway.
    function _listOne(ListEntry calldata entry) internal returns (uint256) {
        require(bytes(entry.title).length > 0, "empty title");
        require(bytes(entry.ipfsCid).length > 0, "empty ipfsCid");
        require(entry.collaborators.length == entry.splits.length, "length mismatch");
        require(entry.collaborators.length <= 200, "too many collaborators");

        uint256 mediaId = mediaCount++;
        Media storage m = _media[mediaId];
        m.artist = msg.sender;
        m.title = entry.title;
        m.ipfsCid = entry.ipfsCid;
        m.metadataCid = entry.metadataCid;
        m.price = entry.price;
        m.maxSupply = entry.maxSupply;

        if (entry.collaborators.length == 0) {
            m.collaborators.push(msg.sender);
            m.splits.push(10000);
            _artistMedia[msg.sender].push(mediaId);
        } else {
            uint256 total = 0;
            for (uint256 i = 0; i < entry.splits.length; i++) {
                require(entry.collaborators[i] != address(0), "zero address collaborator");
                total += entry.splits[i];
                m.collaborators.push(entry.collaborators[i]);
                m.splits.push(entry.splits[i]);
                _artistMedia[entry.collaborators[i]].push(mediaId);
            }
            require(total == 10000, "splits must sum to 10000");
        }

        emit Listed(mediaId, msg.sender, entry.title, entry.ipfsCid, entry.price, entry.maxSupply);
        return mediaId;
    }

    /// @notice Purchase a media edition, minting a soulbound proof-of-purchase token
    /// @dev Revenue is distributed to collaborators via pendingWithdrawals (pull pattern).
    ///      Overpayment is refunded. CEI: all state changes before refund transfer.
    /// @param mediaId The media item to purchase
    function purchase(uint256 mediaId) external payable {
        Media storage m = _media[mediaId];
        require(m.artist != address(0), "media not found");
        require(!m.delisted, "delisted");
        require(m.maxSupply == 0 || m.totalMinted < m.maxSupply, "sold out");
        require(msg.value >= m.price, "insufficient payment");

        // Effects: update state before any external interaction
        m.totalMinted++;
        uint256 serial = m.totalMinted;
        uint256 tokenId = (mediaId << 128) | serial;

        balanceOf[msg.sender][tokenId] += 1;
        emit Transfer(msg.sender, address(0), msg.sender, tokenId, 1);

        // distribute price among collaborators per splits
        uint256 remaining = m.price;
        for (uint256 i = 0; i < m.collaborators.length; i++) {
            uint256 share = (m.price * m.splits[i]) / 10000;
            if (i == m.collaborators.length - 1) {
                // last collaborator gets remainder to avoid dust
                share = remaining;
            }
            pendingWithdrawals[m.collaborators[i]] += share;
            remaining -= share;
        }

        // Interaction: refund overpayment
        uint256 excess = msg.value - m.price;
        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            require(ok, "refund failed");
        }

        emit Purchased(mediaId, msg.sender, tokenId, m.price);
    }

    /// @notice Update the price of a listed media item (artist only)
    /// @param mediaId The media item to update
    /// @param newPrice The new price in wei
    function setPrice(uint256 mediaId, uint256 newPrice) external {
        require(_media[mediaId].artist == msg.sender, "not artist");
        _media[mediaId].price = newPrice;
        emit PriceChanged(mediaId, newPrice);
    }

    /// @notice Update the max supply of a listed media item (artist only)
    /// @dev Cannot set below the number already minted.
    /// @param mediaId The media item to update
    /// @param newMax The new max supply (0 = unlimited)
    function setMaxSupply(uint256 mediaId, uint256 newMax) external {
        Media storage m = _media[mediaId];
        require(m.artist == msg.sender, "not artist");
        require(newMax == 0 || newMax >= m.totalMinted, "below minted");
        m.maxSupply = newMax;
        emit SupplyChanged(mediaId, newMax);
    }

    /// @notice Delist a media item, preventing further purchases (artist only)
    /// @param mediaId The media item to delist
    function delist(uint256 mediaId) external {
        Media storage m = _media[mediaId];
        require(m.artist == msg.sender, "not artist");
        require(!m.delisted, "already delisted");
        m.delisted = true;
        emit Delisted(mediaId);
    }

    /// @notice Withdraw pending earnings from media sales
    /// @dev CEI: zeroes balance before external ETH transfer.
    function withdraw() external {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "nothing to withdraw");

        // Effects before interaction
        pendingWithdrawals[msg.sender] = 0;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");

        emit Withdrawn(msg.sender, amount);
    }

    // --- Views ---

    /// @notice Get all media IDs associated with an artist or collaborator
    /// @param artist The address to query
    /// @return Array of media IDs
    function getMediaByArtist(address artist) external view returns (uint256[] memory) {
        return _artistMedia[artist];
    }

    /// @notice Get core details for a media item
    /// @param mediaId The media item to query
    /// @return artist The listing artist
    /// @return title Media title
    /// @return ipfsCid IPFS content identifier
    /// @return metadataCid IPFS metadata identifier
    /// @return price Purchase price in wei
    /// @return maxSupply Maximum editions (0 = unlimited)
    /// @return totalMinted Number of editions minted
    function media(uint256 mediaId) external view returns (
        address artist, string memory title, string memory ipfsCid, string memory metadataCid,
        uint256 price, uint256 maxSupply, uint256 totalMinted
    ) {
        Media storage m = _media[mediaId];
        return (m.artist, m.title, m.ipfsCid, m.metadataCid, m.price, m.maxSupply, m.totalMinted);
    }

    /// @notice Get the collaborators and their revenue splits for a media item
    /// @param mediaId The media item to query
    /// @return Tuple of (collaborator addresses, split amounts in basis points)
    function getCollaborators(uint256 mediaId) external view returns (address[] memory, uint256[] memory) {
        return (_media[mediaId].collaborators, _media[mediaId].splits);
    }

    // --- ERC-6909 (soulbound) ---

    /// @notice Transfer is disabled -- all PraxisMedia tokens are soulbound
    function transfer(address, uint256, uint256) external pure returns (bool) {
        revert("soulbound");
    }

    /// @notice TransferFrom is disabled -- all PraxisMedia tokens are soulbound
    function transferFrom(address, address, uint256, uint256) external pure returns (bool) {
        revert("soulbound");
    }

    /// @notice Approve a spender for a token ID (part of ERC-6909 standard)
    /// @param spender The approved spender address
    /// @param id The token ID
    /// @param amount The approved amount
    /// @return True on success
    function approve(address spender, uint256 id, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender][id] = amount;
        emit Approval(msg.sender, spender, id, amount);
        return true;
    }

    /// @notice Grant or revoke operator status (part of ERC-6909 standard)
    /// @param spender The operator address
    /// @param approved True to grant, false to revoke
    /// @return True on success
    function setOperator(address spender, bool approved) external returns (bool) {
        isOperator[msg.sender][spender] = approved;
        emit OperatorSet(msg.sender, spender, approved);
        return true;
    }
}
