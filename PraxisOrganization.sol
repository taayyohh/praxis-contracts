// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces.sol";

/// @title PraxisOrganization
/// @author @taayyohh
/// @notice On-chain registry for organizations (labels, publishers, theatres, film companies)
///         within the Praxis network. Supports bidirectional consent membership, metadata,
///         custom domains, and admin transfer.
/// @dev Bidirectional consent: admin invites, artist accepts. Neither party can force membership.
///      Uses swap-and-pop for O(1) member removal. All string fields are length-bounded to
///      prevent gas griefing.
contract PraxisOrganization {

    /// @notice Reference to the ArtistRegistry for registration checks
    IArtistRegistry public immutable REGISTRY;

    /// @notice Represents an organization on the Praxis network
    /// @param name Display name of the organization (max 256 bytes)
    /// @param domain Optional custom domain for the organization (max 253 bytes)
    /// @param metadataCid IPFS CID pointing to extended metadata JSON (max 128 bytes)
    /// @param admin The admin address who controls the organization
    /// @param createdAt Block timestamp of creation
    /// @param dissolved Whether the organization has been permanently dissolved
    struct Org {
        string name;
        string domain;
        string metadataCid;
        address admin;
        uint256 createdAt;
        bool dissolved;
    }

    /// @notice Total number of organizations created
    uint256 public orgCount;

    /// @notice Mapping of org ID to organization data
    mapping(uint256 => Org) public orgs;

    /// @dev Active members array per org (both parties consented)
    mapping(uint256 => address[]) internal _members;

    /// @notice Whether an address is an active member of an org
    mapping(uint256 => mapping(address => bool)) public isMember;

    /// @dev Index of a member in _members[orgId] for O(1) swap-and-pop removal
    mapping(uint256 => mapping(address => uint256)) internal _memberIndex;

    /// @dev Orgs that a member belongs to (reverse index)
    mapping(address => uint256[]) internal _orgsByMember;

    /// @dev Index of an orgId in _orgsByMember[wallet] for O(1) removal
    mapping(address => mapping(uint256 => uint256)) internal _orgsByMemberIndex;

    /// @notice Whether an address has a pending invite to an org
    mapping(uint256 => mapping(address => bool)) public isInvited;

    // --- Events ---

    /// @notice Emitted when a new organization is created
    event OrgCreated(uint256 indexed orgId, address indexed admin, string name, string metadataCid);

    /// @notice Emitted when an admin invites a user to the organization
    event MemberInvited(uint256 indexed orgId, address indexed wallet);

    /// @notice Emitted when an invited user accepts and joins the organization
    event InviteAccepted(uint256 indexed orgId, address indexed wallet);

    /// @notice Emitted when an invited user declines the invitation
    event InviteDeclined(uint256 indexed orgId, address indexed wallet);

    /// @notice Emitted when an admin revokes a pending invitation
    event InviteRevoked(uint256 indexed orgId, address indexed wallet);

    /// @notice Emitted when an admin removes a member from the organization
    event MemberRemoved(uint256 indexed orgId, address indexed wallet);

    /// @notice Emitted when a member voluntarily leaves the organization
    event MemberLeft(uint256 indexed orgId, address indexed wallet);

    /// @notice Emitted when an organization's metadata CID is updated
    event MetadataUpdated(uint256 indexed orgId, string oldCid, string newCid);

    /// @notice Emitted when admin role is transferred to another member
    event AdminTransferred(uint256 indexed orgId, address indexed oldAdmin, address indexed newAdmin);

    /// @notice Emitted when an organization's domain is updated
    event DomainUpdated(uint256 indexed orgId, string domain);

    /// @notice Emitted when an organization is permanently dissolved
    event OrgDissolved(uint256 indexed orgId);

    // --- Errors ---

    /// @notice Caller is not the organization admin
    error NotAdmin();
    /// @notice Caller is not a registered Praxis user
    error NotUser();
    /// @notice Organization has been dissolved
    error OrgNotActive();
    /// @notice Target address is already a member
    error AlreadyMember();
    /// @notice Target address already has a pending invite
    error AlreadyInvited();
    /// @notice Target address is not a member
    error NotMember();
    /// @notice Target address does not have a pending invite
    error NotInvited();
    /// @notice Organization name cannot be empty
    error EmptyName();
    /// @notice Organization ID is invalid
    error InvalidOrg();
    /// @notice Cannot remove the admin from the organization
    error CannotRemoveAdmin();
    /// @notice Organization name exceeds 256 bytes
    error NameTooLong();
    /// @notice Metadata CID exceeds 128 bytes
    error CidTooLong();
    /// @notice Domain exceeds 253 bytes (DNS maximum)
    error DomainTooLong();

    /// @notice Deploy the PraxisOrganization contract
    /// @param registry Address of the ArtistRegistry contract
    constructor(address registry) {
        REGISTRY = IArtistRegistry(registry);
    }

    /// @dev Restricts function access to the organization's admin and checks active status
    modifier onlyAdmin(uint256 orgId) {
        if (orgs[orgId].admin != msg.sender) revert NotAdmin();
        if (orgs[orgId].dissolved) revert OrgNotActive();
        _;
    }

    // === Org Lifecycle ===

    /// @notice Create a new organization
    /// @dev Creator becomes the admin and is automatically added as the first member.
    /// @param name Display name (1-256 bytes)
    /// @param metadataCid IPFS CID for extended metadata (max 128 bytes, can be empty)
    /// @return The new organization ID
    function createOrg(string calldata name, string calldata metadataCid) external returns (uint256) {
        if (!REGISTRY.isUser(msg.sender)) revert NotUser();
        if (bytes(name).length == 0) revert EmptyName();
        if (bytes(name).length > 256) revert NameTooLong();
        if (bytes(metadataCid).length > 128) revert CidTooLong();

        uint256 orgId = orgCount++;
        orgs[orgId] = Org(name, "", metadataCid, msg.sender, block.timestamp, false);
        _addMember(orgId, msg.sender);

        emit OrgCreated(orgId, msg.sender, name, metadataCid);
        return orgId;
    }

    /// @notice Permanently dissolve an organization (admin only)
    /// @dev Dissolved organizations cannot be reactivated. Members remain in storage
    ///      but no new invites or joins are possible.
    /// @param orgId The organization to dissolve
    function dissolveOrg(uint256 orgId) external onlyAdmin(orgId) {
        orgs[orgId].dissolved = true;
        emit OrgDissolved(orgId);
    }

    // === Bidirectional Consent Membership ===

    /// @notice Admin invites a registered user. Does NOT add them -- they must accept.
    /// @param orgId The organization ID
    /// @param wallet The user's wallet address to invite
    function inviteMember(uint256 orgId, address wallet) external onlyAdmin(orgId) {
        if (!REGISTRY.isUser(wallet)) revert NotUser();
        if (isMember[orgId][wallet]) revert AlreadyMember();
        if (isInvited[orgId][wallet]) revert AlreadyInvited();
        isInvited[orgId][wallet] = true;
        emit MemberInvited(orgId, wallet);
    }

    /// @notice Admin revokes a pending invite before the user accepts
    /// @param orgId The organization ID
    /// @param wallet The invited user's wallet address
    function revokeInvite(uint256 orgId, address wallet) external onlyAdmin(orgId) {
        if (!isInvited[orgId][wallet]) revert NotInvited();
        isInvited[orgId][wallet] = false;
        emit InviteRevoked(orgId, wallet);
    }

    /// @notice Accept a pending invite and join the organization
    /// @param orgId The organization ID to join
    function acceptInvite(uint256 orgId) external {
        if (!isInvited[orgId][msg.sender]) revert NotInvited();
        if (orgs[orgId].dissolved) revert OrgNotActive();
        isInvited[orgId][msg.sender] = false;
        _addMember(orgId, msg.sender);
        emit InviteAccepted(orgId, msg.sender);
    }

    /// @notice Decline a pending invite without joining
    /// @param orgId The organization ID
    function declineInvite(uint256 orgId) external {
        if (!isInvited[orgId][msg.sender]) revert NotInvited();
        isInvited[orgId][msg.sender] = false;
        emit InviteDeclined(orgId, msg.sender);
    }

    /// @notice Voluntarily leave an organization. Admin cannot leave (must transfer first).
    /// @param orgId The organization ID to leave
    function leaveOrg(uint256 orgId) external {
        if (!isMember[orgId][msg.sender]) revert NotMember();
        if (msg.sender == orgs[orgId].admin) revert CannotRemoveAdmin();
        _removeMember(orgId, msg.sender);
        emit MemberLeft(orgId, msg.sender);
    }

    /// @notice Admin removes a member from the organization. Cannot remove self (admin).
    /// @param orgId The organization ID
    /// @param wallet The member's wallet address to remove
    function removeMember(uint256 orgId, address wallet) external onlyAdmin(orgId) {
        if (!isMember[orgId][wallet]) revert NotMember();
        if (wallet == orgs[orgId].admin) revert CannotRemoveAdmin();
        _removeMember(orgId, wallet);
        emit MemberRemoved(orgId, wallet);
    }

    // === Metadata + Admin ===

    /// @notice Update the organization's metadata CID (admin only)
    /// @param orgId The organization ID
    /// @param newCid New IPFS CID for metadata (max 128 bytes)
    function updateMetadata(uint256 orgId, string calldata newCid) external onlyAdmin(orgId) {
        if (bytes(newCid).length > 128) revert CidTooLong();
        string memory oldCid = orgs[orgId].metadataCid;
        orgs[orgId].metadataCid = newCid;
        emit MetadataUpdated(orgId, oldCid, newCid);
    }

    /// @notice Update the organization's custom domain (admin only)
    /// @param orgId The organization ID
    /// @param domain The new domain string (max 253 bytes per DNS spec)
    function updateDomain(uint256 orgId, string calldata domain) external onlyAdmin(orgId) {
        if (bytes(domain).length > 253) revert DomainTooLong();
        orgs[orgId].domain = domain;
        emit DomainUpdated(orgId, domain);
    }

    /// @notice Transfer admin role to another existing member (admin only)
    /// @dev The new admin must already be a member. This is irreversible without the
    ///      new admin's cooperation (they must transfer back).
    /// @param orgId The organization ID
    /// @param newAdmin The member to promote to admin
    function transferAdmin(uint256 orgId, address newAdmin) external onlyAdmin(orgId) {
        if (!isMember[orgId][newAdmin]) revert NotMember();
        address oldAdmin = orgs[orgId].admin;
        orgs[orgId].admin = newAdmin;
        emit AdminTransferred(orgId, oldAdmin, newAdmin);
    }

    // === View Functions ===

    /// @notice Get all active members of an organization
    /// @param orgId The organization ID
    /// @return Array of member wallet addresses
    function getMembers(uint256 orgId) external view returns (address[] memory) {
        return _members[orgId];
    }

    /// @notice Get the number of active members in an organization
    /// @param orgId The organization ID
    /// @return The member count
    function memberCount(uint256 orgId) external view returns (uint256) {
        return _members[orgId].length;
    }

    /// @notice Get all organization IDs that a wallet is a member of
    /// @param wallet The member's wallet address
    /// @return Array of organization IDs
    function getOrgsByMember(address wallet) external view returns (uint256[] memory) {
        return _orgsByMember[wallet];
    }

    // === Internal ===

    /// @dev Add a member to the organization and update both forward and reverse indices
    function _addMember(uint256 orgId, address wallet) internal {
        isMember[orgId][wallet] = true;
        _memberIndex[orgId][wallet] = _members[orgId].length;
        _members[orgId].push(wallet);
        _orgsByMemberIndex[wallet][orgId] = _orgsByMember[wallet].length;
        _orgsByMember[wallet].push(orgId);
    }

    /// @dev Remove a member using swap-and-pop for O(1) removal from both indices
    function _removeMember(uint256 orgId, address wallet) internal {
        uint256 idx = _memberIndex[orgId][wallet];
        uint256 lastIdx = _members[orgId].length - 1;
        if (idx != lastIdx) {
            address last = _members[orgId][lastIdx];
            _members[orgId][idx] = last;
            _memberIndex[orgId][last] = idx;
        }
        _members[orgId].pop();
        delete _memberIndex[orgId][wallet];
        isMember[orgId][wallet] = false;

        uint256[] storage memberOrgs = _orgsByMember[wallet];
        uint256 orgIdx = _orgsByMemberIndex[wallet][orgId];
        uint256 lastOrgIdx = memberOrgs.length - 1;
        if (orgIdx != lastOrgIdx) {
            uint256 lastOrgId = memberOrgs[lastOrgIdx];
            memberOrgs[orgIdx] = lastOrgId;
            _orgsByMemberIndex[wallet][lastOrgId] = orgIdx;
        }
        memberOrgs.pop();
        delete _orgsByMemberIndex[wallet][orgId];
    }
}
