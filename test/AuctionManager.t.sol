// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AuctionManager.sol";
import "../src/interfaces/IAuctionManager.sol";

/// @title AuctionManagerTest
/// @notice Unit tests for the AuctionManager as a standalone primitive.
///         No wall-clock / timing involved — the AM is manually driven.
///         These tests simulate the fund contract via a test-controlled
///         address (`FUND`) using `vm.prank`.
///
///         Integration with the real fund, snapshot freezing, and
///         wall-clock advancement is covered in `SystemInvariants.t.sol`.
contract AuctionManagerTest is Test {
    AuctionManager public am;
    address constant FUND = address(0xFFD);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA701);

    uint256 constant MAX_BID = 0.01 ether;
    uint256 constant BOND    = 0.001 ether;
    uint256 constant EPOCH_1 = 1;

    function setUp() public {
        am = new AuctionManager(FUND);
        // Pre-fund bidders so they can commit.
        vm.deal(ALICE, 10 ether);
        vm.deal(BOB, 10 ether);
        vm.deal(CAROL, 10 ether);
        vm.deal(FUND, 100 ether);
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _open(uint256 epoch, uint256 maxBidV, uint256 bondV) internal {
        vm.prank(FUND);
        am.openAuction(epoch, maxBidV, bondV);
    }

    function _commit(address runner, bytes32 hash) internal {
        vm.prank(FUND);
        am.commit{value: BOND}(runner, hash);
    }

    function _reveal(address runner, uint256 bid, bytes32 salt) internal {
        vm.prank(FUND);
        am.reveal(runner, bid, salt);
    }

    function _next() internal {
        vm.prank(FUND);
        am.nextPhase();
    }

    function _settle(uint256 bounty) internal {
        vm.prank(FUND);
        am.settleExecution{value: bounty}();
    }

    function _close() internal {
        vm.prank(FUND);
        am.closeExecution();
    }

    function _abort() internal {
        vm.prank(FUND);
        am.abortAuction();
    }

    function _hash(address runner, uint256 bid, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(runner, bid, salt));
    }

    // ─── Bootstrap ──────────────────────────────────────────────────────

    function test_initialState() public {
        assertEq(uint8(am.phase()), uint8(IAuctionManager.AuctionPhase.COMMIT));
        assertEq(am.currentEpoch(), 0);
        assertEq(am.maxBid(), 0);
        assertEq(am.bond(), 0);
        assertEq(am.winner(), address(0));
        assertEq(am.winningBid(), 0);
    }

    function test_openAuction_bootstrap() public {
        _open(EPOCH_1, MAX_BID, BOND);
        assertEq(uint8(am.phase()), uint8(IAuctionManager.AuctionPhase.COMMIT));
        assertEq(am.currentEpoch(), EPOCH_1);
        assertEq(am.maxBid(), MAX_BID);
        assertEq(am.bond(), BOND);
    }

    function test_openAuction_requiresFund() public {
        vm.expectRevert(AuctionManager.Unauthorized.selector);
        am.openAuction(EPOCH_1, MAX_BID, BOND);
    }

    function test_openAuction_requiresSettledAfterFirst() public {
        _open(EPOCH_1, MAX_BID, BOND);
        // Can't re-open from COMMIT
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.WrongPhase.selector);
        am.openAuction(2, MAX_BID, BOND);
    }

    function test_openAuction_rejectsZeroBond() public {
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.InvalidParams.selector);
        am.openAuction(EPOCH_1, MAX_BID, 0);
    }

    function test_openAuction_rejectsZeroMaxBid() public {
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.InvalidParams.selector);
        am.openAuction(EPOCH_1, 0, BOND);
    }

    // ─── COMMIT phase ───────────────────────────────────────────────────

    function test_commit_happy() public {
        _open(EPOCH_1, MAX_BID, BOND);
        bytes32 h = _hash(ALICE, 0.005 ether, bytes32("s"));
        _commit(ALICE, h);

        address[] memory list = am.getCommitters();
        assertEq(list.length, 1);
        assertEq(list[0], ALICE);
    }

    function test_commit_wrongPhaseReverts() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _next(); // REVEAL
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.WrongPhase.selector);
        am.commit{value: BOND}(ALICE, bytes32("h"));
    }

    function test_commit_wrongBondAmountReverts() public {
        _open(EPOCH_1, MAX_BID, BOND);
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.InvalidParams.selector);
        am.commit{value: BOND - 1}(ALICE, bytes32("h"));

        vm.prank(FUND);
        vm.expectRevert(AuctionManager.InvalidParams.selector);
        am.commit{value: BOND + 1}(ALICE, bytes32("h"));
    }

    function test_commit_zeroHashReverts() public {
        _open(EPOCH_1, MAX_BID, BOND);
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.InvalidParams.selector);
        am.commit{value: BOND}(ALICE, bytes32(0));
    }

    function test_commit_doubleCommitReverts() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, bytes32("h"));
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.AlreadyDone.selector);
        am.commit{value: BOND}(ALICE, bytes32("h"));
    }

    function test_commit_maxCommittersEnforced() public {
        _open(EPOCH_1, MAX_BID, BOND);
        uint256 max = am.MAX_COMMITTERS();
        for (uint256 i = 0; i < max; i++) {
            address r = address(uint160(0x1000 + i));
            vm.deal(r, 1 ether);
            _commit(r, bytes32(uint256(i + 1)));
        }
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.TooManyCommitters.selector);
        am.commit{value: BOND}(ALICE, bytes32("extra"));
    }

    function test_commit_bondHeldInAm() public {
        _open(EPOCH_1, MAX_BID, BOND);
        uint256 amBalBefore = address(am).balance;
        _commit(ALICE, bytes32("h"));
        assertEq(address(am).balance, amBalBefore + BOND);
    }

    // ─── nextPhase transitions ──────────────────────────────────────────

    function test_nextPhase_commitToReveal() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _next();
        assertEq(uint8(am.phase()), uint8(IAuctionManager.AuctionPhase.REVEAL));
    }

    function test_nextPhase_revealToExecution() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _next(); // REVEAL
        _next(); // EXECUTION
        assertEq(uint8(am.phase()), uint8(IAuctionManager.AuctionPhase.EXECUTION));
    }

    function test_nextPhase_fromExecutionReverts() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _next();
        _next();
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.WrongPhase.selector);
        am.nextPhase();
    }

    function test_nextPhase_fromSettledReverts() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _next(); _next(); // EXECUTION
        _close(); // SETTLED
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.WrongPhase.selector);
        am.nextPhase();
    }

    function test_nextPhase_requiresFund() public {
        _open(EPOCH_1, MAX_BID, BOND);
        vm.expectRevert(AuctionManager.Unauthorized.selector);
        am.nextPhase();
    }

    // ─── REVEAL phase ───────────────────────────────────────────────────

    function test_reveal_happy() public {
        _open(EPOCH_1, MAX_BID, BOND);
        uint256 bid = 0.005 ether;
        bytes32 salt = bytes32("s");
        _commit(ALICE, _hash(ALICE, bid, salt));
        _next();
        _reveal(ALICE, bid, salt);

        assertTrue(am.didReveal(ALICE));
        assertEq(am.winner(), ALICE);
        assertEq(am.winningBid(), bid);
    }

    function test_reveal_lowestWins() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.008 ether, bytes32("a")));
        _commit(BOB, _hash(BOB, 0.003 ether, bytes32("b")));
        _commit(CAROL, _hash(CAROL, 0.005 ether, bytes32("c")));
        _next();

        _reveal(ALICE, 0.008 ether, bytes32("a"));
        assertEq(am.winner(), ALICE);

        _reveal(BOB, 0.003 ether, bytes32("b"));
        assertEq(am.winner(), BOB); // Bob's lower bid takes over

        _reveal(CAROL, 0.005 ether, bytes32("c"));
        assertEq(am.winner(), BOB); // Bob remains
        assertEq(am.winningBid(), 0.003 ether);
    }

    function test_reveal_firstRevealerTiebreak() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.004 ether, bytes32("a")));
        _commit(BOB, _hash(BOB, 0.004 ether, bytes32("b")));
        _next();

        _reveal(ALICE, 0.004 ether, bytes32("a"));
        _reveal(BOB, 0.004 ether, bytes32("b"));

        // Ties broken by first revealer (Alice reveals first)
        assertEq(am.winner(), ALICE);
    }

    function test_reveal_overCeilingReverts() public {
        _open(EPOCH_1, MAX_BID, BOND);
        uint256 bid = MAX_BID + 1;
        bytes32 salt = bytes32("s");
        _commit(ALICE, _hash(ALICE, bid, salt));
        _next();
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.InvalidParams.selector);
        am.reveal(ALICE, bid, salt);
    }

    function test_reveal_atCeilingAllowed() public {
        _open(EPOCH_1, MAX_BID, BOND);
        bytes32 salt = bytes32("s");
        _commit(ALICE, _hash(ALICE, MAX_BID, salt));
        _next();
        _reveal(ALICE, MAX_BID, salt);
        assertEq(am.winningBid(), MAX_BID);
    }

    function test_reveal_zeroBidReverts() public {
        _open(EPOCH_1, MAX_BID, BOND);
        bytes32 salt = bytes32("s");
        _commit(ALICE, _hash(ALICE, 0, salt)); // hash of 0-bid
        _next();
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.InvalidParams.selector);
        am.reveal(ALICE, 0, salt);
    }

    function test_reveal_badPreimageReverts() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("correct")));
        _next();
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.InvalidParams.selector);
        am.reveal(ALICE, 0.005 ether, bytes32("wrong"));
    }

    function test_reveal_doubleRevealReverts() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("s")));
        _next();
        _reveal(ALICE, 0.005 ether, bytes32("s"));
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.AlreadyDone.selector);
        am.reveal(ALICE, 0.005 ether, bytes32("s"));
    }

    function test_reveal_withoutCommitReverts() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _next();
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.Unauthorized.selector);
        am.reveal(ALICE, 0.005 ether, bytes32("s"));
    }

    function test_reveal_wrongPhaseReverts() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("s")));
        // still COMMIT
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.WrongPhase.selector);
        am.reveal(ALICE, 0.005 ether, bytes32("s"));
    }

    // ─── Bond accounting at reveal close ────────────────────────────────

    function test_nonRevealerBondsForfeitToFund() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("a")));
        _commit(BOB, _hash(BOB, 0.004 ether, bytes32("b")));
        _next(); // REVEAL

        // Only Alice reveals
        _reveal(ALICE, 0.005 ether, bytes32("a"));

        uint256 fundBalBefore = FUND.balance;
        _next(); // REVEAL → EXECUTION; Bob's bond forfeits to fund
        assertEq(FUND.balance, fundBalBefore + BOND);
    }

    function test_nonWinningRevealerBondsBecomePending() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("a")));
        _commit(BOB, _hash(BOB, 0.003 ether, bytes32("b")));
        _commit(CAROL, _hash(CAROL, 0.007 ether, bytes32("c")));
        _next();
        _reveal(ALICE, 0.005 ether, bytes32("a"));
        _reveal(BOB, 0.003 ether, bytes32("b"));
        _reveal(CAROL, 0.007 ether, bytes32("c"));
        _next(); // REVEAL → EXECUTION

        // Bob wins; Alice + Carol are non-winning revealers.
        assertEq(am.winner(), BOB);
        assertEq(am.pendingBondRefunds(), 2 * BOND);
    }

    function test_noRevealsAllCommittersForfeit() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("a")));
        _commit(BOB, _hash(BOB, 0.004 ether, bytes32("b")));
        _next(); // REVEAL

        uint256 fundBalBefore = FUND.balance;
        _next(); // REVEAL → EXECUTION, no reveals
        assertEq(FUND.balance, fundBalBefore + 2 * BOND);
        assertEq(am.winner(), address(0));
    }

    // ─── EXECUTION / settle paths ───────────────────────────────────────

    function test_settleExecution_happy() public {
        _open(EPOCH_1, MAX_BID, BOND);
        uint256 bid = 0.005 ether;
        _commit(ALICE, _hash(ALICE, bid, bytes32("s")));
        _next();
        _reveal(ALICE, bid, bytes32("s"));
        _next(); // EXECUTION

        uint256 aliceBalBefore = ALICE.balance;
        _settle(bid); // msg.value == winningBid

        assertEq(ALICE.balance, aliceBalBefore + BOND + bid);
        assertEq(uint8(am.phase()), uint8(IAuctionManager.AuctionPhase.SETTLED));
    }

    function test_settleExecution_bountyMismatchReverts() public {
        _open(EPOCH_1, MAX_BID, BOND);
        uint256 bid = 0.005 ether;
        _commit(ALICE, _hash(ALICE, bid, bytes32("s")));
        _next();
        _reveal(ALICE, bid, bytes32("s"));
        _next();
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.BountyMismatch.selector);
        am.settleExecution{value: bid - 1}();
    }

    function test_settleExecution_wrongPhaseReverts() public {
        _open(EPOCH_1, MAX_BID, BOND);
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.WrongPhase.selector);
        am.settleExecution{value: 0}();
    }

    function test_settleExecution_noWinnerReverts() public {
        // No commits → no reveals → no winner, still in EXECUTION
        _open(EPOCH_1, MAX_BID, BOND);
        _next(); _next(); // EXECUTION with no winner
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.InvalidParams.selector);
        am.settleExecution{value: 0}();
    }

    function test_closeExecution_forfeits() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("s")));
        _next();
        _reveal(ALICE, 0.005 ether, bytes32("s"));
        _next(); // EXECUTION

        uint256 fundBalBefore = FUND.balance;
        _close();

        assertEq(FUND.balance, fundBalBefore + BOND);
        assertEq(uint8(am.phase()), uint8(IAuctionManager.AuctionPhase.SETTLED));

        // Historical record shows forfeiture
        IAuctionManager.BidRecord memory rec = am.getBidRecord(EPOCH_1, ALICE);
        assertTrue(rec.winner);
        assertTrue(rec.forfeited);
    }

    function test_closeExecution_noWinner_noTransfer() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _next(); _next(); // EXECUTION, empty auction
        uint256 fundBalBefore = FUND.balance;
        _close();
        assertEq(FUND.balance, fundBalBefore);
        assertEq(uint8(am.phase()), uint8(IAuctionManager.AuctionPhase.SETTLED));
    }

    function test_closeExecution_wrongPhaseReverts() public {
        _open(EPOCH_1, MAX_BID, BOND);
        vm.prank(FUND);
        vm.expectRevert(AuctionManager.WrongPhase.selector);
        am.closeExecution();
    }

    // ─── abortAuction ───────────────────────────────────────────────────

    function test_abortAuction_fromCommit_refundsAll() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("a")));
        _commit(BOB, _hash(BOB, 0.004 ether, bytes32("b")));

        uint256 aliceBalBefore = ALICE.balance;
        uint256 bobBalBefore = BOB.balance;

        _abort();

        assertEq(ALICE.balance, aliceBalBefore + BOND);
        assertEq(BOB.balance, bobBalBefore + BOND);
        assertEq(uint8(am.phase()), uint8(IAuctionManager.AuctionPhase.SETTLED));
    }

    function test_abortAuction_fromReveal_refundsAll() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("a")));
        _commit(BOB, _hash(BOB, 0.003 ether, bytes32("b")));
        _next(); // REVEAL
        _reveal(ALICE, 0.005 ether, bytes32("a"));

        uint256 aliceBalBefore = ALICE.balance;
        uint256 bobBalBefore = BOB.balance;

        _abort();

        // Both get refund regardless of reveal status
        assertEq(ALICE.balance, aliceBalBefore + BOND);
        assertEq(BOB.balance, bobBalBefore + BOND);
    }

    function test_abortAuction_fromExecution_refundsWinnerOnly() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("a")));
        _commit(BOB, _hash(BOB, 0.003 ether, bytes32("b")));
        _next();
        _reveal(ALICE, 0.005 ether, bytes32("a"));
        _reveal(BOB, 0.003 ether, bytes32("b"));
        _next(); // EXECUTION

        uint256 bobBalBefore = BOB.balance;  // winner
        _abort();
        assertEq(BOB.balance, bobBalBefore + BOND);
        // Alice's non-winning-revealer bond is in pendingBondRefunds — claimable post-abort
        assertEq(am.pendingBondRefunds(), BOND);
    }

    function test_abortAuction_fromSettled_noop() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _next(); _next(); // EXECUTION
        _close(); // SETTLED

        uint256 amBal = address(am).balance;
        _abort();
        assertEq(address(am).balance, amBal);
        assertEq(uint8(am.phase()), uint8(IAuctionManager.AuctionPhase.SETTLED));
    }

    // ─── claimBond (permissionless) ─────────────────────────────────────

    function test_claimBond_happy() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("a")));
        _commit(BOB, _hash(BOB, 0.003 ether, bytes32("b")));
        _next();
        _reveal(ALICE, 0.005 ether, bytes32("a"));
        _reveal(BOB, 0.003 ether, bytes32("b"));
        _next(); // EXECUTION — Bob wins, Alice pending

        _settle(0.003 ether); // Bob gets bond+bounty, transitions to SETTLED

        uint256 aliceBalBefore = ALICE.balance;
        vm.prank(ALICE);
        am.claimBond(EPOCH_1);
        assertEq(ALICE.balance, aliceBalBefore + BOND);
        assertEq(am.pendingBondRefunds(), 0);
    }

    function test_claimBond_winnerCannotClaim() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("a")));
        _next();
        _reveal(ALICE, 0.005 ether, bytes32("a"));
        _next();
        _settle(0.005 ether);

        vm.prank(ALICE);
        vm.expectRevert(AuctionManager.InvalidParams.selector);
        am.claimBond(EPOCH_1);
    }

    function test_claimBond_nonRevealerCannotClaim() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("a")));
        _commit(BOB, _hash(BOB, 0.004 ether, bytes32("b")));
        _next();
        _reveal(ALICE, 0.005 ether, bytes32("a"));
        // Bob doesn't reveal
        _next();

        vm.prank(BOB);
        vm.expectRevert(AuctionManager.Unauthorized.selector);
        am.claimBond(EPOCH_1);
    }

    function test_claimBond_doubleClaimReverts() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("a")));
        _commit(BOB, _hash(BOB, 0.003 ether, bytes32("b")));
        _next();
        _reveal(ALICE, 0.005 ether, bytes32("a"));
        _reveal(BOB, 0.003 ether, bytes32("b"));
        _next();
        _settle(0.003 ether);

        vm.prank(ALICE);
        am.claimBond(EPOCH_1);

        vm.prank(ALICE);
        vm.expectRevert(AuctionManager.AlreadyDone.selector);
        am.claimBond(EPOCH_1);
    }

    // ─── Lifecycle: reopen after settle ─────────────────────────────────

    function test_reopenAfterSettled_clearsState() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("a")));
        _next();
        _reveal(ALICE, 0.005 ether, bytes32("a"));
        _next();
        _settle(0.005 ether);

        // Open epoch 2
        _open(2, MAX_BID * 2, BOND);
        assertEq(am.currentEpoch(), 2);
        assertEq(am.maxBid(), MAX_BID * 2);
        assertEq(uint8(am.phase()), uint8(IAuctionManager.AuctionPhase.COMMIT));
        assertEq(am.winner(), address(0));
        assertEq(am.winningBid(), 0);
        assertEq(am.getCommitters().length, 0);
        assertFalse(am.didReveal(ALICE));

        // Historical records survive
        assertEq(am.getWinner(EPOCH_1), ALICE);
        assertEq(am.getWinningBid(EPOCH_1), 0.005 ether);
        assertEq(am.getBond(EPOCH_1), BOND);
    }

    function test_reopenAfterAbort() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("a")));
        _abort();

        // Abort lands in SETTLED — can reopen
        _open(2, MAX_BID, BOND);
        assertEq(uint8(am.phase()), uint8(IAuctionManager.AuctionPhase.COMMIT));
    }

    // ─── Access control ─────────────────────────────────────────────────

    function test_onlyFund_mutations() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("a")));

        // Each mutation guarded by onlyFund
        vm.expectRevert(AuctionManager.Unauthorized.selector);
        am.nextPhase();

        vm.expectRevert(AuctionManager.Unauthorized.selector);
        am.commit{value: BOND}(BOB, bytes32("h"));

        vm.expectRevert(AuctionManager.Unauthorized.selector);
        am.closeExecution();

        vm.expectRevert(AuctionManager.Unauthorized.selector);
        am.abortAuction();
    }

    // ─── Bond conservation invariant ────────────────────────────────────

    function test_invariant_bondConservation() public {
        _open(EPOCH_1, MAX_BID, BOND);
        _commit(ALICE, _hash(ALICE, 0.005 ether, bytes32("a")));
        _commit(BOB, _hash(BOB, 0.003 ether, bytes32("b")));
        _commit(CAROL, _hash(CAROL, 0.004 ether, bytes32("c")));

        // During COMMIT: all bonds held; pendingBondRefunds = 0
        assertEq(address(am).balance, 3 * BOND);
        assertEq(am.pendingBondRefunds(), 0);

        _next();
        _reveal(ALICE, 0.005 ether, bytes32("a"));
        _reveal(BOB, 0.003 ether, bytes32("b"));
        // Carol doesn't reveal
        _next(); // REVEAL → EXECUTION

        // After reveal close:
        //   - Carol's bond forfeited to fund (1 BOND out)
        //   - Alice's bond is in pendingBondRefunds (non-winning revealer)
        //   - Bob's bond still held as in-flight winner bond
        assertEq(address(am).balance, 2 * BOND);
        assertEq(am.pendingBondRefunds(), BOND);

        _settle(0.003 ether); // Bob gets bond+bounty

        // After settle:
        //   - Bob's bond pushed out (1 BOND + 0.003 bounty out)
        //   - Alice's pending remains
        assertEq(address(am).balance, BOND);
        assertEq(am.pendingBondRefunds(), BOND);

        vm.prank(ALICE);
        am.claimBond(EPOCH_1);

        // Fully drained
        assertEq(address(am).balance, 0);
        assertEq(am.pendingBondRefunds(), 0);
    }
}
