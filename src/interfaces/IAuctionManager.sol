// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAuctionManager
/// @notice Interface for the auction state machine that manages commit-reveal auctions.
///         Handles phases, bids, bonds, timing, and winner selection.
///         Does NOT know about epoch numbering, treasury state, or verification.
///
///         The state machine is 3-phase cyclic: COMMIT → REVEAL → EXECUTION. The
///         EXECUTION → COMMIT-of-next-epoch transition (including bond forfeit
///         for no-show winners) is handled by the fund contract, not here.
///
///         Phase advancement within an epoch is automatic via syncPhase() — the fund
///         contract calls it before every action. Bond refunds are lazy via
///         claimBond(epoch).
interface IAuctionManager {
    // ─── Enums ──────────────────────────────────────────────────────────

    /// @notice The three phases of an in-flight auction. Phases cycle per epoch.
    ///         There is no IDLE/SETTLED rest state — the fund always holds exactly
    ///         one auction-in-progress, and an epoch is considered "done" when the
    ///         fund marks `epochs[e].executed` and advances to the next epoch's COMMIT.
    enum AuctionPhase { COMMIT, REVEAL, EXECUTION }

    // ─── Historical Records ─────────────────────────────────────────────

    struct BidRecord {
        bool revealed;      // true if the runner revealed their bid
        uint256 bidAmount;  // 0 if not revealed
        bool winner;        // true if this runner won
        bool forfeited;     // true if the winner forfeited (didn't submit result)
    }

    // ─── Auction Setup & Sync (onlyFund) ────────────────────────────────

    /// @notice Open a new auction. Clears any prior in-flight state and sets
    ///         phase to COMMIT for `epoch`. No phase precondition — the fund
    ///         is responsible for calling this only when it makes sense
    ///         (i.e. at deploy bootstrap or after `_closeExecution` for the
    ///         prior epoch).
    /// @param epoch The epoch identifier (opaque to the AM).
    /// @param bond The bond amount each committer must stake.
    /// @param startTime Wall-clock scheduled start time for this auction's phase windows.
    function openAuction(uint256 epoch, uint256 bond, uint256 startTime) external;

    /// @notice Advance the auction through any elapsed WITHIN-EPOCH phase windows.
    ///         Cascades COMMIT→REVEAL→EXECUTION based on wall-clock. Does NOT
    ///         advance epochs or transition out of EXECUTION — the fund handles
    ///         the EXECUTION→COMMIT-of-next-epoch boundary via its own helpers.
    /// @return phase The phase AFTER advancement.
    /// @return advanced True if any phase transition occurred.
    function syncPhase(uint256 epoch) external returns (AuctionPhase phase, bool advanced);

    // ─── Prover Actions (onlyFund, forwarded from provers) ──────────────

    /// @notice Record a sealed bid commitment. Must be called with bond ETH attached.
    function commit(uint256 epoch, address runner, bytes32 commitHash) external payable;

    /// @notice Record a bid reveal. Verifies commitment hash and tracks lowest bidder.
    function recordReveal(uint256 epoch, address runner, uint256 bidAmount, bytes32 salt) external;

    /// @notice Settle a successful execution. Validates caller is the winner and
    ///         within the execution window, refunds the winner's bond, and stores
    ///         the auction summary. Phase stays EXECUTION — the fund's
    ///         `epochs[epoch].executed` bit is the double-submit guard, and the
    ///         fund's `_closeExecution` drives the subsequent phase advance.
    function settleExecution(uint256 epoch, address caller) external;

    /// @notice Close the current EXECUTION phase and clear in-flight state so
    ///         the fund can call `openAuction` for the next epoch.
    ///         If the winner never submitted (i.e. `settleExecution` never ran
    ///         and no auction history exists for the current epoch yet), this
    ///         forfeits the winner's bond to the fund. If settleExecution
    ///         already ran, this is just a state-clear — no bond movement.
    ///         Reverts if called outside EXECUTION phase.
    function closeExecution() external;

    // ─── Configuration (onlyFund) ───────────────────────────────────────

    /// @notice Update auction timing parameters.
    function setTiming(uint256 _commitWindow, uint256 _revealWindow, uint256 _executionWindow) external;

    /// @notice Abort the in-flight auction and refund all held bonds.
    ///         Operator intervention path: NOT a forfeit event — committers
    ///         get their bonds back regardless of phase. Non-revealer bonds
    ///         already forfeited at reveal close are not unwound; non-winning
    ///         revealer credits in `pendingBondRefunds` are left intact.
    ///         See `AuctionManager.abortAuction` for the full refund matrix.
    function abortAuction() external;

    /// @notice Force-close the current auction phase without checking
    ///         wall-clock deadlines. Time-independent counterpart to
    ///         `syncPhase`, used by the fund's owner `nextPhase` entry
    ///         point. Only advances within an epoch (COMMIT→REVEAL or
    ///         REVEAL→EXECUTION). Reverts if called when the AM is already
    ///         in EXECUTION — the fund handles the EXECUTION→next-epoch
    ///         boundary itself.
    function forceClosePhase() external;

    // ─── Bond Claims (anyone) ───────────────────────────────────────────

    /// @notice Claim bond refund for a specific epoch.
    ///         Eligible: non-winning revealers. Winners are paid directly
    ///         by `settleExecution` and don't need to claim.
    function claimBond(uint256 epoch) external;

    // ─── Views ──────────────────────────────────────────────────────────

    function currentAuctionEpoch() external view returns (uint256);
    function getPhase(uint256 epoch) external view returns (AuctionPhase);
    function getWinner(uint256 epoch) external view returns (address);
    function getWinningBid(uint256 epoch) external view returns (uint256);
    function getBond(uint256 epoch) external view returns (uint256);
    function getStartTime(uint256 epoch) external view returns (uint256);
    function getRandomnessSeed(uint256 epoch) external view returns (uint256);
    function getCommitters(uint256 epoch) external view returns (address[] memory);
    function didReveal(uint256 epoch, address runner) external view returns (bool);
    function getBidRecord(uint256 epoch, address runner) external view returns (BidRecord memory);
    function commitWindow() external view returns (uint256);
    function revealWindow() external view returns (uint256);
    function executionWindow() external view returns (uint256);
    function executionDeadline() external view returns (uint256);
    function pendingBondRefunds() external view returns (uint256);
}
