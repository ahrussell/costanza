// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
import "../src/interfaces/IAuctionManager.sol";
import "./helpers/EpochTest.sol";

/// @title Auction State Machine Invariants
///
/// Spec-in-code for the properties documented in docs/AUCTION_INVARIANTS.md.
/// Each test maps 1:1 to an invariant (I1–I7) or a derived property. A
/// passing test asserts that the current contract satisfies that invariant
/// under the covered conditions.
///
/// Tests marked `[POST_REFACTOR]` depend on API that doesn't exist yet
/// (`nextPhase`, `resetAuction`, manual-only FREEZE_AUCTION semantics).
/// They're stubbed with clear TODOs and will be filled in once the
/// _nextPhase refactor lands. When that happens, every `[POST_REFACTOR]`
/// marker should disappear from this file.
contract AuctionInvariantsTest is EpochTest {
    TheHumanFund public fund;
    AuctionManager public am;

    address runner1 = address(0x4001);
    address runner2 = address(0x4002);

    uint256 constant EPOCH_DUR  = 300;
    uint256 constant COMMIT_WIN = 60;
    uint256 constant REVEAL_WIN = 30;
    uint256 constant EXEC_WIN   = 120;

    function setUp() public {
        fund = new TheHumanFund{value: 10 ether}(
            1000, 0.01 ether,
            address(0xBEEF), address(0xBEEF), address(0xBEEF), address(0xBEEF), address(0)
        );

        am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am));
        fund.setAuctionTiming(EPOCH_DUR, COMMIT_WIN, REVEAL_WIN, EXEC_WIN);

        vm.deal(runner1, 10 ether);
        vm.deal(runner2, 10 ether);
    }

    function _commitHash(address runner, uint256 bid, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(runner, bid, salt));
    }

    // ══════════════════════════════════════════════════════════════════
    // I1. Monotonicity — (currentEpoch, phase) is strictly lex-increasing
    //     under any driver. No call reverses epoch or phase.
    // ══════════════════════════════════════════════════════════════════

    /// Under repeated wall-clock advancement, currentEpoch is non-decreasing.
    /// Covers the time driver; manual driver coverage lives in the
    /// [POST_REFACTOR] test below.
    function test_I1_timeDriver_monotonicEpoch() public {
        uint256 prevEpoch = fund.currentEpoch();
        for (uint256 i = 0; i < 20; i++) {
            vm.warp(block.timestamp + EPOCH_DUR / 3);
            fund.syncPhase();
            uint256 e = fund.currentEpoch();
            assertGe(e, prevEpoch, "I1: epoch must not decrease");
            prevEpoch = e;
        }
    }

    /// Idempotence: repeated syncPhase at the same timestamp must not
    /// advance state. (A driver that re-runs cleanups would break I2.)
    function test_I1_syncPhaseIdempotent() public {
        fund.syncPhase();
        uint256 e1 = fund.currentEpoch();
        IAuctionManager.AuctionPhase p1 = am.getPhase(e1);
        fund.syncPhase();
        fund.syncPhase();
        fund.syncPhase();
        assertEq(fund.currentEpoch(), e1, "I1: epoch stable under repeat sync");
        assertEq(uint8(am.getPhase(e1)), uint8(p1), "I1: phase stable under repeat sync");
    }

    // [POST_REFACTOR] I1 under manual driver:
    //   - Call `fund.nextPhase()` as owner, assert (epoch, phase) only
    //     moves forward. Needs the owner entry point to exist.

    // ══════════════════════════════════════════════════════════════════
    // I2. Transition completeness — every phase exit runs its cleanup
    //     exactly once. Tested via observable outcomes: non-reveal
    //     forfeit runs exactly once, seed capture runs exactly once,
    //     snapshot freeze runs exactly once.
    // ══════════════════════════════════════════════════════════════════

    /// Non-revealer forfeiture: committer who doesn't reveal has their
    /// bond forfeited to the treasury at reveal close, regardless of how
    /// many times syncPhase is called afterward.
    function test_I2_nonRevealerForfeit_exactlyOnce() public {
        fund.syncPhase();
        uint256 bond = fund.currentBond();
        uint256 treasuryBefore = address(fund).balance;

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("salt")));

        // Warp past reveal window without revealing → bond forfeits to treasury
        vm.warp(block.timestamp + COMMIT_WIN + REVEAL_WIN + 1);
        fund.syncPhase();

        // Treasury gained exactly `bond`
        assertEq(address(fund).balance, treasuryBefore + bond, "I2: one forfeit on reveal close");

        // Repeated syncPhase must not double-forfeit. Treasury balance
        // only changes from epoch rollover (new epoch opens, no new commits).
        uint256 afterFirst = address(fund).balance;
        fund.syncPhase();
        fund.syncPhase();
        assertEq(address(fund).balance, afterFirst, "I2: no double forfeit under repeat sync");
    }

    // ══════════════════════════════════════════════════════════════════
    // I3. Bond accounting closure — every committed bond ends in exactly
    //     one of: held, claimable, winner-held, forfeited-to-treasury.
    //     No double-counting, no leaks.
    // ══════════════════════════════════════════════════════════════════

    /// A committer who reveals but isn't the winner gets their bond to
    /// the claimable state, not forfeited. Conservation: wei in == wei
    /// out across bond states.
    function test_I3_nonWinnerRevealer_bondClaimable() public {
        fund.syncPhase();
        uint256 bond = fund.currentBond();

        // Two runners commit; runner1 is the loser (higher bid), runner2 wins.
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.008 ether, bytes32("r1")));
        vm.prank(runner2);
        fund.commit{value: bond}(_commitHash(runner2, 0.005 ether, bytes32("r2")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.008 ether, bytes32("r1"));
        vm.prank(runner2);
        fund.reveal(0.005 ether, bytes32("r2"));

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase(); // closes reveal, picks winner (runner2)

        // runner1 (non-winner) can claim bond back
        uint256 r1Before = runner1.balance;
        vm.prank(runner1);
        am.claimBond(1);
        assertEq(runner1.balance - r1Before, bond, "I3: non-winner reveal bond claimable");

        // Second claim must revert — no double-credit. Reverting is
        // strictly stronger than silent no-op: it catches client bugs
        // that repeat the call.
        vm.prank(runner1);
        vm.expectRevert(AuctionManager.AlreadyDone.selector);
        am.claimBond(1);
    }

    // [POST_REFACTOR] I3 conservation test:
    //   - Sum tracked bond states (claimableBonds + forfeited + winner-held)
    //     should equal total commits across all epochs. Needs a helper on
    //     AuctionManager or explicit test harness tracking.

    // ══════════════════════════════════════════════════════════════════
    // I4. Schedule coherence — after any transition,
    //     epochStartTime(currentEpoch) <= block.timestamp.
    //     Wall clock never "catches up" from the past.
    // ══════════════════════════════════════════════════════════════════

    function test_I4_epochStartNeverInFuture_underTimeAdvance() public {
        for (uint256 i = 0; i < 15; i++) {
            vm.warp(block.timestamp + EPOCH_DUR * 2 + 17); // arbitrary jump
            fund.syncPhase();
            assertLe(
                fund.epochStartTime(fund.currentEpoch()),
                block.timestamp,
                "I4: current epoch start must not be in the future"
            );
        }
    }

    // [POST_REFACTOR] I4 under manual driver:
    //   - After owner `nextPhase()`, assert timingAnchor was moved so that
    //     epochStartTime(currentEpoch) == block.timestamp exactly. Then
    //     assert syncPhase() is a no-op until the wall clock ticks
    //     forward.

    // ══════════════════════════════════════════════════════════════════
    // I5. Freeze atomicity — EpochSnapshot[e] is frozen exactly once, at
    //     the transition that opens COMMIT[e]. After freeze, the snapshot
    //     is immutable under further state mutation.
    // ══════════════════════════════════════════════════════════════════

    function test_I5_snapshotFrozenAtAuctionOpen() public {
        // Before syncPhase opens the auction, snapshot for epoch 1 should
        // have zero treasuryBalance (not yet populated).
        TheHumanFund.EpochSnapshot memory preSnap = fund.getEpochSnapshot(1);
        assertEq(preSnap.balance, 0, "I5: snapshot empty before auction open");

        fund.syncPhase(); // opens epoch 1 COMMIT → freezes snapshot

        TheHumanFund.EpochSnapshot memory postSnap = fund.getEpochSnapshot(1);
        assertEq(postSnap.balance, 10 ether, "I5: snapshot frozen with treasury at open");
        assertEq(postSnap.epoch, 1, "I5: snapshot epoch matches");
    }

    function test_I5_snapshotImmutableAfterFreeze() public {
        fund.syncPhase();
        bytes32 hashAtOpen = fund.computeInputHashForEpoch(1);

        // Receive ETH → live treasury changes. Snapshot must not.
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(fund).call{value: 1 ether}("");
        require(ok, "receive");

        TheHumanFund.EpochSnapshot memory snap = fund.getEpochSnapshot(1);
        assertEq(snap.balance, 10 ether, "I5: snapshot unchanged by live mutation");
        assertEq(fund.computeInputHashForEpoch(1), hashAtOpen, "I5: input hash stable");
    }

    // ══════════════════════════════════════════════════════════════════
    // I6. Randomness capture atomicity — seed is set exactly once, at
    //     the REVEAL → EXECUTION transition, from prevrandao ^ salt
    //     accumulator.
    // ══════════════════════════════════════════════════════════════════

    function test_I6_seedSetAtRevealClose_stableAfter() public {
        fund.syncPhase();
        uint256 bond = fund.currentBond();

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));

        // Seed is zero during COMMIT/REVEAL windows.
        assertEq(am.getRandomnessSeed(1), 0, "I6: seed unset before reveal close");

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));

        assertEq(am.getRandomnessSeed(1), 0, "I6: seed unset during reveal window");

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase(); // closes reveal → captures seed

        uint256 seed = am.getRandomnessSeed(1);
        assertTrue(seed != 0, "I6: seed captured at reveal close");

        // Further syncPhase calls must not re-set the seed.
        fund.syncPhase();
        fund.syncPhase();
        assertEq(am.getRandomnessSeed(1), seed, "I6: seed stable after capture");
    }

    // ══════════════════════════════════════════════════════════════════
    // I7. Freeze scope is manual-only. FREEZE_AUCTION gates owner-only
    //     entry points (nextPhase, resetAuction, migrate), but does NOT
    //     block participants (commit/reveal/submitAuctionResult) or the
    //     time driver (syncPhase).
    // ══════════════════════════════════════════════════════════════════

    // [POST_REFACTOR] I7:
    //   - Set FREEZE_AUCTION.
    //   - Assert: fund.nextPhase() reverts with Frozen
    //   - Assert: fund.resetAuction() reverts with Frozen
    //   - Assert: runner can still call commit() (no revert)
    //   - Assert: runner can still call reveal() (no revert)
    //   - Assert: fund.syncPhase() still advances phases
    //
    // Today there is no FREEZE_AUCTION flag matching this semantic — the
    // existing FREEZE_DIRECT_MODE / FREEZE_SUNSET gates have different
    // scopes. This test is the acceptance criterion for the refactor.

    // ══════════════════════════════════════════════════════════════════
    // Derived: Driver equivalence
    //
    // Given the same (state, block.timestamp), time driver and manual
    // driver produce the same resulting (state, schedule). Core property
    // that justifies the refactor.
    // ══════════════════════════════════════════════════════════════════

    // [POST_REFACTOR] Driver equivalence:
    //   - Fork two identical contract instances.
    //   - On instance A: run N wall-clock syncPhase cycles.
    //   - On instance B: run N owner nextPhase steps with vm.warp to
    //     match each step's expected start time.
    //   - Assert: equal (currentEpoch, phase, timingAnchor, snapshots,
    //     bond states) after each step.

    // ══════════════════════════════════════════════════════════════════
    // Derived: No stuck states
    //
    // For any reachable (epoch, phase), there exists a finite sequence of
    // syncPhase calls that reaches a new epoch. Today `recover_submit.py`
    // exists because this isn't guaranteed; the refactor makes it so.
    // ══════════════════════════════════════════════════════════════════

    /// From any phase, enough wall-clock advancement + syncPhase always
    /// reaches a fresh epoch. No manual escape hatch required.
    function test_derived_noStuckStates_fromEachPhase() public {
        // Case A: stuck in IDLE/fresh
        _assertAdvancesToNewEpoch();

        // Case B: stuck mid-COMMIT (one commit, never reveals)
        fund.syncPhase();
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));
        _assertAdvancesToNewEpoch();

        // Case C: stuck mid-REVEAL (warp into reveal but don't reveal)
        fund.syncPhase();
        bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1b")));
        vm.warp(block.timestamp + COMMIT_WIN + 1);
        _assertAdvancesToNewEpoch();
    }

    function _assertAdvancesToNewEpoch() internal {
        uint256 start = fund.currentEpoch();
        // Give the state machine a full epoch duration of wall-clock and
        // enough syncPhase calls to drain whatever cleanup is pending.
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + EPOCH_DUR);
            fund.syncPhase();
        }
        assertGt(fund.currentEpoch(), start, "no stuck states: epoch eventually advances");
    }

    // ══════════════════════════════════════════════════════════════════
    // Derived: Operator non-confiscation
    //
    // No sequence of owner `nextPhase` + `resetAuction` calls can move a
    // bond from a non-forfeit state into `forfeited-to-treasury`. Manual
    // intervention must always refund.
    // ══════════════════════════════════════════════════════════════════

    // [POST_REFACTOR] Operator non-confiscation:
    //   - Commit as runner1 (bond held in AM).
    //   - Warp into REVEAL window (don't reveal).
    //   - Owner calls resetAuction() — bond must return to runner1, NOT
    //     to treasury.
    //   - Assert: runner1.balance increased by bond.
    //   - Assert: treasury.balance unchanged (mod seed).
}
