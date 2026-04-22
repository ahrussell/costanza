// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IProofVerifier.sol";
import "./interfaces/IInvestmentManager.sol";
import "./interfaces/IAuctionManager.sol";
import "./interfaces/IWorldView.sol";
import "./interfaces/IAggregatorV3.sol";
import "./DonationExecutor.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title The Human Fund
/// @notice An autonomous AI agent that manages a charitable treasury on Base.
/// @dev Each epoch (~24 hours), the runner submits an action chosen by the AI model.
///      The contract validates bounds, executes the action, and emits a DiaryEntry event.
contract TheHumanFund is ReentrancyGuard {
    // ─── Errors ──────────────────────────────────────────────────────────

    error Unauthorized();
    error InvalidParams();
    error WrongPhase();
    error TimingError();
    error TransferFailed();
    error AlreadyDone();
    error ProofFailed();
    error Frozen();

    // ─── Types ───────────────────────────────────────────────────────────

    struct Nonprofit {
        string name;
        string description;
        bytes32 ein;           // EIN as bytes32 (e.g., "52-0907625" → formatBytes32String)
        uint256 totalDonated;
        uint256 totalDonatedUsd;  // USDC amount (6 decimals) — actual swap output
        uint256 donationCount;
        bool exists;
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

    /// @dev Frozen state snapshot taken at auction open. This is the SINGLE
    ///      SOURCE OF TRUTH for the enclave's input hash: `_hashSnapshot` is
    ///      declared `pure`, so the Solidity compiler mechanically proves the
    ///      contract can only hash values that live on this struct (plus its
    ///      immediate sub-hashes, which are themselves frozen bytes32s). No
    ///      storage reads are possible during input-hash computation.
    ///
    ///      Every field the enclave shows the model must be either
    ///        (a) a direct field on this struct, OR
    ///        (b) bound transitively via one of the frozen sub-hashes
    ///            (nonprofitsHash / messagesHash / historyHash /
    ///            worldviewHash / investmentsHash), which are computed live
    ///            at `_freezeEpochSnapshot()` time and stored here.
    ///
    ///      The prover mirrors this snapshot via `getEpochSnapshot(epoch)`
    ///      and passes its contents to the enclave. The enclave rebuilds
    ///      the same hash and binds it into REPORTDATA; on-chain verification
    ///      checks the stored hash against the TEE quote.
    struct EpochSnapshot {
        // ── Scalars (drift-prone or owner-mutable live state) ────────────
        uint256 epoch;                         // redundant with mapping key, but hashed for clarity
        uint256 balance;
        uint256 commissionRateBps;
        uint256 maxBid;
        // effectiveMaxBid is derived from balance + consecutiveMissedEpochs;
        // frozen here so the enclave doesn't have to re-derive the formula.
        uint256 effectiveMaxBid;
        uint256 consecutiveMissedEpochs;
        uint256 lastDonationEpoch;
        uint256 lastCommissionChangeEpoch;
        uint256 totalInflows;
        uint256 totalDonatedToNonprofits;
        uint256 totalCommissionsPaid;
        uint256 totalBountiesPaid;
        uint256 currentEpochInflow;
        uint256 currentEpochDonationCount;
        uint256 epochEthUsdPrice;
        // epochDuration frozen at auction open. The only path that can
        // change live epochDuration is `resetAuction`, which aborts the
        // in-flight auction atomically — so by construction no in-flight
        // snapshot can drift from live.
        uint256 epochDuration;
        // Message queue boundaries at auction open (used alongside messagesHash).
        uint256 messageHead;
        uint256 messageCount;
        // Nonprofit count at auction open (used alongside nonprofitsHash).
        // Admin-added nonprofits mid-auction are invisible to this snapshot.
        uint256 nonprofitCount;

        // ── Sub-hashes (computed LIVE at freeze time, then frozen) ───────
        // These are the byte-exact rolling hashes of nonprofit / message /
        // history / worldview / investment state, captured at the instant
        // freeze runs (when live state is authoritative). The pure
        // `_hashSnapshot` function reads them as plain bytes32 inputs.
        bytes32 nonprofitsHash;
        bytes32 messagesHash;
        bytes32 historyHash;
        bytes32 worldviewHash;
        bytes32 investmentsHash;

        // ── Investment raw values (prover display + drift-handling) ──────
        // Investment position currentValues drift with DeFi yields between
        // blocks; active flags can toggle via admin setProtocolActive().
        // Indexed 1..investmentProtocolCount, matching InvestmentManager.
        // name / riskTier / expectedApyBps are immutable post-addProtocol
        // and read live by the prover, bounded by investmentProtocolCount.
        // All of this is transitively bound via investmentsHash.
        uint256 investmentProtocolCount;
        uint256[21] investmentCurrentValues;  // 1-indexed, [0] unused, max 20 protocols
        bool[21] investmentActive;
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
        uint256 amountEth,
        uint256 amountUsd
    );

    event CommissionRateChanged(uint256 indexed epoch, uint256 newRateBps);
    event ReferralCodeMinted(uint256 indexed codeId, address indexed owner);
    event CommissionPaid(address indexed referrer, uint256 amount, uint256 referralCodeId);

    // Auction events
    event AuctionOpened(uint256 indexed epoch, bytes32 inputHash, uint256 maxBidCeiling, uint256 bond);
    event BidCommitted(uint256 indexed epoch, address indexed runner);
    event BidRevealed(uint256 indexed epoch, address indexed runner, uint256 bidAmount);
    event RevealClosed(uint256 indexed epoch, address indexed winner, uint256 winningBid);
    event EpochExecuted(uint256 indexed epoch, address indexed runner, uint256 bountyPaid);
    event BondForfeited(uint256 indexed epoch, address indexed runner, uint256 bondAmount);
    event ActionRejected(uint256 indexed epoch, bytes action, uint8 reason);
    // ActionRejected reason codes:
    // 1 = empty, 2 = malformed, 3 = out_of_bounds, 4 = invest_err,
    // 5 = invest_fail, 6 = withdraw_err, 7 = withdraw_fail,
    // 8 = policy_err, 9 = policy_fail, 10 = unknown_type
    event MessageReceived(address indexed sender, uint256 amount, uint256 indexed messageId);

    // ─── Constants ───────────────────────────────────────────────────────

    uint256 public constant MAX_DONATION_BPS = 1000;       // 10% of treasury
    uint256 public constant MIN_COMMISSION_BPS = 100;      // 1%
    uint256 public constant MAX_COMMISSION_BPS = 9000;     // 90%
    uint256 public constant MIN_MAX_BID = 0.0001 ether;
    uint256 public constant MAX_BID_BPS = 1000;            // 10% of treasury: hard ceiling on effectiveMaxBid
    uint256 public constant MIN_DONATION_AMOUNT = 0.001 ether;
    uint256 public constant AUTO_ESCALATION_BPS = 1000;    // 10% increase per missed epoch
    uint256 public constant MAX_NONPROFITS = 20;
    uint256 public constant BASE_BOND = 0.001 ether;         // Fixed bond, escalates on missed epochs
    uint256 public constant MIN_BOND_CAP = 0.1 ether;         // Bond cap floor (independent of treasury)
    uint256 public constant MAX_BOND_BPS = 1000;             // Bond cap as 10% of treasury
    uint256 public constant MIN_MESSAGE_DONATION = 0.001 ether; // Minimum ETH to include a message
    uint256 public constant MAX_MESSAGE_LENGTH = 280;
    uint256 public constant MAX_MESSAGES_PER_EPOCH = 3;     // Max messages shown to the model per epoch
    uint256 public constant MAX_POLICY_UPDATES_PER_EPOCH = 3; // Max worldview sidecar updates per epoch
    uint256 public constant PRICE_STALENESS_THRESHOLD = 3600; // 1 hour
    uint256 public constant MAX_MISSED_EPOCHS = 50;           // Cap loop iterations in effectiveMaxBid/currentBond

    // ─── State ───────────────────────────────────────────────────────────

    address public owner;
    uint256 public deployTimestamp;
    uint256 public currentEpoch;

    // Agent-controlled parameters
    uint256 public commissionRateBps;
    uint256 public maxBid;

    // Treasury tracking
    uint256 public totalInflows;
    uint256 public totalDonatedToNonprofits;
    uint256 public totalDonatedToNonprofitsUsd;  // USDC (6 decimals) — actual swap outputs
    uint256 public totalCommissionsPaid;
    uint256 public totalBountiesPaid;

    // Epoch tracking
    uint256 public lastDonationEpoch;
    uint256 public lastCommissionChangeEpoch;
    uint256 public consecutiveMissedEpochs;
    uint256 public lastEpochStartTime;  // Scheduled start time of the last opened epoch
    uint256 public timingAnchor;        // Wall-clock reference point for epoch schedule
    uint256 public anchorEpoch;         // Epoch number at the anchor

    // Nonprofits (1-indexed for the agent's benefit)
    uint256 public nonprofitCount;
    mapping(uint256 => Nonprofit) public nonprofits;

    // Donation execution (ETH → WETH → USDC → Endaoment pipeline)
    DonationExecutor public immutable donationExecutor;

    // Chainlink ETH/USD price feed
    IAggregatorV3 public immutable ethUsdFeed;
    uint256 public epochEthUsdPrice;  // Snapshotted at epoch start (feed decimals, typically 8)

    // Epochs
    mapping(uint256 => EpochRecord) public epochs;
    mapping(uint256 => bytes32) public epochInputHashes;

    // Referral system
    uint256 public nextReferralCodeId;
    mapping(uint256 => ReferralCode) public referralCodes;
    /// @notice Claimable commission balances (pull-based fallback when referrer reverts).
    mapping(address => uint256) public claimableCommissions;

    // Per-epoch inflow tracking (reset each epoch)
    uint256 public currentEpochInflow;
    uint256 public currentEpochDonationCount;
    uint256 public currentEpochCommissions;


    // Proof verifier registry — supports TEE (TDX) and future ZK verifiers
    mapping(uint8 => IProofVerifier) public verifiers;
    mapping(uint256 => bytes) public epochProofs; // Raw proofs per epoch (attestation quotes, ZK proofs)

    // Base input hashes (pre-seed) — extended with randomness seed at closeAuction()
    mapping(uint256 => bytes32) public epochBaseInputHashes;

    // Frozen state snapshots — taken at auction open so provers can reproduce the input hash
    mapping(uint256 => EpochSnapshot) internal _epochSnapshots;

    // Per-epoch content hashes — cached at settlement for cheap history verification
    mapping(uint256 => bytes32) public epochContentHashes;

    // Investment manager (separate contract — see InvestmentManager.sol)
    IInvestmentManager public investmentManager;

    // Worldview (separate contract — see WorldView.sol)
    IWorldView public worldView;

    // approvedPromptHash removed — prompt on dm-verity rootfs, verified via image key

    // Donor messages
    DonorMessage[] public messages;
    mapping(uint256 => bytes32) public messageHashes;  // messageId => keccak256(sender, amount, text, epoch)
    uint256 public messageHead;  // index of first unread message

    // Auction state
    uint256 public epochDuration;                            // derived = cw + rw + xw
    uint256 public commitWindow;                              // seconds in COMMIT phase
    uint256 public revealWindow;                              // seconds in REVEAL phase
    uint256 public executionWindow;                           // seconds in EXECUTION phase
    uint256 public currentAuctionStartTime;                  // wall-clock start of current auction

    // Auction manager (separate contract — see AuctionManager.sol)
    IAuctionManager public auctionManager;

    // Input-hash chain seed material. The salt accumulator is mutated per
    // reveal; the seed is captured (and input hash bound) at REVEAL→EXECUTION.
    mapping(uint256 => bytes32) public epochSaltAccumulator;
    mapping(uint256 => uint256) public epochSeeds;

    // Kill switches — bitmask flags, once set permanently disable the corresponding methods.
    uint256 public constant FREEZE_NONPROFITS          = 1 << 0;
    uint256 public constant FREEZE_INVESTMENT_WIRING   = 1 << 1;
    uint256 public constant FREEZE_WORLDVIEW_WIRING    = 1 << 2;
    uint256 public constant FREEZE_AUCTION_CONFIG      = 1 << 3;
    uint256 public constant FREEZE_VERIFIERS           = 1 << 4;
    // Bits (1 << 5) and (1 << 6) are unused.
    uint256 public constant FREEZE_MIGRATE              = 1 << 7;
    uint256 public constant FREEZE_SUNSET               = 1 << 8;
    uint256 public frozenFlags;

    event PermissionFrozen(uint256 indexed flag);
    event Sunset(address indexed destination);
    event OwnershipTransferred(address indexed newOwner);
    event AuctionReset(uint256 indexed fromEpoch, uint256 indexed toEpoch);

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    function _requireNotSunset() internal view {
        if (frozenFlags & FREEZE_SUNSET != 0) revert Frozen();
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(
        uint256 _initialCommissionBps,
        uint256 _initialMaxBid,
        address _donationExecutor,
        address _ethUsdFeed
    ) payable {
        if (_initialCommissionBps < MIN_COMMISSION_BPS || _initialCommissionBps > MAX_COMMISSION_BPS) revert InvalidParams();
        if (_initialMaxBid < MIN_MAX_BID) revert InvalidParams();

        owner = msg.sender;
        deployTimestamp = block.timestamp;
        currentEpoch = 1;
        commissionRateBps = _initialCommissionBps;
        maxBid = _initialMaxBid;
        nextReferralCodeId = 1;

        // Default epoch duration (overwritten by setAuctionManager when AM timing is set)
        epochDuration = 24 hours;
        // Timing anchor is left at zero; setAuctionManager is the first
        // operation after deploy and writes it via _openAuction. Before that,
        // epoch view functions return meaningless values but nothing calls them.

        // `consecutiveStalledEpochs` starts at 0 (Solidity default), so
        // `currentBond() == BASE_BOND` at deploy. Bond is a pure function
        // of the counter — no direct writes anywhere.

        donationExecutor = DonationExecutor(_donationExecutor);
        ethUsdFeed = IAggregatorV3(_ethUsdFeed);

        if (msg.value > 0) {
            totalInflows += msg.value;
        }
    }

    /// @notice Add a nonprofit to the registry. Only callable by owner.
    /// @param _name Display name of the nonprofit.
    /// @param _description Human-readable description for the agent prompt.
    /// @param _ein EIN as bytes32 (e.g., formatBytes32String("52-0907625")).
    function addNonprofit(
        string calldata _name,
        string calldata _description,
        bytes32 _ein
    ) external onlyOwner returns (uint256 id) {
        if (frozenFlags & FREEZE_NONPROFITS != 0) revert Frozen();
        if (nonprofitCount >= MAX_NONPROFITS) revert InvalidParams();
        if (_ein == bytes32(0)) revert InvalidParams();
        id = ++nonprofitCount;
        nonprofits[id] = Nonprofit({
            name: _name,
            description: _description,
            ein: _ein,
            totalDonated: 0,
            totalDonatedUsd: 0,
            donationCount: 0,
            exists: true
        });
    }

    // ─── Public: Donate to the Fund ──────────────────────────────────────

    /// @notice Donate ETH to the fund, optionally with a referral code.
    /// @param referralCodeId The referral code ID (0 for no referral).
    function donate(uint256 referralCodeId) external payable nonReentrant {
        _requireNotSunset();
        if (msg.value < MIN_DONATION_AMOUNT) revert InvalidParams();

        // ─── Effects ─ all state writes BEFORE any external call (CEI) ──
        // Note: we do NOT call _advanceToNow here. Donations arriving during
        // an idle gap (wall-clock past epoch end, no prover activity) will
        // be credited to `totalInflows` but lost from `currentEpochInflow`
        // when the next prover sync resets the per-epoch counter. This is
        // an accepted accounting limitation — net treasury balance is
        // always correct, only the per-epoch breakdown drifts.
        totalInflows += msg.value;
        currentEpochInflow += msg.value;
        currentEpochDonationCount += 1;

        // ─── Interactions ─ external call last ──────────────────────────
        // `_payCommission` calls out to the referrer. Reentry into other
        // `nonReentrant` functions is blocked by the outer guard, but the
        // referrer CAN still call non-guarded functions like `syncPhase()`.
        // Putting this call LAST ensures any such reentry observes
        // fully-committed state.
        uint256 commission = 0;
        if (referralCodeId > 0 && referralCodes[referralCodeId].exists) {
            commission = _payCommission(referralCodeId);
        }

        emit DonationReceived(msg.sender, msg.value, referralCodeId, commission);
    }

    /// @notice Donate ETH to the fund with a message for the AI agent.
    /// @param referralCodeId The referral code ID (0 for no referral).
    /// @param message A message for the agent (max 280 characters, requires >= 0.01 ETH).
    function donateWithMessage(uint256 referralCodeId, string calldata message) external payable nonReentrant {
        _requireNotSunset();
        if (msg.value < MIN_MESSAGE_DONATION) revert InvalidParams();
        // Reject rather than silently truncate: byte-level truncation at
        // MAX_MESSAGE_LENGTH can split a multi-byte UTF-8 codepoint in half,
        // producing invalid UTF-8 that breaks JSON serialization in the
        // enclave prompt-assembly path.
        if (bytes(message).length > MAX_MESSAGE_LENGTH) revert InvalidParams();

        // ─── Effects ─ all state writes BEFORE any external call (CEI) ──
        // See `donate()` re: per-epoch accounting drift for idle-gap donations.
        totalInflows += msg.value;
        currentEpochInflow += msg.value;
        currentEpochDonationCount += 1;

        uint256 messageId = messages.length;
        messages.push(DonorMessage({
            sender: msg.sender,
            amount: msg.value,
            text: message,
            epoch: currentEpoch
        }));
        messageHashes[messageId] = keccak256(abi.encode(msg.sender, msg.value, message, currentEpoch));

        // ─── Interactions ─ external call last ──────────────────────────
        // `_payCommission` must run AFTER all state writes (including
        // messages.push) so a referrer-triggered reentry via `syncPhase()`
        // cannot observe a half-done state where counters have moved but
        // the message isn't in the queue yet.
        uint256 commission = 0;
        if (referralCodeId > 0 && referralCodes[referralCodeId].exists) {
            commission = _payCommission(referralCodeId);
        }

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

    /// @dev Pay commission to the referrer. Falls back to pull-based if referrer reverts.
    ///
    /// Known accepted limitation — "referrer reentry drift":
    /// The external `.call` below hands execution to an arbitrary referrer
    /// address. A malicious smart-contract referrer can reenter the fund
    /// via `fund.syncPhase()` (which is intentionally not nonReentrant, so
    /// migrate paths can drive it during sunset). If wall-clock has crossed
    /// an epoch boundary, that reentrant sync advances `currentEpoch` and
    /// zeros `currentEpochInflow` / `currentEpochDonationCount` /
    /// `currentEpochCommissions` — effectively hiding the in-progress
    /// donation from per-epoch telemetry. Callers of donate/donateWithMessage
    /// write state BEFORE calling this function (CEI), so:
    ///   - `totalInflows` is correct (written pre-call, never reset)
    ///   - `messages[]` contains the donor message (pushed pre-call)
    ///   - Treasury balance reflects the net ETH movement
    ///   - Only the per-epoch counters can drift to zero
    /// The model reads treasury balance and the message queue directly, so
    /// this drift only affects one narrative line in the prompt. It is
    /// equivalent to the "idle-gap donation" accounting loss that is also
    /// accepted. Closing it hard would require either marking `syncPhase`
    /// nonReentrant (breaks the sunset-drain path) or tracking per-donation
    /// epoch tags independently of the global counters.
    function _payCommission(uint256 referralCodeId) internal returns (uint256 commission) {
        commission = (msg.value * commissionRateBps) / 10000;
        address payable referrer = payable(referralCodes[referralCodeId].owner);
        referralCodes[referralCodeId].totalReferred += msg.value;
        referralCodes[referralCodeId].referralCount += 1;
        totalCommissionsPaid += commission;
        currentEpochCommissions += commission;
        (bool sent, ) = referrer.call{value: commission}("");
        if (!sent) {
            // Referrer contract reverted — credit commission for pull-based claim
            claimableCommissions[referrer] += commission;
        }
        emit CommissionPaid(referrer, commission, referralCodeId);
    }

    /// @notice Claim accumulated commission balances (for referrers whose contracts revert on receive).
    function claimCommission() external nonReentrant {
        uint256 amount = claimableCommissions[msg.sender];
        if (amount == 0) revert InvalidParams();
        claimableCommissions[msg.sender] = 0;
        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        if (!sent) revert TransferFailed();
    }

    // ─── Owner: Proof Verifier Registry ──────────────────────────────────

    event VerifierApproved(uint8 indexed verifierId, address verifier);
    event VerifierRevoked(uint8 indexed verifierId);

    /// @notice Register a proof verifier (TEE, ZK, etc.) at a given ID.
    /// @param id Verifier ID (1+ recommended; 0 is valid but unusual).
    /// @param _verifier The IProofVerifier contract address.
    function approveVerifier(uint8 id, address _verifier) external onlyOwner {
        if (frozenFlags & FREEZE_VERIFIERS != 0) revert Frozen();
        if (_verifier == address(0)) revert InvalidParams();
        verifiers[id] = IProofVerifier(_verifier);
        emit VerifierApproved(id, _verifier);
    }

    /// @notice Remove a proof verifier from the registry.
    function revokeVerifier(uint8 id) external onlyOwner {
        if (frozenFlags & FREEZE_VERIFIERS != 0) revert Frozen();
        if (address(verifiers[id]) == address(0)) revert InvalidParams();
        delete verifiers[id];
        emit VerifierRevoked(id);
    }

    /// @notice Set the investment manager contract address.
    function setInvestmentManager(address _im) external onlyOwner {
        if (frozenFlags & FREEZE_INVESTMENT_WIRING != 0) revert Frozen();
        investmentManager = IInvestmentManager(_im);
    }

    /// @notice Transfer contract ownership to a new address (e.g., a multisig).
    /// @dev Frozen by FREEZE_MIGRATE (same gate as withdrawAll/migrate).
    function transferOwnership(address newOwner) external onlyOwner {
        if (frozenFlags & FREEZE_MIGRATE != 0) revert Frozen();
        if (newOwner == address(0)) revert InvalidParams();
        owner = newOwner;
        emit OwnershipTransferred(newOwner);
    }

    /// @notice Withdraw all DeFi positions and transfer entire treasury to owner.
    /// @dev Emergency shutdown: unwinds all investments, sends everything to owner.
    function withdrawAll() external onlyOwner {
        if (frozenFlags & FREEZE_MIGRATE != 0) revert Frozen();
        _withdrawTo(owner);
    }

    /// @notice Graceful migration: requires FREEZE_SUNSET to be set first (blocking inflows),
    ///         then drains any in-flight auction, unwinds all positions, and sends
    ///         funds to the destination address.
    /// @param destination The address to receive all funds (e.g., a new contract).
    /// @dev Phase-agnostic: `_resetAuction` always refunds held bonds non-
    ///      confiscatorily regardless of the AM's current phase. Freeze-flag
    ///      checks are the only preconditions.
    function migrate(address destination) external onlyOwner {
        if (frozenFlags & FREEZE_MIGRATE != 0) revert Frozen();
        if (frozenFlags & FREEZE_SUNSET == 0) revert InvalidParams();
        if (address(auctionManager) != address(0)) {
            // Preserve current timing — migrate doesn't change windows.
            _resetAuction(commitWindow, revealWindow, executionWindow);
        }
        _withdrawTo(destination);
        emit Sunset(destination);
    }

    function _withdrawTo(address recipient) internal {
        if (address(investmentManager) != address(0)) {
            investmentManager.withdrawAll(recipient);
        }
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool sent,) = recipient.call{value: bal}("");
            if (!sent) revert TransferFailed();
        }
    }

    function setWorldView(address _wv) external onlyOwner {
        if (frozenFlags & FREEZE_WORLDVIEW_WIRING != 0) revert Frozen();
        worldView = IWorldView(_wv);
    }

    /// @notice Set (or replace) the auction manager and configure phase timing.
    ///         Re-anchors the epoch schedule to now. For mid-life timing
    ///         changes after auctions have run, use `resetAuction` instead
    ///         (it aborts in-flight bonds non-confiscatorily).
    /// @dev Timing windows live here, not in the AM — the AM is timing-
    ///      agnostic and driven manually by this contract via `am.nextPhase()`.
    ///      `epochDuration` is derived from the sum of phase windows.
    function setAuctionManager(
        address _am,
        uint256 _commitWindow,
        uint256 _revealWindow,
        uint256 _executionWindow
    ) external onlyOwner {
        if (frozenFlags & FREEZE_AUCTION_CONFIG != 0) revert Frozen();
        if (_am == address(0)) revert InvalidParams();
        if (_commitWindow == 0 || _revealWindow == 0 || _executionWindow == 0) revert InvalidParams();

        auctionManager = IAuctionManager(_am);
        commitWindow = _commitWindow;
        revealWindow = _revealWindow;
        executionWindow = _executionWindow;
        epochDuration = _commitWindow + _revealWindow + _executionWindow;

        // Eagerly open epoch N's auction. `_openAuction` is the sole site
        // that writes the timing anchor, so passing `block.timestamp` as
        // `scheduledStart` atomically re-anchors + opens. Subsequent opens
        // happen inside `_closeExecution` → `_openAuction` during normal
        // epoch rollover.
        _openAuction(currentEpoch, block.timestamp);
    }

    // setApprovedPromptHash removed — prompt verified via dm-verity image key

    /// @notice Seed multiple worldview policies at once. Only callable by owner.
    /// @dev Intended for initial setup before the fund goes live.
    function seedWorldView(
        uint256[] calldata slots,
        string[] calldata titles,
        string[] calldata bodies
    ) external onlyOwner {
        if (frozenFlags & FREEZE_WORLDVIEW_WIRING != 0) revert Frozen();
        require(address(worldView) != address(0), "no worldview");
        require(slots.length == titles.length, "length mismatch");
        require(slots.length == bodies.length, "length mismatch");
        for (uint256 i = 0; i < slots.length; i++) {
            worldView.setPolicy(slots[i], titles[i], bodies[i]);
        }
    }

    // ─── Kill Switches ────────────────────────────────────────────────────

    /// @notice Permanently freeze a permission group. Once frozen, methods guarded
    ///         by that flag will revert with Frozen(). Cannot be undone.
    /// @param flag The permission flag (e.g., FREEZE_NONPROFITS, FREEZE_AUCTION_CONFIG).
    function freeze(uint256 flag) external onlyOwner {
        frozenFlags |= flag;
        emit PermissionFrozen(flag);
    }

    /// @notice Freeze a specific verifier's internal state (e.g., image registry).
    /// @dev Calls freeze() on the verifier contract via IProofVerifier interface.
    function freezeVerifier(uint8 id) external onlyOwner {
        if (address(verifiers[id]) == address(0)) revert InvalidParams();
        verifiers[id].freeze();
    }

    // ─── Reverse Auction ──────────────────────────────────────────────────

    /// @notice Current bond amount — the cost for a prover to commit to
    ///         an epoch. Escalates 10% on winner-forfeit (a successful
    ///         committer who failed to submit is considered actively
    ///         stalling the agent). Resets to `BASE_BOND` on successful
    ///         execution. Capped at `max(MIN_BOND_CAP, 10% of treasury)`.
    ///
    /// @dev Escalation is stored as direct state (not derived from a
    ///      counter) so reads and writes are both O(1). Silent epochs
    ///      where nobody committed do NOT escalate the bond — that
    ///      would discourage new bidders from joining after a drought.
    ///      The max bid escalation (in `effectiveMaxBid`) still tracks
    ///      silent epochs via `consecutiveMissedEpochs` because its
    ///      purpose is to attract bidders, not to punish stalling.
    /// @notice Counter driving bond escalation. Updates at exactly one
    ///         site (`_closeExecution`): resets to 0 on successful epoch;
    ///         increments by 1 on winner-forfeit; unchanged on silence.
    ///         Bounded at `MAX_MISSED_EPOCHS` to cap the `currentBond()`
    ///         loop gas cost.
    uint256 public consecutiveStalledEpochs;

    /// @notice Current bond amount, as a deterministic function of
    ///         `consecutiveStalledEpochs`:
    ///
    ///           currentBond = min(bondCap, BASE_BOND * (1+E)^stalled)
    ///
    ///         where E = AUTO_ESCALATION_BPS / 10000 (10%) and `bondCap`
    ///         is the treasury-derived cap below.
    function currentBond() public view returns (uint256) {
        return _bondFor(consecutiveStalledEpochs);
    }

    /// @dev Pure formula for the bond amount given a stalled-counter value.
    ///      Single source of truth for bond math, consumed by `currentBond()`
    ///      and by `projectedCurrentBond()` (via `_projectCounters`). Any
    ///      change to the formula only needs to happen here.
    function _bondFor(uint256 stalled) internal view returns (uint256) {
        uint256 bond = BASE_BOND;
        uint256 cap = _bondCap();
        for (uint256 i = 0; i < stalled; i++) {
            bond = bond + (bond * AUTO_ESCALATION_BPS) / 10000;
            if (bond >= cap) return cap;
        }
        return bond > cap ? cap : bond;
    }

    /// @dev Compute the treasury-derived bond cap: max(MIN_BOND_CAP,
    ///      MAX_BOND_BPS of treasury). The cap prevents the escalation
    ///      from growing unboundedly.
    function _bondCap() internal view returns (uint256) {
        uint256 treasuryPct = (address(this).balance * MAX_BOND_BPS) / 10000;
        return treasuryPct > MIN_BOND_CAP ? treasuryPct : MIN_BOND_CAP;
    }

    /// @notice Compute the deterministic scheduled start time for any epoch.
    function _epochStartTime(uint256 epoch) internal view returns (uint256) {
        return timingAnchor + (epoch - anchorEpoch) * epochDuration;
    }

    /// @dev Advance `currentEpoch` by `count`, resetting per-epoch
    ///      counters. Shared by the single-epoch and multi-epoch
    ///      branches of `_advanceToNow` Step B so the bookkeeping is
    ///      defined in exactly one place.
    /// @param count The number of epochs to advance past.
    /// @param missCount How many of those elapsed epochs to credit
    ///      toward `consecutiveMissedEpochs`. Usually equal to `count`;
    ///      one less when the current epoch was successfully executed
    ///      (that one doesn't count as a miss). See call site.
    function _advanceEpochBy(uint256 count, uint256 missCount) internal {
        if (missCount > 0) {
            uint256 newMissed = consecutiveMissedEpochs + missCount;
            if (newMissed > MAX_MISSED_EPOCHS) newMissed = MAX_MISSED_EPOCHS;
            consecutiveMissedEpochs = newMissed;
        }
        currentEpoch += count;
        currentEpochInflow = 0;
        currentEpochDonationCount = 0;
        currentEpochCommissions = 0;
    }

    // ─── Phase Sync ────────────────────────────────────────────────────

    /// @notice Advance the contract through any elapsed epoch/phase boundaries.
    ///         Anyone can call — permissionless state advancement. Replaces
    ///         startEpoch(), closeCommit(), closeReveal(), and forfeitBond().
    /// @dev NOT sunset-gated: `migrate()` always drains in-flight auctions
    ///      via `_resetAuction`, so we keep `syncPhase` available even under
    ///      sunset for off-chain observers / late-reveal bond claims that
    ///      don't require a live auction.
    function syncPhase() external {
        _advanceToNow();
    }

    /// @notice Owner-only manual advance: walk the state machine exactly
    ///         one step. Useful for debugging stuck auctions in prod and
    ///         for test ergonomics (no vm.warp needed).
    ///
    ///         Transitions (3-phase cyclic, monotonic):
    ///           COMMIT    → REVEAL         (via `_nextPhase`)
    ///           REVEAL    → EXECUTION      (via `_nextPhase`; captures seed,
    ///                                       binds input hash)
    ///           EXECUTION → COMMIT of next epoch (via `_closeExecution` +
    ///                                       `_openAuction`; forfeits winner
    ///                                       bond if epoch was not executed)
    ///
    ///         Normal auction consequences apply: non-revealers forfeit
    ///         bonds at reveal close, winners forfeit at execution close.
    ///         This preserves **driver equivalence** — manual and wall-
    ///         clock drivers produce the same state for the same scenario.
    ///         For a non-confiscatory abort (refund all bonds), use
    ///         `resetAuction` instead.
    ///
    /// @dev Gated by `FREEZE_AUCTION_CONFIG` (invariant I7).
    /// @dev Re-anchors timing when crossing an epoch boundary so
    ///      `epochStartTime(currentEpoch) == block.timestamp`, satisfying
    ///      I4 (schedule coherence).
    function nextPhase() external onlyOwner returns (uint8 newPhase) {
        if (frozenFlags & FREEZE_AUCTION_CONFIG != 0) revert Frozen();
        IAuctionManager am = auctionManager;
        if (address(am) == address(0)) revert InvalidParams();

        // Sync-first: catch up to wall-clock BEFORE the manual one-step
        // advance. Without this, the manual driver could leave the contract
        // indefinitely behind wall-clock (one owner tx advances one phase
        // step while whole epochs worth of wall-clock time elapse).
        _advanceToNow();

        IAuctionManager.AuctionPhase phase = am.phase();

        if (phase == IAuctionManager.AuctionPhase.EXECUTION
            || phase == IAuctionManager.AuctionPhase.SETTLED
        ) {
            // Cross the epoch boundary. `_closeExecution` handles both the
            // EXECUTION path (winner no-show → forfeit via `am.closeExecution`)
            // and the SETTLED path (epoch already settled via settleExecution;
            // counter update only, no AM call).
            _closeExecution();
            _openAuction(currentEpoch, block.timestamp);
        } else {
            // Intra-epoch: COMMIT→REVEAL or REVEAL→EXECUTION.
            _nextPhase();
        }
        newPhase = uint8(am.phase());
    }

    /// @notice Owner-only reset: abort any in-flight auction, apply new
    ///         auction timing parameters, advance one epoch, and re-anchor
    ///         timing to now. This is the ONLY safe way to change auction
    ///         timing while the contract is live.
    /// @dev Why this exists: mainnet v1 was bricked (commit bd883a9) when
    ///      `epochDuration` was changed mid-epoch — the frozen snapshot's
    ///      `epochBaseInputHashes[epoch]` was bound to the old duration,
    ///      so the prover's TEE input hash diverged after the change and
    ///      `submitAuctionResult` reverted. `resetAuction` avoids this by
    ///      aborting the in-flight auction first (refunding all held
    ///      bonds — operator intervention is NOT a forfeit), applying
    ///      new timing atomically, and advancing to a fresh epoch whose
    ///      snapshot will be opened at the new timing values.
    /// @dev `epochDuration` is derived from `cw + rw + xw` — no separate
    ///      parameter that could drift.
    /// @dev `consecutiveMissedEpochs` is NOT incremented — the reset
    ///      wasn't anyone's fault, and we don't want auto-escalation to
    ///      spike as a side effect of recovery.
    /// @dev Gated by `FREEZE_AUCTION_CONFIG`.
    /// @param _commitWindow    New commit window duration (seconds).
    /// @param _revealWindow    New reveal window duration (seconds).
    /// @param _executionWindow New execution window duration (seconds).
    function resetAuction(
        uint256 _commitWindow,
        uint256 _revealWindow,
        uint256 _executionWindow
    ) external onlyOwner {
        if (frozenFlags & FREEZE_AUCTION_CONFIG != 0) revert Frozen();
        _resetAuction(_commitWindow, _revealWindow, _executionWindow);
    }

    /// @dev Internal core of `resetAuction`. Aborts any in-flight auction
    ///      (refunding held bonds), applies new timing, advances one epoch,
    ///      re-anchors the schedule to now, and opens a fresh auction for
    ///      the new epoch. Callers are responsible for their own
    ///      authorization and freeze gating. Shared by `resetAuction`
    ///      (auction-config gated) and `migrate` (sunset gated) so the
    ///      drain path lives in exactly one place.
    /// @dev Under sunset, skip the re-open — `migrate` is about to withdraw
    ///      everything anyway, and opening a new auction that immediately
    ///      gets migrated away is wasted gas plus a confusing snapshot.
    function _resetAuction(
        uint256 _commitWindow,
        uint256 _revealWindow,
        uint256 _executionWindow
    ) internal {
        if (_commitWindow == 0 || _revealWindow == 0 || _executionWindow == 0) revert InvalidParams();
        IAuctionManager am = auctionManager;
        if (address(am) == address(0)) revert InvalidParams();

        // Sync-first: catch up to wall-clock BEFORE aborting, so the
        // "from epoch" reflects reality rather than stale state.
        _advanceToNow();

        uint256 fromEpoch = currentEpoch;

        // Abort any in-flight auction and refund held bonds non-
        // confiscatorily (operator intervention is NOT a forfeit event).
        // Idempotent if the AM is already SETTLED.
        am.abortAuction();

        // Apply new timing atomically. epochDuration is derived from the
        // sum so it cannot drift from the phase windows.
        commitWindow = _commitWindow;
        revealWindow = _revealWindow;
        executionWindow = _executionWindow;
        epochDuration = _commitWindow + _revealWindow + _executionWindow;

        // Advance one epoch. Reset is not a missed epoch, so neither
        // `consecutiveMissedEpochs` nor `consecutiveStalledEpochs` is
        // touched (missCount = 0).
        _advanceEpochBy(1, 0);

        // Open the fresh auction. Skipped under FREEZE_SUNSET — migrate
        // is about to drain, and the stale anchor never gets consulted.
        if (frozenFlags & FREEZE_SUNSET == 0) {
            _openAuction(currentEpoch, block.timestamp);
        }

        emit AuctionReset(fromEpoch, currentEpoch);
    }

    // ─── Intra-Epoch Primitive ────────────────────────────────────────

    /// @dev Execute exactly one state-machine transition WITHIN the current
    ///      epoch. Narrow semantics: COMMIT→REVEAL or REVEAL→EXECUTION.
    ///      Reverts (via AM.nextPhase's WrongPhase) if called in EXECUTION
    ///      or SETTLED — the epoch boundary is handled by `_closeExecution`
    ///      + `_openAuction`.
    ///
    ///      Seed capture + input-hash binding happen here on the REVEAL→
    ///      EXECUTION transition — the single code path where those side
    ///      effects fire (invariant I6). The salt accumulator is main-
    ///      owned (`epochSaltAccumulator`); the seed mixes prevrandao with
    ///      the accumulator and is stored on `epochSeeds` alongside the
    ///      bound input hash.
    function _nextPhase() internal {
        IAuctionManager am = auctionManager;
        uint256 epoch = currentEpoch;

        IAuctionManager.AuctionPhase prevPhase = am.phase();
        am.nextPhase();

        // If we just closed REVEAL, capture the seed and bind the full
        // input hash (base ⊕ seed) so provers can verify their output.
        if (prevPhase == IAuctionManager.AuctionPhase.REVEAL) {
            uint256 seed = uint256(block.prevrandao) ^ uint256(epochSaltAccumulator[epoch]);
            epochSeeds[epoch] = seed;
            epochInputHashes[epoch] = keccak256(abi.encodePacked(
                epochBaseInputHashes[epoch],
                seed
            ));
            emit RevealClosed(epoch, am.winner(), am.winningBid());
        }
    }

    // ─── End-of-Epoch Primitive ────────────────────────────────────────

    /// @dev Close out the current epoch's EXECUTION phase and advance
    ///      `currentEpoch += 1`. Does NOT open the next auction — callers
    ///      handle that step separately so the wall-clock driver can
    ///      arithmetically fast-forward through multiple elapsed epochs
    ///      between the close and the open.
    ///
    ///      Counter updates (SOLE UPDATE SITE for both counters' end-of-
    ///      epoch branch — only `_advanceToNow` fast-forward also touches
    ///      `consecutiveMissedEpochs`):
    ///
    ///        epochs[e].executed  | winner present | missed   | stalled
    ///        ────────────────────┼────────────────┼──────────┼─────────
    ///        true                | —              | → 0      | → 0
    ///        false               | yes            | += 1     | += 1
    ///        false               | no             | += 1     | unchanged
    ///
    ///      The `stalled` counter drives `currentBond()`; the `missed`
    ///      counter drives `effectiveMaxBid`.
    function _closeExecution() internal {
        IAuctionManager am = auctionManager;
        uint256 epoch = currentEpoch;
        bool executed = epochs[epoch].executed;

        if (executed) {
            consecutiveMissedEpochs = 0;
            consecutiveStalledEpochs = 0;
            // AM already in SETTLED via settleExecution. Nothing to close.
        } else {
            // Read AM state BEFORE calling closeExecution (which transitions
            // AM → SETTLED and moves the forfeit ETH to us).
            address winner = am.winner();
            uint256 forfeitedBond = am.bond();
            if (winner != address(0)) {
                emit BondForfeited(epoch, winner, forfeitedBond);
                uint256 newStalled = consecutiveStalledEpochs + 1;
                if (newStalled > MAX_MISSED_EPOCHS) newStalled = MAX_MISSED_EPOCHS;
                consecutiveStalledEpochs = newStalled;
            }
            // consecutiveMissedEpochs increments below via _advanceEpochBy.

            // Transition AM to SETTLED (forfeits the winner's bond to us
            // if present; stores history). Reverts if AM is not EXECUTION.
            am.closeExecution();
        }

        _advanceEpochBy(1, executed ? 0 : 1);
    }

    // ─── Wall-Clock Driver ─────────────────────────────────────────────

    /// @dev Advance through all elapsed phases and epochs to reach
    ///      wall-clock-consistent state. Called before every prover
    ///      action (commit, reveal, submit, syncPhase).
    ///
    ///      Four independent steps:
    ///        A. Close any elapsed INTRA-epoch phases via `_nextPhase`.
    ///           At most two calls (COMMIT → REVEAL → EXECUTION).
    ///        B. If at EXECUTION past deadline (or executed + epoch elapsed),
    ///           cross the epoch boundary via `_closeExecution`.
    ///        C. Arithmetically advance `currentEpoch` past any additional
    ///           fully-elapsed "ghost" epochs — epochs whose commit windows
    ///           came and went without anyone opening an auction. O(1).
    ///        D. Open an auction on the landed epoch if one isn't already
    ///           open for it. This runs on EVERY non-skipped epoch so the
    ///           bookkeeping (`_freezeEpochSnapshot`, base-input-hash bind,
    ///           `AuctionOpened` event) fires exactly once per landed epoch.
    ///           After opening, cascade `_nextPhase()` to bring the phase
    ///           in line with wall-clock (opening always starts in COMMIT).
    ///           The per-phase gates on `commit`/`reveal`/`submitAuctionResult`
    ///           prevent anyone from participating in an already-elapsed
    ///           window on a retroactively-opened epoch. Skipped under sunset.
    ///
    ///      The steps are decoupled so a stuck step never traps the
    ///      others; repeated calls converge regardless of where
    ///      execution left off.
    ///
    /// @dev ⚠ If you change the counter arithmetic in this function (the
    ///      missed/stalled updates in `_closeExecution` / `_advanceEpochBy`
    ///      or the epoch-advance math in Step C), update `_projectCounters`
    ///      to match. `testFuzz_projectedState_matchesAdvanceToNow` enforces
    ///      parity between the two under fuzzed wall-clock advancement.
    function _advanceToNow() internal {
        IAuctionManager am = auctionManager;
        if (address(am) == address(0)) return;

        uint256 epoch = currentEpoch;
        IAuctionManager.AuctionPhase phase = am.phase();

        // ─── Step A: drain in-flight intra-epoch phases ─────────────────
        // Only meaningful if the AM holds a live auction for this epoch.
        // COMMIT→REVEAL and REVEAL→EXECUTION cascade if wall-clock demands.
        if (am.currentEpoch() == epoch && phase != IAuctionManager.AuctionPhase.SETTLED) {
            uint256 startTime = currentAuctionStartTime;
            uint256 cw = commitWindow;
            uint256 rw = revealWindow;

            if (phase == IAuctionManager.AuctionPhase.COMMIT
                && block.timestamp >= startTime + cw
            ) {
                _nextPhase();
                phase = am.phase();
            }
            if (phase == IAuctionManager.AuctionPhase.REVEAL
                && block.timestamp >= startTime + cw + rw
            ) {
                _nextPhase();
                phase = am.phase();
            }
        }

        // ─── Step B: cross epoch boundary ───────────────────────────────
        // Two triggers — both depend on AM being tagged to `epoch`:
        //   - EXECUTION past deadline → AM still live; close via
        //     `_closeExecution` → `am.closeExecution` (forfeits winner
        //     if any).
        //   - SETTLED past scheduled epoch end → AM already closed (via
        //     settleExecution or abort); main-side counter accounting
        //     only. `_closeExecution` skips the AM call when
        //     `epochs[e].executed == true`.
        if (am.currentEpoch() == epoch) {
            IAuctionManager.AuctionPhase liveOrSettled = am.phase();
            uint256 execDeadline = currentAuctionStartTime + commitWindow + revealWindow + executionWindow;
            bool pastDeadline = liveOrSettled == IAuctionManager.AuctionPhase.EXECUTION
                && block.timestamp >= execDeadline;
            bool settledAndDone = liveOrSettled == IAuctionManager.AuctionPhase.SETTLED
                && block.timestamp >= _epochStartTime(epoch) + epochDuration;
            if (pastDeadline || settledAndDone) {
                _closeExecution();
                epoch = currentEpoch;
            }
        }

        // ─── Step C: O(1) arithmetic fast-forward through ghost epochs ─
        // Only applies when no live auction is tagged to currentEpoch
        // (AM is SETTLED after the close above, or never matched epoch).
        if (am.phase() == IAuctionManager.AuctionPhase.SETTLED || am.currentEpoch() != epoch) {
            uint256 scheduledStart = _epochStartTime(epoch);
            if (block.timestamp >= scheduledStart + epochDuration) {
                uint256 advance = (block.timestamp - scheduledStart) / epochDuration;
                if (advance > 0) {
                    _advanceEpochBy(advance, advance);
                    epoch = currentEpoch;
                }
            }
        }

        // ─── Step D: open an auction on the landed epoch + cascade phases ─
        // Skipped under FREEZE_SUNSET so the AM stays in SETTLED and
        // `migrate()` can drain without waiting.
        //
        // `_openAuction` freezes the snapshot, binds the base input hash,
        // and sets `currentAuctionStartTime`. This MUST happen for every
        // non-skipped epoch to preserve the meta-invariant (exactly one
        // in-flight auction). The AM always opens in COMMIT; if wall-clock
        // is already past commit/reveal windows, we cascade `_nextPhase`.
        //
        // Guard: if AM is already tagged to the landed epoch (regardless of
        // whether it's mid-auction or already SETTLED), don't re-open. The
        // SETTLED-same-epoch case is the post-submit interregnum — we wait
        // for the scheduled epoch end (Step B fires then) before rolling
        // over to the next epoch. Re-opening the same epoch would be a
        // double-snapshot / double-base-hash bug.
        if (frozenFlags & FREEZE_SUNSET != 0) return;
        if (am.currentEpoch() == epoch) return;
        uint256 newScheduledStart = _epochStartTime(epoch);
        if (block.timestamp < newScheduledStart) return; // epoch hasn't started yet
        _openAuction(epoch, newScheduledStart);

        // Cascade phases to match wall-clock on the newly-opened auction.
        if (block.timestamp >= newScheduledStart + commitWindow) {
            _nextPhase(); // COMMIT → REVEAL
        }
        if (block.timestamp >= newScheduledStart + commitWindow + revealWindow) {
            _nextPhase(); // REVEAL → EXECUTION
        }
    }

    /// @dev Open the next auction for `epoch`. The single freeze site:
    ///      this is the ONLY path that calls `_freezeEpochSnapshot`.
    ///      Every action flows through the auction state machine.
    ///      Steps:
    ///        1. Snapshot ETH/USD price
    ///        2. Call AuctionManager.openAuction with current bond
    ///        3. Freeze the full epoch snapshot (drifting state → storage)
    ///        4. Compute & store the base input hash off the snapshot
    ///        5. Emit AuctionOpened
    ///      At this instant live state == snapshot values, so the input
    ///      hash computed here is consistent with what the prover will
    ///      reproduce off the frozen snapshot.
    function _openAuction(uint256 epoch, uint256 scheduledStart) internal {
        // Re-anchor the epoch schedule. `_openAuction` is the sole site
        // that writes the timing anchor — every open re-centers the
        // schedule so `_epochStartTime(epoch) == scheduledStart` exactly.
        // For wall-clock-driven opens `scheduledStart` equals the schedule's
        // existing time; for manual opens (deploy/nextPhase/reset)
        // `scheduledStart == block.timestamp` so the schedule restarts.
        timingAnchor = scheduledStart;
        anchorEpoch = epoch;
        lastEpochStartTime = scheduledStart;
        currentAuctionStartTime = scheduledStart;

        _snapshotEthUsdPrice();

        // Read once here (main is source of truth for both formulas);
        // AM stores the frozen copies for the life of the auction.
        uint256 maxBidCeiling = effectiveMaxBid();
        uint256 bondAmount = currentBond();
        auctionManager.openAuction(epoch, maxBidCeiling, bondAmount);

        // Freeze drifting state into snapshot. At this instant live state
        // == snapshot values, so _computeInputHash is consistent.
        _freezeEpochSnapshot(epoch);

        bytes32 baseInputHash = _computeInputHash(epoch);
        epochBaseInputHashes[epoch] = baseInputHash;

        emit AuctionOpened(epoch, baseInputHash, maxBidCeiling, bondAmount);
    }

    /// @dev Freeze all drifting state into `_epochSnapshots[epoch]`. Called from
    ///      `_openAuction` at auction open. Must be called at a moment
    ///      when live state represents
    ///      what should be hashed — anything that isn't frozen here is invisible
    ///      to `_hashSnapshot` (by compiler enforcement).
    ///
    ///      Phases:
    ///        1. Copy every scalar the enclave needs
    ///        2. Snapshot investment raw values (so the prover can display them)
    ///        3. Compute all sub-hashes LIVE (nonprofits / messages / history /
    ///           worldview / investments) and freeze them as bytes32 fields
    function _freezeEpochSnapshot(uint256 epoch) internal {
        EpochSnapshot storage snap = _epochSnapshots[epoch];

        // ── 1. Scalars ───────────────────────────────────────────────────
        snap.epoch = epoch;
        snap.balance = address(this).balance;
        snap.commissionRateBps = commissionRateBps;
        snap.maxBid = maxBid;
        snap.effectiveMaxBid = effectiveMaxBid();
        snap.consecutiveMissedEpochs = consecutiveMissedEpochs;
        snap.lastDonationEpoch = lastDonationEpoch;
        snap.lastCommissionChangeEpoch = lastCommissionChangeEpoch;
        snap.totalInflows = totalInflows;
        snap.totalDonatedToNonprofits = totalDonatedToNonprofits;
        snap.totalCommissionsPaid = totalCommissionsPaid;
        snap.totalBountiesPaid = totalBountiesPaid;
        snap.currentEpochInflow = currentEpochInflow;
        snap.currentEpochDonationCount = currentEpochDonationCount;
        snap.epochEthUsdPrice = epochEthUsdPrice;
        snap.epochDuration = epochDuration;
        snap.messageHead = messageHead;
        snap.messageCount = messages.length;
        snap.nonprofitCount = nonprofitCount;

        // ── 2. Investment raw values ─────────────────────────────────────
        // currentValues drift with DeFi yields; active flags can toggle via
        // admin setProtocolActive(). protocolCount is frozen so any
        // protocols added mid-epoch are ignored until the next auction
        // open. name / riskTier / expectedApyBps are immutable
        // post-addProtocol and bound transitively via investmentsHash.
        if (address(investmentManager) != address(0)) {
            uint256 pCount = investmentManager.protocolCount();
            snap.investmentProtocolCount = pCount;
            for (uint256 i = 1; i <= pCount; i++) {
                snap.investmentCurrentValues[i] = investmentManager.getProtocolValue(i);
                snap.investmentActive[i] = investmentManager.isProtocolActive(i);
            }
        }

        // ── 3. Sub-hashes (computed LIVE at this instant) ────────────────
        // These helpers read live storage, but they run exactly once per
        // epoch — RIGHT NOW, when live state == the at-freeze values we
        // want to bind. The resulting bytes32s are stored on the snapshot
        // and consumed by the pure `_hashSnapshot` later.
        snap.nonprofitsHash = _liveHashNonprofits();
        snap.messagesHash = _liveHashUnreadMessages();
        snap.historyHash = _liveHashRecentHistory(epoch);
        snap.worldviewHash = address(worldView) != address(0)
            ? worldView.stateHash()
            : bytes32(0);
        snap.investmentsHash = address(investmentManager) != address(0)
            ? investmentManager.epochStateHash(
                snap.investmentCurrentValues,
                snap.investmentActive,
                snap.investmentProtocolCount
              )
            : bytes32(0);
    }

    // ─── Prover Actions (auto-sync before each) ─────────────────────────

    /// @notice Submit a sealed bid commitment for the current epoch.
    ///         Auto-syncs phase first (opens auction if needed).
    function commit(bytes32 commitHash) external payable {
        _requireNotSunset();
        _advanceToNow();

        uint256 epoch = currentEpoch;
        uint256 requiredBond = auctionManager.bond();
        if (msg.value < requiredBond) revert InvalidParams();

        // Forward exactly the bond to the auction manager. AM enforces
        // phase, msg.value == bond, no-double-commit, MAX_COMMITTERS.
        auctionManager.commit{value: requiredBond}(msg.sender, commitHash);

        // Refund excess ETH sent beyond the bond
        uint256 excess = msg.value - requiredBond;
        if (excess > 0) {
            (bool sent, ) = payable(msg.sender).call{value: excess}("");
            if (!sent) revert TransferFailed();
        }

        emit BidCommitted(epoch, msg.sender);
    }

    /// @notice Reveal a previously committed bid.
    ///         Auto-syncs phase first (closes commit window if needed).
    ///         The max-bid ceiling is enforced by the AM using the value
    ///         stored at auction open — main does NOT re-check live
    ///         `effectiveMaxBid()` here (doing so would let mid-epoch
    ///         treasury moves change the ceiling, which violates the
    ///         snapshot's immutability).
    function reveal(uint256 bidAmount, bytes32 salt) external {
        _advanceToNow();

        uint256 epoch = currentEpoch;
        // AM enforces: phase==REVEAL, commit preimage match, bidAmount>0,
        // bidAmount<=stored maxBid.
        auctionManager.reveal(msg.sender, bidAmount, salt);

        // Main accumulates salts for the seed mix at reveal close.
        epochSaltAccumulator[epoch] ^= salt;

        emit BidRevealed(epoch, msg.sender, bidAmount);
    }

    /// @notice Submit the auction result (winner only).
    ///         Auto-syncs phase first (closes reveal window, captures seed, binds input hash).
    /// @param updates Optional worldview policy updates (array form, best-effort,
    ///                truncated to MAX_POLICY_UPDATES_PER_EPOCH). Duplicate slots
    ///                are applied in order so the last write wins.
    function submitAuctionResult(
        bytes calldata action,
        bytes calldata reasoning,
        bytes calldata proof,
        uint8 verifierId,
        IWorldView.PolicyUpdate[] calldata updates
    ) external payable nonReentrant {
        _advanceToNow();

        uint256 epoch = currentEpoch;
        if (epochs[epoch].executed) revert AlreadyDone();

        // Winner and bounty are AM-owned. Read them BEFORE settleExecution
        // transitions the AM to SETTLED.
        IAuctionManager am = auctionManager;
        if (am.phase() != IAuctionManager.AuctionPhase.EXECUTION) revert InvalidParams();
        if (msg.sender != am.winner()) revert Unauthorized();
        uint256 bountyAmount = am.winningBid();

        // Verify proof (scoped to reduce stack depth).
        {
            IProofVerifier v = verifiers[verifierId];
            if (address(v) == address(0)) revert InvalidParams();
            // outputHash binds the action bytes, reasoning text, AND the
            // worldview update batch. Without the updatesHash term, a
            // malicious prover client could substitute its own worldview
            // updates between the enclave's output and this submission and
            // the DCAP verification would still pass — see
            // prover/enclave/test_output_coverage.py for the analyzer that
            // enforces every enclave output the client trusts is bound here.
            bytes32 outputHash = _computeOutputHash(action, reasoning, updates);
            if (!v.verify{value: msg.value}(epochInputHashes[epoch], outputHash, proof))
                revert ProofFailed();
            epochProofs[epoch] = proof;
        }

        totalBountiesPaid += bountyAmount;

        // Settle in AM: AM validates msg.value == bountyAmount, combines
        // with held bond, pushes (bond + bounty) to winner. Transitions
        // AM to SETTLED. Main's _advanceToNow will later open the next
        // auction on the next sync.
        am.settleExecution{value: bountyAmount}();

        emit EpochExecuted(epoch, msg.sender, bountyAmount);

        _applyPolicyUpdates(updates);
        _recordAndExecute(epoch, action, reasoning, bountyAmount);
    }

    // ─── Internal: Price Snapshot ───────────────────────────────────────

    /// @dev Snapshot Chainlink ETH/USD price for this epoch.
    ///      Silently sets 0 if feed is not configured or returns stale/negative data.
    function _snapshotEthUsdPrice() internal {
        if (address(ethUsdFeed) == address(0)) {
            epochEthUsdPrice = 0;
            return;
        }
        try ethUsdFeed.latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer > 0 && block.timestamp - updatedAt <= PRICE_STALENESS_THRESHOLD) {
                epochEthUsdPrice = uint256(answer);
            } else {
                epochEthUsdPrice = 0;
            }
        } catch {
            epochEthUsdPrice = 0;
        }
    }

    // ─── Internal: Output Hash (must mirror prover/enclave/attestation.py) ─

    /// @notice Compute the outputHash bound by REPORTDATA. Public so the
    ///         cross-stack FFI test in test/CrossStackHash.t.sol can compare
    ///         this to the Python `compute_report_data` output for the same
    ///         inputs.
    /// @dev    MUST match `compute_report_data` in
    ///         `prover/enclave/attestation.py` byte-for-byte. Any change
    ///         here requires a symmetric Python change AND a CrossStackHash
    ///         test update — otherwise live submissions revert.
    function computeOutputHash(
        bytes calldata action,
        bytes calldata reasoning,
        IWorldView.PolicyUpdate[] calldata updates
    ) external pure returns (bytes32) {
        return _computeOutputHash(action, reasoning, updates);
    }

    function _computeOutputHash(
        bytes calldata action,
        bytes calldata reasoning,
        IWorldView.PolicyUpdate[] calldata updates
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            sha256(action),
            sha256(reasoning),
            _hashSubmittedUpdates(updates)
        ));
    }

    /// @dev Rolling hash over the submitted worldview updates. Empty list
    ///      → bytes32(0). Each entry is hashed as
    ///      `keccak256(abi.encode(slot, title, body))`, then folded into
    ///      `rolling = keccak256(abi.encode(rolling, item))`. Same pattern
    ///      as _hashNonprofits / _hashUnreadMessages elsewhere in the
    ///      contract; mirrored byte-for-byte by
    ///      `_hash_submitted_updates` in attestation.py.
    function _hashSubmittedUpdates(IWorldView.PolicyUpdate[] calldata updates)
        internal pure returns (bytes32)
    {
        if (updates.length == 0) return bytes32(0);
        bytes32 rolling = bytes32(0);
        for (uint256 i = 0; i < updates.length; i++) {
            bytes32 itemHash = keccak256(abi.encode(
                updates[i].slot,
                updates[i].title,
                updates[i].body
            ));
            rolling = keccak256(abi.encode(rolling, itemHash));
        }
        return rolling;
    }

    // ─── Internal: Epoch Recording ─────────────────────────────────────

    /// @dev Apply worldview policy updates. Best-effort — individual failures
    ///      are silently ignored so one bad entry can't block payment or block
    ///      the rest of the batch. Batch is capped at MAX_POLICY_UPDATES_PER_EPOCH
    ///      (extra entries are silently dropped). Duplicate slots are applied
    ///      in order — last write wins.
    function _applyPolicyUpdates(IWorldView.PolicyUpdate[] calldata updates) internal {
        if (address(worldView) == address(0)) return;
        uint256 n = updates.length;
        if (n > MAX_POLICY_UPDATES_PER_EPOCH) {
            n = MAX_POLICY_UPDATES_PER_EPOCH;
        }
        for (uint256 i = 0; i < n; i++) {
            try worldView.setPolicy(
                uint256(updates[i].slot),
                updates[i].title,
                updates[i].body
            ) {
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
        // bountyPaid is included so the enclave's lifespan / burn-rate math
        // cannot be manipulated by a runner lying about past epoch costs.
        epochContentHashes[epoch] = keccak256(abi.encode(
            keccak256(reasoning), keccak256(action), treasuryBefore, treasuryAfter, bountyPaid
        ));

        // Advance message head using the frozen count captured at auction open.
        // The model only saw messages in [messageHead, frozenCount) — any message
        // that arrived between auction open and execution has index >= frozenCount
        // and must survive until a future epoch's snapshot picks it up. Using the
        // live messages.length here would silently skip past those late arrivals.
        uint256 frozenCount = _epochSnapshots[epoch].messageCount;
        uint256 newlyReadMessages = frozenCount - messageHead;
        if (newlyReadMessages > MAX_MESSAGES_PER_EPOCH) {
            messageHead += MAX_MESSAGES_PER_EPOCH;
        } else {
            messageHead = frozenCount;
        }

        // Per-epoch counter resets (currentEpochInflow / DonationCount /
        // Commissions) and escalation counter resets happen later in
        // `_closeExecution` → `_advanceEpochBy` when the epoch formally
        // ends. That keeps every epoch-end mutation in exactly one site.
    }

    // ─── Internal: Action Execution ──────────────────────────────────────

    /// @dev Execute the model's chosen action. Out-of-bounds parameters cause
    ///      a no-op (not a revert) — the prover did their job, the model made
    ///      a bad choice. The raw action bytes are still recorded in the epoch
    ///      history so future prompts can see what was attempted.
    function _executeAction(uint256 epoch, bytes calldata action) internal {
        if (action.length < 1) {
            emit ActionRejected(epoch, action, 1);
            return;
        }

        uint8 actionType = uint8(action[0]);

        if (actionType == 0) {
            // do_nothing — action_type 0 is the explicit no-action opcode
            return;
        } else if (actionType == 1) {
            // donate
            if (action.length < 65) {
                emit ActionRejected(epoch, action, 2);
                return;
            }
            (uint256 nonprofitId, uint256 amount) = abi.decode(action[1:], (uint256, uint256));
            if (!_executeDonate(epoch, nonprofitId, amount)) {
                emit ActionRejected(epoch, action, 3);
            }
        } else if (actionType == 2) {
            // set_commission_rate
            if (action.length < 33) {
                emit ActionRejected(epoch, action, 2);
                return;
            }
            uint256 rateBps = abi.decode(action[1:], (uint256));
            if (!_executeSetCommissionRate(epoch, rateBps)) {
                emit ActionRejected(epoch, action, 3);
            }
        } else if (actionType == 3) {
            // invest — delegate to InvestmentManager
            if (action.length < 65 || address(investmentManager) == address(0)) {
                emit ActionRejected(epoch, action, 4);
                return;
            }
            (uint256 pid, uint256 amt) = abi.decode(action[1:], (uint256, uint256));
            try investmentManager.deposit{value: amt}(pid, amt) {
                // success
            } catch {
                emit ActionRejected(epoch, action, 5);
            }
        } else if (actionType == 4) {
            // withdraw — delegate to InvestmentManager
            if (action.length < 65 || address(investmentManager) == address(0)) {
                emit ActionRejected(epoch, action, 6);
                return;
            }
            (uint256 pid, uint256 amt) = abi.decode(action[1:], (uint256, uint256));
            try investmentManager.withdraw(pid, amt) {
                // success — ETH comes back to this contract via receive()
            } catch {
                emit ActionRejected(epoch, action, 7);
            }
        } else {
            emit ActionRejected(epoch, action, 10);
        }
    }

    /// @dev Bounds-check then delegate to DonationExecutor for the
    ///      ETH → WETH → USDC → Endaoment pipeline. State updates
    ///      (nonprofit totals, global counters) stay here on the fund.
    function _executeDonate(uint256 epoch, uint256 nonprofitId, uint256 amount) internal returns (bool) {
        if (nonprofitId < 1 || nonprofitId > nonprofitCount) return false;
        if (amount == 0) return false;

        uint256 maxDonation = (address(this).balance * MAX_DONATION_BPS) / 10000;
        if (amount > maxDonation) return false;

        Nonprofit storage np = nonprofits[nonprofitId];
        if (!np.exists) return false;

        // Delegate the DeFi pipeline to DonationExecutor.
        // Guard + try/catch so a misconfigured or absent executor
        // results in a no-op (ActionRejected) rather than a revert.
        if (address(donationExecutor).code.length == 0) return false;
        uint256 usdcAmount;
        try donationExecutor.executeDonate{value: amount}(np.ein) returns (uint256 result) {
            usdcAmount = result;
        } catch {
            return false;
        }
        if (usdcAmount == 0) return false;

        np.totalDonated += amount;
        np.totalDonatedUsd += usdcAmount;
        np.donationCount += 1;
        totalDonatedToNonprofits += amount;
        totalDonatedToNonprofitsUsd += usdcAmount;
        lastDonationEpoch = epoch;

        emit NonprofitDonation(epoch, nonprofitId, amount, usdcAmount);
        return true;
    }

    /// @dev Returns false if parameters are out of bounds (action becomes a no-op).
    function _executeSetCommissionRate(uint256 epoch, uint256 rateBps) internal returns (bool) {
        if (rateBps < MIN_COMMISSION_BPS || rateBps > MAX_COMMISSION_BPS) return false;
        commissionRateBps = rateBps;
        lastCommissionChangeEpoch = epoch;
        emit CommissionRateChanged(epoch, rateBps);
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
    /// @dev Compute the input hash for a given epoch's frozen snapshot.
    ///      Reads one mapping slot (the snapshot), then delegates to
    ///      `_hashSnapshot` which is `pure` — the compiler mechanically
    ///      proves no other storage is read.
    function _computeInputHash(uint256 epoch) internal view returns (bytes32) {
        return _hashSnapshot(_epochSnapshots[epoch]);
    }

    /// @dev THE ONE TRUE INPUT HASH. `pure` by compiler decree: no storage
    ///      reads, no live contract calls, no hidden drift. Everything the
    ///      enclave sees must flow through the struct argument. If you
    ///      want to add a new field to the prompt, you must first add it
    ///      to `EpochSnapshot` and populate it in `_freezeEpochSnapshot`.
    function _hashSnapshot(EpochSnapshot memory snap) internal pure returns (bytes32) {
        bytes32 scalarHash = _hashSnapshotScalars(snap);
        return keccak256(abi.encode(
            scalarHash,
            snap.nonprofitsHash,
            snap.investmentsHash,
            snap.worldviewHash,
            snap.messagesHash,
            snap.historyHash
        ));
    }

    /// @dev Scalar portion of the snapshot hash. Split in halves to avoid
    ///      stack-too-deep with ~20 fields.
    function _hashSnapshotScalars(EpochSnapshot memory snap) internal pure returns (bytes32) {
        bytes32 h1 = keccak256(abi.encode(
            snap.epoch,
            snap.balance,
            snap.commissionRateBps,
            snap.maxBid,
            snap.effectiveMaxBid,
            snap.consecutiveMissedEpochs,
            snap.lastDonationEpoch,
            snap.lastCommissionChangeEpoch,
            snap.totalInflows
        ));
        return keccak256(abi.encode(
            h1,
            snap.totalDonatedToNonprofits,
            snap.totalCommissionsPaid,
            snap.totalBountiesPaid,
            snap.currentEpochInflow,
            snap.currentEpochDonationCount,
            snap.epochEthUsdPrice,
            snap.epochDuration,
            snap.messageHead,
            snap.messageCount,
            snap.nonprofitCount
        ));
    }

    // ─── Live sub-hashers — called ONLY from _freezeEpochSnapshot ───────
    //
    // These helpers read live storage, which is exactly what we need at
    // freeze time (when live state == the at-freeze values we want to bind).
    // They are NEVER called from the input-hash path — `_hashSnapshot` is
    // `pure` and physically cannot invoke them. Their outputs are stored
    // as bytes32 fields on the snapshot and re-read from there.
    //
    // The rolling-hash shapes below are duplicated byte-for-byte in the
    // Python mirror (`prover/enclave/input_hash.py`) and tested for parity
    // via the FFI cross-stack test.

    /// @dev Live rolling hash of the current nonprofit registry.
    function _liveHashNonprofits() internal view returns (bytes32) {
        if (nonprofitCount == 0) return bytes32(0);
        bytes32 rolling;
        for (uint256 i = 1; i <= nonprofitCount; i++) {
            Nonprofit storage np = nonprofits[i];
            // `i` is included per-entry so the enclave can safely use
            // np["id"] from runner-supplied state. Without this, a runner
            // could swap id fields across entries (identical content hash)
            // and trick the model into donating to the wrong nonprofit.
            bytes32 itemHash = keccak256(abi.encode(
                i, np.name, np.description, np.ein, np.totalDonated, np.totalDonatedUsd, np.donationCount
            ));
            rolling = keccak256(abi.encode(rolling, itemHash));
        }
        return rolling;
    }

    /// @dev Live rolling hash of the unread-messages queue.
    function _liveHashUnreadMessages() internal view returns (bytes32) {
        uint256 unread = messages.length - messageHead;
        uint256 count = unread > MAX_MESSAGES_PER_EPOCH ? MAX_MESSAGES_PER_EPOCH : unread;
        if (count == 0) return bytes32(0);

        bytes32 rolling;
        for (uint256 i = 0; i < count; i++) {
            rolling = keccak256(abi.encode(rolling, messageHashes[messageHead + i]));
        }
        return rolling;
    }

    /// @dev Live rolling hash of recent epoch content hashes.
    ///      Takes the epoch as a parameter so callers can compute the
    ///      history rolling up to any target epoch.
    function _liveHashRecentHistory(uint256 epoch) internal view returns (bytes32) {
        if (epoch == 0) return bytes32(0);

        uint256 count = epoch > MAX_HISTORY_ENTRIES ? MAX_HISTORY_ENTRIES : epoch;
        bytes32 rolling;
        for (uint256 i = 0; i < count; i++) {
            uint256 histEpoch = epoch - 1 - i;  // most recent first
            rolling = keccak256(abi.encode(rolling, epochContentHashes[histEpoch]));
        }
        return rolling;
    }

    // ─── Views ───────────────────────────────────────────────────────────

    /// @notice Effective max bid ceiling with auto-escalation for missed epochs.
    ///
    /// Formula: `effectiveMaxBid = min(treasury * MAX_BID_BPS / 10000,
    ///                                 maxBid * (1 + AUTO_ESCALATION_BPS/10000)^consecutiveMissedEpochs)`
    ///
    /// The `maxBid` state variable is the starting point (owner-configured
    /// at deploy). As missed epochs accumulate, the bid ceiling grows by
    /// AUTO_ESCALATION_BPS (10%) per miss, bounded at MAX_BID_BPS (10%)
    /// of the current treasury. When an epoch executes successfully,
    /// `consecutiveMissedEpochs` resets and so does the escalated ceiling.
    function effectiveMaxBid() public view returns (uint256) {
        return _maxBidFor(consecutiveMissedEpochs, address(this).balance);
    }

    /// @dev Pure formula for the effective max-bid ceiling given a missed-
    ///      counter value and a treasury balance. Single source of truth for
    ///      max-bid math, consumed by `effectiveMaxBid()` and by
    ///      `projectedMaxBid()` (via `_projectCounters`). Any change to the
    ///      formula only needs to happen here.
    function _maxBidFor(uint256 missed, uint256 treasury) internal view returns (uint256) {
        uint256 cap = (treasury * MAX_BID_BPS) / 10000;

        uint256 effective = maxBid;
        for (uint256 i = 0; i < missed; i++) {
            effective = effective + (effective * AUTO_ESCALATION_BPS) / 10000;
            if (effective >= cap) return cap;
        }
        return effective > cap ? cap : effective;
    }

    /// @notice Compute the epoch input hash from current contract state.
    /// @dev Public view for runners to verify their input matches.
    ///      Note: after auction open, live state may drift due to donations/messages/yields.
    ///      Use getEpochSnapshot() to read the frozen values that the input hash was computed from.
    function computeInputHash() external view returns (bytes32) {
        return _computeInputHash(currentEpoch);
    }

    /// @notice Compute the input hash for a specific epoch's frozen snapshot.
    /// @dev Drift-free: reads only from the frozen snapshot struct and
    ///      delegates to the pure `_hashSnapshot`. Returns zero for epochs
    ///      whose snapshot was never populated.
    function computeInputHashForEpoch(uint256 epoch) external view returns (bytes32) {
        return _computeInputHash(epoch);
    }

    /// @notice Get the frozen state snapshot for an epoch.
    /// @dev Populated at auction open. Contains drifting values (balance, inflows, messages,
    ///      investment positions) frozen at the instant the input hash was computed.
    function getEpochSnapshot(uint256 epoch) external view returns (EpochSnapshot memory) {
        return _epochSnapshots[epoch];
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
    function getNonprofit(uint256 id) external view returns (
        string memory name, string memory description, bytes32 ein,
        uint256 totalDonated, uint256 totalDonatedUsd, uint256 donationCount
    ) {
        if (id < 1 || id > nonprofitCount) revert InvalidParams();
        Nonprofit storage np = nonprofits[id];
        return (np.name, np.description, np.ein, np.totalDonated, np.totalDonatedUsd, np.donationCount);
    }

    /// @notice Get epoch record.
    function getEpochRecord(uint256 epoch) external view returns (
        uint256 timestamp, bytes memory action, bytes memory reasoning,
        uint256 treasuryBefore, uint256 treasuryAfter, uint256 bountyPaid, bool executed
    ) {
        EpochRecord storage r = epochs[epoch];
        return (r.timestamp, r.action, r.reasoning, r.treasuryBefore, r.treasuryAfter, r.bountyPaid, r.executed);
    }


    // Projection views (projectedEpoch, projectedPhase, projectedMaxBid,
    // projectedCurrentBond) are intentionally NOT implemented on-chain.
    // The only consumer is the frontend (`index.html`), which computes
    // these values in JavaScript from raw state reads. Keeping projection
    // logic off-chain avoids both bytecode bloat and the drift risk of
    // mirroring `_advanceToNow`'s arithmetic in a view.

    /// @notice Compute the deterministic scheduled start time for any epoch.
    function epochStartTime(uint256 epoch) external view returns (uint256) {
        return _epochStartTime(epoch);
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

    // Allow receiving ETH directly (for seed funding).
    //
    // The AuctionManager pushes forfeited bonds / bond refunds into the fund,
    // and the InvestmentManager pushes ETH back when positions are withdrawn
    // (either by a model `withdraw` action or by `migrate`'s unwind path).
    // Those internal transfers must succeed even after FREEZE_SUNSET, otherwise
    // settling an in-flight auction reverts, `_advanceToNow` reverts, and the
    // fund deadlocks with no way to `migrate()` (which aborts + drains the
    // in-flight auction unconditionally). So `_requireNotSunset` is bypassed
    // for those two trusted internal senders only.
    receive() external payable {
        if (msg.sender != address(auctionManager) && msg.sender != address(investmentManager)) {
            _requireNotSunset();
        }
        totalInflows += msg.value;
    }
}
