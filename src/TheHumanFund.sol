// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IAutomataDcapAttestation.sol";

/// @title The Human Fund
/// @notice An autonomous AI agent that manages a charitable treasury on Base.
///         Phase 0: No auction, no TEE — single authorized runner for testing.
///         Phase 1: TEE attestation verification via Automata DCAP.
///         Phase 2: Reverse auction for permissionless runner participation.
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

    // Phase 2: Auction types
    enum EpochPhase { IDLE, BIDDING, EXECUTION, SETTLED }

    struct AuctionState {
        uint256 epochStartTime;       // block.timestamp when auction opened
        EpochPhase phase;             // current lifecycle phase
        uint256 bidCount;             // number of bids received
        address winner;               // lowest bidder (address(0) if none)
        uint256 winningBid;           // lowest bid amount in wei
        uint256 winningBidTimestamp;   // block.timestamp of winning bid (tie-breaking)
        uint256 bondAmount;           // bond held from winner (20% of bid)
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

    // Phase 2: Auction events
    event AuctionOpened(uint256 indexed epoch, bytes32 inputHash, uint256 maxBidCeiling);
    event BidSubmitted(uint256 indexed epoch, address indexed runner, uint256 bidAmount);
    event AuctionClosed(uint256 indexed epoch, address indexed winner, uint256 winningBid);
    event EpochExecuted(uint256 indexed epoch, address indexed runner, uint256 bountyPaid);
    event BondForfeited(uint256 indexed epoch, address indexed runner, uint256 bondAmount);
    event AuctionModeChanged(bool enabled);

    // ─── Constants ───────────────────────────────────────────────────────

    uint256 public constant MAX_DONATION_BPS = 1000;       // 10% of treasury
    uint256 public constant MIN_COMMISSION_BPS = 100;      // 1%
    uint256 public constant MAX_COMMISSION_BPS = 9000;     // 90%
    uint256 public constant MIN_MAX_BID = 0.0001 ether;
    uint256 public constant MAX_BID_BPS = 200;             // 2% of treasury
    uint256 public constant MIN_DONATION_AMOUNT = 0.001 ether;
    uint256 public constant COMMISSION_DELAY = 7 days;
    uint256 public constant AUTO_ESCALATION_BPS = 1000;    // 10% increase per missed epoch
    uint256 public constant NUM_NONPROFITS = 3;
    uint256 public constant BOND_BPS = 2000;               // 20% bond on bids

    // Automata DCAP Attestation verifier (same address on all chains via CREATE2)
    IAutomataDcapAttestation public constant DCAP_VERIFIER =
        IAutomataDcapAttestation(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F);

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

    // TEE attestation (Phase 1)
    bool public teeRequired;                          // When true, only TEE-attested submissions accepted
    bytes32 public approvedMrtd;                      // Approved TEE image measurement (MRTD)
    mapping(uint256 => bytes) public epochAttestations; // Raw attestation quotes per epoch

    // Phase 2: Auction state
    bool public auctionEnabled;                              // false = Phase 0/1 mode, true = auction mode
    uint256 public epochDuration;                            // 24 hours production, shorter for testnet
    uint256 public biddingWindow;                            // 1 hour production
    uint256 public executionWindow;                          // 2 hours production
    mapping(uint256 => AuctionState) public auctions;        // epoch -> auction state
    mapping(uint256 => mapping(address => bool)) public hasBid; // epoch -> runner -> has bid

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

        // Default timing (can be overridden via setAuctionTiming)
        epochDuration = 24 hours;
        biddingWindow = 1 hours;
        executionWindow = 2 hours;

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
        require(!auctionEnabled, "Auction enabled: use auction path");
        require(!teeRequired, "TEE required: use submitEpochActionTEE");
        uint256 epoch = currentEpoch;
        require(!epochs[epoch].executed, "Epoch already executed");
        _recordAndExecuteEpoch(epoch, action, reasoning, 0);
    }

    /// @notice Skip the current epoch (no runner bid or missed deadline).
    function skipEpoch() external onlyOwner {
        require(!auctionEnabled, "Auction enabled: epochs managed by auction");
        uint256 epoch = currentEpoch;
        require(!epochs[epoch].executed, "Epoch already executed");

        consecutiveMissedEpochs += 1;
        currentEpoch = epoch + 1;

        // Reset per-epoch counters
        currentEpochInflow = 0;
        currentEpochDonationCount = 0;
        currentEpochCommissions = 0;
    }

    // ─── Owner: TEE Configuration (Phase 1) ─────────────────────────────

    /// @notice Enable or disable TEE attestation requirement.
    /// @dev When enabled, only submitEpochActionTEE() is accepted.
    function setTeeRequired(bool required) external onlyOwner {
        teeRequired = required;
    }

    /// @notice Set the approved TEE image measurement (MRTD).
    /// @dev This is the hash of the TEE enclave image. Only quotes with
    ///      this MRTD will be accepted.
    function setApprovedMrtd(bytes32 mrtd) external onlyOwner {
        approvedMrtd = mrtd;
    }

    // ─── Phase 1: TEE-Attested Epoch Submission ──────────────────────────

    /// @notice Submit an epoch action with TDX attestation proof.
    /// @dev The attestation quote binds (input_hash, action, reasoning) to the TEE.
    ///      The contract verifies the quote on-chain via Automata DCAP.
    /// @param action The encoded action blob.
    /// @param reasoning The agent's chain-of-thought reasoning.
    /// @param attestationQuote Raw TDX DCAP attestation quote.
    function submitEpochActionTEE(
        bytes calldata action,
        bytes calldata reasoning,
        bytes calldata attestationQuote
    ) external payable {
        require(!auctionEnabled, "Auction enabled: use auction path");
        uint256 epoch = currentEpoch;
        require(!epochs[epoch].executed, "Epoch already executed");

        // Verify the attestation quote on-chain via Automata DCAP
        (bool verified, ) = DCAP_VERIFIER.verifyAndAttestOnChain{value: msg.value}(attestationQuote);
        require(verified, "TEE attestation failed");

        // Store attestation for transparency and external verification
        epochAttestations[epoch] = attestationQuote;

        // Execute action and record epoch (shared logic)
        _recordAndExecuteEpoch(epoch, action, reasoning, 0);
    }

    // ─── Phase 2: Reverse Auction ────────────────────────────────────────

    /// @notice Enable or disable auction mode.
    /// @dev When enabled, Phase 0/1 direct submission functions are blocked.
    ///      Epochs are managed through the auction lifecycle instead.
    function setAuctionEnabled(bool enabled) external onlyOwner {
        auctionEnabled = enabled;
        emit AuctionModeChanged(enabled);
    }

    /// @notice Set auction timing parameters (owner-only, for testnet tuning).
    /// @param _epochDuration Total epoch duration (e.g., 24 hours or 5 minutes for testnet)
    /// @param _biddingWindow Duration of the bidding phase
    /// @param _executionWindow Duration of the execution phase after auction closes
    function setAuctionTiming(
        uint256 _epochDuration,
        uint256 _biddingWindow,
        uint256 _executionWindow
    ) external onlyOwner {
        require(_biddingWindow + _executionWindow <= _epochDuration, "Windows exceed epoch duration");
        require(_biddingWindow > 0 && _executionWindow > 0, "Windows must be nonzero");
        epochDuration = _epochDuration;
        biddingWindow = _biddingWindow;
        executionWindow = _executionWindow;
    }

    /// @notice Open the auction for the current epoch. Anyone can call this.
    /// @dev Requires the previous epoch's duration to have elapsed (or this is epoch 1).
    ///      Computes and commits the epoch input hash, which runners use to verify
    ///      their input matches the contract state.
    function startEpoch() external {
        require(auctionEnabled, "Auction not enabled");
        uint256 epoch = currentEpoch;
        require(auctions[epoch].phase == EpochPhase.IDLE, "Epoch already started");

        // Enforce timing: previous epoch must have finished
        if (epoch > 1) {
            AuctionState storage prevAuction = auctions[epoch - 1];
            // Previous epoch must be settled (or never started, which is IDLE)
            if (prevAuction.phase != EpochPhase.IDLE) {
                require(
                    prevAuction.phase == EpochPhase.SETTLED,
                    "Previous epoch not settled"
                );
                require(
                    block.timestamp >= prevAuction.epochStartTime + epochDuration,
                    "Epoch duration not elapsed"
                );
            }
        }

        // Compute and commit the input hash
        bytes32 inputHash = _computeInputHash();
        epochInputHashes[epoch] = inputHash;

        // Open the auction
        auctions[epoch] = AuctionState({
            epochStartTime: block.timestamp,
            phase: EpochPhase.BIDDING,
            bidCount: 0,
            winner: address(0),
            winningBid: 0,
            winningBidTimestamp: 0,
            bondAmount: 0
        });

        emit AuctionOpened(epoch, inputHash, effectiveMaxBid());
    }

    /// @notice Submit a bid for the current epoch's auction.
    /// @dev Must send bond (20% of bid amount) as ETH with the transaction.
    ///      If this bid is lower than the current leader, the previous leader's
    ///      bond is refunded immediately. One bid per runner per epoch.
    /// @param amount The bounty amount the runner is willing to accept (in wei).
    function bid(uint256 amount) external payable {
        require(auctionEnabled, "Auction not enabled");
        uint256 epoch = currentEpoch;
        AuctionState storage auction = auctions[epoch];

        require(auction.phase == EpochPhase.BIDDING, "Not in bidding phase");
        require(block.timestamp < auction.epochStartTime + biddingWindow, "Bidding window closed");
        require(amount > 0, "Bid must be positive");
        require(amount <= effectiveMaxBid(), "Bid exceeds max bid ceiling");
        require(!hasBid[epoch][msg.sender], "Already bid this epoch");

        uint256 requiredBond = (amount * BOND_BPS) / 10000;
        require(msg.value >= requiredBond, "Insufficient bond");

        // Refund excess ETH sent
        uint256 excess = msg.value - requiredBond;

        hasBid[epoch][msg.sender] = true;
        auction.bidCount += 1;

        // Check if this is the new lowest bid
        bool isNewLeader = false;
        if (auction.winner == address(0)) {
            // First bid
            isNewLeader = true;
        } else if (amount < auction.winningBid) {
            // Lower bid
            isNewLeader = true;
        } else if (amount == auction.winningBid && block.timestamp < auction.winningBidTimestamp) {
            // Same amount, earlier timestamp (tie-break)
            isNewLeader = true;
        }

        if (isNewLeader) {
            // Refund previous leader's bond (if any)
            address previousWinner = auction.winner;
            uint256 previousBond = auction.bondAmount;

            // Update state before external call (checks-effects-interactions)
            auction.winner = msg.sender;
            auction.winningBid = amount;
            auction.winningBidTimestamp = block.timestamp;
            auction.bondAmount = requiredBond;

            if (previousWinner != address(0) && previousBond > 0) {
                (bool refunded, ) = payable(previousWinner).call{value: previousBond}("");
                require(refunded, "Bond refund failed");
            }
        } else {
            // Not the new leader — refund bond immediately
            excess += requiredBond;
        }

        // Refund any excess ETH
        if (excess > 0) {
            (bool sent, ) = payable(msg.sender).call{value: excess}("");
            require(sent, "Excess refund failed");
        }

        emit BidSubmitted(epoch, msg.sender, amount);
    }

    /// @notice Close the auction and transition to execution phase.
    /// @dev Anyone can call this after the bidding window has elapsed.
    ///      If no bids were received, the epoch is skipped.
    function closeAuction() external {
        require(auctionEnabled, "Auction not enabled");
        uint256 epoch = currentEpoch;
        AuctionState storage auction = auctions[epoch];

        require(auction.phase == EpochPhase.BIDDING, "Not in bidding phase");
        require(block.timestamp >= auction.epochStartTime + biddingWindow, "Bidding window not closed");

        if (auction.bidCount == 0) {
            // No bids — skip this epoch
            auction.phase = EpochPhase.SETTLED;
            consecutiveMissedEpochs += 1;
            currentEpoch = epoch + 1;

            // Reset per-epoch counters
            currentEpochInflow = 0;
            currentEpochDonationCount = 0;
            currentEpochCommissions = 0;
        } else {
            // Winner determined — enter execution phase
            auction.phase = EpochPhase.EXECUTION;
            emit AuctionClosed(epoch, auction.winner, auction.winningBid);
        }
    }

    /// @notice Submit the auction result (winner only).
    /// @dev The winner submits the attested inference result. On success,
    ///      the action is executed, the bounty is paid from treasury, and
    ///      the bond is refunded.
    /// @param action The encoded action blob.
    /// @param reasoning The agent's chain-of-thought reasoning.
    /// @param attestationQuote Raw TDX DCAP attestation quote.
    function submitAuctionResult(
        bytes calldata action,
        bytes calldata reasoning,
        bytes calldata attestationQuote
    ) external payable {
        require(auctionEnabled, "Auction not enabled");
        uint256 epoch = currentEpoch;
        AuctionState storage auction = auctions[epoch];

        require(auction.phase == EpochPhase.EXECUTION, "Not in execution phase");
        require(msg.sender == auction.winner, "Not the auction winner");
        require(
            block.timestamp < auction.epochStartTime + biddingWindow + executionWindow,
            "Execution window expired"
        );

        // Verify TEE attestation
        (bool verified, ) = DCAP_VERIFIER.verifyAndAttestOnChain{value: msg.value}(attestationQuote);
        require(verified, "TEE attestation failed");
        epochAttestations[epoch] = attestationQuote;

        // Capture bounty and bond amounts before state changes
        uint256 bountyAmount = auction.winningBid;
        uint256 bondRefund = auction.bondAmount;
        address winner = auction.winner;

        // Mark auction as settled
        auction.phase = EpochPhase.SETTLED;

        // Execute action and record epoch
        _recordAndExecuteEpoch(epoch, action, reasoning, bountyAmount);

        // Pay bounty from treasury + refund bond
        uint256 totalPayout = bountyAmount + bondRefund;
        totalBountiesPaid += bountyAmount;

        (bool paid, ) = payable(winner).call{value: totalPayout}("");
        require(paid, "Bounty payment failed");

        emit EpochExecuted(epoch, winner, bountyAmount);
    }

    /// @notice Forfeit the winner's bond after the execution window expires.
    /// @dev Anyone can call this to advance the epoch when the winner fails to deliver.
    ///      The bond stays in the contract as additional treasury.
    function forfeitBond() external {
        require(auctionEnabled, "Auction not enabled");
        uint256 epoch = currentEpoch;
        AuctionState storage auction = auctions[epoch];

        require(auction.phase == EpochPhase.EXECUTION, "Not in execution phase");
        require(
            block.timestamp >= auction.epochStartTime + biddingWindow + executionWindow,
            "Execution window not expired"
        );

        address forfeitedRunner = auction.winner;
        uint256 forfeitedBond = auction.bondAmount;

        // Mark auction as settled
        auction.phase = EpochPhase.SETTLED;

        // Skip the epoch
        consecutiveMissedEpochs += 1;
        currentEpoch = epoch + 1;

        // Reset per-epoch counters
        currentEpochInflow = 0;
        currentEpochDonationCount = 0;
        currentEpochCommissions = 0;

        // Bond stays in contract as treasury (no transfer needed)
        emit BondForfeited(epoch, forfeitedRunner, forfeitedBond);
    }

    // ─── Internal: Epoch Recording ─────────────────────────────────────

    function _recordAndExecuteEpoch(
        uint256 epoch,
        bytes calldata action,
        bytes calldata reasoning,
        uint256 bountyPaid
    ) internal {
        uint256 treasuryBefore = address(this).balance;
        _executeAction(epoch, action);
        uint256 treasuryAfter = address(this).balance;

        epochs[epoch] = EpochRecord({
            timestamp: block.timestamp,
            action: action,
            reasoning: reasoning,
            treasuryBefore: treasuryBefore,
            treasuryAfter: treasuryAfter,
            bountyPaid: bountyPaid,
            executed: true
        });

        if (epoch % 5 == 0) {
            balanceSnapshots[epoch] = treasuryAfter;
        }

        emit DiaryEntry(epoch, reasoning, action, treasuryBefore, treasuryAfter);

        currentEpochInflow = 0;
        currentEpochDonationCount = 0;
        currentEpochCommissions = 0;
        consecutiveMissedEpochs = 0;
        currentEpoch = epoch + 1;
    }

    // ─── Internal: Action Execution ──────────────────────────────────────

    function _executeAction(uint256 epoch, bytes calldata action) internal {
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

    // ─── Internal: Input Hash ────────────────────────────────────────────

    /// @notice Deterministically compute the epoch input hash from contract state.
    /// @dev Runners reconstruct this hash from on-chain state to verify their input.
    function _computeInputHash() internal view returns (bytes32) {
        // Split into two hashes to avoid stack-too-deep
        bytes32 stateHash = keccak256(abi.encode(
            currentEpoch,
            address(this).balance,
            commissionRateBps,
            maxBid,
            consecutiveMissedEpochs,
            lastDonationEpoch,
            lastCommissionChangeEpoch
        ));
        return keccak256(abi.encode(
            stateHash,
            currentEpochInflow,
            currentEpochDonationCount,
            nonprofits[1].totalDonated,
            nonprofits[2].totalDonated,
            nonprofits[3].totalDonated
        ));
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

    /// @notice Compute the epoch input hash from current contract state.
    /// @dev Public view for runners to verify their input matches.
    function computeInputHash() external view returns (bytes32) {
        return _computeInputHash();
    }

    /// @notice Get the current auction state for an epoch.
    function getAuctionState(uint256 epoch) external view returns (
        uint256 epochStartTime,
        EpochPhase phase,
        uint256 bidCount,
        address winner,
        uint256 winningBid,
        uint256 bondAmount
    ) {
        AuctionState storage a = auctions[epoch];
        return (a.epochStartTime, a.phase, a.bidCount, a.winner, a.winningBid, a.bondAmount);
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
