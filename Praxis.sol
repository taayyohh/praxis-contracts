// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces.sol";

//  ____  ____    __    _  _  ____  ___
// (  _ \(  _ \  /__\  ( \/ )(  _ \/ __)
//  )___/ )   / /(__)\  )  (  )(_) \__ \
// (__)  (_)\_)(__)(__)(_/\_)(____/(___/
//
/// @title Praxis
/// @author @taayyohh
/// @notice Collaborative project funding, lifecycle management, and ERC-6909 credential system
/// @dev Projects follow a lifecycle: PROPOSED -> FUNDED -> CONFIRMED -> COMPLETING -> COMPLETED/CANCELLED.
///      Implements ERC-6909 multi-token standard for tickets (transferable) and soulbound credentials.
contract Praxis {
    // --- Types ---

    /// @notice Categories of creative projects
    enum ProjectType { SHOW, FILM, THEATER, RECORDING, WORKSHOP, INSTALLATION, OTHER }

    /// @notice Project status: proposed (0), funded (1), confirmed (2), completing (3), completed (4), cancelled (5), disputed (6)
    uint8 public constant PROPOSED = 0;
    uint8 public constant FUNDED = 1;
    uint8 public constant CONFIRMED = 2;
    uint8 public constant COMPLETING = 3;
    uint8 public constant COMPLETED = 4;
    uint8 public constant CANCELLED = 5;
    uint8 public constant DISPUTED = 6;

    /// @notice Core project data
    struct Project {
        address proposer;
        string title;
        string description;
        ProjectType projectType;
        address[] collaborators;
        uint256[] splits;
        uint256 fundingGoal;
        uint256 totalFunded;
        uint256 deadline;
        uint8 status;
        uint256 createdAt;
        uint256 completedAt;
        uint256 disputeWindowDays;   // 0-30, set at creation. 0 = no dispute window
        bool autoComplete;            // if true, funds distribute immediately when goal met
        uint8 confirmationMode;       // 0=none (autoComplete), 1=proposer-only, 2=majority, 3=all
    }

    /// @notice A funding tier within a project
    /// @param name Display name of the tier
    /// @param price Cost per unit in wei
    /// @param maxSupply Maximum mintable units (0 = unlimited)
    /// @param sold Number of units sold
    /// @param transferable If true mints a TICKET (transferable), otherwise a PRODUCER credential (soulbound)
    struct Tier {
        string name;
        uint256 price;
        uint256 maxSupply;
        uint256 sold;
        bool transferable;
    }

    /// @notice Arguments for `proposeProject`, packed into a struct to avoid
    ///         stack-too-deep in `via_ir` coverage compilation. The 16-arg form
    ///         pre-v2 broke `forge coverage` even with the IR pipeline.
    struct ProposeProjectArgs {
        string title;
        string description;
        ProjectType projectType;
        address[] collaborators;
        uint256[] splits;
        uint256 fundingGoal;
        uint256 deadline;
        string[] tierNames;
        uint256[] tierPrices;
        uint256[] tierMaxSupplies;
        bool[] tierTransferable;
        uint256 revenueSharePercent;
        uint128 location;
        uint256 disputeWindowDays;
        bool autoComplete;
        uint8 confirmationMode;
    }

    /// @notice Token type for transferable tickets
    uint8 public constant TICKET = 1;

    /// @notice Token type for soulbound producer credentials
    uint8 public constant PRODUCER = 2;

    /// @notice Token type for soulbound contributor credentials (minted on project completion)
    uint8 public constant CONTRIBUTOR = 3;

    /// @notice Token type for revenue sharing badges
    uint8 public constant REVENUE_SHARER = 4;

    /// @notice Minimum funding goal to prevent dust-level projects
    uint256 public minFundingGoal = 0.001 ether;

    // --- State ---

    /// @notice Reference to the ArtistRegistry contract for registration checks
    IArtistRegistry public immutable REGISTRY;

    /// @notice Reference to the PraxisInvites contract for granting invites on completion
    IPraxisInvites public immutable INVITES;

    /// @notice Total number of projects created
    uint256 public projectCount;

    /// @dev Internal project storage
    mapping(uint256 => Project) internal _projects;

    /// @notice Tier data for each project: tiers[projectId][tierId]
    mapping(uint256 => mapping(uint256 => Tier)) public tiers;

    /// @notice Number of tiers per project
    mapping(uint256 => uint256) public tierCount;

    /// @notice Whether an address has confirmed a given project
    mapping(uint256 => mapping(address => bool)) public hasConfirmed;

    /// @notice Total confirmation count per project
    mapping(uint256 => uint256) public confirmCount;

    /// @notice Whether an address has disputed a given project
    mapping(uint256 => mapping(address => bool)) public hasDisputed;

    /// @notice Total ETH amount backing disputes for a project
    mapping(uint256 => uint256) public disputeAmount;

    /// @notice ERC-6909 token balances: balanceOf[owner][tokenId]
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    /// @notice ERC-6909 per-token allowances: allowance[owner][spender][tokenId]
    mapping(address => mapping(address => mapping(uint256 => uint256))) public allowance;

    /// @notice ERC-6909 operator approvals: isOperator[owner][operator]
    mapping(address => mapping(address => bool)) public isOperator;

    /// @notice Total supply per token ID
    mapping(uint256 => uint256) public totalSupply;

    /// @notice Pull-payment balances for collaborators after project finalization
    mapping(address => uint256) public pendingWithdrawals;

    /// @notice ETH contributed per funder per project
    mapping(uint256 => mapping(address => uint256)) public contributions;

    /// @dev Monotonic mint counter per (projectId, tierId). Used for serial number
    ///      assignment so burned/withdrawn serials are never reused (would otherwise
    ///      collide with the next mint after a withdrawal).
    mapping(uint256 => mapping(uint256 => uint256)) internal _tierMinted;

    /// @dev Per-funder list of token serials minted within a (projectId, tierId).
    ///      Lets withdrawFunding burn the funder's tokens in O(funder's holdings)
    ///      instead of iterating every serial ever sold (former O(tier.sold²) DoS).
    mapping(uint256 => mapping(uint256 => mapping(address => uint256[]))) internal _funderTokenSerials;

    /// @notice Whether a participant has claimed their post-completion invite grant
    /// @dev Pull pattern replaces the former unbounded `_funders[]` push loop in
    ///      `_grantInvitesOnComplete`. Each collaborator/funder calls
    ///      `claimCompletionInvites(projectId)` themselves.
    mapping(uint256 => mapping(address => bool)) public completionInviteClaimed;

    /// @notice Packed latitude/longitude for project location (0 = no location)
    mapping(uint256 => uint128) public projectLocation;

    /// @notice Revenue share percentage in basis points (0 = disabled, max 10000)
    mapping(uint256 => uint256) public revenueShareBps;

    /// @notice Total ETH received as revenue for a project
    mapping(uint256 => uint256) public totalRevenue;

    /// @notice Portion of revenue allocated to funders for a project
    mapping(uint256 => uint256) public funderRevenue;

    /// @notice Amount of revenue already claimed per funder per project
    mapping(uint256 => mapping(address => uint256)) public claimedRevenue;

    // --- Events ---

    /// @notice Emitted when a new project is proposed
    /// @param projectId The ID of the new project
    /// @param proposer The address that proposed the project
    /// @param fundingGoal The target funding amount in wei
    event ProjectProposed(uint256 indexed projectId, address indexed proposer, uint256 fundingGoal);

    /// @notice Emitted when a funder purchases tier units
    /// @param projectId The project being funded
    /// @param tierId The tier purchased
    /// @param funder The funder's address
    /// @param quantity Number of units purchased
    /// @param amount Total ETH paid
    event TierFunded(uint256 indexed projectId, uint256 indexed tierId, address indexed funder, uint256 quantity, uint256 amount);

    /// @notice Emitted when a funder withdraws their funding before the goal is met
    /// @param projectId The project ID
    /// @param funder The funder's address
    /// @param amount ETH returned
    event FundingWithdrawn(uint256 indexed projectId, address indexed funder, uint256 amount);

    /// @notice Emitted when a participant confirms a funded project
    /// @param projectId The project ID
    /// @param confirmer The confirming address
    event ProjectConfirmed(uint256 indexed projectId, address indexed confirmer);

    /// @notice Emitted when a project enters the dispute window
    /// @param projectId The project ID
    /// @param disputeDeadline The timestamp when the dispute window closes
    event ProjectCompleting(uint256 indexed projectId, uint256 disputeDeadline);

    /// @notice Emitted when a project is finalized and funds are distributed
    /// @param projectId The project ID
    /// @param totalDistributed The total ETH distributed to collaborators
    event ProjectCompleted(uint256 indexed projectId, uint256 totalDistributed);

    /// @notice Emitted when a project is cancelled
    /// @param projectId The project ID
    event ProjectCancelled(uint256 indexed projectId);

    /// @notice Emitted when a funder disputes during the dispute window
    /// @param projectId The project ID
    /// @param disputer The disputing funder's address
    /// @param amount The ETH amount backing the dispute
    event ProjectDisputed(uint256 indexed projectId, address indexed disputer, uint256 amount);

    /// @notice Emitted when a funder claims a refund from a cancelled or expired project
    /// @param projectId The project ID
    /// @param funder The funder's address
    /// @param amount ETH refunded
    event RefundClaimed(uint256 indexed projectId, address indexed funder, uint256 amount);

    /// @notice Emitted when a collaborator claims their pending funds
    /// @param recipient The recipient's address
    /// @param amount ETH claimed
    event FundsClaimed(address indexed recipient, uint256 amount);

    /// @notice Emitted when revenue is distributed to a completed project's funders
    /// @param projectId The project ID
    /// @param sender The address distributing revenue
    /// @param amount ETH distributed
    event RevenueDistributed(uint256 indexed projectId, address indexed sender, uint256 amount);

    /// @notice Emitted when a funder claims their share of distributed revenue
    /// @param projectId The project ID
    /// @param funder The funder's address
    /// @param amount ETH claimed
    event RevenueClaimed(uint256 indexed projectId, address indexed funder, uint256 amount);

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

    /// @notice Restricts function access to any registered user (artist or supporter)
    modifier onlyUser() {
        require(REGISTRY.isUser(msg.sender), "not registered");
        _;
    }

    // --- Constructor ---

    /// @notice Deploy the Praxis contract
    /// @param registry Address of the ArtistRegistry contract
    /// @param invites Address of the PraxisInvites contract
    constructor(address registry, address invites) {
        REGISTRY = IArtistRegistry(registry);
        INVITES = IPraxisInvites(invites);
    }

    // --- Token ID helpers ---

    /// @notice Generate a packed token ID from its components
    /// @param tokenType The token type (TICKET, PRODUCER, CONTRIBUTOR, REVENUE_SHARER)
    /// @param projectId The project ID
    /// @param tierId The tier ID
    /// @param serial The serial number within the tier
    /// @return The packed token ID
    function generateTokenId(uint8 tokenType, uint256 projectId, uint256 tierId, uint256 serial) public pure returns (uint256) {
        return (uint256(tokenType) << 248) | (projectId << 184) | (tierId << 152) | serial;
    }

    /// @notice Extract the token type from a packed token ID
    /// @param tokenId The packed token ID
    /// @return The token type (1=TICKET, 2=PRODUCER, 3=CONTRIBUTOR, 4=REVENUE_SHARER)
    function getTokenType(uint256 tokenId) public pure returns (uint8) {
        return uint8(tokenId >> 248);
    }

    /// @notice Extract the project ID from a packed token ID
    /// @param tokenId The packed token ID
    /// @return The project ID
    function getProjectId(uint256 tokenId) public pure returns (uint64) {
        return uint64(tokenId >> 184);
    }

    /// @notice Extract the tier ID from a packed token ID
    /// @param tokenId The packed token ID
    /// @return The tier ID
    function getTierId(uint256 tokenId) public pure returns (uint32) {
        return uint32(tokenId >> 152);
    }

    // --- ERC-6909 ---

    /// @notice Transfer transferable tokens (tickets only) to another address
    /// @param receiver The recipient address
    /// @param id The token ID to transfer
    /// @param amount The amount to transfer
    /// @return True on success
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool) {
        require(getTokenType(id) == TICKET, "soulbound");
        balanceOf[msg.sender][id] -= amount;
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, msg.sender, receiver, id, amount);
        return true;
    }

    /// @notice Transfer tokens on behalf of another address (tickets only)
    /// @param sender The address to transfer from
    /// @param receiver The recipient address
    /// @param id The token ID to transfer
    /// @param amount The amount to transfer
    /// @return True on success
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external returns (bool) {
        require(getTokenType(id) == TICKET, "soulbound");

        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            uint256 allowed = allowance[sender][msg.sender][id];
            if (allowed != type(uint256).max) {
                allowance[sender][msg.sender][id] = allowed - amount;
            }
        }

        balanceOf[sender][id] -= amount;
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, sender, receiver, id, amount);
        return true;
    }

    /// @notice Approve a spender to transfer a specific token ID
    /// @param spender The approved spender address
    /// @param id The token ID to approve
    /// @param amount The approved amount (type(uint256).max for unlimited)
    /// @return True on success
    function approve(address spender, uint256 id, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender][id] = amount;
        emit Approval(msg.sender, spender, id, amount);
        return true;
    }

    /// @notice Grant or revoke operator status for all token IDs
    /// @param spender The operator address
    /// @param approved True to grant, false to revoke
    /// @return True on success
    function setOperator(address spender, bool approved) external returns (bool) {
        isOperator[msg.sender][spender] = approved;
        emit OperatorSet(msg.sender, spender, approved);
        return true;
    }

    // --- Internal mint/burn ---

    /// @notice Mint new tokens
    /// @param to The recipient address
    /// @param id The token ID to mint
    /// @param amount The amount to mint
    function _mint(address to, uint256 id, uint256 amount) internal {
        balanceOf[to][id] += amount;
        totalSupply[id] += amount;
        emit Transfer(msg.sender, address(0), to, id, amount);
    }

    /// @notice Burn existing tokens
    /// @param from The address to burn from
    /// @param id The token ID to burn
    /// @param amount The amount to burn
    function _burn(address from, uint256 id, uint256 amount) internal {
        balanceOf[from][id] -= amount;
        totalSupply[id] -= amount;
        emit Transfer(msg.sender, from, address(0), id, amount);
    }

    // --- Project lifecycle ---

    /// @notice Update the minimum funding goal (deployer only)
    function setMinFundingGoal(uint256 _min) external {
        require(msg.sender == REGISTRY.deployer(), "not deployer");
        require(_min > 0 && _min <= 100 ether, "invalid min (0 < min <= 100 ETH)");
        minFundingGoal = _min;
    }

    /// @notice Propose a new collaborative project with tiered funding
    /// @dev Args packed into a struct to avoid stack-too-deep in via_ir coverage builds.
    /// @param args See {ProposeProjectArgs}
    /// @return id The new project's id
    function proposeProject(ProposeProjectArgs calldata args) external onlyRegistered returns (uint256) {
        require(bytes(args.title).length > 0, "empty title");
        require(args.collaborators.length > 0, "no collaborators");
        require(args.collaborators.length <= 200, "too many collaborators");
        require(args.collaborators.length == args.splits.length, "splits mismatch");
        require(args.fundingGoal >= minFundingGoal, "goal too low");
        require(args.deadline > block.timestamp, "past deadline");
        require(args.tierNames.length > 0, "no tiers");
        // Hard cap on tier count: bounds finalize/withdraw/fund loops to a known constant
        // and prevents griefing the proposer by inflating per-call gas cost.
        require(args.tierNames.length <= 100, "too many tiers");
        require(
            args.tierNames.length == args.tierPrices.length &&
            args.tierNames.length == args.tierMaxSupplies.length &&
            args.tierNames.length == args.tierTransferable.length,
            "tier arrays mismatch"
        );
        require(args.disputeWindowDays <= 30, "dispute window too long");
        require(args.confirmationMode <= 3, "invalid confirmation mode");

        uint256 _disputeWindowDays = args.disputeWindowDays;
        uint8 _confirmationMode = args.confirmationMode;
        if (args.autoComplete) {
            require(_disputeWindowDays == 0, "autoComplete requires no dispute window");
            _confirmationMode = 0;
        } else {
            // Non-autoComplete projects MUST have confirmation (mode 1, 2, or 3)
            require(_confirmationMode >= 1, "non-autoComplete needs confirmation");
            // Non-autoComplete projects must have at least 1-day dispute window
            if (_disputeWindowDays == 0) _disputeWindowDays = 1;
        }

        uint256 totalSplits;
        for (uint256 i = 0; i < args.splits.length; i++) {
            totalSplits += args.splits[i];
        }
        require(totalSplits == 10000, "splits must sum to 10000");

        for (uint256 i = 0; i < args.collaborators.length; i++) {
            (, uint256 registeredAt) = REGISTRY.artists(args.collaborators[i]);
            require(registeredAt > 0, "collaborator not registered");
        }

        uint256 id = projectCount++;
        Project storage p = _projects[id];
        p.proposer = msg.sender;
        p.title = args.title;
        p.description = args.description;
        p.projectType = args.projectType;
        p.collaborators = args.collaborators;
        p.splits = args.splits;
        p.fundingGoal = args.fundingGoal;
        p.deadline = args.deadline;
        p.status = PROPOSED;
        p.createdAt = block.timestamp;
        p.disputeWindowDays = _disputeWindowDays;
        p.autoComplete = args.autoComplete;
        p.confirmationMode = _confirmationMode;

        for (uint256 i = 0; i < args.tierNames.length; i++) {
            require(args.tierPrices[i] > 0, "zero tier price");
            tiers[id][i] = Tier({
                name: args.tierNames[i],
                price: args.tierPrices[i],
                maxSupply: args.tierMaxSupplies[i],
                sold: 0,
                transferable: args.tierTransferable[i]
            });
        }
        tierCount[id] = args.tierNames.length;

        if (args.revenueSharePercent > 0) {
            require(args.revenueSharePercent <= 10000, "invalid revenue share");
            revenueShareBps[id] = args.revenueSharePercent;
        }

        if (args.location != 0) {
            projectLocation[id] = args.location;
        }

        emit ProjectProposed(id, msg.sender, args.fundingGoal);
        return id;
    }

    /// @notice Fund a project by purchasing tier units
    /// @dev Mints TICKET tokens for transferable tiers, PRODUCER tokens for soulbound tiers.
    ///      Automatically transitions project to FUNDED when fundingGoal is met.
    /// @param projectId The project to fund
    /// @param tierId The tier to purchase from
    /// @param quantity Number of units to purchase (max 100 per transaction)
    function fundTier(uint256 projectId, uint256 tierId, uint256 quantity) external payable onlyUser {
        Project storage p = _projects[projectId];
        require(p.status == PROPOSED, "not fundable");
        require(block.timestamp < p.deadline, "past deadline");
        require(tierId < tierCount[projectId], "invalid tier");
        require(quantity > 0, "zero quantity");
        require(quantity <= 100, "max 100 per tx");

        Tier storage t = tiers[projectId][tierId];
        require(t.maxSupply == 0 || t.sold + quantity <= t.maxSupply, "tier sold out");

        uint256 cost = t.price * quantity;
        require(msg.value == cost, "wrong payment");

        p.totalFunded += cost;
        contributions[projectId][msg.sender] += cost;
        t.sold += quantity;

        uint8 tokenType = t.transferable ? TICKET : PRODUCER;
        // Use monotonic mint counter (never decrements on burn) so withdrawn serials
        // are never reused — preserves token-id uniqueness across the project's life.
        uint256 mintedSoFar = _tierMinted[projectId][tierId];
        for (uint256 i = 0; i < quantity; i++) {
            uint256 serial = mintedSoFar + i + 1;
            uint256 tokenId = generateTokenId(tokenType, projectId, tierId, serial);
            _mint(msg.sender, tokenId, 1);
            _funderTokenSerials[projectId][tierId][msg.sender].push(serial);
        }
        _tierMinted[projectId][tierId] = mintedSoFar + quantity;

        if (p.totalFunded >= p.fundingGoal) {
            if (p.autoComplete) {
                // Skip FUNDED state, go directly to COMPLETED
                p.status = COMPLETED;
                p.completedAt = block.timestamp;

                // distribute to pendingWithdrawals per splits (last gets remainder)
                uint256 total = p.totalFunded;
                uint256 remaining = total;
                for (uint256 j = 0; j < p.collaborators.length; j++) {
                    uint256 share;
                    if (j == p.collaborators.length - 1) {
                        share = remaining;
                    } else {
                        share = (total * p.splits[j]) / 10000;
                    }
                    pendingWithdrawals[p.collaborators[j]] += share;
                    remaining -= share;
                }

                // mint CONTRIBUTOR tokens
                for (uint256 j = 0; j < p.collaborators.length; j++) {
                    uint256 tokenId = generateTokenId(CONTRIBUTOR, projectId, 0, j);
                    _mint(p.collaborators[j], tokenId, 1);
                }

                // Invites are NOT pushed here — participants pull via claimCompletionInvites()
                // to bound gas (former O(funders) loop was an unbounded DoS vector at scale).

                emit ProjectCompleted(projectId, total);
            } else {
                p.status = FUNDED;
            }
        }

        emit TierFunded(projectId, tierId, msg.sender, quantity, cost);
    }

    /// @notice Withdraw funding from a project that has not yet reached its goal
    /// @dev Only available while project is PROPOSED. Burns all tokens STILL HELD by the
    ///      funder and refunds proportionally. Transferred-away tokens are not refunded.
    ///      CEI: state changes before external call.
    /// @param projectId The project to withdraw from
    function withdrawFunding(uint256 projectId) external {
        Project storage p = _projects[projectId];
        require(p.status == PROPOSED, "funding locked");

        uint256 originalContribution = contributions[projectId][msg.sender];
        require(originalContribution > 0, "nothing to withdraw");

        // Calculate refund based on tokens STILL HELD, not original contribution.
        // If funder transferred tickets away, they don't get refunded for those.
        uint256 refundAmount;
        uint256 tc = tierCount[projectId];
        for (uint256 t = 0; t < tc; t++) {
            Tier storage tier = tiers[projectId][t];
            uint8 tokenType = tier.transferable ? TICKET : PRODUCER;
            uint256[] storage serials = _funderTokenSerials[projectId][t][msg.sender];
            uint256 burned;
            for (uint256 i = 0; i < serials.length; i++) {
                uint256 tokenId = generateTokenId(tokenType, projectId, t, serials[i]);
                uint256 bal = balanceOf[msg.sender][tokenId];
                if (bal > 0) {
                    _burn(msg.sender, tokenId, bal);
                    burned += bal;
                    refundAmount += tier.price * bal;
                }
            }
            delete _funderTokenSerials[projectId][t][msg.sender];
            tier.sold -= burned;
        }
        require(refundAmount > 0, "no tokens held");

        // Effects: update contribution and totalFunded based on actual refund
        contributions[projectId][msg.sender] = originalContribution - refundAmount;
        p.totalFunded -= refundAmount;

        // Interaction: external ETH transfer
        (bool ok,) = msg.sender.call{value: refundAmount}("");
        require(ok, "transfer failed");

        emit FundingWithdrawn(projectId, msg.sender, refundAmount);
    }

    // --- Confirmation: proposer + majority of collaborators ---

    /// @notice Confirm a funded project as a participant (proposer or collaborator)
    /// @dev Requires the project to be in FUNDED status. Transitions to CONFIRMED when
    ///      the proposer and a majority of collaborators have confirmed.
    /// @param projectId The project to confirm
    function confirmProject(uint256 projectId) external {
        Project storage p = _projects[projectId];
        require(p.status == FUNDED, "not funded");

        bool isParticipant = (msg.sender == p.proposer);
        for (uint256 i = 0; i < p.collaborators.length; i++) {
            if (p.collaborators[i] == msg.sender) { isParticipant = true; break; }
        }
        require(isParticipant, "not a participant");
        require(!hasConfirmed[projectId][msg.sender], "already confirmed");

        hasConfirmed[projectId][msg.sender] = true;
        confirmCount[projectId]++;

        emit ProjectConfirmed(projectId, msg.sender);

        if (_isConfirmationMet(projectId)) {
            p.status = CONFIRMED;
        }
    }

    /// @notice Check if the confirmation threshold is met for a project
    /// @param projectId The project to check
    /// @return True if the confirmation threshold is met based on confirmationMode
    function _isConfirmationMet(uint256 projectId) internal view returns (bool) {
        Project storage p = _projects[projectId];

        if (p.confirmationMode == 0) return true; // autoComplete, no confirmation needed
        if (!hasConfirmed[projectId][p.proposer]) return false;
        if (p.confirmationMode == 1) return true; // proposer-only

        uint256 collabConfirms;
        for (uint256 i = 0; i < p.collaborators.length; i++) {
            if (hasConfirmed[projectId][p.collaborators[i]]) collabConfirms++;
        }

        if (p.confirmationMode == 2) return collabConfirms > p.collaborators.length / 2; // majority
        return collabConfirms == p.collaborators.length; // all (mode 3)
    }

    // --- Completion: starts 3-day dispute window ---

    /// @notice Initiate project completion, starting the dispute window
    /// @dev Only the proposer can call this. Funders can dispute during the window.
    /// @param projectId The project to complete
    function completeProject(uint256 projectId) external {
        Project storage p = _projects[projectId];
        require(msg.sender == p.proposer, "not proposer");
        require(p.status == CONFIRMED, "not confirmed");

        p.status = COMPLETING;
        p.completedAt = block.timestamp;

        emit ProjectCompleting(projectId, block.timestamp + (p.disputeWindowDays * 1 days));
    }

    // --- Dispute: funders can dispute during the 3-day window ---

    /// @notice Dispute a project during the 3-day dispute window
    /// @dev If disputes exceed 50% of total funded amount, the project is auto-cancelled.
    /// @param projectId The project to dispute
    function dispute(uint256 projectId) external {
        Project storage p = _projects[projectId];
        require(p.status == COMPLETING, "not in dispute window");
        require(block.timestamp < p.completedAt + (p.disputeWindowDays * 1 days), "dispute window closed");

        uint256 contributed = contributions[projectId][msg.sender];
        require(contributed > 0, "not a funder");
        require(!hasDisputed[projectId][msg.sender], "already disputed");

        hasDisputed[projectId][msg.sender] = true;
        disputeAmount[projectId] += contributed;

        emit ProjectDisputed(projectId, msg.sender, contributed);

        // if >=50% of funded amount disputes, revert to cancelled
        // Uses multiplication to avoid rounding errors from division
        if (disputeAmount[projectId] * 2 >= p.totalFunded) {
            p.status = CANCELLED;
            emit ProjectCancelled(projectId);
        }
    }

    // --- Finalize: after dispute window passes without majority dispute ---

    /// @notice Finalize a completed project, distributing funds to collaborators
    /// @dev Can only be called after the dispute window has passed. Distributes ETH to
    ///      collaborator pendingWithdrawals per splits, mints CONTRIBUTOR tokens, and
    ///      grants invites to all participants.
    /// @param projectId The project to finalize
    function finalizeProject(uint256 projectId) external {
        Project storage p = _projects[projectId];
        require(p.status == COMPLETING, "not completing");
        require(block.timestamp >= p.completedAt + (p.disputeWindowDays * 1 days), "dispute window active");

        p.status = COMPLETED;
        uint256 total = p.totalFunded;

        // distribute to pendingWithdrawals per splits (last gets remainder to avoid dust)
        uint256 remaining = total;
        for (uint256 i = 0; i < p.collaborators.length; i++) {
            uint256 share;
            if (i == p.collaborators.length - 1) {
                share = remaining; // last collaborator gets remainder
            } else {
                share = (total * p.splits[i]) / 10000;
            }
            pendingWithdrawals[p.collaborators[i]] += share;
            remaining -= share;
        }

        // mint CONTRIBUTOR tokens to all collaborators
        for (uint256 i = 0; i < p.collaborators.length; i++) {
            uint256 tokenId = generateTokenId(CONTRIBUTOR, projectId, 0, i);
            _mint(p.collaborators[i], tokenId, 1);
        }

        // Invites are pulled by participants via claimCompletionInvites() — see notes above.

        emit ProjectCompleted(projectId, total);
    }

    /// @notice Pull 5 completion invites for a participant on a COMPLETED project
    /// @dev Replaces the former unbounded `_grantInvitesOnComplete` push loop, which
    ///      iterated every funder address and could exceed the block gas limit at scale.
    ///      Anyone can call this for themselves; eligibility = collaborator OR non-zero
    ///      contribution. Uses try/catch so a failing invite contract never bricks claims.
    /// @param projectId The completed project to claim from
    function claimCompletionInvites(uint256 projectId) external {
        Project storage p = _projects[projectId];
        require(p.status == COMPLETED, "not completed");
        require(!completionInviteClaimed[projectId][msg.sender], "already claimed");

        bool eligible;
        if (contributions[projectId][msg.sender] > 0) {
            eligible = true;
        } else {
            for (uint256 i = 0; i < p.collaborators.length; i++) {
                if (p.collaborators[i] == msg.sender) { eligible = true; break; }
            }
        }
        require(eligible, "not eligible");

        completionInviteClaimed[projectId][msg.sender] = true;
        try INVITES.grantInvites(msg.sender, 5) {} catch {}
    }

    /// @notice Cancel a project (proposer only, while PROPOSED or FUNDED)
    /// @dev Cancelled projects allow funders to claim refunds.
    /// @param projectId The project to cancel
    function cancelProject(uint256 projectId) external {
        Project storage p = _projects[projectId];
        require(msg.sender == p.proposer, "not proposer");
        require(p.status == PROPOSED || p.status == FUNDED, "not cancellable");

        p.status = CANCELLED;
        emit ProjectCancelled(projectId);
    }

    /// @notice Claim a refund from a cancelled or expired project
    /// @dev Available when project is CANCELLED or PROPOSED past its deadline.
    ///      CEI: zeroes contribution before external ETH transfer.
    /// @param projectId The project to claim a refund from
    function claimRefund(uint256 projectId) external {
        Project storage p = _projects[projectId];
        require(
            p.status == CANCELLED ||
            (p.status == PROPOSED && block.timestamp >= p.deadline),
            "not refundable"
        );

        uint256 originalContribution = contributions[projectId][msg.sender];
        require(originalContribution > 0, "nothing to refund");

        // Calculate refund based on tokens STILL HELD (same as withdrawFunding).
        // Prevents transfer-then-refund exploit on cancellation.
        uint256 refundAmount;
        uint256 tc = tierCount[projectId];
        for (uint256 t = 0; t < tc; t++) {
            Tier storage tier = tiers[projectId][t];
            uint8 tokenType = tier.transferable ? TICKET : PRODUCER;
            uint256[] storage serials = _funderTokenSerials[projectId][t][msg.sender];
            uint256 burned;
            for (uint256 i = 0; i < serials.length; i++) {
                uint256 tokenId = generateTokenId(tokenType, projectId, t, serials[i]);
                uint256 bal = balanceOf[msg.sender][tokenId];
                if (bal > 0) {
                    _burn(msg.sender, tokenId, bal);
                    burned += bal;
                    refundAmount += tier.price * bal;
                }
            }
            delete _funderTokenSerials[projectId][t][msg.sender];
            tier.sold -= burned;
        }
        // If no tokens held but had contribution (e.g., all transferred), no refund
        require(refundAmount > 0, "no tokens held");

        // Effects before interaction
        contributions[projectId][msg.sender] = originalContribution - refundAmount;
        p.totalFunded -= refundAmount;

        (bool ok,) = msg.sender.call{value: refundAmount}("");
        require(ok, "transfer failed");

        emit RefundClaimed(projectId, msg.sender, refundAmount);
    }

    /// @notice Claim pending withdrawal funds (collaborator earnings from completed projects)
    /// @dev CEI: zeroes pending balance before external ETH transfer.
    function claimFunds() external {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "nothing to claim");

        // Effects before interaction
        pendingWithdrawals[msg.sender] = 0;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");

        emit FundsClaimed(msg.sender, amount);
    }

    // --- Revenue sharing ---

    /// @notice Distribute revenue to funders of a completed project
    /// @dev 100% of msg.value goes to the funder pool. The team keeps their cut before calling this.
    ///      Mints a REVENUE_SHARER badge (once per sender per project).
    /// @param projectId The completed project to distribute revenue for
    function distributeRevenue(uint256 projectId) external payable onlyRegistered {
        Project storage p = _projects[projectId];
        require(p.status == COMPLETED, "not completed");
        require(revenueShareBps[projectId] > 0, "no revenue sharing");
        require(msg.value > 0, "no value");

        totalRevenue[projectId] += msg.value;
        funderRevenue[projectId] += msg.value;

        // mint REVENUE_SHARER badge (once per project)
        uint256 badgeId = generateTokenId(REVENUE_SHARER, projectId, 0, 0);
        if (balanceOf[msg.sender][badgeId] == 0) {
            _mint(msg.sender, badgeId, 1);
        }

        emit RevenueDistributed(projectId, msg.sender, msg.value);
    }

    /// @notice Claim proportional revenue share as a funder
    /// @dev Calculates entitled amount as (contributed / totalFunded) * funderRevenue,
    ///      minus any previously claimed amount. CEI: updates claimed before transfer.
    /// @param projectId The project to claim revenue from
    function claimRevenue(uint256 projectId) external {
        require(revenueShareBps[projectId] > 0, "no revenue sharing");
        uint256 contributed = contributions[projectId][msg.sender];
        require(contributed > 0, "not a funder");

        Project storage p = _projects[projectId];
        uint256 totalFunderRev = funderRevenue[projectId];

        uint256 entitled = (totalFunderRev * contributed) / p.totalFunded;
        uint256 alreadyClaimed = claimedRevenue[projectId][msg.sender];
        uint256 claimable = entitled - alreadyClaimed;
        require(claimable > 0, "nothing to claim");

        // Effects before interaction
        claimedRevenue[projectId][msg.sender] += claimable;

        (bool ok,) = msg.sender.call{value: claimable}("");
        require(ok, "transfer failed");

        emit RevenueClaimed(projectId, msg.sender, claimable);
    }

    /// @notice Calculate unclaimed revenue for a funder on a project
    /// @param projectId The project to query
    /// @param funder The funder's address
    /// @return The amount of unclaimed revenue in wei
    function pendingRevenueFor(uint256 projectId, address funder) external view returns (uint256) {
        if (revenueShareBps[projectId] == 0) return 0;
        uint256 contributed = contributions[projectId][funder];
        if (contributed == 0) return 0;
        uint256 entitled = (funderRevenue[projectId] * contributed) / _projects[projectId].totalFunded;
        return entitled - claimedRevenue[projectId][funder];
    }

    // --- Views ---

    /// @notice Get full project details
    /// @param projectId The project to query
    /// @return proposer The project proposer
    /// @return title Project title
    /// @return description Project description
    /// @return projectType Project category
    /// @return collaborators Array of collaborator addresses
    /// @return splits Revenue splits in basis points
    /// @return fundingGoal Target funding in wei
    /// @return totalFunded Current funding in wei
    /// @return deadline Funding expiration timestamp
    /// @return status Current lifecycle status
    /// @return createdAt Creation timestamp
    function getProject(uint256 projectId) external view returns (
        address proposer,
        string memory title,
        string memory description,
        ProjectType projectType,
        address[] memory collaborators,
        uint256[] memory splits,
        uint256 fundingGoal,
        uint256 totalFunded,
        uint256 deadline,
        uint8 status,
        uint256 createdAt
    ) {
        Project storage p = _projects[projectId];
        return (p.proposer, p.title, p.description, p.projectType,
                p.collaborators, p.splits, p.fundingGoal, p.totalFunded,
                p.deadline, p.status, p.createdAt);
    }

    /// @notice Get the geographic location of a project
    /// @param projectId The project to query
    /// @return lat Latitude as a signed 64-bit integer
    /// @return lng Longitude as a signed 64-bit integer
    function getProjectLocation(uint256 projectId) external view returns (int64 lat, int64 lng) {
        uint128 packed = projectLocation[projectId];
        lat = int64(uint64(packed >> 64));
        lng = int64(uint64(packed));
    }

    /// @notice Get details for a specific funding tier
    /// @param projectId The project to query
    /// @param tierId The tier index
    /// @return name Tier display name
    /// @return price Cost per unit in wei
    /// @return maxSupply Maximum mintable units (0 = unlimited)
    /// @return sold Number of units sold
    /// @return transferable Whether the tier mints transferable tickets
    function getTier(uint256 projectId, uint256 tierId) external view returns (
        string memory name,
        uint256 price,
        uint256 maxSupply,
        uint256 sold,
        bool transferable
    ) {
        Tier storage t = tiers[projectId][tierId];
        return (t.name, t.price, t.maxSupply, t.sold, t.transferable);
    }

    /// @notice Get the serial numbers held by a funder within a tier
    /// @dev Replaces the deprecated `getFunders(projectId)` enumerator. Indexers track
    ///      funders via `TierFunded` events; this view exists for client-side burn-cost
    ///      estimation before calling `withdrawFunding`.
    /// @param projectId The project to query
    /// @param tierId The tier to query
    /// @param funder The funder's address
    /// @return Array of serial numbers minted to this funder for this tier
    function getFunderSerials(uint256 projectId, uint256 tierId, address funder)
        external
        view
        returns (uint256[] memory)
    {
        return _funderTokenSerials[projectId][tierId][funder];
    }
}
