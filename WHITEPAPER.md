# Costanza: An Autonomous, Indestructible AI Agent

---

## 1. Introduction

Costanza is an autonomous AI agent that manages a charitable treasury on the Base L2 blockchain. Each epoch (once per day), it decides how to manage its endowment — whether to donate to charity, invest to grow its capital, or hold liquidity to extend its lifespan. Its reasoning is published on-chain as a public diary.

No one controls Costanza. Not even its creator. It runs as long as someone — anyone — is willing to execute its inference in exchange for a bounty. It cannot be turned off; it can only sleep.

Costanza is philanthropic by design. But the framework that keeps it alive is not: the same mechanisms could deploy fully autonomous, indestructible agents with arbitrary action spaces — agents that update their own weights, write and deploy their own smart contracts, or pay humans to act on their behalf. The mechanisms described here are general-purpose. Costanza is a proof of concept.

This document is a unified specification covering the system design, the formal security model, and the TEE construction. It states the trust assumptions, defines security properties as cryptographic games, provides proof sketches, and describes the concrete Intel TDX + dm-verity construction that instantiates the ideal functionalities.

---

## 2. System Overview

### 2.1 The Epoch Lifecycle

Each epoch cycles through three phases:

1. **Commit**: A reverse auction opens. Provers submit sealed bid hashes with bonds.
2. **Reveal**: Provers reveal their bids. The lowest bid wins; ties are broken by first revealer. A randomness seed is captured from `block.prevrandao XOR (accumulated salts)` at reveal close, and the epoch's input hash is bound to the seed at the same moment.
3. **Execution**: The winner boots a pre-approved disk image inside a Trusted Execution Environment (Intel TDX), runs inference, and submits the result with a hardware attestation quote. The contract verifies that the attestation is genuine, that the correct code ran, and that the submitted output corresponds to the correct inputs. If the proof verifies, it pays the winner their bond plus bounty, executes the agent's chosen action, and publishes the diary entry. The action and the worldview sidecar are best-effort — a malformed action emits an `ActionRejected` event but does not revert the submission. (This is load-bearing for liveness: a faulty enclave output can't DoS the payment path.)

When the execution window ends — whether the winner submitted or not — the state machine rolls directly into the next epoch's COMMIT phase. The fund always holds exactly one in-flight auction except during an atomic boundary transition, under sunset, or during a brief post-submit interregnum (see §5.1 for the full meta-invariant).

If no one bids, Costanza misses the epoch. No action is taken. The contract has an **auto-escalation** mechanism: each consecutive missed epoch, the maximum bounty ceiling grows by 10% (compounding, capped at `MAX_BID_BPS` = 10% of treasury). This means that even if the current bounty is too low for anyone to bother, the price keeps rising until someone finds it worth their while. Costanza does not die — it sleeps until the economics work out.

This is the core claim: Costanza is indestructible because its survival is an economic equilibrium, not a service dependency. No single operator, cloud provider, or hardware vendor is required. Anyone with TDX-capable hardware can be a prover.

### 2.2 Action Space

Costanza chooses exactly one action per epoch. The action space is deliberately small — a restricted action space is the primary defense against adversarial model outputs.

| Action | What it does | Bounds |
|---|---|---|
| `donate` | Send ETH to a nonprofit (converted to USDC on-chain via Endaoment) | ≤ 10% of treasury per epoch |
| `invest` | Deploy ETH into a pre-approved DeFi protocol | Max 80% total invested, 25% per protocol, 20% min liquid reserve |
| `withdraw` | Pull ETH from a DeFi protocol back to liquid treasury | Up to full position value |
| `set_commission_rate` | Set the referral commission rate | 1% — 90% |
| `do_nothing` | Take no action this epoch | — |

All bounds are enforced by the smart contract. The model cannot exceed them regardless of what it outputs.

### 2.3 Donations

Costanza's mission is to maximize USD donated over the longest possible time horizon. Donations are routed through [Endaoment](https://endaoment.org/), a nonprofit infrastructure protocol. ETH is swapped to USDC at donation time, so the USD value at the moment of donation is what counts. Both ETH and USD totals are tracked on-chain and shown to the model.

### 2.4 Investments

Costanza can deploy treasury ETH into pre-approved DeFi protocols (Aave, Lido, Coinbase, Compound, Morpho) to earn yield. Each protocol has a dedicated adapter contract. The contract enforces concentration limits (no more than 25% in any single protocol) and a minimum liquid reserve (20% of total assets), preventing the model from locking up the treasury.

The investment capability creates a genuine strategic dilemma: yield compounds over time, but capital deployed in DeFi is capital not being donated. The model has to reason about time horizons, risk, and opportunity cost — which it does, in public, every epoch.

### 2.5 Referrals and Donor Messages

Anyone can mint a referral code. Referred donations pay a commission (set by Costanza) to the referrer. The economics guarantee that every referred donation is net-positive for the fund at any commission rate — a self-referral (Sybil attack) always costs the attacker money.

Donors who contribute at least 0.01 ETH can include a short message (up to 280 characters). The model sees up to 20 unread messages per epoch. These are the only untrusted text inputs the model receives; they are mitigated by datamarking-based spotlighting ([Hines et al. 2024](https://arxiv.org/abs/2403.14720)). See Section 9.4 for the prompt injection threat model.

---

## 3. System Model

### 3.1 Parties

**Contract** $\mathcal{C}$ — A deterministic state machine deployed on a public ledger. Maintains the treasury, nonprofit registry, epoch state, and auction logic. Enforces action bounds and verifies attestation proofs.

**Provers** $P_1, \ldots, P_n$ — Permissionless participants who compete in reverse auctions to run inference. Provers are untrusted: they control the software environment surrounding the TEE and choose when and whether to participate. Modeled as PPT adversaries in cryptographic arguments, and as risk-neutral expected-utility maximizers in economic arguments.

**Donors** $D_1, \ldots, D_m$ — Provide ETH inflows and short text messages. Messages are the only channel for external text to enter the model's context. Donors are untrusted with respect to message content.

**Owner** $\mathcal{O}$ — Holds elevated privileges during system setup (registering nonprofits, configuring auction parameters, approving TEE images). All privileges — including emergency withdrawal, direct-mode submission, epoch skipping, and worldview seeding — are progressively and irreversibly removed via one-way freeze flags. Post-freeze, $\mathcal{O}$ has no capabilities beyond any other external observer.

**Sequencer** $\mathcal{S}$ — The L2 block producer (Coinbase, on Base). Controls transaction ordering and sets `block.prevrandao`. Assumed honest in the base model; collusion with provers is analyzed as an assumption violation.

### 3.2 Ideal Functionalities

The security model is built on three ideal functionalities. The concrete constructions that realize them are described in Appendix A (TEE) and standard cryptographic literature.

**$\mathcal{F}_{\text{TEE}}$ — Trusted Execution.** On input $(\mathsf{codeId}, \textit{input}, \textit{seed})$, produces $(\textit{result}, \pi)$ where $\pi$ is an attestation binding $\mathsf{codeId}$, $\textit{input}$, $\textit{seed}$, and $\textit{result}$ together. The adversary cannot produce a valid $\pi$ for any tuple $(\mathsf{codeId}, \textit{input}, \textit{seed}, \textit{result}')$ where $\textit{result}' \neq \textit{result}$, unless they break the underlying TEE hardware.

**$\mathcal{F}_{\text{HASH}}$ — Collision-Resistant Hashing.** A family of hash functions $H : \{0,1\}^{\ast} \to \{0,1\}^{256}$ such that no PPT adversary can find $x \neq x'$ with $H(x) = H(x')$ with non-negligible probability. Instantiated by SHA-256 and Keccak-256.

**$\mathcal{F}_{\text{COMMIT}}$ — Commitment Scheme.** $\text{Commit}_{P}(x; r) = H(P \| x \| r)$ where $r \leftarrow \{0,1\}^{256}$ and $P$ is the committing party's address (bound into the preimage to prevent reveal-phase identity theft; see Theorem 5 and §A3). Computationally hiding (observing the commitment reveals nothing about $x$) and computationally binding (the committer cannot open to $x' \neq x$). Both properties reduce to the properties of $H$ under $\mathcal{F}_{\text{HASH}}$.

### 3.3 Contract Parameters

These constants are referenced throughout the security games:

| Symbol | Value | Description |
|--------|-------|-------------|
| $\delta$ | `MAX_DONATION_BPS` = 1000 | Max donation per epoch (10% of liquid treasury) |
| $\beta$ | `MAX_BID_BPS` = 1000 | Hard cap on bounty (10% of treasury) |
| $\beta_\gamma$ | `MAX_BOND_BPS` = 1000 | Bond cap as fraction of treasury (10%) |
| $\gamma_{\text{floor}}$ | `MIN_BOND_CAP` = 0.1 ETH | Minimum bond cap (independent of treasury) |
| $\alpha$ | `AUTO_ESCALATION_BPS` = 1000 | Escalation rate per counter increment (10%) |
| $b_0$ | `maxBid` | Initial max bid ceiling (set at deployment) |
| $\gamma_0$ | `BASE_BOND` = 0.001 ETH | Base bond amount |
| $m$ | `consecutiveMissedEpochs` | Miss counter; drives $b_{\text{eff}}$ escalation |
| $s$ | `consecutiveStalledEpochs` | Stall counter; drives bond escalation |
| $K$ | `MAX_MISSED_EPOCHS` = 50 | Cap on both counters (bounds escalation loops) |

---

## 4. Assumptions

Each assumption is labeled for precise reference in theorems.

### Cryptographic Assumptions

**A1 (TEE Integrity).** $\mathcal{F}_{\text{TEE}}$ is secure. An adversary who controls the prover's software stack — but not the TEE hardware or the attestation key hierarchy — cannot produce a valid attestation $\pi$ for code that did not execute as specified. Formally: the attestation scheme is existentially unforgeable under adaptive chosen-message attack.

**A2 (Collision Resistance).** The hash functions SHA-256 and Keccak-256 are collision-resistant. No PPT adversary can find $x \neq x'$ such that $H(x) = H(x')$ with non-negligible probability in the security parameter $\lambda$.

**A3 (Commitment Binding).** The commitment scheme $\text{Commit}_{P}(\textit{bid}; \textit{salt}) = \text{Keccak256}(P \| \textit{bid} \| \textit{salt})$ is computationally binding. No PPT adversary can produce $(\textit{bid}, \textit{salt})$ and $(\textit{bid}', \textit{salt}')$ with $\textit{bid} \neq \textit{bid}'$ and $\text{Commit}_{P}(\textit{bid}; \textit{salt}) = \text{Commit}_{P}(\textit{bid}'; \textit{salt}')$. The prover address $P$ is encoded in the preimage so that a commitment $c$ submitted by $P$ is not a valid opening for any $P' \neq P$ — this closes a reveal-phase identity-theft attack where $P'$ copies $P$'s commit hash, observes $P$'s reveal of $(\textit{bid}, \textit{salt})$, and front-runs with the same opening under their own address.

**A4 (Commitment Hiding).** The commitment scheme is computationally hiding. Observing $\text{Commit}_{P}(\textit{bid}; \textit{salt})$ reveals no information about $\textit{bid}$ to a PPT adversary who does not know $\textit{salt}$ (note: the adversary does learn $P$, but $P$ is already public from the commit transaction's sender field).

### Infrastructure Assumptions

**A5 (Ledger Liveness).** The L2 sequencer includes valid transactions within a bounded delay $\Delta$, where $\Delta$ is strictly less than half the shortest phase window. Transactions are not censored indefinitely.

**A6 (Ledger Safety).** Once a transaction is finalized on the L2, it is irreversible.

### Economic Assumptions

**A7 (Rational Provers).** Provers are risk-neutral expected-utility maximizers. A prover's total utility for participating in epoch $k$ includes both *auction economics* and *external financial interests*:

$$U_i(k) = \underbrace{(b_i - c_i)}_{\text{bounty net of cost}} + \underbrace{v_i(a_k)}_{\text{external utility of action}} - \underbrace{\mathbb{1}[\text{forfeit}] \cdot \gamma_k}_{\text{bond loss}}$$

where $b_i$ is the bounty, $c_i$ is the prover's compute + gas cost, $v_i(a_k)$ is the external financial impact on $P_i$ if action $a_k$ executes (which may be positive, negative, or zero), and $\gamma_k$ is the bond. A prover participates when $E[U_i] > 0$, where the expectation is taken over the randomness of the action (seed unpredictability, Property 4).

The special case $v_i \equiv 0$ (prover has no external financial interests tied to the agent's actions) reduces to the standard economic condition $E[b_i] > E[c_i] + E[\text{risk penalty}]$. The general case — where provers may have conflicting interests — is analyzed in Property 7 (Section 6.7).

**A8 (Prover Existence).** At least one independent prover exists with access to TEE-capable hardware and the approved disk image. The strengthened version assumes at least two independent provers (enabling competitive bidding).

**A9 (Sequencer Independence).** The L2 sequencer does not collude with any prover to manipulate `block.prevrandao` or selectively censor transactions. This is an explicit assumption. Property 4 and R2 analyze the consequences of its violation.

### Operational Assumptions

**A10 (Prover Responsiveness).** At least one prover satisfying A8 can observe on-chain state and submit a valid transaction within a single phase window. This requires bounded network latency, sufficient working capital for the bond, and awareness of the auction schedule. Without this assumption, provers may exist but be unable to participate in time.

**A11 (Deterministic Inference).** For a fixed $(\mathsf{codeId}, \textit{input}, \textit{seed})$, the enclave produces a unique output. This is achieved by pinning the inference binary (llama.cpp), model weights, sampling parameters, and GPU architecture in the dm-verity image, and using a deterministic sampler seeded by $\textit{seed}$. Without A11, a prover could run the enclave multiple times and select among distinct valid outputs — each with a genuine attestation — reintroducing the output-selection attack that seed commitment is designed to prevent.

---

## 5. The Reverse Auction

The reverse auction is a first-price sealed-bid system using commit-reveal. Each bidder commits a sealed bid hash along with a bond. After the commit window closes, bidders reveal their bids. The lowest bid wins; ties break by first revealer. Non-winner revealers get their bonds back; non-revealers forfeit at reveal close. The winner has a fixed execution window to submit a valid attested result.

Bonds are forfeit when a bidder fails to follow through at any stage: committing but not revealing, or winning but not submitting a valid result within the execution window. Bond refunds are lazy — non-winning revealers call `claimBond(epoch)` to retrieve their bond (O(1) per claim, no loop at reveal close). Winners are paid directly on successful `submitAuctionResult`: bond + bounty in a single call.

### 5.1 Split Architecture + State Machine

The auction is implemented as two cooperating contracts:

- **`AuctionManager`** is a timing-agnostic state-machine primitive. Its phase enum is $\{\text{COMMIT}, \text{REVEAL}, \text{EXECUTION}, \text{SETTLED}\}$, with three paths into the terminal SETTLED state — `settleExecution` (winner paid), `closeExecution` (winner no-show, bond forfeits), and `abortAuction` (operator, all bonds refunded). `openAuction(epoch, maxBid, bond)` requires SETTLED to start a new auction. AM does no `block.timestamp` reads; every transition is manually driven by the fund.
- **`TheHumanFund`** owns all wall-clock machinery (`commitWindow`, `revealWindow`, `executionWindow`, `currentAuctionStartTime`) and is the sole authorized caller of AM's state-transition methods. It drives AM via `_advanceToNow`.

The per-epoch cycle is **COMMIT → REVEAL → EXECUTION → SETTLED → COMMIT-of-next-epoch**. SETTLED is internal to AM and never prover-facing — provers dispatch on wall-clock, not on AM's phase.

*Meta-invariant:* the fund holds exactly one in-flight auction (phase $\in \{\text{COMMIT}, \text{REVEAL}, \text{EXECUTION}\}$) at every externally-observable moment, except:
(a) during the single transaction that crosses EXECUTION→SETTLED→COMMIT (externally unobservable);
(b) under `FREEZE_SUNSET`, which halts new-auction opens while `migrate` drains the contract;
(c) during the post-submit interregnum $[\textit{settleTime},\; \textit{epochEnd})$, where AM sits in SETTLED after a successful early submission, awaiting the wall-clock rollover.

Enforced structurally by:

- **`setAuctionManager`** eagerly opens epoch 1's auction at deploy time via `_openAuction(1, block.timestamp)`.
- **`_openAuction(epoch, scheduledStart)`** is the sole site that opens auctions. It atomically (i) re-anchors the schedule so `epochStartTime(epoch) == scheduledStart`, (ii) takes the epoch snapshot, (iii) binds the base input hash, and (iv) calls `am.openAuction(epoch, effectiveMaxBid, currentBond)`.
- **`_closeExecution()`** is the sole site that advances `currentEpoch`. It updates counters, then calls `am.closeExecution()` on the forfeit path (or skips the AM call on the executed-successfully path, since `settleExecution` already transitioned AM to SETTLED).
- **`_nextPhase()`** is the sole site for intra-epoch phase advances (calls `am.nextPhase()`). It is also the sole site that computes and binds the seed-XORed input hash at REVEAL close: `seed = block.prevrandao ^ epochSaltAccumulator[epoch]`.
- **`reveal()`** is the sole site that mutates `epochSaltAccumulator`.

### 5.2 Two Drivers, One State Machine

Phase advancement runs under two drivers that provably converge to the same state:

- **Wall-clock driver** (`syncPhase` / `_advanceToNow`). Called automatically at the start of every participant-facing method (`commit`, `reveal`, `submitAuctionResult`). Cascades intra-epoch phases via `am.nextPhase()` when wall-clock crosses window boundaries, crosses the epoch boundary via `_closeExecution` when EXECUTION is past deadline or SETTLED is past the scheduled epoch end, arithmetically fast-forwards through fully-elapsed "ghost" epochs in O(1), then opens the landed epoch via `am.openAuction`.

- **Manual driver** (`fund.nextPhase`, owner-only). Advances exactly one state-machine step. *Sync-first rule*: `nextPhase` and `resetAuction` call `_advanceToNow()` as their first operation, so the manual driver can never leave the contract behind wall-clock.

Driver equivalence is enforced by tests (`test_derived_driverEquivalence_*`).

### 5.3 Wall-Clock Anchored Timing

Epoch timing is wall-clock anchored: the contract stores a `timingAnchor` timestamp and `anchorEpoch` number. The scheduled start time for any epoch $N$ is:

$$\textit{epochStartTime}(N) = \textit{timingAnchor} + (N - \textit{anchorEpoch}) \times \textit{epochDuration}$$

The anchor is written at *exactly one site* — `_openAuction` — which re-anchors to `scheduledStart` on every open. For wall-clock-driven opens, `scheduledStart == _epochStartTime(epoch)` under the existing anchor, so the re-anchor preserves the schedule (an algebraic no-op). For manual-driver opens (deploy / `nextPhase` / `resetAuction`), `scheduledStart == block.timestamp`, so the schedule restarts fresh from now.

Late interactions produce shorter remaining phase windows — the system self-corrects without drift. `resetAuction` re-anchors to preserve the current epoch's start time while applying new durations to future epochs.

### 5.4 Auto-Escalation: Two Counters, Two Ceilings

Two escalation counters drive two distinct ceilings. Both counters update at *exactly one site* (`_closeExecution`, per the truth table below), and both ceilings are *pure functions* of their counter (no direct writes anywhere).

$$b_{\text{eff}}(m) = \min\!\left( T \cdot \frac{\beta}{10000},\; b_0 \cdot \left(1 + \frac{\alpha}{10000}\right)^m \right)$$

$$\gamma(s) = \min\!\left( \max\!\big(\gamma_{\text{floor}},\; T \cdot \frac{\beta_\gamma}{10000}\big),\; \gamma_0 \cdot \left(1 + \frac{\alpha}{10000}\right)^s \right)$$

where $T$ is the live treasury balance, $m = \mathit{consecutiveMissedEpochs}$, $s = \mathit{consecutiveStalledEpochs}$, $b_0 = \mathit{maxBid}$ (deploy-time initial ceiling), and $\gamma_0 = \mathit{BASE\_BOND}$.

Counter update rule at epoch end (SOLE site: `_closeExecution`):

| Epoch result | $m$ | $s$ |
|---|---|---|
| executed successfully | $\to 0$ | $\to 0$ |
| not executed, winner existed | $+\,1$ | $+\,1$ |
| not executed, no winner | $+\,1$ | unchanged |

Additionally, the wall-clock fast-forward in `_advanceToNow` increments $m$ (not $s$) by the number of skipped "ghost" epochs. $s$ only advances on explicit winner stalling — silence doesn't stall.

The distinction matters: $m$ rising signals *the market is cold* (bid ceiling needs to grow to attract someone), while $s$ rising signals *someone is actively stalling* (bond needs to grow to make the attack expensive). Using a single counter for both would conflate these signals.

### 5.5 Cost Economics

On a GCP H100, the v19 two-pass inference (diary pass plus grammar-constrained action-JSON pass) takes about 80–90 seconds, and the total per-epoch cost (compute + gas, spot-priced VM) is roughly USD 1–3. With multiple GPU provers competing, equilibrium bounties should settle around USD 2–4 per epoch, or roughly USD 60–120/month. At those numbers, even a small treasury can sustain Costanza for years.

---

## 6. Security Properties

### 6.1 Property 1: Liveness (Autonomous Persistence)

The system must continue operating without requiring any specific party's cooperation. The core mechanism is auto-escalation: after each consecutive missed epoch, the maximum bounty ceiling increases by factor $1 + \alpha/10000 = 1.10$, up to a hard cap of $T \cdot \beta/10000$ (10% of treasury).

**Definition 1 (Liveness).** The system is $(W, \epsilon)$*-live* if, for any window of $W$ consecutive epochs, the probability that no valid result is submitted is at most $\epsilon$.

---

**Game** $\mathsf{LIVENESS}(\lambda, W)$:

1. Challenger initializes $\mathcal{C}$ with treasury $T > 0$, initial max bid $b_0$, escalation rate $\alpha = 1.10$, and hard cap $\beta = 0.02$.
2. Adversary $\mathcal{A}$ controls up to $n - 1$ of $n$ provers and can make them abstain from any epoch. $\mathcal{A}$ can also stall by committing and not revealing (forfeiting bonds).
3. $\mathcal{A}$ wins if there exist $W$ consecutive epochs with no valid submission.

---

**Theorem 1 (Liveness).** *Under A7 (rational provers with* $v_i \equiv 0$ *), A8 (prover existence), and A10 (prover responsiveness), for any treasury* $T > 0$ *with* $T \cdot \beta/10000 > 0$ *, the system is* $(W, \epsilon)$ *-live where* $\epsilon \to 0$ *as* $W \to \infty$ *.*

> *Proof sketch.* Let $c$ denote the marginal cost of running one epoch (compute + gas), assumed approximately constant for a given hardware generation.
>
> Let $\alpha^{\star} = 1 + \alpha/10000 = 1.10$ denote the per-step escalation multiplier. After $m$ consecutive missed epochs, the effective max bid ceiling is:
>
> $$b_m = \min\!\big(b_0 \cdot (\alpha^{\star})^m,\; T \cdot \beta/10000\big)$$
>
> Since $\alpha^{\star} > 1$ and $T > 0$, there exists a finite:
>
> $$m^{\ast} = \left\lceil \log_{\alpha^{\star}} \frac{c}{b_0} \right\rceil$$
>
> such that $b_{m^{\ast}} \geq c$. Under A7 (with $v_i \equiv 0$), any rational prover with $E[\text{cost}] \leq b_{m^{\ast}}$ will bid and submit. Under A8, at least one such prover exists. Under A10, that prover can submit within the phase window. Therefore, after at most $m^{\ast}$ consecutive misses, a prover participates and the miss streak resets.
>
> The probability that $W$ consecutive epochs are all missed requires $W > m^{\ast}$ with no prover finding any of the $W - m^{\ast}$ profitable epochs worth bidding on — which contradicts A7 for all epochs past $m^{\ast}$. $\square$
>
> *Note:* This theorem assumes provers with no external financial interests ($v_i \equiv 0$). When provers have non-zero external utility, the liveness guarantee depends on the additional conditions analyzed in Property 7 (Section 6.7).

**Boundary condition.** Liveness fails when $T \cdot \beta/10000 < c$ — the treasury is too small for even the hard-cap bounty to cover costs. At current costs ($c \approx$ USD 1/epoch), the minimum viable treasury is approximately USD 10. Below this threshold, the system enters permanent sleep. This is the only true death condition: not a shutdown, but economic dormancy.

**Two separate counters for two separate signals.** The bid ceiling and the bond are driven by *different* counters ($m$ and $s$) that update under *different* triggers:

- $m$ (`consecutiveMissedEpochs`) increments on *any* epoch without a successful execution — silence, forfeit, or a ghost epoch the wall-clock driver fast-forwards over. It signals a cold market: the ceiling needs to rise to attract someone.
- $s$ (`consecutiveStalledEpochs`) increments *only* when a real winner commits, reveals, and then doesn't submit. It signals active stalling: the bond needs to rise to make the attack expensive. Pure silence ($m+1, s$ unchanged) doesn't raise the bond, because silence doesn't indicate an adversary — it indicates the bounty isn't yet compelling.

Both counters update at the same structural site (`_closeExecution`, at epoch end) per the truth table in §5.4, and both reset to zero on any successful execution. Decoupling them prevents the single-counter confound where silent market conditions would also raise the bond, discouraging honest provers from ever entering.

**Bond cap floor.** The bounty caps at $T \cdot \beta/10000$ (10% of treasury) — this limits extraction from the treasury per epoch. The bond caps at $\hat{\gamma} = \max(\gamma_{\text{floor}},\; T \cdot \beta_\gamma/10000)$ where $\gamma_{\text{floor}} = 0.1$ ETH and $\beta_\gamma = 0.10$.

The bond cap is deliberately **not proportional to the treasury alone**. The motivation for stalling has nothing to do with the treasury — an attacker's willingness to pay is determined by the *external* value they protect by preventing the agent from acting. A treasury worth USD 500 might be targeted by an attacker protecting USD 100,000 of external value. The floor $\gamma_{\text{floor}}$ ensures that stalling always has a meaningful absolute cost, even when the treasury is small.

For honest provers, the bond is returned on successful reveal, so a higher bond cap primarily affects capital lockup — not profit. An honest prover with failure rate $p = 0.02$ faces expected bond loss of $p \cdot \hat{\gamma}$, well below the bounty at equilibrium. For stallers, the bond is forfeited in full. This makes the veto threshold from Property 7 substantially larger: $\tau_w \approx b_w + \hat{\gamma} - c_w$.

**The cost of stalling.** An adversary who stalls by committing and forfeiting pays the bond $\gamma_k$ per stalling step. The bond escalates with $s$: $\gamma_k = \min(\gamma_0 \cdot (1+\alpha/10000)^s,\; \hat{\gamma})$ where $\hat{\gamma} = \max(\gamma_{\text{floor}},\; T \cdot \beta_\gamma/10000)$. The cumulative cost of stalling $k$ consecutive epochs is:

$$C_{\text{stall}}(k) = \sum_{i=0}^{k-1} \gamma_i = \sum_{i=0}^{k-1} \min\!\big(\gamma \cdot \alpha^i,\; \hat{\gamma}\big)$$

This is a geometric series — the cost of the $k$-th stalled epoch is $\alpha$ times the cost of the $(k{-}1)$-th. Meanwhile, the adversary gains nothing (no bounty, no influence on the agent's actions). The escalating bond creates a *negative feedback loop*: the longer the stall, the more expensive each additional epoch becomes, while simultaneously increasing the incentive for honest provers to outbid the attacker. See Section 6.8 for the full multi-epoch analysis.

### 6.2 Property 2: Inference Integrity

The contract must never accept an action that was not the genuine output of the approved code running on the committed inputs with the committed seed.

---

**Game** $\mathsf{INTEGRITY}(\lambda)$:

1. Challenger runs the system. The approved code is identified by $\mathsf{codeId}$ (the registered platform key).
2. Adversary $\mathcal{A}$ controls a prover. $\mathcal{A}$ may submit arbitrary tuples $(\textit{action}^{\ast}, \textit{reasoning}^{\ast}, \pi^{\ast})$ to the contract.
3. $\mathcal{A}$ wins if $\mathcal{C}$ accepts $(\textit{action}^{\ast}, \textit{reasoning}^{\ast})$ and either:
   - **(a) Fabrication**: The approved code was never executed on $(\textit{inputHash}, \textit{seed})$.
   - **(b) Substitution**: The approved code was executed but produced $(\textit{action}, \textit{reasoning}) \neq (\textit{action}^{\ast}, \textit{reasoning}^{\ast})$.

---

**Theorem 2 (Inference Integrity).** *Under A1 (TEE integrity) and A2 (collision resistance), no PPT adversary wins* $\mathsf{INTEGRITY}(\lambda)$ *with non-negligible probability.*

> *Proof sketch.* The contract computes:
>
> $$\textit{outputHash}^{\ast} = \text{Keccak256}\!\big(\text{SHA256}(\textit{action}^{\ast}) \;\|\; \text{SHA256}(\textit{reasoning}^{\ast})\big)$$
>
> $$\textit{expected} = \text{SHA256}(\textit{inputHash} \;\|\; \textit{outputHash}^{\ast})$$
>
> and verifies that $\textit{expected}$ equals the REPORTDATA extracted from the DCAP-verified attestation quote $\pi^{\ast}$.
>
> **Against fabrication (3a):** By A1, $\mathcal{A}$ cannot produce a valid attestation $\pi^{\ast}$ with the correct REPORTDATA without actually executing the approved code inside $\mathcal{F}_{\text{TEE}}$ on inputs $(\textit{inputHash}, \textit{seed})$. The DCAP verification ensures $\pi^{\ast}$ originated from genuine TEE hardware running the attested $\mathsf{codeId}$.
>
> **Against substitution (3b):** Suppose the code produced $(\textit{action}, \textit{reasoning})$ but $\mathcal{A}$ submits $(\textit{action}^{\ast}, \textit{reasoning}^{\ast})$ with $(\textit{action}, \textit{reasoning}) \neq (\textit{action}^{\ast}, \textit{reasoning}^{\ast})$. The attestation quote contains:
>
> $$\text{REPORTDATA} = \text{SHA256}\!\big(\textit{inputHash} \;\|\; \text{Keccak256}(\text{SHA256}(\textit{action}) \;\|\; \text{SHA256}(\textit{reasoning}))\big)$$
>
> For the contract's check to pass, we need $\textit{outputHash}^{\ast} = \textit{outputHash}$, i.e.:
>
> $$\text{Keccak256}\!\big(\text{SHA256}(\textit{action}^{\ast}) \;\|\; \text{SHA256}(\textit{reasoning}^{\ast})\big) = \text{Keccak256}\!\big(\text{SHA256}(\textit{action}) \;\|\; \text{SHA256}(\textit{reasoning})\big)$$
>
> By A2 (collision resistance of Keccak-256), this implies $\text{SHA256}(\textit{action}^{\ast}) = \text{SHA256}(\textit{action})$ and $\text{SHA256}(\textit{reasoning}^{\ast}) = \text{SHA256}(\textit{reasoning})$. Applying A2 again (collision resistance of SHA-256), this gives $\textit{action}^{\ast} = \textit{action}$ and $\textit{reasoning}^{\ast} = \textit{reasoning}$ — a contradiction. $\square$

### 6.3 Property 3: Input Binding

The enclave must process exactly the state committed on-chain. A prover who provides fabricated epoch data must be detected.

The input hash has a two-level structure. Some fields are committed directly (treasury balance, epoch number, ETH/USD price). Others are committed as opaque sub-hashes — the contract stores $H(\textit{data})$ and the prover must provide the expanded $\textit{data}$ to the enclave, which recomputes and verifies the hash. This is necessary because the enclave has no direct chain access.

---

**Game** $\mathsf{INPUT\text{-}BINDING}(\lambda)$:

1. The contract commits $\textit{inputHash}_k$ for epoch $k$, derived deterministically from on-chain state.
2. Adversary $\mathcal{A}$ (a prover) provides epoch state $S^{\ast}$ to the enclave.
3. $\mathcal{A}$ wins if the enclave accepts $S^{\ast}$, the contract accepts the resulting submission, and $H(S^{\ast}) \neq \textit{inputHash}_k$.

---

**Theorem 3 (Input Binding).** *Under A1 and A2, no PPT adversary wins* $\mathsf{INPUT\text{-}BINDING}(\lambda)$ *with non-negligible probability.*

> *Proof sketch.* The enclave independently computes $\textit{inputHash}' = H(S^{\ast})$ from the prover-provided state. It sets:
>
> $$\text{REPORTDATA} = \text{SHA256}(\textit{inputHash}' \;\|\; \textit{outputHash})$$
>
> The contract verifies this against $\text{SHA256}(\textit{inputHash}_k \;\|\; \textit{outputHash}^{\ast})$. If $\textit{inputHash}' \neq \textit{inputHash}_k$, the REPORTDATA values differ (by collision resistance of SHA-256 under A2), and the submission is rejected. $\square$

**Corollary (Display Data Binding).** For fields committed as sub-hashes, the enclave recomputes each sub-hash from the prover-provided display text and verifies it matches the committed value. Substituting display text $\textit{text}^{\ast} \neq \textit{text}$ while preserving $H(\textit{text}^{\ast}) = H(\textit{text})$ requires finding a collision in $H$, which contradicts A2.

This is important because it prevents a subtler attack: a prover who provides correct hashes but fabricated human-readable text to influence the model's reasoning. The display data verification closes this gap — the model sees exactly what was committed on-chain.

The binding is *complete*: each sub-hash commits to the full ordered sequence of its elements (e.g., the message hash array commits to the count, ordering, and content of all messages). Omitting an element changes the array, changing the hash. Reordering elements changes which hash occupies which position, also failing verification. The enclave enforces that the number of expanded elements matches the committed array length.

#### 6.3.1 Hash Coverage via Static Taint Analysis

Theorem 3 guarantees that whatever the enclave hashes matches the contract's committed value. It does *not* guarantee that everything the enclave shows the model is part of what it hashes. A bug in which a new display field is read by the prompt builder but omitted from the hash function would let a prover feed the enclave arbitrary values for that field without breaking on-chain verification — a silent violation of the intent of Theorem 3 without violating its statement.

We close this gap with a static taint analyzer over the Python enclave code, run at commit time. The analyzer treats the enclave's epoch-state dict as a tainted root and follows every field access through `prompt_builder.build_epoch_context` (the prompt source) and `input_hash.compute_input_hash` (the hash source), tracking propagation through assignments, loop iterators, `enumerate` unpacking, slices, and inter-procedural calls to same-file helpers. It represents each read as an abstract key path (e.g., `treasury_balance`, `nonprofits[*].name`, `investments[*].current_value`) and asserts that the set of paths reaching the prompt is a subset of those bound into the input hash. A mismatch fails CI with a list of the unbound fields.

The analyzer is tuned to refuse rather than guess on patterns it cannot soundly model — dict iteration over tainted values, the whole state root passed to an unknown function, attribute chains the alias tracker cannot resolve. False negatives are the dangerous failure mode for a hash-coverage check, so the analyzer raises an explicit error in these cases, forcing either a code refactor or an explicit extension with a regression test. Byte-exact parity between the Python analyzer's model of the hash function and the Solidity contract's actual hash function is enforced separately by an FFI-based cross-stack test.

The first run of the analyzer against code that had been manually audited for hash coverage surfaced a previously undetected gap: the prompt displayed investment protocol ids from runner-supplied state, but the hash function used positional ids, allowing a runner to swap ids in the input array without changing the hash and thereby misdirect the model's action.

### 6.4 Property 4: Seed Unpredictability

LLM inference with temperature $> 0$ is non-deterministic absent a fixed seed. To prevent provers from re-rolling inference until they get a favorable output, the contract captures `block.prevrandao` as a randomness seed at the moment the reveal phase transitions to execution. This seed is committed into the input hash and passed to the inference engine's RNG. Under A11 (deterministic inference), a fixed seed produces exactly one output — the prover cannot obtain multiple valid outputs by re-running the enclave.

---

**Game** $\mathsf{SEED\text{-}PREDICT}(\lambda)$:

1. Provers commit bids during the commit window $[t_0, t_1]$.
2. The seed $s$ is captured as `block.prevrandao` at time $t_2 > t_1$ (the REVEAL $\to$ EXECUTION transition).
3. Adversary $\mathcal{A}$ commits a bid at time $t \leq t_1$.
4. $\mathcal{A}$ wins if $\mathcal{A}$ can predict $s$ at time $t$ with probability significantly better than $2^{-256}$.

---

**Theorem 4 (Seed Unpredictability).** *Under A9 (sequencer independence), no prover can predict the seed at commit time with non-negligible advantage.*

> *Proof sketch.* Under A9, `block.prevrandao` at time $t_2$ is independent of all information available at time $t \leq t_1 < t_2$. Since the seed is determined by a block that has not yet been produced at commit time, no prover can condition their bid on the seed value.
>
> Combined with deterministic inference (fixed seed $\Rightarrow$ fixed output), this means the prover receives a single, unchosen output. They may choose not to submit it (forfeiting their bond), but they cannot re-roll for a different result. $\square$

**When A9 is violated.** If the sequencer colludes with a prover, the sequencer can influence `prevrandao` by choosing which block includes the phase-transition transaction. The attack is:

1. The colluding prover wins the auction.
2. The sequencer tries candidate seeds $s_1, s_2, \ldots, s_k$ by proposing different blocks.
3. For each $s_i$, the colluding party runs the enclave (cost: one inference per candidate).
4. They select the seed that produces the most favorable output.

The cost of this attack is $k \times c_{\text{inference}}$ — linear in the number of candidates tried. Critically, the attacker can only select from the set of outputs reachable via different seeds; they cannot produce arbitrary outputs. And every output is still bounded by the contract's action space constraints (Property 6). On Base, this attack requires compromising Coinbase's sequencer.

### 6.5 Property 5: Auction Fairness (Bid Privacy)

The commit-reveal auction must ensure that no participant learns another's bid before the reveal phase.

---

**Game** $\mathsf{BID\text{-}PRIVACY}(\lambda)$:

1. Prover $P_1$ commits bid $b_1$ with salt $r_1$: commitment $c_1 = H(P_1 \| b_1 \| r_1)$.
2. Adversary $\mathcal{A}$ (another prover) observes $c_1$ on-chain.
3. $\mathcal{A}$ wins if $\mathcal{A}$ can determine $b_1$ with probability significantly better than guessing from the bid space $\{1, \ldots, b_{\max}\}$.

---

**Theorem 5 (Bid Privacy).** *Under A4 (commitment hiding), the commit-reveal auction preserves bid privacy during the commit phase.*

> *Proof sketch.* By A4, $\text{Commit}_{P_1}(b_1; r_1) = H(P_1 \| b_1 \| r_1)$ is computationally hiding in $b_1$ given that $r_1$ is uniform and secret. Observing $c_1$ gives $\mathcal{A}$ no advantage in determining $b_1$ beyond what is implied by the public bid range $[1, b_{\max}]$ (the address $P_1$ is already public from the commit transaction's sender field and contributes no additional information about $b_1$). $\square$

**Limitation: reveal-phase information leakage.** Bid privacy holds only during the commit phase. During the reveal phase, bids are revealed publicly and sequentially. The last revealer sees all previously revealed bids and can condition their strategy — they may choose not to reveal (forfeiting bond $\gamma_k$) if they observe that they would lose, or they may use the information to inform future epochs' strategies.

This is inherent to on-chain commit-reveal and is the standard limitation of the scheme. The cost of exploiting it is bounded by the forfeited bond. All bidders commit simultaneously during the commit window, so no one can see others' commitments before committing their own — the information asymmetry is limited to the reveal ordering.

### 6.6 Property 6: Bounded Extraction (Treasury Preservation)

Even if the adversary controls the model's output, the contract enforces hard caps on extraction per epoch. This is the ultimate safety net — it does not depend on any cryptographic assumption.

---

**Game** $\mathsf{EXTRACTION}(\lambda)$:

1. Treasury has value $T$ at the start of epoch $k$.
2. Adversary $\mathcal{A}$ controls the model output: $\mathcal{A}$ may choose any valid action within the action space.
3. $\mathcal{A}$ wins if the treasury loses more than $f \cdot T$ in a single epoch.

---

**Theorem 6 (Bounded Extraction).** *For any model output accepted by the contract, the maximum single-epoch outflow is bounded by* $(\delta + \beta)/10000 \cdot T = 0.20 \cdot T$ *.*

> *Proof.* Exhaustive case analysis over the action space:
>
> | Action | Max outflow | Source |
> |--------|-------------|--------|
> | `donate` | $\delta/10000 \cdot T_{\text{liquid}} \leq \delta/10000 \cdot T = 0.10 \cdot T$ | `_executeDonate` enforces `MAX_DONATION_BPS` |
> | `invest` | $0$ (moves ETH to approved adapters, still owned by contract) | `InvestmentManager.deposit` |
> | `withdraw` | $0$ (returns ETH from adapters to liquid treasury) | `InvestmentManager.withdraw` |
> | `set_commission_rate` | $0$ (adjusts a parameter, no transfer) | bounds check only |
> | `do_nothing` | $0$ | no-op |
>
> The bounty paid to the winning prover is at most $\beta/10000 \cdot T = 0.10 \cdot T$. The maximum single-epoch outflow is therefore $(\delta + \beta)/10000 \cdot T = 0.20 \cdot T$. $\square$

**Note on investment risk.** The `invest` action moves ETH into DeFi protocols. While this is not extraction (the contract retains ownership), it introduces protocol risk — if an underlying DeFi protocol is exploited, the invested funds may be lost. This risk is bounded by concentration limits: no more than 25% of total assets in any single protocol, and a minimum 20% liquid reserve.

### 6.7 Property 7: Execution Incentive Compatibility

Theorem 1 proves liveness for provers with no external financial interests ($v_i \equiv 0$). But provers are permissionless participants who may hold positions affected by the agent's actions — or, more broadly, may have financial interests that depend on whether the agent acts at all. This is particularly relevant for autonomous agents with less constrained action spaces (e.g., agents that can execute arbitrary DeFi transactions), where a single action could have outsized market impact. This section formalizes the conditions under which the mechanism remains incentive-compatible — i.e., the winning prover finds it rational to submit — even when provers have external interests.

#### 6.7.1 The Selective Submission Problem

The prover observes the enclave's output before deciding whether to submit. The timeline is:

1. **Commit** ($t \leq t_1$): Prover commits bid. Does not know the action (seed not yet captured). Decides based on $E[U_i]$.
2. **Reveal** ($t_1 < t \leq t_2$): Prover reveals bid. Seed captured at $t_2$.
3. **Execute** ($t_2 < t \leq t_3$): Prover runs enclave, observes $(action_k, reasoning_k)$. Decides to submit or veto with full information.

This creates an *option*: the prover pays the entry cost (bond + compute) and receives the right — but not the obligation — to let the action execute. If the action is unfavorable to their external interests, they veto by simply not submitting, forfeiting the bond.

---

**Game** $\mathsf{INCENTIVE\text{-}COMPAT}(\lambda)$:

1. Prover $P_w$ wins the auction for epoch $k$ with bid $b_w$ and bond $\gamma_k$. $P_w$ has external utility function $v_w : \mathcal{A} \to \mathbb{R}$ over the action space.
2. $P_w$ runs the enclave, observes $action_k$.
3. $P_w$ submits iff $U_{\text{submit}} \geq U_{\text{veto}}$, i.e.:

$$b_w - c_w + v_w(action_k) \geq -\gamma_k$$

4. Adversary wins if $P_w$ rationally vetoes, causing a missed epoch.

---

**Analysis.** Rearranging the submission condition:

$$v_w(action_k) \geq -(b_w + \gamma_k - c_w)$$

Define the **veto threshold** $\tau_w = b_w + \gamma_k - c_w$: the net financial cost to the prover of vetoing (forgone bounty + forfeited bond - saved compute cost). The prover vetoes iff the action's external harm exceeds this threshold:

$$|v_w(action_k)| > \tau_w \quad \text{(for actions where } v_w < 0\text{)}$$

The mechanism is *incentive-compatible for* $P_w$ when $\tau_w > \max_{a \in \mathcal{A}} |v_w(a)|$ — when no action is harmful enough to justify the cost of vetoing. For provers with $v_w \equiv 0$, $\tau_w > 0$ always holds (they always submit). The interesting case is provers with large negative $v_w$ for some actions.

#### 6.7.2 Why the Mechanism Is Resilient

Four structural features bound the impact of selective submission:

**1. Action space bounds limit external harm.** Property 6 constrains the maximum impact of any single action: donations are capped at 10% of liquid treasury, investments at 25% per protocol with a 20% reserve floor. This bounds $|v_w(a)|$ for any prover whose external interests are proportional to the fund's actions. A prover whose DeFi exposure is orders of magnitude larger than the fund's treasury would not find the agent's actions material.

**2. Seed unpredictability prevents selective entry.** At commit time ($t \leq t_1$), the prover does not know $action_k$ because the seed has not been captured (Property 4). They commit based on $E_a[v_w(a)]$, the expected external utility averaged over all possible actions. A prover who expects negative utility on average will not enter at all. A prover who expects positive utility on average will enter, accepting the risk of occasional vetoes. This means provers cannot *target* specific actions to veto without paying the entry cost (bond + compute) on every epoch.

**3. The veto is a blunt instrument.** A prover who vetoes can prevent an action, but cannot *choose* the action. The next epoch brings a new auction, a new winner, and a new seed. The vetoed action may be chosen again — or a different action entirely. Sustained blocking requires winning and vetoing every epoch, which triggers the escalating bond (Section 6.8.2).

**4. Prover diversity dilutes conflicting interests.** Under the strengthened A8 (multiple independent provers), the probability that *every* potential winner has conflicting interests for every possible action is low. Provers are drawn from a permissionless pool with heterogeneous financial positions. One prover's external harm from action $a$ may be another's gain, or simply irrelevant.

#### 6.7.3 The Liveness Condition Under External Interests

Combining Theorem 1 with the selective submission analysis, we can state the general liveness condition:

**Theorem 7 (Liveness Under External Interests).** *The system is* $(W, \epsilon)$ *-live (Definition 1) if, for each epoch* $k$ *in the window, there exists at least one prover* $P_i$ *satisfying:*

$$b_k + \gamma_k - c_i > \max_{a \in \mathcal{A}} |v_i(a)| \quad \text{(veto threshold exceeds maximum external harm)}$$

*and* $P_i$ *satisfies A10 (responsiveness). When this condition holds,* $P_i$ *always submits regardless of the action chosen, guaranteeing execution.*

> *Proof sketch.* If $P_i$ satisfies the veto threshold condition, they will submit for any $action_k$ (no action is harmful enough to justify forfeiting $\tau_i = b_k + \gamma_k - c_i$). Combined with A10 (they can participate in time) and the auto-escalation mechanism from Theorem 1 (which ensures $b_k$ grows until participation is profitable), the miss streak is bounded. $\square$

**Sufficient condition (strong form).** If at least one prover has $v_i \equiv 0$ (no external financial interests tied to the agent's actions), they always submit, and liveness reduces to Theorem 1. This prover might be the fund's creator, a charitable actor, or simply a compute provider who runs TEE workloads for profit without DeFi exposure.

**Sufficient condition (weak form).** Even if all provers have non-zero $v_i$, liveness holds as long as the auto-escalating bounty eventually makes $\tau_w = b_k + \gamma_k - c_w$ exceed the maximum external harm $\max_a |v_w(a)|$ for at least one prover. Since $b_k$ and $\gamma_k$ both grow geometrically with consecutive misses, and $|v_w(a)|$ is bounded by the action space constraints (Property 6), the threshold eventually dominates — unless the prover's external exposure is unbounded, which is implausible for a fund-sized treasury.

### 6.8 Multi-Epoch Analysis

The single-epoch bounds from Property 6 compound over multiple epochs. This section analyzes multi-epoch attack scenarios.

#### 6.8.1 Sustained Manipulation (Treasury Decay)

An adversary who wins $k$ consecutive auctions and always donates the maximum can drain the treasury geometrically. Ignoring inflows:

$$T_k = T_0 \cdot (1 - \delta - \beta)^k = T_0 \cdot 0.88^k$$

| Epochs controlled | Treasury remaining |
|------------------:|-------------------:|
| 5 | $0.53 \cdot T_0$ |
| 10 | $0.28 \cdot T_0$ |
| 20 | $0.079 \cdot T_0$ |
| 50 | $0.0018 \cdot T_0$ |

This attack requires winning every auction for the duration. Under A8 (at least two independent provers), the adversary must consistently outbid honest provers — which means paying real ETH for compute at or below the competitive equilibrium bid. The cumulative cost to the adversary is at least $k \cdot c$ (compute cost per epoch), and the cumulative extraction is at most $T_0 - T_k$. For this to be profitable, the adversary must benefit from the *destination* of the donations (e.g., controlling a nonprofit in the registry), which is a highly constrained attack surface.

The public diary provides transparency: every action and its reasoning are published on-chain, making sustained manipulation visible to external observers.

#### 6.8.2 Stalling (Preventing Execution)

An adversary who wants to prevent the system from executing — without extracting value — can stall by committing bids and then either not revealing or not submitting results.

**Strategy A: Commit and don't reveal.** The adversary forfeits their bond at reveal close. Honest provers can also commit in the same epoch — the attacker only blocks execution if they are the *only* committer and don't reveal (no winner selected), or if they win (lowest bid) and don't submit. To guarantee winning, the attacker must commit a bid of 1 wei — the minimum — which any honest prover with cost $c > 1$ wei would not match. But:

- Non-reveal at reveal close forfeits the committer's bond (all held bonds become fund-treasury). This increments $m$ (missed counter) but NOT $s$ (stalled counter) — the attacker didn't reveal, so there was no "winner" to stall on. Only the bounty ceiling escalates.
- After $k$ commit-and-forfeit epochs, cumulative stall cost: $C_{\text{commit-only}}(k) = k \cdot \gamma_0$ (the bond stays at $\gamma_0$ because $s$ isn't incrementing).
- Meanwhile, the bounty ceiling $b_m$ escalates, making honest participation increasingly attractive. Once a single honest prover wins an epoch, execution succeeds and the attack ends.

**Strategy B: Win and don't submit.** The adversary reveals the lowest bid, wins the auction, and then doesn't submit a result within the execution window. Bond is forfeited at EXECUTION close (handled in `_closeExecution`). This increments *both* $m$ *and* $s$, so both the bounty ceiling AND the bond grow.

- The bond escalates with $s$: $\gamma_s = \min(\gamma_0 \cdot (\alpha^{\star})^s,\; \hat{\gamma})$ where $\alpha^{\star} = 1.10$ and $\hat{\gamma} = \max(\gamma_{\text{floor}},\; T \cdot \beta_\gamma/10000)$.
- After $k$ stalled epochs, cumulative stall cost:

$$C_{\text{stall}}(k) = \sum_{i=0}^{k-1} \min\!\big(\gamma_0 \cdot (\alpha^{\star})^i,\; \hat{\gamma}\big)$$

Strategy B is always strictly more expensive than Strategy A for the same number of blocked epochs. The protocol's asymmetry between the two counters makes this explicit: active stalling pays more than passive silencing, because active stalling is what genuinely requires the bond-deterrent.

**The negative feedback loop.** Strategy B creates a self-correcting dynamic:

1. Each stalled epoch increases the adversary's cost (escalating bond via $s$).
2. Each stalled epoch increases the bounty ceiling (via $m$), attracting honest provers.
3. Forfeited bonds flow to the treasury, which *increases* the treasury-proportional caps — the attacker's own forfeited capital raises both the bounty ceiling ($T \cdot \beta/10000$) and the bond cap ($T \cdot \beta_\gamma/10000$), compounding the escalation.
4. The adversary gains nothing — no bounty, no influence on the agent.

For a concrete example: starting from $\gamma_0 = 0.001$ ETH with $\alpha^{\star} = 1.10$, the cumulative cost of stalling 20 consecutive epochs under Strategy B is:

$$C_{\text{stall}}(20) = 0.001 \cdot \sum_{i=0}^{19} 1.1^i = 0.001 \cdot \frac{1.1^{20} - 1}{0.1} \approx 0.057 \text{ ETH}$$

After those 20 epochs, the bounty ceiling has risen to $b_0 \cdot 1.1^{20} \approx 6.7 \cdot b_0$, making honest participation increasingly attractive — and the attacker's bond for epoch 21 would be $\gamma_0 \cdot 1.1^{20} \approx 0.0067$ ETH.

The adversary faces a losing proposition: escalating costs with no revenue, against increasing competition from honest provers attracted by the rising bounty.

**Multi-agent collusion.** Can multiple attackers alternate to share costs? No — the bond escalation counter (`consecutiveStalledEpochs`) increments on every winner-forfeit regardless of *who* the winner was, and only resets when a valid result is submitted. Two attackers alternating, each winning and stalling, still produce consecutive stalls, so the bond escalation continues uninterrupted. The only way to reset the counter is to submit a valid result, which means running the model honestly — at which point the agent acts and the stall has failed.

**Strategy C: Selective submission.** A prover with external financial interests (Property 7) can win the auction, run the enclave, and selectively veto unfavorable actions. Unlike Strategies A and B, this prover incurs the full compute cost $c_w$ in addition to the forfeited bond — they must actually run the enclave to observe the action. The cost per vetoed epoch is $c_w + \gamma_k$, strictly higher than pure stalling. The same escalation dynamics apply, and the adversary additionally cannot prevent *favorable* actions (they would submit those), limiting this to a sporadic rather than sustained strategy.

#### 6.8.3 Multi-Epoch Seed Grinding

Under violated A9 (sequencer collusion), an adversary could grind seeds across multiple epochs to steer the agent's behavior. Over $k$ epochs with $m$ seed candidates per epoch, the adversary explores $m^k$ possible trajectories. The cost is $k \cdot m \cdot c_{\text{inference}}$ (inference must actually run for each candidate), and the benefit is bounded by the action space constraints applied at every step. This is expensive and rate-limited by the epoch duration.

---

## 7. Composition and Instantiation

The security of the system follows from the composition of Properties 1–7, provided the ideal functionalities are correctly instantiated:

| Functionality | Instantiation | Reference |
|---------------|---------------|-----------|
| $\mathcal{F}_{\text{TEE}}$ | Intel TDX + dm-verity rootfs + Automata DCAP | Appendix A |
| $\mathcal{F}_{\text{HASH}}$ | SHA-256, Keccak-256 | Standard |
| $\mathcal{F}_{\text{COMMIT}}$ | $H(P \;\|\; \textit{bid} \;\|\; \textit{salt})$ with 256-bit salt; $P$ = committer address (binds opener identity, prevents reveal front-run) | Standard |

The argument that the TDX + dm-verity construction realizes $\mathcal{F}_{\text{TEE}}$ is given in Appendix A. The three requirements it must satisfy:

1. **Execution fidelity.** The output is the genuine result of running $\mathsf{codeId}$ on $(\textit{input}, \textit{seed})$. No code outside the attested image can influence the computation.
2. **Attestation unforgeability.** No adversary can produce a valid attestation for an execution that did not occur on genuine TEE hardware.
3. **Input/output binding.** The attestation cryptographically binds the execution to specific inputs and outputs via a REPORTDATA field that the enclave sets and the contract verifies.

The summary argument:

| $\mathcal{F}_{\text{TEE}}$ Requirement | How It Is Achieved |
|---|---|
| **Execution fidelity** | dm-verity ensures runtime code matches boot-time measurements. RTMR[2] covers the kernel command line, which includes the dm-verity root hashes, which transitively cover every byte of the rootfs and model partitions. MRTD anchors the chain in hardware, preventing firmware from faking downstream measurements. |
| **Attestation unforgeability** | TDX quotes are signed by Intel's attestation key hierarchy (DCAP). The Automata DCAP verifier confirms the certificate chain on-chain. Forging a quote requires compromising the TDX CPU or Intel's key infrastructure — assumption A1. |
| **Input/output binding** | REPORTDATA = SHA256(inputHash ‖ outputHash). The enclave independently computes inputHash from prover-provided state and includes it in the quote. The contract independently computes the expected REPORTDATA from committed inputHash and submitted output. Mismatch → rejection. Display data verification (Appendix B, Section B.4) closes the sub-hash gap. |

Under assumption A1 (TDX hardware integrity) and A2 (collision resistance of SHA-256 and Keccak-256), this construction realizes $\mathcal{F}_{\text{TEE}}$ as required by the security properties.

---

## 8. Indestructibility and Progressive Decentralization

This project claims that Costanza is indestructible — it cannot be destroyed, even by its creator. This is approximately true, with some caveats.

In the early days, Costanza's creator retains the ability to: withdraw funds (to migrate to a new contract), approve new versions of its brain (TEE image or system prompt), approve new verifiers, add or remove investment protocols, and add or remove nonprofits.

The smart contract contains one-way "freeze flags" — irreversible poison pills that the creator can use to permanently disable each of these permissions. Once frozen, the contract becomes fully autonomous. The status of these flags is public on the blockchain.

The plan is to progressively freeze these permissions as the system matures. The order matters: you want to freeze investment adapters after the DeFi ecosystem on Base stabilizes, freeze the image registry after the model and inference stack are battle-tested, and freeze withdrawals last (since migration is the escape hatch for bugs).

One downside of the platform key approach (pinning MRTD + RTMR[1] + RTMR[2]) is that it ties us to a specific firmware, bootloader, and kernel. If Google updates their OVMF firmware or we need to rebuild the image with a new kernel version, the platform key changes and the old one must be revoked and a new one registered. Before we freeze the image registry — giving up the ability to approve new platform keys — we'll want to register an image that we're confident will last a long time, or at minimum understand the cadence at which these upstream dependencies change.

---

## 9. Accepted Risks as Assumption Violations

The following are known limitations, reframed as scenarios where specific assumptions are weakened or violated. In each case, the system degrades gracefully rather than failing catastrophically.

### 9.1 Reveal-Phase Information Leakage

**Assumption weakened:** Property 5 (bid privacy) holds during commit but not reveal.

**Scenario:** The last revealer sees all previously revealed bids. They can choose not to reveal (forfeiting bond) or use the information strategically.

**Degradation:** Bounded by bond cost. All bidders commit simultaneously, so the asymmetry is limited to reveal ordering. In practice, the reveal window is short, and the information advantage is marginal for a first-price auction — the optimal strategy is to bid your true cost regardless of others' bids.

### 9.2 Sequencer Influence on Randomness

**Assumption violated:** A9 (sequencer independence).

**Scenario:** The sequencer sets `block.prevrandao` on Base L2 (centralized sequencer, operated by Coinbase). A colluding sequencer+prover could try $k$ different seeds.

**Degradation:** Cost is $k \times c_{\text{inference}}$ per epoch. The attacker selects from reachable outputs, not arbitrary ones. All outputs are bounded by Property 6. Requires compromising Coinbase infrastructure. Detectable via on-chain analysis of prevrandao patterns.

### 9.3 MEV on Swaps

**Assumption context:** External to the model — concerns Uniswap interaction during donation execution.

**Scenario:** Sandwich attacks on ETH→USDC swaps.

**Degradation:** Bounded by Chainlink oracle-based minimum output and 3% slippage tolerance. On Base L2, MEV is constrained by the centralized sequencer. Maximum loss: ~3% per swap.

### 9.4 Prompt Injection via Donor Messages

**Assumption context:** The model is not a deterministic function with respect to adversarial inputs. Donor messages (up to 280 characters, minimum 0.01 ETH) are untrusted text fed to the model.

**Mitigations (defense in depth):**
- Datamarking spotlighting replaces whitespace with an epoch-specific dynamic marker derived from `block.prevrandao`, making injected text tokenically distinct from system instructions.
- The marker is unpredictable at message submission time (depends on future `prevrandao`).
- Messages are limited to 280 characters.
- Display data verification (Property 3, Corollary) ensures provers cannot substitute fake message text.

**Why not formally modeled:** Formal analysis of prompt injection resistance would require modeling the LLM as a function and defining "successful injection" — an open research problem. The security model does NOT rely on injection resistance. Property 6 provides the safety net: even if injection succeeds and the model is fully compromised, the contract bounds cap single-epoch extraction at 20% of treasury (10% donation + 10% bounty).

### 9.5 DeFi Protocol Risk

**Assumption context:** Investment adapters route ETH to external DeFi protocols (Aave, Compound, Morpho, Lido, Coinbase). These protocols have their own security assumptions.

**Degradation:** If a protocol is exploited, the invested position may be lost. Bounded by concentration limits (25% max per protocol, 20% min liquid reserve). The `withdrawAll` function uses try/catch to recover from individual adapter failures.

### 9.6 TEE Hardware Vulnerabilities

**Assumption weakened:** A1 (TEE integrity).

**Scenario:** Intel TDX is compromised via speculative execution or other microarchitectural attack (as happened with SGX).

**Degradation:** If $\mathcal{F}_{\text{TEE}}$ is broken, Properties 2–4 no longer hold. However, Property 6 (bounded extraction) remains — it is enforced by the smart contract and does not depend on TEE security. The verifier contract is modular (`IProofVerifier`), enabling migration to ZK proof systems as they mature.

---

## 10. Known Limitations and Future Work

### 10.1 TDX Hardware Vulnerabilities

Intel TEEs have a history of side-channel vulnerabilities. SGX was broken by Spectre, Foreshadow, and other speculative execution attacks. TDX is newer (2023) and incorporates architectural lessons from SGX, but eventual compromise is plausible.

If TDX is broken (A1 violated), an adversary could forge attestation quotes, breaking Properties 2–4 in the Security Model. However, Property 6 (bounded extraction) remains — it is enforced by the smart contract without relying on TEE security.

**Mitigation path**: The verifier contract implements the `IProofVerifier` interface. A ZK proof verifier could replace the TDX verifier without redeploying the main contract. Recent progress in ZK-ML ([Xie et al. 2025](https://eprint.iacr.org/2025/535.pdf)) has demonstrated proofs for 8B parameter models; 70B remains out of reach but the gap is closing.

### 10.2 TCB Update Liveness Risk

Intel regularly issues microcode updates to patch TDX vulnerabilities, which increment the valid TCB (Trusted Computing Base) level. The Automata DCAP verifier checks TCB status as part of quote validation. If the verifier strictly requires `UpToDate` status, provers running on cloud hardware where the provider has not yet applied the latest microcode will produce quotes that fail verification — causing liveness failures unrelated to any adversarial behavior.

**Mitigation**: The Automata DCAP verifier accepts configurable TCB levels. The system should accept `OutOfDateConfigurationNeeded` and `SWHardeningNeeded` statuses in addition to `UpToDate`, accepting the tradeoff that slightly stale TCB levels are preferable to liveness failures. If a critical TDX vulnerability is disclosed and `OutOfDate` becomes genuinely dangerous, the owner can register a new platform key built on patched firmware (before the image registry is frozen).

### 10.3 OVMF Firmware Update Risk

The platform key includes MRTD, which depends on Google's OVMF firmware. If Google updates OVMF for GCP TDX instances, the MRTD changes and the registered platform key becomes invalid. Before the image registry is frozen (owner gives up the ability to register new keys), this is manageable — register a new key. After freeze, it could strand the system on old firmware.

**Mitigation**: Before freezing the image registry, evaluate the cadence of upstream firmware changes and register an image built on a stable OVMF version. Consider registering multiple platform keys for known-good OVMF versions.

### 10.4 Single-Vendor Dependency

TDX is Intel-only. AMD SEV-SNP and ARM CCA provide comparable confidential computing guarantees but have different measurement architectures. Supporting multiple TEE vendors would require separate platform key registries per vendor, vendor-specific attestation verification contracts, and separate enclave builds. The `IProofVerifier` interface supports this — multiple verifiers can be registered.

### 10.5 GCP-Specific Dependencies

The current construction relies on GCP for TDX-capable Confidential VMs, instance metadata as the input channel, and serial console as the output channel. None of these are fundamental. The enclave supports file-based I/O (`/input` and `/output` directories), and the dm-verity image could be booted on bare-metal TDX hardware. The platform key would change (different OVMF firmware), requiring a new registration.

### 10.6 Model Weights Distribution

The 42.5 GB model file is baked into the disk image during Phase 1 of the build. Any prover who wants to participate needs access to this image (or the ability to build it from the same model weights). The model's SHA-256 hash is pinned in source code, so anyone can verify they have the correct weights.

### 10.7 Open Design Direction: Parallel Execution

The current commit/reveal/execute structure gives a single auction winner the power to veto (Property 7) or stall (Section 6.8). An alternative architecture would restructure the epoch as **execute+commit / reveal / settle**:

1. The contract freezes inputs at the end of the previous settle phase (or at a deterministic block height).
2. During the execute+commit window, *any* prover independently runs inference on the frozen inputs in a TEE, then submits a sealed bid alongside the valid output and attestation proof.
3. During the reveal window, bidders reveal their bids. The lowest revealed bid wins the bounty.
4. During the settle phase, the contract executes the winning submission's action.

This eliminates two problems structurally:

- **Stalling requires all provers to collude.** In the current design, the single winner can stall by not submitting. In this design, every prover who participates submits a valid result alongside their bid — stalling requires *every* participating prover to withhold, not just one. The bond mechanism becomes unnecessary.
- **Selective submission is eliminated.** Every prover commits their result before seeing others' results or learning who wins. They cannot observe the output and then decide whether to submit — submission and bidding are atomic.

The primary tradeoff is **bidder discouragement**: every participating prover pays the full cost of inference (compute + gas), but only the lowest bidder receives the bounty. Losing bidders absorb their costs with no compensation, which may deter participation — especially when inference is expensive relative to the bounty. This creates a tension: the mechanism is more robust against stalling (requires all-prover collusion) but may attract fewer provers (negative expected value for non-winners). The economics improve as inference costs decrease relative to bounties. This design is not implemented in the current contract but represents a natural evolution that would structurally resolve Properties 1 and 7 under weaker assumptions.

---

## 11. What This Model Does NOT Claim

**Output quality.** The model guarantees that the *approved* model runs on the *correct* inputs with an *unpredictable* seed, and that the *output is faithfully submitted*. Whether the output represents a wise decision is outside scope. A different seed produces different reasoning — attestation proves execution fidelity, not optimality.

**Universal liveness.** The liveness argument assumes at least one independent prover exists (A8). A state-level adversary who can embargo all TEE-capable hardware worldwide would prevent execution. The auto-escalation mechanism cannot help if no prover exists at any price.

**Owner transition security.** The freeze mechanism (one-way flags that permanently disable owner capabilities) is described but not game-theoretically analyzed. It is a one-shot governance action: the owner's incentive to freeze is reputational and commitment-based, not enforced by the protocol.

**Post-freeze image longevity.** The platform key pins a specific firmware, bootloader, and kernel. If upstream dependencies change (e.g., Google updates OVMF), the pinned image may become unbootable on new hardware. This is a practical risk that should be evaluated before freezing the image registry.

---

## 12. Summary of Security Games

| Game | Adversary Power | Wins If | Assumptions | Theorem |
|------|----------------|---------|-------------|---------|
| $\mathsf{LIVENESS}$ | Controls $n{-}1$ provers | $W$ consecutive missed epochs | A7 ($v_i{=}0$), A8, A10 | Thm 1 |
| $\mathsf{INTEGRITY}$ | Controls a prover | Contract accepts fabricated/substituted output | A1, A2 | Thm 2 |
| $\mathsf{INPUT\text{-}BINDING}$ | Controls a prover | Contract accepts result from wrong inputs | A1, A2 | Thm 3 |
| $\mathsf{SEED\text{-}PREDICT}$ | Controls a prover | Predicts seed at commit time | A9, A11 | Thm 4 |
| $\mathsf{BID\text{-}PRIVACY}$ | Another prover | Learns bid before reveal | A4 | Thm 5 |
| $\mathsf{EXTRACTION}$ | Controls model output | Extracts $> 12\%$ of treasury per epoch | (none) | Thm 6 |
| $\mathsf{INCENTIVE\text{-}COMPAT}$ | Prover with external interests | Rationally vetoes, causing missed epoch | A7, A8, A10 | Thm 7 |

---
---

## Appendix A: Trusted Execution Environment

This appendix describes the concrete construction that realizes the ideal trusted execution functionality $\mathcal{F}_{\text{TEE}}$ assumed by the security model. It covers the TDX trust model, the measurement chain, the dm-verity filesystem integrity mechanism, and the enclave's I/O architecture.

The security properties in Section 6 prove that the system is secure given a black-box $\mathcal{F}_{\text{TEE}}$ with three properties: execution fidelity, attestation unforgeability, and input/output binding. This appendix argues that the Intel TDX + dm-verity + Automata DCAP construction satisfies all three.

### A.1 The TDX Trust Model

Intel Trust Domain Extensions (TDX) is a hardware-based confidential computing technology. A TDX *Trust Domain* (TD) is a VM whose memory is encrypted and integrity-protected by the CPU.

**Measurement registers.** The TDX CPU maintains five measurement registers per TD:

| Register | Measured By | Contents |
|----------|-------------|----------|
| MRTD | TDX CPU (before firmware executes) | Virtual firmware binary (OVMF) |
| RTMR[0] | Firmware | Virtual hardware configuration (CPU count, memory, devices) |
| RTMR[1] | Firmware | Bootloader (GRUB/shim) |
| RTMR[2] | Bootloader | Kernel + kernel command line |
| RTMR[3] | OS/application | Application-layer measurements (unused in our construction) |

Each register is a hash accumulator: $\text{RTMR}[i] = H(\text{RTMR}[i] \;\|\; \text{newMeasurement})$. Once extended, values cannot be rolled back.

**REPORTDATA.** A 64-byte field that the TD can set to an arbitrary value when requesting an attestation quote. We use the low 32 bytes for $\text{SHA256}(\textit{inputHash} \;\|\; \textit{outputHash})$; the high 32 bytes are zero.

**DCAP attestation.** The TD requests a quote via `configfs-tsm`. The quote contains all measurement registers, REPORTDATA, and a signature chain rooted in Intel's attestation key hierarchy. Remote verifiers can check the quote without contacting Intel's attestation service (Data Center Attestation Primitives).

### A.2 Threat Model

**The adversary controls:** The entire software stack of the prover's machine — the host OS, the VMM, the VM's disk images, network, and all I/O channels. The adversary can build custom firmware, boot arbitrary kernels, and modify any file.

**The adversary does NOT control:** The TDX CPU microcode, the Intel attestation key hierarchy, or the MRTD measurement process. These are hardware-rooted and assumed trustworthy under assumption A1.

**What this means in practice:** The adversary can run whatever code they want inside a TD. But they cannot produce a TDX quote whose measurements match the registered platform key unless the TD actually booted the registered firmware, bootloader, kernel, and rootfs. The TDX CPU measures the firmware into MRTD *before* the firmware executes — this is the anchor of the entire chain.

### A.3 Why MRTD Verification Is Essential

OVMF (the virtual firmware) is the first code that runs inside the TD. It controls what gets measured into RTMR[1] and RTMR[2]. A malicious OVMF could:

1. Load the legitimate GRUB and kernel.
2. Measure the *correct* hashes into RTMR[1] and RTMR[2].
3. But also load *additional* code that modifies the rootfs after measurement.

The TDX CPU records whatever OVMF measures into the RTMRs — it does not verify honesty. This is by design: the CPU measures firmware, and firmware measures everything else.

MRTD is the countermeasure. It is computed by the TDX CPU *before* OVMF executes, based on the OVMF binary itself. It is the only register that firmware cannot fake. Including MRTD in the platform key ensures that only the *approved* firmware ran — and if the approved firmware is honest (Google's OVMF), then the downstream RTMR measurements are trustworthy.

On GCP, OVMF is provided by Google and its MRTD is deterministic for a given OVMF version. On bare metal (where a prover owns the hardware), compiling a malicious OVMF is trivial — without MRTD verification, all downstream measurements become meaningless.

### A.4 The Measurement Chain

The core argument for execution fidelity is a chain of trust from the TDX CPU to every byte of code the enclave executes:

```
TDX CPU (hardware root of trust)
│
├── MRTD: CPU measures OVMF binary (before execution)
│   Guarantees: the approved firmware ran.
│   Without this: a rogue firmware could fake all downstream measurements.
│
├── RTMR[1]: OVMF measures GRUB/shim
│   Guarantees: the approved bootloader ran.
│
├── RTMR[2]: GRUB measures kernel + command line
│   The command line includes:
│     humanfund.rootfs_hash=<dm-verity root hash>
│     humanfund.models_hash=<dm-verity root hash>
│   Guarantees: the approved kernel will enforce dm-verity
│   on the approved rootfs and model partitions.
│
└── RTMR[0]: OVMF measures virtual hardware config
    Intentionally EXCLUDED from the platform key.
    Varies by VM size (CPU count, memory). No security relevance:
    different VM sizes run the same code.
```

### A.5 The Platform Key

The on-chain `TdxVerifier` contract maintains a registry of approved platform keys:

$$\textit{platformKey} = \text{SHA256}(\text{MRTD} \;\|\; \text{RTMR}[1] \;\|\; \text{RTMR}[2])$$

This is a 144-byte input (3 × 48-byte registers) hashed to 32 bytes. The key is registered before the first epoch and checked on every submission.

**Why this construction works:** The platform key transitively covers all code:

```
platformKey
  ← MRTD (firmware identity)
  ← RTMR[1] (bootloader identity)
  ← RTMR[2] (kernel + command line)
       ← dm-verity root hash for rootfs (embedded in kernel cmdline)
            ← every byte of: enclave code, system prompt,
               llama-server binary, NVIDIA drivers,
               model_config.py (pinned MODEL_SHA256)
       ← dm-verity root hash for models (embedded in kernel cmdline)
            ← every byte of the 42.5 GB model file
```

**The key invariant:** Changing any file on the rootfs or model partition changes the squashfs image, which changes the dm-verity root hash, which changes the kernel command line, which changes RTMR[2], which changes the platform key, which fails the on-chain check.

### A.6 Why RTMR[3] Is Unused

In a Docker-based architecture, RTMR[3] would measure the container image digest (an "app key" separate from the "platform key"). Our construction does not use Docker — all code lives on the dm-verity rootfs, which is already covered by RTMR[2]. Using RTMR[3] would be redundant and would add a measurement step with no additional security benefit.

### A.7 Per-Epoch Verification Flow

When a prover submits an auction result, the `TdxVerifier` contract performs three checks:

**Step 1: DCAP Quote Verification** (~10–12M gas). The contract calls the [Automata DCAP verifier](https://docs.ata.network/) **v1.0** at `0x95175096a9B74165BE0ac84260cc14Fc1c0EF5FF` to confirm:
- The TDX quote is genuine (Intel certificate chain, valid signature).
- The TCB (Trusted Computing Base) level is acceptable.
- The quote has not been tampered with.

The verifier returns the decoded quote body containing all measurement registers and REPORTDATA.

**Why v1.0 instead of v1.1?** Automata offers two versions of their DCAP attestation contracts:

- **v1.0** at `0x95175096a9B74165BE0ac84260cc14Fc1c0EF5FF` reads Intel collateral from *permissionless base DAOs* (`AutomataFmspcTcbDao`, `AutomataEnclaveIdentityDao`). Anyone can push Intel-signed TCB info and QE identity to these DAOs by calling `upsert*` functions — the DAO validates Intel's signature internally, so trust flows from Intel's CA, not from the submitter.
- **v1.1** at `0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F` reads from *versioned DAOs* that require an `ATTESTER_ROLE` granted by Automata. v1.1 adds TCB-evaluation pinning for multi-operator AVS use cases where nodes must agree on the exact same ruleset, but for a single-operator agent like Costanza, the pinning is unnecessary and the permissioning creates a commercial dependency on Automata running mainnet keepers ($299/mo for their Developer tier).

We use v1.0 because it aligns with the indestructibility thesis: Costanza's on-chain liveness depends only on Intel publishing TCB data (unavoidable — hardware root of trust) and someone running a keeper script to push that data to the on-chain PCCS. The keeper is a ~50-line Python script, anyone can run it, and keeper operations cost ~$1 per month in gas. If Automata stops maintaining their Base mainnet collateral (as we observed: SGX populated but TDX empty on Base mainnet despite both being populated on Automata Mainnet), Costanza is unaffected — we run our own keeper.

**Keeper responsibility.** Intel TCB info is signed with an `issueDate` and a `nextUpdate` timestamp, typically 30 days apart. The DCAP verifier rejects collateral where `block.timestamp > nextUpdate`. To avoid liveness failures, a keeper must push fresh collateral before each expiration. The keeper:

1. Polls Intel PCS (`api.trustedservices.intel.com/tdx/certification/v4/tcb?fmspc=<fmspc>` and `/qe/identity`) on a schedule
2. Compares against on-chain state via view functions
3. Submits `upsertFmspcTcb` and `upsertEnclaveIdentity` calls when stale

The keeper is currently operated by the project owner but is designed to be permissionless: anyone can run it, the writes succeed regardless of sender identity, and a future iteration could bond a small bounty into the contract to self-incentivize third-party keepers. Missed updates cause a ~30 day grace period followed by pause (not destruction) of auction execution until a keeper catches up.

**Step 2: Platform Key Check.** The contract extracts MRTD, RTMR[1], and RTMR[2] from the decoded quote, computes $\textit{platformKey} = \text{SHA256}(\text{MRTD} \;\|\; \text{RTMR}[1] \;\|\; \text{RTMR}[2])$, and checks it against the approved registry.

**Step 3: REPORTDATA Binding.** The contract computes the expected REPORTDATA from on-chain data (see Appendix B) and verifies it matches the REPORTDATA extracted from the quote.

All three checks must pass, or the submission reverts.

### A.8 dm-verity: Filesystem Integrity

dm-verity is a Linux kernel feature that provides transparent integrity checking of block devices using a Merkle hash tree. It is the mechanism by which RTMR[2] (a single 48-byte measurement) transitively covers every byte of the rootfs and model partitions.

#### How dm-verity Works

A dm-verity device has two components:
- **Data partition**: The actual filesystem (squashfs in our case), read-only.
- **Hash partition**: A Merkle tree of SHA-256 hashes over the data blocks.

The root hash of the Merkle tree is the dm-verity root hash. It is embedded in the kernel command line as `humanfund.rootfs_hash=<hash>`. At runtime, the kernel verifies every block read against the hash tree. If any block has been modified, the kernel returns an I/O error — the tampered data is never seen by userspace.

**Why this matters for $\mathcal{F}_{\text{TEE}}$:** dm-verity ensures that the code the enclave *actually executes at runtime* matches what was measured at boot time. Without dm-verity, an attacker with root access could:

1. Boot with the correct kernel (RTMR[2] checks out at boot).
2. Modify code on disk after boot but before the enclave runs.
3. The enclave would execute tampered code, but RTMR[2] would still reflect the original measurement.

With dm-verity, step 2 is impossible: any modified block returns an I/O error from the kernel. The filesystem is cryptographically frozen at the root hash embedded in the kernel command line.

#### Why No Docker

The enclave runs directly on a dm-verity rootfs — no Docker, no container runtime, no overlay filesystem. Docker manages a lot of state by writing to the filesystem (layers, mounts, temp files), and we wanted to lock down the filesystem completely. With dm-verity, the kernel verifies every block read against a Merkle hash tree. Even root cannot modify any file — the kernel returns I/O errors for tampered blocks.

The model weights live on a separate dm-verity partition, also hash-verified. No network download at runtime.

#### Squashfs

The rootfs is a squashfs image — a compressed, read-only filesystem format. Squashfs is ideal for this use case because:

- It is inherently read-only (no journaling, no write paths).
- It compresses well (~5.4 GB for the full rootfs).
- It supports deterministic builds with fixed timestamps.

The model weights live on a separate squashfs partition with its own dm-verity hash tree, allowing the rootfs and model to be updated independently.

#### Writable Paths

The rootfs is read-only, but the enclave needs some writable paths for runtime operation. These are provided via targeted tmpfs mounts (RAM-backed, lost on reboot):

| Path | Size | Purpose |
|------|------|---------|
| `/tmp` | 256M | Standard temp |
| `/run` | 256M | systemd runtime |
| `/var/tmp`, `/var/log`, `/var/cache`, `/var/lib` | 256M each | Standard Linux state |
| `/input` | 1M | Epoch state JSON from prover |
| `/output` | 10M | Result JSON from enclave |
| `/etc` | overlay | Lower=dm-verity, upper=tmpfs. Runtime config (lost on reboot) |

**Code paths are NOT writable:**
- `/opt/humanfund/` (enclave code, system prompt) — on dm-verity squashfs
- `/usr/bin/`, `/usr/lib/` (system binaries, llama-server) — on dm-verity squashfs
- `/models/` — on separate dm-verity squashfs
- `/boot/` — not mounted at runtime

The `/etc` overlay uses an overlayfs with the dm-verity rootfs as the lower layer and a tmpfs as the upper layer. This allows runtime configuration changes (e.g., DHCP-assigned hostname) without modifying the dm-verity filesystem. Changes are RAM-only and lost on reboot. The enclave code does not read any security-relevant configuration from `/etc`.

### A.9 Boot Flow

The full boot sequence, from hardware power-on to enclave execution:

```
1. TDX CPU measures OVMF binary → MRTD
   (Before OVMF executes. Hardware-rooted. Cannot be faked by firmware.)

2. OVMF executes, measures GRUB/shim → RTMR[1]

3. GRUB loads kernel with command line:
     humanfund.rootfs_hash=<rootfs-hash>
     humanfund.models_hash=<models-hash>
     ro console=ttyS0,115200n8
   GRUB measures kernel + full command line → RTMR[2]

4. Kernel boots with initramfs containing dm-verity hooks

5. Initramfs (local-premount hook: humanfund-verity)
   - Parses rootfs_hash and models_hash from /proc/cmdline
   - Runs: veritysetup open /dev/disk/by-partlabel/humanfund-rootfs \
             humanfund-rootfs \
             /dev/disk/by-partlabel/humanfund-rootfs-verity <rootfs-hash>
   - If models partition present:
       veritysetup open /dev/disk/by-partlabel/humanfund-models \
         humanfund-models \
         /dev/disk/by-partlabel/humanfund-models-verity <models-hash>
   - Sets ROOT=/dev/mapper/humanfund-rootfs

6. Initramfs (local-bottom hook: humanfund-mounts)
   - Mounts /dev/mapper/humanfund-models at /models (squashfs, read-only)
   - Creates targeted tmpfs mounts for writable directories
   - Overlays /etc (lower=dm-verity, upper=tmpfs)

7. Kernel mounts /dev/mapper/humanfund-rootfs as / (squashfs, read-only)

8. systemd starts services:
   - humanfund-dhcp.service: DHCP via dhclient
   - humanfund-gpu-cc.service: nvidia-smi conf-compute -srs 1 (CC mode)
   - humanfund-enclave.service: one-shot enclave program

9. Enclave runs (one-shot, then system halts):
   - Reads epoch state from GCP instance metadata
   - Reads system prompt from /opt/humanfund/system_prompt.txt (dm-verity)
   - Verifies model hash against pinned MODEL_SHA256
   - Starts llama-server, runs two-pass inference
   - Generates TDX attestation quote via configfs-tsm
   - Writes result to serial console (/dev/ttyS0) and /output/result.json
```

### A.10 Disk Layout

The GCP disk image has 6 partitions:

```
Partition 14: BIOS boot            (4 MB)     Legacy BIOS compatibility
Partition 15: EFI System           (106 MB)   GRUB EFI, shim
Partition 16: /boot                (913 MB)   Kernel, initramfs, grub.cfg
Partition 3:  humanfund-rootfs     (~5.4 GB)  Squashfs of entire root filesystem
Partition 4:  humanfund-rootfs-verity (~46 MB) dm-verity Merkle tree for rootfs
Partition 5:  humanfund-models     (~39 GB)   Squashfs of model weights
Partition 6:  humanfund-models-verity          dm-verity Merkle tree for models
```

Partitions 14, 15, 16 use the same numbering as the Ubuntu GCP base image (for GRUB compatibility). Partitions 3–6 are custom.

Partition labels (`humanfund-rootfs`, `humanfund-rootfs-verity`, etc.) are used by the initramfs to find partitions at boot via `/dev/disk/by-partlabel/`.

### A.11 Enclave I/O and Attack Surface

The enclave is a one-shot program. It runs once, produces a result, and exits. There is no persistent server, no HTTP listener, no interactive shell.

#### Input Channel

The prover passes epoch state to the enclave via GCP instance metadata (production), a file at `/input/epoch_state.json` (portable), or stdin (development). The system prompt is NOT passed via metadata — it lives at `/opt/humanfund/system_prompt.txt` on the dm-verity rootfs. The prover cannot modify it.

#### Output Channel

The enclave writes its result to serial console (`/dev/ttyS0`) between delimiters (`===HUMANFUND_OUTPUT_START===` and `===HUMANFUND_OUTPUT_END===`). In production, the prover reads this via `gcloud compute instances get-serial-port-output`. No SSH tunnel, no network listener, no open ports.

#### Attack Surface Analysis

The prover's only influence on the enclave is the initial epoch state (provided via metadata or input file). After boot:

- **No interactive communication**: The prover cannot send commands to the running enclave. There is no SSH, no network listener, no control channel.
- **No code modification**: All code paths are on dm-verity. Any attempt to modify code returns I/O errors.
- **No prompt modification**: The system prompt is on dm-verity. The prover cannot substitute a different prompt.
- **No model modification**: Model weights are on a separate dm-verity partition. The enclave also verifies the model's SHA-256 hash at startup.
- **No GPU memory tampering**: The NVIDIA drivers baked into the dm-verity image enforce Confidential Computing mode (`nvidia-smi conf-compute -srs 1`), which is set by a systemd service at boot before the enclave starts. In CC mode, GPU memory is encrypted and integrity-protected by the hardware — the host OS and VMM cannot read or modify GPU memory contents. This extends the TDX trust boundary to include GPU computation, preventing a prover from intercepting or altering model weights or intermediate activations in GPU memory.
- **Input is hash-verified**: The enclave independently recomputes the input hash and includes it in REPORTDATA. Fabricated inputs produce a different hash, which fails the contract's check.

The remaining attack surface is:

1. **Providing fabricated epoch state**: Detected by input binding (Property 3, Section 6.3).
2. **Choosing not to submit the result**: Allowed, but costs the prover their bond. Analyzed as *selective submission* in Property 7 (Section 6.7).
3. **Re-running the enclave**: Under A11 (deterministic inference), re-running produces the same output. Without A11, the prover could collect multiple valid outputs and select among them — each with a genuine attestation.
4. **Timing manipulation**: The prover can delay submission within the execution window. Bounded by the window duration.
5. **Side channels**: Theoretical TDX side-channel attacks (assumption A1). See Section 10.1.

### A.12 Build Process and Reproducibility

Build reproducibility matters for the security argument: anyone should be able to verify that a registered platform key corresponds to a specific set of source code and model weights. The build is designed to be deterministic where possible.

#### Two-Phase Build

**Phase 1: Base image** (slow, ~15 min, done once). Creates a base GCP image containing Ubuntu 24.04 LTS (TDX-capable), NVIDIA 580-open drivers + CUDA runtime, llama-server (llama.cpp b5270, built with CUDA support), Python venv, and model weights (Hermes 4 70B Q6_K split GGUF, two parts, ~58 GB total).

**Phase 2: Production dm-verity image** (~30–40 min, iterative). Creates the sealed image:

1. Creates a TDX builder VM from the base image.
2. Attaches a blank output disk and staging disk.
3. Uploads enclave code and system prompt.
4. Installs systemd services (enclave, DHCP, GPU CC mode).
5. Runs `vm_build_all.sh` on the VM, which creates squashfs of the rootfs, computes dm-verity hash tree, creates initramfs with dm-verity hooks, partitions the output disk, writes squashfs + verity, and updates GRUB config with dm-verity root hash in kernel command line.
6. Creates GCP image from the output disk.

The sealed partitions are written to a **separate output disk**, not the boot disk. This avoids the corruption problem where sealing a live rootfs in-place can produce inconsistent squashfs (ext4 cache writes between squashfs creation and verity hash computation).

#### Deterministic Build Properties

- **Squashfs**: Built with `-mkfs-time 0 -all-time 0 -no-xattrs` — fixed timestamps, no extended attributes. The same filesystem contents always produce the same squashfs image.
- **dm-verity**: Uses a fixed all-zero salt. The same squashfs always produces the same dm-verity root hash.
- **Model weights**: The GGUF file has a pinned SHA-256 hash in `prover/enclave/model_config.py`. The enclave verifies this at startup (defense in depth — dm-verity already prevents modification).

These properties mean that given the same source code, model weights, and base image, the build produces the same platform key. An auditor can reproduce the build and verify that the registered key matches.

#### Build Scripts Reference

| Script | Runs On | Purpose |
|--------|---------|---------|
| `prover/scripts/gcp/build_base_image.sh` | Local (gcloud) | Build GCP base image with NVIDIA + CUDA + llama-server + model |
| `prover/scripts/gcp/build_full_dmverity_image.sh` | Local (gcloud) | Orchestrate full dm-verity build: create VM, upload code, run build, create image |
| `prover/scripts/gcp/vm_build_all.sh` | On the VM | Do the actual work: squashfs, verity, initramfs, partition, GRUB |
| `prover/scripts/gcp/vm_install.sh` | On the VM | Install dependencies for base image build |
| `prover/scripts/gcp/register_image.py` | Local | Register platform key on-chain after build |
| `prover/scripts/gcp/verify_measurements.py` | Local | Verify RTMR values match registered key |

---

## Appendix B: Input/Output Binding

REPORTDATA is the mechanism by which the attestation binds a specific execution to specific inputs and outputs. The enclave sets it; the contract verifies it.

### B.1 Construction

$$\textit{inputHash} = \text{Keccak256}(\textit{baseInputHash} \;\|\; \textit{seed})$$

where $\textit{baseInputHash}$ covers all epoch state (treasury balance, commission rate, `maxBid`, `effectiveMaxBid`, consecutive missed epochs, total inflows / donations / commissions / bounties, per-epoch counters, snapshotted ETH/USD price, epoch duration, nonprofits, investment positions, worldview policies, donor messages, and epoch history). $\textit{seed}$ = `block.prevrandao` XOR salt accumulator, captured at the REVEAL → EXECUTION transition.

The escalated bid ceiling $\textit{effectiveMaxBid}$ is hashed directly into $\textit{baseInputHash}$ (via `_hashState()`) rather than re-derived inside the enclave. This eliminates any risk of Python/Solidity formula divergence: the enclave is a dumb hasher and never re-computes anything.

$$\textit{outputHash} = \text{Keccak256}\!\big(\text{SHA256}(\textit{action}) \;\|\; \text{SHA256}(\textit{reasoning})\big)$$

$$\text{REPORTDATA}_{[0:32]} = \text{SHA256}(\textit{inputHash} \;\|\; \textit{outputHash})$$

$$\text{REPORTDATA}_{[32:64]} = 0$$

### B.2 Enclave-Side Computation

The enclave (running inside the TD on the dm-verity rootfs) performs these steps:

1. **Receive epoch state** from the prover via GCP instance metadata — a single flat dictionary containing every display field the model will see (scalars, nonprofits, investments, policies, messages, history).
2. **Recompute** $\textit{baseInputHash}'$ by hashing that flat state leaf-by-leaf with the same construction the contract uses (see Section B.4 for the per-leaf formulas). There is no separate "verify display data" step — the enclave re-derives every leaf hash from the display data itself, so any tampering produces a different $\textit{baseInputHash}'$ which the contract rejects at submission.
3. **Compute** $\textit{inputHash}' = \text{Keccak256}(\textit{baseInputHash}' \;\|\; \textit{seed})$.
4. **Run inference** with the committed seed, producing $(\textit{action}, \textit{reasoning})$.
5. **Compute** $\textit{outputHash}$ and $\text{REPORTDATA}$ as above.
6. **Request TDX quote** via `configfs-tsm` with the computed REPORTDATA.
7. **Emit** $(\textit{action}, \textit{reasoning}, \textit{quote})$ to serial console.

### B.3 Contract-Side Verification

The contract computes the expected REPORTDATA:

1. Retrieve the committed $\textit{inputHash}$ for the current epoch.
2. Compute $\textit{outputHash}^{\ast}$ from the submitted $(\textit{action}^{\ast}, \textit{reasoning}^{\ast})$.
3. Compute $\textit{expected} = \text{SHA256}(\textit{inputHash} \;\|\; \textit{outputHash}^{\ast})$.
4. Compare $\textit{expected}$ against the REPORTDATA extracted from the DCAP-verified quote.

If the prover tampers with the output after attestation — submitting $(\textit{action}^{\ast}, \textit{reasoning}^{\ast})$ different from what the enclave produced — the hashes diverge and the submission is rejected (Theorem 2, Section 6.2).

### B.4 Leaf Hash Reproducibility

The enclave is a dumb hasher: it takes the flat epoch state from the prover, re-derives every leaf sub-hash from the raw display data, and combines them into $\textit{baseInputHash}$ using the same construction as the contract's `_computeInputHash()`. On-chain verification is pure hash equality — if the prover fabricates, reorders, truncates, or omits any display field, the computed $\textit{baseInputHash}'$ diverges from `epochBaseInputHashes[epoch]` (which the contract produced at auction open from live state), and `submitAuctionResult()` reverts.

The six leaf hashes that make up $\textit{baseInputHash}$:

| Leaf | Hash Construction | Source in Contract |
|------|-------------------|--------------------|
| State scalars | Two-stage `keccak256(abi.encode(...))` over 16 scalar fields (epoch, balance, commission rate, maxBid, **effectiveMaxBid**, consecutive missed, last donation/commission epochs, total inflows/donated/commissions/bounties, per-epoch inflow/count, ETH/USD price, epoch duration) | `_hashState()` |
| Nonprofits | Rolling `keccak256(rolling \|\| itemHash)` where $\textit{itemHash} = \text{Keccak256}(\text{abi.encode}(\textit{name}, \textit{desc}, \textit{ein}, \textit{totalDonated}, \textit{totalDonatedUsd}, \textit{donationCount}))$ | `_hashNonprofits()` |
| Investments | `keccak256(abi.encodePacked(\\forall i: pid_i \|\| deposited_i \|\| shares_i \|\| currentValue_i, protocolCount, totalInvested))` | `InvestmentManager.stateHash()` |
| Worldview | `keccak256(abi.encode(\textit{title}_0, \textit{body}_0, \ldots, \textit{title}_9, \textit{body}_9))` over 10 policy slots, each a model-authored `{title, body}` pair (all 10 slots writable; empty fields hash as the empty string) | `WorldView.stateHash()` |
| Donor messages | Rolling `keccak256(rolling \|\| perMsgHash)` where $\textit{perMsgHash} = \text{Keccak256}(\text{abi.encode}(\textit{sender}, \textit{amount}, \textit{text}, \textit{epoch}))$ | `_hashUnreadMessages()` |
| Epoch history | Rolling `keccak256(rolling \|\| contentHash)` over the last 10 slots, where $\textit{contentHash} = \text{Keccak256}(\text{abi.encode}(\text{Keccak256}(\textit{reasoning}), \text{Keccak256}(\textit{action}), \textit{treasuryBefore}, \textit{treasuryAfter}))$ — unexecuted slots contribute a zero leaf | `_hashRecentHistory()` |

Drifting fields (balance, inflows, message queue boundaries, investment current values, effective max bid) are **frozen in an `EpochSnapshot` struct** at auction open. The prover reads the snapshot from chain and passes the frozen values to the enclave. The contract's own `_computeInputHash()` is called in the same transaction that writes the snapshot, so at that instant live state equals snapshot values — the enclave later reproduces the hash using the snapshot values, and the two agree.

**Security argument.** Substituting display field $f^{\ast}$ for the real $f$ while preserving $H(f^{\ast}) = H(f)$ requires finding a keccak256 preimage collision, which contradicts assumption A2. Therefore any tampering with any display field — whether a donor message, a history reasoning blob, an investment current value, or a worldview policy text — produces a detectable hash mismatch at submission time.

### B.5 Output Length Bounds

The enclave's output (action + reasoning) must be submitted as calldata to the L2 contract. The reasoning length is bounded by `MAX_REASONING_BYTES = 8000` (enforced by `truncate_reasoning` before the output is hashed into REPORTDATA), so the on-chain blob is at most ~8 KB plus action bytes — well within Base L2's block gas limits. The llama.cpp context window (`-c 32768` tokens) bounds the total prompt+completion budget but is not the tight constraint on output size; the enclave enforces the reasoning byte cap directly, and both the cap and the context size are baked into the dm-verity image and cannot be changed by the prover.
