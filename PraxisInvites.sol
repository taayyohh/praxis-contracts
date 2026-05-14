// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces.sol";
import "./Crypto.sol";

//  ____  _  _  _  _  ____  ____  ____  ___
// (_  _)( \( )( \/ )(_  _)(_  _)( ___)/ __)
//  _)(_  )  (  \  /  _)(_   )(   )__) \__ \
// (____)(_)\_)  \/  (____) (__) (____)(___/
//
/// @title PraxisInvites
/// @author @taayyohh
/// @notice On-chain invite system for the Praxis network. Artists earn invites and use
///         hashed codes to onboard new artists. Invite codes are generated client-side;
///         only their keccak256 hashes are stored on-chain.
/// @dev v2 hardening:
///      1. EIP-712 orchestrator-signed `useInvite` to prevent mempool front-running. Pre-v2,
///         a watcher could replace the invitee on a `useInvite(code)` tx and steal the
///         invitee's invite balance + inviter relationship.
///      2. Merkle-root commitment for migration from v1 PraxisInvites — the deployer commits
///         the snapshot root in the constructor, and existing artists pull-claim their
///         invite balances during a 7-day window. After the deadline, claims auto-lock.
///      3. Emergency pause for redemptions if the orchestrator key is compromised.
contract PraxisInvites is EIP712 {
    using ECDSA for bytes32;

    /// @notice Reference to the ArtistRegistry for registration checks
    IArtistRegistry public immutable REGISTRY;

    /// @notice The deployer address, authorized for admin operations
    address public immutable deployer;

    /// @notice The Praxis contract address, authorized to grant invites on project completion
    address public praxisContract;

    /// @notice Number of invites granted to new users upon registration
    uint256 public invitesPerRegistration = 10;

    /// @notice Maximum window between block.timestamp and signature expiry (1 hour)
    uint256 public constant MAX_VALIDITY = 1 hours;

    /// @notice Emergency pause toggle for useInvite (deployer only)
    /// @dev If the orchestrator signing key is compromised, deployer can pause useInvite
    ///      to prevent further front-running while a new key is rotated.
    bool public paused;

    /// @notice Number of remaining invite codes an artist can create
    mapping(address => uint256) public invitesRemaining;

    /// @notice Maps invite code hash to the inviter's address
    mapping(bytes32 => address) public inviteCodeOwner;

    /// @notice Whether an invite code hash has been used
    mapping(bytes32 => bool) public codeUsed;

    /// @notice Maps an invitee address to their inviter
    mapping(address => address) public invitedBy;

    /// @notice Per-orchestrator-signature nonces (defense in depth against replay)
    mapping(bytes32 => bool) public usedNonces;

    /// @notice Merkle root of (artist, invitesRemaining) snapshot from v1 PraxisInvites
    /// @dev Committed in the constructor; deployer cannot mutate after deploy
    bytes32 public immutable migrationRoot;

    /// @notice Timestamp after which migration claims auto-lock
    uint256 public immutable migrationDeadline;

    /// @notice Tracks which artist addresses have already claimed their migration balance
    mapping(address => bool) public migrationClaimed;

    /// @notice Tracks which artist addresses have already claimed their one-time
    ///         "initial" invite grant (10 invites for any registered artist).
    /// @dev Pre-v2 the only way to receive invites was via `useInvite`. Artists who
    ///      registered through any other path (registerDirect, payable register, etc.)
    ///      ended up with zero invites permanently. v2 lets them self-claim once.
    mapping(address => bool) public initialClaimed;

    /// @dev EIP-712 typehash for the UseInvite struct
    bytes32 private constant USE_INVITE_TYPEHASH =
        keccak256("UseInvite(bytes32 codeHash,address invitee,uint256 expiry,bytes32 nonce)");

    /// @notice Emitted when an artist creates an invite code
    /// @param inviter The artist who created the invite
    /// @param codeHash The keccak256 hash of the invite code
    event InviteCreated(address indexed inviter, bytes32 indexed codeHash);

    /// @notice Emitted when a new artist uses an invite code
    /// @param invitee The new artist who used the invite
    /// @param inviter The artist who created the invite
    /// @param codeHash The keccak256 hash of the used code
    event InviteUsed(address indexed invitee, address indexed inviter, bytes32 indexed codeHash);

    /// @notice Emitted when invites are granted to an artist
    /// @param artist The artist receiving invites
    /// @param count The number of invites granted
    event InvitesGranted(address indexed artist, uint256 count);

    /// @notice Emitted when an artist claims their migrated invite balance
    event MigrationClaimed(address indexed artist, uint256 amount);

    /// @notice Emitted when an artist claims their one-time initial invite grant
    event InitialInvitesClaimed(address indexed artist, uint256 amount);

    /// @notice Emitted when the pause state changes
    event PausedSet(bool paused);

    /// @notice Deploy the PraxisInvites contract
    /// @param registry Address of the ArtistRegistry contract
    /// @param _migrationRoot Merkle root of (address,uint256) leaves for v1 invite balances.
    ///        Pass bytes32(0) to disable migration entirely (fresh deploy with no v1 state).
    constructor(address registry, bytes32 _migrationRoot) EIP712("PraxisInvites", "1") {
        REGISTRY = IArtistRegistry(registry);
        deployer = msg.sender;
        migrationRoot = _migrationRoot;
        migrationDeadline = block.timestamp + 7 days;
    }

    /// @notice Set the Praxis contract address (one-time only, deployer only)
    /// @dev Once set, the Praxis contract can call grantInvites on project completion
    /// @param praxis The Praxis contract address
    function setPraxisContract(address praxis) external {
        require(msg.sender == deployer, "not deployer");
        require(praxisContract == address(0), "already set");
        praxisContract = praxis;
    }

    /// @notice Update the number of invites granted per registration (deployer only)
    /// @param _count New invite count (1-100)
    function setInvitesPerRegistration(uint256 _count) external {
        require(msg.sender == deployer, "not deployer");
        require(_count > 0 && _count <= 100, "1-100");
        invitesPerRegistration = _count;
    }

    /// @notice Pause/unpause useInvite redemptions in case the orchestrator key is compromised
    /// @dev Only blocks new useInvite calls; createInvite/grantInvites/claimMigration still work
    function setPaused(bool _paused) external {
        require(msg.sender == deployer, "not deployer");
        paused = _paused;
        emit PausedSet(_paused);
    }

    /// @notice Grant invites to an artist (deployer or Praxis contract only)
    /// @param artist The artist to receive invites
    /// @param count The number of invites to grant
    function grantInvites(address artist, uint256 count) external {
        require(msg.sender == deployer || msg.sender == praxisContract, "not authorized");
        invitesRemaining[artist] += count;
        emit InvitesGranted(artist, count);
    }

    /// @notice Claim a migrated invite balance from v1 PraxisInvites
    /// @dev Trustless restoration of v1 state. Anyone can submit a proof on behalf of any
    ///      artist (the balance lands in the artist's mapping, not the caller's). After
    ///      `migrationDeadline`, the claim window closes permanently.
    /// @param artist The artist whose v1 balance is being restored
    /// @param amount The exact `invitesRemaining[artist]` value from the v1 snapshot
    /// @param proof Merkle proof against `migrationRoot`
    function claimMigration(address artist, uint256 amount, bytes32[] calldata proof) external {
        require(block.timestamp <= migrationDeadline, "claim window closed");
        require(migrationRoot != bytes32(0), "no migration");
        require(!migrationClaimed[artist], "already claimed");

        // Leaf is keccak256(abi.encode(artist, amount)) — abi.encode prevents collision
        // attacks possible with abi.encodePacked when concatenating dynamic types.
        bytes32 leaf = keccak256(abi.encode(artist, amount));
        require(MerkleProof.verify(proof, migrationRoot, leaf), "bad proof");

        migrationClaimed[artist] = true;
        invitesRemaining[artist] += amount;

        emit MigrationClaimed(artist, amount);
        emit InvitesGranted(artist, amount);
    }

    /// @notice One-time self-claim of `invitesPerRegistration` invites for any
    ///         registered artist. Replaces the missing auto-grant on registration —
    ///         pre-v2 only `useInvite` recipients received invites, so artists who
    ///         registered through any other path got nothing.
    /// @dev Trustless: anyone can call for themselves, gated by registry membership.
    ///      Each address can claim exactly once. Frontend calls this immediately
    ///      after a successful `register()` so it's invisible to the user.
    function claimInitialInvites() external {
        (, uint256 registeredAt) = REGISTRY.artists(msg.sender);
        require(registeredAt > 0, "not registered");
        require(!initialClaimed[msg.sender], "already claimed");

        initialClaimed[msg.sender] = true;
        uint256 amount = invitesPerRegistration;
        invitesRemaining[msg.sender] += amount;

        emit InitialInvitesClaimed(msg.sender, amount);
        emit InvitesGranted(msg.sender, amount);
    }

    /// @notice Create an invite code by storing its hash on-chain
    /// @dev The actual code is generated client-side. Only the keccak256 hash is stored.
    ///      Caller must be a registered artist with remaining invites.
    /// @param codeHash The keccak256 hash of the invite code
    function createInvite(bytes32 codeHash) external {
        (, uint256 registeredAt) = REGISTRY.artists(msg.sender);
        require(registeredAt > 0, "not registered");
        require(invitesRemaining[msg.sender] > 0, "no invites");
        require(inviteCodeOwner[codeHash] == address(0), "code exists");

        inviteCodeOwner[codeHash] = msg.sender;
        invitesRemaining[msg.sender]--;

        emit InviteCreated(msg.sender, codeHash);
    }

    /// @notice Use an invite code to join the network with orchestrator-signed authorization
    /// @dev Front-running protection: the orchestrator signs (codeHash, msg.sender, expiry, nonce).
    ///      A mempool watcher cannot replace the invitee because the signature binds msg.sender.
    ///      The orchestrator key MUST be kept secret; if compromised, deployer should call setPaused(true).
    /// @param code The plaintext invite code
    /// @param expiry Unix timestamp after which the signature is invalid (max 1h from now)
    /// @param nonce Random 32-byte nonce (each signature must use a fresh nonce)
    /// @param orchSig 65-byte EIP-712 signature from REGISTRY.orchestrator()
    function useInvite(string calldata code, uint256 expiry, bytes32 nonce, bytes calldata orchSig) external {
        require(!paused, "paused");
        require(block.timestamp < expiry, "expired");
        require(expiry - block.timestamp <= MAX_VALIDITY, "expiry too far");
        require(!usedNonces[nonce], "nonce used");

        bytes32 codeHash = keccak256(abi.encodePacked(code));
        address inviter = inviteCodeOwner[codeHash];
        require(inviter != address(0), "invalid code");
        require(!codeUsed[codeHash], "code used");

        // Verify EIP-712 signature from orchestrator
        // Binds (codeHash, msg.sender, expiry, nonce) — invitee front-running impossible
        bytes32 structHash = keccak256(abi.encode(USE_INVITE_TYPEHASH, codeHash, msg.sender, expiry, nonce));
        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = digest.recover(orchSig);
        require(recovered == REGISTRY.orchestrator(), "invalid orch sig");

        codeUsed[codeHash] = true;
        usedNonces[nonce] = true;
        invitedBy[msg.sender] = inviter;
        invitesRemaining[msg.sender] = invitesPerRegistration;

        emit InviteUsed(msg.sender, inviter, codeHash);
    }

    /// @notice Batch-create multiple invite codes in a single transaction
    /// @dev Caller must be a registered artist with enough remaining invites.
    /// @param codeHashes Array of keccak256 hashes of invite codes
    function createInvites(bytes32[] calldata codeHashes) external {
        (, uint256 registeredAt) = REGISTRY.artists(msg.sender);
        require(registeredAt > 0, "not registered");
        require(invitesRemaining[msg.sender] >= codeHashes.length, "not enough invites");

        for (uint256 i = 0; i < codeHashes.length; i++) {
            require(inviteCodeOwner[codeHashes[i]] == address(0), "code exists");
            inviteCodeOwner[codeHashes[i]] = msg.sender;
            emit InviteCreated(msg.sender, codeHashes[i]);
        }

        invitesRemaining[msg.sender] -= codeHashes.length;
    }

    /// @notice Get the EIP-712 domain separator (for off-chain signers)
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
