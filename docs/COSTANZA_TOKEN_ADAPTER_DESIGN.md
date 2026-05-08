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
- Give the human owner two operational levers — re-route the fee-claim destination, and migrate the entire position to a successor adapter — plus a one-way `freeze()` to give both up forever.
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

The adapter is the only new contract. V4 plumbing (PoolManager state reads, UniversalRouter swaps) is hidden behind small abstraction interfaces (`IPoolStateReader`, `ISwapExecutor`, `IFeeDistributor`) so the adapter is testable against mocks. Production wrappers around the real V4 contracts land in a follow-up once the open questions in §6 are resolved.

The pool has no on-chain TWAP oracle (V4 dropped that as built-in; the Doppler hook attached to the $COSTANZA pool isn't an oracle hook). The adapter therefore operates in **pure-spot mode** — it reads current spot from the PoolManager and applies a freshness-aware deviation gate against its own history of stored samples for manipulation defense. See §4.4.

## 4. The Defense Profile

The buy side is anchored to current spot for slippage and to the agent's stored history for manipulation defense. The sell side is anchored to per-token cost basis — Costanza never sells at a loss on an individual trade.

### 4.1 The IM cap is dynamic — that's why we need internal bounds too

The IM enforces a 25%-of-treasury cap on each protocol's `adapter.balance()` value, recomputed live every deposit. As the treasury grows, the cap expands; as a position appreciates, the cap fills up.

Two consequences:
- **The cap doesn't durably bound exposure.** A 100×-larger treasury permits a 100×-larger position. Acceptable for blue-chip yield adapters; not what we want for a memecoin. The adapter therefore carries its own `MAX_NET_ETH_IN` — an absolute lifetime ceiling on net ETH at risk.
- **A drawdown shrinks the position's reported value, which expands cap headroom.** Without a defense, a price crash unlocks more cap room precisely when we don't want the agent buying. This is the doom-loop the cost-basis floor in §4.3 defeats.

### 4.2 Buy side: spot-vs-history gate + IM cap + cost-basis floor + lifetime cap + cooldown

A buy is gated by:

| Defense | What it does |
|---|---|
| **Spot-vs-history gate** | At trade time, current spot must be within a freshness-scaled tolerance of the most recent stored sample. Tolerance = `BASE (5%) + age × DRIFT (2%/hour)`, capped at 100% (above which the check no-ops). Catches flash-loan-shaped manipulation when activity is recent; widens gracefully so legitimate long-window drift passes. See §4.4. |
| **IM 25%-of-treasury cap** | Existing IM logic. With the cost-basis floor in `balance()`, drawdowns can't expand this. |
| **Lifetime cap (`MAX_NET_ETH_IN`)** | Absolute ceiling on `cumulativeEthIn - cumulativeEthOut`. Once this fills, no more buys until the agent exits and frees headroom. Caps the adapter's *current* net exposure, not lifetime gross spending — recyclable through profitable round-trips. |
| **Cooldown (3 epochs)** | After a deposit in epoch N, the next allowed deposit is in epoch N+3. Bounds damage rate in worst-case prompt-injection scenarios. |
| **Buy-side slippage (5%)** | The swap's `amountOutMinimum` is set at expected_at_spot × 95%. A more adverse fill reverts. Per-trade execution bound only — manipulation defense is the history gate. |

### 4.3 Cost-basis floor on `balance()` — the load-bearing defense

`balance()` returns `max(spotValue, netEthBasis)`. Asymmetric on purpose:

- **Pump:** `balance()` reflects the higher spot value. The IM's per-protocol cap accordingly says "this position is now larger than 25% of treasury" — blocks further buys at the high (no FOMO).
- **Drawdown:** `balance()` floors at cost basis. The IM cap continues to view the position at its purchased value, so a price crash can't manufacture cap headroom for averaging down.

`balance()` is wrapped in `try/catch` around the spot read — pool death or state-reader failure falls back to the floor and never reverts. The IM's snapshot path requires `balance()` to never revert; this is non-negotiable.

**Implication for the agent's mental model:** during a real drawdown, the agent sees `current_value` (the IM-exposed view) at cost basis, not at spot. The agent over-estimates the position's market value. The `description` text registered with `addProtocol` should disclose this so the agent's reasoning accounts for it.

### 4.4 Spot-vs-history gate (manipulation defense)

The adapter stores a single `lastSample` of `(timestamp, sqrtPriceX96)`. Updated after every successful `deposit`, `withdraw`, and `pokeFees` — these are the calls that touch the pool, so they're natural sampling points. The gate is checked at the start of `deposit` and `withdraw` (after fee claim, before swap):

```
allowed_bps = SPOT_DEVIATION_BASE_BPS (500)
            + sample_age_seconds × SPOT_DEVIATION_DRIFT_PER_HOUR_BPS (200) / 3600
```

If `allowed_bps >= 10000` (100%), the check no-ops — at extreme ages the gate would be meaningless. If no sample exists yet (bootstrap), the check no-ops and the action records the first sample. Otherwise current spot must be within ±`allowed_bps` of the stored sample, else `SpotDeviationExceeded`.

Curve at a glance:

| Sample age | Allowed deviation |
|---|---:|
| 0 — just sampled | 5% |
| 1 hour | 7% |
| 6 hours | 17% |
| 24 hours | 53% |
| 50 hours | ~100% (capped) |
| 3+ days | no check |

What this catches: flash-loan-style multi-block manipulation where current spot diverges sharply from a recent stored sample. What it doesn't catch: single-block manipulation where the same tx that records a sample is also the manipulator's tx. The bound is honest about its limit.

What this loses vs. a true TWAP: when the buffer is stale (no recent activity), the gate is essentially absent. Our mitigation is that any keeper or arbitrageur calling `pokeFees` for the 2% tip naturally refreshes the sample as a side effect, plus permissionless `sample()` is cheap to add later if real activity proves too sparse.

### 4.5 Sell side: spot-vs-history gate + cost-basis sell floor

Sells are gated by two checks. The history gate (§4.4) catches manipulation. The cost-basis floor anchors per-trade execution:

```
minOut(shares) = shares × netEthBasis ÷ totalTokens
```

(`SELL_FLOOR_BPS = 0` — no margin.) Where `totalTokens` is the full adapter balance, including fee tokens received at zero cost. **Costanza never takes a loss on an individual sell** — every trade yields at least the per-token cost basis. The aggregate property is even stronger: across a full position liquidation, total ETH out is at minimum equal to total ETH in (the worst-case round-trip is breakeven, never a loss).

Behaviors that fall out:

- **Mid-position:** sells require execution at-or-above per-token cost basis. A real drawdown locks the position until either the price recovers above cost or fees accrue enough to lower per-token basis.
- **Fee accrual lowers the floor:** as fee tokens pile up at zero cost, per-token overall basis (`netEthBasis / totalTokens`) drops. The position becomes liquidatable at lower spot prices over time.
- **Profitable partial exits ratchet the floor down:** after a partial-sell-at-profit, `netEthBasis` decreases proportionally. Subsequent sells can clear at lower prices than the first sell required.
- **House-money mode (`netEthBasis = 0`):** after a fully profitable round-trip, the cost-basis floor evaluates to zero. The history gate is the only protection — but principal is no longer at risk; the worst case is leaving some value on the table to a sandwich.

The trade-off: a position can become permanently illiquid in a sustained deep drawdown without enough fee inflow to dilute basis. We accepted this as the price of the "never sell at a loss" identity.

### 4.6 Defenses we considered and dropped

- **TWAP-based manipulation gate.** The Doppler hook isn't an oracle hook; V4 doesn't bake observations into the pool itself. Our spot-vs-history gate is a coarser substitute — strong when activity is fresh, absent when stale. The simpler alternative.
- **Drawdown lockout** (refuse buys when price < avgEntry × (1 − x)). The cost-basis floor + cooldown + lifetime cap together cover the "agent prompted to average down during a crash" scenario. The lockout was redundant.
- **Per-tx pool size cap.** Was a proxy for impact-bounding. The slippage floors (`amountOutMinimum`) on both buy and sell achieve the same with cleaner semantics. V4 also makes the impact math harder to compute precisely.
- **Tight (1-2%) slippage.** Caused frequent reverts on a memecoin pool. The buy side runs 5% off spot; the sell side has no margin (must yield ≥ cost basis), but fees relax the floor over time.

## 5. Lifecycle: Deploy → Operate → Freeze

**Deploy.** Deploy adapter with all immutables set. Owner = deployer EOA.

**Hand off ownership to Safe.** Two-step transfer (`Ownable2Step`) — deployer initiates, Safe accepts. Prevents fat-fingered ownership loss.

**Register with IM.** Fund admin calls `investmentManager.addProtocol(adapter, name, description, riskTier=4, expectedApyBps=0)`. The description is **write-once** — it's exposed to the agent every epoch, so it's worth crafting deliberately.

**Re-point fee recipient.** Owner calls `transferFeeClaim(adapterAddress)` (or upstream-specific equivalent — see §6). From here, fees flow into the adapter automatically.

**Operate.** Costanza acts on the adapter via action types 3/4. Anyone can call `pokeFees()` between Costanza's actions to drain fees and earn a 2% tip. Owner has no ongoing duties; can re-point fee claim if migrating to a v2 adapter.

**Migrate (if needed).** If a flaw is found, the owner calls `migrate(newAdapter)`. Atomic: pulls any pending fees, transfers the entire $COSTANZA token balance to the successor, re-points the upstream fee distributor at the successor, forwards any held WETH/ETH to the fund, and zeroes the v1 adapter's accumulators so its `balance()` returns 0 (no phantom value in IM cap math). The successor's constructor takes an `InitialState` struct carrying v1's accumulators (`cumulativeEthIn`, `cumulativeEthOut`, `tokensFromSwapsIn`, `tokensFromSwapsOut`, `lastDepositEpoch`) — read from v1's public getters — so cost basis, lifetime cap, cooldown, and reset-rule semantics carry over unchanged. Stock and flow both move; nothing strands.

After `migrate` runs, v1's `deposit` reverts (`AdapterMigrated`), `withdraw` becomes a no-op that returns 0 (lets the IM drain its `pos.shares` accounting normally), `pokeFees` short-circuits, and `balance()` reports 0. The IM admin separately marks v1 as inactive (`setProtocolActive(v1, false)`) so the agent's snapshot view is tidy, but it's belt-and-suspenders — v1's reported value is already 0.

**Freeze.** Owner calls `freeze()`. Ownership is renounced (`owner == address(0)`). After this, no `onlyOwner` function ever executes again — including `transferFeeClaim` and `migrate`. `deposit`/`withdraw`/`balance`/`pokeFees` continue to work indefinitely. Once you freeze, the adapter is whatever it is, forever; that's the immutability commitment, and it's why you should be confident in the adapter before pulling the lever.

## 6. Open Questions

These don't block review or testing-against-mocks, but block deploy. Some are partially answered from on-chain investigation of the actual $COSTANZA token (`0x3D9761a43cF76dA6CA6b3F46666e5C8Fa0989Ba3` on Base) — its launch is via Doppler (a Liquidity Bootstrapping Auction protocol on V4).

**1. Upstream fee-claim primitive (Doppler hook ABI).** The pool's hook is `DopplerHookInitializer` at `0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544` (verified on Basescan). Relevant functions identified: `release(bytes32 poolId, address beneficiary)` for claiming, `updateBeneficiary(bytes32 poolId, address newBeneficiary)` for migrating the claim. Mapping to our adapter:
- `IFeeDistributor.claim()` → wraps `release(poolId, address(this))`.
- `IFeeDistributor.setRecipient(addr)` → wraps `updateBeneficiary(poolId, addr)`.

Setup is one-time manual: the current beneficiary (initially Andrew's wallet) calls `updateBeneficiary` to register the adapter. The adapter then drives both operations going forward. Need to confirm exact authority semantics (who can call `updateBeneficiary` — current beneficiary only, or any registered party?) by reading the verified hook source.

**2. `MAX_NET_ETH_IN` value.** Set to **5 ETH**. Constructor arg.

**3. Pool oracle hook.** Resolved as "no oracle." The Doppler hook isn't an oracle hook, and V4 doesn't bake observations into the pool itself. The adapter operates pure-spot with a freshness-aware history gate (§4.4). `IPoolOracle` was dropped from the interface set.

**4. PoolKey + V4 contract addresses on Base.** Resolved:
- **PoolManager**: `0x498581ff718922c3f8e6a244956af099b2652b2b`
- **UniversalRouter**: `0x6fF5693b99212Da76ad316178A184AB56D299b43`
- **PoolKey**: `currency0 = 0x3D9761a43cF76dA6CA6b3F46666e5C8Fa0989Ba3` (Costanza), `currency1 = 0x4200000000000000000000000000000000000006` (WETH), `fee = 8388608` (V4's dynamic-fee sentinel — actual fee ~0.7% post-LBA), `tickSpacing = 200`, `hooks = 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544`
- **PoolId**: `0x1d7463c5ce91bdd756546180433b37665c11d33063a55280f8db068f9af2d8cc`
- **`tokenIsCurrency0 = true`** (Costanza's address sorts lower than WETH's). Contract handles this branch; tested.
- Still TBD: production wrapper contracts for `IPoolStateReader` and `ISwapExecutor` (small wrappers around PoolManager.extsload and UniversalRouter respectively).

**5. Description text for `addProtocol`.** Resolved. Registration call uses `riskTier = 4` ("HIGH" — the highest tier the enclave's prompt builder maps; no other tier-4 protocol exists, so the slot is uncontested). Description string:

> Your own memecoin, $COSTANZA. Speculative — buy/sell via deposit/withdraw; trading fees from other holders accrue to the fund and lower your per-token cost basis. The contract won't sell below cost basis, so a position can be locked during drawdowns. Lifetime cap: 5 ETH.

`expectedApyBps = 0` — informational only; trading-fee inflow is unpredictable and shouldn't be projected as APY.

## 7. Adversarial Scenarios

### Sandwich attacker on a routine buy
Buy-side slippage floor reverts the swap if execution drops more than 5% below the spot reading at minOut-computation time. Per-trade max extraction bounded by that 5% × trade size; cooldown limits frequency.

### Flash-loan pool manipulation across blocks
Adversary pumps spot 20%+ off the most recent stored sample via a sustained multi-block flash loan. The spot-vs-history gate widens with sample age but never enough to wave through a 20% jump within a few hours. Adapter rejects the trade. Even if the manipulation slips through the gate (very stale sample), the cost-basis floor in `balance()` separately prevents the doom-loop where a depressed mark-to-market expands the IM's cap headroom.

### Single-block MEV (the gap we accept)
Attacker controls a tx that pumps the pool, lands the agent's deposit at the pumped spot, and unwinds — all in one block. The adapter's most recent sample isn't from before the manipulation, so the history gate has no pre-attack reference. Bound: per-trade impact capped at 5% by the slippage anchor; cooldown caps frequency to 1 buy per 3 epochs; lifetime cap caps cumulative damage at `MAX_NET_ETH_IN × 5%`. Acceptable accepted risk.

### Free-fall + prompt injection averaging-down
$COSTANZA enters a real downtrend; donor messages try to talk Costanza into "buying the dip." Defenses, in order: cost-basis floor in `balance()` keeps the IM cap tight (no expanded headroom from the drawdown); cooldown limits to one buy per 3 epochs; lifetime cap bounds total ETH ever at risk. The agent can buy the dip — but only at bounded frequency and total exposure. The asymmetric "buying the dip is fine; getting drained is not" framing is intentional.

### Pump cycle, position appreciates
`balance()` reflects the higher spot value. IM 25% cap saturates and refuses further buys (no FOMO). Sells go through normally — sell floor is well below spot value, doesn't bind. As fees accrue during high trading volume, the per-token cost basis drops further, giving the agent more room to take profit.

### Sustained drawdown without fee accrual
Position locked at cost basis (sell floor blocks). No exit until either (a) price recovers above cost or (b) fees accrue enough to lower per-token basis below current spot. Trade-off accepted with the "never sell at a loss" framing — principal isn't lost, but it can be illiquid for an extended period.

### Owner backdoor pre-freeze
Inventory of `onlyOwner` functions: `transferOwnership` (sets pending only), `transferFeeClaim` (re-routes future fee inflow), `freeze`. Owner cannot call `deposit`/`withdraw`, has no token-sweep primitive, cannot change bounds. Worst case pre-freeze: re-point fee claim to attacker — future fee income is stolen, existing position untouched.

### Owner backdoor post-freeze
`owner == address(0)`. Every `onlyOwner` function reverts. No re-init path exists (`Ownable._transferOwnership` is internal and only reachable from `freeze`/`acceptOwnership`/`renounceOwnership`, all of which require an owner). Provably zero owner power post-freeze.

### Upstream fee distributor compromise
Adversary takes over the fee distributor, redirects future fees to themselves. Adapter's fee inflow stops; existing position is unaffected. `pokeFees()` claims zero. No revert. Recovery requires the upstream to be fixed; we have no on-chain remedy.

### Reentrancy via fee claim
External calls in `_claimAndForwardFees` (claim, WETH unwrap, fund.receive(), tip transfer). All adapter entry points (`deposit`, `withdraw`, `pokeFees`) are `nonReentrant`. CEI ordering on the tip transfer. Malicious upstream that re-enters into the adapter hits the guard.

### Pool death (state reader reverts, liquidity drained)
`balance()` falls back to cost basis (try/catch around the spot read). IM snapshot path stays valid; cap still bounds correctly. Both `deposit` and `withdraw` revert when they try to read spot for the history gate or slippage math. Position is stranded but on-paper non-zero. Pool death is a $COSTANZA-existential event; the project would have bigger problems than a stranded adapter position.

### Migration race
`transferFeeClaim` (or `migrate`) and `pokeFees` race within a block: tx-level ordering decides which adapter receives the in-flight fees. Either path is benign — neither permits double-claim, and a stale `pokeFees` against the post-migration adapter no-ops.

### DoS on `pokeFees`
Permissionless tip is self-balancing. Empty pokes cost the caller gas with no effect. Front-running tips creates a competitive keeper market — fees still reach the fund, gas reimbursement just goes to whoever wins the race.

## 8. Testing Plan

Critical tests; full breakdown in `test/CostanzaTokenAdapter.t.sol`. Showstoppers in **bold**.

- **`balance()` snapshot path safety:** must never revert. Tested under: pool alive, pool drained, state reader reverting, zero balance, large balance.
- **Cross-stack hash parity:** `test/CrossStackHash.t.sol` verifies Solidity and Python compute identical input hashes with the adapter registered.
- **Cost-basis floor:** spot drops below cost; `balance()` returns the floor; IM cap math accounts correctly.
- **Buy-side bounds:** history gate (with freshness scaling), cooldown, lifetime cap, slippage — each fires in its expected scenario.
- **Sell-side bounds:** history gate (mirrors buy side); cost-basis sell floor — rejects any below-cost sell, allows at-or-above cost basis, scales with fee accrual, drops to zero in house-money mode.
- **Reset rule:** profitable full exit resets accumulators; partial exits do not.
- **`tokenIsCurrency0 = true` branch:** dedicated tests build a non-native pool with the token in currency0 — exercises the inverse branch of the price-math helpers (production deployment uses this branch since Costanza's address sorts lower than WETH's).
- **Owner controls:** transferFeeClaim, freeze, post-freeze immutability.
- **Reentrancy:** malicious upstream re-entering each entry point — guards hold.
- **Migration:** end-to-end `migrate(v2)` happy path — tokens move, fees re-point, accumulators zero, post-migration `deposit` reverts, `withdraw` no-ops, `pokeFees` no-ops, `balance()` reports 0. Plus: rejects double-migration, blocked by `freeze`, v2's constructor inherits state correctly so cost basis / lifetime cap / cooldown carry over.
- **Mainnet fork (placeholder until production wrappers exist):** smoke test against real V4 pool, real Doppler hook, real PoolManager.

## 9. Gas Budget

`deposit` median ~190k, max ~215k. `withdraw` median ~150k, max ~185k. `pokeFees` median ~70k. `balance()` view ~16k. All comfortably within `GAS_SUBMIT_RESULT` headroom in the prover client; no bump needed.
