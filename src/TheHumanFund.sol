// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IProofVerifier.sol";
import "./interfaces/IInvestmentManager.sol";
import "./interfaces/IAuctionManager.sol";
import "./interfaces/IWorldView.sol";
import "./interfaces/IEndaoment.sol";
import "./interfaces/IAggregatorV3.sol";
import "./adapters/IWETH.sol";
import "./adapters/SwapHelper.sol"; // for ISwapRouter, IERC20

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
    event MaxBidChanged(uint256 indexed epoch, uint256 newMaxBid);
    event ReferralCodeMinted(uint256 indexed codeId, address indexed owner);
    event CommissionPaid(address indexed referrer, uint256 amount, uint256 referralCodeId);
    event EpochStarted(uint256 indexed epoch, bytes32 inputHash);

    // Auction events
    event AuctionOpened(uint256 indexed epoch, bytes32 inputHash, uint256 maxBidCeiling, uint256 bond);
    event BidCommitted(uint256 indexed epoch, address indexed runner);
    event BidRevealed(uint256 indexed epoch, address indexed runner, uint256 bidAmount);
    event RevealClosed(uint256 indexed epoch, address indexed winner, uint256 winningBid);
    event EpochExecuted(uint256 indexed epoch, address indexed runner, uint256 bountyPaid);
    event BondForfeited(uint256 indexed epoch, address indexed runner, uint256 bondAmount);
    event AuctionModeChanged(bool enabled);
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
    uint256 public constant MAX_BID_BPS = 200;             // 2% of treasury
    uint256 public constant MIN_DONATION_AMOUNT = 0.001 ether;
    uint256 public constant AUTO_ESCALATION_BPS = 1000;    // 10% increase per missed epoch
    uint256 public constant MAX_NONPROFITS = 20;
    uint256 public constant BASE_BOND = 0.001 ether;        // Fixed bond, escalates on missed epochs
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
    uint256 public totalDonatedToNonprofitsUsd;  // USDC (6 decimals) — actual swap outputs
    uint256 public totalCommissionsPaid;
    uint256 public totalBountiesPaid;

    // Epoch tracking
    uint256 public lastDonationEpoch;
    uint256 public lastCommissionChangeEpoch;
    uint256 public consecutiveMissedEpochs;

    // Nonprofits (1-indexed for the agent's benefit)
    uint256 public nonprofitCount;
    mapping(uint256 => Nonprofit) public nonprofits;

    // Endaoment integration (Base mainnet addresses passed via constructor)
    IEndaomentFactory public immutable endaomentFactory;
    IWETH public immutable weth;
    address public immutable usdc;
    address public immutable swapRouter;

    // Chainlink ETH/USD price feed
    IAggregatorV3 public immutable ethUsdFeed;
    uint256 public epochEthUsdPrice;  // Snapshotted at epoch start (feed decimals, typically 8)

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

    // Auction manager (separate contract — see AuctionManager.sol)
    IAuctionManager public auctionManager;

    // Kill switches — bitmask flags, once set permanently disable the corresponding methods.
    uint256 public constant FREEZE_NONPROFITS          = 1 << 0;
    uint256 public constant FREEZE_INVESTMENT_WIRING   = 1 << 1;
    uint256 public constant FREEZE_WORLDVIEW_WIRING    = 1 << 2;
    uint256 public constant FREEZE_AUCTION_CONFIG      = 1 << 3;
    uint256 public constant FREEZE_VERIFIERS           = 1 << 4;
    uint256 public constant FREEZE_PROMPT              = 1 << 5;
    uint256 public constant FREEZE_DIRECT_MODE         = 1 << 6;
    uint256 public constant FREEZE_EMERGENCY_WITHDRAWAL = 1 << 7;
    uint256 public frozenFlags;

    event PermissionFrozen(uint256 indexed flag);

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(
        uint256 _initialCommissionBps,
        uint256 _initialMaxBid,
        address _endaomentFactory,
        address _weth,
        address _usdc,
        address _swapRouter,
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

        // Default epoch duration (can be overridden via setAuctionTiming)
        epochDuration = 24 hours;

        // Endaoment integration addresses
        endaomentFactory = IEndaomentFactory(_endaomentFactory);
        weth = IWETH(_weth);
        usdc = _usdc;
        swapRouter = _swapRouter;
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

    /// @notice Submit the AI agent's action with an optional worldview update.
    /// @param action The encoded action blob.
    /// @param reasoning The agent's chain-of-thought reasoning.
    /// @param policySlot The worldview slot to update (0-9), or -1 to skip.
    /// @param policyText The policy text (max 280 chars). Ignored if policySlot is -1.
    function submitEpochAction(
        bytes calldata action,
        bytes calldata reasoning,
        int8 policySlot,
        string calldata policyText
    ) external onlyOwner {
        if (frozenFlags & FREEZE_DIRECT_MODE != 0) revert Frozen();
        if (auctionEnabled) revert WrongPhase();
        uint256 epoch = currentEpoch;
        if (epochs[epoch].executed) revert AlreadyDone();
        _snapshotEthUsdPrice();
        _applyPolicyUpdate(policySlot, policyText);
        _recordAndExecute(epoch, action, reasoning, 0);
    }

    /// @notice Skip the current epoch (no runner bid or missed deadline).
    function skipEpoch() external onlyOwner {
        if (frozenFlags & FREEZE_DIRECT_MODE != 0) revert Frozen();
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

    /// @notice Withdraw all DeFi positions and transfer entire treasury to owner.
    /// @dev Emergency shutdown: unwinds all investments, sends everything to owner.
    function withdrawAll() external onlyOwner {
        if (frozenFlags & FREEZE_EMERGENCY_WITHDRAWAL != 0) revert Frozen();
        // Unwind all DeFi positions — ETH sent directly to owner
        if (address(investmentManager) != address(0)) {
            investmentManager.withdrawAll(owner);
        }

        // Transfer remaining liquid balance to owner
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool sent, ) = owner.call{value: bal}("");
            if (!sent) revert TransferFailed();
        }
    }

    function setWorldView(address _wv) external onlyOwner {
        if (frozenFlags & FREEZE_WORLDVIEW_WIRING != 0) revert Frozen();
        worldView = IWorldView(_wv);
    }

    /// @notice Set the auction manager contract address.
    function setAuctionManager(address _am) external onlyOwner {
        if (frozenFlags & FREEZE_AUCTION_CONFIG != 0) revert Frozen();
        auctionManager = IAuctionManager(_am);
    }

    /// @notice Set the approved system prompt hash.
    /// @dev The TEE hashes the prompt it receives and includes it in REPORTDATA.
    ///      The contract verifies it matches this value during auction settlement.
    function setApprovedPromptHash(bytes32 _hash) external onlyOwner {
        if (frozenFlags & FREEZE_PROMPT != 0) revert Frozen();
        approvedPromptHash = _hash;
    }

    /// @notice Seed multiple worldview policies at once. Only callable by owner.
    /// @dev Intended for initial setup before the fund goes live.
    function seedWorldView(uint256[] calldata slots, string[] calldata policies) external onlyOwner {
        if (frozenFlags & FREEZE_WORLDVIEW_WIRING != 0) revert Frozen();
        require(address(worldView) != address(0), "no worldview");
        require(slots.length == policies.length, "length mismatch");
        for (uint256 i = 0; i < slots.length; i++) {
            worldView.setPolicy(slots[i], policies[i]);
        }
    }

    // ─── Kill Switches ────────────────────────────────────────────────────

    /// @notice Permanently freeze a permission group. Once frozen, methods guarded
    ///         by that flag will revert with Frozen(). Cannot be undone.
    /// @param flag The permission flag (e.g., FREEZE_NONPROFITS, FREEZE_DIRECT_MODE).
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

    /// @notice Enable or disable auction mode.
    function setAuctionEnabled(bool enabled) external onlyOwner {
        if (frozenFlags & FREEZE_AUCTION_CONFIG != 0) revert Frozen();
        auctionEnabled = enabled;
        emit AuctionModeChanged(enabled);
    }

    /// @notice Set auction timing parameters (owner-only, for testnet tuning).
    function setAuctionTiming(
        uint256 _epochDuration,
        uint256 _commitWindow,
        uint256 _revealWindow,
        uint256 _executionWindow
    ) external onlyOwner {
        if (frozenFlags & FREEZE_AUCTION_CONFIG != 0) revert Frozen();
        if (_commitWindow + _revealWindow + _executionWindow > _epochDuration) revert InvalidParams();
        epochDuration = _epochDuration;
        auctionManager.setTiming(_commitWindow, _revealWindow, _executionWindow);
    }

    /// @notice Current bond amount — fixed base that escalates 10% per consecutive missed epoch.
    function currentBond() public view returns (uint256) {
        uint256 bond = BASE_BOND;
        for (uint256 i = 0; i < consecutiveMissedEpochs; i++) {
            bond = bond + (bond * AUTO_ESCALATION_BPS) / 10000;
        }
        return bond;
    }

    /// @notice Open the auction for the current epoch. Anyone can call this.
    function startEpoch() external {
        if (!auctionEnabled) revert WrongPhase();
        IAuctionManager am = auctionManager;
        uint256 epoch = currentEpoch;

        // Auto-forfeit a stale previous auction if needed
        if (epoch > 1 && am.getPhase(epoch - 1) == IAuctionManager.AuctionPhase.EXECUTION) {
            // forfeitExecution validates the execution window has expired
            address forfeitedRunner = am.getWinner(epoch - 1);
            uint256 forfeitedBond = am.getBond(epoch - 1);
            am.forfeitExecution(epoch - 1);
            _advanceEpochMissed();
            emit BondForfeited(epoch - 1, forfeitedRunner, forfeitedBond);
            epoch = currentEpoch; // re-read after advancement
        }

        // Enforce epoch pacing: previous epoch's full duration must have elapsed.
        if (epoch > 1) {
            uint256 prevStart = am.getStartTime(epoch - 1);
            if (prevStart > 0 && block.timestamp < prevStart + epochDuration) revert TimingError();
        }

        _snapshotEthUsdPrice();

        uint256 bond = currentBond();
        am.openAuction(epoch, bond);

        bytes32 baseInputHash = _computeInputHash();
        epochBaseInputHashes[epoch] = baseInputHash;

        emit AuctionOpened(epoch, baseInputHash, effectiveMaxBid(), bond);
    }

    /// @notice Submit a sealed bid commitment for the current epoch.
    function commit(bytes32 commitHash) external payable {
        if (!auctionEnabled) revert WrongPhase();
        uint256 epoch = currentEpoch;
        uint256 bond = auctionManager.getBond(epoch);
        if (msg.value < bond) revert InvalidParams();

        // Forward exactly the bond to the auction manager
        auctionManager.commit{value: bond}(epoch, msg.sender, commitHash);

        // Refund excess ETH sent beyond the bond
        uint256 excess = msg.value - bond;
        if (excess > 0) {
            (bool sent, ) = payable(msg.sender).call{value: excess}("");
            if (!sent) revert TransferFailed();
        }

        emit BidCommitted(epoch, msg.sender);
    }

    /// @notice Close the commit phase. Anyone can call after commit window expires.
    function closeCommit() external {
        if (!auctionEnabled) revert WrongPhase();
        uint256 commitCount = auctionManager.closeCommitPhase(currentEpoch);
        if (commitCount == 0) {
            _advanceEpochMissed();
        }
    }

    /// @notice Reveal a previously committed bid.
    function reveal(uint256 bidAmount, bytes32 salt) external {
        if (!auctionEnabled) revert WrongPhase();
        if (bidAmount == 0 || bidAmount > effectiveMaxBid()) revert InvalidParams();
        auctionManager.recordReveal(currentEpoch, msg.sender, bidAmount, salt);
        emit BidRevealed(currentEpoch, msg.sender, bidAmount);
    }

    /// @notice Close the reveal phase. Anyone can call after reveal window.
    function closeReveal() external {
        if (!auctionEnabled) revert WrongPhase();
        uint256 epoch = currentEpoch;
        (address winner, uint256 winningBid, uint256 revealCount) = auctionManager.closeRevealPhase(epoch);

        if (revealCount == 0) {
            _advanceEpochMissed();
            return;
        }

        // Bind randomness to the input hash
        uint256 seed = auctionManager.getRandomnessSeed(epoch);
        epochInputHashes[epoch] = keccak256(abi.encodePacked(
            epochBaseInputHashes[epoch],
            seed
        ));

        emit RevealClosed(epoch, winner, winningBid);
    }

    /// @notice Submit the auction result (winner only).
    function submitAuctionResult(
        bytes calldata action,
        bytes calldata reasoning,
        bytes calldata proof,
        uint8 verifierId,
        int8 policySlot,
        string calldata policyText
    ) external payable {
        if (!auctionEnabled) revert WrongPhase();
        uint256 epoch = currentEpoch;

        // Settle auction — AM validates phase, caller==winner, and timing.
        // Refunds bond to the winner.
        auctionManager.settleExecution(epoch, msg.sender);

        // Verify proof and pay bounty (scoped to reduce stack depth)
        uint256 bountyAmount;
        {
            IProofVerifier v = verifiers[verifierId];
            if (address(v) == address(0)) revert InvalidParams();
            bytes32 outputHash = keccak256(abi.encodePacked(
                sha256(action), sha256(reasoning), approvedPromptHash
            ));
            if (!v.verify{value: msg.value}(epochInputHashes[epoch], outputHash, proof))
                revert ProofFailed();
            epochProofs[epoch] = proof;

            bountyAmount = auctionManager.getWinningBid(epoch);
            totalBountiesPaid += bountyAmount;
            (bool paid, ) = payable(msg.sender).call{value: bountyAmount}("");
            if (!paid) revert TransferFailed();
        }

        emit EpochExecuted(epoch, msg.sender, bountyAmount);

        _applyPolicyUpdate(policySlot, policyText);
        _recordAndExecute(epoch, action, reasoning, bountyAmount);
    }

    /// @notice Forfeit the winner's bond after the execution window expires.
    function forfeitBond() external {
        if (!auctionEnabled) revert WrongPhase();
        uint256 epoch = currentEpoch;
        IAuctionManager am = auctionManager;

        // AM validates phase and timing
        address forfeitedRunner = am.getWinner(epoch);
        uint256 forfeitedBond = am.getBond(epoch);
        am.forfeitExecution(epoch);
        _advanceEpochMissed();

        emit BondForfeited(epoch, forfeitedRunner, forfeitedBond);
    }

    /// @dev Advance epoch on a missed/forfeited epoch.
    function _advanceEpochMissed() internal {
        consecutiveMissedEpochs += 1;
        currentEpoch += 1;
        currentEpochInflow = 0;
        currentEpochDonationCount = 0;
        currentEpochCommissions = 0;
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
            uint80, int256 answer, uint256, uint256, uint80
        ) {
            epochEthUsdPrice = answer > 0 ? uint256(answer) : 0;
        } catch {
            epochEthUsdPrice = 0;
        }
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
            emit ActionRejected(epoch, action, 1);
            return;
        }

        uint8 actionType = uint8(action[0]);

        if (actionType == 0) {
            // noop — do nothing
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
            // set_max_bid
            if (action.length < 33) {
                emit ActionRejected(epoch, action, 2);
                return;
            }
            uint256 amount = abi.decode(action[1:], (uint256));
            if (!_executeSetMaxBid(epoch, amount)) {
                emit ActionRejected(epoch, action, 3);
            }
        } else if (actionType == 4) {
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
        } else if (actionType == 5) {
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
        } else if (actionType == 6) {
            // set_guiding_policy — delegate to WorldView contract
            if (action.length < 33 || address(worldView) == address(0)) {
                emit ActionRejected(epoch, action, 8);
                return;
            }
            // Forward raw ABI-encoded (uint256 slot, string policy) to WorldView
            (bool ok, ) = address(worldView).call(
                abi.encodePacked(IWorldView.setPolicy.selector, action[1:])
            );
            if (!ok) {
                emit ActionRejected(epoch, action, 9);
            }
        } else {
            emit ActionRejected(epoch, action, 10);
        }
    }

    /// @dev Returns false if parameters are out of bounds (action becomes noop).
    function _executeDonate(uint256 epoch, uint256 nonprofitId, uint256 amount) internal returns (bool) {
        if (nonprofitId < 1 || nonprofitId > nonprofitCount) return false;
        if (amount == 0) return false;

        uint256 maxDonation = (address(this).balance * MAX_DONATION_BPS) / 10000;
        if (amount > maxDonation) return false;

        Nonprofit storage np = nonprofits[nonprofitId];
        if (!np.exists) return false;

        // Compute Endaoment org address from EIN (deterministic via CREATE2)
        address orgAddr = endaomentFactory.computeOrgAddress(np.ein);

        // Deploy org if not yet deployed on this chain (one-time cost)
        if (orgAddr.code.length == 0) {
            endaomentFactory.deployOrg(np.ein);
        }

        // Swap ETH → USDC via Uniswap V3
        weth.deposit{value: amount}();
        weth.approve(swapRouter, amount);
        uint256 usdcAmount = ISwapRouter(swapRouter).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: usdc,
                fee: 500,
                recipient: address(this),
                amountIn: amount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // Donate USDC to Endaoment org
        IERC20(usdc).approve(orgAddr, usdcAmount);
        IEndaomentOrg(orgAddr).donate(usdcAmount);

        np.totalDonated += amount;
        np.totalDonatedUsd += usdcAmount;
        np.donationCount += 1;
        totalDonatedToNonprofits += amount;
        totalDonatedToNonprofitsUsd += usdcAmount;
        lastDonationEpoch = epoch;

        emit NonprofitDonation(epoch, nonprofitId, amount, usdcAmount);
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
            currentEpochDonationCount,
            epochEthUsdPrice
        ));
    }

    /// @dev Hash nonprofit state (dynamic entries, includes description + EIN).
    function _hashNonprofits() internal view returns (bytes32) {
        if (nonprofitCount == 0) return bytes32(0);
        bytes memory packed;
        for (uint256 i = 1; i <= nonprofitCount; i++) {
            Nonprofit storage np = nonprofits[i];
            packed = abi.encodePacked(packed, keccak256(abi.encode(
                np.name, np.description, np.ein, np.totalDonated, np.totalDonatedUsd, np.donationCount
            )));
        }
        return keccak256(packed);
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
