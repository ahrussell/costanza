# `_nextPhase` Refactor: Implementation Plan

Acceptance criteria: [AUCTION_INVARIANTS.md](AUCTION_INVARIANTS.md).
This document is the ordered execution plan for getting there.

## Architecture decision (resolved while reading the code)

The current architecture has `TheHumanFund` as the orchestrator and
`AuctionManager` as a pure one-auction-at-a-time state machine. The
AM transitions `COMMIT → REVEAL → EXECUTION → SETTLED` internally, and
the fund calls `openAuction(e+1)` separately to start the next one.

Two ways to unify this under `_nextPhase`:

**A. Invert control.** Move `openAuction` logic into the AM, have the
AM call back to the fund for the new bond amount / start time / freeze
snapshot. `_nextPhase` lives in the AM and handles the full
`COMMIT → REVEAL → EXECUTION → COMMIT[e+1]` cycle. Cleanest, but
changes the AM's interface and requires the fund to expose a "seed
next auction" hook.

**B. Keep the orchestrator split.** `_nextPhase` lives in the fund and
internally calls existing AM externals (`syncPhase`, `openAuction`)
plus the fund's own `_openAuction` / `_freezeEpochSnapshot`. The AM
keeps its internal `SETTLED` state but the fund never exposes it —
`_nextPhase` always advances past SETTLED in the same call. From the
fund's external API, the phase enum is `COMMIT | REVEAL | EXECUTION`.

**Decision: B.** Rationale:
- The fund already has all the state needed (epochDuration, timingAnchor,
  freeze flags, EpochSnapshot fields). Moving that into the AM would
  require either duplicating it or opening a fat callback interface.
- The AM is self-contained at 418 LOC and well-tested. Disturbing it
  risks regressions in bond accounting and randomness capture — the
  two things we have the hardest time testing end-to-end.
- Option A is reachable as a follow-up if we want to collapse the two
  contracts later.

**Sub-decision: collapse SETTLED into IDLE inside the AM.** The
invariants doc says "no SETTLED phase." Today the AM has both IDLE
(no auction has ever started OR just cleared) and SETTLED (an auction
completed, history stored, waiting for fund to call `openAuction`
again). These are semantically the same "AM is at rest" state — the
only caller-visible difference is whether `auctionHistory[epoch]` is
populated, which is a storage question, not a phase question.

The refactor collapses them: the AM's phase enum becomes
`IDLE | COMMIT | REVEAL | EXECUTION`. After `_closeReveal`/`_doForfeit`,
the AM transitions back to IDLE. Historical data lives in
`auctionHistory[epoch]` keyed by epoch, unchanged from today.
`getPhase(epoch)` returns IDLE for past epochs too (the AM doesn't
remember "this was settled" — the fund's `epochs[epoch].executed`
mapping is the authoritative source for that).

Effect on invariants:
- I5 (freeze atomicity): unchanged. Fund still freezes snapshot at
  `_openNextAuction`.
- External view of phase is three-state (`COMMIT | REVEAL | EXECUTION`)
  for the active epoch, and "no active auction" otherwise. Frontend
  uses timing math to decide what to display, same as today.

This sub-decision adds a tiny bit of work to commit 2 (map SETTLED →
IDLE in the AM and update call sites that distinguish them), but
makes commits 3–6 cleaner because there's one fewer phase to reason
about.

## Ordered commits

Each bullet is one reviewable commit. Order is load-bearing: earlier
commits enable invariant tests that catch regressions in later ones.

### 1. Reuse `FREEZE_AUCTION_CONFIG` for manual-driver gate  *(low risk)*
- `FREEZE_AUCTION_CONFIG` already gates `setAuctionTiming` and
  `setAuctionManager` — semantically "owner can't reshape the auction
  state machine." Extend it (no rename) to cover the new manual-driver
  entry points `nextPhase` and `resetAuction` added in commits 3 and 4.
- `FREEZE_MIGRATE` stays as-is for `migrate`/`withdrawAll`/
  `transferOwnership` — those are lifecycle, not auction control.
- This commit is documentation-only: the flag already exists. The
  actual gating happens in commits 3 and 4 when the new entry points
  land.
- Alternative: land a tiny scaffold commit that adds a `whenAuctionUnfrozen`
  modifier and the I7 test stub. But since there's nothing to gate yet,
  skip it — fold the work into commits 3 and 4 directly.

### 2. `_nextPhase` as the single progression helper  *(medium risk)*
- In `TheHumanFund.sol`, rename internal `_syncPhase` → `_advanceToNow`
  (a loop) and extract a new `_nextPhase()` that performs exactly
  one transition step.
- `_nextPhase` returns `(uint256 epoch, Phase phase)` for the new
  state. Phase enum is fund-local: `COMMIT | REVEAL | EXECUTION`.
- `_advanceToNow` loops `while (fund-phase(now) > current) _nextPhase();`
- All existing `_syncPhase()` call sites become `_advanceToNow()`.
- No external behavior change. All 239 tests must still pass.
- Invariant test: `test_I1_timeDriver_monotonicEpoch` already covers
  this; it will keep passing.

### 2.5. Multi-epoch fast-forward preservation + tests  *(low risk, pure spec lock-in)*

The current code already does O(1) arithmetic advance through empty
missed epochs (see commits `74dfdfd` and `990f944`). This is
load-bearing for the realistic "contract untouched for days" case:
without it, `syncPhase` would have to do N real transitions for N
missed epochs, and anyone who stopped calling the contract would hit
a gas cliff when trying to resume.

The refactor must preserve this property. This commit locks it in as
tests *before* the `_nextPhase` restructure, so any regression during
commits 2–7 shows up as an immediate test failure.

**Two primitives, one loop:**

1. `_stepPhase()` — one real transition on the in-flight auction
   (`COMMIT → REVEAL`, `REVEAL → EXECUTION`, `EXECUTION → close-out`).
   Each call runs exactly one phase's cleanup. These have side effects
   that must fire: bond forfeiture, seed capture, winner bond settle.

2. `_fastForwardEmptyEpochs(uint256 nMissed)` — O(1) bulk advance
   through `N` fully-missed epochs. Updates only:
   - `currentEpoch += nMissed`
   - `consecutiveMissedEpochs += nMissed` (capped at `MAX_MISSED_EPOCHS`)
   - `lastEpochStartTime` bumped to the new epoch's scheduled start
   - Nothing else. `effectiveMaxBid` and `currentBond` are pure
     functions of `consecutiveMissedEpochs`, so they recompute
     automatically. Messages untouched. No content hashes appended.
     No snapshot frozen.

**The loop in `_advanceToNow`:**
```
while (currentPhase != wallClockPhase) {
    _stepPhase();
    if (just finished in-flight auction) {
        uint256 missed = _wallClockEpoch() - currentEpoch - 1;
        if (missed > 0) _fastForwardEmptyEpochs(missed);
    }
}
```

Worst case is ~3 internal transitions + one arithmetic collapse,
regardless of how many epochs were skipped.

**Tests to add (all run against the current contract and should pass
today; they are regression canaries, not new-behavior specs):**

| Test | Scenario | Asserts |
|---|---|---|
| `test_ff_longSilence_noActivity` | open epoch 1, warp +10 epochs, syncPhase | `currentEpoch == 11`, `consecutiveMissedEpochs == 10`, `effectiveMaxBid` escalated correctly |
| `test_ff_commitNoReveal_thenSilence` | commit epoch 1, warp +10 epochs, syncPhase | treasury gained exactly ONE bond (not 10), `consecutiveMissedEpochs == 10` |
| `test_ff_successfulEpoch_thenSilence` | execute epoch 1, warp +10, syncPhase | `consecutiveMissedEpochs` resets on success then re-accumulates to 10 |
| `test_ff_messagesPreservedAcrossSilence` | queue 3 messages in epoch 1, no submit, warp +10, syncPhase | `messageCount == 3`, `messageHead == 0`, all 3 visible in landing snapshot |
| `test_ff_messagesQueuedDuringSilence` | warp +5, queue 2 messages, warp +5, syncPhase | both messages visible, `messageCount == 2` |
| `test_ff_snapshotReflectsEscalation` | long silence, read landing `getEpochSnapshot` | snapshot's `effectiveMaxBid` and `consecutiveMissedEpochs` match live values |
| `test_ff_bondEscalation` | long silence, read `currentBond()` | matches formula `bond * 1.1^N` within integer math |
| `test_ff_syncPhaseGas_boundedInN` | measure gas for `syncPhase` at N=1 vs N=20 missed epochs | gas stays within ~20% envelope (regression canary for "accidentally made it O(N)") |
| `test_ff_exactlyOneForfeit` | vm.recordLogs + treasury delta | treasury gains exactly one bond, not N bonds |

The **gas bound test** is the most important — it's the guard rail
against someone (future Claude or otherwise) "simplifying" the
arithmetic advance into a loop. If that test fails, the O(1)
property has been regressed.

### 3. Owner `nextPhase()` entry point  *(medium risk)*
- Add `function nextPhase() external onlyOwner` that:
  1. Reverts if `FREEZE_AUCTION_CONFIG` is set.
  2. Calls `_stepPhase()` once (just one transition — no wall-clock
     loop, no fast-forward).
  3. Re-anchors `timingAnchor` so `epochStartTime(currentEpoch) ==
     block.timestamp`. This guarantees I4 under the manual driver.
- Unblocks: `[POST_REFACTOR] I1 manual driver`, `[POST_REFACTOR] I4
  manual re-anchor`, `[POST_REFACTOR] I7 manual-only freeze`. Write
  those tests in this commit.

### 4. `resetAuction()` owner entry point  *(medium-high risk)*
- Add `function resetAuction() external onlyOwner`.
- Behavior: loop `_stepPhase()` until we're back in a fresh
  `COMMIT[e+1]`, refunding all active bonds along the way (never
  forfeiting). This is the "operator intervention never punishes
  bidders" rule from invariant I3.
- Gated by `FREEZE_AUCTION_CONFIG`.
- Key subtlety: the refund path needs to iterate committers and send
  each their bond. The current AM has `MAX_COMMITTERS = 50`, so a loop
  is safe. Add an internal AM helper `refundAllActiveBonds()` that
  sends each committer's bond back and clears the commit state.
- Unblocks: `[POST_REFACTOR] operator non-confiscation` test.

### 5. Compose `migrate()` out of `resetAuction + withdrawAll + transfer`  *(medium risk)*
- Replace the current monolithic `migrate()` with a composition that
  calls `resetAuction()` first (so no bonds are in flight), then
  withdraws all investments, then transfers treasury.
- Audit: make sure `FREEZE_SUNSET` + bond drain from AM (the thing
  `c3e083e` fixed) still works. The composed version should make this
  *easier* to reason about, not harder.
- Test: keep the existing `test_sunset_midAuction_canDrainAndMigrate`
  regression test passing.

### 6. Genesis bootstrap via `_openNextAuction`  *(low risk, pure refactor)*
- Extract `_openAuction` + `_freezeEpochSnapshot` + opening-side setup
  into a single internal `_openNextAuction(uint256 epoch, uint256
  scheduledStart)` helper.
- Call it from the constructor (for epoch 1) and from the
  `EXECUTION → COMMIT` branch of `_nextPhase`.
- Add a contract invariant: `_openNextAuction` is the *only* function
  that calls `_freezeEpochSnapshot`. Enforce with a comment + grep
  check (or a linter rule if we want to be fancy).
- No behavior change. Tests stay green.

### 7. Remove `submitEpochAction` and direct mode  *(high risk — lots of test churn)*
- Delete `submitEpochAction`, `FREEZE_DIRECT_MODE`, the direct-mode
  path in `_recordAndExecute`, and any views that only made sense in
  direct mode.
- Rewire `EpochTest.speedrunEpoch` to use the real
  `commit + warp + reveal + warp + submitAuctionResult` flow against a
  `MockProofVerifier` that accepts any proof (similar to the
  `AuctionMockDcapVerifier` pattern in `test/TheHumanFundAuction.t.sol`,
  but for the general `IProofVerifier` interface).
- The helper needs: a MockProofVerifier deployed and registered in
  `setUp` of EpochTest-using test classes (or better: EpochTest deploys
  its own in a shared setUp, but Foundry doesn't inherit setUp that
  way — each test class has to call `_setUpEpochTest()` in its own
  `setUp`). Alternatively, EpochTest defines `_deployMockVerifier()`
  and each test class calls it.
- Delete tests that only made sense for direct mode:
  - `test_only_owner_can_submit`
  - `test_freezeDirectMode`
  - `test_directSubmission_coexists`
  - `test_input_hash_includes_*` tests that rely on submit-without-sync
    for mid-epoch hash inspection — rewrite these to run two full
    epochs.
- Migrate `CrossStackHash.t.sol` to freeze via the auction path.
- Migrate `MainnetFork.t.sol` adapter tests to run via the auction
  path OR mark them as "use the same direct-mode-style helper" which
  is actually just speedrunEpoch post-refactor.
- Fuzz tests in `TheHumanFund.t.sol` (L604–L649): rewrite to use
  speedrunEpoch.

### 8. Update prover client  *(medium risk)*
- The prover's `client.py` and `auction.py` don't call
  `submitEpochAction` (it was never a prover path), but they DO
  reference phase constants and error selectors. Update:
  - Any phase enum handling to drop `SETTLED` (if it's even checked).
  - Error selector map — `AlreadyDone` etc. stay, `Frozen` may change.
- Sanity: run the prover in simulation mode against a local anvil node
  with the new contract.

### 9. Sepolia burn-in  *(user operation)*
- Deploy to Base Sepolia.
- Run the prover cron for at least 24 hours.
- Watch for stuck-state reports. If any, they're Class A bugs that
  would have hit mainnet.

### 10. Mainnet redeploy  *(user operation)*
- Same pattern as the recent 2026-04-14 redeploy. Withdraw from old
  contract, deploy new, update frontend DEPLOYMENTS array, update
  prover .env.

## Risk register

| Risk | Mitigation |
|---|---|
| Bond accounting regression in `resetAuction` refund path | Write property test: sum of bond states before == sum after. |
| `_nextPhase` infinite loop if phase math is off-by-one | `_advanceToNow` has a hard cap (e.g. 100 iterations) with a revert; syncPhase math already prevents this but defense in depth. |
| Test churn in commit 7 hides real behavior changes | Commit 7 is the biggest blast radius. Split into sub-commits if it's >500 LOC: (a) delete tests, (b) rewire helper, (c) remove direct mode. |
| `migrate()` composition breaks the sunset drain path | Keep the existing `test_sunset_midAuction_canDrainAndMigrate` test. If it fails, we're doing something wrong. |
| Prover client breaks against new contract | Run against local anvil before Sepolia. |

## Non-goals (do not touch in this refactor)

- Input hash layout (snapshots, sub-hashes, taint analyzer)
- Verifier registry / TDX attestation
- InvestmentManager / adapters
- WorldView slot schema
- Frontend (beyond DEPLOYMENTS update at the end)

## Risk register addendum

| Risk | Mitigation |
|---|---|
| Refactor accidentally regresses O(1) missed-epoch gas | `test_ff_syncPhaseGas_boundedInN` (added in commit 2.5) catches this immediately |
| Fast-forward drops messages or content hashes | `test_ff_messagesPreservedAcrossSilence` + `test_ff_messagesQueuedDuringSilence` |
| Bond/bid escalation drifts from `currentBond()` / `effectiveMaxBid()` during arithmetic advance | `test_ff_snapshotReflectsEscalation` + `test_ff_bondEscalation` |

## Status check

### Done

- [x] Invariants doc (`docs/AUCTION_INVARIANTS.md`)
- [x] `speedrunEpoch` abstraction + migration of 5 test files
      (commit `a0056eb`)
- [x] Invariant tests (`test/AuctionInvariants.t.sol`) — 9 tests
      mapping to I1–I6 + derived (commit `c6f796a`)
- [x] Fast-forward regression tests — 7 tests including gas canary
      (commit `fcff066`)
- [x] **`resetAuction()`** — owner entry point, gated by
      `FREEZE_AUCTION_CONFIG`. Takes `(commitWindow, revealWindow,
      executionWindow)`, aborts in-flight auction (refunds all held
      bonds via `AuctionManager.abortAuction`), applies new timing
      atomically, re-anchors schedule to now. Covers every phase:
      COMMIT/REVEAL refund all committers, EXECUTION refunds winner
      only (non-winning revealers keep their existing `claimBond`
      path), IDLE/SETTLED is a no-op. Plus 11 new tests for the
      non-confiscation property and each phase case
      (commit `3e8f2b8`). Also: deleted `claimLegacyBonds` +
      `claimableBonds` mapping; winners now get bond via direct push
      in `settleExecution`.
- [x] **`setAuctionTiming` removed.** The only paths that change
      auction timing now are `setAuctionManager(am, cw, rw, xw)`
      (initial wiring + initial timing) and `resetAuction(cw, rw, xw)`
      (mid-life). Both take the three phase windows; `epochDuration`
      is derived as `cw + rw + xw`, so it can't drift. The drift bug
      that bricked mainnet v1 (bd883a9) is impossible by construction.
- [x] **Missed-epoch credit semantics fix.** Old behavior: pristine
      IDLE silence didn't escalate `consecutiveMissedEpochs`, so a
      fresh deploy with no prover activity would never raise the max
      bid — bounded escalation mechanism was effectively dead on
      arrival. New rule, in `_advanceEpochBy(count, missCount)`:
      `missCount = advance - (executed ? 1 : 0)`. Every elapsed epoch
      counts as a miss except the current epoch if it was
      successfully executed (we're just catching up past a success).
      Plus the single-epoch and multi-epoch branches of Step B are
      now factored through a shared `_advanceEpochBy` helper
      (commit `705b982`).
- [x] **Bond and max-bid escalation decoupled** (commit `d5e1dda`).
      Two different incentives, two different triggers:
      - `effectiveMaxBid` escalates on every silent epoch
        (`consecutiveMissedEpochs`) → attracts bidders when running
        the agent isn't profitable. Unchanged from prior refactor.
      - `currentBond` is now direct state (not derived). Mutates via
        `currentBond = min(currentBond * 1.1, cap)` on winner-forfeit
        only. Resets to `BASE_BOND` on successful execution. Pristine
        silence, non-reveal, infra drop-outs do NOT bump it — they're
        either already punished via direct bond loss or shouldn't
        discourage new bidders from joining.
      Test `test_missedEpochs_escalateMaxBidButNotBond` and new
      `test_winnerForfeit_bondEscalates` lock the decoupled semantics in.

### Skipped / folded

- ~~Commit 1~~: reuse `FREEZE_AUCTION_CONFIG`. **Folded into
  `resetAuction`** — the flag already existed and `resetAuction`
  just uses it directly. No dedicated commit needed.
- ~~Commit 2.5~~: fast-forward preservation. **Not needed** —
  preservation is already locked in by the fast-forward tests
  landed in `fcff066`, and no commit reworked the fast-forward path.

### Remaining

- [ ] **Commit 8: update prover client** *(medium risk)*
  - Doesn't call `submitEpochAction` (never did), but references
    phase constants and error selectors. Audit:
    - Any phase enum handling that assumes `SETTLED` exists
      distinctly from `IDLE` — probably none since the AM's enum
      still has SETTLED (the collapse was not done).
    - Error selector map in `prover/client/chain.py` — `Frozen` now
      refers to different owner paths than before. Check whether
      the prover cares (it probably doesn't, since it's not calling
      owner methods).
  - Run the prover in simulation mode against a local anvil node
    with the new contract to catch anything missed.
- [ ] **Commit 9: Sepolia burn-in** *(user operation)*
  - Deploy the new contract to Base Sepolia.
  - Run the prover cron for at least 24 hours (one full day/night
    cycle).
  - Watch for stuck-state reports or forfeit alerts. Any issue is
    a Class A bug that would have hit mainnet.
- [ ] **Commit 10: mainnet redeploy** *(user operation)*
  - Withdraw from old contract (`0xeE98b474...`) using the existing
    sunset/migrate flow.
  - Deploy new contract with production timing (20m/20m/50m = 90m).
  - Update frontend `DEPLOYMENTS` array in `index.html`.
  - Update prover `.env` with new contract address.
  - Register GCP image key via `register_image.py` if the enclave
    image has changed (it hasn't in this refactor — the enclave
    code and the input hash format are both untouched).

### What was done (session 2)

- [x] **Commit 5: compose `migrate()` out of `_resetAuction`**
      (commit `ce6c7d2`). Extracted `_resetAuction` internal helper;
      `migrate()` calls it with current AM timing before draining.
      Mid-auction migration now works atomically. New test
      `test_migrate_midAuction_refundsCommitters`.
- [x] **Commit 6: rename `_openAuction` → `_openNextAuction`**
      (commit `e1c94a0`). Pure refactor, documents single-freeze-site
      role. `_openNextAuction` is the only production path that calls
      `_freezeEpochSnapshot`.
- [x] **Commit 2: extract `_nextPhase`, rename `_syncPhase` →
      `_advanceToNow`** (commit `fbfa660`). New internal
      `_nextPhase(scheduledStart)` — shared single-step primitive.
      `_advanceToNow` uses it for each elapsed phase close; preserves
      O(1 fast-forward. AM gets `forceClosePhase()` for time-
      independent phase transitions.
- [x] **Commit 3: owner `nextPhase()` entry point** (commit `6f47aae`).
      Owner-only manual driver. Calls `_nextPhase()` once, re-anchors
      timing on epoch advance / auction open. Gated by
      `FREEZE_AUCTION_CONFIG` (I7). 14 new tests: I1/I3/I4/I7
      manual driver, driver equivalence, 4 mixed-driver, edge cases.
      Updated `AUCTION_INVARIANTS.md` with implemented semantics.
- [x] **`_nextPhase` returns `AuctionPhase`** (commit `9cba456`).
      Per invariants doc design decision #5.
- [x] **Commit 7a: rewire `speedrunEpoch` via `nextPhase`**
      (commit `2641d17`). `MockProofVerifier` + `EpochTest` rewrite.
      `speedrunEpoch` now drives epochs through the real auction
      path using `nextPhase()` — no `vm.warp` needed. All test
      setUps register mock verifier at slot 7. Mechanical fixes:
      balance assertions (1 wei bounty), content hash, event ordering.
- [x] **Commit 7b+c+d: delete `submitEpochAction` and
      `FREEZE_DIRECT_MODE`** (commit `0ca5d77`). Removed from
      contract, deploy script, and prover comments. Deleted 3
      direct-mode-only tests. Converted 5 fuzz tests,
      CrossStackHash, and MainnetFork to use `speedrunEpoch`.
      `_openNextAuction` is now THE sole freeze site (I5).

Current test total: **266 passing, 0 failing, 9 skipped** on branch
`claude/nextphase` at commit `0ca5d77`.
