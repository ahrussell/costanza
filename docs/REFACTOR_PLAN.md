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
- The invariants doc says "no SETTLED phase." The invariants are about
  the *fund's* external behavior, not the AM's internal state. As long
  as the fund never leaves a call in SETTLED, the invariant holds.
- Option A is reachable as a follow-up if we want to collapse the two
  contracts later.

## Ordered commits

Each bullet is one reviewable commit. Order is load-bearing: earlier
commits enable invariant tests that catch regressions in later ones.

### 1. `FREEZE_AUCTION` flag scaffold  *(low risk)*
- Add `FREEZE_AUCTION` constant to `TheHumanFund.sol`.
- Add `frozen(FREEZE_AUCTION)` guards to `setAuctionTiming`,
  `setAuctionManager` (owner-only entry points that mutate auction
  wiring). Leave `submitEpochAction` for now.
- Do NOT gate `syncPhase`, `commit`, `reveal`, `submitAuctionResult`.
- Unblocks: I7 test can be enabled (it currently sits in the
  `[POST_REFACTOR]` TODO block).
- Test: enable the stubbed I7 test, confirm it passes.

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

### 3. Owner `nextPhase()` entry point  *(medium risk)*
- Add `function nextPhase() external onlyOwner` that:
  1. Reverts if `FREEZE_AUCTION` is set.
  2. Calls `_nextPhase()` once.
  3. Re-anchors `timingAnchor` so `epochStartTime(currentEpoch) ==
     block.timestamp`. This guarantees I4 under the manual driver.
- Unblocks: `[POST_REFACTOR] I1 manual driver`, `[POST_REFACTOR] I4
  manual re-anchor`. Write those tests in this commit.

### 4. `resetAuction()` owner entry point  *(medium-high risk)*
- Add `function resetAuction() external onlyOwner`.
- Behavior: loop `_nextPhase()` until we're back in a fresh
  `COMMIT[e+1]`, refunding all active bonds along the way (never
  forfeiting). This is the "operator intervention never punishes
  bidders" rule from invariant I3.
- Gated by `FREEZE_AUCTION`.
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

## Status check

- [x] Invariants doc (`docs/AUCTION_INVARIANTS.md`)
- [x] `speedrunEpoch` abstraction + migration of 5 test files
- [x] Invariant tests (`test/AuctionInvariants.t.sol`)
- [ ] Commit 1: `FREEZE_AUCTION` scaffold
- [ ] Commit 2: `_nextPhase` extraction
- [ ] Commit 3: owner `nextPhase()`
- [ ] Commit 4: `resetAuction()`
- [ ] Commit 5: composed `migrate()`
- [ ] Commit 6: `_openNextAuction` genesis bootstrap
- [ ] Commit 7: remove direct mode (test churn)
- [ ] Commit 8: prover client update
- [ ] Commit 9: Sepolia burn-in
- [ ] Commit 10: mainnet redeploy
