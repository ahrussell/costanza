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
/// All invariant tests are live. The `[POST_REFACTOR]` stubs from
/// the initial stubbing pass have been filled in now that `nextPhase`,
/// `resetAuction`, and `FREEZE_AUCTION_CONFIG` are implemented.
contract AuctionInvariantsTest is EpochTest {
    TheHumanFund public fund;
    AuctionManager public am;

    address runner1 = address(0x4001);
    address runner2 = address(0x4002);

    uint256 constant COMMIT_WIN = 60;
    uint256 constant REVEAL_WIN = 30;
    uint256 constant EXEC_WIN   = 210;
    uint256 constant EPOCH_DUR  = COMMIT_WIN + REVEAL_WIN + EXEC_WIN; // 300

    function setUp() public {
        fund = new TheHumanFund{value: 10 ether}(
            1000, 0.01 ether,
            address(0xBEEF), address(0xBEEF), address(0xBEEF), address(0xBEEF), address(0)
        );

        am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am), COMMIT_WIN, REVEAL_WIN, EXEC_WIN);

        vm.deal(runner1, 10 ether);
        vm.deal(runner2, 10 ether);
        _registerMockVerifier(fund);
    }

    function _commitHash(address runner, uint256 bid, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(runner, bid, salt));
    }

    // ══════════════════════════════════════════════════════════════════
    // I1. Monotonicity — (currentEpoch, phase) is strictly lex-increasing
    //     under any driver. No call reverses epoch or phase.
    // ══════════════════════════════════════════════════════════════════

    /// Under repeated wall-clock advancement, currentEpoch is non-decreasing.
    /// Covers the time driver; manual driver coverage in
    /// test_I1_manualDriver_monotonicEpochAndPhase below.
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

    /// I1 under manual driver: walking the state machine via nextPhase
    /// produces strictly lex-increasing (epoch, phase). Full cycle through
    /// forfeit: IDLE → COMMIT → REVEAL → EXECUTION → SETTLED → next-COMMIT.
    function test_I1_manualDriver_monotonicEpochAndPhase() public {
        uint256 bond = fund.currentBond();

        // IDLE → COMMIT (epoch 1)
        fund.nextPhase();
        assertEq(fund.currentEpoch(), 1);
        assertEq(uint8(am.getPhase(1)), uint8(IAuctionManager.AuctionPhase.COMMIT));

        // Commit, then COMMIT → REVEAL
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));
        fund.nextPhase();
        assertEq(uint8(am.getPhase(1)), uint8(IAuctionManager.AuctionPhase.REVEAL));

        // Reveal, then REVEAL → EXECUTION (captures seed)
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));
        fund.nextPhase();
        assertEq(uint8(am.getPhase(1)), uint8(IAuctionManager.AuctionPhase.EXECUTION));

        // EXECUTION → SETTLED (winner forfeit — no submit)
        fund.nextPhase();
        assertEq(uint8(am.getPhase(1)), uint8(IAuctionManager.AuctionPhase.SETTLED));

        // SETTLED → advance epoch + open COMMIT (epoch 2)
        fund.nextPhase();
        assertEq(fund.currentEpoch(), 2);
        assertEq(uint8(am.getPhase(2)), uint8(IAuctionManager.AuctionPhase.COMMIT));
    }

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

    /// I3 conservation: across a manual-driver forfeit cycle (nextPhase
    /// through EXECUTION without submit), total wei is conserved. The
    /// winner's bond goes to treasury (forfeit), the non-winning
    /// revealer's bond goes to pendingBondRefunds (claimable).
    function test_I3_conservation_manualDriverForfeit() public {
        fund.nextPhase(); // IDLE → COMMIT
        uint256 bond = fund.currentBond();
        uint256 treasuryBefore = address(fund).balance;

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.008 ether, bytes32("r1")));
        vm.prank(runner2);
        fund.commit{value: bond}(_commitHash(runner2, 0.005 ether, bytes32("r2")));

        fund.nextPhase(); // COMMIT → REVEAL
        vm.prank(runner1);
        fund.reveal(0.008 ether, bytes32("r1"));
        vm.prank(runner2);
        fund.reveal(0.005 ether, bytes32("r2"));

        fund.nextPhase(); // REVEAL → EXECUTION (seed captured)
        // At this point: winner=runner2 (lower bid), both revealed.
        // No non-revealers, so no forfeit at reveal close. Both bonds
        // accounted: winner-held (runner2) + pending refund (runner1).

        fund.nextPhase(); // EXECUTION → SETTLED (winner forfeit)
        // Winner (runner2) bond forfeited to treasury.
        // Non-winner (runner1) bond is claimable.

        assertEq(
            address(fund).balance,
            treasuryBefore + bond,
            "I3: treasury gained exactly one forfeited bond"
        );
        assertEq(am.pendingBondRefunds(), bond, "I3: one bond claimable");

        // runner1 claims
        uint256 r1Before = runner1.balance;
        vm.prank(runner1);
        am.claimBond(1);
        assertEq(runner1.balance, r1Before + bond, "I3: non-winner reclaimed bond");
        assertEq(am.pendingBondRefunds(), 0, "I3: all bonds accounted");
    }

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

    /// I4 under manual driver: after nextPhase opens a new auction,
    /// epochStartTime(currentEpoch) == block.timestamp exactly. After
    /// that, syncPhase is a no-op until the wall clock ticks forward.
    function test_I4_manualDriver_reanchor() public {
        fund.nextPhase(); // IDLE → COMMIT (epoch 1)
        assertEq(
            fund.epochStartTime(fund.currentEpoch()),
            block.timestamp,
            "I4: epoch start == now after open"
        );

        // Walk through a full cycle via manual driver
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));
        fund.nextPhase(); // COMMIT → REVEAL
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));
        fund.nextPhase(); // REVEAL → EXECUTION
        fund.nextPhase(); // EXECUTION → SETTLED (forfeit)
        fund.nextPhase(); // SETTLED → COMMIT (epoch 2)

        assertEq(
            fund.epochStartTime(fund.currentEpoch()),
            block.timestamp,
            "I4: re-anchored after epoch advance"
        );

        // syncPhase must be a no-op — we're at the start of the commit
        // window, so it sees the auction is already open.
        uint256 epochBefore = fund.currentEpoch();
        uint8 phaseBefore = uint8(am.getPhase(epochBefore));
        fund.syncPhase();
        assertEq(fund.currentEpoch(), epochBefore, "I4: syncPhase is noop (epoch)");
        assertEq(uint8(am.getPhase(epochBefore)), phaseBefore, "I4: syncPhase is noop (phase)");
    }

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

    /// I7: FREEZE_AUCTION_CONFIG gates manual-only entry points but
    /// does NOT block participants or the time driver.
    function test_I7_freezeAuctionConfig_manualOnlyScope() public {
        // First, open an auction so we can test participant actions.
        fund.syncPhase(); // opens epoch 1 COMMIT
        uint256 bond = fund.currentBond();

        // Freeze the manual driver.
        fund.freeze(fund.FREEZE_AUCTION_CONFIG());

        // Manual entry points are blocked.
        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.nextPhase();

        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.resetAuction(COMMIT_WIN, REVEAL_WIN, EXEC_WIN);

        // Participants can still act (commit, reveal, syncPhase).
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));

        // Time driver still advances phases.
        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase();
        assertEq(
            uint8(am.getPhase(1)),
            uint8(IAuctionManager.AuctionPhase.EXECUTION),
            "I7: syncPhase still works under freeze"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    // Derived: Driver equivalence
    //
    // Given the same (state, block.timestamp), time driver and manual
    // driver produce the same resulting (state, schedule). Core property
    // that justifies the refactor.
    // ══════════════════════════════════════════════════════════════════

    /// Driver equivalence (simplified): manual nextPhase and wall-clock
    /// syncPhase produce the same currentEpoch after a forfeit cycle.
    /// Full state comparison needs two contract instances; this test
    /// verifies the key property: epoch advancement is equivalent.
    function test_derived_driverEquivalence_epochAdvancement() public {
        // ── Manual driver path ──
        uint256 snap = vm.snapshotState();
        fund.nextPhase(); // IDLE → COMMIT
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));
        fund.nextPhase(); // COMMIT → REVEAL
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));
        fund.nextPhase(); // REVEAL → EXECUTION
        fund.nextPhase(); // EXECUTION → SETTLED (forfeit)
        fund.nextPhase(); // SETTLED → COMMIT (epoch 2)
        uint256 manualEpoch = fund.currentEpoch();
        uint256 manualMissed = fund.consecutiveMissedEpochs();
        uint256 manualBond = fund.currentBond();

        // ── Wall-clock driver path (same scenario) ──
        vm.revertToState(snap);
        fund.syncPhase(); // opens epoch 1 COMMIT
        bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));
        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));
        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase(); // REVEAL → EXECUTION
        vm.warp(block.timestamp + EXEC_WIN);
        fund.syncPhase(); // EXECUTION → SETTLED → advance → COMMIT (epoch 2)

        assertEq(fund.currentEpoch(), manualEpoch, "equivalence: epoch");
        assertEq(fund.consecutiveMissedEpochs(), manualMissed, "equivalence: missed");
        assertEq(fund.currentBond(), manualBond, "equivalence: bond");
    }

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
    // No sequence of owner `resetAuction` calls can move a bond from a
    // non-forfeit state into `forfeited-to-treasury`. Manual intervention
    // must always refund.
    // ══════════════════════════════════════════════════════════════════

    /// In COMMIT phase, resetAuction refunds the committer's bond
    /// directly (push-to-address), not to treasury. This is the
    /// primary non-confiscation property.
    function test_resetAuction_commitPhase_refundsCommitter() public {
        fund.syncPhase();
        uint256 bond = fund.currentBond();
        uint256 treasuryBefore = address(fund).balance;
        uint256 runnerBefore = runner1.balance;

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));
        // Fund balance temporarily excludes the bond (it sits in AM).
        assertEq(address(fund).balance, treasuryBefore, "treasury unchanged by commit");

        fund.resetAuction(COMMIT_WIN, REVEAL_WIN, EXEC_WIN);

        // Runner got their bond back via direct push.
        assertEq(runner1.balance, runnerBefore, "committer bond refunded");
        // Treasury unchanged — no confiscation.
        assertEq(address(fund).balance, treasuryBefore, "treasury unchanged by reset");
    }

    /// In REVEAL phase, resetAuction refunds ALL committers (both those
    /// who revealed and those who didn't) — the reveal process hasn't
    /// settled bonds yet, and operator intervention must not punish
    /// late revealers.
    function test_resetAuction_revealPhase_refundsAllCommitters() public {
        fund.syncPhase();
        uint256 bond = fund.currentBond();
        uint256 r1Before = runner1.balance;
        uint256 r2Before = runner2.balance;
        uint256 treasuryBefore = address(fund).balance;

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.008 ether, bytes32("r1")));
        vm.prank(runner2);
        fund.commit{value: bond}(_commitHash(runner2, 0.005 ether, bytes32("r2")));

        // Advance into REVEAL. runner1 reveals, runner2 doesn't.
        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.008 ether, bytes32("r1"));

        // We're in REVEAL with one revealer, one non-revealer. Owner aborts.
        fund.resetAuction(COMMIT_WIN, REVEAL_WIN, EXEC_WIN);

        // Both runners get their bonds back — even runner2 who didn't reveal.
        // Under normal flow, runner2 would have forfeited at reveal close;
        // under operator reset, they're refunded.
        assertEq(runner1.balance, r1Before, "reveal-phase revealer refunded");
        assertEq(runner2.balance, r2Before, "reveal-phase non-revealer refunded");
        assertEq(address(fund).balance, treasuryBefore, "treasury unchanged");
    }

    /// In EXECUTION phase, the winner's bond is refunded. Non-winning
    /// revealers already have their `pendingBondRefunds` credit intact
    /// and can still claim via `claimBond(epoch)`. Non-revealer bonds
    /// that were forfeited at reveal close remain in treasury — those
    /// are closed transactions that operator intervention does not
    /// retroactively unwind.
    function test_resetAuction_executionPhase_refundsWinnerOnly() public {
        fund.syncPhase();
        uint256 bond = fund.currentBond();
        uint256 r1Before = runner1.balance;
        uint256 r2Before = runner2.balance;

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.008 ether, bytes32("r1")));
        vm.prank(runner2);
        fund.commit{value: bond}(_commitHash(runner2, 0.005 ether, bytes32("r2")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.008 ether, bytes32("r1"));
        vm.prank(runner2);
        fund.reveal(0.005 ether, bytes32("r2"));

        // Warp to reveal close → AM enters EXECUTION with runner2 as winner.
        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase();

        uint256 treasuryBeforeReset = address(fund).balance;
        fund.resetAuction(COMMIT_WIN, REVEAL_WIN, EXEC_WIN);

        // runner2 (winner) refunded directly.
        assertEq(runner2.balance, r2Before, "execution-phase winner refunded");
        // runner1 (non-winning revealer) still has a claimable credit.
        assertEq(runner1.balance, r1Before - bond, "non-winner balance deducted by commit");
        // Treasury unchanged by the reset itself.
        assertEq(address(fund).balance, treasuryBeforeReset, "treasury unchanged by reset");
        // runner1 can still claim their bond.
        vm.prank(runner1);
        am.claimBond(1);
        assertEq(runner1.balance, r1Before, "non-winner can still claim post-reset");
    }

    /// resetAuction from IDLE (no active auction) is a clean no-op on
    /// the bond state — nothing to refund, but the epoch advances and
    /// the timing is re-anchored.
    function test_resetAuction_idle_noop_advancesEpoch() public {
        uint256 startEpoch = fund.currentEpoch();
        uint256 treasuryBefore = address(fund).balance;

        fund.resetAuction(COMMIT_WIN, REVEAL_WIN, EXEC_WIN);

        assertEq(fund.currentEpoch(), startEpoch + 1, "epoch advanced by 1");
        assertEq(address(fund).balance, treasuryBefore, "treasury unchanged");
        // Re-anchored: the new epoch starts now.
        assertEq(fund.epochStartTime(fund.currentEpoch()), block.timestamp, "re-anchored");
    }

    /// resetAuction does NOT increment `consecutiveMissedEpochs` —
    /// operator intervention is not a missed epoch.
    function test_resetAuction_doesNotBumpMissedCounter() public {
        fund.syncPhase();
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));

        uint256 missedBefore = fund.consecutiveMissedEpochs();
        fund.resetAuction(COMMIT_WIN, REVEAL_WIN, EXEC_WIN);
        assertEq(fund.consecutiveMissedEpochs(), missedBefore, "reset does not count as a miss");
    }

    /// After resetAuction, syncPhase opens a fresh auction for the new
    /// epoch (landing in COMMIT). Verifies the re-anchor leaves the
    /// contract in a usable state.
    function test_resetAuction_followedBySyncPhase_opensNewAuction() public {
        fund.syncPhase();
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));

        fund.resetAuction(COMMIT_WIN, REVEAL_WIN, EXEC_WIN);
        uint256 newEpoch = fund.currentEpoch();

        // syncPhase should open the new epoch's auction.
        fund.syncPhase();
        assertEq(
            uint8(am.getPhase(newEpoch)),
            uint8(IAuctionManager.AuctionPhase.COMMIT),
            "new epoch in COMMIT"
        );
    }

    /// FREEZE_AUCTION_CONFIG blocks resetAuction. This is the manual-only
    /// freeze scope from invariant I7: the flag gates owner-side auction
    /// manipulation, not participant-driven phase changes.
    function test_resetAuction_blockedByFreezeAuctionConfig() public {
        fund.freeze(fund.FREEZE_AUCTION_CONFIG());
        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.resetAuction(COMMIT_WIN, REVEAL_WIN, EXEC_WIN);
    }

    /// resetAuction is owner-only.
    function test_resetAuction_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.resetAuction(COMMIT_WIN, REVEAL_WIN, EXEC_WIN);
    }

    /// Emits AuctionReset(from, to) with the correct epoch pair.
    function test_resetAuction_emitsEvent() public {
        uint256 from = fund.currentEpoch();
        vm.expectEmit(true, true, false, false);
        emit TheHumanFund.AuctionReset(from, from + 1);
        fund.resetAuction(COMMIT_WIN, REVEAL_WIN, EXEC_WIN);
    }

    /// The whole reason `resetAuction` takes timing parameters: apply
    /// new auction timing atomically with the abort. After the reset,
    /// subsequent phase windows must reflect the new durations, and
    /// the in-flight epoch's input hash cannot diverge from what the
    /// prover would compute (the drift bug from mainnet v1 —
    /// commit bd883a9).
    function test_resetAuction_changesAuctionTiming() public {
        fund.syncPhase();
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));

        // Change timing: different phase splits.
        // (epochDuration is derived as the sum — 800 here.)
        uint256 newCommitWin = 200;
        uint256 newRevealWin = 100;
        uint256 newExecWin   = 500;
        fund.resetAuction(newCommitWin, newRevealWin, newExecWin);

        // New timing is live on the AM.
        assertEq(am.commitWindow(), newCommitWin, "new commit window applied");
        assertEq(am.revealWindow(), newRevealWin, "new reveal window applied");
        assertEq(am.executionWindow(), newExecWin, "new exec window applied");

        // Next syncPhase should open a fresh auction using the new windows.
        fund.syncPhase();
        uint256 newEpoch = fund.currentEpoch();
        assertEq(
            uint8(am.getPhase(newEpoch)),
            uint8(IAuctionManager.AuctionPhase.COMMIT),
            "new auction opened in COMMIT"
        );

        // The new epoch's commit window ends at start + newCommitWin.
        // Warp almost to the end — should still be in COMMIT.
        vm.warp(block.timestamp + newCommitWin - 1);
        vm.prank(runner1);
        fund.commit{value: fund.currentBond()}(_commitHash(runner1, 0.004 ether, bytes32("r2")));

        // Warp past the new commit window — should transition on next sync.
        vm.warp(block.timestamp + 2);
        fund.syncPhase();
        assertEq(
            uint8(am.getPhase(newEpoch)),
            uint8(IAuctionManager.AuctionPhase.REVEAL),
            "new commit window boundary respected"
        );
    }

    /// resetAuction rejects zero-duration phases.
    function test_resetAuction_rejectsInvalidTiming() public {
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.resetAuction(0, 100, 100); // zero commit window
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.resetAuction(100, 0, 100); // zero reveal window
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.resetAuction(100, 100, 0); // zero execution window
    }

    // ══════════════════════════════════════════════════════════════════
    // Multi-epoch fast-forward — O(1) preservation
    //
    // The contract must handle "untouched for days" gracefully. When
    // many epochs elapse with no interaction, syncPhase should:
    //   - Run the in-flight auction through its real cleanup (if any)
    //   - Arithmetic-advance through empty epochs in O(1)
    //   - Land in the wall-clock target epoch's COMMIT with correct
    //     bookkeeping (consecutiveMissedEpochs, effectiveMaxBid, bond
    //     escalation, message queue preserved)
    //
    // These tests run against the CURRENT contract and lock in the
    // existing O(1) arithmetic-advance behavior (see commits 74dfdfd
    // and 990f944). Any refactor regression shows up here immediately.
    // ══════════════════════════════════════════════════════════════════

    /// Warp 10 epochs forward with an auction open but no commits. Exactly
    /// one syncPhase call should land in epoch 11's COMMIT with escalated
    /// bond/bid values. The "missed" semantics require that an auction was
    /// open at the start of the silence — that's what distinguishes a
    /// real-world prover outage from a fresh-deploy state.
    function test_ff_longSilence_noActivity() public {
        fund.syncPhase(); // opens epoch 1 auction

        // Jump 10 full epochs into the future without any interaction.
        vm.warp(fund.epochStartTime(11) + 1);
        fund.syncPhase();

        assertEq(fund.currentEpoch(), 11, "ff: landed at epoch 11");
        // Epoch 1 had an open auction that was never completed, and epochs
        // 2..10 were fully skipped — 10 missed epochs total.
        assertEq(fund.consecutiveMissedEpochs(), 10, "ff: missed counter");
    }

    /// A committer who never reveals + long silence: exactly ONE bond
    /// forfeited, not 10. The forfeit happens on the in-flight epoch
    /// (epoch 1 here) via _closeReveal's no-reveals branch.
    function test_ff_commitNoReveal_thenSilence() public {
        fund.syncPhase(); // open epoch 1 COMMIT
        uint256 bond = fund.currentBond();
        uint256 treasuryBefore = address(fund).balance;

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));

        // Jump 10 full epochs forward.
        vm.warp(fund.epochStartTime(11) + 1);
        fund.syncPhase();

        // Treasury gained exactly ONE bond (the one committed, forfeited
        // for non-reveal). Not 10.
        assertEq(address(fund).balance, treasuryBefore + bond, "ff: one forfeit, not many");
        // Epochs 1..10 all count as missed.
        assertEq(fund.consecutiveMissedEpochs(), 10, "ff: missed counter after forfeit");
        assertEq(fund.currentEpoch(), 11, "ff: landed at epoch 11");
    }

    /// After a successful execution, wall-clock silence re-accumulates
    /// the missed counter. Only the silent epochs count — the successful
    /// epoch itself is not a miss.
    function test_ff_successfulEpoch_thenSilence() public {
        // Direct mode executes epoch 1 and advances currentEpoch to 2.
        // (Direct mode is removed in commit 7; when it goes, swap this
        // for a real commit/reveal/submit flow via the mock verifier.)
        speedrunEpoch(fund, abi.encodePacked(uint8(0)), "executed");
        assertEq(fund.consecutiveMissedEpochs(), 0, "reset after success");
        assertEq(fund.currentEpoch(), 2, "advanced past executed epoch 1");

        // Warp to the start of epoch 11 (9 full silent epochs between
        // epoch 2 and epoch 11).
        vm.warp(fund.epochStartTime(11) + 1);
        fund.syncPhase();

        // Epochs 2..10 were all silent → 9 misses.
        assertEq(fund.consecutiveMissedEpochs(), 9, "9 silent epochs credited");
        assertEq(fund.currentEpoch(), 11, "landed at epoch 11");
    }

    /// Pristine-IDLE long silence (fresh deploy, nobody has called
    /// anything): every elapsed epoch counts as a miss. This was
    /// previously broken — the original logic explicitly skipped
    /// pristine-IDLE escalation, which meant a fresh deploy with no
    /// prover activity would never raise the bid cap, forever.
    function test_ff_pristineIdle_longSilence_credits() public {
        // No setup beyond the test's setUp(). Contract was just deployed.
        assertEq(fund.currentEpoch(), 1, "fresh deploy at epoch 1");
        assertEq(fund.consecutiveMissedEpochs(), 0, "counter starts at 0");

        vm.warp(fund.epochStartTime(11) + 1);
        fund.syncPhase();

        // All 10 elapsed epochs were silent → all 10 count as misses.
        // The bid cap should be escalated so any prover that shows up
        // later has headroom to win.
        assertEq(fund.currentEpoch(), 11, "landed at epoch 11");
        assertEq(fund.consecutiveMissedEpochs(), 10, "pristine silence counts");
    }

    /// Messages queued before silence must survive and be visible in the
    /// landing epoch's snapshot. messageHead must NOT advance during
    /// silence (no action executed = no messages consumed).
    function test_ff_messagesPreservedAcrossSilence() public {
        // Queue 3 messages in epoch 1 BEFORE any executed epoch, so
        // they land in the queue with epoch=1 tagging.
        vm.deal(address(0xAA), 1 ether);
        vm.prank(address(0xAA));
        fund.donateWithMessage{value: 0.01 ether}(0, "msg 1");
        vm.prank(address(0xAA));
        fund.donateWithMessage{value: 0.01 ether}(0, "msg 2");
        vm.prank(address(0xAA));
        fund.donateWithMessage{value: 0.01 ether}(0, "msg 3");

        assertEq(fund.messageCount(), 3, "3 messages queued");
        assertEq(fund.messageHead(), 0, "head at 0");

        // Silence for 10 epochs.
        vm.warp(fund.epochStartTime(11) + 1);
        fund.syncPhase();

        // Head NEVER advanced — no action executed during silence.
        assertEq(fund.messageHead(), 0, "ff: messageHead preserved");
        assertEq(fund.messageCount(), 3, "ff: messageCount preserved");

        // All 3 messages visible in the landing epoch's snapshot.
        TheHumanFund.EpochSnapshot memory snap = fund.getEpochSnapshot(fund.currentEpoch());
        // messageCount in snapshot = live count at freeze time. Head and
        // count frozen; the window is [head, count).
        assertEq(snap.messageHead, 0, "ff: snapshot head");
        assertEq(snap.messageCount, 3, "ff: snapshot sees all 3");
    }

    /// Messages can arrive DURING silence (donateWithMessage doesn't
    /// advance the state machine). All must be preserved.
    function test_ff_messagesQueuedDuringSilence() public {
        fund.syncPhase(); // open epoch 1

        // Warp partway, then queue messages.
        vm.warp(fund.epochStartTime(5) + 1);
        vm.deal(address(0xAA), 1 ether);
        vm.prank(address(0xAA));
        fund.donateWithMessage{value: 0.01 ether}(0, "mid-silence 1");
        vm.prank(address(0xAA));
        fund.donateWithMessage{value: 0.01 ether}(0, "mid-silence 2");

        // Warp further, then syncPhase to land.
        vm.warp(fund.epochStartTime(10) + 1);
        fund.syncPhase();

        assertEq(fund.messageCount(), 2, "ff: mid-silence messages preserved");
        assertEq(fund.messageHead(), 0, "ff: head still at 0");
    }

    /// The landing epoch's snapshot must reflect the escalated values,
    /// not the pre-silence values. This is the I5 invariant applied to
    /// the fast-forward path: whatever is frozen MUST match what
    /// `currentBond()` and `effectiveMaxBid()` would return for the
    /// landing state.
    function test_ff_snapshotReflectsEscalation() public {
        fund.syncPhase(); // open epoch 1 auction

        vm.warp(fund.epochStartTime(6) + 1);
        fund.syncPhase();

        TheHumanFund.EpochSnapshot memory snap = fund.getEpochSnapshot(fund.currentEpoch());
        assertEq(snap.consecutiveMissedEpochs, 5, "ff: snap missed count");
        assertEq(snap.effectiveMaxBid, fund.effectiveMaxBid(), "ff: snap effectiveMaxBid matches live");
    }

    /// Pure silence does NOT escalate the bond. Bond only moves on
    /// winner-forfeit events. This is the key property that keeps the
    /// auction attractive for new bidders after a drought.
    function test_ff_bondDoesNotEscalateOnSilence() public {
        fund.syncPhase(); // open epoch 1 auction
        uint256 bondBefore = fund.currentBond();

        // Long silence — 5 epochs with no commits, no reveals, nothing.
        vm.warp(fund.epochStartTime(6) + 1);
        fund.syncPhase();

        // Bond unchanged. Max bid escalated (via consecutiveMissedEpochs),
        // but bond stays at base to welcome the next bidder.
        assertEq(fund.currentBond(), bondBefore, "ff: bond unchanged after silence");
        assertGt(fund.effectiveMaxBid(), fund.maxBid(), "ff: max bid did escalate");
    }

    /// O(1) gas property: syncPhase gas usage should be roughly constant
    /// regardless of how many empty epochs are being fast-forwarded.
    /// This is the regression canary — if someone replaces the arithmetic
    /// advance with a loop, this test fires immediately.
    ///
    /// We measure gas for N=1 missed vs N=20 missed. If the advance is
    /// truly O(1), the gas delta should be a small constant (< 10k gas
    /// difference). If it's O(N), the delta would be tens of thousands.
    function test_ff_syncPhaseGas_boundedInN() public {
        uint256 snapId = vm.snapshotState();

        // Baseline: open auction + 1 missed epoch.
        fund.syncPhase();
        vm.warp(fund.epochStartTime(2) + 1);
        uint256 g1 = gasleft();
        fund.syncPhase();
        uint256 gasN1 = g1 - gasleft();

        vm.revertToState(snapId);

        // Longer: open auction + 20 missed epochs.
        fund.syncPhase();
        vm.warp(fund.epochStartTime(21) + 1);
        uint256 g20 = gasleft();
        fund.syncPhase();
        uint256 gasN20 = g20 - gasleft();

        // The delta should be bounded — if it weren't, someone has
        // introduced per-missed-epoch work in the fast-forward path.
        // A 2x slack gives room for effectiveMaxBid's bounded loop
        // (over min(N, MAX_MISSED_EPOCHS)) without permitting a true
        // O(N) regression.
        // As of the current contract: gasN1 ≈ 416k, gasN20 ≈ 451k (8%
        // delta for 20x more missed epochs). The delta comes from
        // effectiveMaxBid's bounded escalation loop, not the fast-forward
        // advance itself.
        assertLt(gasN20, gasN1 * 2, "ff: syncPhase gas must not scale linearly in N");
    }

    // test_ff_commitNoReveal_thenSilence above already asserts "exactly
    // one forfeit" via treasury delta. No separate test needed.

    // ══════════════════════════════════════════════════════════════════
    // nextPhase — edge cases and auth
    // ══════════════════════════════════════════════════════════════════

    function test_nextPhase_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.nextPhase();
    }

    /// nextPhase with 0 commits: COMMIT → SETTLED (no-commit drain),
    /// then next nextPhase opens epoch 2 and credits the miss.
    function test_nextPhase_commitToSettled_noCommits() public {
        fund.nextPhase(); // IDLE → COMMIT
        fund.nextPhase(); // COMMIT → SETTLED (0 commits)
        assertEq(uint8(am.getPhase(1)), uint8(IAuctionManager.AuctionPhase.SETTLED));

        fund.nextPhase(); // SETTLED → COMMIT (epoch 2)
        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.consecutiveMissedEpochs(), 1, "one missed epoch credited");
    }

    /// nextPhase with commits but no reveals: REVEAL → SETTLED, bonds
    /// forfeited. Same as wall-clock driver would do.
    function test_nextPhase_revealToSettled_noReveals() public {
        fund.nextPhase(); // IDLE → COMMIT
        uint256 bond = fund.currentBond();
        uint256 treasuryBefore = address(fund).balance;

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));

        fund.nextPhase(); // COMMIT → REVEAL
        fund.nextPhase(); // REVEAL → SETTLED (no reveals, bonds forfeited)

        assertEq(
            address(fund).balance,
            treasuryBefore + bond,
            "non-revealer bond forfeited to treasury"
        );
    }

    /// Bond escalation via manual driver: EXECUTION forfeit escalates
    /// currentBond, same as wall-clock path.
    function test_nextPhase_executionForfeit_escalatesBond() public {
        fund.nextPhase(); // IDLE → COMMIT
        uint256 bond = fund.currentBond();

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));
        fund.nextPhase(); // COMMIT → REVEAL
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));
        fund.nextPhase(); // REVEAL → EXECUTION

        uint256 bondBefore = fund.currentBond();
        fund.nextPhase(); // EXECUTION → SETTLED (winner forfeit)

        // Bond escalated by AUTO_ESCALATION_BPS (1000 = 10%)
        uint256 expected = bondBefore + (bondBefore * 1000) / 10000;
        assertEq(fund.currentBond(), expected, "bond escalated on forfeit");
    }

    // ══════════════════════════════════════════════════════════════════
    // Mixed driver — the truly diabolical tests. Manual nextPhase and
    // wall-clock syncPhase interleaved in the same epoch. The contract
    // must stay consistent regardless of which driver fires when.
    // ══════════════════════════════════════════════════════════════════

    /// Manual open, then wall-clock takes over for the rest of the
    /// auction. The auction opened by nextPhase must be drainable by
    /// syncPhase when wall-clock catches up.
    function test_mixed_manualOpen_wallClockDrain() public {
        fund.nextPhase(); // manual: IDLE → COMMIT
        uint256 bond = fund.currentBond();

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));

        // Wall-clock catches up: warp past commit window
        vm.warp(block.timestamp + COMMIT_WIN);
        fund.syncPhase(); // wall-clock: COMMIT → REVEAL
        assertEq(uint8(am.getPhase(1)), uint8(IAuctionManager.AuctionPhase.REVEAL));

        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));

        // Wall-clock continues
        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase(); // REVEAL → EXECUTION
        assertEq(uint8(am.getPhase(1)), uint8(IAuctionManager.AuctionPhase.EXECUTION));

        vm.warp(block.timestamp + EXEC_WIN);
        fund.syncPhase(); // EXECUTION → SETTLED → advance → COMMIT (epoch 2)
        assertEq(fund.currentEpoch(), 2);
    }

    /// Wall-clock opens the auction, manual driver closes phases in
    /// the middle. syncPhase must be a no-op after each nextPhase
    /// since the manual driver already advanced.
    function test_mixed_wallClockOpen_manualClose() public {
        fund.syncPhase(); // wall-clock: opens epoch 1 COMMIT
        uint256 bond = fund.currentBond();

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));

        // Manual close of COMMIT (no wall-clock advancement)
        fund.nextPhase(); // COMMIT → REVEAL
        assertEq(uint8(am.getPhase(1)), uint8(IAuctionManager.AuctionPhase.REVEAL));

        // syncPhase must be a no-op — we haven't reached the reveal
        // deadline on the AM's internal clock.
        fund.syncPhase();
        assertEq(uint8(am.getPhase(1)), uint8(IAuctionManager.AuctionPhase.REVEAL),
            "syncPhase noop: reveal deadline not reached");

        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));
        fund.nextPhase(); // REVEAL → EXECUTION

        // syncPhase again should be a no-op
        fund.syncPhase();
        assertEq(uint8(am.getPhase(1)), uint8(IAuctionManager.AuctionPhase.EXECUTION),
            "syncPhase noop: execution deadline not reached");
    }

    /// Manual open + commit + manual close commit, then wall-clock
    /// warp past the FULL epoch. syncPhase must handle the auction
    /// that was manually advanced to REVEAL but whose reveal window
    /// expired on the wall-clock.
    function test_mixed_manualPartial_wallClockFinishesEpoch() public {
        fund.nextPhase(); // manual: IDLE → COMMIT

        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));

        fund.nextPhase(); // manual: COMMIT → REVEAL
        // Runner doesn't reveal. Warp past the entire epoch.
        vm.warp(block.timestamp + EPOCH_DUR * 2);
        fund.syncPhase();

        // The auction was in REVEAL with no reveals → SETTLED (forfeit
        // all non-revealer bonds). Then epoch advance + open.
        assertGt(fund.currentEpoch(), 1, "advanced past stuck epoch");
    }

    /// Interleave: open via manual, warp just past commit, syncPhase
    /// closes commit (wall-clock), then manual nextPhase closes reveal.
    /// Verifies both drivers can contribute to the same epoch.
    function test_mixed_alternatingDrivers_sameEpoch() public {
        fund.nextPhase(); // manual: IDLE → COMMIT
        uint256 bond = fund.currentBond();

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));

        // Wall-clock closes commit
        vm.warp(block.timestamp + COMMIT_WIN);
        fund.syncPhase(); // wall-clock: COMMIT → REVEAL

        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));

        // Manual closes reveal
        fund.nextPhase(); // manual: REVEAL → EXECUTION

        // Verify seed was captured (the critical side effect)
        assertTrue(am.getRandomnessSeed(1) != 0, "seed captured via mixed drivers");
        assertTrue(fund.epochInputHashes(1) != bytes32(0), "input hash bound");
    }

    /// Seed captured at REVEAL → EXECUTION via manual driver, same as
    /// wall-clock. Input hash bound at the same transition.
    function test_nextPhase_seedCapturedAtRevealClose() public {
        fund.nextPhase(); // IDLE → COMMIT
        uint256 bond = fund.currentBond();

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));
        fund.nextPhase(); // COMMIT → REVEAL

        assertEq(am.getRandomnessSeed(1), 0, "seed unset before reveal close");
        assertEq(fund.epochInputHashes(1), bytes32(0), "input hash unbound");

        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));
        fund.nextPhase(); // REVEAL → EXECUTION

        assertTrue(am.getRandomnessSeed(1) != 0, "seed captured at reveal close");
        assertTrue(fund.epochInputHashes(1) != bytes32(0), "input hash bound");
    }
}
