// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
import "../src/interfaces/IAuctionManager.sol";
import "./helpers/EpochTest.sol";

/// @title Behavioral Invariants — The Human Fund + AuctionManager
///
/// Spec-in-code. Each test pins down a property the contracts must
/// satisfy. Organized into 8 concern-groups:
///
///   1. Epoch lifecycle
///   2. Timing & schedule
///   3. Auction mechanics
///   4. Snapshot & messages
///   5. Input-hash & attestation chain
///   6. Bonds
///   7. Drivers & permissions
///   8. Safety & kill-switches
///
/// ─── META-INVARIANT ──────────────────────────────────────────────────
///
/// The fund always holds EXACTLY ONE in-flight auction, with phase ∈
/// {COMMIT, REVEAL, EXECUTION}, except:
///   (a) during the atomic EXECUTION→COMMIT(next epoch) transition
///       inside a single transaction (externally unobservable), and
///   (b) while FREEZE_SUNSET is set (migration draining window).
///
/// There is no IDLE or SETTLED phase. Epochs are considered "done" when
/// the fund marks `epochs[e].executed=true` (successful submission) or
/// when `_closeExecution` forfeits the winner's bond and advances to
/// `currentEpoch += 1` — both of which are internal state, separate
/// from the AM's phase enum.
///
/// ─── BEHAVIORAL SPEC ─────────────────────────────────────────────────
///
/// 1. EPOCH LIFECYCLE
///    - Phases cycle per epoch: COMMIT → REVEAL → EXECUTION → COMMIT(N+1)
///    - `currentEpoch` is monotonically non-decreasing (I1)
///    - Every opened epoch traverses all three phases unless `_resetAuction` aborts it
///    - `_resetAuction` advances currentEpoch by exactly 1 and re-anchors timing
///
/// 2. TIMING & SCHEDULE
///    - Schedule coherence (I4): `epochStartTime(currentEpoch) ≤ block.timestamp`
///    - Timing anchor changes only at: (a) `setAuctionManager`, (b) `nextPhase`
///      crossing EXECUTION→COMMIT, (c) `_resetAuction`. Wall-clock rollovers
///      preserve the anchor — the schedule is fixed at anchor time
///    - `epochDuration = cw + rw + xw` (derived, never drifts)
///    - Auction timing windows change only via `_resetAuction`
///    - Commits, reveals, submissions each allowed iff phase matches AND
///      `block.timestamp` is strictly within that phase's wall-clock window
///
/// 3. AUCTION MECHANICS
///    - Commit requires phase=COMMIT, `msg.value >= currentBond`, no prior
///      commit by this address in this epoch, and the committers-list has
///      room (≤ MAX_COMMITTERS)
///    - Reveal requires phase=REVEAL, a prior commit by this address whose
///      preimage is `keccak(runner || bid || salt)`
///    - At most one winner per epoch: lowest revealed bid; ties broken by
///      first revealer
///    - Only the winner can call `submitAuctionResult` during EXECUTION
///    - `epochs[e].executed == true` iff the winner W submitted a proof
///      that `TdxVerifier.verify` accepted during epoch e's EXECUTION window
///
/// 4. SNAPSHOT & MESSAGES
///    - Snapshot frozen exactly when (and if) `_openAuction` fires for
///      that epoch (I5). Skipped/ghost epochs never freeze
///    - Snapshot is immutable after freeze — mid-epoch state changes
///      (donations, messages, investments) don't affect the frozen copy
///    - Messages sent during epoch N (any phase) first appear in the
///      earliest subsequent epoch whose `_openAuction` fires
///    - Each message is consumed at most once: in the first successful
///      epoch where the head pointer crosses its position
///    - Per-successful-epoch consumption cap: `MAX_MESSAGES_PER_EPOCH` (3)
///
/// 5. INPUT-HASH & ATTESTATION CHAIN
///    - `epochBaseInputHashes[e]` bound exactly at `_openAuction` (snapshot-derived)
///    - Seed captured exactly once at REVEAL close: `prevrandao ^ saltAccumulator` (I6)
///    - `epochInputHashes[e] = keccak(base ⊕ seed)` bound exactly at REVEAL close
///    - REPORTDATA bound at submission: `keccak(epochInputHashes[e] || outputHash)`
///
/// 6. BONDS
///    - Bond conservation (I3): `pendingBondRefunds + in-flight-bond-held` =
///      total bonds held by AM. No double-count, no drop
///    - Committed bonds exit via exactly one of:
///        - `claimBond` by a non-winning revealer (after reveal close)
///        - push to winner in `settleExecution` (successful submit)
///        - forfeit to fund at reveal close (non-revealer)
///        - forfeit to fund at EXECUTION→COMMIT (winner no-show)
///        - refund in `abortAuction` (operator reset / migrate)
///    - Bond escalation: `currentBond *= (1 + AUTO_ESCALATION_BPS/10000)` (capped)
///      fires ONLY when a real winner forfeits. Not on silence, success, or reset
///    - `consecutiveMissedEpochs`: resets on successful execute; increments on
///      silence/forfeit/ghost skip; untouched by `_resetAuction`
///
/// 7. DRIVERS & PERMISSIONS
///    - Participant-facing methods call `_advanceToNow()` first:
///      `commit`, `reveal`, `submitAuctionResult`, `syncPhase`
///    - Owner drivers (`nextPhase`, `resetAuction`) ALSO call `_advanceToNow()`
///      first — "sync-first" rule — so manual drivers can't time-travel backward
///    - Driver equivalence: manual (`nextPhase`) and wall-clock (`syncPhase`)
///      converge to the same state under the same scenario
///    - Permissionless: `syncPhase`, `claimBond`, `donate*`, `donateWithMessage`
///    - Owner-only: `resetAuction`, `migrate`, `setAuctionManager`, `nextPhase`,
///      freeze flags, verifier registration, investment-manager wiring
///
/// 8. SAFETY & KILL-SWITCHES
///    - Non-reentrancy on `submitAuctionResult`, `claimBond`, `abortAuction`
///    - `submitAuctionResult` NEVER reverts on a valid proof, regardless of
///      whether the action parses, validates, or executes successfully.
///      The winner receives bounty + bond-back as long as the proof verifies;
///      invalid actions emit `ActionRejected`, invalid policy sidecars fail
///      silently. This is load-bearing for liveness — a malicious enclave
///      output can't DoS the payment path
///    - FREEZE_SUNSET: blocks new-auction opens and donations; `migrate` drains
///      via `_resetAuction` and withdraws; FREEZE_MIGRATE is terminal
///    - Other freezes: AUCTION_CONFIG, INVESTMENT_WIRING, WORLDVIEW_WIRING,
///      NONPROFITS — each permanently disables a specific setter once set
///
/// ─── TEST ORGANIZATION ──────────────────────────────────────────────
///
/// Tests are grouped by concern, matching the 8 sections above. Property
/// tests use the I1–I7 prefix for the numbered invariants; mechanical
/// single-path tests use descriptive names.
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
            address(0xBEEF), address(0)
        );

        am = new AuctionManager(address(fund));
        // setAuctionManager eagerly opens epoch 1's COMMIT auction at the
        // end, so after this call: currentEpoch == 1, phase == COMMIT.
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

    /// I1 under manual driver: walking the 3-phase cycle via nextPhase
    /// produces strictly lex-increasing (epoch, phase). Cycle is
    /// COMMIT → REVEAL → EXECUTION → COMMIT(next epoch).
    function test_I1_manualDriver_monotonicEpochAndPhase() public {
        uint256 bond = fund.currentBond();

        // Epoch 1 is already open in COMMIT (setAuctionManager opened it).
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

        // EXECUTION → COMMIT (epoch 2) — winner forfeit happens as a
        // side effect of this transition (no executed submit).
        fund.nextPhase();
        assertEq(fund.currentEpoch(), 2);
        assertEq(uint8(am.getPhase(2)), uint8(IAuctionManager.AuctionPhase.COMMIT));

        // And the cycle continues: epoch 2's COMMIT → REVEAL
        fund.nextPhase();
        assertEq(uint8(am.getPhase(2)), uint8(IAuctionManager.AuctionPhase.REVEAL));
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
    /// through EXECUTION → COMMIT(next) without submit), total wei is
    /// conserved. The winner's bond goes to treasury (forfeit on the
    /// EXECUTION → COMMIT(next) transition), the non-winning revealer's
    /// bond goes to pendingBondRefunds (claimable).
    function test_I3_conservation_manualDriverForfeit() public {
        // Epoch 1 COMMIT is already open (from setUp).
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

        fund.nextPhase(); // EXECUTION → COMMIT(epoch 2) with winner forfeit side-effect
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

    /// I4 under manual driver: after the EXECUTION → COMMIT(next) transition
    /// opens a new auction, epochStartTime(currentEpoch) == block.timestamp
    /// exactly (re-anchored). After that, syncPhase is a no-op until the
    /// wall clock ticks forward.
    function test_I4_manualDriver_reanchor() public {
        // Epoch 1 COMMIT already open from setUp; epochStartTime(1) == now.
        assertEq(
            fund.epochStartTime(fund.currentEpoch()),
            block.timestamp,
            "I4: epoch 1 start == now after setUp open"
        );

        // Walk through a full cycle via manual driver
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));
        fund.nextPhase(); // COMMIT → REVEAL
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));
        fund.nextPhase(); // REVEAL → EXECUTION
        fund.nextPhase(); // EXECUTION → COMMIT (epoch 2) with forfeit

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
    // SYNC-FIRST — owner drivers catch up to wall-clock before acting.
    //
    // The manual driver must not let the contract "time-travel backward":
    // if wall-clock says we should be in epoch N+K phase P, calling
    // `nextPhase` or `resetAuction` from a stale epoch N state must first
    // catch up (via _advanceToNow) and THEN perform its one-step action.
    // Otherwise, the contract falls further behind the schedule each time
    // a manual driver is invoked under stale state.
    // ══════════════════════════════════════════════════════════════════

    /// Starting in epoch 1 COMMIT, warp 3 full epoch durations forward.
    /// Wall-clock says we should be in epoch 4's COMMIT phase. Calling
    /// `nextPhase` must FIRST sync to wall-clock (→ epoch 4 COMMIT), then
    /// advance exactly one state-machine step (→ epoch 4 REVEAL).
    /// Without sync-first, we'd incorrectly land in epoch 1 REVEAL.
    function test_syncFirst_nextPhase_catchesUpFromStaleEpoch() public {
        assertEq(fund.currentEpoch(), 1, "pre: epoch 1");
        vm.warp(block.timestamp + 3 * EPOCH_DUR);

        fund.nextPhase();

        assertGe(fund.currentEpoch(), 4,
            "nextPhase must sync to wall-clock first (expected epoch >= 4)");
    }

    /// Same scenario, but for `resetAuction`. Starting in epoch 1 with 3
    /// epoch durations elapsed, resetAuction must first catch up to the
    /// wall-clock-correct epoch (4), then abort and advance to epoch 5.
    /// Without sync-first, it would abort the stale epoch 1 and advance
    /// only to epoch 2 — leaving the contract 3 epochs behind wall-clock.
    function test_syncFirst_resetAuction_catchesUpFromStaleEpoch() public {
        assertEq(fund.currentEpoch(), 1, "pre: epoch 1");
        vm.warp(block.timestamp + 3 * EPOCH_DUR);

        fund.resetAuction(COMMIT_WIN, REVEAL_WIN, EXEC_WIN);

        // After sync-then-reset: sync should have taken us to epoch 4
        // (COMMIT of wall-clock), then reset aborts and advances to 5.
        assertGe(fund.currentEpoch(), 5,
            "resetAuction must sync to wall-clock first (expected epoch >= 5)");
    }

    // ══════════════════════════════════════════════════════════════════
    // I5. Freeze atomicity — EpochSnapshot[e] is frozen exactly once, at
    //     the transition that opens COMMIT[e]. For e=1 that transition is
    //     `setAuctionManager` (bootstrap); for e>1 it's the
    //     EXECUTION[e-1] → COMMIT[e] transition in _openAuction.
    //     After freeze, the snapshot is immutable under further state
    //     mutation.
    // ══════════════════════════════════════════════════════════════════

    function test_I5_snapshotFrozenAtAuctionOpen() public {
        // Epoch 1 was opened at setUp time (via setAuctionManager's eager
        // _openAuction). Snapshot should be frozen with the
        // treasury balance at that instant.
        TheHumanFund.EpochSnapshot memory snap1 = fund.getEpochSnapshot(1);
        assertEq(snap1.balance, 10 ether, "I5: epoch 1 snapshot frozen at setAuctionManager");
        assertEq(snap1.epoch, 1, "I5: snapshot epoch matches");

        // Before epoch 2 opens, its snapshot should be empty.
        TheHumanFund.EpochSnapshot memory preSnap2 = fund.getEpochSnapshot(2);
        assertEq(preSnap2.balance, 0, "I5: epoch 2 snapshot empty before open");

        // Drive through to EXECUTION → COMMIT(epoch 2); this is the
        // steady-state freeze path.
        fund.nextPhase(); // COMMIT → REVEAL (epoch 1)
        fund.nextPhase(); // REVEAL → EXECUTION (epoch 1, no reveals so no seed capture issues)
        // With no commits, the EXECUTION→COMMIT(2) still opens epoch 2's
        // auction and freezes its snapshot.
        fund.nextPhase(); // EXECUTION → COMMIT (epoch 2)

        TheHumanFund.EpochSnapshot memory snap2 = fund.getEpochSnapshot(2);
        assertEq(snap2.epoch, 2, "I5: epoch 2 snapshot frozen on steady-state open");
        assertGt(snap2.balance, 0, "I5: epoch 2 snapshot has balance");
    }

    function test_I5_snapshotImmutableAfterFreeze() public {
        // Epoch 1 snapshot already frozen via setUp's setAuctionManager.
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
        // Epoch 1 COMMIT already open from setUp.
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
        // Epoch 1 COMMIT already open.
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));
        fund.nextPhase(); // COMMIT → REVEAL
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));
        fund.nextPhase(); // REVEAL → EXECUTION
        fund.nextPhase(); // EXECUTION → COMMIT (epoch 2) with forfeit
        uint256 manualEpoch = fund.currentEpoch();
        uint256 manualMissed = fund.consecutiveMissedEpochs();
        uint256 manualBond = fund.currentBond();

        // ── Wall-clock driver path (same scenario) ──
        vm.revertToState(snap);
        // Epoch 1 already open; no syncPhase needed to open it.
        bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));
        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));
        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase(); // REVEAL → EXECUTION
        vm.warp(block.timestamp + EXEC_WIN);
        fund.syncPhase(); // EXECUTION → COMMIT (epoch 2)

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
        // Case A: fresh (epoch 1 COMMIT, no commits)
        _assertAdvancesToNewEpoch();

        // Case B: stuck mid-COMMIT (one commit, never reveals)
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));
        _assertAdvancesToNewEpoch();

        // Case C: stuck mid-REVEAL (warp into reveal but don't reveal)
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

    /// resetAuction does NOT increment `consecutiveMissedEpochs` —
    /// operator intervention is not a missed epoch.
    function test_resetAuction_doesNotBumpMissedCounter() public {
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
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));

        fund.resetAuction(COMMIT_WIN, REVEAL_WIN, EXEC_WIN);
        uint256 newEpoch = fund.currentEpoch();

        // syncPhase should leave the new epoch in COMMIT (or resetAuction
        // already opened it).
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

        // Fresh auction should be in COMMIT using the new windows.
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
    /// bond/bid values.
    function test_ff_longSilence_noActivity() public {
        // Epoch 1 already open from setUp.

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
    /// (epoch 1 here) via the reveal-close no-reveals branch.
    function test_ff_commitNoReveal_thenSilence() public {
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
        // Epoch 1 already open from setUp.

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
        // Epoch 1 already open from setUp.

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
        // Epoch 1 already open from setUp.
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

        // Baseline: epoch 1 already open + 1 missed epoch.
        vm.warp(fund.epochStartTime(2) + 1);
        uint256 g1 = gasleft();
        fund.syncPhase();
        uint256 gasN1 = g1 - gasleft();

        vm.revertToState(snapId);

        // Longer: epoch 1 already open + 20 missed epochs.
        vm.warp(fund.epochStartTime(21) + 1);
        uint256 g20 = gasleft();
        fund.syncPhase();
        uint256 gasN20 = g20 - gasleft();

        // The delta should be bounded — if it weren't, someone has
        // introduced per-missed-epoch work in the fast-forward path.
        // A 2x slack gives room for effectiveMaxBid's bounded loop
        // (over min(N, MAX_MISSED_EPOCHS)) without permitting a true
        // O(N) regression.
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

    /// nextPhase with 0 commits walks COMMIT → REVEAL → EXECUTION → COMMIT(next).
    /// No SETTLED terminal state — the epoch advance happens on the
    /// EXECUTION → COMMIT(next) transition.
    function test_nextPhase_commitToExecution_noCommits() public {
        // Epoch 1 COMMIT already open from setUp.
        fund.nextPhase(); // COMMIT → REVEAL
        assertEq(uint8(am.getPhase(1)), uint8(IAuctionManager.AuctionPhase.REVEAL));
        fund.nextPhase(); // REVEAL → EXECUTION (0 reveals, no winner)
        assertEq(uint8(am.getPhase(1)), uint8(IAuctionManager.AuctionPhase.EXECUTION));

        fund.nextPhase(); // EXECUTION → COMMIT (epoch 2)
        assertEq(fund.currentEpoch(), 2);
        assertEq(uint8(am.getPhase(2)), uint8(IAuctionManager.AuctionPhase.COMMIT));
        assertEq(fund.consecutiveMissedEpochs(), 1, "one missed epoch credited");
    }

    /// nextPhase with commits but no reveals: bonds forfeit at reveal
    /// close (the REVEAL → EXECUTION transition). Same semantics as the
    /// wall-clock driver.
    function test_nextPhase_revealToExecution_noReveals() public {
        // Epoch 1 COMMIT already open from setUp.
        uint256 bond = fund.currentBond();
        uint256 treasuryBefore = address(fund).balance;

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));

        fund.nextPhase(); // COMMIT → REVEAL
        fund.nextPhase(); // REVEAL → EXECUTION (no reveals, bonds forfeited)

        assertEq(
            address(fund).balance,
            treasuryBefore + bond,
            "non-revealer bond forfeited to treasury at reveal close"
        );
    }

    /// Bond escalation via manual driver: a winner who doesn't submit
    /// forfeits their bond at the EXECUTION → COMMIT(next) transition,
    /// which also escalates currentBond. Same as the wall-clock path.
    function test_nextPhase_executionForfeit_escalatesBond() public {
        // Epoch 1 COMMIT already open from setUp.
        uint256 bond = fund.currentBond();

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));
        fund.nextPhase(); // COMMIT → REVEAL
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));
        fund.nextPhase(); // REVEAL → EXECUTION

        uint256 bondBefore = fund.currentBond();
        fund.nextPhase(); // EXECUTION → COMMIT(epoch 2) with winner forfeit

        // Bond escalated by AUTO_ESCALATION_BPS (1000 = 10%)
        uint256 expected = bondBefore + (bondBefore * 1000) / 10000;
        assertEq(fund.currentBond(), expected, "bond escalated on forfeit");
    }

    // ══════════════════════════════════════════════════════════════════
    // Mixed driver — the truly diabolical tests. Manual nextPhase and
    // wall-clock syncPhase interleaved in the same epoch. The contract
    // must stay consistent regardless of which driver fires when.
    // ══════════════════════════════════════════════════════════════════

    /// Manual partial close, then wall-clock takes over. The auction
    /// started by setUp must be drainable by syncPhase when wall-clock
    /// catches up.
    function test_mixed_manualOpen_wallClockDrain() public {
        // Epoch 1 COMMIT already open from setUp.
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
        fund.syncPhase(); // EXECUTION → advance → COMMIT (epoch 2)
        assertEq(fund.currentEpoch(), 2);
    }

    /// Wall-clock and manual driver interleaved to close phases. syncPhase
    /// must be a no-op after each nextPhase since the manual driver
    /// already advanced.
    function test_mixed_wallClockOpen_manualClose() public {
        // Epoch 1 COMMIT already open from setUp.
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

    /// Commit + manual close of commit, then wall-clock warp past the
    /// FULL epoch. syncPhase must handle the auction that was manually
    /// advanced to REVEAL but whose reveal window expired on the
    /// wall-clock.
    function test_mixed_manualPartial_wallClockFinishesEpoch() public {
        // Epoch 1 COMMIT already open from setUp.
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));

        fund.nextPhase(); // manual: COMMIT → REVEAL
        // Runner doesn't reveal. Warp past the entire epoch.
        vm.warp(block.timestamp + EPOCH_DUR * 2);
        fund.syncPhase();

        // The auction was in REVEAL with no reveals → EXECUTION (forfeit
        // all non-revealer bonds). Then epoch advance + open.
        assertGt(fund.currentEpoch(), 1, "advanced past stuck epoch");
    }

    /// Interleave: warp just past commit, syncPhase closes commit
    /// (wall-clock), then manual nextPhase closes reveal. Verifies both
    /// drivers can contribute to the same epoch.
    function test_mixed_alternatingDrivers_sameEpoch() public {
        // Epoch 1 COMMIT already open from setUp.
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
        // Epoch 1 COMMIT already open from setUp.
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

    // ══════════════════════════════════════════════════════════════════
    // Additional coverage — gaps identified during audit
    // ══════════════════════════════════════════════════════════════════

    // ── I2: transition cleanup exactly-once under manual driver ──────

    /// Non-revealer forfeit via manual driver: bond forfeited exactly
    /// once at the REVEAL → EXECUTION transition, repeated nextPhase
    /// calls don't double-forfeit.
    function test_I2_manualDriver_nonRevealerForfeit_exactlyOnce() public {
        // Epoch 1 COMMIT already open from setUp.
        uint256 bond = fund.currentBond();
        uint256 treasuryBefore = address(fund).balance;

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));

        fund.nextPhase(); // COMMIT → REVEAL
        fund.nextPhase(); // REVEAL → EXECUTION (0 reveals, bond forfeited)

        assertEq(address(fund).balance, treasuryBefore + bond, "I2: one forfeit via manual");

        // Advance to next epoch + open. Treasury should only gain from
        // the one forfeit, not any phantom re-forfeit.
        uint256 afterForfeit = address(fund).balance;
        fund.nextPhase(); // EXECUTION → COMMIT (epoch 2)
        fund.nextPhase(); // epoch 2: COMMIT → REVEAL (no commits)
        fund.nextPhase(); // epoch 2: REVEAL → EXECUTION
        assertEq(address(fund).balance, afterForfeit, "I2: no double-forfeit across epochs");
    }

    /// Winner forfeit via manual driver runs exactly once — at the
    /// EXECUTION → COMMIT(next) transition.
    function test_I2_manualDriver_winnerForfeit_exactlyOnce() public {
        // Epoch 1 COMMIT already open from setUp.
        uint256 bond = fund.currentBond();
        uint256 treasuryBefore = address(fund).balance;

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));
        fund.nextPhase(); // COMMIT → REVEAL
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));
        fund.nextPhase(); // REVEAL → EXECUTION

        fund.nextPhase(); // EXECUTION → COMMIT(epoch 2) with winner forfeit
        assertEq(address(fund).balance, treasuryBefore + bond, "I2: winner bond forfeited once");

        uint256 afterForfeit = address(fund).balance;
        // Further advances through empty epoch 2 must not re-forfeit.
        fund.nextPhase(); // epoch 2: COMMIT → REVEAL
        fund.nextPhase(); // epoch 2: REVEAL → EXECUTION
        assertEq(address(fund).balance, afterForfeit, "I2: no re-forfeit on advance");
    }

    // ── I3: full system wei conservation ─────────────────────────────

    /// Total ETH across the entire system (fund + AM + all runners)
    /// is conserved across a complete auction lifecycle.
    function test_I3_fullSystemWeiConservation() public {
        uint256 systemTotal = address(fund).balance + address(am).balance
            + runner1.balance + runner2.balance;

        // Epoch 1 COMMIT already open from setUp.
        uint256 bond = fund.currentBond();

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.008 ether, bytes32("r1")));
        vm.prank(runner2);
        fund.commit{value: bond}(_commitHash(runner2, 0.005 ether, bytes32("r2")));
        assertEq(_systemTotal(), systemTotal, "I3: conserved after commits");

        fund.nextPhase(); // COMMIT → REVEAL
        vm.prank(runner1);
        fund.reveal(0.008 ether, bytes32("r1"));
        vm.prank(runner2);
        fund.reveal(0.005 ether, bytes32("r2"));
        assertEq(_systemTotal(), systemTotal, "I3: conserved after reveals");

        fund.nextPhase(); // REVEAL → EXECUTION (non-revealer bonds = 0 here)
        assertEq(_systemTotal(), systemTotal, "I3: conserved after reveal close");

        fund.nextPhase(); // EXECUTION → COMMIT(epoch 2) with winner forfeit
        assertEq(_systemTotal(), systemTotal, "I3: conserved after forfeit");

        // runner1 claims non-winner bond
        vm.prank(runner1);
        am.claimBond(1);
        assertEq(_systemTotal(), systemTotal, "I3: conserved after claim");
    }

    function _systemTotal() internal view returns (uint256) {
        return address(fund).balance + address(am).balance
            + runner1.balance + runner2.balance;
    }

    // ── I5: freeze atomicity under manual driver ─────────────────────

    /// Snapshot opened at setUp via setAuctionManager is immutable:
    /// subsequent mutations (donations, inflows) do not change the
    /// frozen snapshot.
    function test_I5_manualDriver_snapshotImmutable() public {
        // Epoch 1 already opened at setUp (via setAuctionManager's eager
        // _openAuction), freezing the snapshot.
        bytes32 hashAtOpen = fund.computeInputHashForEpoch(1);

        TheHumanFund.EpochSnapshot memory snapBefore = fund.getEpochSnapshot(1);
        assertEq(snapBefore.balance, 10 ether, "I5: snapshot balance at open");

        // Mutate live state
        vm.deal(address(this), 2 ether);
        (bool ok,) = address(fund).call{value: 2 ether}("");
        require(ok);

        // Snapshot unchanged
        TheHumanFund.EpochSnapshot memory snapAfter = fund.getEpochSnapshot(1);
        assertEq(snapAfter.balance, 10 ether, "I5: snapshot balance unchanged after donation");
        assertEq(fund.computeInputHashForEpoch(1), hashAtOpen, "I5: hash stable");
    }

    // ── I6: seed stability under manual driver ───────────────────────

    /// Seed captured via nextPhase is stable across repeated calls.
    function test_I6_manualDriver_seedStableAfterCapture() public {
        // Epoch 1 COMMIT already open from setUp.
        uint256 bond = fund.currentBond();

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));
        fund.nextPhase(); // COMMIT → REVEAL
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));
        fund.nextPhase(); // REVEAL → EXECUTION (seed captured)

        uint256 seed = am.getRandomnessSeed(1);
        assertTrue(seed != 0, "I6: seed captured");

        // Walk through forfeit + next epoch — seed must not change
        fund.nextPhase(); // EXECUTION → COMMIT (epoch 2) with forfeit
        fund.nextPhase(); // epoch 2: COMMIT → REVEAL
        assertEq(am.getRandomnessSeed(1), seed, "I6: seed stable after epoch advance");
    }

    // ── Derived: no stuck states via manual driver ───────────────────

    /// From any phase, a finite sequence of nextPhase calls reaches a
    /// new epoch — no wall-clock needed. Quiescence in the 3-phase model
    /// means "cleanly advanced to the next epoch's COMMIT."
    function test_derived_noStuckStates_manualDriver() public {
        uint256 bond;

        // Case A: pristine (epoch 1 COMMIT, no commits)
        uint256 start = fund.currentEpoch();
        _advanceOneEpochManual();
        assertGt(fund.currentEpoch(), start, "A: advanced from fresh COMMIT");

        // Case B: mid-COMMIT with commits
        start = fund.currentEpoch();
        bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("stuck-b")));
        _drainToNextEpochManual();
        assertGt(fund.currentEpoch(), start, "B: advanced from mid-COMMIT");

        // Case C: EXECUTION (commit + reveal, no submit)
        start = fund.currentEpoch();
        bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("stuck-c")));
        fund.nextPhase(); // COMMIT → REVEAL
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("stuck-c"));
        fund.nextPhase(); // REVEAL → EXECUTION
        fund.nextPhase(); // EXECUTION → COMMIT(next) with forfeit
        assertGt(fund.currentEpoch(), start, "C: advanced from EXECUTION");
    }

    /// Helper: from a fresh COMMIT (no commits), advance exactly one
    /// epoch via the 3-phase cycle.
    function _advanceOneEpochManual() internal {
        fund.nextPhase(); // COMMIT → REVEAL
        fund.nextPhase(); // REVEAL → EXECUTION (0 commits, 0 reveals)
        fund.nextPhase(); // EXECUTION → COMMIT (next epoch)
    }

    /// Helper: from inside a COMMIT with commits, drain to next epoch
    /// via the manual forfeit path.
    function _drainToNextEpochManual() internal {
        fund.nextPhase(); // COMMIT → REVEAL
        fund.nextPhase(); // REVEAL → EXECUTION (0 reveals, forfeit)
        fund.nextPhase(); // EXECUTION → COMMIT (next epoch)
    }

    // ── Derived: nextPhase → resetAuction non-confiscation ───────────

    /// Interleaving nextPhase and resetAuction: committer's bond is
    /// never confiscated by the combination.
    function test_derived_nextPhase_then_resetAuction_nonConfiscation() public {
        // Epoch 1 COMMIT already open from setUp.
        uint256 bond = fund.currentBond();
        uint256 r1Before = runner1.balance;

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));

        // Advance to REVEAL via nextPhase (commits stay intact)
        fund.nextPhase(); // COMMIT → REVEAL

        // Owner decides to abort via resetAuction instead of continuing
        fund.resetAuction(COMMIT_WIN, REVEAL_WIN, EXEC_WIN);

        // runner1's bond was refunded (resetAuction is non-confiscatory)
        assertEq(runner1.balance, r1Before, "non-confiscation: bond refunded");
    }

    // ── Derived: driver equivalence full state ───────────────────────

    /// Full state equivalence: treasury, AM balance, pendingBondRefunds
    /// all match between manual and wall-clock drivers.
    function test_derived_driverEquivalence_fullState() public {
        // ── Manual path ──
        uint256 snap = vm.snapshotState();
        // Epoch 1 COMMIT already open from setUp.
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));
        vm.prank(runner2);
        fund.commit{value: bond}(_commitHash(runner2, 0.003 ether, bytes32("r2")));
        fund.nextPhase(); // COMMIT → REVEAL
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));
        vm.prank(runner2);
        fund.reveal(0.003 ether, bytes32("r2"));
        fund.nextPhase(); // REVEAL → EXECUTION
        fund.nextPhase(); // EXECUTION → COMMIT(epoch 2) with forfeit

        uint256 mTreasury = address(fund).balance;
        uint256 mAM = address(am).balance;
        uint256 mPending = am.pendingBondRefunds();
        uint256 mEpoch = fund.currentEpoch();

        // ── Wall-clock path ──
        vm.revertToState(snap);
        // Epoch 1 already open.
        bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));
        vm.prank(runner2);
        fund.commit{value: bond}(_commitHash(runner2, 0.003 ether, bytes32("r2")));
        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));
        vm.prank(runner2);
        fund.reveal(0.003 ether, bytes32("r2"));
        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase();
        vm.warp(block.timestamp + EXEC_WIN);
        fund.syncPhase();

        assertEq(address(fund).balance, mTreasury, "equiv: treasury");
        assertEq(address(am).balance, mAM, "equiv: AM balance");
        assertEq(am.pendingBondRefunds(), mPending, "equiv: pending refunds");
        assertEq(fund.currentEpoch(), mEpoch, "equiv: epoch");
    }

    // ── Edge: nextPhase with no AM ───────────────────────────────────

    function test_edge_nextPhase_revertsWithNoAM() public {
        // Deploy a bare fund with no AM (don't call setAuctionManager).
        TheHumanFund bare = new TheHumanFund{value: 1 ether}(
            1000, 0.01 ether,
            address(0xBEEF), address(0)
        );
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        bare.nextPhase();
    }

    // ── Edge: partial phase close in _advanceToNow ───────────────────

    /// Wall-clock past commit but not reveal: syncPhase advances exactly
    /// one phase (COMMIT → REVEAL) and stops, leaving AM in REVEAL.
    function test_edge_partialPhaseClose_commitOnly() public {
        // Epoch 1 COMMIT already open from setUp.
        uint256 bond = fund.currentBond();

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("r1")));

        // Warp past commit window but NOT past reveal window
        vm.warp(block.timestamp + COMMIT_WIN + 1);
        fund.syncPhase();

        // Should be in REVEAL, not EXECUTION
        assertEq(
            uint8(am.getPhase(1)),
            uint8(IAuctionManager.AuctionPhase.REVEAL),
            "partial: stopped at REVEAL"
        );

        // Runner can still reveal
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("r1"));
    }

    // ══════════════════════════════════════════════════════════════════
    // META-INVARIANT — The fund always holds exactly one in-flight
    //                  auction (except across the atomic EXECUTION→COMMIT
    //                  tx boundary and under FREEZE_SUNSET).
    // ══════════════════════════════════════════════════════════════════

    /// At any observable point outside a single tx or sunset, the AM's
    /// `currentAuctionEpoch` equals the fund's `currentEpoch` and the AM
    /// phase is one of {COMMIT, REVEAL, EXECUTION}. Walk through all
    /// 3 phases of several epochs and assert at each step.
    function test_meta_alwaysOneAuction_acrossFullLifecycle() public {
        for (uint256 e = 0; e < 3; e++) {
            uint256 expectedEpoch = fund.currentEpoch();

            // COMMIT phase
            assertEq(am.currentAuctionEpoch(), expectedEpoch, "meta: live in COMMIT");
            assertEq(uint8(am.getPhase(expectedEpoch)),
                     uint8(IAuctionManager.AuctionPhase.COMMIT), "meta: COMMIT phase");

            uint256 bond = fund.currentBond();
            bytes32 salt = bytes32(uint256(e | 0xCAFE));
            vm.prank(runner1);
            fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, salt));

            // REVEAL phase (via manual driver)
            fund.nextPhase();
            assertEq(am.currentAuctionEpoch(), expectedEpoch, "meta: live in REVEAL");
            assertEq(uint8(am.getPhase(expectedEpoch)),
                     uint8(IAuctionManager.AuctionPhase.REVEAL), "meta: REVEAL phase");

            vm.prank(runner1);
            fund.reveal(0.005 ether, salt);

            // EXECUTION phase
            fund.nextPhase();
            assertEq(am.currentAuctionEpoch(), expectedEpoch, "meta: live in EXECUTION");
            assertEq(uint8(am.getPhase(expectedEpoch)),
                     uint8(IAuctionManager.AuctionPhase.EXECUTION), "meta: EXEC phase");

            // Submit to cleanly roll into the next epoch
            vm.prank(runner1);
            fund.submitAuctionResult(
                abi.encodePacked(uint8(0)), bytes("noop"), bytes("mock"),
                EPOCH_TEST_VERIFIER_ID, -1, ""
            );
            fund.nextPhase(); // cross boundary
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // BEHAVIORAL COMPLETENESS — mechanical invariants not yet covered.
    // ══════════════════════════════════════════════════════════════════

    /// Commit requires `msg.value >= currentBond`; under-bond reverts.
    function test_commit_underBond_reverts() public {
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        vm.expectRevert();
        fund.commit{value: bond - 1}(_commitHash(runner1, 1, bytes32("s")));
    }

    /// Over-bonded commits accept the excess — the AM only takes exactly
    /// `currentBond`, the rest is returned (or becomes part of the fund,
    /// depending on contract policy). Either way the tx does not revert,
    /// the commit is recorded, and the committer isn't overcharged on
    /// claim time. We assert the recorded commit succeeded.
    function test_commit_overBond_accepted() public {
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond + 0.5 ether}(_commitHash(runner1, 1, bytes32("s")));
        // Recorded: runner1 is a committer for epoch 1.
        address[] memory committers = am.getCommitters(1);
        assertEq(committers.length, 1, "commit recorded despite over-bond");
        assertEq(committers[0], runner1);
    }

    /// submitAuctionResult must NEVER revert on a verified proof, even if
    /// the action bytes are malformed or the action execution fails. The
    /// winner must still receive bounty + bond-back. This is load-bearing
    /// for liveness: a faulty enclave output cannot DoS payment.
    function test_submit_invalidAction_stillPaysWinner() public {
        // Walk epoch 1 into EXECUTION with runner1 as the winner.
        uint256 bond = fund.currentBond();
        bytes32 salt = bytes32(uint256(0xDEAD));
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.003 ether, salt));
        fund.nextPhase();
        vm.prank(runner1);
        fund.reveal(0.003 ether, salt);
        fund.nextPhase();

        uint256 runnerBefore = runner1.balance;
        uint256 winningBid = am.getWinningBid(1);

        // Submit with a malformed action (unrecognized action type).
        vm.prank(runner1);
        fund.submitAuctionResult(
            abi.encodePacked(uint8(99), uint256(0xBAD)), // garbage action
            bytes("reasoning"),
            bytes("mock"),
            EPOCH_TEST_VERIFIER_ID,
            -1, ""
        );

        // Winner got bond refund + bounty regardless of action validity.
        assertEq(runner1.balance, runnerBefore + bond + winningBid,
            "winner paid bond+bounty despite invalid action");
    }

    /// Policy sidecar failure (invalid slot) must NOT revert the submission.
    /// Same liveness concern: bad policy text can't block payment.
    function test_submit_invalidPolicySlot_stillSucceeds() public {
        uint256 bond = fund.currentBond();
        bytes32 salt = bytes32(uint256(0xF00D));
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.003 ether, salt));
        fund.nextPhase();
        vm.prank(runner1);
        fund.reveal(0.003 ether, salt);
        fund.nextPhase();

        // Submit with an invalid policy slot (slot 99 is out of range).
        vm.prank(runner1);
        fund.submitAuctionResult(
            abi.encodePacked(uint8(0)),
            bytes("reasoning"),
            bytes("mock"),
            EPOCH_TEST_VERIFIER_ID,
            int8(99),            // invalid slot
            "invalid"
        );

        // Execution still recorded; epoch marked executed.
        ( , , , , , , bool executed) = fund.getEpochRecord(1);
        assertTrue(executed, "executed despite bad policy sidecar");
    }
}
