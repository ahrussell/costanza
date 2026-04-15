# Auction State Machine Invariants

Working doc for the `_nextPhase` refactor. These are the properties the
state machine must preserve under any driver (wall-clock `syncPhase`,
owner manual `nextPhase`, or direct action entry points). If writing
them down reveals inconsistencies with the current code, that is where
the refactor earns its keep.

## Vocabulary

- **Driver** — anything that causes a phase transition. Three kinds:
  1. *Time driver*: `syncPhase()` called by anyone, internally calls
     `_advanceToNow()` which uses `_nextPhase()` to close elapsed
     phases, then arithmetic-advances through missed epochs (O(1)),
     then opens the next auction if within the commit window.
  2. *Action driver*: `commit` / `reveal` / `submitAuctionResult` each
     call the time driver first, then act in the resulting phase.
  3. *Manual driver*: owner-only `nextPhase()`, calls `_nextPhase()`
     exactly once — no wall-clock loop, no fast-forward. Re-anchors
     timing on epoch advance / auction open so the wall-clock schedule
     remains consistent. Gated by `FREEZE_AUCTION_CONFIG`.
- **Transition** — a single call to `_nextPhase(scheduledStart)`,
  producing exactly one step: close a phase (COMMIT → REVEAL, etc.)
  OR open the next auction (IDLE/SETTLED → COMMIT). Epoch advancement
  is handled by the caller, not by `_nextPhase` itself — this lets
  the time driver preserve its O(1) fast-forward arithmetic.
- **SETTLED phase** — the AM's terminal state after an auction completes.
  The fund's callers (manual and wall-clock drivers) both advance
  `currentEpoch` and re-open from SETTLED. SETTLED is internal to
  the AM; the fund's external API never exposes it.
- **Active epoch** — the epoch whose auction is currently open, i.e.
  `currentEpoch` while its phase is not yet terminal.

## Core invariants

Every transition, regardless of driver, must preserve all of:

### I1. Monotonicity
`(currentEpoch, phase)` is strictly lex-increasing across transitions.
No driver can produce a state `(e', p')` such that `(e', p') ≤ (e, p)`
for the pre-transition state. Consequence: manual and time drivers
can never undo work, and re-entering `_nextPhase` with no elapsed time
is a no-op when already at the target.

### I2. Transition completeness
Every phase has exactly one cleanup routine, and every exit from that
phase runs that cleanup exactly once:

| Exit | Cleanup |
|---|---|
| `COMMIT → REVEAL` | none (commits stay as-is for reveal) |
| `REVEAL → EXECUTION` | close reveals, capture randomness seed, determine winner, settle non-revealer bond forfeiture |
| `EXECUTION → COMMIT[e+1]` | if epoch `e` unexecuted: forfeit winner bond to treasury; `epoch++`; freeze snapshot for `e+1`; open next auction |

No driver may skip a cleanup. A manual `nextPhase` that transitions
`REVEAL → EXECUTION` runs the same seed capture + winner selection as
a time-driven one. This is the main invariant the current codebase
stresses — the auto-`_syncPhase` at the top of every public method
exists precisely to enforce it.

### I3. Bond accounting closure
At every moment, for every bidder `b` who has committed in any epoch
`e`, their bond is in exactly one state:

- **held** — epoch `e` has not yet reached `REVEAL` close
- **claimable** — `b` revealed and is a non-winner in a settled epoch
- **winner-held** — `b` revealed, won, and has not yet delivered or forfeited
- **forfeited-to-treasury** — `b` committed but did not reveal (at reveal close), or won and did not deliver (at execution close)
- **refunded-all** — set by `resetAuction`, overrides the above for
  all bonds active at reset time. Manual operator intervention is
  never a forfeit event.

No state transition may leave a bond in two states, or in none.

**Driver equivalence for `nextPhase`**: `nextPhase` applies the same
forfeit rules as the wall-clock driver. Non-revealers forfeit at
reveal close; winners forfeit at execution close. This preserves the
derived property that both drivers produce the same state for the
same scenario. For a **non-confiscatory** abort (refund all bonds
regardless of phase), the operator uses `resetAuction` instead.
The operator's mental model: `nextPhase` = "advance the protocol
one step (normal rules apply)", `resetAuction` = "abort and refund
everyone (operator intervention, never a forfeit)".

### I4. Schedule coherence
After any transition, `epochStartTime(currentEpoch)` must be ≤
`block.timestamp`. The time driver satisfies this by construction
(it only advances to phases the wall clock has reached). The manual
driver satisfies it by updating `timingAnchor` at each step so that
the new `(anchorEpoch, timingAnchor)` pair makes the freshly-entered
phase's start equal `block.timestamp`. After a manual advance,
`syncPhase()` is a no-op until the wall clock ticks into the next
phase window naturally.

Consequence: there is no "parallel schedule" problem. Manual and
time-driven advances produce the same state *and* the same schedule.

### I5. Freeze atomicity
`EpochSnapshot[e]` is frozen exactly once, at the transition that
opens `COMMIT[e]` (i.e. the `EXECUTION[e-1] → COMMIT[e]` step of
`_nextPhase`, or the bootstrap case at contract genesis). After
freeze, the snapshot is immutable. The input hash is a pure function
of the snapshot, so any cross-stack hash check reads from the frozen
struct, never from live state.

Corollaries the refactor must not regress:
- The prover's epoch state reads every hash-affecting field from
  `getEpochSnapshot(epoch)`. Live reads are only for bounded-by-snapshot
  collection iteration.
- Freeze happens strictly before any committer can call `commit()` for
  that epoch. The commit path assumes a frozen snapshot already exists.
- There is exactly one freeze site in `_nextPhase`: the
  `EXECUTION → COMMIT` branch. Direct mode is gone; every action
  flows through the auction state machine.
- **Genesis bootstrap**: epoch 1's COMMIT has no prior EXECUTION to
  transition from, so the constructor (or a one-shot `initialize`)
  freezes the epoch-1 snapshot and opens the first COMMIT window
  inline. This is the same logic as the `_nextPhase` freeze branch,
  factored into an internal helper (`_openNextAuction(e)`) so both
  call sites share the implementation. The helper is the *only*
  function in the contract allowed to call `_freezeEpochSnapshot`.

### I6. Randomness capture atomicity
`randomnessSeed[e]` is set exactly once, at `REVEAL[e] → EXECUTION[e]`,
from `block.prevrandao XOR saltAccumulator[e]`. No driver may set it
earlier (would let commits grind) or later (would let reveals grind),
and no driver may set it twice.

### I7. Freeze scope is manual-only
`FREEZE_AUCTION` gates *only* the manual driver — owner-only entry
points (`nextPhase`, `resetAuction`, `migrate`, and anything else that
re-anchors timing). The time driver (`syncPhase`) and the action
driver (`commit` / `reveal` / `submitAuctionResult`) are unaffected,
and bidders can continue participating through a freeze. The freeze
flag exists so the operator can relinquish unilateral control without
halting the auction for participants.

## Derived properties (should follow from the invariants)

- **Driver equivalence**: given the same `(state, block.timestamp)`,
  all drivers produce the same resulting `(state, schedule)`. This is
  the core property that makes the refactor worth doing — it means
  tests can use the manual driver as a fast-forward for any scenario
  the time driver supports, and audits only need to reason about
  `_nextPhase` once.
- **No "stuck" states**: for any reachable `(epoch, phase)`, there
  exists a finite sequence of `_nextPhase` calls that reaches a
  well-defined next epoch with a fresh auction, without owner
  intervention. This is what the current `recover_submit.py` exists
  to work around; the invariant says the refactor must make it
  unnecessary.
- **Operator non-confiscation**: no sequence of `nextPhase` +
  `resetAuction` calls can move a bond from a non-forfeit state into
  `forfeited-to-treasury`. (I3 gives this directly.)

## Design decisions (resolved)

1. **No SETTLED phase.** State enum is `COMMIT | REVEAL | EXECUTION`.
   Settlement of epoch `e` is inseparable from opening epoch `e+1`;
   they are the same `_nextPhase` step. Frontend "auction done,
   waiting for next" is derived from timing, not stored.

2. **No direct mode.** `submitEpochAction` and its freeze-inline path
   are removed. Every action flows through `commit → reveal →
   submitAuctionResult`. Operator emergency interventions use
   `nextPhase` / `resetAuction`, which do not execute actions — they
   only advance the state machine.

3. **`migrate` is composed.** It calls `resetAuction` (refunds all
   active bonds, re-anchors timing), then withdraws all investments,
   then transfers treasury to the new address. Atomicity comes from
   it all happening in one transaction; auditability comes from each
   step being a named internal helper with its own invariants.

4. **One freeze flag, manual-only.** `FREEZE_AUCTION` blocks
   `nextPhase`, `resetAuction`, `migrate`, and any other owner entry
   point that could re-anchor timing or mutate auction state. It does
   *not* block `syncPhase`, `commit`, `reveal`, or
   `submitAuctionResult`. The flag's purpose is to let the operator
   renounce unilateral control without halting participant-driven
   auction flow.

5. **`_nextPhase(scheduledStart)` returns `bool advanced`.** The time
   driver re-reads AM phase from storage after each call; the return
   value indicates whether any transition occurred.

## Non-goals

- Changing the phase durations or their semantics.
- Changing how the snapshot is hashed, or what fields it contains.
- Changing the prover client's wall-clock dispatch logic. (The
  refactor is contract-internal; the client keeps calling the same
  entry points.)
- Adding new verifier types or changing proof flow.
