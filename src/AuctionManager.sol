// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IAuctionManager.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionManager
/// @notice Auction state machine for commit-reveal sealed-bid auctions.
///         3-phase cyclic: COMMIT → REVEAL → EXECUTION. The EXECUTION →
///         COMMIT-of-next-epoch boundary (including winner-forfeit-if-no-show
///         bookkeeping) is handled by the fund contract — see
///         `TheHumanFund._closeExecution` and `_openAuction`.
///
///         Within an epoch, phase advancement is automatic: syncPhase()
///         advances through any elapsed phase windows based on block.timestamp
///         vs wall-clock deadlines. Bond refunds are lazy: non-winning
///         revealers call claimBond(epoch). Only the fund contract can call
///         state-transition functions.
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
        // Stale epoch tags are treated as a no-op. The fund shouldn't call
        // syncPhase with a mismatched epoch in normal operation, but we
        // avoid reverting so the caller can detect the no-op cleanly.
        if (epoch != currentAuctionEpoch) return (currentPhase, false);
        return _syncPhase();
    }

    /// @dev Advance through any elapsed within-epoch phase windows.
    ///      Cascades COMMIT→REVEAL→EXECUTION at most once each.
    ///      Does NOT transition out of EXECUTION — the fund handles the
    ///      EXECUTION→COMMIT-of-next-epoch boundary via `_closeExecution`
    ///      + `_openAuction` (which calls into this AM's `openAuction`).
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
        }
        // EXECUTION is terminal within the epoch. The fund's `_closeExecution`
        // handles the boundary crossing.
    }

    // ─── Auction Setup ──────────────────────────────────────────────────

    /// @inheritdoc IAuctionManager
    function openAuction(uint256 epoch, uint256 bond, uint256 startTime) external override onlyFund {
        if (bond == 0) revert InvalidParams();

        // Reset current auction state. No phase precondition: the fund only
        // calls this at bootstrap or after `_closeExecution` has finished
        // with the prior epoch. openAuction overwrites live state atomically.
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

        // Verify commitment. The runner address is part of the preimage to
        // prevent reveal front-running: if a commit hash only bound (bid, salt),
        // an attacker could observe a legit runner's commit, submit the same
        // hash under their own address, then front-run the legit reveal tx
        // and steal the winning slot with the same (bid, salt) pair.
        bytes32 expectedHash = keccak256(abi.encodePacked(runner, bidAmount, salt));
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

        uint256 bondRefund = currentBondAmount;

        // Phase stays at EXECUTION. Double-submit prevention lives on the
        // fund side (`epochs[epoch].executed`). The fund's `_closeExecution`
        // later observes `executed==true` and skips forfeit before advancing.
        _storeHistory(false);

        // Push bond directly to winner. If the push fails, the whole
        // submitAuctionResult tx reverts — the winner's own contract is
        // at fault (e.g. non-payable fallback), and they can retry after
        // fixing it.
        (bool sent, ) = payable(caller).call{value: bondRefund}("");
        if (!sent) revert TransferFailed();
    }

    /// @inheritdoc IAuctionManager
    /// @dev End-of-epoch state-clear. Called exclusively by the fund at the
    ///      EXECUTION → COMMIT-of-next-epoch boundary. Distinguishes
    ///      "winner already submitted" from "winner no-showed" by whether
    ///      history was stored (settleExecution stores on success):
    ///        - history stored   → bond already refunded in settleExecution;
    ///                             just clear state.
    ///        - history not stored → winner never submitted; forfeit the
    ///                             held bond to the fund, store history
    ///                             (marked forfeited), then clear state.
    function closeExecution() external override onlyFund nonReentrant {
        if (currentPhase != AuctionPhase.EXECUTION) revert WrongPhase();

        uint256 epoch = currentAuctionEpoch;
        bool alreadySettled = auctionHistory[epoch].startTime != 0;

        if (!alreadySettled) {
            uint256 forfeitedBond = currentBondAmount;
            _storeHistory(true);
            if (forfeitedBond > 0 && currentWinner != address(0)) {
                (bool sent, ) = payable(fund).call{value: forfeitedBond}("");
                if (!sent) revert TransferFailed();
            }
        }

        _clearCurrentAuction();
        // Zero the tag so getX(epoch) lookups route through auctionHistory
        // until the fund calls openAuction() for the next epoch.
        currentAuctionEpoch = 0;
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

    // ─── Owner-Driven Reset ─────────────────────────────────────────────

    /// @notice Abort the in-flight auction and refund all held bonds.
    ///         Callable only by the fund (via its owner `resetAuction` and
    ///         `migrate` entry points, both routing through the shared
    ///         `_resetAuction` internal). This is operator intervention,
    ///         NOT a forfeit event — committers get their bonds back
    ///         regardless of phase.
    ///
    /// Per-phase refund matrix:
    ///  - COMMIT:    all committers' bonds are held here → refund all.
    ///  - REVEAL:    all committers' bonds are held here → refund all
    ///               (reveals haven't settled yet; both revealers and
    ///               non-revealers get their bond back).
    ///  - EXECUTION: non-revealer bonds were already forfeited to the
    ///               fund at reveal close and are NOT unwound here. Non-
    ///               winning revealers already have a `pendingBondRefunds`
    ///               credit and will claim via `claimBond` as normal. The
    ///               only bond still held by the AM is the winner's —
    ///               that's what we refund (if there is a winner).
    ///
    /// @dev Refunds are direct push. If any committer's push fails (e.g.
    ///      a malicious fallback), the entire reset reverts. The operator
    ///      must investigate and either remove the griefer (by a direct
    ///      admin action outside this contract) or accept that recovery
    ///      requires off-chain coordination. In practice the committer
    ///      set is small and operator-controlled, so this is acceptable.
    function abortAuction() external onlyFund nonReentrant {
        // No live auction (e.g., we're between _closeExecution and
        // _openAuction under sunset). Nothing to abort, no history to store.
        if (currentAuctionEpoch == 0) return;

        AuctionPhase phase = currentPhase;
        uint256 bond = currentBondAmount;

        if (phase == AuctionPhase.COMMIT || phase == AuctionPhase.REVEAL) {
            // Refund every committer. In REVEAL phase we don't distinguish
            // revealers from non-revealers — this is an abort, everyone
            // gets their bond back.
            address[] memory list = committers;
            for (uint256 i = 0; i < list.length; i++) {
                if (bond > 0) {
                    (bool sent, ) = payable(list[i]).call{value: bond}("");
                    if (!sent) revert TransferFailed();
                }
            }
        } else {
            // EXECUTION: only the winner's bond is still held here.
            address winner = currentWinner;
            if (winner != address(0) && bond > 0) {
                (bool sent, ) = payable(winner).call{value: bond}("");
                if (!sent) revert TransferFailed();
            }
        }

        // Record history so the epoch is visibly "closed" in auctionHistory,
        // then clear working state. Mark as not-forfeited — this is an
        // operator abort, not a winner failure.
        _storeHistory(false);
        _clearCurrentAuction();
        // After abort there is no active auction. Zero out the epoch tag so
        // getX(epoch) lookups route through auctionHistory. The fund MUST
        // immediately call openAuction() to restore a live auction — any
        // interaction between abort and open is undefined.
        currentAuctionEpoch = 0;
    }

    // ─── Owner-Driven Single-Step Advance ───────────────────────────────

    /// @notice Force-close the current auction phase WITHOUT checking
    ///         wall-clock deadlines. Callable only by the fund (via its
    ///         owner `nextPhase` entry point and internal `_nextPhase`
    ///         primitive). The time-independent counterpart to `syncPhase`.
    ///
    /// Transitions by phase:
    ///  - COMMIT    → REVEAL (phase always advances regardless of commit
    ///                count; see `_closeCommit`).
    ///  - REVEAL    → EXECUTION (captures seed and pushes forfeited
    ///                non-revealer bonds; see `_closeReveal`).
    ///  - EXECUTION: reverts with WrongPhase. The EXECUTION → COMMIT-of-
    ///                next-epoch transition is handled exclusively by the
    ///                fund (via `_closeExecution` + `_openAuction`).
    ///
    /// @dev User actions (commit, reveal, submitAuctionResult) still
    ///      enforce their wall-clock windows. `forceClosePhase` only
    ///      bypasses the *state-machine's* time gates — it does not
    ///      grant the owner a way to invalidate a revealer's fair
    ///      reveal window, because those bounds are enforced in
    ///      commit()/recordReveal()/settleExecution() themselves. The
    ///      worst an owner can do with this is prematurely close a
    ///      phase — bidders lose the opportunity to act, but bonds
    ///      are still handled by the normal close-paths.
    function forceClosePhase() external override onlyFund nonReentrant {
        AuctionPhase phase = currentPhase;
        if (phase == AuctionPhase.COMMIT) {
            _closeCommit();
        } else if (phase == AuctionPhase.REVEAL) {
            _closeReveal();
        } else {
            // EXECUTION — the fund handles the boundary, not us.
            revert WrongPhase();
        }
    }

    // ─── Internal: Phase Transitions ────────────────────────────────────

    /// @dev Close the commit phase. COMMIT → REVEAL unconditionally.
    ///      Under the 3-phase cyclic model, phases always advance. An empty
    ///      commit window lands in REVEAL with zero revealers, which then
    ///      advances to EXECUTION with no winner — the fund's
    ///      `_closeExecution` handles the "no-winner" case at the boundary.
    function _closeCommit() internal {
        currentPhase = AuctionPhase.REVEAL;
    }

    /// @dev Close the reveal phase. REVEAL → EXECUTION unconditionally.
    ///      Captures randomness seed from prevrandao XOR accumulated salts.
    ///      Computes aggregate bond refunds O(1) (no committer loop):
    ///        - non-winning revealers: credited to pendingBondRefunds (lazy claim).
    ///        - non-revealers: bonds forfeited to fund treasury immediately.
    ///      If there were zero reveals (or zero commits, cascading here), all
    ///      held bonds go to the fund.
    function _closeReveal() internal {
        uint256 revealCount = currentRevealCount;

        // Enter execution phase. Seed is computed even when revealCount==0
        // (it simply doesn't matter — there's no winner to use it).
        currentPhase = AuctionPhase.EXECUTION;
        currentRandomnessSeed = uint256(keccak256(abi.encodePacked(block.prevrandao, saltAccumulator)));

        uint256 bond = currentBondAmount;
        uint256 forfeitedBonds;

        if (revealCount == 0) {
            // No reveals — every committer's bond forfeits to the fund.
            forfeitedBonds = currentCommitCount * bond;
        } else {
            // O(1) bond accounting — no committer loop.
            uint256 nonWinnerRevealers = revealCount - 1;          // winner is a revealer
            uint256 revealerRefunds = nonWinnerRevealers * bond;   // owed to non-winning revealers
            forfeitedBonds = (currentCommitCount - revealCount) * bond; // non-revealers forfeit
            pendingBondRefunds += revealerRefunds;
        }

        // Send forfeited bonds to the fund treasury immediately.
        if (forfeitedBonds > 0) {
            (bool sent, ) = payable(fund).call{value: forfeitedBonds}("");
            if (!sent) revert TransferFailed();
        }
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
    ///      `currentPhase` is deliberately NOT reset here — `openAuction`
    ///      always sets it to COMMIT immediately after, and between abort
    ///      and open there should be no external reads.
    function _clearCurrentAuction() internal {
        delete committers;

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

    /// @notice Returns the current live phase for `epoch` if `epoch` matches
    ///         the in-flight auction, otherwise returns EXECUTION (the
    ///         terminal phase for any past epoch — past epochs are "done"
    ///         in the sense that the fund has moved on, and their fund-side
    ///         `executed` bit carries the success/forfeit distinction).
    ///         Epochs that were never opened also return EXECUTION — the
    ///         fund's `epochs[e].executed` is the authoritative "did this
    ///         epoch's auction actually run" signal.
    function getPhase(uint256 epoch) external view override returns (AuctionPhase) {
        if (epoch == currentAuctionEpoch) return currentPhase;
        return AuctionPhase.EXECUTION;
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
