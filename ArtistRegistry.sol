// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

//    __    ____  ____  ____  ___  ____
//   /__\  (  _ \(_  _)(_  _)/ __)(_  _)
//  /(__)\  )   /  )(   _)(_ \__ \  )(
// (__)(__)(_)\_) (__) (____)(___/ (__)
//  ____  ____  ___  ____  ___  ____  ____  _  _
// (  _ \( ___)/ __)(_  _)/ __)(_  _)(  _ \( \/ )
//  )   / )__)( (_-. _)(_ \__ \  )(   )   / \  /
// (_)\_)(____)\___/(____)(___/ (__) (_)\_) (__)
//
/// @title ArtistRegistry
/// @author @taayyohh
/// @notice On-chain registry for Praxis network artists, mapping wallet addresses to domains
/// @dev Supports orchestrator-signed registration, domain updates, and a full social graph (follow/unfollow)
contract ArtistRegistry {
    /// @notice Represents a registered artist
    /// @param domain The artist's verified domain name
    /// @param registeredAt Timestamp of registration
    struct Artist {
        string domain;
        uint256 registeredAt;
    }

    /// @notice Mapping of wallet address to artist profile
    mapping(address => Artist) public artists;

    /// @notice Ordered list of all registered artist addresses
    address[] public registeredAddresses;

    /// @dev Whether address A follows address B
    mapping(address => mapping(address => bool)) internal _follows;

    /// @dev List of addresses that a given address is following
    mapping(address => address[]) internal _following;

    /// @dev List of addresses that follow a given address
    mapping(address => address[]) internal _followers;

    /// @dev Index of a target in _following[source] for O(1) removal
    mapping(address => mapping(address => uint256)) internal _followingIndex;

    /// @dev Index of a follower in _followers[target] for O(1) removal
    mapping(address => mapping(address => uint256)) internal _followersIndex;

    /// @dev Index of an address in registeredAddresses for O(1) removal
    mapping(address => uint256) internal _registeredIndex;

    /// @notice The deployer address, used for admin operations
    address public deployer;

    /// @notice Pending deployer for timelock transfer
    address public pendingDeployer;

    /// @notice Timestamp when pending deployer transfer can be confirmed
    uint256 public deployerTransferTime;

    /// @notice Timelock duration for deployer transfer
    uint256 public constant DEPLOYER_TIMELOCK = 2 days;

    /// @notice The orchestrator address that signs domain verification proofs
    address public orchestrator;

    /// @notice Whether the initial migration has been completed
    bool public migrated;

    /// @notice Treasury wallet that receives deploy fees
    address public treasury;

    /// @notice Deploy fee in wei (set by deployer, defaults to 0 for backward compat)
    uint256 public deployFee;

    /// @notice Nonce per user for replay-safe signatures
    mapping(address => uint256) public nonces;

    /// @notice Emitted when treasury address is updated
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @notice Emitted when deploy fee is updated
    event DeployFeeUpdated(uint256 oldFee, uint256 newFee);

    /// @notice Represents a registered supporter (fan/collector)
    /// @param handle The supporter's chosen handle
    /// @param registeredAt Timestamp of registration
    struct Supporter {
        string handle;
        uint256 registeredAt;
    }

    /// @notice Mapping of wallet address to supporter profile
    mapping(address => Supporter) public supporters;

    /// @notice Reverse lookup: handle string to wallet address
    mapping(string => address) public supporterByHandle;

    /// @notice Ordered list of all registered supporter addresses
    address[] public registeredSupporters;

    /// @dev Index of an address in registeredSupporters for O(1) removal
    mapping(address => uint256) internal _supporterIndex;

    /// @notice Emitted when a supporter registers
    event SupporterRegistered(address indexed wallet, string handle, uint256 timestamp);

    /// @notice Emitted when a supporter unregisters
    event SupporterUnregistered(address indexed wallet, string handle);

    /// @notice Emitted when an artist registers or updates their domain
    /// @param wallet The artist's wallet address
    /// @param domain The registered or updated domain
    event Registered(address indexed wallet, string domain);

    /// @notice Emitted when an artist unregisters from the network
    /// @param wallet The artist's wallet address
    /// @param domain The domain that was unregistered
    event Unregistered(address indexed wallet, string domain);

    /// @notice Emitted when an artist transfers their registration to a new wallet
    /// @param oldWallet The original wallet address
    /// @param newWallet The new wallet address
    /// @param domain The domain being transferred
    event RegistrationTransferred(address indexed oldWallet, address indexed newWallet, string domain);

    /// @notice Emitted when one artist follows another
    /// @param follower The address initiating the follow
    /// @param followed The address being followed
    event Followed(address indexed follower, address indexed followed);

    /// @notice Emitted when one artist unfollows another
    /// @param follower The address initiating the unfollow
    /// @param followed The address being unfollowed
    event Unfollowed(address indexed follower, address indexed followed);

    /// @notice Emitted when a deployer transfer is proposed
    event DeployerTransferProposed(address indexed current, address indexed proposed);

    /// @notice Emitted when a deployer transfer is confirmed
    event DeployerTransferred(address indexed oldDeployer, address indexed newDeployer);

    /// @notice Sets the deployer as the initial orchestrator and treasury
    constructor() {
        deployer = msg.sender;
        orchestrator = msg.sender;
        treasury = msg.sender;
    }

    /// @notice Update the orchestrator address that signs registration proofs
    /// @param _orchestrator The new orchestrator address
    function setOrchestrator(address _orchestrator) external {
        require(msg.sender == deployer, "not deployer");
        orchestrator = _orchestrator;
    }

    /// @notice Update the treasury wallet — callable by deployer only
    /// @param _treasury The new treasury address
    function setTreasury(address _treasury) external {
        require(msg.sender == deployer, "not deployer");
        require(_treasury != address(0), "zero address");
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    /// @notice Update the deploy fee — callable by deployer only
    /// @param _fee The new fee in wei
    function setDeployFee(uint256 _fee) external {
        require(msg.sender == deployer, "not deployer");
        require(_fee <= 1 ether, "fee too high (max 1 ETH)");
        emit DeployFeeUpdated(deployFee, _fee);
        deployFee = _fee;
    }

    // --- deployer transfer ---

    /// @notice Propose transferring deployer role to a new address (starts timelock)
    function transferDeployer(address _newDeployer) external {
        require(msg.sender == deployer, "not deployer");
        require(_newDeployer != address(0), "zero address");
        pendingDeployer = _newDeployer;
        deployerTransferTime = block.timestamp + DEPLOYER_TIMELOCK;
        emit DeployerTransferProposed(deployer, _newDeployer);
    }

    /// @notice Confirm deployer transfer after timelock expires
    function confirmDeployerTransfer() external {
        require(msg.sender == pendingDeployer, "not pending deployer");
        require(block.timestamp >= deployerTransferTime, "timelock active");
        emit DeployerTransferred(deployer, pendingDeployer);
        deployer = pendingDeployer;
        delete pendingDeployer;
        delete deployerTransferTime;
    }

    /// @notice Cancel a pending deployer transfer
    function cancelDeployerTransfer() external {
        require(msg.sender == deployer, "not deployer");
        delete pendingDeployer;
        delete deployerTransferTime;
    }

    // --- migration ---

    /// @notice Batch-migrate artists from a previous contract version
    /// @dev Can only be called once by the deployer before migration is finalized
    /// @param wallets Array of artist wallet addresses
    /// @param domains Array of corresponding domain names
    /// @param timestamps Array of original registration timestamps
    function migrateArtists(
        address[] calldata wallets,
        string[] calldata domains,
        uint256[] calldata timestamps
    ) external {
        require(msg.sender == deployer, "not deployer");
        require(!migrated, "already migrated");
        require(wallets.length == domains.length && domains.length == timestamps.length, "length mismatch");

        for (uint256 i = 0; i < wallets.length; i++) {
            require(bytes(artists[wallets[i]].domain).length == 0, "already registered");
            artists[wallets[i]] = Artist(domains[i], timestamps[i]);
            _registeredIndex[wallets[i]] = registeredAddresses.length;
            registeredAddresses.push(wallets[i]);
            emit Registered(wallets[i], domains[i]);
        }

        migrated = true;
    }

    // --- registration ---

    /// @notice Register as an artist with a verified domain
    /// @dev Requires a valid orchestrator signature proving DNS ownership of the domain
    /// @param domain The domain to register (e.g. "milesxb.bio")
    /// @param signature The orchestrator's ECDSA signature over keccak256(abi.encodePacked(wallet, domain))
    function register(string calldata domain, bytes calldata signature) external payable {
        require(bytes(domain).length > 0, "empty domain");
        require(bytes(artists[msg.sender].domain).length == 0, "already registered");
        require(msg.value >= deployFee, "insufficient fee");

        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, domain, nonces[msg.sender], block.chainid, address(this)));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        require(_recover(ethSignedHash, signature) == orchestrator, "invalid signature");
        nonces[msg.sender]++;

        artists[msg.sender] = Artist(domain, block.timestamp);
        _registeredIndex[msg.sender] = registeredAddresses.length;
        registeredAddresses.push(msg.sender);

        // Forward exactly deployFee to treasury, refund overpayment
        if (deployFee > 0) {
            (bool sent, ) = payable(treasury).call{value: deployFee}("");
            require(sent, "fee transfer failed");
        }
        uint256 excess = msg.value - deployFee;
        if (excess > 0) {
            (bool refunded, ) = payable(msg.sender).call{value: excess}("");
            require(refunded, "refund failed");
        }

        emit Registered(msg.sender, domain);
    }

    /// @notice Direct registration by deployer without signature verification
    /// @dev Used for migration and testing purposes only
    /// @param wallet The artist's wallet address
    /// @param domain The domain to register
    function registerDirect(address wallet, string calldata domain) external {
        require(msg.sender == deployer, "not deployer");
        require(bytes(domain).length > 0, "empty domain");
        require(bytes(artists[wallet].domain).length == 0, "already registered");

        artists[wallet] = Artist(domain, block.timestamp);
        _registeredIndex[wallet] = registeredAddresses.length;
        registeredAddresses.push(wallet);
        emit Registered(wallet, domain);
    }

    // --- unregister ---

    /// @notice Unregister from the network, removing your domain
    /// @dev Clears artist data and removes from registeredAddresses (swap-and-pop).
    ///      Follow relationships are NOT cleaned up (lazy deletion).
    ///      isUser() returns false for unregistered wallets, so follow() checks will reject.
    ///      Existing follow data becomes stale but doesn't affect protocol correctness.
    function unregister() external {
        require(bytes(artists[msg.sender].domain).length > 0, "not registered");
        string memory domain = artists[msg.sender].domain;

        // clear artist data
        delete artists[msg.sender];

        // swap-and-pop from registeredAddresses
        uint256 idx = _registeredIndex[msg.sender];
        uint256 lastIdx = registeredAddresses.length - 1;
        if (idx != lastIdx) {
            address last = registeredAddresses[lastIdx];
            registeredAddresses[idx] = last;
            _registeredIndex[last] = idx;
        }
        registeredAddresses.pop();
        delete _registeredIndex[msg.sender];

        // Note: follow relationships are NOT cleaned up (lazy deletion).
        // isUser() returns false for unregistered wallets, so follow() checks will reject.
        // Existing follow data becomes stale but doesn't affect protocol correctness.

        emit Unregistered(msg.sender, domain);
    }

    // --- update domain ---

    /// @notice Update a registered artist's domain name
    /// @dev Requires a valid orchestrator signature for the new domain
    /// @param newDomain The new domain to set
    /// @param signature The orchestrator's ECDSA signature over keccak256(abi.encodePacked(wallet, newDomain))
    function updateDomain(string calldata newDomain, bytes calldata signature) external {
        require(bytes(artists[msg.sender].domain).length > 0, "not registered");
        require(bytes(newDomain).length > 0, "empty domain");

        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, newDomain, nonces[msg.sender], block.chainid, address(this)));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        require(_recover(ethSignedHash, signature) == orchestrator, "invalid signature");
        nonces[msg.sender]++;

        artists[msg.sender].domain = newDomain;

        emit Registered(msg.sender, newDomain);
    }

    // --- transfer registration ---

    /// @notice Transfer registration to a new wallet address, preserving domain, timestamp, and all follow relationships
    /// @dev Requires orchestrator signature over keccak256(abi.encodePacked(oldWallet, newWallet)).
    ///      Moves the Artist struct, updates registeredAddresses, and rewires all follow mappings.
    ///      Gas cost scales with total followers + following count.
    /// @param newWallet The destination wallet address
    /// @param signature The orchestrator's ECDSA signature proving the transfer is authorized
    function transferRegistration(address newWallet, bytes calldata signature) external {
        require(bytes(artists[msg.sender].domain).length > 0, "not registered");
        require(newWallet != address(0), "zero address");
        require(newWallet != msg.sender, "same address");
        require(bytes(artists[newWallet].domain).length == 0, "target already registered");

        // verify orchestrator signed (oldWallet, newWallet, nonce, chainid, contract)
        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, newWallet, nonces[msg.sender], block.chainid, address(this)));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        require(_recover(ethSignedHash, signature) == orchestrator, "invalid signature");
        nonces[msg.sender]++;

        // move artist data
        artists[newWallet] = artists[msg.sender];
        delete artists[msg.sender];

        // update registeredAddresses: swap old address for new (in-place)
        uint256 idx = _registeredIndex[msg.sender];
        registeredAddresses[idx] = newWallet;
        _registeredIndex[newWallet] = idx;
        delete _registeredIndex[msg.sender];

        // transfer outgoing follows (who msg.sender follows)
        address[] storage outgoing = _following[msg.sender];
        for (uint256 i = 0; i < outgoing.length; i++) {
            address target = outgoing[i];
            // update _follows mapping
            _follows[newWallet][target] = true;
            delete _follows[msg.sender][target];
            // update target's _followers array: replace msg.sender with newWallet
            uint256 fIdx = _followersIndex[target][msg.sender];
            _followers[target][fIdx] = newWallet;
            _followersIndex[target][newWallet] = fIdx;
            delete _followersIndex[target][msg.sender];
            // update _followingIndex for new wallet
            _followingIndex[newWallet][target] = i;
            delete _followingIndex[msg.sender][target];
        }
        // move the following array reference
        // Solidity doesn't allow direct storage array assignment between mappings,
        // so we copy element by element and clear
        uint256 outLen = outgoing.length;
        for (uint256 i = 0; i < outLen; i++) {
            _following[newWallet].push(outgoing[i]);
        }
        // clear old following array
        while (_following[msg.sender].length > 0) {
            _following[msg.sender].pop();
        }

        // transfer incoming follows (who follows msg.sender)
        address[] storage incoming = _followers[msg.sender];
        for (uint256 i = 0; i < incoming.length; i++) {
            address follower = incoming[i];
            // update _follows mapping
            _follows[follower][newWallet] = true;
            delete _follows[follower][msg.sender];
            // update follower's _following array: replace msg.sender with newWallet
            uint256 fIdx = _followingIndex[follower][msg.sender];
            _following[follower][fIdx] = newWallet;
            _followingIndex[follower][newWallet] = fIdx;
            delete _followingIndex[follower][msg.sender];
            // update _followersIndex for new wallet
            _followersIndex[newWallet][follower] = i;
            delete _followersIndex[msg.sender][follower];
        }
        // move the followers array
        uint256 inLen = incoming.length;
        for (uint256 i = 0; i < inLen; i++) {
            _followers[newWallet].push(incoming[i]);
        }
        while (_followers[msg.sender].length > 0) {
            _followers[msg.sender].pop();
        }

        emit RegistrationTransferred(msg.sender, newWallet, artists[newWallet].domain);
    }

    /// @notice Recover signer address from an ECDSA signature
    /// @param hash The signed message hash
    /// @param sig The 65-byte signature (r, s, v)
    /// @return The recovered signer address
    function _recover(bytes32 hash, bytes memory sig) internal pure returns (address) {
        require(sig.length == 65, "invalid signature length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        // Reject malleable signatures: s must be in the lower half of the curve
        require(uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0, "invalid s");
        if (v < 27) v += 27;
        require(v == 27 || v == 28, "invalid v");
        address recovered = ecrecover(hash, v, r, s);
        require(recovered != address(0), "invalid signature");
        return recovered;
    }

    /// @notice Check if an address is either a registered artist or supporter
    function _isUser(address wallet) internal view returns (bool) {
        return artists[wallet].registeredAt > 0 || supporters[wallet].registeredAt > 0;
    }

    /// @notice Check if an address is either a registered artist or supporter
    function isUser(address wallet) external view returns (bool) {
        return _isUser(wallet);
    }

    // --- follow ---

    /// @notice Follow another registered artist
    /// @dev Both caller and target must be registered. Cannot follow self or duplicate follow.
    /// @param target The address of the artist to follow
    function follow(address target) external {
        require(_isUser(msg.sender), "not registered");
        require(_isUser(target), "target not registered");
        require(msg.sender != target, "cannot follow self");
        require(!_follows[msg.sender][target], "already following");

        _follows[msg.sender][target] = true;

        _followingIndex[msg.sender][target] = _following[msg.sender].length;
        _following[msg.sender].push(target);

        _followersIndex[target][msg.sender] = _followers[target].length;
        _followers[target].push(msg.sender);

        emit Followed(msg.sender, target);
    }

    /// @notice Unfollow a previously followed artist
    /// @dev Uses swap-and-pop for O(1) removal from both following and followers arrays
    /// @param target The address of the artist to unfollow
    function unfollow(address target) external {
        require(_follows[msg.sender][target], "not following");

        _follows[msg.sender][target] = false;

        // swap-and-pop from _following[msg.sender]
        uint256 idx = _followingIndex[msg.sender][target];
        uint256 lastIdx = _following[msg.sender].length - 1;
        if (idx != lastIdx) {
            address last = _following[msg.sender][lastIdx];
            _following[msg.sender][idx] = last;
            _followingIndex[msg.sender][last] = idx;
        }
        _following[msg.sender].pop();
        delete _followingIndex[msg.sender][target];

        // swap-and-pop from _followers[target]
        idx = _followersIndex[target][msg.sender];
        lastIdx = _followers[target].length - 1;
        if (idx != lastIdx) {
            address last = _followers[target][lastIdx];
            _followers[target][idx] = last;
            _followersIndex[target][last] = idx;
        }
        _followers[target].pop();
        delete _followersIndex[target][msg.sender];

        emit Unfollowed(msg.sender, target);
    }

    // --- supporter registration ---

    /// @notice Register as a supporter with a handle (no domain, no signature needed)
    /// @param handle The chosen handle (3-32 chars, lowercase a-z0-9 and hyphens)
    function registerSupporter(string calldata handle) external {
        require(!_isUser(msg.sender), "already registered");
        _validateHandle(handle);
        require(supporterByHandle[handle] == address(0), "handle taken");

        supporters[msg.sender] = Supporter(handle, block.timestamp);
        supporterByHandle[handle] = msg.sender;
        _supporterIndex[msg.sender] = registeredSupporters.length;
        registeredSupporters.push(msg.sender);

        emit SupporterRegistered(msg.sender, handle, block.timestamp);
    }

    /// @notice Unregister as a supporter, removing handle
    /// @dev Follow relationships are NOT cleaned up (lazy deletion).
    ///      isUser() returns false for unregistered wallets, so follow() checks will reject.
    function unregisterSupporter() external {
        require(supporters[msg.sender].registeredAt > 0, "not a supporter");

        string memory handle = supporters[msg.sender].handle;

        // clear supporter data
        delete supporterByHandle[handle];
        delete supporters[msg.sender];

        // swap-and-pop from registeredSupporters
        uint256 idx = _supporterIndex[msg.sender];
        uint256 lastIdx = registeredSupporters.length - 1;
        if (idx != lastIdx) {
            address last = registeredSupporters[lastIdx];
            registeredSupporters[idx] = last;
            _supporterIndex[last] = idx;
        }
        registeredSupporters.pop();
        delete _supporterIndex[msg.sender];

        // Note: follow relationships are NOT cleaned up (lazy deletion).
        // isUser() returns false for unregistered wallets, so follow() checks will reject.
        // Existing follow data becomes stale but doesn't affect protocol correctness.

        emit SupporterUnregistered(msg.sender, handle);
    }

    /// @notice Check if a handle is available for registration
    function handleAvailable(string calldata handle) external view returns (bool) {
        return supporterByHandle[handle] == address(0);
    }

    /// @notice Validate a supporter handle
    function _validateHandle(string calldata handle) internal pure {
        bytes memory b = bytes(handle);
        require(b.length >= 3 && b.length <= 32, "handle 3-32 chars");
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            require(
                (c >= 0x61 && c <= 0x7a) || // a-z
                (c >= 0x30 && c <= 0x39) || // 0-9
                c == 0x2d,                   // hyphen
                "invalid char"
            );
        }
        require(b[0] != 0x2d && b[b.length - 1] != 0x2d, "no leading/trailing hyphen");
    }

    /// @notice Batch-migrate supporters from off-chain data
    function migrateSupporters(
        address[] calldata wallets,
        string[] calldata handles,
        uint256[] calldata timestamps
    ) external {
        require(msg.sender == deployer, "not deployer");
        require(wallets.length == handles.length && handles.length == timestamps.length, "length mismatch");

        for (uint256 i = 0; i < wallets.length; i++) {
            require(!_isUser(wallets[i]), "already registered");
            require(supporterByHandle[handles[i]] == address(0), "handle taken");
            supporters[wallets[i]] = Supporter(handles[i], timestamps[i]);
            supporterByHandle[handles[i]] = wallets[i];
            _supporterIndex[wallets[i]] = registeredSupporters.length;
            registeredSupporters.push(wallets[i]);
            emit SupporterRegistered(wallets[i], handles[i], timestamps[i]);
        }
    }

    /// @notice Batch-migrate follow relationships
    function migrateFollows(
        address[] calldata followers,
        address[] calldata followeds
    ) external {
        require(msg.sender == deployer, "not deployer");
        require(followers.length == followeds.length, "length mismatch");

        for (uint256 i = 0; i < followers.length; i++) {
            address f = followers[i];
            address t = followeds[i];
            if (_follows[f][t]) continue; // skip if already following

            _follows[f][t] = true;
            _followingIndex[f][t] = _following[f].length;
            _following[f].push(t);
            _followersIndex[t][f] = _followers[t].length;
            _followers[t].push(f);

            emit Followed(f, t);
        }
    }

    // --- views ---

    /// @notice Check if address a is following address b
    /// @param a The potential follower
    /// @param b The potential followed
    /// @return True if a follows b
    function isFollowing(address a, address b) external view returns (bool) {
        return _follows[a][b];
    }

    /// @notice Check if two addresses mutually follow each other
    /// @param a First address
    /// @param b Second address
    /// @return True if both a follows b and b follows a
    function isMutual(address a, address b) external view returns (bool) {
        return _follows[a][b] && _follows[b][a];
    }

    /// @notice Get the list of addresses that an account is following
    /// @param account The account to query
    /// @return Array of followed addresses
    function getFollowing(address account) external view returns (address[] memory) {
        return _following[account];
    }

    /// @notice Get the list of addresses that follow an account
    /// @param account The account to query
    /// @return Array of follower addresses
    function getFollowers(address account) external view returns (address[] memory) {
        return _followers[account];
    }

    /// @notice Get the number of accounts that an address is following
    /// @param account The account to query
    /// @return The following count
    function followingCount(address account) external view returns (uint256) {
        return _following[account].length;
    }

    /// @notice Get the number of followers for an address
    /// @param account The account to query
    /// @return The follower count
    function followerCount(address account) external view returns (uint256) {
        return _followers[account].length;
    }

    /// @notice Get all registered artist addresses and their domains
    /// @return wallets Array of all registered wallet addresses
    /// @return domains Array of corresponding domain names
    function allArtists() external view returns (address[] memory wallets, string[] memory domains) {
        uint256 len = registeredAddresses.length;
        wallets = new address[](len);
        domains = new string[](len);

        for (uint256 i = 0; i < len; i++) {
            wallets[i] = registeredAddresses[i];
            domains[i] = artists[registeredAddresses[i]].domain;
        }
    }

    /// @notice Get the total number of registered artists
    /// @return The count of registered artists
    function totalArtists() external view returns (uint256) {
        return registeredAddresses.length;
    }

    /// @notice Get the total number of registered supporters
    function totalSupporters() external view returns (uint256) {
        return registeredSupporters.length;
    }

    /// @notice Get all registered supporter addresses and their handles
    function allSupporters() external view returns (address[] memory wallets, string[] memory handles) {
        uint256 len = registeredSupporters.length;
        wallets = new address[](len);
        handles = new string[](len);
        for (uint256 i = 0; i < len; i++) {
            wallets[i] = registeredSupporters[i];
            handles[i] = supporters[registeredSupporters[i]].handle;
        }
    }

    // --- Migration functions (deployer-only, one-time use) ---

    /// @notice Whether migration has been permanently locked
    bool public migrationLocked;

    /// @dev Reverts if migration has been locked
    modifier notLocked() {
        require(!migrationLocked, "migration locked");
        _;
    }

    /// @notice Migrate a single artist (deployer only, before lock)
    /// @param wallet The artist's wallet address
    /// @param domain The artist's domain name
    function migrateArtist(address wallet, string calldata domain) external notLocked {
        require(msg.sender == deployer, "not deployer");
        require(bytes(artists[wallet].domain).length == 0, "already registered");

        artists[wallet] = Artist(domain, block.timestamp);
        _registeredIndex[wallet] = registeredAddresses.length;
        registeredAddresses.push(wallet);
        emit Registered(wallet, domain);
    }

    /// @notice Migrate a single supporter (deployer only, before lock)
    /// @param wallet The supporter's wallet address
    /// @param handle The supporter's handle
    function migrateSupporter(address wallet, string calldata handle) external notLocked {
        require(msg.sender == deployer, "not deployer");
        require(!_isUser(wallet), "already registered");
        require(supporterByHandle[handle] == address(0), "handle taken");

        supporters[wallet] = Supporter(handle, block.timestamp);
        supporterByHandle[handle] = wallet;
        _supporterIndex[wallet] = registeredSupporters.length;
        registeredSupporters.push(wallet);
        emit SupporterRegistered(wallet, handle, block.timestamp);
    }

    /// @notice Migrate a single follow relationship (deployer only, before lock)
    /// @param follower The address initiating the follow
    /// @param followed The address being followed
    function migrateFollow(address follower, address followed) external notLocked {
        require(msg.sender == deployer, "not deployer");

        if (!_follows[follower][followed]) {
            _follows[follower][followed] = true;
            _followingIndex[follower][followed] = _following[follower].length;
            _following[follower].push(followed);
            _followersIndex[followed][follower] = _followers[followed].length;
            _followers[followed].push(follower);
            emit Followed(follower, followed);
        }
    }

    /// @notice Permanently lock migration functions
    function lockMigration() external {
        require(msg.sender == deployer, "not deployer");
        migrationLocked = true;
    }
}
