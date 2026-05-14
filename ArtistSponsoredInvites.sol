// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces.sol";
import "./Crypto.sol";

//  ___  ____   __   _  _  ___   __   ____  ____  ____
// / __)(  _ \ /  \ ( \( )/ __) /  \ (  _ \( ___)(_  _)
// \__ \ )___/( () ) )  ( \__ \( () ) )   / )__)  _)(_
// (___/(__)   \__/ (_)\_)(___/ \__/ (_)\_)(____)(____)
//
/// @title ArtistSponsoredInvites
/// @author @taayyohh
/// @notice Trustless escrow for artist-sponsored invites. Artists deposit ETH to cover
///         the deploy fee for people they invite. Funds are held by the contract and
///         released when the invite is redeemed via an orchestrator-signed claim.
/// @dev v2 — adds EIP-712 orchestrator-signed redemption to prevent mempool front-running.
///      Pre-v2, anyone watching the mempool could replace the recipient on a `redeem(code)`
///      tx with their own address and steal the deposit. Now redemptions require an
///      EIP-712 signature from REGISTRY.orchestrator() binding (codeHash, recipient, expiry, nonce).
/// @dev v3 — adds optional per-slot domain budget. Sponsors can attach extra ETH at deposit
///      time so the recipient can also cover a domain registration fee. Capped per-slot by a
///      deployer-set `maxDomainBudget` so sponsors can't be tricked into overspending. The
///      domain budget is paid out alongside the deploy fee on `redeem()` — the recipient then
///      pays the orchestrator for the actual NameSilo domain via the normal registration flow.
contract ArtistSponsoredInvites is EIP712 {
    using ECDSA for bytes32;

    IArtistRegistry public immutable REGISTRY;

    /// @notice Maximum window between block.timestamp and signature expiry (1 hour)
    /// @dev Prevents the orchestrator from accidentally signing forever-valid redemptions
    uint256 public constant MAX_VALIDITY = 1 hours;

    /// @notice Gas buffer sent alongside deploy fee so recipient can transact
    /// On Scroll L2 gas is cheap, 0.001 ETH is more than enough for multiple txs
    uint256 public gasBuffer = 0.001 ether;

    /// @notice Maximum per-slot domain budget a sponsor may attach (deployer-settable)
    /// @dev Denominated in wei. Frontend converts a USD cap (e.g. $10) to wei using the
    ///      current ETH price. Defaults to ~$10 at deploy-time prices (4000 USD/ETH ⇒ 0.0025 ETH).
    ///      Set to 0 to disable domain sponsorship entirely. Capped at 0.05 ETH as a hard
    ///      sanity ceiling so a misbehaving deployer can't push it sky-high.
    uint256 public maxDomainBudget = 0.0025 ether;

    /// @notice Emergency pause toggle for redemptions (deployer only)
    /// @dev If the orchestrator signing key is compromised, deployer can pause redemptions
    ///      to prevent further drainage while a new signing key is rotated.
    bool public paused;

    /// @notice Unassigned sponsored slots per artist (deposited but not yet linked to a code)
    mapping(address => uint256) public availableSlots;

    /// @notice Maps invite code hash to the sponsoring artist
    mapping(bytes32 => address) public sponsorOf;

    /// @notice Whether a sponsored invite has been redeemed
    mapping(bytes32 => bool) public redeemed;

    /// @notice Price per slot at deposit time (protects against fee changes)
    mapping(address => uint256) public depositedSponsorAmount;

    /// @notice Exact deposit amount recorded per sponsored code hash
    mapping(bytes32 => uint256) public codeDepositAmount;

    /// @notice Per-orchestrator-signature nonces (defense in depth against replay)
    mapping(bytes32 => bool) public usedNonces;

    /// @dev EIP-712 typehash for the Redeem struct
    bytes32 private constant REDEEM_TYPEHASH =
        keccak256("Redeem(bytes32 codeHash,address recipient,uint256 expiry,bytes32 nonce)");

    /// @notice Emitted when an artist deposits ETH to sponsor future invites
    event Deposited(address indexed artist, uint256 count, uint256 totalValue);

    /// @notice Emitted when a sponsored invite code is linked to a deposit slot
    event SponsoredInviteCreated(address indexed artist, bytes32 indexed codeHash);

    /// @notice Emitted when a sponsored invite is redeemed by a recipient
    event SponsorshipRedeemed(bytes32 indexed codeHash, address indexed sponsor, address indexed recipient, uint256 amount);

    /// @notice Emitted when unassigned slots are refunded to the sponsor
    event SlotRefunded(address indexed artist, uint256 count, uint256 totalValue);

    /// @notice Emitted when a sponsor revokes an unredeemed invite and reclaims the deposit
    event InviteRevoked(address indexed artist, bytes32 indexed codeHash);

    /// @notice Emitted when the pause state changes
    event PausedSet(bool paused);

    /// @notice Emitted when the maximum domain budget per slot is updated
    event MaxDomainBudgetSet(uint256 newMax);

    /// @notice Deploy the ArtistSponsoredInvites contract
    /// @param registry Address of the ArtistRegistry contract
    constructor(address registry) EIP712("PraxisSponsoredInvites", "1") {
        REGISTRY = IArtistRegistry(registry);
    }

    /// @notice Compute the current sponsor amount (deploy fee + gas buffer)
    function sponsorAmount() public view returns (uint256) {
        return REGISTRY.deployFee() + gasBuffer;
    }

    /// @notice Update the gas buffer (deployer only)
    function setGasBuffer(uint256 _buffer) external {
        require(msg.sender == REGISTRY.deployer(), "not authorized");
        require(_buffer > 0 && _buffer <= 0.01 ether, "out of range");
        gasBuffer = _buffer;
    }

    /// @notice Pause/unpause redemptions in case the orchestrator signing key is compromised
    /// @dev Only blocks new redemptions; deposits, refunds, and revokes still work
    function setPaused(bool _paused) external {
        require(msg.sender == REGISTRY.deployer(), "not authorized");
        paused = _paused;
        emit PausedSet(_paused);
    }

    /// @notice Update the per-slot domain budget cap (deployer only)
    /// @dev Hard ceiling of 0.05 ETH (~$200) so a compromised deployer key can't push it
    ///      arbitrarily high. Set to 0 to disable domain sponsorship entirely (deposits with
    ///      a non-zero domainBudgetPerSlot will revert).
    function setMaxDomainBudget(uint256 _max) external {
        require(msg.sender == REGISTRY.deployer(), "not authorized");
        require(_max <= 0.05 ether, "out of range");
        maxDomainBudget = _max;
        emit MaxDomainBudgetSet(_max);
    }

    /// @notice Deposit ETH to sponsor future invites with optional domain budget
    /// @param count Number of invites to sponsor
    /// @param domainBudgetPerSlot Extra ETH per slot the recipient can use to register a domain.
    ///        Pass 0 for deploy-fee-only sponsorship. Capped by `maxDomainBudget`.
    function deposit(uint256 count, uint256 domainBudgetPerSlot) external payable {
        require(count > 0, "count must be > 0");
        require(domainBudgetPerSlot <= maxDomainBudget, "domain budget too high");
        uint256 _perSlot = sponsorAmount() + domainBudgetPerSlot;
        require(msg.value == count * _perSlot, "wrong value");
        (, uint256 registeredAt) = REGISTRY.artists(msg.sender);
        require(registeredAt > 0, "not registered artist");

        // Track total deposited ETH for accurate refunds (handles multi-price deposits).
        // depositedSponsorAmount stores the FULL per-slot value (deployFee + gasBuffer +
        // domainBudgetPerSlot), so refunds, revokes, and redeems all reuse the same
        // weighted-average bookkeeping that already existed in v2.
        uint256 oldSlots = availableSlots[msg.sender];
        uint256 oldTotal = oldSlots * depositedSponsorAmount[msg.sender];
        availableSlots[msg.sender] += count;
        // Weighted average price: (oldTotal + newDeposit) / totalSlots
        depositedSponsorAmount[msg.sender] = (oldTotal + msg.value) / (oldSlots + count);
        emit Deposited(msg.sender, count, msg.value);
    }


    /// @notice Link a code hash to a sponsored slot
    /// @dev Call after generating the code client-side. Uses one available slot.
    /// @param codeHash The keccak256 hash of the invite code
    function sponsorInvite(bytes32 codeHash) external {
        require(codeHash != bytes32(0), "zero hash");
        require(availableSlots[msg.sender] > 0, "no slots");
        require(sponsorOf[codeHash] == address(0), "already sponsored");

        availableSlots[msg.sender]--;
        sponsorOf[codeHash] = msg.sender;
        codeDepositAmount[codeHash] = depositedSponsorAmount[msg.sender];
        emit SponsoredInviteCreated(msg.sender, codeHash);
    }

    /// @notice Batch-link multiple code hashes to sponsored slots
    /// @param codeHashes Array of keccak256 hashes
    function sponsorInvites(bytes32[] calldata codeHashes) external {
        // Bounded batch — without this cap a malicious artist could submit a
        // 10,000-element array and burn block gas. 100 invites is plenty for
        // any reasonable use case.
        require(codeHashes.length > 0 && codeHashes.length <= 100, "batch out of range");
        require(availableSlots[msg.sender] >= codeHashes.length, "not enough slots");
        uint256 _depositPrice = depositedSponsorAmount[msg.sender];
        for (uint256 i = 0; i < codeHashes.length; i++) {
            require(codeHashes[i] != bytes32(0), "zero hash");
            require(sponsorOf[codeHashes[i]] == address(0), "already sponsored");
            sponsorOf[codeHashes[i]] = msg.sender;
            codeDepositAmount[codeHashes[i]] = _depositPrice;
            emit SponsoredInviteCreated(msg.sender, codeHashes[i]);
        }
        availableSlots[msg.sender] -= codeHashes.length;
    }

    /// @notice Redeem a sponsored invite using an orchestrator-signed authorization
    /// @dev Front-running protection: the orchestrator signs (codeHash, msg.sender, expiry, nonce).
    ///      A mempool watcher cannot replace the recipient because the signature binds msg.sender.
    ///      The orchestrator key MUST be kept secret; if compromised, deployer should call setPaused(true).
    /// @param code The plaintext invite code
    /// @param expiry Unix timestamp after which the signature is invalid (max 1h from now)
    /// @param nonce Random 32-byte nonce (each signature must use a fresh nonce)
    /// @param orchSig 65-byte EIP-712 signature from REGISTRY.orchestrator()
    function redeem(string calldata code, uint256 expiry, bytes32 nonce, bytes calldata orchSig) external {
        require(!paused, "paused");
        require(block.timestamp < expiry, "expired");
        require(expiry - block.timestamp <= MAX_VALIDITY, "expiry too far");
        require(!usedNonces[nonce], "nonce used");

        bytes32 codeHash = keccak256(abi.encodePacked(code));
        address sponsor = sponsorOf[codeHash];
        require(sponsor != address(0), "not sponsored");
        require(!redeemed[codeHash], "already redeemed");

        // Verify EIP-712 signature from orchestrator
        // Binds (codeHash, msg.sender, expiry, nonce) — recipient front-running impossible
        bytes32 structHash = keccak256(abi.encode(REDEEM_TYPEHASH, codeHash, msg.sender, expiry, nonce));
        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = digest.recover(orchSig);
        require(recovered == REGISTRY.orchestrator(), "invalid orch sig");

        // Use per-code deposit price (not weighted average) to prevent insolvency if fee changes
        uint256 _depositPrice = codeDepositAmount[codeHash];
        require(_depositPrice > 0, "no deposit");

        // Effects before interactions (CEI)
        redeemed[codeHash] = true;
        usedNonces[nonce] = true;

        // No gas cap — CEI pattern prevents reentrancy. Smart wallets need >10k gas to receive.
        (bool ok, ) = payable(msg.sender).call{value: _depositPrice}("");
        require(ok, "transfer failed");

        emit SponsorshipRedeemed(codeHash, sponsor, msg.sender, _depositPrice);
    }

    /// @notice Refund unassigned slots (not yet linked to any code)
    /// @param count Number of slots to refund
    function refundSlots(uint256 count) external {
        require(count > 0 && count <= availableSlots[msg.sender], "invalid count");

        // Use deposited price (not current) to prevent fee-change rug
        uint256 _depositPrice = depositedSponsorAmount[msg.sender];
        require(_depositPrice > 0, "no deposit");
        uint256 amount = count * _depositPrice;

        // Effects before interactions
        availableSlots[msg.sender] -= count;

        // No gas cap — CEI pattern prevents reentrancy
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "transfer failed");

        emit SlotRefunded(msg.sender, count, amount);
    }

    /// @notice Revoke a specific unredeemed sponsored invite and reclaim deposit
    /// @param codeHash The code hash to revoke
    function revokeInvite(bytes32 codeHash) external {
        require(sponsorOf[codeHash] == msg.sender, "not your invite");
        require(!redeemed[codeHash], "already redeemed");

        // Use per-code deposit price (not weighted average) to prevent fee-change rug
        uint256 _depositPrice = codeDepositAmount[codeHash];
        require(_depositPrice > 0, "no deposit");

        // Effects before interactions
        sponsorOf[codeHash] = address(0);
        codeDepositAmount[codeHash] = 0;

        // No gas cap — CEI pattern prevents reentrancy
        (bool ok, ) = payable(msg.sender).call{value: _depositPrice}("");
        require(ok, "transfer failed");

        emit InviteRevoked(msg.sender, codeHash);
    }

    /// @notice Check if a code hash has an active (unredeemed) sponsorship
    /// @param codeHash The code hash to check
    /// @return sponsor The sponsoring artist address (zero if not sponsored or already redeemed)
    function activeSponsor(bytes32 codeHash) external view returns (address sponsor) {
        if (redeemed[codeHash]) return address(0);
        return sponsorOf[codeHash];
    }

    /// @notice Get the EIP-712 domain separator (for off-chain signers)
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
