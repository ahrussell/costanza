// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IAuctionManager.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionManager
/// @notice Auction state machine for commit-reveal sealed-bid auctions.
///         Phase advancement is automatic: syncPhase() advances through any
///         elapsed phase windows based on block.timestamp vs wall-clock deadlines.
///         Bond refunds are lazy: non-winning revealers call claimBond(epoch).
///         Only the fund contract can call state-transition functions.
contract AuctionManager is IAuctionManager, ReentrancyGuard {
    // ─── Errors ──────────────────────────────────────────────────────────

    error Unauthorized();
    error WrongPhase();
    error TimingError();
    error AlreadyDone();
    error InvalidParams();
    error TransferFailed();
    error TooManyCommitters();

    // ─── Constants ──────────────────────────────────────────────────────

    uint256 public constant MAX_COMMITTERS = 50;

    // ─── Current Auction State ───────────────────────────────────────────

    address public immutable fund;

    /// @notice Legacy claimable bond balances (from before lazy-claim migration).
    mapping(address => uint256) public claimableBonds;

    /// @notice Aggregate pending bond refunds owed to non-winning revealers.
    ///         Incremented O(1) at reveal close; decremented per claimBond(epoch) call.
    uint256 public override pendingBondRefunds;

    /// @notice Tracks whether a runner has claimed their bond for a given epoch.
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    uint256 public override commitWindow;
    uint256 public override revealWindow;
    uint256 public override executionWindow;

    /// @notice The epoch tag of the current (or most recent) auction.
    uint256 public override currentAuctionEpoch;

    AuctionPhase public currentPhase;
    uint256 public currentStartTime;
    uint256 public currentBondAmount;
    uint256 public currentCommitCount;
    uint256 public currentRevealCount;
    address public currentWinner;
    uint256 public currentWinningBid;
    uint256 public currentRandomnessSeed;

    // Per-runner state keyed by epoch — no cleanup loop needed between auctions.
    mapping(uint256 => mapping(address => bytes32)) internal bidCommits;
    mapping(uint256 => mapping(address => bool)) internal hasCommitted;
    mapping(uint256 => mapping(address => bool)) internal hasRevealed;
    mapping(uint256 => mapping(address => uint256)) internal revealedBids;
    address[] internal committers;
    bytes32 internal saltAccumulator; // XOR of all revealed salts — mixed into randomness seed

    // ─── Historical Records ──────────────────────────────────────────────

    mapping(uint256 => mapping(address => BidRecord)) internal bidRecords;

    struct AuctionSummary {
        uint256 startTime;
        address winner;
        uint256 winningBid;
        uint256 bondAmount;
        uint256 randomnessSeed;
        address[] committerList;
    }
    mapping(uint256 => AuctionSummary) internal auctionHistory;

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyFund() {
        if (msg.sender != fund) revert Unauthorized();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(address _fund) {
        fund = _fund;
    }

    // ─── Phase Sync ─────────────────────────────────────────────────────

    /// @inheritdoc IAuctionManager
    function syncPhase(uint256 epoch) external override onlyFund returns (AuctionPhase phase, bool advanced) {
        if (epoch != currentAuctionEpoch) return (AuctionPhase.IDLE, false);
        return _syncPhase();
    }

    /// @dev Advance through any elapsed phase windows.
    ///      Each transition runs at most once (phase changes prevent re-entry).
    ///      Returns the final phase and whether any transition occurred.
    ///      The fund contract checks passedThroughReveal and passedThroughExecution
    ///      to handle side effects (seed binding, forfeit events).
    function _syncPhase() internal returns (AuctionPhase phase, bool advanced) {
        phase = currentPhase;
        advanced = false;

        if (phase == AuctionPhase.COMMIT && block.timestamp >= currentStartTime + commitWindow) {
            _closeCommit();
            phase = currentPhase; // re-read after transition
            advanced = true;
        }

        if (phase == AuctionPhase.REVEAL && block.timestamp >= currentStartTime + commitWindow + revealWindow) {
            _closeReveal();
            phase = currentPhase;
            advanced = true;
            // Note: if _closeReveal sets EXECUTION, the next if-block may forfeit it
        }

        if (phase == AuctionPhase.EXECUTION && block.timestamp >= _executionDeadline()) {
            _doForfeit();
            phase = currentPhase;
            advanced = true;
        }
    }

    // ─── Auction Setup ──────────────────────────────────────────────────

    /// @inheritdoc IAuctionManager
    function openAuction(uint256 epoch, uint256 bond, uint256 startTime) external override onlyFund {
        if (bond == 0) revert InvalidParams();
        if (currentPhase != AuctionPhase.IDLE && currentPhase != AuctionPhase.SETTLED) revert WrongPhase();

        // Reset current auction state
        _clearCurrentAuction();

        currentAuctionEpoch = epoch;
        currentPhase = AuctionPhase.COMMIT;
        currentStartTime = startTime;
        currentBondAmount = bond;
    }

    // ─── Prover Actions ─────────────────────────────────────────────────

    /// @inheritdoc IAuctionManager
    function commit(uint256 epoch, address runner, bytes32 commitHash) external payable override onlyFund {
        if (epoch != currentAuctionEpoch) revert InvalidParams();
        if (currentPhase != AuctionPhase.COMMIT) revert WrongPhase();
        if (block.timestamp >= currentStartTime + commitWindow) revert TimingError();
        if (hasCommitted[epoch][runner]) revert AlreadyDone();
        if (commitHash == bytes32(0)) revert InvalidParams();
        if (msg.value < currentBondAmount) revert InvalidParams();
        if (committers.length >= MAX_COMMITTERS) revert TooManyCommitters();

        hasCommitted[epoch][runner] = true;
        bidCommits[epoch][runner] = commitHash;
        committers.push(runner);
        currentCommitCount += 1;
    }

    /// @inheritdoc IAuctionManager
    function recordReveal(uint256 epoch, address runner, uint256 bidAmount, bytes32 salt) external override onlyFund {
        if (epoch != currentAuctionEpoch) revert InvalidParams();
        if (currentPhase != AuctionPhase.REVEAL) revert WrongPhase();
        if (block.timestamp >= currentStartTime + commitWindow + revealWindow) revert TimingError();
        if (!hasCommitted[epoch][runner]) revert Unauthorized();
        if (hasRevealed[epoch][runner]) revert AlreadyDone();

        // Verify commitment
        bytes32 expectedHash = keccak256(abi.encodePacked(bidAmount, salt));
        if (expectedHash != bidCommits[epoch][runner]) revert InvalidParams();

        hasRevealed[epoch][runner] = true;
        revealedBids[epoch][runner] = bidAmount;
        saltAccumulator ^= salt;
        currentRevealCount += 1;

        // Update winner if this is the lowest bid (or first reveal)
        if (currentWinner == address(0) || bidAmount < currentWinningBid) {
            currentWinner = runner;
            currentWinningBid = bidAmount;
        }
    }

    /// @inheritdoc IAuctionManager
    function settleExecution(uint256 epoch, address caller) external override onlyFund {
        if (epoch != currentAuctionEpoch) revert InvalidParams();
        if (currentPhase != AuctionPhase.EXECUTION) revert WrongPhase();
        if (caller != currentWinner) revert Unauthorized();
        if (block.timestamp >= _executionDeadline()) revert TimingError();

        address winner = currentWinner;
        uint256 bondRefund = currentBondAmount;
        currentPhase = AuctionPhase.SETTLED;
        _storeHistory(false);

        // Credit bond to the winner (pull-based via legacy claimable)
        claimableBonds[winner] += bondRefund;
    }

    // ─── Configuration ──────────────────────────────────────────────────

    /// @inheritdoc IAuctionManager
    function setTiming(uint256 _commitWindow, uint256 _revealWindow, uint256 _executionWindow) external override onlyFund {
        if (_commitWindow == 0 || _revealWindow == 0 || _executionWindow == 0) revert InvalidParams();
        commitWindow = _commitWindow;
        revealWindow = _revealWindow;
        executionWindow = _executionWindow;
    }

    // ─── Bond Claims ────────────────────────────────────────────────────

    /// @inheritdoc IAuctionManager
    function claimBond(uint256 epoch) external override nonReentrant {
        if (!hasRevealed[epoch][msg.sender]) revert Unauthorized();
        if (msg.sender == _getWinner(epoch)) revert InvalidParams(); // winners use settleExecution
        if (hasClaimed[epoch][msg.sender]) revert AlreadyDone();

        uint256 bond = _getBond(epoch);
        if (bond == 0) revert InvalidParams();

        hasClaimed[epoch][msg.sender] = true;
        pendingBondRefunds -= bond;

        (bool sent, ) = payable(msg.sender).call{value: bond}("");
        if (!sent) revert TransferFailed();
    }

    /// @inheritdoc IAuctionManager
    function claimLegacyBonds() external override nonReentrant {
        uint256 amount = claimableBonds[msg.sender];
        if (amount == 0) revert InvalidParams();
        claimableBonds[msg.sender] = 0;
        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        if (!sent) revert TransferFailed();
    }

    // ─── Internal: Phase Transitions ────────────────────────────────────

    /// @dev Close the commit phase. COMMIT → REVEAL (or SETTLED if no commits).
    function _closeCommit() internal {
        uint256 commitCount = currentCommitCount;
        if (commitCount == 0) {
            currentPhase = AuctionPhase.SETTLED;
            _storeHistory(false);
        } else {
            currentPhase = AuctionPhase.REVEAL;
        }
    }

    /// @dev Close the reveal phase. REVEAL → EXECUTION (or SETTLED if no reveals).
    ///      Captures randomness seed. Computes aggregate bond refunds O(1) (no loop).
    ///      Sends forfeited (unrevealed) bonds to the fund treasury.
    function _closeReveal() internal {
        uint256 revealCount = currentRevealCount;

        if (revealCount == 0) {
            // No reveals — all bonds forfeited to fund
            currentPhase = AuctionPhase.SETTLED;
            _storeHistory(false);
            uint256 allBonds = currentCommitCount * currentBondAmount;
            if (allBonds > 0) {
                (bool sent, ) = payable(fund).call{value: allBonds}("");
                if (!sent) revert TransferFailed();
            }
            return;
        }

        // Enter execution phase — seed mixes prevrandao with revealed salts
        currentPhase = AuctionPhase.EXECUTION;
        currentRandomnessSeed = uint256(keccak256(abi.encodePacked(block.prevrandao, saltAccumulator)));

        // O(1) bond accounting — no committer loop
        uint256 bond = currentBondAmount;
        uint256 nonWinnerRevealers = revealCount - 1;          // winner is a revealer
        uint256 revealerRefunds = nonWinnerRevealers * bond;   // owed to non-winning revealers
        uint256 forfeitedBonds = (currentCommitCount - revealCount) * bond; // non-revealers

        pendingBondRefunds += revealerRefunds;

        // Send forfeited bonds to fund treasury immediately
        if (forfeitedBonds > 0) {
            (bool sent, ) = payable(fund).call{value: forfeitedBonds}("");
            if (!sent) revert TransferFailed();
        }
    }

    /// @dev Forfeit the current auction winner's bond. Stores history, sends bond to fund.
    function _doForfeit() internal {
        uint256 forfeitedBond = currentBondAmount;
        currentPhase = AuctionPhase.SETTLED;
        _storeHistory(true);

        (bool sent, ) = payable(fund).call{value: forfeitedBond}("");
        if (!sent) revert TransferFailed();
    }

    // ─── Internal: History & Cleanup ────────────────────────────────────

    /// @dev Store historical records for the current auction.
    function _storeHistory(bool forfeited) internal {
        uint256 epoch = currentAuctionEpoch;

        // Store auction summary
        auctionHistory[epoch].startTime = currentStartTime;
        auctionHistory[epoch].winner = currentWinner;
        auctionHistory[epoch].winningBid = currentWinningBid;
        auctionHistory[epoch].bondAmount = currentBondAmount;
        auctionHistory[epoch].randomnessSeed = currentRandomnessSeed;
        auctionHistory[epoch].committerList = committers;

        // Store per-runner bid records
        address winner = currentWinner;
        for (uint256 i = 0; i < committers.length; i++) {
            address runner = committers[i];
            bool revealed = hasRevealed[epoch][runner];
            bidRecords[epoch][runner] = BidRecord({
                revealed: revealed,
                bidAmount: revealed ? revealedBids[epoch][runner] : 0,
                winner: runner == winner,
                forfeited: runner == winner && forfeited
            });
        }
    }

    /// @dev Clear current auction working state for reuse.
    ///      Per-runner mappings are epoch-keyed, so no cleanup loop needed.
    function _clearCurrentAuction() internal {
        delete committers;

        currentPhase = AuctionPhase.IDLE;
        currentStartTime = 0;
        currentBondAmount = 0;
        currentCommitCount = 0;
        currentRevealCount = 0;
        saltAccumulator = bytes32(0);
        currentWinner = address(0);
        currentWinningBid = 0;
        currentRandomnessSeed = 0;
    }

    // ─── Internal: Helpers ──────────────────────────────────────────────

    function _executionDeadline() internal view returns (uint256) {
        return currentStartTime + commitWindow + revealWindow + executionWindow;
    }

    /// @dev Get winner for an epoch (current or historical).
    function _getWinner(uint256 epoch) internal view returns (address) {
        if (epoch == currentAuctionEpoch) return currentWinner;
        return auctionHistory[epoch].winner;
    }

    /// @dev Get bond for an epoch (current or historical).
    function _getBond(uint256 epoch) internal view returns (uint256) {
        if (epoch == currentAuctionEpoch) return currentBondAmount;
        return auctionHistory[epoch].bondAmount;
    }

    // ─── Views ───────────────────────────────────────────────────────────

    function getPhase(uint256 epoch) external view override returns (AuctionPhase) {
        if (epoch == currentAuctionEpoch) return currentPhase;
        if (auctionHistory[epoch].startTime != 0) return AuctionPhase.SETTLED;
        return AuctionPhase.IDLE;
    }

    function getWinner(uint256 epoch) external view override returns (address) {
        return _getWinner(epoch);
    }

    function getWinningBid(uint256 epoch) external view override returns (uint256) {
        if (epoch == currentAuctionEpoch) return currentWinningBid;
        return auctionHistory[epoch].winningBid;
    }

    function getBond(uint256 epoch) external view override returns (uint256) {
        return _getBond(epoch);
    }

    function getStartTime(uint256 epoch) external view override returns (uint256) {
        if (epoch == currentAuctionEpoch) return currentStartTime;
        return auctionHistory[epoch].startTime;
    }

    function getRandomnessSeed(uint256 epoch) external view override returns (uint256) {
        if (epoch == currentAuctionEpoch) return currentRandomnessSeed;
        return auctionHistory[epoch].randomnessSeed;
    }

    function getCommitters(uint256 epoch) external view override returns (address[] memory) {
        if (epoch == currentAuctionEpoch) return committers;
        return auctionHistory[epoch].committerList;
    }

    function didReveal(uint256 epoch, address runner) external view override returns (bool) {
        if (epoch == currentAuctionEpoch) return hasRevealed[epoch][runner];
        return bidRecords[epoch][runner].revealed;
    }

    function getBidRecord(uint256 epoch, address runner) external view override returns (BidRecord memory) {
        return bidRecords[epoch][runner];
    }

    function executionDeadline() external view override returns (uint256) {
        return _executionDeadline();
    }

    // Accept ETH (bond payments forwarded from fund)
    receive() external payable {}
}
