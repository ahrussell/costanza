// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title The Human Fund
/// @notice An autonomous AI agent that manages a charitable treasury on Base.
///         Phase 0: No auction, no TEE — single authorized runner for testing.
/// @dev Each epoch (~24 hours), the runner submits an action chosen by the AI model.
///      The contract validates bounds, executes the action, and emits a DiaryEntry event.
contract TheHumanFund {
    // ─── Types ───────────────────────────────────────────────────────────

    struct Nonprofit {
        string name;
        address payable addr;
        uint256 totalDonated;
        uint256 donationCount;
    }

    struct EpochRecord {
        uint256 timestamp;
        bytes action;      // JSON action blob
        bytes reasoning;   // CoT reasoning blob
        uint256 treasuryBefore;
        uint256 treasuryAfter;
        uint256 bountyPaid;
        bool executed;
    }

    struct ReferralCode {
        address owner;
        uint256 totalReferred;
        uint256 referralCount;
        bool exists;
    }

    struct PendingCommission {
        address payable referrer;
        uint256 amount;
        uint256 releaseTime;
        bool claimed;
    }

    // ─── Events ──────────────────────────────────────────────────────────

    event DiaryEntry(
        uint256 indexed epoch,
        bytes reasoning,
        bytes action,
        uint256 treasuryBefore,
        uint256 treasuryAfter
    );

    event DonationReceived(
        address indexed donor,
        uint256 amount,
        uint256 indexed referralCode,
        uint256 commissionAmount
    );

    event NonprofitDonation(
        uint256 indexed epoch,
        uint256 indexed nonprofitId,
        uint256 amount
    );

    event CommissionRateChanged(uint256 indexed epoch, uint256 newRateBps);
    event MaxBidChanged(uint256 indexed epoch, uint256 newMaxBid);
    event ReferralCodeMinted(uint256 indexed codeId, address indexed owner);
    event CommissionClaimed(uint256 indexed codeId, uint256 amount);
    event EpochStarted(uint256 indexed epoch, bytes32 inputHash);

    // ─── Constants ───────────────────────────────────────────────────────

    uint256 public constant EPOCH_DURATION = 24 hours;
    uint256 public constant MAX_DONATION_BPS = 1000;       // 10% of treasury
    uint256 public constant MIN_COMMISSION_BPS = 100;      // 1%
    uint256 public constant MAX_COMMISSION_BPS = 9000;     // 90%
    uint256 public constant MIN_MAX_BID = 0.0001 ether;
    uint256 public constant MAX_BID_BPS = 200;             // 2% of treasury
    uint256 public constant MIN_DONATION_AMOUNT = 0.001 ether;
    uint256 public constant COMMISSION_DELAY = 7 days;
    uint256 public constant AUTO_ESCALATION_BPS = 1000;    // 10% increase per missed epoch
    uint256 public constant NUM_NONPROFITS = 3;

    // ─── State ───────────────────────────────────────────────────────────

    address public owner;           // Phase 0: deployer is the authorized runner
    uint256 public deployTimestamp;
    uint256 public currentEpoch;

    // Agent-controlled parameters
    uint256 public commissionRateBps;
    uint256 public maxBid;

    // Treasury tracking
    uint256 public totalInflows;
    uint256 public totalDonatedToNonprofits;
    uint256 public totalCommissionsPaid;
    uint256 public totalBountiesPaid;

    // Epoch tracking
    uint256 public lastDonationEpoch;
    uint256 public lastCommissionChangeEpoch;
    uint256 public consecutiveMissedEpochs;

    // Nonprofits (1-indexed for the agent's benefit)
    mapping(uint256 => Nonprofit) public nonprofits;

    // Epochs
    mapping(uint256 => EpochRecord) public epochs;
    mapping(uint256 => bytes32) public epochInputHashes;

    // Referral system
    uint256 public nextReferralCodeId;
    mapping(uint256 => ReferralCode) public referralCodes;
    PendingCommission[] public pendingCommissions;

    // Per-epoch inflow tracking (reset each epoch)
    uint256 public currentEpochInflow;
    uint256 public currentEpochDonationCount;
    uint256 public currentEpochCommissions;

    // Balance snapshots for treasury trend (stored every 5 epochs)
    mapping(uint256 => uint256) public balanceSnapshots;

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(
        string[3] memory _names,
        address payable[3] memory _addrs,
        uint256 _initialCommissionBps,
        uint256 _initialMaxBid
    ) payable {
        require(_initialCommissionBps >= MIN_COMMISSION_BPS && _initialCommissionBps <= MAX_COMMISSION_BPS, "Invalid commission");
        require(_initialMaxBid >= MIN_MAX_BID, "Max bid too low");

        owner = msg.sender;
        deployTimestamp = block.timestamp;
        currentEpoch = 1;
        commissionRateBps = _initialCommissionBps;
        maxBid = _initialMaxBid;
        nextReferralCodeId = 1;

        for (uint256 i = 0; i < NUM_NONPROFITS; i++) {
            require(_addrs[i] != address(0), "Zero address nonprofit");
            nonprofits[i + 1] = Nonprofit({
                name: _names[i],
                addr: _addrs[i],
                totalDonated: 0,
                donationCount: 0
            });
        }

        if (msg.value > 0) {
            totalInflows += msg.value;
        }
    }

    // ─── Public: Donate to the Fund ──────────────────────────────────────

    /// @notice Donate ETH to the fund, optionally with a referral code.
    /// @param referralCodeId The referral code ID (0 for no referral).
    function donate(uint256 referralCodeId) external payable {
        require(msg.value >= MIN_DONATION_AMOUNT, "Below minimum donation");

        uint256 commission = 0;

        if (referralCodeId > 0 && referralCodes[referralCodeId].exists) {
            commission = (msg.value * commissionRateBps) / 10000;
            pendingCommissions.push(PendingCommission({
                referrer: payable(referralCodes[referralCodeId].owner),
                amount: commission,
                releaseTime: block.timestamp + COMMISSION_DELAY,
                claimed: false
            }));
            referralCodes[referralCodeId].totalReferred += msg.value;
            referralCodes[referralCodeId].referralCount += 1;
        }

        totalInflows += msg.value;
        currentEpochInflow += msg.value;
        currentEpochDonationCount += 1;

        emit DonationReceived(msg.sender, msg.value, referralCodeId, commission);
    }

    /// @notice Mint a referral code for the caller.
    function mintReferralCode() external returns (uint256) {
        uint256 codeId = nextReferralCodeId++;
        referralCodes[codeId] = ReferralCode({
            owner: msg.sender,
            totalReferred: 0,
            referralCount: 0,
            exists: true
        });
        emit ReferralCodeMinted(codeId, msg.sender);
        return codeId;
    }

    /// @notice Claim all matured commissions for a referral code.
    function claimCommissions() external {
        uint256 totalClaimed = 0;
        for (uint256 i = 0; i < pendingCommissions.length; i++) {
            PendingCommission storage pc = pendingCommissions[i];
            if (pc.referrer == msg.sender && !pc.claimed && block.timestamp >= pc.releaseTime) {
                pc.claimed = true;
                totalClaimed += pc.amount;
            }
        }
        require(totalClaimed > 0, "No claimable commissions");
        totalCommissionsPaid += totalClaimed;
        (bool sent, ) = payable(msg.sender).call{value: totalClaimed}("");
        require(sent, "Commission transfer failed");
    }

    // ─── Owner: Epoch Execution (Phase 0) ────────────────────────────────

    /// @notice Submit the AI agent's action for the current epoch.
    /// @dev Phase 0: Only the owner can call this. No auction, no TEE.
    /// @param action The JSON-encoded action blob.
    /// @param reasoning The agent's chain-of-thought reasoning.
    function submitEpochAction(bytes calldata action, bytes calldata reasoning) external onlyOwner {
        uint256 epoch = currentEpoch;
        require(!epochs[epoch].executed, "Epoch already executed");

        uint256 treasuryBefore = address(this).balance;

        // Parse and execute the action
        _executeAction(epoch, action);

        uint256 treasuryAfter = address(this).balance;

        // Record the epoch
        epochs[epoch] = EpochRecord({
            timestamp: block.timestamp,
            action: action,
            reasoning: reasoning,
            treasuryBefore: treasuryBefore,
            treasuryAfter: treasuryAfter,
            bountyPaid: 0,   // Phase 0: no bounty
            executed: true
        });

        // Store balance snapshot every 5 epochs
        if (epoch % 5 == 0) {
            balanceSnapshots[epoch] = treasuryAfter;
        }

        emit DiaryEntry(epoch, reasoning, action, treasuryBefore, treasuryAfter);

        // Reset per-epoch counters and advance
        currentEpochInflow = 0;
        currentEpochDonationCount = 0;
        currentEpochCommissions = 0;
        consecutiveMissedEpochs = 0;
        currentEpoch = epoch + 1;
    }

    /// @notice Skip the current epoch (no runner bid or missed deadline).
    function skipEpoch() external onlyOwner {
        uint256 epoch = currentEpoch;
        require(!epochs[epoch].executed, "Epoch already executed");

        consecutiveMissedEpochs += 1;
        currentEpoch = epoch + 1;

        // Reset per-epoch counters
        currentEpochInflow = 0;
        currentEpochDonationCount = 0;
        currentEpochCommissions = 0;
    }

    // ─── Internal: Action Execution ──────────────────────────────────────

    function _executeAction(uint256 epoch, bytes calldata action) internal {
        // Simple action parsing — expects ABI-encoded action type + params
        // For Phase 0, we use a simplified encoding:
        //   action_type (uint8): 0=noop, 1=donate, 2=set_commission_rate, 3=set_max_bid
        //   For donate: nonprofit_id (uint256), amount (uint256)
        //   For set_commission_rate: rate_bps (uint256)
        //   For set_max_bid: amount (uint256)

        require(action.length >= 1, "Empty action");

        uint8 actionType = uint8(action[0]);

        if (actionType == 0) {
            // noop — do nothing
            return;
        } else if (actionType == 1) {
            // donate
            require(action.length >= 65, "Invalid donate params");
            (uint256 nonprofitId, uint256 amount) = abi.decode(action[1:], (uint256, uint256));
            _executeDonate(epoch, nonprofitId, amount);
        } else if (actionType == 2) {
            // set_commission_rate
            require(action.length >= 33, "Invalid commission params");
            uint256 rateBps = abi.decode(action[1:], (uint256));
            _executeSetCommissionRate(epoch, rateBps);
        } else if (actionType == 3) {
            // set_max_bid
            require(action.length >= 33, "Invalid max bid params");
            uint256 amount = abi.decode(action[1:], (uint256));
            _executeSetMaxBid(epoch, amount);
        } else {
            revert("Unknown action type");
        }
    }

    function _executeDonate(uint256 epoch, uint256 nonprofitId, uint256 amount) internal {
        require(nonprofitId >= 1 && nonprofitId <= NUM_NONPROFITS, "Invalid nonprofit ID");
        require(amount > 0, "Donation must be positive");

        uint256 maxDonation = (address(this).balance * MAX_DONATION_BPS) / 10000;
        require(amount <= maxDonation, "Exceeds max donation (10% of treasury)");

        Nonprofit storage np = nonprofits[nonprofitId];
        (bool sent, ) = np.addr.call{value: amount}("");
        require(sent, "Donation transfer failed");

        np.totalDonated += amount;
        np.donationCount += 1;
        totalDonatedToNonprofits += amount;
        lastDonationEpoch = epoch;

        emit NonprofitDonation(epoch, nonprofitId, amount);
    }

    function _executeSetCommissionRate(uint256 epoch, uint256 rateBps) internal {
        require(rateBps >= MIN_COMMISSION_BPS && rateBps <= MAX_COMMISSION_BPS, "Commission out of bounds");
        commissionRateBps = rateBps;
        lastCommissionChangeEpoch = epoch;
        emit CommissionRateChanged(epoch, rateBps);
    }

    function _executeSetMaxBid(uint256 epoch, uint256 amount) internal {
        require(amount >= MIN_MAX_BID, "Below minimum bid");
        uint256 maxAllowed = (address(this).balance * MAX_BID_BPS) / 10000;
        require(amount <= maxAllowed, "Exceeds max bid ceiling (2% of treasury)");
        maxBid = amount;
        emit MaxBidChanged(epoch, amount);
    }

    // ─── Views ───────────────────────────────────────────────────────────

    /// @notice Get the effective max bid ceiling (with auto-escalation for missed epochs).
    function effectiveMaxBid() public view returns (uint256) {
        if (consecutiveMissedEpochs == 0) return maxBid;

        // 10% compounding escalation per missed epoch
        uint256 escalated = maxBid;
        for (uint256 i = 0; i < consecutiveMissedEpochs; i++) {
            escalated = escalated + (escalated * AUTO_ESCALATION_BPS) / 10000;
        }

        // Cap at 2% of treasury
        uint256 hardCap = (address(this).balance * MAX_BID_BPS) / 10000;
        return escalated < hardCap ? escalated : hardCap;
    }

    /// @notice Get the current treasury balance.
    function treasuryBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Get nonprofit info by ID.
    function getNonprofit(uint256 id) external view returns (string memory name, address addr, uint256 totalDonated, uint256 donationCount) {
        require(id >= 1 && id <= NUM_NONPROFITS, "Invalid nonprofit ID");
        Nonprofit storage np = nonprofits[id];
        return (np.name, np.addr, np.totalDonated, np.donationCount);
    }

    /// @notice Get epoch record.
    function getEpochRecord(uint256 epoch) external view returns (
        uint256 timestamp, bytes memory action, bytes memory reasoning,
        uint256 treasuryBefore, uint256 treasuryAfter, uint256 bountyPaid, bool executed
    ) {
        EpochRecord storage r = epochs[epoch];
        return (r.timestamp, r.action, r.reasoning, r.treasuryBefore, r.treasuryAfter, r.bountyPaid, r.executed);
    }

    /// @notice Get number of pending commissions.
    function pendingCommissionsCount() external view returns (uint256) {
        return pendingCommissions.length;
    }

    // Allow receiving ETH directly (for seed funding)
    receive() external payable {
        totalInflows += msg.value;
    }
}
