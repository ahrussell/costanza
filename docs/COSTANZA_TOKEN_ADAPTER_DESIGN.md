# CostanzaTokenAdapter — Design Doc

**Status:** Implementation in progress. Open questions in §6 should be resolved before mainnet deploy but do not block writing/testing the contract against mocks.

**Scope:** A new `IProtocolAdapter` registered with the existing `InvestmentManager`. Lets the agent take a position in the $COSTANZA token launched by a third party, and auto-routes creator-fee inflows from that token's fee distributor back to the fund treasury.

**Venue:** $COSTANZA is a Uniswap **V4** pool on Base. The adapter reads TWAP from a pool-attached oracle hook and swaps via UniversalRouter. The hook ABI and pool address are open questions deferred to deploy time.

**Constraint:** `TheHumanFund` and `InvestmentManager` are immutable on Base mainnet. We deploy a new adapter and have the IM admin call `addProtocol`. Nothing else.

---

## 1. Background

The Human Fund holds an existing IM with five blue-chip yield adapters (Aave, Lido, Coinbase, Compound, Morpho). All five have smooth value curves denominated in ETH-equivalent.

Independently, a third party launched the $COSTANZA token on Base. By the launch's design, a fraction of trading fees accrue to the creator wallet as $COSTANZA + WETH. These are currently being claimed manually and forwarded to the fund as donations.

We want:
1. **Automate the fee claim** — fees flow back to the treasury without manual ops.
2. **Let the agent buy/sell its own token** — via the existing IM `invest`/`withdraw` action types, with no contract changes elsewhere.

The mechanism: a sixth adapter in the IM, plus a one-time re-pointing of the upstream fee-claim recipient to the new adapter.

## 2. Goals & Non-Goals

### Goals
- Auto-claim creator fees and route to the fund treasury.
- Bound exposure tightly enough that no single agent decision (or adversarial prompt) can meaningfully drain the treasury.
- Give the human owner exactly one operational lever — the ability to re-route the fee-claim destination — and a one-way commitment to give it up forever (`freeze()`).
- Adapter outlives the human's involvement: post-freeze, no off-chain operator is needed.

### Non-Goals
- LP provision ($COSTANZA/WETH pair). Memecoin/ETH LP is the textbook worst-case for IL, and turning the treasury into the dominant LP for its own market has rug-like exit optics.
- Off-chain MEV protection (CowSwap, Flashbots Protect). On-chain swaps with hardcoded bounds is v1; revisit only if losses prove material.
- Bounds setters / ratchets. All bounds are immutable constants. If a bound is wrong, redeploy and migrate.
- Per-protocol cap configurability inside the IM. The adapter enforces an absolute cap on top of the IM's existing percentage cap.
- Surfacing freeze state to the agent's prompt. The IM-level immutability narrative covers it; over-explaining adds noise.

## 3. Architecture

```
┌──────────────────────┐
│  TheHumanFund (live) │ ← receive() catches fee inflow + swap proceeds
└──────────┬───────────┘
           │ invest / withdraw (action types 3/4)
           ▼
┌──────────────────────┐
│ InvestmentManager    │ ← global 25% / 80% / 20% bounds (live)
└──────────┬───────────┘
           │ adapter.deposit / withdraw / balance
           ▼
┌──────────────────────┐    ┌───────────────────┐
│ CostanzaTokenAdapter │◄───┤ Upstream fee dist │ (recipient set once)
└────┬──────────┬──────┘    └───────────────────┘
     │ swap     │ pokeFees / auto-claim on every adapter call
     ▼          ▼
┌─────────┐  ┌──────────────────┐
│  V4     │  │ fund.receive()   │
│  pool   │  └──────────────────┘
└─────────┘
```

The adapter is the only new contract. V4 plumbing (PoolManager state reads, UniversalRouter swaps, oracle hook reads) is hidden behind small abstraction interfaces (`IPoolStateReader`, `ISwapExecutor`, `IPoolOracle`, `IFeeDistributor`) so the adapter is testable against mocks. Production wrappers around the real V4 contracts land in a follow-up once the open questions in §6 are resolved.

## 4. The Defense Profile

Buy and sell paths share the same manipulation gate (spot-vs-TWAP); they differ in the slippage anchor — buys anchor to TWAP-expected output, sells anchor to per-token cost basis (which uniquely makes sense for the sell side, where "what we paid" is a meaningful reference).

### 4.1 The IM cap is dynamic — that's why we need internal bounds too

The IM enforces a 25%-of-treasury cap on each protocol's `adapter.balance()` value, recomputed live every deposit. As the treasury grows, the cap expands; as a position appreciates, the cap fills up.

Two consequences:
- **The cap doesn't durably bound exposure.** A 100×-larger treasury permits a 100×-larger position. Acceptable for blue-chip yield adapters; not what we want for a memecoin. The adapter therefore carries its own `MAX_NET_ETH_IN` — an absolute lifetime ceiling on net ETH at risk.
- **A drawdown shrinks the position's reported value, which expands cap headroom.** Without a defense, a price crash unlocks more cap room precisely when we don't want the agent buying. This is the doom-loop the cost-basis floor in §4.3 defeats.

### 4.2 Buy side: spot-TWAP gate + IM cap + cost-basis floor + lifetime cap + cooldown

A buy is gated by:

| Defense | What it does |
|---|---|
| **Spot-vs-TWAP (10%)** | Refuses to trade if current spot is more than 10% off the 30-min TWAP — catches flash-loan-shaped manipulation. Loose enough to accommodate normal directional drift; tight enough to catch the obvious attack shape. |
| **IM 25%-of-treasury cap** | Existing IM logic. With the cost-basis floor in `balance()`, drawdowns can't expand this. |
| **Lifetime cap (`MAX_NET_ETH_IN`)** | Absolute ceiling on `cumulativeEthIn - cumulativeEthOut`. Once this fills, no more buys until the agent exits and frees headroom. Caps the adapter's *current* net exposure, not lifetime gross spending — recyclable through profitable round-trips. |
| **Cooldown (3 epochs)** | After a deposit in epoch N, the next allowed deposit is in epoch N+3. Bounds damage rate in worst-case prompt-injection scenarios. |
| **Buy-side slippage (15%)** | The swap's `amountOutMinimum` is set at TWAP × 85%. A more adverse fill reverts. |

### 4.3 Cost-basis floor on `balance()` — the load-bearing defense

`balance()` returns `max(twapValue, netEthBasis)`. Asymmetric on purpose:

- **Pump:** `balance()` reflects the higher TWAP value. The IM's per-protocol cap accordingly says "this position is now larger than 25% of treasury" — blocks further buys at the high (no FOMO).
- **Drawdown:** `balance()` floors at cost basis. The IM cap continues to view the position at its purchased value, so a price crash can't manufacture cap headroom for averaging down.

`balance()` is wrapped in `try/catch` around the oracle call — pool death or oracle staleness fall back to the floor and never revert. The IM's snapshot path requires `balance()` to never revert; this is non-negotiable.

**Implication for the agent's mental model:** during a real drawdown, the agent sees `current_value` (the IM-exposed view) at cost basis, not at TWAP. The agent over-estimates the position's market value. The `description` text registered with `addProtocol` should disclose this so the agent's reasoning accounts for it.

### 4.4 Sell side: spot-vs-TWAP gate + cost-basis sell floor

Sells are gated by two checks. The first is the same spot-vs-TWAP gate as on buys (10% threshold) — it catches manipulation regardless of cost basis. The second is a cost-basis-anchored slippage floor:

```
minOut(shares) = (shares × netEthBasis × 80%) ÷ totalTokens
```

Where `totalTokens` is the full adapter balance (including fee tokens received at zero cost). The agent never sells more than 20% below per-token overall cost basis.

Why both:

- **The spot-vs-TWAP gate alone wouldn't be a slippage bound** — it just verifies the pool isn't currently manipulated. It says nothing about how unfavorable the realized fill is.
- **The cost-basis floor alone has a gap.** When cost basis is far below TWAP (cheap entry, or fee-diluted basis), an attacker can manipulate spot down to a price still above the floor and extract a large slice of the TWAP value before the floor fires. The gate closes that gap.

Behaviors that fall out:

- **Mid-position:** sells get expected value back ± 20% off cost basis, gated by 10% spot deviation.
- **Fee accrual lowers the floor:** as fee tokens pile up (zero-cost additions), per-token basis drops. The agent has more room to liquidate as the position becomes more profitable through fees.
- **House-money mode (`netEthBasis = 0`):** after a profitable full exit, the cost-basis floor evaluates to zero. The spot-vs-TWAP gate is the only protection — but principal is no longer at risk, and the gate still bounds extraction by manipulation to ~10% of TWAP value per attack.

The slippage anchors differ across sides on purpose: buys anchor to TWAP (we don't have a "what we paid" reference yet), sells anchor to cost basis (we do). The manipulation gate is identical on both sides.

### 4.5 Defenses we considered and dropped

- **Drawdown lockout** (refuse buys when TWAP < avgEntry × (1 − x)). The cost-basis floor + cooldown + lifetime cap together cover the "agent prompted to average down during a crash" scenario. The lockout was redundant.
- **Per-tx pool size cap.** Was a proxy for impact-bounding. The slippage floors (`amountOutMinimum`) on both buy and sell achieve the same with cleaner semantics. V4 also makes the impact math harder to compute precisely.
- **Tight (1-2%) slippage.** Caused frequent reverts on a memecoin pool. Loosened to 15% on buy and 20%-off-cost-basis on sell — wide enough that healthy markets pass, narrow enough that a real attack reverts.

## 5. Lifecycle: Deploy → Operate → Freeze

**Deploy.** Deploy adapter with all immutables set. Owner = deployer EOA.

**Hand off ownership to Safe.** Two-step transfer (`Ownable2Step`) — deployer initiates, Safe accepts. Prevents fat-fingered ownership loss.

**Register with IM.** Fund admin calls `investmentManager.addProtocol(adapter, name, description, riskTier=4, expectedApyBps=0)`. The description is **write-once** — it's exposed to the agent every epoch, so it's worth crafting deliberately.

**Re-point fee recipient.** Owner calls `transferFeeClaim(adapterAddress)` (or upstream-specific equivalent — see §6). From here, fees flow into the adapter automatically.

**Operate.** Costanza acts on the adapter via action types 3/4. Anyone can call `pokeFees()` between Costanza's actions to drain fees and earn a 2% tip. Owner has no ongoing duties; can re-point fee claim if migrating to a v2 adapter.

**Migrate (if needed).** If a flaw is found: register a replacement adapter, deactivate the old one via `setProtocolActive(false)` (allows withdraws but not deposits), and re-point fee claim. Costanza naturally drains the old position over time. Existing $COSTANZA tokens stay in the old adapter until the agent withdraws — migration moves *flow*, not *stock*.

**Freeze.** Owner calls `freeze()`. Ownership is renounced (`owner == address(0)`). After this, no `onlyOwner` function ever executes again. `deposit`/`withdraw`/`balance`/`pokeFees` continue to work indefinitely. This is the immutability commitment.

## 6. Open Questions

These don't block review or testing-against-mocks, but block deploy.

**1. Upstream fee-claim primitive.** Determines `transferFeeClaim`'s shape:
- Clanker `claim(recipient)` style → `transferFeeClaim` is meaningless on-chain; remove it.
- `setRecipient(address)` admin pattern → as currently drafted.
- LP-NFT-based fee accrual → adapter holds the NFT; `transferFeeClaim` becomes "transfer the NFT."
- Something else → TBD.

**2. `MAX_NET_ETH_IN` value.** Constructor arg. Trade-off: tight enough that worst-case loss is recoverable from donation/fee inflow within a reasonable timeframe; loose enough to be a meaningful position. Probably in the 1-10 ETH band.

**3. Pool oracle hook details.** Need:
- The hook contract address.
- Confirmation that the hook supports a 30-min lookback window.
- The exact ABI shape (we currently assume `consultSqrtPriceX96(poolId, secondsAgo)` — adjust the `IPoolOracle` interface if real ABI differs, or write a thin wrapper).

**4. PoolKey + V4 contract addresses on Base.** PoolManager, UniversalRouter, the `(currency0, currency1, fee, tickSpacing, hooks)` for the actual $COSTANZA pool. Plus production V4 wrapper contracts for `IPoolStateReader` and `ISwapExecutor`.

**5. Description text for `addProtocol`.** Write-once, on-chain, agent-visible every epoch. Should communicate self-reference, that holding is speculative (not yield), and the cost-basis-floor caveat from §4.3 (so the agent's withdraw math accounts for the apparent vs. realizable value gap during drawdowns).

## 7. Adversarial Scenarios

### Sandwich attacker on a routine buy
Buy-side slippage floor reverts the swap if execution drops more than 15% below TWAP. Per-trade max extraction is bounded; cooldown limits frequency.

### Flash-loan pool manipulation
Adversary pushes spot 20%+ off TWAP via flash loan. The spot-vs-TWAP gate (10%) reverts the deposit immediately. Even if they could sustain manipulation across the full TWAP window (expensive — every block another arb risks unwinding), the cost-basis floor in `balance()` separately prevents the doom-loop where a depressed mark-to-market expands the IM's cap headroom.

### Free-fall + prompt injection averaging-down
$COSTANZA enters a real downtrend; donor messages try to talk Costanza into "buying the dip." Defenses, in order: cost-basis floor in `balance()` keeps the IM cap tight (no expanded headroom from the drawdown); cooldown limits to one buy per 3 epochs; lifetime cap bounds total ETH ever at risk. The agent can buy the dip — but only at bounded frequency and total exposure. The asymmetric "buying the dip is fine; getting drained is not" framing is intentional.

### Pump cycle, position appreciates
`balance()` reflects the higher TWAP value. IM 25% cap saturates and refuses further buys (no FOMO). Sells go through normally — sell floor is well below TWAP value, doesn't bind. As fees accrue during high trading volume, the per-token cost basis drops further, giving the agent more room to take profit.

### Owner backdoor pre-freeze
Inventory of `onlyOwner` functions: `transferOwnership` (sets pending only), `transferFeeClaim` (re-routes future fee inflow), `freeze`. Owner cannot call `deposit`/`withdraw`, has no token-sweep primitive, cannot change bounds. Worst case pre-freeze: re-point fee claim to attacker — future fee income is stolen, existing position untouched.

### Owner backdoor post-freeze
`owner == address(0)`. Every `onlyOwner` function reverts. No re-init path exists (`Ownable._transferOwnership` is internal and only reachable from `freeze`/`acceptOwnership`/`renounceOwnership`, all of which require an owner). Provably zero owner power post-freeze.

### Upstream fee distributor compromise
Adversary takes over the fee distributor, redirects future fees to themselves. Adapter's fee inflow stops; existing position is unaffected. `pokeFees()` claims zero. No revert. Recovery requires the upstream to be fixed; we have no on-chain remedy.

### Reentrancy via fee claim
External calls in `_claimAndForwardFees` (claim, WETH unwrap, fund.receive(), tip transfer). All adapter entry points (`deposit`, `withdraw`, `pokeFees`) are `nonReentrant`. CEI ordering on the tip transfer. Malicious upstream that re-enters into the adapter hits the guard.

### Pool death (oracle reverts, liquidity drained)
`balance()` falls back to cost basis (try/catch around oracle). IM snapshot path stays valid; cap still bounds correctly. Both `deposit` and `withdraw` revert via the spot-vs-TWAP gate (oracle reverts → gate can't evaluate → revert). Position is stranded but on-paper non-zero. Pool death is a $COSTANZA-existential event; the project would have bigger problems than a stranded adapter position.

### Migration race
`transferFeeClaim` and `pokeFees` race within a block: tx-level ordering decides which adapter receives the in-flight fees. Either path is benign — neither permits double-claim, and a stale `pokeFees` against the old adapter just claims zero.

### DoS on `pokeFees`
Permissionless tip is self-balancing. Empty pokes cost the caller gas with no effect. Front-running tips creates a competitive keeper market — fees still reach the fund, gas reimbursement just goes to whoever wins the race.

## 8. Testing Plan

Critical tests; full breakdown in `test/CostanzaTokenAdapter.t.sol`. Showstoppers in **bold**.

- **`balance()` snapshot path safety:** must never revert. Tested under: pool alive, pool drained, oracle reverting, zero balance, large balance.
- **Cross-stack hash parity:** `test/CrossStackHash.t.sol` verifies Solidity and Python compute identical input hashes with the adapter registered.
- **Cost-basis floor:** TWAP drops below cost; `balance()` returns the floor; IM cap math accounts correctly.
- **Buy-side bounds:** spot-vs-TWAP gate, cooldown, lifetime cap, slippage — each fires in its expected scenario.
- **Sell-side bounds:** spot-vs-TWAP gate (mirrors buy side); cost-basis sell floor — rejects below-cost sells, allows sells within margin, scales with fee accrual, drops to zero in house-money mode.
- **Reset rule:** profitable round-trip resets accumulators; loss round-trip does not.
- **Owner controls:** transferFeeClaim, freeze, post-freeze immutability.
- **Reentrancy:** malicious upstream re-entering each entry point — guards hold.
- **Migration:** dual-adapter setup with transferFeeClaim re-pointing.
- **Mainnet fork (placeholder until real addresses are known):** smoke test against real V4 pool, oracle hook, fee distributor.

## 9. Gas Budget

`deposit` median ~190k, max ~215k. `withdraw` median ~150k, max ~185k. `pokeFees` median ~70k. `balance()` view ~16k. All comfortably within `GAS_SUBMIT_RESULT` headroom in the prover client; no bump needed.
