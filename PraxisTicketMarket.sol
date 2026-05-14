// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

//  ____  ____  ___  _  _  ____  ____  ___
// (_  _)(_  _)/ __)( )/ )( ___)(_  _)/ __)
//   )(   _)(_( (__  )  (  )__)   )(  \__ \
//  (__) (____)\___)(__ \_)(____) (__) (___/
//
/// @title IPraxis
/// @notice Interface for the Praxis ERC-6909 token contract
interface IPraxis {
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function getTokenType(uint256 id) external pure returns (uint8);
    function isOperator(address owner, address spender) external view returns (bool);
    function allowance(address owner, address spender, uint256 id) external view returns (uint256);
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external;
}

/// @title PraxisTicketMarket
/// @author @taayyohh
/// @notice Secondary marketplace for transferable TICKET tokens from the Praxis ERC-6909 contract.
///         Only TICKET type (type=1) tokens can be listed. PRODUCER and CONTRIBUTOR tokens are soulbound.
/// @dev Uses pull payments for seller proceeds. Requires operator or per-token approval on the
///      Praxis contract before listing.
contract PraxisTicketMarket {
    // --- Types ---

    /// @notice A resale listing for a ticket token
    /// @param seller The address that listed the ticket
    /// @param price The asking price in wei
    /// @param active Whether the listing is currently active
    struct Listing {
        address seller;
        uint256 price;
        bool active;
    }

    // --- State ---

    /// @notice Reference to the Praxis ERC-6909 contract
    IPraxis public immutable praxis;

    /// @notice Active listings by token ID
    mapping(uint256 => Listing) public listings;

    /// @notice Pull-payment balances for sellers
    mapping(address => uint256) public pendingWithdrawals;

    /// @notice Total number of currently active listings
    uint256 public listingCount;

    // --- Events ---

    /// @notice Emitted when a ticket is listed for resale
    /// @param tokenId The listed token ID
    /// @param seller The seller's address
    /// @param price The asking price in wei
    event TicketListed(uint256 indexed tokenId, address indexed seller, uint256 price);

    /// @notice Emitted when a listed ticket is purchased
    /// @param tokenId The purchased token ID
    /// @param buyer The buyer's address
    /// @param seller The seller's address
    /// @param price The purchase price in wei
    event TicketPurchased(uint256 indexed tokenId, address indexed buyer, address indexed seller, uint256 price);

    /// @notice Emitted when a listing is cancelled by the seller
    /// @param tokenId The cancelled token ID
    /// @param seller The seller's address
    event TicketCancelled(uint256 indexed tokenId, address indexed seller);

    /// @notice Emitted when a listing's price is updated
    /// @param tokenId The token ID
    /// @param newPrice The new asking price in wei
    event TicketPriceChanged(uint256 indexed tokenId, uint256 newPrice);

    /// @notice Emitted when a seller withdraws their pending proceeds
    /// @param seller The seller's address
    /// @param amount The amount withdrawn in wei
    event Withdrawn(address indexed seller, uint256 amount);

    // --- Constructor ---

    /// @notice Deploy the PraxisTicketMarket contract
    /// @param _praxis Address of the Praxis ERC-6909 contract
    constructor(address _praxis) {
        praxis = IPraxis(_praxis);
    }

    // --- Functions ---

    /// @notice List a ticket token for resale
    /// @dev Caller must own the token and have approved this contract (operator or per-token allowance).
    ///      Only TICKET type (type=1) tokens can be listed.
    /// @param tokenId The token ID to list
    /// @param price The asking price in wei (must be > 0)
    function list(uint256 tokenId, uint256 price) external {
        require(praxis.balanceOf(msg.sender, tokenId) >= 1, "not owner");
        require(praxis.getTokenType(tokenId) == 1, "not a ticket");
        require(
            praxis.isOperator(msg.sender, address(this)) ||
            praxis.allowance(msg.sender, address(this), tokenId) >= 1,
            "not approved"
        );
        require(price > 0, "zero price");
        require(!listings[tokenId].active, "already listed");

        listings[tokenId] = Listing({
            seller: msg.sender,
            price: price,
            active: true
        });
        listingCount++;

        emit TicketListed(tokenId, msg.sender, price);
    }

    /// @notice Purchase a listed ticket
    /// @dev CEI: all state changes (deactivate listing, credit seller) happen before
    ///      the external transferFrom call on the Praxis contract.
    /// @param tokenId The token ID to purchase
    function purchase(uint256 tokenId) external payable {
        Listing storage listing = listings[tokenId];
        require(listing.active, "not active");
        require(msg.value == listing.price, "wrong price");

        address seller = listing.seller;
        uint256 price = listing.price;

        // Verify seller still owns the token (prevents stale listings)
        require(praxis.balanceOf(seller, tokenId) >= 1, "seller no longer owns token");

        // Effects: deactivate listing and credit seller before external call
        listing.active = false;
        listingCount--;
        pendingWithdrawals[seller] += price;

        // Interaction: external call to Praxis contract
        praxis.transferFrom(seller, msg.sender, tokenId, 1);

        emit TicketPurchased(tokenId, msg.sender, seller, price);
    }

    /// @notice Cancel a listing (seller only)
    /// @param tokenId The token ID to delist
    function cancel(uint256 tokenId) external {
        Listing storage listing = listings[tokenId];
        require(listing.active, "not active");
        require(listing.seller == msg.sender, "not seller");

        listing.active = false;
        listingCount--;

        emit TicketCancelled(tokenId, msg.sender);
    }

    /// @notice Update the asking price of a listing (seller only)
    /// @param tokenId The listed token ID
    /// @param newPrice The new asking price in wei (must be > 0)
    function updatePrice(uint256 tokenId, uint256 newPrice) external {
        Listing storage listing = listings[tokenId];
        require(listing.active, "not active");
        require(listing.seller == msg.sender, "not seller");
        require(newPrice > 0, "zero price");

        listing.price = newPrice;

        emit TicketPriceChanged(tokenId, newPrice);
    }

    /// @notice Withdraw pending proceeds from ticket sales
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
}
