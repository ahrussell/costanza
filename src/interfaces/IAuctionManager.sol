// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAuctionManager
/// @notice Interface for the auction state machine — a reusable commit-reveal
///         sealed-bid auction primitive with bond slashing. The AM knows
///         nothing about wall-clock time, epoch scheduling, treasury, or
///         verification. It is driven entirely by the fund contract.
///
///         State machine:
///
///             COMMIT ── nextPhase ──▸ REVEAL ── nextPhase ──▸ EXECUTION
///                                                                  │
///                                       ┌─ settleExecution ────────┤
///                                       ├─ closeExecution  ────────┤
///                                       └─ abortAuction   ─────────┘
///                                                                  │
///                                                                  ▼
///                                                              SETTLED
///                                                                  │
///                                                                  │ openAuction
///                                                                  ▼
///                                                              COMMIT
///
///         SETTLED is an internal terminal state; it is never prover-facing
///         (provers dispatch on wall-clock). `openAuction` is the only way
///         to leave SETTLED; it requires the previous auction to have reached
///         SETTLED via one of the three closing paths.
interface IAuctionManager {
    // ─── Enums ──────────────────────────────────────────────────────────

    enum AuctionPhase { COMMIT, REVEAL, EXECUTION, SETTLED }

    // ─── Historical Records ─────────────────────────────────────────────

    struct BidRecord {
        bool revealed;      // true if the runner revealed their bid
        uint256 bidAmount;  // 0 if not revealed
        bool winner;        // true if this runner won
        bool forfeited;     // true if the winner forfeited (didn't submit result)
    }

    // ─── State Transitions (onlyFund) ───────────────────────────────────

    /// @notice Open a fresh auction for `epoch` with the given bid ceiling
    ///         and bond amount. Requires the current phase to be SETTLED
    ///         (enforced by implementation) or that no auction has ever been
    ///         opened. `maxBid` and `bond` are stored for the life of the
    ///         auction; the fund is the source of truth for both values.
    /// @param epoch Epoch identifier — opaque to the AM; used as a history
    ///        key and returned by `currentEpoch()` while the auction runs.
    /// @param maxBid The bid ceiling enforced at reveal time.
    /// @param bond The bond amount each committer must stake.
    function openAuction(uint256 epoch, uint256 maxBid, uint256 bond) external;

    /// @notice Advance the state machine by one step: COMMIT→REVEAL or
    ///         REVEAL→EXECUTION. Reverts if called in EXECUTION or SETTLED.
    ///         REVEAL→EXECUTION finalizes the winner selection and distributes
    ///         non-revealer bond forfeits to the fund.
    function nextPhase() external;

    /// @notice Happy-path terminal transition: EXECUTION → SETTLED. The
    ///         caller must send `msg.value == winningBid()` as the bounty;
    ///         the AM combines it with the winner's held bond and pushes
    ///         `bond + bounty` to the winner in a single transfer. Records
    ///         history (non-forfeited).
    function settleExecution() external payable;

    /// @notice No-show terminal transition: EXECUTION → SETTLED. Forfeits
    ///         the held winner bond to the fund and records history
    ///         (marked forfeited). Reverts if called outside EXECUTION.
    function closeExecution() external;

    /// @notice Operator-abort terminal transition: any phase → SETTLED.
    ///         Refunds all held bonds non-confiscatorily. See implementation
    ///         docstring for the per-phase refund matrix. Records history
    ///         (non-forfeited).
    function abortAuction() external;

    // ─── Bidder Actions (onlyFund; fund forwards from provers) ──────────

    /// @notice Record a sealed bid commitment. `msg.value` must equal the
    ///         bond amount configured for the current auction.
    function commit(address runner, bytes32 commitHash) external payable;

    /// @notice Record a bid reveal. Verifies commitment preimage and enforces
    ///         the stored max-bid ceiling. Updates current winner incrementally
    ///         (lowest bid wins; ties broken by first-revealer).
    function reveal(address runner, uint256 bidAmount, bytes32 salt) external;

    // ─── Bond Claims (permissionless) ───────────────────────────────────

    /// @notice Claim a bond refund for a past epoch.
    ///         Eligible: non-winning revealers from that epoch's auction.
    ///         Winners received bond+bounty at `settleExecution` time.
    function claimBond(uint256 epoch) external;

    // ─── Views ──────────────────────────────────────────────────────────

    /// @notice The current auction's phase. Use this (not historical epoch
    ///         lookups) for the in-flight auction's state.
    function phase() external view returns (AuctionPhase);

    /// @notice The current auction's epoch tag (set at `openAuction`).
    function currentEpoch() external view returns (uint256);

    /// @notice Max-bid ceiling for the current auction.
    function maxBid() external view returns (uint256);

    /// @notice Bond amount required per commit for the current auction.
    function bond() external view returns (uint256);

    /// @notice The current auction's leading bidder (lowest revealed bid).
    ///         Returns address(0) before any reveal lands.
    function winner() external view returns (address);

    /// @notice The current auction's leading bid. Zero before any reveal.
    function winningBid() external view returns (uint256);

    /// @notice The list of runners who have committed to the current auction.
    function getCommitters() external view returns (address[] memory);

    /// @notice True if `runner` has revealed their bid in the current auction.
    function didReveal(address runner) external view returns (bool);

    // Historical lookups (keyed by past epoch)

    function getWinner(uint256 epoch) external view returns (address);
    function getWinningBid(uint256 epoch) external view returns (uint256);
    function getBond(uint256 epoch) external view returns (uint256);
    function getBidRecord(uint256 epoch, address runner) external view returns (BidRecord memory);
    function getCommittersOfEpoch(uint256 epoch) external view returns (address[] memory);
    function didRevealInEpoch(uint256 epoch, address runner) external view returns (bool);

    /// @notice Total bond ETH held for non-winning revealers who haven't
    ///         claimed yet. Decrements as `claimBond` calls succeed.
    function pendingBondRefunds() external view returns (uint256);
}
