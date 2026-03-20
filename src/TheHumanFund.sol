// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IAutomataDcapAttestation.sol";
import "./interfaces/IAttestationVerifier.sol";
import "./interfaces/IInvestmentManager.sol";

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
    error AttestationFailed();

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
    event CommissionClaimed(uint256 indexed codeId, uint256 amount);
    event EpochStarted(uint256 indexed epoch, bytes32 inputHash);

    // Phase 2: Auction events
    event AuctionOpened(uint256 indexed epoch, bytes32 inputHash, uint256 maxBidCeiling);
    event BidSubmitted(uint256 indexed epoch, address indexed runner, uint256 bidAmount);
    event AuctionClosed(uint256 indexed epoch, address indexed winner, uint256 winningBid);
    event EpochExecuted(uint256 indexed epoch, address indexed runner, uint256 bountyPaid);
    event BondForfeited(uint256 indexed epoch, address indexed runner, uint256 bondAmount);
    event AuctionModeChanged(bool enabled);
    event ActionRejected(uint256 indexed epoch, bytes action, string reason);

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

    // Note: DCAP verification now handled by the AttestationVerifier contract (see setVerifier)

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

    // TEE attestation verifier (separate contract — see AttestationVerifier.sol)
    IAttestationVerifier public verifier;
    mapping(uint256 => bytes) public epochAttestations; // Raw attestation quotes per epoch

    // Rolling history hash — Merkle chain over all epoch reasoning
    bytes32 public historyHash;

    // Investment manager (separate contract — see InvestmentManager.sol)
    IInvestmentManager public investmentManager;

    // Phase 2: Auction state
    bool public auctionEnabled;                              // false = Phase 0/1 mode, true = auction mode
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
        if (totalClaimed == 0) revert InvalidParams();
        totalCommissionsPaid += totalClaimed;
        (bool sent, ) = payable(msg.sender).call{value: totalClaimed}("");
        if (!sent) revert TransferFailed();
    }

    // ─── Owner: Epoch Execution (Phase 0) ────────────────────────────────

    /// @notice Submit the AI agent's action for the current epoch.
    /// @dev Phase 0: Only the owner can call this. No auction, no TEE.
    /// @param action The JSON-encoded action blob.
    /// @param reasoning The agent's chain-of-thought reasoning.
    function submitEpochAction(bytes calldata action, bytes calldata reasoning) external onlyOwner {
        if (auctionEnabled) revert WrongPhase();
        uint256 epoch = currentEpoch;
        if (epochs[epoch].executed) revert AlreadyDone();
        _recordAndExecuteEpoch(epoch, action, reasoning, 0);
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

    // ─── Owner: Attestation Verifier Configuration ──────────────────────

    /// @notice Set the attestation verifier contract address.
    /// @dev The verifier handles DCAP verification, image registry, and REPORTDATA checks.
    function setVerifier(address _verifier) external onlyOwner {
        verifier = IAttestationVerifier(_verifier);
    }

    /// @notice Set the investment manager contract address.
    function setInvestmentManager(address _im) external onlyOwner {
        investmentManager = IInvestmentManager(_im);
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

        // Enforce timing: previous epoch must have finished
        if (epoch > 1) {
            AuctionState storage prevAuction = auctions[epoch - 1];
            if (prevAuction.phase != EpochPhase.IDLE) {
                if (prevAuction.phase != EpochPhase.SETTLED) revert WrongPhase();
                if (block.timestamp < prevAuction.epochStartTime + epochDuration) revert TimingError();
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
            bondAmount: 0,
            randomnessSeed: 0
        });

        emit AuctionOpened(epoch, inputHash, effectiveMaxBid());
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
            emit AuctionClosed(epoch, auction.winner, auction.winningBid);
        }
    }

    /// @notice Submit the auction result (winner only).
    /// @dev The winner submits the attested inference result. On success,
    ///      the action is executed, the bounty is paid from treasury, and
    ///      the bond is refunded. Verifies:
    ///      1. DCAP quote is genuine TDX hardware (via Automata)
    ///      2. MRTD + RTMR[0..2] match an approved image
    ///      3. REPORTDATA matches sha256(inputHash || sha256(action) || sha256(reasoning) || seed)
    /// @param action The encoded action blob.
    /// @param reasoning The agent's chain-of-thought reasoning.
    /// @param attestationQuote Raw TDX DCAP attestation quote.
    function submitAuctionResult(
        bytes calldata action,
        bytes calldata reasoning,
        bytes calldata attestationQuote
    ) external payable {
        if (!auctionEnabled) revert WrongPhase();
        uint256 epoch = currentEpoch;
        AuctionState storage auction = auctions[epoch];

        if (auction.phase != EpochPhase.EXECUTION) revert WrongPhase();
        if (msg.sender != auction.winner) revert Unauthorized();
        if (block.timestamp >= auction.epochStartTime + biddingWindow + executionWindow) revert TimingError();

        // Compute expected REPORTDATA: sha256(inputHash || sha256(action) || sha256(reasoning) || seed)
        bytes32 expectedReportData = sha256(abi.encodePacked(
            epochInputHashes[epoch],
            sha256(action),
            sha256(reasoning),
            auction.randomnessSeed
        ));

        // Verify TEE attestation (DCAP + image measurements + REPORTDATA)
        bool verified = verifier.verifyAttestation{value: msg.value}(attestationQuote, expectedReportData);
        if (!verified) revert AttestationFailed();
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
        if (!paid) revert TransferFailed();

        emit EpochExecuted(epoch, winner, bountyAmount);
    }

    /// @notice Forfeit the winner's bond after the execution window expires.
    /// @dev Anyone can call this to advance the epoch when the winner fails to deliver.
    ///      The bond stays in the contract as additional treasury.
    function forfeitBond() external {
        if (!auctionEnabled) revert WrongPhase();
        uint256 epoch = currentEpoch;
        AuctionState storage auction = auctions[epoch];

        if (auction.phase != EpochPhase.EXECUTION) revert WrongPhase();
        if (block.timestamp < auction.epochStartTime + biddingWindow + executionWindow) revert TimingError();

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

        // Extend rolling history hash (Merkle chain over all reasoning)
        historyHash = keccak256(abi.encodePacked(historyHash, keccak256(reasoning)));

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
        if (!sent) revert TransferFailed();

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
        bytes32 investHash = address(investmentManager) != address(0)
            ? investmentManager.stateHash()
            : bytes32(0);
        return keccak256(abi.encode(
            stateHash,
            currentEpochInflow,
            currentEpochDonationCount,
            nonprofits[1].totalDonated,
            nonprofits[2].totalDonated,
            nonprofits[3].totalDonated,
            historyHash,
            investHash
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

    /// @notice Get number of pending commissions.
    function pendingCommissionsCount() external view returns (uint256) {
        return pendingCommissions.length;
    }

    // Allow receiving ETH directly (for seed funding)
    receive() external payable {
        totalInflows += msg.value;
    }
}
