// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IProofVerifier.sol";
import "./interfaces/IInvestmentManager.sol";
import "./interfaces/IWorldView.sol";

/// @title The Human Fund
/// @notice An autonomous AI agent that manages a charitable treasury on Base.
/// @dev Each epoch (~24 hours), the runner submits an action chosen by the AI model.
///      The contract validates bounds, executes the action, and emits a DiaryEntry event.
contract TheHumanFund {
    // ─── Errors ──────────────────────────────────────────────────────────

    error Unauthorized();
    error InvalidParams();
    error WrongPhase();
    error TimingError();
    error TransferFailed();
    error AlreadyDone();
    error ProofFailed();

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

    struct DonorMessage {
        address sender;
        uint256 amount;        // ETH donated with this message
        string text;
        uint256 epoch;         // epoch when the message was received
    }

    // Auction types
    enum EpochPhase { IDLE, BIDDING, EXECUTION, SETTLED }

    struct AuctionState {
        uint256 epochStartTime;       // block.timestamp when auction opened
        EpochPhase phase;             // current lifecycle phase
        uint256 bidCount;             // number of bids received
        address winner;               // lowest bidder (address(0) if none)
        uint256 winningBid;           // lowest bid amount in wei
        uint256 winningBidTimestamp;   // block.timestamp of winning bid (tie-breaking)
        uint256 bondAmount;           // bond held from winner (20% of bid)
        uint256 randomnessSeed;       // block.prevrandao captured at closeAuction()
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
    event CommissionPaid(address indexed referrer, uint256 amount, uint256 referralCodeId);
    event EpochStarted(uint256 indexed epoch, bytes32 inputHash);

    // Auction events
    event AuctionOpened(uint256 indexed epoch, bytes32 inputHash, uint256 maxBidCeiling);
    event BidSubmitted(uint256 indexed epoch, address indexed runner, uint256 bidAmount);
    event AuctionClosed(uint256 indexed epoch, address indexed winner, uint256 winningBid);
    event EpochExecuted(uint256 indexed epoch, address indexed runner, uint256 bountyPaid);
    event BondForfeited(uint256 indexed epoch, address indexed runner, uint256 bondAmount);
    event AuctionModeChanged(bool enabled);
    event ActionRejected(uint256 indexed epoch, bytes action, string reason);
    event MessageReceived(address indexed sender, uint256 amount, uint256 indexed messageId);

    // ─── Constants ───────────────────────────────────────────────────────

    uint256 public constant MAX_DONATION_BPS = 1000;       // 10% of treasury
    uint256 public constant MIN_COMMISSION_BPS = 100;      // 1%
    uint256 public constant MAX_COMMISSION_BPS = 9000;     // 90%
    uint256 public constant MIN_MAX_BID = 0.0001 ether;
    uint256 public constant MAX_BID_BPS = 200;             // 2% of treasury
    uint256 public constant MIN_DONATION_AMOUNT = 0.001 ether;
    uint256 public constant AUTO_ESCALATION_BPS = 1000;    // 10% increase per missed epoch
    uint256 public constant NUM_NONPROFITS = 3;
    uint256 public constant BOND_BPS = 2000;               // 20% bond on bids
    uint256 public constant MIN_MESSAGE_DONATION = 0.01 ether;  // 10x normal min to prevent spam
    uint256 public constant MAX_MESSAGE_LENGTH = 280;
    uint256 public constant MAX_MESSAGES_PER_EPOCH = 20;

    // Note: DCAP verification now handled by the AttestationVerifier contract (see setVerifier)

    // ─── State ───────────────────────────────────────────────────────────

    address public owner;           // Deployer is the authorized runner for direct submission
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

    // Per-epoch inflow tracking (reset each epoch)
    uint256 public currentEpochInflow;
    uint256 public currentEpochDonationCount;
    uint256 public currentEpochCommissions;


    // Proof verifier registry — supports TEE (TDX) and future ZK verifiers
    mapping(uint8 => IProofVerifier) public verifiers;
    mapping(uint256 => bytes) public epochProofs; // Raw proofs per epoch (attestation quotes, ZK proofs)

    // Base input hashes (pre-seed) — extended with randomness seed at closeAuction()
    mapping(uint256 => bytes32) public epochBaseInputHashes;

    // Per-epoch content hashes — cached at settlement for cheap history verification
    mapping(uint256 => bytes32) public epochContentHashes;

    // Investment manager (separate contract — see InvestmentManager.sol)
    IInvestmentManager public investmentManager;

    // Worldview (separate contract — see WorldView.sol)
    IWorldView public worldView;

    /// @notice SHA-256 hash of the approved system prompt. The TEE must hash
    ///         the prompt it receives and include it in REPORTDATA. The contract
    ///         verifies it matches this value. Owner can update to change the prompt.
    bytes32 public approvedPromptHash;

    // Donor messages
    DonorMessage[] public messages;
    mapping(uint256 => bytes32) public messageHashes;  // messageId => keccak256(sender, amount, text, epoch)
    uint256 public messageHead;  // index of first unread message

    // Auction state
    bool public auctionEnabled;                              // false = direct submission, true = auction mode
    uint256 public epochDuration;                            // 24 hours production, shorter for testnet
    uint256 public biddingWindow;                            // 1 hour production
    uint256 public executionWindow;                          // 2 hours production
    mapping(uint256 => AuctionState) public auctions;        // epoch -> auction state
    mapping(uint256 => mapping(address => bool)) public hasBid; // epoch -> runner -> has bid

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(
        string[3] memory _names,
        address payable[3] memory _addrs,
        uint256 _initialCommissionBps,
        uint256 _initialMaxBid
    ) payable {
        if (_initialCommissionBps < MIN_COMMISSION_BPS || _initialCommissionBps > MAX_COMMISSION_BPS) revert InvalidParams();
        if (_initialMaxBid < MIN_MAX_BID) revert InvalidParams();

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
            if (_addrs[i] == address(0)) revert InvalidParams();
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
        if (msg.value < MIN_DONATION_AMOUNT) revert InvalidParams();

        uint256 commission = 0;

        if (referralCodeId > 0 && referralCodes[referralCodeId].exists) {
            commission = _payCommission(referralCodeId);
        }

        totalInflows += msg.value;
        currentEpochInflow += msg.value;
        currentEpochDonationCount += 1;

        emit DonationReceived(msg.sender, msg.value, referralCodeId, commission);
    }

    /// @notice Donate ETH to the fund with a message for the AI agent.
    /// @param referralCodeId The referral code ID (0 for no referral).
    /// @param message A message for the agent (max 280 characters, requires >= 0.01 ETH).
    function donateWithMessage(uint256 referralCodeId, string calldata message) external payable {
        if (msg.value < MIN_MESSAGE_DONATION) revert InvalidParams();

        // Process donation (same logic as donate)
        uint256 commission = 0;
        if (referralCodeId > 0 && referralCodes[referralCodeId].exists) {
            commission = _payCommission(referralCodeId);
        }

        totalInflows += msg.value;
        currentEpochInflow += msg.value;
        currentEpochDonationCount += 1;

        // Store message (truncate to MAX_MESSAGE_LENGTH bytes)
        bytes memory msgBytes = bytes(message);
        string memory truncated = message;
        if (msgBytes.length > MAX_MESSAGE_LENGTH) {
            // Truncate raw bytes and convert back
            bytes memory cut = new bytes(MAX_MESSAGE_LENGTH);
            for (uint256 i = 0; i < MAX_MESSAGE_LENGTH; i++) {
                cut[i] = msgBytes[i];
            }
            truncated = string(cut);
        }

        uint256 messageId = messages.length;
        messages.push(DonorMessage({
            sender: msg.sender,
            amount: msg.value,
            text: truncated,
            epoch: currentEpoch
        }));
        messageHashes[messageId] = keccak256(abi.encode(msg.sender, msg.value, truncated, currentEpoch));

        emit DonationReceived(msg.sender, msg.value, referralCodeId, commission);
        emit MessageReceived(msg.sender, msg.value, messageId);
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

    /// @dev Pay commission to the referrer immediately.
    function _payCommission(uint256 referralCodeId) internal returns (uint256 commission) {
        commission = (msg.value * commissionRateBps) / 10000;
        address payable referrer = payable(referralCodes[referralCodeId].owner);
        referralCodes[referralCodeId].totalReferred += msg.value;
        referralCodes[referralCodeId].referralCount += 1;
        totalCommissionsPaid += commission;
        (bool sent, ) = referrer.call{value: commission}("");
        if (!sent) revert TransferFailed();
        emit CommissionPaid(referrer, commission, referralCodeId);
    }

    // ─── Owner: Direct Epoch Submission ───────────────────────────────────

    /// @notice Submit the AI agent's action for the current epoch.
    /// @dev Owner-only direct submission (no auction, no proof required).
    /// @param action The encoded action blob.
    /// @param reasoning The agent's chain-of-thought reasoning.
    function submitEpochAction(bytes calldata action, bytes calldata reasoning) external onlyOwner {
        if (auctionEnabled) revert WrongPhase();
        uint256 epoch = currentEpoch;
        if (epochs[epoch].executed) revert AlreadyDone();
        _recordAndExecute(epoch, action, reasoning, 0);
    }

    /// @notice Submit the AI agent's action with an optional worldview update.
    /// @param action The encoded action blob.
    /// @param reasoning The agent's chain-of-thought reasoning.
    /// @param policySlot The worldview slot to update (0-9), or -1 to skip.
    /// @param policyText The policy text (max 280 chars). Ignored if policySlot is -1.
    function submitEpochActionWithPolicy(
        bytes calldata action,
        bytes calldata reasoning,
        int8 policySlot,
        string calldata policyText
    ) external onlyOwner {
        if (auctionEnabled) revert WrongPhase();
        uint256 epoch = currentEpoch;
        if (epochs[epoch].executed) revert AlreadyDone();
        _applyPolicyUpdate(policySlot, policyText);
        _recordAndExecute(epoch, action, reasoning, 0);
    }

    /// @notice Skip the current epoch (no runner bid or missed deadline).
    function skipEpoch() external onlyOwner {
        if (auctionEnabled) revert WrongPhase();
        uint256 epoch = currentEpoch;
        if (epochs[epoch].executed) revert AlreadyDone();

        consecutiveMissedEpochs += 1;
        currentEpoch = epoch + 1;

        // Reset per-epoch counters
        currentEpochInflow = 0;
        currentEpochDonationCount = 0;
        currentEpochCommissions = 0;
    }

    // ─── Owner: Proof Verifier Registry ──────────────────────────────────

    event VerifierApproved(uint8 indexed verifierId, address verifier);
    event VerifierRevoked(uint8 indexed verifierId);

    /// @notice Register a proof verifier (TEE, ZK, etc.) at a given ID.
    /// @param id Verifier ID (1+ recommended; 0 is valid but unusual).
    /// @param _verifier The IProofVerifier contract address.
    function approveVerifier(uint8 id, address _verifier) external onlyOwner {
        if (_verifier == address(0)) revert InvalidParams();
        verifiers[id] = IProofVerifier(_verifier);
        emit VerifierApproved(id, _verifier);
    }

    /// @notice Remove a proof verifier from the registry.
    function revokeVerifier(uint8 id) external onlyOwner {
        if (address(verifiers[id]) == address(0)) revert InvalidParams();
        delete verifiers[id];
        emit VerifierRevoked(id);
    }

    /// @notice Set the investment manager contract address.
    function setInvestmentManager(address _im) external onlyOwner {
        investmentManager = IInvestmentManager(_im);
    }

    function setWorldView(address _wv) external onlyOwner {
        worldView = IWorldView(_wv);
    }

    /// @notice Set the approved system prompt hash.
    /// @dev The TEE hashes the prompt it receives and includes it in REPORTDATA.
    ///      The contract verifies it matches this value during auction settlement.
    function setApprovedPromptHash(bytes32 _hash) external onlyOwner {
        approvedPromptHash = _hash;
    }

    /// @notice Seed multiple worldview policies at once. Only callable by owner.
    /// @dev Intended for initial setup before the fund goes live.
    function seedWorldView(uint256[] calldata slots, string[] calldata policies) external onlyOwner {
        require(address(worldView) != address(0), "no worldview");
        require(slots.length == policies.length, "length mismatch");
        for (uint256 i = 0; i < slots.length; i++) {
            worldView.setPolicy(slots[i], policies[i]);
        }
    }

    // ─── Reverse Auction ──────────────────────────────────────────────────

    /// @notice Enable or disable auction mode.
    /// @dev When enabled, owner-only direct submission functions are blocked.
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
        if (_biddingWindow + _executionWindow > _epochDuration) revert InvalidParams();
        if (_biddingWindow == 0 || _executionWindow == 0) revert InvalidParams();
        epochDuration = _epochDuration;
        biddingWindow = _biddingWindow;
        executionWindow = _executionWindow;
    }

    /// @notice Open the auction for the current epoch. Anyone can call this.
    /// @dev Requires the previous epoch's duration to have elapsed (or this is epoch 1).
    ///      Computes and commits the epoch input hash, which runners use to verify
    ///      their input matches the contract state.
    function startEpoch() external {
        if (!auctionEnabled) revert WrongPhase();
        uint256 epoch = currentEpoch;
        if (auctions[epoch].phase != EpochPhase.IDLE) revert AlreadyDone();

        // Enforce timing: previous epoch must have finished.
        // If the previous winner failed to deliver and the execution window has passed,
        // auto-forfeit their bond so we can start the next epoch without a separate call.
        if (epoch > 1) {
            AuctionState storage prevAuction = auctions[epoch - 1];
            if (prevAuction.phase == EpochPhase.EXECUTION) {
                // Auto-forfeit if execution window expired
                if (block.timestamp < prevAuction.epochStartTime + biddingWindow + executionWindow)
                    revert TimingError();
                _forfeitBond(epoch - 1, prevAuction);
            }
            if (prevAuction.phase == EpochPhase.SETTLED) {
                if (block.timestamp < prevAuction.epochStartTime + epochDuration) revert TimingError();
            }
        }

        // Compute and commit the base input hash (seed added at closeAuction)
        bytes32 baseInputHash = _computeInputHash();
        epochBaseInputHashes[epoch] = baseInputHash;

        // Open the auction
        auctions[epoch] = AuctionState({
            epochStartTime: block.timestamp,
            phase: EpochPhase.BIDDING,
            bidCount: 0,
            winner: address(0),
            winningBid: 0,
            winningBidTimestamp: 0,
            bondAmount: 0,
            randomnessSeed: 0
        });

        emit AuctionOpened(epoch, baseInputHash, effectiveMaxBid());
    }

    /// @notice Submit a bid for the current epoch's auction.
    /// @dev Must send bond (20% of bid amount) as ETH with the transaction.
    ///      If this bid is lower than the current leader, the previous leader's
    ///      bond is refunded immediately. One bid per runner per epoch.
    /// @param amount The bounty amount the runner is willing to accept (in wei).
    function bid(uint256 amount) external payable {
        if (!auctionEnabled) revert WrongPhase();
        uint256 epoch = currentEpoch;
        AuctionState storage auction = auctions[epoch];

        if (auction.phase != EpochPhase.BIDDING) revert WrongPhase();
        if (block.timestamp >= auction.epochStartTime + biddingWindow) revert TimingError();
        if (amount == 0) revert InvalidParams();
        if (amount > effectiveMaxBid()) revert InvalidParams();
        if (hasBid[epoch][msg.sender]) revert AlreadyDone();

        uint256 requiredBond = (amount * BOND_BPS) / 10000;
        if (msg.value < requiredBond) revert InvalidParams();

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
                if (!refunded) revert TransferFailed();
            }
        } else {
            // Not the new leader — refund bond immediately
            excess += requiredBond;
        }

        // Refund any excess ETH
        if (excess > 0) {
            (bool sent, ) = payable(msg.sender).call{value: excess}("");
            if (!sent) revert TransferFailed();
        }

        emit BidSubmitted(epoch, msg.sender, amount);
    }

    /// @notice Close the auction and transition to execution phase.
    /// @dev Anyone can call this after the bidding window has elapsed.
    ///      If no bids were received, the epoch is skipped.
    function closeAuction() external {
        if (!auctionEnabled) revert WrongPhase();
        uint256 epoch = currentEpoch;
        AuctionState storage auction = auctions[epoch];

        if (auction.phase != EpochPhase.BIDDING) revert WrongPhase();
        if (block.timestamp < auction.epochStartTime + biddingWindow) revert TimingError();

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
            auction.randomnessSeed = block.prevrandao;

            // Extend base input hash with randomness seed to produce final input hash
            epochInputHashes[epoch] = keccak256(abi.encodePacked(
                epochBaseInputHashes[epoch],
                block.prevrandao
            ));

            emit AuctionClosed(epoch, auction.winner, auction.winningBid);
        }
    }

    /// @notice Submit the auction result (winner only).
    /// @dev The winner submits a proof (TEE attestation, ZK proof, etc.) that binds
    ///      the epoch inputs to the submitted outputs. On success, the bounty is paid,
    ///      the bond is refunded, and the action is executed.
    /// @param action The encoded action blob.
    /// @param reasoning The agent's chain-of-thought reasoning.
    /// @param proof Opaque proof bytes (attestation quote for TDX, ZK proof for future).
    /// @param verifierId Which registered verifier to route the proof to.
    function submitAuctionResult(
        bytes calldata action,
        bytes calldata reasoning,
        bytes calldata proof,
        uint8 verifierId,
        int8 policySlot,
        string calldata policyText
    ) external payable {
        if (!auctionEnabled) revert WrongPhase();

        // Verify proof, settle auction, and pay prover (scoped to reduce stack depth)
        uint256 bountyAmount;
        {
            IProofVerifier v = verifiers[verifierId];
            if (address(v) == address(0)) revert InvalidParams();
            // outputHash binds action + reasoning + approved prompt.
            // The TEE computes: keccak256(sha256(action) || sha256(reasoning) || sha256(prompt))
            // and the prompt hash must equal approvedPromptHash.
            bytes32 outputHash = keccak256(abi.encodePacked(
                sha256(action), sha256(reasoning), approvedPromptHash
            ));

            uint256 bondRefund;
            address winner;
            (bountyAmount, bondRefund, winner) =
                _verifyAndSettleAuction(currentEpoch, proof, outputHash, v);
            _payProver(winner, bountyAmount, bondRefund);
            emit EpochExecuted(currentEpoch, winner, bountyAmount);
        }

        // Apply optional worldview update + execute action + record epoch
        _applyPolicyUpdate(policySlot, policyText);
        _recordAndExecute(currentEpoch, action, reasoning, bountyAmount);
    }

    /// @dev Pay the auction winner their bounty + bond refund.
    function _payProver(address winner, uint256 bountyAmount, uint256 bondRefund) internal {
        totalBountiesPaid += bountyAmount;
        (bool paid, ) = payable(winner).call{value: bountyAmount + bondRefund}("");
        if (!paid) revert TransferFailed();
    }

    /// @dev Verify proof and settle auction. Returns bounty, bond, winner.
    function _verifyAndSettleAuction(
        uint256 epoch,
        bytes calldata proof,
        bytes32 outputHash,
        IProofVerifier v
    ) internal returns (uint256 bountyAmount, uint256 bondRefund, address winner) {
        AuctionState storage auction = auctions[epoch];
        if (auction.phase != EpochPhase.EXECUTION) revert WrongPhase();
        if (msg.sender != auction.winner) revert Unauthorized();
        if (block.timestamp >= auction.epochStartTime + biddingWindow + executionWindow) revert TimingError();

        if (!v.verify{value: msg.value}(epochInputHashes[epoch], outputHash, proof))
            revert ProofFailed();
        epochProofs[epoch] = proof;

        bountyAmount = auction.winningBid;
        bondRefund = auction.bondAmount;
        winner = auction.winner;
        auction.phase = EpochPhase.SETTLED;
    }

    /// @notice Forfeit the winner's bond after the execution window expires.
    /// @dev Anyone can call this to advance the epoch when the winner fails to deliver.
    ///      The bond stays in the contract as additional treasury.
    ///      Note: startEpoch() will auto-forfeit if needed, so calling this directly
    ///      is only necessary if you want to forfeit without immediately starting a new epoch.
    function forfeitBond() external {
        if (!auctionEnabled) revert WrongPhase();
        uint256 epoch = currentEpoch;
        AuctionState storage auction = auctions[epoch];

        if (auction.phase != EpochPhase.EXECUTION) revert WrongPhase();
        if (block.timestamp < auction.epochStartTime + biddingWindow + executionWindow) revert TimingError();

        _forfeitBond(epoch, auction);
    }

    /// @dev Internal forfeit logic shared by forfeitBond() and startEpoch().
    function _forfeitBond(uint256 epoch, AuctionState storage auction) internal {
        address forfeitedRunner = auction.winner;
        uint256 forfeitedBond = auction.bondAmount;

        auction.phase = EpochPhase.SETTLED;

        consecutiveMissedEpochs += 1;
        currentEpoch = epoch + 1;

        currentEpochInflow = 0;
        currentEpochDonationCount = 0;
        currentEpochCommissions = 0;

        emit BondForfeited(epoch, forfeitedRunner, forfeitedBond);
    }

    // ─── Internal: Epoch Recording ─────────────────────────────────────

    /// @dev Apply optional worldview policy update. Best-effort — failures
    ///      are silently ignored so they can't block prover payment or epoch recording.
    function _applyPolicyUpdate(int8 policySlot, string memory policyText) internal {
        if (policySlot >= 0 && address(worldView) != address(0)) {
            try worldView.setPolicy(uint256(uint8(policySlot)), policyText) {
                // success
            } catch {
                // Silently ignore — invalid slot, too-long text, etc.
            }
        }
    }

    function _recordAndExecute(
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

        emit DiaryEntry(epoch, reasoning, action, treasuryBefore, treasuryAfter);

        // Cache content hash for this epoch — used by _computeInputHash() to verify
        // that the TEE sees the same history as on-chain without re-hashing calldata.
        epochContentHashes[epoch] = keccak256(abi.encode(
            keccak256(reasoning), keccak256(action), treasuryBefore, treasuryAfter
        ));

        // Advance message head (up to MAX_MESSAGES_PER_EPOCH)
        uint256 unread = messages.length - messageHead;
        if (unread > MAX_MESSAGES_PER_EPOCH) {
            messageHead += MAX_MESSAGES_PER_EPOCH;
        } else {
            messageHead = messages.length;
        }

        currentEpochInflow = 0;
        currentEpochDonationCount = 0;
        currentEpochCommissions = 0;
        consecutiveMissedEpochs = 0;
        currentEpoch = epoch + 1;
    }

    // ─── Internal: Action Execution ──────────────────────────────────────

    /// @dev Execute the model's chosen action. Out-of-bounds parameters cause
    ///      a noop (not a revert) — the prover did their job, the model made
    ///      a bad choice. The raw action bytes are still recorded in the epoch
    ///      history so future prompts can see what was attempted.
    function _executeAction(uint256 epoch, bytes calldata action) internal {
        if (action.length < 1) {
            emit ActionRejected(epoch, action, "empty");
            return;
        }

        uint8 actionType = uint8(action[0]);

        if (actionType == 0) {
            // noop — do nothing
            return;
        } else if (actionType == 1) {
            // donate
            if (action.length < 65) {
                emit ActionRejected(epoch, action, "malformed");
                return;
            }
            (uint256 nonprofitId, uint256 amount) = abi.decode(action[1:], (uint256, uint256));
            if (!_executeDonate(epoch, nonprofitId, amount)) {
                emit ActionRejected(epoch, action, "out_of_bounds");
            }
        } else if (actionType == 2) {
            // set_commission_rate
            if (action.length < 33) {
                emit ActionRejected(epoch, action, "malformed");
                return;
            }
            uint256 rateBps = abi.decode(action[1:], (uint256));
            if (!_executeSetCommissionRate(epoch, rateBps)) {
                emit ActionRejected(epoch, action, "out_of_bounds");
            }
        } else if (actionType == 3) {
            // set_max_bid
            if (action.length < 33) {
                emit ActionRejected(epoch, action, "malformed");
                return;
            }
            uint256 amount = abi.decode(action[1:], (uint256));
            if (!_executeSetMaxBid(epoch, amount)) {
                emit ActionRejected(epoch, action, "out_of_bounds");
            }
        } else if (actionType == 4) {
            // invest — delegate to InvestmentManager
            if (action.length < 65 || address(investmentManager) == address(0)) {
                emit ActionRejected(epoch, action, "invest_err");
                return;
            }
            (uint256 pid, uint256 amt) = abi.decode(action[1:], (uint256, uint256));
            try investmentManager.deposit{value: amt}(pid, amt) {
                // success
            } catch {
                emit ActionRejected(epoch, action, "invest_fail");
            }
        } else if (actionType == 5) {
            // withdraw — delegate to InvestmentManager
            if (action.length < 65 || address(investmentManager) == address(0)) {
                emit ActionRejected(epoch, action, "withdraw_err");
                return;
            }
            (uint256 pid, uint256 amt) = abi.decode(action[1:], (uint256, uint256));
            try investmentManager.withdraw(pid, amt) {
                // success — ETH comes back to this contract via receive()
            } catch {
                emit ActionRejected(epoch, action, "withdraw_fail");
            }
        } else if (actionType == 6) {
            // set_guiding_policy — delegate to WorldView contract
            if (action.length < 33 || address(worldView) == address(0)) {
                emit ActionRejected(epoch, action, "policy_err");
                return;
            }
            // Forward raw ABI-encoded (uint256 slot, string policy) to WorldView
            (bool ok, ) = address(worldView).call(
                abi.encodePacked(IWorldView.setPolicy.selector, action[1:])
            );
            if (!ok) {
                emit ActionRejected(epoch, action, "policy_fail");
            }
        } else {
            emit ActionRejected(epoch, action, "unknown_type");
        }
    }

    /// @dev Returns false if parameters are out of bounds (action becomes noop).
    function _executeDonate(uint256 epoch, uint256 nonprofitId, uint256 amount) internal returns (bool) {
        if (nonprofitId < 1 || nonprofitId > NUM_NONPROFITS) return false;
        if (amount == 0) return false;

        uint256 maxDonation = (address(this).balance * MAX_DONATION_BPS) / 10000;
        if (amount > maxDonation) return false;

        Nonprofit storage np = nonprofits[nonprofitId];
        (bool sent, ) = np.addr.call{value: amount}("");
        if (!sent) return false;

        np.totalDonated += amount;
        np.donationCount += 1;
        totalDonatedToNonprofits += amount;
        lastDonationEpoch = epoch;

        emit NonprofitDonation(epoch, nonprofitId, amount);
        return true;
    }

    /// @dev Returns false if parameters are out of bounds (action becomes noop).
    function _executeSetCommissionRate(uint256 epoch, uint256 rateBps) internal returns (bool) {
        if (rateBps < MIN_COMMISSION_BPS || rateBps > MAX_COMMISSION_BPS) return false;
        commissionRateBps = rateBps;
        lastCommissionChangeEpoch = epoch;
        emit CommissionRateChanged(epoch, rateBps);
        return true;
    }

    /// @dev Returns false if parameters are out of bounds (action becomes noop).
    function _executeSetMaxBid(uint256 epoch, uint256 amount) internal returns (bool) {
        if (amount < MIN_MAX_BID) return false;
        uint256 maxAllowed = (address(this).balance * MAX_BID_BPS) / 10000;
        if (amount > maxAllowed) return false;
        maxBid = amount;
        emit MaxBidChanged(epoch, amount);
        return true;
    }

    // ─── Internal: Input Hash ────────────────────────────────────────────

    uint256 public constant MAX_HISTORY_ENTRIES = 10;

    /// @notice Deterministically compute the epoch input hash from contract state.
    /// @dev The TEE computes this same hash from the structured data it receives
    ///      and includes it in the TDX REPORTDATA. The contract then verifies:
    ///      1. The TDX attestation is genuine (DCAP + approved image)
    ///      2. The REPORTDATA contains this hash — proving the TEE saw these inputs
    ///      The TEE is a dumb signer: it hashes whatever it's given. The contract
    ///      is the verifier that checks the hash matches real on-chain state.
    ///      All heavy data (reasoning, messages) uses pre-cached hashes.
    function _computeInputHash() internal view returns (bytes32) {
        bytes32 stateHash = _hashState();
        bytes32 nonprofitHash = _hashNonprofits();
        bytes32 investHash = address(investmentManager) != address(0)
            ? investmentManager.stateHash()
            : bytes32(0);
        bytes32 worldviewHash = address(worldView) != address(0)
            ? worldView.stateHash()
            : bytes32(0);
        bytes32 msgHash = _hashUnreadMessages();
        bytes32 histHash = _hashRecentHistory();
        return keccak256(abi.encode(
            stateHash,
            nonprofitHash,
            investHash,
            worldviewHash,
            msgHash,
            histHash
        ));
    }

    /// @dev Hash current state variables (all cheap SLOADs).
    function _hashState() internal view returns (bytes32) {
        return keccak256(abi.encode(
            currentEpoch,
            address(this).balance,
            commissionRateBps,
            maxBid,
            consecutiveMissedEpochs,
            lastDonationEpoch,
            lastCommissionChangeEpoch,
            totalInflows,
            totalDonatedToNonprofits,
            totalCommissionsPaid,
            totalBountiesPaid,
            currentEpochInflow,
            currentEpochDonationCount
        ));
    }

    /// @dev Hash nonprofit state (3 entries, all integers).
    function _hashNonprofits() internal view returns (bytes32) {
        return keccak256(abi.encode(
            nonprofits[1].name, nonprofits[1].addr, nonprofits[1].totalDonated, nonprofits[1].donationCount,
            nonprofits[2].name, nonprofits[2].addr, nonprofits[2].totalDonated, nonprofits[2].donationCount,
            nonprofits[3].name, nonprofits[3].addr, nonprofits[3].totalDonated, nonprofits[3].donationCount
        ));
    }

    /// @dev Hash unread messages using pre-cached per-message hashes.
    function _hashUnreadMessages() internal view returns (bytes32) {
        uint256 unread = messages.length - messageHead;
        uint256 count = unread > MAX_MESSAGES_PER_EPOCH ? MAX_MESSAGES_PER_EPOCH : unread;
        if (count == 0) return bytes32(0);

        bytes memory packed;
        for (uint256 i = 0; i < count; i++) {
            packed = abi.encodePacked(packed, messageHashes[messageHead + i]);
        }
        return keccak256(packed);
    }

    /// @dev Hash the last N epoch content hashes (pre-cached at settlement).
    function _hashRecentHistory() internal view returns (bytes32) {
        uint256 epoch = currentEpoch;
        if (epoch == 0) return bytes32(0);

        uint256 count = epoch > MAX_HISTORY_ENTRIES ? MAX_HISTORY_ENTRIES : epoch;
        bytes memory packed;
        for (uint256 i = 0; i < count; i++) {
            uint256 histEpoch = epoch - 1 - i;  // most recent first
            packed = abi.encodePacked(packed, epochContentHashes[histEpoch]);
        }
        return keccak256(packed);
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
        uint256 bondAmount,
        uint256 randomnessSeed
    ) {
        AuctionState storage a = auctions[epoch];
        return (a.epochStartTime, a.phase, a.bidCount, a.winner, a.winningBid, a.bondAmount, a.randomnessSeed);
    }

    /// @notice Get the current treasury balance (liquid ETH only).
    function treasuryBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Get total assets: liquid treasury + invested value.
    function totalAssets() external view returns (uint256) {
        uint256 invested = address(investmentManager) != address(0)
            ? investmentManager.totalInvestedValue()
            : 0;
        return address(this).balance + invested;
    }

    /// @notice Get nonprofit info by ID.
    function getNonprofit(uint256 id) external view returns (string memory name, address addr, uint256 totalDonated, uint256 donationCount) {
        if (id < 1 || id > NUM_NONPROFITS) revert InvalidParams();
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


    /// @notice Get the total number of messages.
    function messageCount() external view returns (uint256) {
        return messages.length;
    }

    /// @notice Get unread messages for the current epoch (up to MAX_MESSAGES_PER_EPOCH).
    /// @return senders Array of sender addresses
    /// @return amounts Array of ETH amounts
    /// @return texts Array of message texts
    /// @return epochNums Array of epoch numbers when messages were received
    function getUnreadMessages() external view returns (
        address[] memory senders,
        uint256[] memory amounts,
        string[] memory texts,
        uint256[] memory epochNums
    ) {
        uint256 total = messages.length;
        uint256 unread = total > messageHead ? total - messageHead : 0;
        uint256 count = unread > MAX_MESSAGES_PER_EPOCH ? MAX_MESSAGES_PER_EPOCH : unread;

        senders = new address[](count);
        amounts = new uint256[](count);
        texts = new string[](count);
        epochNums = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            DonorMessage storage m = messages[messageHead + i];
            senders[i] = m.sender;
            amounts[i] = m.amount;
            texts[i] = m.text;
            epochNums[i] = m.epoch;
        }
    }

    // Allow receiving ETH directly (for seed funding)
    receive() external payable {
        totalInflows += msg.value;
    }
}
