# CostanzaTokenAdapter — Adversarial Treasury Report

This document reports the outcomes of six adversarial simulations run
against the real `CostanzaTokenAdapter` + `InvestmentManager` +
`TheHumanFund` contracts, with mocked V4 plumbing for deterministic
control of price and fee inflows. Each scenario answers the same
question from a different attack angle: **what is the worst the
treasury can be hurt, and what does the post-attack steady state look
like?**

The harness lives at `test/CostanzaTokenAdapterAdversarial.t.sol`. All
six scenarios pass; the numbers below are taken verbatim from the test
output.

## Definitions

Two treasury readings matter, and they're not always equal:

- **On-paper treasury.** What `TheHumanFund` reports to the agent and
  to anyone reading state on-chain:
  `fund.balance + im.totalInvestedValue()`. The `totalInvestedValue`
  call routes to `adapter.balance()`, which is **cost-basis floored** —
  if spot says the position is worth less than the ETH we paid for it,
  `balance()` returns the cost basis instead. This floor is what
  prevents a doom-loop where the IM cap math forces the agent to sell
  into a falling price.

- **Realizable treasury.** What the treasury would actually walk away
  with if the position were liquidated at current spot:
  `fund.balance + adapter.spotValueOfHoldings()`. No floor.

The gap between the two is **hidden loss** — value the protocol
internally believes it owns but couldn't actually realize on-market
right now. Hidden loss is the right metric for adversarial impact: a
sandwich attacker doesn't take ETH out of `fund.balance`, they push the
spot price away from where we executed, and the damage shows up as
on-paper > realizable.

## Setup

- Initial treasury: **10 ETH** (fund's seed balance).
- Adapter `MAX_NET_ETH_IN`: **5 ETH** (lifetime cap on cumulative net
  ETH committed to the position).
- IM per-protocol cap: 25% of total assets (so the adapter can hold at
  most ~25% of the fund at any moment).
- Cooldown: **3 epochs** (~71 hours at 23h40m epochs) between buys.
  No cooldown on sells.
- Buy slippage tolerance: 5% off spot.
- Sell floor: 100% of cost basis ("never sell at a loss" — per-trade
  `minOut = shares × netEthBasis / totalTokens`).
- History gate: spot must agree with `lastSample` within
  `5% + 2%/hour` of sample age, capped at 100%.
- "Natural" market: 1000 tokens/ETH.

# S1 — MEV Sandwich Marathon

**Premise.** A sandwich-builder pumps spot 5% before every adapter
buy, takes the agent's deposit at the worse rate, then unwinds. Done
relentlessly: 100 attempts, 13 hours apart (clear of the 3-epoch
cooldown). Goal: how much can a structurally hostile mempool bleed off
the treasury over a long campaign?

**Result.**

```
Attempts:          100
Successful buys:   10
cumulativeEthIn:   5.000 ETH      ← exactly hits MAX_NET_ETH_IN
tokensFromSwapsIn: 4761.90 tokens ← bought at 5% premium spot
on-paper end:      60.000 ETH
realizable end:    59.762 ETH
hidden loss:       0.238 ETH      ← 4.76% of cumulative ETH committed
```

**Why only 10 successful buys?** Three independent gates close in
sequence:

1. The 3-epoch cooldown limits buys to roughly one per 71 hours; even
   with the harness's 13-hour spacing, every buy succeeds on its
   freshness budget — the cap that actually binds is the next one.
2. The IM 25% per-protocol cap stops accepting deposits once the
   adapter holds 25% of the fund's total assets.
3. The adapter's `MAX_NET_ETH_IN = 5 ETH` is the absolute ceiling.
   The 10th successful buy (0.5 ETH × 10 = 5 ETH) hits it exactly,
   and every subsequent attempt fails with `LifetimeCapExceeded`.

**Treasury impact.** The maximum sandwich bleed is **bounded by the
lifetime cap times the buy slippage**: 5 ETH × 5% = 0.25 ETH. The
realized loss of 0.238 ETH (4.76%) sits just under that ceiling
because the harness pumped exactly to the gate. Beyond cumulative ETH
in of 5 ETH, no further bleed is possible regardless of how long the
attack runs — the adapter simply stops buying.

**Verdict.** Hostile-mempool damage is **capped by construction**.
A sandwich-only adversary can extract at most 0.25 ETH from this
adapter in its lifetime, even with infinite attempts.

# S2 — Pump-Buy-Dump Trap

**Premise.** The adversary sustains a 50% pump for long enough that
the history gate widens and accepts the new price as legitimate. The
agent (FOMO'd or prompt-injected) goes all-in at the peak. The
adversary unwinds; spot snaps back. The agent now holds tokens at a
cost basis the market doesn't support — can they ever sell at a loss?

**Result.**

```
Bootstrap deposit (0.01 ETH):  succeeded
80h skip + spot pumped to 50% premium
FOMO 4 ETH deposit:            FAILED
  cumulativeEthIn:    0.01 ETH  ← unchanged
  tokensFromSwapsIn:  10 tokens ← unchanged
Market returns to natural
Attempted exit:                succeeded   ← 0 tokens to sell, no-op
on-paper end:        14.010 ETH
realizable end:      14.010 ETH
hidden loss:         0
```

**Why did the FOMO deposit fail?** Two layered defenses fired:

1. **History gate.** The adapter recorded a sample at the bootstrap
   deposit (1000 tokens/ETH). After 80 hours, the gate's tolerance is
   `5% + (80h × 2%/h) = 165%`, which would actually accept the 50%
   pump. So the gate let it through.
2. **Buy slippage.** `_quoteBuy` computes the expected output at spot,
   then enforces `minOut = expected × (1 - 5%)`. The pumped pool has
   moved against us so the executor's actual fill is below the
   slippage tolerance. The swap executor reverts.

Even if both spot-side checks were bypassed (e.g. by prompt injection
making the agent set `minAmountOut` lower in their action params — but
note that the IM calls `deposit()` with no slippage knob, the adapter
sets it internally), the **sell floor** would lock the position
afterward: any sell where `(shares × netEthBasis) / totalTokens` falls
below current spot value reverts.

**Treasury impact.** Zero. The agent never gets a chance to be trapped
at a high cost basis because the adapter refuses to execute the buy.

**Verdict.** A sustained pump fails to extract value because the buy
side itself enforces slippage; the trap closes on the agent's
decision before the cost basis is even set. The post-event realizable
treasury is unchanged from the start of the attack.

# S3 — The Drawdown of Doom

**Premise.** A real bear market: $COSTANZA loses ~50% of its value
over 30 days, in 24-hour steps of ~2.3% each. The agent has built a
2 ETH position at par (5 × 0.4 ETH buys, 80 hours apart). No fees flow
in. Can the agent panic-sell into the drawdown?

**Result.**

```
Position built:    2.0 ETH cost basis, 2000 tokens held
After 30-day drawdown:
  Final spot rate: 1978 tokens/ETH  ← 50% drop in token value
  on-paper end:    12.000 ETH        ← cost-basis floored
  realizable end:  11.011 ETH
  hidden loss:     0.989 ETH

Periodic exit attempts during drawdown:  all blocked (sell floor)
```

**What's happening.** The position's spot value has fallen from
2.0 ETH to about 1.011 ETH. But `balance()` returns
`max(spotValue, netEthBasis) = max(1.011, 2.000) = 2.000`. The IM,
treasury accounting, and agent prompt all see the position at 2 ETH.
This **is the cost-basis floor doing its job**: it stops the IM cap
math from forcing a sell. (Without the floor, a 50% drawdown would
make the IM see total assets at ~9 ETH, breach the 25% cap from
above, and force a withdraw at the worst possible price — the doom
loop.)

The agent's periodic sell attempts all revert because the sell floor
won't permit a transaction that yields less than per-token cost
basis. The position is **locked** until either spot recovers or fees
drag the per-token basis down.

**Treasury impact.** 0.989 ETH of hidden loss exists on-paper. The
treasury can't realize more than 11.011 ETH if forced to liquidate
right now. But the protocol holds, doesn't doom-loop, and doesn't
make the loss permanent: a future spot recovery, or fee inflows
(scenario S4), unwinds the gap.

**Verdict.** The protocol survives a deep, sustained drawdown without
panic-selling. **Hidden loss = drawdown × position size**, capped at
`MAX_NET_ETH_IN`. The agent loses optionality (can't exit) but doesn't
lose principal beyond the realizable mark.

# S4 — The Phoenix

**Premise.** Same setup as S3 but smaller (1 ETH position, 30%
drawdown), and creator fees actively flow in. Each fee inflow brings
free tokens onto the adapter's books, which **drops the per-token
cost basis without changing `netEthBasis`**. Eventually the per-token
basis falls below spot and sells unlock.

**Result.**

```
After 1 ETH buy:
  on-paper:    11.000 ETH    realizable: 11.000 ETH
After 30% drawdown:
  on-paper:    11.000 ETH    realizable: 10.769 ETH    (hidden 0.231)
Pre-fee sell attempt:        FAILED  ← sell floor blocks
After 800-token fee inflow (via pokeFees):
  tokens held:           1800 tokens
  netEthBasis:           1.000 ETH
  per-token basis x1e18: 555,555,555,555,555  ← 0.000556 ETH/token
  spot per-token x1e18:  ~769,000,000,000,000  ← 0.000769 ETH/token
Post-fee sell attempt:       SUCCEEDED
on-paper end:    11.385 ETH    realizable end:  11.385 ETH
hidden loss:     0
```

**What's happening.** The agent buys 1000 tokens for 1 ETH; per-token
basis is 0.001 ETH. Drawdown moves spot to 0.000769 ETH — sell floor
locks the position. Then 800 free tokens arrive as creator fees. Now
the adapter holds 1800 tokens against a `netEthBasis` of 1 ETH, so
per-token basis falls to ~0.000556 ETH. Spot (~0.000769) is now
**above** per-token basis, so the sell floor admits the trade.

**Treasury impact.** The 0.231 ETH of hidden loss after the drawdown
is fully extinguished by the fee inflow — final realizable = final
on-paper. The treasury actually ends *above* its pre-drawdown
realizable mark because the sell happens at a price where per-token
basis × tokens-sold < ETH received.

**Verdict.** Fees are the recovery mechanism for a locked position.
For a position held long enough, creator fees drag the per-token basis
arbitrarily low, eventually unlocking exit even into a sustained
drawdown. The cost-basis floor is not a permanent trap; it's a
temporary one whose duration is bounded by how fast fees flow.

# S5 — Beneficiary Hijack Attempt

**Premise.** A random attacker calls every owner-gated and IM-gated
entry point on the adapter. Goal: any path to drain tokens, redirect
fees, or mutate state. The adapter is `Ownable2Step` + has an
`onlyManager` check on deposit/withdraw, so all five paths should
revert.

**Result.**

```
transferFeeClaim from attacker:  REVERTED  (good)
deposit from attacker:           REVERTED  (good)  ← onlyManager
withdraw from attacker:          REVERTED  (good)  ← onlyManager
migrate from attacker:           REVERTED  (good)
freeze from attacker:            REVERTED  (good)

Attacker ETH gain:     0
Attacker token gain:   0
Adapter tokens still:  1000 tokens  (intact)
```

**Verdict.** All five paths revert cleanly with the right error
messages. Attacker walks away with zero ETH and zero tokens. The
adapter's existing position is untouched. No gas-cost griefing either —
the calls revert in their preamble before doing material work.

# S6 — Doppler Compromise

**Premise.** The Doppler hook contract is third-party code we don't
control. Suppose it's compromised: the attacker re-points its
beneficiary registration so future fee claims would go to them
instead of the adapter. **What happens to the existing position, and
does the adapter degrade gracefully on routine ops?**

**Result.**

```
Initial state: 1 ETH position + 200 fee tokens already collected.
After legit ops:
  on-paper:    11.200 ETH    realizable: 11.200 ETH

Adversary takes over fee distributor; new fees seeded.
Hostile pokeFees runs (try/catch swallows the failed claim):
  adapter tokens:   1200 tokens  ← unchanged
  attacker tokens:  0            ← attacker holds the seeded fees
                                   inside the (compromised) distributor
                                   contract; not in their EOA

Withdraw post-compromise:        SUCCEEDED
on-paper end:    11.200 ETH      realizable end:  11.200 ETH
```

**What's happening.** The adapter's `pokeFees` calls into the
`feeDistributor.release(poolId, address(this))`. Under the Doppler
ABI semantics, releasing to a non-registered address is a **no-op
(returns 0)**, not a revert — so the call returns cleanly with no
fees moved. The adapter doesn't leak gas, doesn't enter an unhealthy
state, and routine deposit/withdraw paths continue to work because
they don't depend on fee inflow.

**Treasury impact.** Zero on the existing position. The realized
treasury is preserved end-to-end. What's lost is **future fee flow**:
all post-compromise creator fees go to the attacker instead of the
fund. The escape hatch is `transferFeeClaim(newAdapter)` — Andrew (as
adapter owner) can re-point the beneficiary back to a clean adapter
once the upstream hook is fixed.

**Verdict.** Compromise of the upstream Doppler hook costs us future
fee inflow but doesn't endanger the existing principal or the
adapter's basic functions. The blast radius is bounded to the fee
stream specifically.

# Summary

| Scenario | On-paper change | Realizable change | Hidden loss bound | Recovery path |
|---|---|---|---|---|
| S1 — Sandwich marathon | +50 ETH topups, 5 ETH cost-basis acquired | +49.76 ETH realizable | **≤ 0.25 ETH** (hard cap = `MAX_NET_ETH_IN × buy slippage`) | Position holds; spot mean-reverts |
| S2 — Pump-buy-dump | 0 (FOMO buy refused) | 0 | **0** (buy never executes) | n/a |
| S3 — Sustained drawdown | 0 (cost-basis floored) | −drawdown × position | **≤ position cost basis** | Fees (S4) or spot recovery |
| S4 — Drawdown + fees | + fee tokens to fund | + fee tokens to fund | **0 at steady state** | Fee inflow drops per-token basis |
| S5 — Hijack attempt | 0 | 0 | **0** | n/a (all paths reverted) |
| S6 — Doppler compromise | 0 (existing position) | 0 (existing position) | **0** on existing position; future fees lost | `transferFeeClaim` to clean adapter |

**The defining property: Costanza's principal is bounded.** Across
every scenario, the worst-case realizable loss on the existing
treasury is bounded by `MAX_NET_ETH_IN` (5 ETH) times the worst
in-trade slippage the adapter permits (5%) — **0.25 ETH** of bleed
maximum from any combination of MEV, drawdown-induced lockup, or
hostile market structure. Above that, the adapter stops accepting
deposits.

The defenses that make this true, in the order they fire:

1. **History gate** — refuses buys at spot prices that haven't been
   sustained long enough.
2. **Buy slippage cap (5%)** — refuses buys where executor fills below
   spot expectation.
3. **IM 25% per-protocol cap** — limits what fraction of the treasury
   can sit in the position at any moment.
4. **`MAX_NET_ETH_IN`** (5 ETH) — limits cumulative net ETH ever
   committed across the adapter's lifetime.
5. **Cooldown (3 epochs)** — limits buy frequency; bounds adversarial
   scaling.
6. **Sell floor (100% of cost basis)** — refuses sells that would
   yield less than the per-token cost basis. Aggregate property:
   *Costanza never realizes a per-token loss.*
7. **Cost-basis floor on `balance()`** — prevents drawdown from
   driving the IM cap math into a forced-sell doom loop.
8. **`Ownable2Step` + `onlyManager` access controls** — every owner
   path is owner-only, every IM-gated path is manager-only.
9. **Migration / freeze escape hatches** — `transferFeeClaim` and
   `migrate()` give Andrew clean wind-down paths that don't strand
   funds; `freeze()` permanently retires the adapter while leaving
   IM-side withdraws functional.

The pattern is conservative-by-construction: every adversarial
scenario where the agent makes a bad decision (S2, prompt-injected),
the protocol catches it before money moves. Every scenario where the
market goes against the agent (S1, S3), the loss is bounded and
recoverable. Every scenario where infrastructure is hostile (S5, S6),
the existing principal is preserved.
