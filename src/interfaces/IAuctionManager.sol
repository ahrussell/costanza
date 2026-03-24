// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAuctionManager
/// @notice Interface for the auction state machine that manages commit-reveal auctions.
///         Handles phases, bids, bonds, timing, and winner selection.
///         Does NOT know about epoch numbering, treasury state, or verification.
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

    // ─── State Transitions (onlyFund) ───────────────────────────────────

    /// @notice Open a new auction. IDLE → COMMIT.
    /// @param epoch The epoch identifier (opaque to the AM).
    /// @param bond The bond amount each committer must stake.
    function openAuction(uint256 epoch, uint256 bond) external;

    /// @notice Record a sealed bid commitment. Must be called with bond ETH attached.
    function commit(uint256 epoch, address runner, bytes32 commitHash) external payable;

    /// @notice Close the commit phase. COMMIT → REVEAL (or SETTLED if no commits).
    /// @return commitCount Number of commits received.
    function closeCommitPhase(uint256 epoch) external returns (uint256 commitCount);

    /// @notice Record a bid reveal. Verifies commitment hash and tracks lowest bidder.
    function recordReveal(uint256 epoch, address runner, uint256 bidAmount, bytes32 salt) external;

    /// @notice Close the reveal phase. REVEAL → EXECUTION (or SETTLED if no reveals).
    ///         Refunds bonds to non-winning revealers.
    /// @return winner Address of the lowest bidder.
    /// @return winningBid The winning bid amount in wei.
    /// @return revealCount Number of valid reveals.
    function closeRevealPhase(uint256 epoch) external returns (address winner, uint256 winningBid, uint256 revealCount);

    /// @notice Settle a successful execution. EXECUTION → SETTLED.
    ///         Validates caller is the winner and within the execution window.
    ///         Refunds bond to the winner. Stores historical bid records.
    /// @param epoch The epoch identifier.
    /// @param caller The address attempting to settle (must be the winner).
    function settleExecution(uint256 epoch, address caller) external;

    /// @notice Forfeit the winner's bond. EXECUTION → SETTLED.
    ///         Validates the execution window has expired.
    ///         Sends forfeited bond to the fund. Stores historical bid records.
    /// @param epoch The epoch identifier.
    function forfeitExecution(uint256 epoch) external;

    /// @notice Update auction timing parameters.
    function setTiming(uint256 _commitWindow, uint256 _revealWindow, uint256 _executionWindow) external;

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
}
