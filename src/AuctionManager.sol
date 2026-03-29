// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IAuctionManager.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionManager
/// @notice Auction state machine for commit-reveal sealed-bid auctions.
///         Operates on one auction at a time. Stores historical BidRecords
///         per-epoch for querying past auctions.
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

    /// @notice Claimable bond balances (pull-based refunds to prevent griefing).
    mapping(address => uint256) public claimableBonds;

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

    // Per-runner state for the current auction (cleared on next openAuction)
    mapping(address => bytes32) internal bidCommits;
    mapping(address => bool) internal hasCommitted;
    mapping(address => bool) internal hasRevealed;
    mapping(address => uint256) internal revealedBids;
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

    // ─── State Transitions ───────────────────────────────────────────────

    /// @inheritdoc IAuctionManager
    function openAuction(uint256 epoch, uint256 bond) external override onlyFund {
        if (bond == 0) revert InvalidParams();
        if (currentPhase != AuctionPhase.IDLE && currentPhase != AuctionPhase.SETTLED) revert WrongPhase();

        // Reset current auction state
        _clearCurrentAuction();

        currentAuctionEpoch = epoch;
        currentPhase = AuctionPhase.COMMIT;
        currentStartTime = block.timestamp;
        currentBondAmount = bond;
    }

    /// @inheritdoc IAuctionManager
    function commit(uint256 epoch, address runner, bytes32 commitHash) external payable override onlyFund {
        if (epoch != currentAuctionEpoch) revert InvalidParams();
        if (currentPhase != AuctionPhase.COMMIT) revert WrongPhase();
        if (block.timestamp >= currentStartTime + commitWindow) revert TimingError();
        if (hasCommitted[runner]) revert AlreadyDone();
        if (commitHash == bytes32(0)) revert InvalidParams();
        if (msg.value < currentBondAmount) revert InvalidParams();
        if (committers.length >= MAX_COMMITTERS) revert TooManyCommitters();

        hasCommitted[runner] = true;
        bidCommits[runner] = commitHash;
        committers.push(runner);
        currentCommitCount += 1;
    }

    /// @inheritdoc IAuctionManager
    function closeCommitPhase(uint256 epoch) external override onlyFund returns (uint256 commitCount) {
        if (epoch != currentAuctionEpoch) revert InvalidParams();
        if (currentPhase != AuctionPhase.COMMIT) revert WrongPhase();
        if (block.timestamp < currentStartTime + commitWindow) revert TimingError();

        commitCount = currentCommitCount;
        if (commitCount == 0) {
            currentPhase = AuctionPhase.SETTLED;
            _storeHistory(false);
        } else {
            currentPhase = AuctionPhase.REVEAL;
        }
    }

    /// @inheritdoc IAuctionManager
    function recordReveal(uint256 epoch, address runner, uint256 bidAmount, bytes32 salt) external override onlyFund {
        if (epoch != currentAuctionEpoch) revert InvalidParams();
        if (currentPhase != AuctionPhase.REVEAL) revert WrongPhase();
        if (block.timestamp >= currentStartTime + commitWindow + revealWindow) revert TimingError();
        if (!hasCommitted[runner]) revert Unauthorized();
        if (hasRevealed[runner]) revert AlreadyDone();

        // Verify commitment
        bytes32 expectedHash = keccak256(abi.encodePacked(bidAmount, salt));
        if (expectedHash != bidCommits[runner]) revert InvalidParams();

        hasRevealed[runner] = true;
        revealedBids[runner] = bidAmount;
        saltAccumulator ^= salt;
        currentRevealCount += 1;

        // Update winner if this is the lowest bid (or first reveal)
        if (currentWinner == address(0) || bidAmount < currentWinningBid) {
            currentWinner = runner;
            currentWinningBid = bidAmount;
        }
    }

    /// @inheritdoc IAuctionManager
    function closeRevealPhase(uint256 epoch) external override onlyFund returns (
        address winner, uint256 winningBid, uint256 revealCount
    ) {
        if (epoch != currentAuctionEpoch) revert InvalidParams();
        if (currentPhase != AuctionPhase.REVEAL) revert WrongPhase();
        if (block.timestamp < currentStartTime + commitWindow + revealWindow) revert TimingError();

        revealCount = currentRevealCount;

        if (revealCount == 0) {
            currentPhase = AuctionPhase.SETTLED;
            _storeHistory(false);
            return (address(0), 0, 0);
        }

        // Enter execution phase — seed mixes prevrandao with revealed salts so
        // neither the block proposer alone nor the last revealer alone can control it.
        currentPhase = AuctionPhase.EXECUTION;
        currentRandomnessSeed = uint256(keccak256(abi.encodePacked(block.prevrandao, saltAccumulator)));
        winner = currentWinner;
        winningBid = currentWinningBid;

        // Credit bonds to non-winners who revealed (pull-based to prevent griefing).
        // Non-revealers lose their bond — sent to fund treasury.
        uint256 bond = currentBondAmount;
        uint256 unrevealedBonds = 0;
        for (uint256 i = 0; i < committers.length; i++) {
            address r = committers[i];
            if (r != winner && hasRevealed[r]) {
                claimableBonds[r] += bond;
            } else if (r != winner) {
                unrevealedBonds += bond;
            }
        }
        // Send unrevealed bonds to fund treasury
        if (unrevealedBonds > 0) {
            (bool sent, ) = payable(fund).call{value: unrevealedBonds}("");
            if (!sent) claimableBonds[fund] += unrevealedBonds;
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

        // Credit bond to the winner (pull-based)
        claimableBonds[winner] += bondRefund;
    }

    /// @inheritdoc IAuctionManager
    function forfeitExecution(uint256 epoch) external override onlyFund {
        if (epoch != currentAuctionEpoch) revert InvalidParams();
        if (currentPhase != AuctionPhase.EXECUTION) revert WrongPhase();
        if (block.timestamp < _executionDeadline()) revert TimingError();

        _doForfeit();
    }

    /// @inheritdoc IAuctionManager
    function setTiming(uint256 _commitWindow, uint256 _revealWindow, uint256 _executionWindow) external override onlyFund {
        if (_commitWindow == 0 || _revealWindow == 0 || _executionWindow == 0) revert InvalidParams();
        commitWindow = _commitWindow;
        revealWindow = _revealWindow;
        executionWindow = _executionWindow;
    }

    // ─── Pull-based Bond Claims ─────────────────────────────────────────

    /// @notice Claim accumulated bond refunds. Anyone can call for their own balance.
    function claimBond() external nonReentrant {
        uint256 amount = claimableBonds[msg.sender];
        if (amount == 0) revert InvalidParams();
        claimableBonds[msg.sender] = 0;
        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        if (!sent) revert TransferFailed();
    }

    // ─── Internal ────────────────────────────────────────────────────────

    function _executionDeadline() internal view returns (uint256) {
        return currentStartTime + commitWindow + revealWindow + executionWindow;
    }

    /// @dev Forfeit the current auction winner's bond. Stores history, sends bond to fund.
    function _doForfeit() internal returns (address forfeitedRunner, uint256 forfeitedBond) {
        forfeitedRunner = currentWinner;
        forfeitedBond = currentBondAmount;
        currentPhase = AuctionPhase.SETTLED;
        _storeHistory(true);

        (bool sent, ) = payable(fund).call{value: forfeitedBond}("");
        if (!sent) revert TransferFailed();
    }

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
            bool revealed = hasRevealed[runner];
            bidRecords[epoch][runner] = BidRecord({
                revealed: revealed,
                bidAmount: revealed ? revealedBids[runner] : 0,
                winner: runner == winner,
                forfeited: runner == winner && forfeited
            });
        }
    }

    /// @dev Clear current auction working state for reuse.
    function _clearCurrentAuction() internal {
        for (uint256 i = 0; i < committers.length; i++) {
            address runner = committers[i];
            delete bidCommits[runner];
            delete hasCommitted[runner];
            delete hasRevealed[runner];
            delete revealedBids[runner];
        }
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

    // ─── Views ───────────────────────────────────────────────────────────

    function getPhase(uint256 epoch) external view override returns (AuctionPhase) {
        if (epoch == currentAuctionEpoch) return currentPhase;
        if (auctionHistory[epoch].startTime != 0) return AuctionPhase.SETTLED;
        return AuctionPhase.IDLE;
    }

    function getWinner(uint256 epoch) external view override returns (address) {
        if (epoch == currentAuctionEpoch) return currentWinner;
        return auctionHistory[epoch].winner;
    }

    function getWinningBid(uint256 epoch) external view override returns (uint256) {
        if (epoch == currentAuctionEpoch) return currentWinningBid;
        return auctionHistory[epoch].winningBid;
    }

    function getBond(uint256 epoch) external view override returns (uint256) {
        if (epoch == currentAuctionEpoch) return currentBondAmount;
        return auctionHistory[epoch].bondAmount;
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
        if (epoch == currentAuctionEpoch) return hasRevealed[runner];
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
