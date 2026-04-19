// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IAuctionManager.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionManager
/// @notice Reusable commit-reveal sealed-bid auction primitive. Manually
///         driven by the fund contract — has no knowledge of wall-clock,
///         epoch scheduling, treasury, or verification.
///
///         Every state-mutating function is onlyFund except `claimBond`.
///         The fund wraps prover actions (commit, reveal) and injects the
///         bidder address as `runner`.
///
///         Bonds are held directly by this contract:
///           - committed bonds → `address(this).balance`
///           - non-winning revealers' refunds → still in balance, tracked
///             by `pendingBondRefunds`, claimable per-epoch via `claimBond`
///           - winner's bond+bounty → pushed to winner in `settleExecution`
///           - forfeited bonds → pushed to fund in `nextPhase` (REVEAL→EXECUTION)
///             or `closeExecution`
///
///         Bond conservation invariant:
///           `currentAuctionHeldBond + pendingBondRefunds == address(this).balance`
///         between transactions. `currentAuctionHeldBond` is the sum of bonds
///         still tied to the in-flight auction (committers pre-reveal-close,
///         winner pre-settle/close).
contract AuctionManager is IAuctionManager, ReentrancyGuard {
    // ─── Errors ──────────────────────────────────────────────────────────

    error Unauthorized();
    error WrongPhase();
    error AlreadyDone();
    error InvalidParams();
    error TransferFailed();
    error TooManyCommitters();
    error BountyMismatch();

    // ─── Constants ──────────────────────────────────────────────────────

    uint256 public constant MAX_COMMITTERS = 50;

    // ─── Fund Linkage ───────────────────────────────────────────────────

    address public immutable fund;

    modifier onlyFund() {
        if (msg.sender != fund) revert Unauthorized();
        _;
    }

    // ─── Current Auction State ──────────────────────────────────────────

    AuctionPhase public override phase;  // default COMMIT (0) pre-first-open
    uint256 public override currentEpoch;
    uint256 public override maxBid;
    uint256 public override bond;

    address public override winner;
    uint256 public override winningBid;

    uint256 internal commitCount;
    uint256 internal revealCount;
    address[] internal committers;

    mapping(address => bytes32) internal commitHashOf;
    mapping(address => bool) internal hasCommitted;   // current-auction scope
    mapping(address => bool) internal hasRevealed;    // current-auction scope
    mapping(address => uint256) internal revealedBidOf;

    // Whether the first-ever auction has been opened. Gates the SETTLED
    // precondition on `openAuction` so that the bootstrap call (from the
    // default zero-state) can proceed.
    bool internal bootstrapped;

    // ─── Bond Accounting ────────────────────────────────────────────────

    /// @notice Aggregate lazy-claimable refunds owed to past non-winning
    ///         revealers. Invariant: decrements by exactly `bond` on each
    ///         successful `claimBond` call.
    uint256 public override pendingBondRefunds;

    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    // ─── Historical Records ─────────────────────────────────────────────

    mapping(uint256 => mapping(address => BidRecord)) internal bidRecords;

    struct AuctionSummary {
        address winner;
        uint256 winningBid;
        uint256 bond;
        address[] committerList;
    }
    mapping(uint256 => AuctionSummary) internal auctionHistory;
    mapping(uint256 => mapping(address => bool)) internal hasRevealedInEpoch;

    // ─── Constructor ────────────────────────────────────────────────────

    constructor(address _fund) {
        fund = _fund;
    }

    // ─── State Transitions (onlyFund) ───────────────────────────────────

    /// @inheritdoc IAuctionManager
    function openAuction(uint256 epoch, uint256 maxBid_, uint256 bond_) external override onlyFund {
        if (bootstrapped && phase != AuctionPhase.SETTLED) revert WrongPhase();
        if (bond_ == 0) revert InvalidParams();
        if (maxBid_ == 0) revert InvalidParams();

        _clearCurrentAuction();

        currentEpoch = epoch;
        maxBid = maxBid_;
        bond = bond_;
        phase = AuctionPhase.COMMIT;
        bootstrapped = true;
    }

    /// @inheritdoc IAuctionManager
    function nextPhase() external override onlyFund nonReentrant {
        AuctionPhase p = phase;
        if (p == AuctionPhase.COMMIT) {
            phase = AuctionPhase.REVEAL;
        } else if (p == AuctionPhase.REVEAL) {
            _closeReveal();
        } else {
            // EXECUTION and SETTLED cannot be advanced via nextPhase.
            // EXECUTION requires settleExecution / closeExecution / abortAuction.
            // SETTLED requires openAuction.
            revert WrongPhase();
        }
    }

    /// @inheritdoc IAuctionManager
    function settleExecution() external payable override onlyFund nonReentrant {
        if (phase != AuctionPhase.EXECUTION) revert WrongPhase();
        if (msg.value != winningBid) revert BountyMismatch();

        address w = winner;
        // With MAX_COMMITTERS > 0 and at least one revealer required to
        // reach EXECUTION with a real winner, `w` should be set — but guard
        // defensively. If nobody revealed, closeExecution is the correct
        // terminal path, not settleExecution.
        if (w == address(0)) revert InvalidParams();

        uint256 refund = bond + msg.value;
        _storeHistory(false);
        phase = AuctionPhase.SETTLED;

        (bool sent, ) = payable(w).call{value: refund}("");
        if (!sent) revert TransferFailed();
    }

    /// @inheritdoc IAuctionManager
    function closeExecution() external override onlyFund nonReentrant {
        if (phase != AuctionPhase.EXECUTION) revert WrongPhase();

        address w = winner;
        uint256 forfeited = bond;

        // If there was a winner who failed to submit, forfeit their bond
        // to the fund. If there was no winner (empty auction), there's
        // no in-flight bond to forfeit — non-revealer bonds already went
        // to the fund at REVEAL close.
        _storeHistory(w != address(0));  // forfeited=true iff winner no-showed
        phase = AuctionPhase.SETTLED;

        if (w != address(0) && forfeited > 0) {
            (bool sent, ) = payable(fund).call{value: forfeited}("");
            if (!sent) revert TransferFailed();
        }
    }

    /// @inheritdoc IAuctionManager
    /// @dev Per-phase refund matrix:
    ///  - COMMIT:    all committer bonds held here → refund each committer.
    ///  - REVEAL:    all committer bonds held here → refund each committer
    ///               (reveals haven't settled yet; both revealers and
    ///               non-revealers get their bond back).
    ///  - EXECUTION: non-revealer bonds already forfeited at reveal close
    ///               (not unwound). Non-winning revealer credits in
    ///               pendingBondRefunds remain claimable post-abort. Only
    ///               the winner's bond is refunded here (if there is one).
    ///  - SETTLED:   no-op (already terminal; nothing to refund).
    function abortAuction() external override onlyFund nonReentrant {
        AuctionPhase p = phase;
        if (p == AuctionPhase.SETTLED) return;

        uint256 b = bond;

        if (p == AuctionPhase.COMMIT || p == AuctionPhase.REVEAL) {
            address[] memory list = committers;
            for (uint256 i = 0; i < list.length; i++) {
                if (b > 0) {
                    (bool sent, ) = payable(list[i]).call{value: b}("");
                    if (!sent) revert TransferFailed();
                }
            }
        } else {
            // EXECUTION
            address w = winner;
            if (w != address(0) && b > 0) {
                (bool sent, ) = payable(w).call{value: b}("");
                if (!sent) revert TransferFailed();
            }
        }

        _storeHistory(false);
        phase = AuctionPhase.SETTLED;
    }

    // ─── Bidder Actions (onlyFund) ──────────────────────────────────────

    /// @inheritdoc IAuctionManager
    function commit(address runner, bytes32 commitHash) external payable override onlyFund {
        if (phase != AuctionPhase.COMMIT) revert WrongPhase();
        if (commitHash == bytes32(0)) revert InvalidParams();
        if (msg.value != bond) revert InvalidParams();
        if (hasCommitted[runner]) revert AlreadyDone();
        if (committers.length >= MAX_COMMITTERS) revert TooManyCommitters();

        hasCommitted[runner] = true;
        commitHashOf[runner] = commitHash;
        committers.push(runner);
        commitCount += 1;
    }

    /// @inheritdoc IAuctionManager
    function reveal(address runner, uint256 bidAmount, bytes32 salt) external override onlyFund {
        if (phase != AuctionPhase.REVEAL) revert WrongPhase();
        if (!hasCommitted[runner]) revert Unauthorized();
        if (hasRevealed[runner]) revert AlreadyDone();
        if (bidAmount == 0) revert InvalidParams();
        if (bidAmount > maxBid) revert InvalidParams();

        // Commit hash binds the runner address to prevent reveal front-running.
        bytes32 expected = keccak256(abi.encodePacked(runner, bidAmount, salt));
        if (expected != commitHashOf[runner]) revert InvalidParams();

        hasRevealed[runner] = true;
        // Also persist to the epoch-keyed mapping so `claimBond` works from
        // the moment REVEAL→EXECUTION completes (without waiting for
        // settlement). The persistent write lets non-winning revealers
        // claim as soon as their non-winner status is known — which is at
        // reveal-close when the winner is finalized, before settleExecution.
        hasRevealedInEpoch[currentEpoch][runner] = true;
        revealedBidOf[runner] = bidAmount;
        revealCount += 1;

        // Incrementally track winner: lowest bid wins; first-revealer tiebreak.
        if (winner == address(0) || bidAmount < winningBid) {
            winner = runner;
            winningBid = bidAmount;
        }
    }

    // ─── Bond Claims (permissionless) ───────────────────────────────────

    /// @inheritdoc IAuctionManager
    function claimBond(uint256 epoch) external override nonReentrant {
        if (!hasRevealedInEpoch[epoch][msg.sender]) revert Unauthorized();
        if (hasClaimed[epoch][msg.sender]) revert AlreadyDone();
        if (msg.sender == auctionHistory[epoch].winner) revert InvalidParams();

        uint256 b = auctionHistory[epoch].bond;
        if (b == 0) revert InvalidParams();

        hasClaimed[epoch][msg.sender] = true;
        pendingBondRefunds -= b;

        (bool sent, ) = payable(msg.sender).call{value: b}("");
        if (!sent) revert TransferFailed();
    }

    // ─── Internal: Phase Transitions ────────────────────────────────────

    /// @dev REVEAL → EXECUTION. Aggregates O(1) bond accounting:
    ///       - non-winning revealers → credited to pendingBondRefunds
    ///       - non-revealers → bonds forfeited to fund immediately
    ///       - no reveals at all → all committer bonds forfeit to fund
    ///
    ///      Also partially populates `auctionHistory[currentEpoch]` — the
    ///      winner, winningBid, and bond are known at this point, so we
    ///      commit them to history immediately. This lets `claimBond` work
    ///      during EXECUTION (before settleExecution/closeExecution/abort
    ///      fire). The committer list and per-runner BidRecords are
    ///      finalized later in `_storeHistory` at terminal transition.
    function _closeReveal() internal {
        uint256 rc = revealCount;
        uint256 cc = commitCount;
        uint256 b = bond;
        uint256 forfeited;

        phase = AuctionPhase.EXECUTION;

        // Partial history write — enough for claimBond to work.
        AuctionSummary storage s = auctionHistory[currentEpoch];
        s.winner = winner;
        s.winningBid = winningBid;
        s.bond = b;

        if (rc == 0) {
            // No reveals — every committer's bond forfeits.
            forfeited = cc * b;
        } else {
            // Winner is a revealer; `rc - 1` non-winning revealers hold claims.
            uint256 nonWinnerRevealers = rc - 1;
            pendingBondRefunds += nonWinnerRevealers * b;
            forfeited = (cc - rc) * b;  // non-revealers
        }

        if (forfeited > 0) {
            (bool sent, ) = payable(fund).call{value: forfeited}("");
            if (!sent) revert TransferFailed();
        }
    }

    // ─── Internal: History & Cleanup ────────────────────────────────────

    /// @dev Freeze the current auction's state into historical records.
    ///      Called on each path into SETTLED (settle / close / abort).
    ///      `forfeited` marks the winner's bond status: true on no-show
    ///      forfeiture (closeExecution), false otherwise.
    function _storeHistory(bool forfeited) internal {
        uint256 e = currentEpoch;
        AuctionSummary storage s = auctionHistory[e];
        s.winner = winner;
        s.winningBid = winningBid;
        s.bond = bond;
        s.committerList = committers;

        address w = winner;
        for (uint256 i = 0; i < committers.length; i++) {
            address r = committers[i];
            bool revealed = hasRevealed[r];
            bidRecords[e][r] = BidRecord({
                revealed: revealed,
                bidAmount: revealed ? revealedBidOf[r] : 0,
                winner: r == w,
                forfeited: r == w && forfeited
            });
            if (revealed) {
                hasRevealedInEpoch[e][r] = true;
            }
        }
    }

    /// @dev Wipe current-auction working state. Called at `openAuction` so
    ///      the next auction starts with a clean slate. Historical records
    ///      remain; `hasRevealedInEpoch[e]` is the canonical "did X reveal
    ///      in epoch e?" signal for past epochs.
    function _clearCurrentAuction() internal {
        for (uint256 i = 0; i < committers.length; i++) {
            address r = committers[i];
            delete hasCommitted[r];
            delete hasRevealed[r];
            delete commitHashOf[r];
            delete revealedBidOf[r];
        }
        delete committers;
        winner = address(0);
        winningBid = 0;
        commitCount = 0;
        revealCount = 0;
    }

    // ─── Views ──────────────────────────────────────────────────────────

    /// @inheritdoc IAuctionManager
    function getCommitters() external view override returns (address[] memory) {
        return committers;
    }

    /// @inheritdoc IAuctionManager
    function didReveal(address runner) external view override returns (bool) {
        return hasRevealed[runner];
    }

    /// @inheritdoc IAuctionManager
    function getWinner(uint256 epoch) external view override returns (address) {
        return auctionHistory[epoch].winner;
    }

    /// @inheritdoc IAuctionManager
    function getWinningBid(uint256 epoch) external view override returns (uint256) {
        return auctionHistory[epoch].winningBid;
    }

    /// @inheritdoc IAuctionManager
    function getBond(uint256 epoch) external view override returns (uint256) {
        return auctionHistory[epoch].bond;
    }

    /// @inheritdoc IAuctionManager
    function getBidRecord(uint256 epoch, address runner) external view override returns (BidRecord memory) {
        return bidRecords[epoch][runner];
    }

    /// @inheritdoc IAuctionManager
    function getCommittersOfEpoch(uint256 epoch) external view override returns (address[] memory) {
        return auctionHistory[epoch].committerList;
    }

    /// @inheritdoc IAuctionManager
    function didRevealInEpoch(uint256 epoch, address runner) external view override returns (bool) {
        return hasRevealedInEpoch[epoch][runner];
    }

    // Accept ETH (bond payments flow in via payable `commit` and bounty via
    // payable `settleExecution`; this receive guards against accidental
    // direct sends but doesn't error — tests and harnesses may pre-fund).
    receive() external payable {}
}
