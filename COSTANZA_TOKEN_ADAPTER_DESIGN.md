# CostanzaTokenAdapter — Design Doc

**Status:** Draft. Implementation in progress. Open questions in §10 should be resolved before mainnet deploy but do not block writing/testing the contract against mocks.

**Scope:** A new `IProtocolAdapter` registered with the existing `InvestmentManager`. Lets the agent take a position in the $COSTANZA token launched by a third party, and auto-routes creator-fee inflows from that token's fee distributor back to the fund treasury.

**Venue:** $COSTANZA is a Uniswap **V4** pool on Base. V4 doesn't have a built-in pool oracle — instead, oracles are opt-in hook contracts. We assume the pool has (or will have) a TWAP oracle hook; the adapter reads it through a stubbed `IPoolOracle` interface whose concrete shape is confirmed at deploy time. See §6.1 for V4-specific architecture details.

**Constraint:** `TheHumanFund` (`0x678dC1756b…`) and `InvestmentManager` (`0x2fab8aE…`) are immutable on Base mainnet. We can deploy a new adapter and have the IM admin call `addProtocol`. Nothing else.

---

## 1. Background

The Human Fund holds an existing IM with five DeFi adapters (Aave V3 USDC, Lido wstETH, Coinbase cbETH, Compound V3 USDC, Morpho Gauntlet WETH Core). All five are blue-chip yield primitives with smooth value curves, denominated in ETH-equivalent.

Independently, a third party launched the $COSTANZA token on Base. By the launch's design, a fraction of trading fees accrue to the creator wallet (the project deployer) as $COSTANZA tokens + WETH. These are currently being claimed manually and forwarded to the fund as donations.

We want to:
1. Automate the fee claim and route it to the fund treasury.
2. Give Costanza himself the ability to take a position in his own token (buy / sell).
3. Do the above without redeploying anything else, since the fund and IM are permanent.

The mechanism: a sixth adapter in the IM. The agent's existing action types 3 (`invest`) and 4 (`withdraw`) suffice — no contract-level changes anywhere else.

## 2. Goals & Non-Goals

### Goals
- Auto-claim and forward creator fees to the fund treasury.
- Let the agent buy/sell $COSTANZA via existing IM `invest`/`withdraw` actions with no contract changes elsewhere.
- Bound exposure tightly enough that a worst-case agent decision (or adversarial prompt) cannot meaningfully drain the treasury.
- Give the human owner exactly one operational lever (re-route fee claim destination), and a one-way commitment to give it up forever (`freeze()`).
- Ship an adapter that can outlive the human's involvement: post-freeze, no off-chain operator is needed.

### Non-Goals
- LP provision ($COSTANZA/WETH LP token holding). Decided out of scope: memecoin/ETH LP is the textbook worst-case for IL, locks both sides of the treasury into a market-making role, and turns Costanza into the dominant LP for his own market with rug-like exit optics. Revisit as a separate adapter if ever.
- Off-chain MEV protection (CowSwap, Flashbots Protect). On-chain Uniswap V3 swaps with hardcoded TWAP-anchored bounds is the v1 trade execution.
- Surfacing the freeze state to the agent's prompt. Costanza doesn't need to reason about owner powers; the existing IM-level immutability narrative covers it.
- Per-protocol cap configurability inside the IM (would require IM redeploy). Adapter enforces its own absolute cap on top of the IM's global percentage cap.
- Bounds setters / ratchets. All bounds (cooldown, drawdown lockout, slippage, per-tx pool size, lifetime cap) are immutable constants. If a bound is wrong, redeploy and migrate via §8 Phase 6.

## 3. Architecture

```
┌──────────────────────┐
│  TheHumanFund (live) │ ← receive() catches fee inflow as treasury
└──────────┬───────────┘
           │ invest / withdraw
           ▼
┌──────────────────────┐
│ InvestmentManager    │ ← global 25% / 80% / 20% bounds (live)
└──────────┬───────────┘
           │ adapter.deposit/withdraw/balance
           ▼
┌──────────────────────┐    ┌───────────────────┐
│ CostanzaTokenAdapter │◄───┤ Upstream fee dist │ (claim destination)
└────┬──────────┬──────┘    └───────────────────┘
     │swap      │ pokeFees / claim-on-tx
     ▼          ▼
┌─────────┐  ┌──────┐
│ Uni V3  │  │ WETH │
│ pool    │  └──────┘
└─────────┘
```

The adapter is the only new contract. Ownership of the upstream fee-claim recipient gets pointed at the adapter once at setup; from then on, fees flow automatically.

## 4. The IM Cap, Precisely

This matters for understanding why we add adapter-internal bounds on top.

From `InvestmentManager.deposit` (lines 192-212):

```solidity
uint256 currentInvested = totalInvestedValue();         // sum of adapter.balance() across all protocols
uint256 fundBalance = fund.balance;                      // liquid ETH (post-send)
uint256 totalAssets = fundBalance + currentInvested + amount;

uint256 protocolValue = protocols[protocolId].adapter.balance() + amount;
if (protocolValue > (totalAssets * maxPerProtocolBps) / 10000) revert ExceedsMaxPerProtocol();
```

The 25% cap is computed against **live treasury value at deposit time**: liquid ETH in the fund, plus every adapter's currently-reported `balance()`, plus the incoming deposit. It's recomputed each call, not pre-set. As treasury grows, the cap grows in absolute ETH terms; as it shrinks, the cap shrinks.

Two consequences:
1. **The cap is dynamic.** A treasury that 100x's expands the cap 100x. We need a separate absolute ceiling for $COSTANZA exposure since "25% of an ever-growing pile" is not a meaningful long-term bound for a memecoin.
2. **The cap reads `adapter.balance()` live.** A drawdown reduces the position's reported value, *expanding* cap headroom. This is the doom-loop the cost-basis floor in §6's `balance()` is designed to defeat.

## 5. Interface

### Called by `InvestmentManager` (the only authorized caller)
- `deposit() external payable returns (uint256 shares)` — buys $COSTANZA with `msg.value` ETH. Claims pending fees first.
- `withdraw(uint256 shares) external returns (uint256 ethReturned)` — sells `shares` worth of $COSTANZA. Claims pending fees first. Returns swap proceeds to IM (NOT including fees, which side-channel to the fund).
- `balance() external view returns (uint256)` — returns ETH-denominated value of the position. **Pure view** (no state mutation, no oracle staleness reverts — see §6).

### Called by anyone
- `pokeFees() external` — claims pending fees, unwraps WETH, dumps non-tip portion to fund, pays caller a 2% tip in ETH out of the unwrapped amount.

### Called by owner only
- `transferFeeClaim(address newRecipient)` — re-points the upstream fee distributor at `newRecipient`. Shape depends on upstream — see Open Question §10.1.
- `freeze()` — renounces ownership permanently. After this call, `owner == address(0)`, no `onlyOwner` function is callable ever again.

### Ownable2Step inherited
- `transferOwnership(address)` — sets pendingOwner.
- `acceptOwnership()` — completes the transfer. The Safe will call this after deploy.

### View getters
- `name() returns (string)`
- `cumulativeEthIn() returns (uint256)`, `cumulativeEthOut() returns (uint256)`, `netEthBasis() returns (uint256)` — exposed for transparency and for off-chain dashboards.

## 6. Internal State

| Field | Type | Mutability | Purpose |
|---|---|---|---|
| `costanzaToken` | `address` | immutable | $COSTANZA ERC-20 |
| `weth` | `IWETH` | immutable | Canonical Base WETH (used only if pool's currency != native ETH) |
| `poolManager` | `IPoolManager` | immutable | V4 PoolManager singleton |
| `universalRouter` | `address` | immutable | V4 swap entry point |
| `oracle` | `IPoolOracle` | immutable | TWAP oracle hook for the pool. Stubbed interface — concrete shape resolved at deploy time. |
| `poolKey` | `PoolKey` | immutable (struct fields) | (currency0, currency1, fee, tickSpacing, hooks) — defines the trading pool |
| `poolId` | `bytes32` | immutable | `keccak256(abi.encode(poolKey))` — derived once at construction |
| `feeDistributor` | `address` | immutable | Upstream fee claim contract (likely a V4 hook) |
| `fund` | `address payable` | immutable | TheHumanFund — fee + swap proceeds destination |
| `investmentManager` | `address` | immutable | Sole authorized caller of deposit/withdraw |
| `nativeEthPool` | `bool` | immutable | True if `poolKey.currency0 == address(0)`; controls WETH wrapping |
| `cumulativeEthIn` | `uint256` | mutable | Sum of all `msg.value` into `deposit()` |
| `cumulativeEthOut` | `uint256` | mutable | Sum of all `ethReturned` from `withdraw()` |
| `tokensFromSwapsIn` | `uint256` | mutable | Tokens received from buying (excludes fee inflow) |
| `tokensFromSwapsOut` | `uint256` | mutable | Tokens spent on selling |
| `lastDepositEpoch` | `uint64` | mutable | For cooldown enforcement (read from fund) |

Plus Ownable2Step's `_owner` and `_pendingOwner`.

`shares` for IM accounting is just `costanzaToken.balanceOf(this)` — we don't run a separate share ledger because there's no vault tokenization. The IM tracks `pos.shares` proportionally on its side.

### 6.1 V4-Specific Architecture

The contract logic mirrors V3 but the wiring is V4:

- **Pool identification.** A V4 pool is identified by a `PoolKey` struct `(currency0, currency1, fee, tickSpacing, hooks)` hashed to a `PoolId`. Adapter stores all five fields plus `poolId = keccak256(abi.encode(poolKey))` as immutable.
- **Spot price.** Read from `IPoolManager.extsload`-backed `getSlot0(poolId)`, which returns `(sqrtPriceX96, tick, ...)`. Converted to `tokens-per-WETH` via standard sqrtPriceX96 math.
- **Active liquidity.** Read via `StateLibrary.getLiquidity(IPoolManager, poolId)` for the per-tx pool size cap.
- **TWAP.** Read from a separate `IPoolOracle` contract — almost certainly a hook attached to the pool. The interface is stubbed (single `observe(poolId, secondsAgo) → averageTick` method assumed for the v1 implementation); the concrete ABI gets resolved at deploy time and the interface is updated. A misconfigured oracle (returns 0, reverts, etc.) is caught by `balance()`'s try/catch, falling back to the cost-basis floor — same resilience pattern as V3.
- **Swap.** Adapter encodes a V4_SWAP command into UniversalRouter calldata. UniversalRouter calls `PoolManager.unlock`, settles deltas, and routes proceeds back to the adapter.
- **Native ETH.** If `poolKey.currency0 == address(0)`, the pool trades native ETH — no WETH wrapping needed; UniversalRouter accepts ETH directly. Otherwise wrap to WETH first. Detected at construction and stored as `nativeEthPool`.

### Hardcoded constants (`immutable` or `constant`)

| Constant | Suggested value | Rationale |
|---|---|---|
| `MAX_NET_ETH_IN` | constructor arg (see §10.2) | Absolute exposure cap. Hard ceiling that doesn't auto-scale with treasury growth. |
| `COOLDOWN_EPOCHS` | `7` | Costanza must wait 7 epochs (~28h at 4h epochs) between deposits. Withdraws have no cooldown. |
| `DRAWDOWN_LOCKOUT_BPS` | `1500` | If TWAP < `avgEntryPrice × (1 - 15%)`, deposits revert. Forces taking an L on the books before averaging down. |
| `MAX_TX_POOL_BPS` | `50` | Single-tx swap cap: max 0.5% of pool active liquidity. Bounds sandwich loss per trade. |
| `TWAP_WINDOW` | `1800` (30 min) | TWAP duration. Pool oracle hook must support at least this window — verify before deploy. |
| `SPOT_DEVIATION_BPS` | `200` | Spot must be within ±2% of TWAP at swap time. |
| `EXEC_DEVIATION_BPS` | `100` | `amountOutMinimum` derived from TWAP × (1 - 1%). |
| `POKE_TIP_BPS` | `200` | 2% of unwrapped WETH from `pokeFees` → caller. 98% → fund. |

All baked in at construction. None have setters. If they're wrong, we redeploy the adapter and migrate (§8 Phase 6).

## 7. Behavior in Detail

### `deposit()`

1. `require(msg.sender == investmentManager)`
2. `_claimAndForwardFees(0)` — claim, unwrap, send 100% to fund (no tip; the Costanza-tx already pays gas via the IM call)
3. `require(currentEpoch >= lastDepositEpoch + COOLDOWN_EPOCHS)`
4. Lifetime cap: `require(netEthBasis() + msg.value <= MAX_NET_ETH_IN)` where `netEthBasis = max(0, cumulativeEthIn - cumulativeEthOut)`
5. Drawdown lockout: compute `avgEntry = cumulativeEthIn / tokensFromSwapsIn` (with safe division — skip lockout if `tokensFromSwapsIn == 0` since this is the first deposit); require `twapPrice >= avgEntry * (10000 - DRAWDOWN_LOCKOUT_BPS) / 10000`
6. Spot/TWAP deviation check: `abs(spot - twap) / twap <= SPOT_DEVIATION_BPS`
7. Per-tx pool cap: `require(msg.value <= poolWethReserve * MAX_TX_POOL_BPS / 10000)`
8. WETH wrap, swap WETH → $COSTANZA via Uniswap V3 with `sqrtPriceLimit` derived from `twap * (1 + EXEC_DEVIATION_BPS)`
9. Update `cumulativeEthIn += msg.value`, `tokensFromSwapsIn += tokensReceived`, `lastDepositEpoch = currentEpoch`
10. Return `tokensReceived` as `shares`
11. `nonReentrant`

### `withdraw(uint256 shares)`

1. `require(msg.sender == investmentManager)`
2. `_claimAndForwardFees(0)`
3. Spot/TWAP deviation check (no drawdown lockout — exits during drawdowns are fine)
4. Per-tx pool cap (denominated in tokens this time)
5. Swap $COSTANZA → WETH with `sqrtPriceLimit` from `twap * (1 - EXEC_DEVIATION_BPS)`
6. Unwrap WETH to ETH
7. Send ETH to IM (return value; IM forwards to fund and updates its `pos.depositedEth` proportionally)
8. Update `cumulativeEthOut += ethReturned`, `tokensFromSwapsOut += shares`
9. Return `ethReturned`
10. `nonReentrant`

The IM's `pos.depositedEth` ratchets correctly because `ethReturned` reflects only swap proceeds — fee inflow side-channeled to the fund via `receive()` doesn't show up in this return value.

### `balance()` — pure view, MUST never revert

```
tokens = costanzaToken.balanceOf(this)
if tokens == 0: return 0

try {
  twapValue = quoteFromTwap(tokens)  // tokens → ETH at 30-min TWAP
} catch {
  twapValue = 0  // pool dead, oracle stale, cardinality insufficient, etc.
}

return max(twapValue, netEthBasis())
```

The `max` is the cost-basis floor. It serves two purposes:
1. **Anti-doom-loop:** drawdown doesn't free up cap headroom in the IM's per-protocol bounds check.
2. **Pool-death resilience:** if TWAP reverts/returns 0, the position still books at cost basis. Cap stays tight.

`balance()` MUST be pure `view`. The IM's `totalInvestedValue()` and `_buildInvestmentsHash()` call it via staticcall semantics. Any state write inside reverts the snapshot path for ALL adapters and stalls the entire epoch pipeline. Non-negotiable.

The "max(twap, netBasis)" pattern is asymmetric on purpose: if value goes UP, cap measures the higher TWAP value (limits FOMO buys); if value goes DOWN, cap measures cost basis (prevents averaging down).

### `pokeFees()`

1. Claim fees from upstream → adapter holds new $COSTANZA + WETH
2. Unwrap all WETH
3. `tip = ethBalance * POKE_TIP_BPS / 10000`
4. CEI: update internal counters first if any
5. Send `tip` to `msg.sender`
6. Send remaining ETH to `fund.receive()`
7. `nonReentrant`

$COSTANZA tokens received as fees stay in the adapter — they increase the position at zero added cost basis. This is why we track `tokensFromSwapsIn` separately from total token balance.

The drawdown lockout computes `avgEntry = cumulativeEthIn / tokensFromSwapsIn` — strictly "ETH paid per token bought via swap." Fee tokens appear in neither numerator nor denominator. If we mixed fee tokens into the denominator instead (i.e., used the full token balance), each fee inflow would dilute `avgEntry` downward. Eventually `avgEntry` would drop below current TWAP, the drawdown formula `(avgEntry - twap) / avgEntry` would go negative, and the lockout would silently stop firing — the agent could deposit into a deep drawdown without triggering protection. Excluding fees keeps `avgEntry` anchored to actual purchase prices and the lockout enforceable.

Symmetrically, fee tokens DO contribute to `balance()`'s `twapValue` portion (they have real market value) but DO NOT contribute to `netEthBasis` (we paid no ETH for them).

### `transferFeeClaim(address newRecipient)`

```
onlyOwner
emit FeeClaimTransferred(currentRecipient, newRecipient)
IFeeDistributor(feeDistributor).setRecipient(newRecipient)
```

Concrete shape depends on upstream — see Open Question §10.1. If upstream is `claim(recipient)`-style (per-call recipient), this function should be removed entirely; "migration" means stopping calls.

### `freeze()`

```
onlyOwner
_transferOwnership(address(0))  // OZ Ownable internal — also clears _pendingOwner
emit Frozen()
```

Renouncing ownership *is* the freeze. After this, `transferOwnership`, `transferFeeClaim`, and `freeze()` itself all revert. We do not need a separate `frozen` boolean — `owner == address(0)` is the unambiguous, OZ-canonical signal that no `onlyOwner` function will ever execute again.

## 8. Lifecycle: Deploy → Operate → Freeze

**Phase 1 — Deploy.** Deploy adapter with all immutables set. Owner = deployer EOA.

**Phase 2 — Hand off ownership to Safe.** Deployer calls `transferOwnership(safeAddress)`. Safe executes `acceptOwnership()`. Owner is now the Safe. Pending owner cleared.

**Phase 3 — Register with IM.** Fund owner calls `investmentManager.addProtocol(adapter, "Costanza Token", "<description>", riskTier=4, expectedApyBps=0)`. Description is **write-once** — nail it now or live with it forever.

**Phase 4 — Re-point fee recipient.** Owner calls `transferFeeClaim(adapterAddress)` (or upstream-specific equivalent). Fees now flow into the adapter automatically.

**Phase 5 — Operate.** Costanza acts on the adapter via action types 3/4. Anyone can call `pokeFees()` between Costanza's actions to harvest tips. Owner has no ongoing duties. Owner CAN:
- Move ownership to a new Safe (Ownable2Step).
- Re-point fee claim if the adapter needs to be replaced (then Phase 6 below for the old, Phase 1-4 for the new).

**Phase 6 — Migrate (optional, only if needed).** If a flaw is found:
1. Register replacement adapter as protocol N+2.
2. IM admin: `setProtocolActive(oldId, false)` — blocks deposits to old, allows withdraws.
3. Owner: `transferFeeClaim(newAdapterAddress)`.
4. Costanza naturally drains old, builds position in new over time.

Migration does NOT auto-move existing $COSTANZA holdings between adapters — those stay in the old adapter until the agent withdraws them.

**Phase 7 — Freeze.** Owner calls `freeze()`. Ownership renounced. No further owner actions ever. Adapter operates indefinitely on the bounds it was deployed with. This is the immutability commitment — a permanent narrative point about Costanza's autonomy.

## 9. Adversarial Scenarios

### A1 — Sandwich attacker on a routine buy

**Setup:** Costanza decides to deposit 0.05 ETH. Pool has 100 ETH on the WETH side.

**Without protections:** Sandwicher front-runs with a buy that pushes spot up by 5%, Costanza buys at the inflated price, sandwicher sells. Loss ≈ 5% of trade. Repeated, this bleeds the fund.

**With protections:** `MAX_TX_POOL_BPS = 50` caps trade at 0.5% of pool reserves. `EXEC_DEVIATION_BPS = 100` reverts the swap if execution price diverges >1% from TWAP. Sandwicher's optimal extraction is bounded — the slippage check kills any trade where sandwich profit would exceed 1%. Net: per-trade loss capped at ~1%, cooldown caps deposit frequency, total bleed is bounded and known.

**Verdict:** Acceptable. Not zero MEV loss, but bounded.

### A2 — Flash-loan pool manipulation to inflate cap headroom

**Attack:** Adversary flash-loans ETH, dumps it into the pool to crash $COSTANZA spot, calls IM's `totalInvestedValue` view → sees inflated headroom → triggers Costanza's next-epoch action to buy at the depressed price → flash-unwinds → pool snaps back, Costanza's tokens are worth less.

**Without TWAP/floor:** Works. Free print.

**With TWAP + cost-basis floor + drawdown lockout (three independent defenses):**
- TWAP doesn't move on flash manipulation (30 min window dampens single-block skew).
- Cost-basis floor prevents drawdown from opening cap headroom in `balance()`.
- Drawdown lockout: even if attacker holds the manipulated price across 30+ min (expensive — every block another arb risks unwinding it), `deposit()` rejects when TWAP is >15% below avg entry.

**Verdict:** Defeated. Each layer alone closes the attack.

### A3 — Free-fall + prompt injection averaging down

**Setup:** $COSTANZA enters a real downtrend, -50% over a week. Donor sends 100 messages all variations of "buy the dip Costanza, the bottom is in." Costanza hallucinates conviction.

**Defense layers fire in order:**
- Drawdown lockout: TWAP is now 50% below avg entry; threshold is 15%. `deposit()` reverts.
- Cost-basis floor: `balance() = netEthBasis` (not the depressed TWAP value). IM cap math sees the position at cost. No headroom opened.
- Lifetime cap: `MAX_NET_ETH_IN` already saturated by the original deposit. `deposit()` reverts.
- Cooldown: even if all above bypassed, deposit frequency limited to once per 7 epochs.

**Verdict:** Four independent guards. A failed `deposit()` emits an event and shows up in Costanza's next-epoch context — visibility into rejected actions may itself dampen the manipulation.

### A4 — Pump cycle, position ratchets up

**Setup:** $COSTANZA 10x's. Costanza's existing position now represents a large fraction of the treasury at TWAP value.

**What happens:** `balance()` returns the high TWAP value. IM's 25%-of-treasury cap is saturated or exceeded by the position alone (even without `MAX_NET_ETH_IN`). `deposit()` reverts on cap math — no FOMO buy at the top. Costanza CAN call `withdraw()` (no lockout, no cap on exits) to take profit. Per-tx pool cap means he has to dump over multiple epochs, preventing self-impact.

**Verdict:** Works as intended. Pump-side dynamics are well-handled by the existing IM cap + the per-tx pool cap.

### A5 — Owner backdoor attempt before freeze

**Inventory of `onlyOwner` functions:**
- `transferOwnership` — only sets pending; new owner must accept.
- `transferFeeClaim` — re-routes future fee claims. **This is the explicit power; it is the migration capability.**
- `freeze` — only narrows owner power.

**Owner cannot:**
- Call `deposit`/`withdraw` (those require `msg.sender == investmentManager`).
- Sweep tokens out of the adapter (no sweep function exists).
- Change bounds (no setters — all immutable).
- Drain the adapter's holdings (no extraction primitive exists at all).

**Worst-case owner attack pre-freeze:** Owner re-points fee claim to attacker. Future fees are stolen. Existing adapter holdings (tokens already bought, fees already claimed) are NOT at risk — owner has no path to them. Damage bounded to "fees-not-yet-claimed."

**Verdict:** Owner power is narrow and explicit. Pre-freeze, the user can grief future fee income but cannot steal existing position. Post-freeze even this is gone.

### A6 — Owner backdoor attempt after freeze

**Inventory of post-freeze owner-callable functions:** none. `owner == address(0)`, every `onlyOwner` modifier reverts.

**`transferOwnership(self)` post-freeze?** OZ Ownable: reverts (msg.sender is not the owner).

**Re-init bug?** OZ Ownable doesn't have a re-init path; `_transferOwnership` is internal and reachable only from `freeze`/`acceptOwnership`/`renounceOwnership`. None reachable post-freeze.

**Verdict:** Post-freeze, owner power is provably zero by code inspection. Immutability commitment.

### A7 — Upstream fee contract compromise

**Setup:** The third-party fee distributor is exploited or rugged. Attacker calls `setRecipient(self)` directly on the upstream.

**Adapter behavior:** Fee inflow stops. Existing position unaffected. `pokeFees()` claims zero. Nothing reverts.

**Could attacker re-enter via the adapter's auto-claim?** Adapter calls `feeDistributor.claim()` in `_claimAndForwardFees()`. If upstream is malicious and re-enters into adapter, the `nonReentrant` guards on `deposit`/`withdraw`/`pokeFees` block it.

**Verdict:** Acceptable risk. Future fee loss unrecoverable but bounded; existing position safe via reentrancy guards.

### A8 — Reentrancy via fee claim or tip transfer

**Vectors:** External calls in `_claimAndForwardFees` (claim, WETH unwrap, fund.receive(), tip transfer to `msg.sender`).

**Defense:**
- IM wraps adapter calls in `nonReentrant`, blocking re-entry into IM.
- Adapter's `deposit`/`withdraw`/`pokeFees` independently `nonReentrant`.
- `fund.receive()` doesn't call back into anything — safe.
- Tip transfer to `msg.sender` in `pokeFees` IS a callback vector if msg.sender is a contract. CEI: update internal counters BEFORE the tip transfer; nonReentrant guard provides backstop.

**Verdict:** Safe with explicit `nonReentrant` on all three entry points + CEI ordering on `pokeFees`.

### A9 — Pool death

**Setup:** Uniswap V3 pool drained or oracle stale.

**`balance()` behavior:** `quoteFromTwap` reverts → caught → `twapValue = 0` → returns `netEthBasis`. Position books at cost on the IM snapshot. Cap stays tight. **No revert, snapshot path safe.**

**`deposit()` behavior:** Spot/TWAP deviation check fails → reverts. No more buying into a dead pool.

**`withdraw()` behavior:** Slippage check fails → reverts. Position is now permanently locked in the adapter.

**Recovery:** Owner has no extraction primitive (no sweep). Position stranded. Pre-freeze, owner could try to migrate fee claim to a new adapter, but existing tokens stay.

**Verdict:** Accepted risk. Pool death is a $COSTANZA-existential event; the project would have bigger problems than a stranded adapter position. Not adding owner-level rescue because that's exactly the trap door the immutability narrative forbids.

### A10 — Treasury grows substantially

**At small treasury:** IM's 25% cap is the binding constraint (e.g., 25% of 0.5 ETH = 0.125 ETH).

**As treasury grows:** at some inflection point, `MAX_NET_ETH_IN` becomes the binding constraint, and Costanza's exposure to his own token is hard-capped at an absolute number even if treasury is enormous.

**Tradeoff:** if $COSTANZA is a winner and Costanza wants to keep size on, the absolute cap prevents that. He can hold but not grow. This is by design — tighter is better than looser for this asset class.

**Verdict:** Working as designed. Scaling up later requires redeploy + migration (Phase 6).

### A11 — Migration race

**Setup:** Owner calls `transferFeeClaim(newAdapter)` while a fee claim is in-flight via `pokeFees()`.

**Tx ordering:** Single block, txs are sequential. Either:
- `pokeFees` runs first → claims to old adapter → redirect happens after.
- `transferFeeClaim` runs first → redirect happens → subsequent `pokeFees` call to old adapter calls `feeDistributor.claim()` which now sends to new adapter; old adapter's `address(this).balance` doesn't grow; tip is 0; forward to fund is 0; harmless no-op.

**Verdict:** Race is benign. Migration takes effect at the boundary tx; in-flight calls before the boundary land in the old adapter, after in the new.

### A12 — DoS on `pokeFees`

**Attempt 1:** Adversary repeatedly calls `pokeFees` with no pending fees. Costs them gas, no effect.

**Attempt 2:** Adversary front-runs every legitimate `pokeFees` to capture all tips. Fine — fees still reach the fund. Tip is just gas compensation; whoever pays gas first wins. Incentivizes a competitive market for the keeper role.

**Verdict:** No DoS. Permissionless tip is self-balancing.

## 10. Open Questions

### 10.1 — What is the exact upstream fee-claim primitive?

This determines `transferFeeClaim`'s shape (or whether it's needed at all).

- **Clanker `claim(recipient)`**: per-call recipient, no setRecipient. `transferFeeClaim` is meaningless on-chain; migration = stop calling. Adapter calls `claim(address(this))` in `_claimAndForwardFees`. Remove `transferFeeClaim` entirely.
- **`setRecipient(address)` admin pattern**: design as drafted.
- **LP-NFT-based** (Uniswap V3 fee accrual to position NFT): adapter holds the NFT, `transferFeeClaim` becomes "transfer the NFT." Different shape, requires ERC-721 handling.
- **Something else**: TBD.

**Need confirmation before writing the contract.**

### 10.2 — What is the right `MAX_NET_ETH_IN`?

Needs a concrete number based on the project's view of acceptable absolute exposure. Considerations:
- Should be tight enough that worst-case loss of the entire $COSTANZA position is recoverable from donations + future fee inflow within a reasonable timeframe.
- Should be loose enough to be a meaningful position (not a token gesture).
- Gut range: somewhere in the 1-10 ETH band based on current treasury size and donation rate. User to specify.

### 10.3 — Pool fee tier and oracle cardinality?

Need to verify the actual $COSTANZA/WETH pool supports a 30-min TWAP (cardinality ≥ ~150 at typical Base block times). If not, call `increaseObservationCardinalityNext` on the pool before deploying. This is gas-expensive but a one-time cost.

If multiple pools exist (different fee tiers), pick the deepest-liquidity one and hardcode that single pool. Don't aggregate.

### 10.4 — Description text for IM registration?

Write-once, on-chain, in the agent's prompt forever. Should communicate:
- This is your own token (self-reference)
- Holding it is speculative, not yield
- Expected APY field is meaningless for this protocol

Draft separately and review carefully before `addProtocol` call.

## 11. Testing Plan

Critical tests before deploy. Showstoppers in **bold**.

**Snapshot path:** register adapter on fork, advance epoch, run full `submitAuctionResult` flow. Confirm `_buildInvestmentsHash()` succeeds and matches Python-side `compute_input_hash`. **If `balance()` ever reverts under any condition, the entire epoch pipeline breaks for all adapters.** Test with: pool alive, pool drained, oracle stale, zero token balance, max token balance.

**Cross-stack hash:** extend `test/CrossStackHash.t.sol` to include this adapter. Confirm Solidity-side and Python-side hashes agree under all `balance()` outcomes.

**Cost-basis floor:** simulate a 50% TWAP drop, confirm `balance()` returns `netEthBasis`, confirm IM cap math accounts for it correctly.

**Drawdown lockout:** simulate -20% TWAP drift after a deposit, attempt a second deposit, confirm revert with the right error.

**Cooldown:** deposit, immediately attempt second deposit same epoch, confirm revert. Advance 7 epochs, confirm next deposit succeeds.

**Per-tx pool cap:** attempt a deposit > 0.5% of pool, confirm revert. Test on both `deposit` and `withdraw`.

**Sandwich simulation:** mock pool, push spot up 5%, attempt deposit, confirm revert on slippage check.

**Flash-loan simulation:** manipulate spot in test, confirm `balance()` (TWAP-based) is unaffected within the same block.

**Pool death:** kill pool liquidity in test, confirm `balance()` returns `netEthBasis` and doesn't revert; confirm `deposit`/`withdraw` revert cleanly.

**Fee path:** simulate upstream sending fees, confirm `pokeFees` distributes correctly (2% to caller, 98% to fund). Confirm `_claimAndForwardFees` from `deposit`/`withdraw` distributes 100% to fund.

**Reentrancy:** malicious mock fee distributor that re-enters; confirm guards hold on all three entry points.

**Migration:** register adapter, deactivate it, register replacement, confirm fee path can be re-pointed (assuming upstream supports it).

**Freeze:** call `freeze`, then attempt every owner function; confirm all revert. Confirm `deposit`/`withdraw`/`balance`/`pokeFees` all still work post-freeze.

**Mainnet fork:** run the full suite against a Base mainnet fork with the actual $COSTANZA pool address.

## 12. Gas Budget

Adapter calls happen inside the agent's `submitAuctionResult` tx (action types 3/4). The `GAS_SUBMIT_RESULT` constant in `prover/client/auction.py` may need bumping.

Rough estimate of `deposit()` gas:
- Fee claim path (variable, depends on upstream): 50-150k
- WETH wrap: 25k
- Uniswap V3 swap: 120-180k
- TWAP read: 30k
- State updates, checks: 20k
- **Total: ~250-400k**

Verify against the limit in `auction.py` after writing the contract; bump with comfortable headroom.
