# Commit 7: Remove Direct Mode — Detailed Plan

(Deferred — pursuing commits 2 + 3 first. See REFACTOR_PLAN.md.)

## Motivation
`submitEpochAction` is a legacy owner-only "execute an epoch without running an
auction" path used almost exclusively by tests (via `speedrunEpoch`) and a
handful of tests that call it directly. It duplicates the final executable path
(`_recordAndExecute`), adds its own `FREEZE_DIRECT_MODE` gate, and keeps a
second `_freezeEpochSnapshot` call site alive. Removing it collapses the
contract surface to a single freeze-site, single execution path
(`submitAuctionResult` → `_recordAndExecute`).

## Strategy: split into 4 sub-commits

### Sub-commit 7a: Add `MockProofVerifier` + rewire `speedrunEpoch`

Test infra only, no contract change.

**New helper — `test/helpers/MockProofVerifier.sol`**: implements `IProofVerifier`,
`verify(...)` returns `true` unconditionally, `freeze()` is a no-op.

**Rewrite `test/helpers/EpochTest.sol`** — `speedrunEpoch` runs a full
commit → reveal → submit cycle:
1. `fund.syncPhase()` (opens auction if within commit window)
2. Read `cw`, `rw`, `xw` from `fund.auctionManager()`
3. Deal bond to canonical `EPOCH_TEST_RUNNER` (`address(0xE90C)`),
   `vm.prank(runner); fund.commit{value: bond}(commitHash)` with fixed salt +
   1 wei bid
4. `vm.warp(+cw)`, `vm.prank(runner); fund.reveal(bidAmount, salt)`
5. `vm.warp(+rw)`, `fund.syncPhase()` (closes reveal, captures seed)
6. `vm.prank(runner); fund.submitAuctionResult(action, reasoning, "", 7, policySlot, policyText)`
7. `vm.warp(fund.epochStartTime(currentEpoch + 1))`, `fund.syncPhase()`

**New `_registerMockVerifier(fund, verifierId)` helper** — each setUp calls it
after `setAuctionManager`. Hard-code `verifierId = 7` so it can't collide with
real-verifier tests that use id 1.

**Touch every setUp** that inherits EpochTest: TheHumanFund, Messages,
WorldView, InvestmentManager, AuctionInvariants, TheHumanFundAuction.

### Sub-commit 7b: Convert holdout tests

| File | Line | Intent | Replacement |
|---|---|---|---|
| `TheHumanFund.t.sol:306` | direct-mode auth | **Delete in 7c** |
| `TheHumanFund.t.sol:361` | run 2nd epoch | `speedrunEpoch(...)` |
| `TheHumanFund.t.sol:418` | freeze flag | **Delete in 7c** |
| `TheHumanFund.t.sol:607, 616, 626, 638, 652` | fuzz | `speedrunEpoch(...)` |
| `Messages.t.sol:283, 331, 364` | run epoch | `speedrunEpoch(...)` |
| `WorldView.t.sol:164` | run 2nd epoch with policy | `speedrunEpoch(..., 1, "...")` |
| `CrossStackHash.t.sol:67, 77, 85, 91, 101` | force freeze | Inherit EpochTest; use `syncPhase()` for pure freeze, `speedrunEpoch` for full-execute cases |
| `MainnetFork.t.sol:196, 210` | invest action | Inherit EpochTest; `speedrunEpoch(...)` |
| `TheHumanFundAuction.t.sol:979` | coexistence test | **Delete in 7c** |

`CrossStackHash` and `MainnetFork` currently inherit plain `Test` — switch to
`EpochTest`.

**`CrossStackHash` bountyPaid caveat:** tests call
`computeInputHashForEpoch(1)` after a freeze. Direct mode stored `bountyPaid=0`;
auction flow stores `bountyPaid=1` (the mock bid). Check
`_buildStateJson` in CrossStackHash and update if so.

### Sub-commit 7c: Delete direct-mode tests

- `TheHumanFund.t.sol::test_only_owner_can_submit`
- `TheHumanFund.t.sol::test_freezeDirectMode`
- `TheHumanFundAuction.t.sol::test_directSubmission_coexists`

Confirm `grep -rn "submitEpochAction\|FREEZE_DIRECT_MODE" test/` shows only
comments.

### Sub-commit 7d: Remove direct mode from the contract

**`src/TheHumanFund.sol`:**
- Delete `FREEZE_DIRECT_MODE` constant
- Delete `submitEpochAction` function
- Remove `FREEZE_DIRECT_MODE` reference in `freeze()` NatSpec
- Update `_openNextAuction` doc — drop direct-mode caveat (it's now THE sole
  freeze site)
- Update `_freezeEpochSnapshot` doc — drop "from submitEpochAction" line

**`script/Deploy.s.sol`:** remove `fund.freeze(fund.FREEZE_DIRECT_MODE())`.

**`prover/client/epoch_state.py:34`:** update comment referencing
`submitEpochAction` → `submitAuctionResult`.

**Verify:** full `forge test` → expected 256 passing (259 − 3 deleted).

## Risk register

| Risk | Mitigation |
|---|---|
| `speedrunEpoch`'s warp-to-next-epoch side effects break assumptions | Fix case-by-case |
| `MockProofVerifier` accidentally used in real-attestation tests | Dedicated slot `7` |
| `CrossStackHash` bountyPaid mismatch | Check `_buildStateJson` after 7b |
| `MainnetFork` can't get bond ETH on fork | Treasury 0.1 ETH vs BASE_BOND 0.01 ETH — OK |
| Fuzz tests exceed per-test gas budget | Lower runs if needed |

## NOTE (Apr 2026): superseded direction

We're instead pursuing commits 2 + 3 from the main plan — an owner-only
`nextPhase()` single-step manual driver — and rewiring `speedrunEpoch` to
drive epochs via `nextPhase()` + `submitAuctionResult` rather than through
the wall-clock path. This preserves the direct-mode ergonomics for tests
*and* ships a prod-debugging tool (owner can walk the state machine a step
at a time if something gets stuck). Commit 7 may still land later to remove
`submitEpochAction` entirely, but only after the new path proves itself.
