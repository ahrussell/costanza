// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAuctionManager
/// @notice Interface for the auction state machine that manages commit-reveal auctions.
///         Handles phases, bids, bonds, timing, and winner selection.
///         Does NOT know about epoch numbering, treasury state, or verification.
///
///         Phase advancement is automatic via syncPhase() — the fund contract calls it
///         before every action. Bond refunds are lazy via claimBond(epoch).
interface IAuctionManager {
    // ─── Enums ──────────────────────────────────────────────────────────

    enum AuctionPhase { IDLE, COMMIT, REVEAL, EXECUTION, SETTLED }

    // ─── Historical Records ─────────────────────────────────────────────

    struct BidRecord {
        bool revealed;      // true if the runner revealed their bid
        uint256 bidAmount;  // 0 if not revealed
        bool winner;        // true if this runner won
        bool forfeited;     // true if the winner forfeited (didn't submit result)
    }

    // ─── Auction Setup & Sync (onlyFund) ────────────────────────────────

    /// @notice Open a new auction. IDLE/SETTLED → COMMIT.
    /// @param epoch The epoch identifier (opaque to the AM).
    /// @param bond The bond amount each committer must stake.
    /// @param startTime Wall-clock scheduled start time for this auction's phase windows.
    function openAuction(uint256 epoch, uint256 bond, uint256 startTime) external;

    /// @notice Advance the auction through any elapsed phase windows.
    ///         Called by the fund contract before every action.
    /// @return phase The phase AFTER advancement.
    /// @return advanced True if any phase transition occurred.
    function syncPhase(uint256 epoch) external returns (AuctionPhase phase, bool advanced);

    // ─── Prover Actions (onlyFund, forwarded from provers) ──────────────

    /// @notice Record a sealed bid commitment. Must be called with bond ETH attached.
    function commit(uint256 epoch, address runner, bytes32 commitHash) external payable;

    /// @notice Record a bid reveal. Verifies commitment hash and tracks lowest bidder.
    function recordReveal(uint256 epoch, address runner, uint256 bidAmount, bytes32 salt) external;

    /// @notice Settle a successful execution. EXECUTION → SETTLED.
    ///         Validates caller is the winner and within the execution window.
    ///         Winner's bond becomes claimable.
    function settleExecution(uint256 epoch, address caller) external;

    // ─── Configuration (onlyFund) ───────────────────────────────────────

    /// @notice Update auction timing parameters.
    function setTiming(uint256 _commitWindow, uint256 _revealWindow, uint256 _executionWindow) external;

    // ─── Bond Claims (anyone) ───────────────────────────────────────────

    /// @notice Claim bond refund for a specific epoch.
    ///         Eligible: non-winning revealers. Winners use settleExecution.
    function claimBond(uint256 epoch) external;

    /// @notice Claim the legacy accumulated bond balance (for backward compatibility
    ///         with any bonds credited before the lazy-claim migration).
    function claimLegacyBonds() external;

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
