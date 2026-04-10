# Security Model

**Costanza: An Autonomous Charitable Treasury Agent**

This document defines the formal security model for Costanza. It states the system model, enumerates assumptions, defines security properties as games, and provides proof sketches that the system satisfies each property under the stated assumptions.

Implementation details — how the TEE is constructed, how the disk image is built, how attestation is verified — are deferred to [TEE_SECURITY.md](TEE_SECURITY.md). This document treats the TEE as an ideal functionality and reasons about the protocol built on top of it.

---

## 1. System Model

Costanza is an autonomous AI agent managing a charitable treasury on Base L2. Each epoch (nominally 24 hours), a reverse auction selects a *prover* who runs the agent's inference inside a Trusted Execution Environment. The contract verifies the result via hardware attestation and executes the agent's chosen action within hard-coded bounds.

### 1.1 Parties

**Contract** $\mathcal{C}$ — A deterministic state machine deployed on a public ledger. Maintains the treasury, nonprofit registry, epoch state, and auction logic. Enforces action bounds and verifies attestation proofs.

**Provers** $P_1, \ldots, P_n$ — Permissionless participants who compete in reverse auctions to run inference. Provers are untrusted: they control the software environment surrounding the TEE and choose when and whether to participate. Modeled as PPT adversaries in cryptographic arguments, and as risk-neutral expected-utility maximizers in economic arguments.

**Donors** $D_1, \ldots, D_m$ — Provide ETH inflows and short text messages. Messages are the only channel for external text to enter the model's context. Donors are untrusted with respect to message content.

**Owner** $\mathcal{O}$ — Holds elevated privileges during system setup (registering nonprofits, configuring auction parameters, approving TEE images). All privileges — including emergency withdrawal, direct-mode submission, epoch skipping, and worldview seeding — are progressively and irreversibly removed via one-way freeze flags. Post-freeze, $\mathcal{O}$ has no capabilities beyond any other external observer.

**Sequencer** $\mathcal{S}$ — The L2 block producer (Coinbase, on Base). Controls transaction ordering and sets `block.prevrandao`. Assumed honest in the base model; collusion with provers is analyzed as an assumption violation.

### 1.2 Ideal Functionalities

The security model is built on three ideal functionalities. The concrete constructions that realize them are described in [TEE_SECURITY.md](TEE_SECURITY.md) and standard cryptographic literature.

**$\mathcal{F}_{\text{TEE}}$ — Trusted Execution.** On input $(\mathsf{codeId}, \textit{input}, \textit{seed})$, produces $(\textit{result}, \pi)$ where $\pi$ is an attestation binding $\mathsf{codeId}$, $\textit{input}$, $\textit{seed}$, and $\textit{result}$ together. The adversary cannot produce a valid $\pi$ for any tuple $(\mathsf{codeId}, \textit{input}, \textit{seed}, \textit{result}')$ where $\textit{result}' \neq \textit{result}$, unless they break the underlying TEE hardware.

**$\mathcal{F}_{\text{HASH}}$ — Collision-Resistant Hashing.** A family of hash functions $H : \{0,1\}^* \to \{0,1\}^{256}$ such that no PPT adversary can find $x \neq x'$ with $H(x) = H(x')$ with non-negligible probability. Instantiated by SHA-256 and Keccak-256.

**$\mathcal{F}_{\text{COMMIT}}$ — Commitment Scheme.** $\text{Commit}(x; r) = H(x \| r)$ where $r \leftarrow \{0,1\}^{256}$. Computationally hiding (observing the commitment reveals nothing about $x$) and computationally binding (the committer cannot open to $x' \neq x$). Both properties reduce to the properties of $H$ under $\mathcal{F}_{\text{HASH}}$.

### 1.3 Contract Parameters

These constants are referenced throughout the security games:

| Symbol | Value | Description |
|--------|-------|-------------|
| $\delta$ | `MAX_DONATION_BPS` = 1000 | Max donation per epoch (10% of liquid treasury) |
| $\beta$ | `MAX_BID_BPS` = 200 | Hard cap on bounty (2% of treasury) |
| $\alpha$ | `AUTO_ESCALATION_BPS` = 1000 | Escalation rate per missed epoch (10%) |
| $b_0$ | `maxBid` | Initial max bid ceiling (set at deployment) |
| $\gamma$ | `BASE_BOND` = 0.001 ETH | Base bond amount |
| $K$ | `MAX_MISSED_EPOCHS` = 50 | Cap on escalation iterations |

---

## 2. Assumptions

Each assumption is labeled for precise reference in theorems.

### Cryptographic Assumptions

**A1 (TEE Integrity).** $\mathcal{F}_{\text{TEE}}$ is secure. An adversary who controls the prover's software stack — but not the TEE hardware or the attestation key hierarchy — cannot produce a valid attestation $\pi$ for code that did not execute as specified. Formally: the attestation scheme is existentially unforgeable under adaptive chosen-message attack.

**A2 (Collision Resistance).** The hash functions SHA-256 and Keccak-256 are collision-resistant. No PPT adversary can find $x \neq x'$ such that $H(x) = H(x')$ with non-negligible probability in the security parameter $\lambda$.

**A3 (Commitment Binding).** The commitment scheme $\text{Commit}(\textit{bid}; \textit{salt}) = \text{Keccak256}(\textit{bid} \| \textit{salt})$ is computationally binding. No PPT adversary can produce $(\textit{bid}, \textit{salt})$ and $(\textit{bid}', \textit{salt}')$ with $\textit{bid} \neq \textit{bid}'$ and $\text{Commit}(\textit{bid}; \textit{salt}) = \text{Commit}(\textit{bid}'; \textit{salt}')$.

**A4 (Commitment Hiding).** The commitment scheme is computationally hiding. Observing $\text{Commit}(\textit{bid}; \textit{salt})$ reveals no information about $\textit{bid}$ to a PPT adversary who does not know $\textit{salt}$.

### Infrastructure Assumptions

**A5 (Ledger Liveness).** The L2 sequencer includes valid transactions within a bounded delay $\Delta$, where $\Delta$ is strictly less than half the shortest phase window. Transactions are not censored indefinitely.

**A6 (Ledger Safety).** Once a transaction is finalized on the L2, it is irreversible.

### Economic Assumptions

**A7 (Rational Provers).** Provers are risk-neutral expected-utility maximizers. A prover's total utility for participating in epoch $k$ includes both *auction economics* and *external financial interests*:

$$U_i(k) = \underbrace{(b_i - c_i)}_{\text{bounty net of cost}} + \underbrace{v_i(a_k)}_{\text{external utility of action}} - \underbrace{\mathbb{1}[\text{forfeit}] \cdot \gamma_k}_{\text{bond loss}}$$

where $b_i$ is the bounty, $c_i$ is the prover's compute + gas cost, $v_i(a_k)$ is the external financial impact on $P_i$ if action $a_k$ executes (which may be positive, negative, or zero), and $\gamma_k$ is the bond. A prover participates when $E[U_i] > 0$, where the expectation is taken over the randomness of the action (seed unpredictability, Property 4).

The special case $v_i \equiv 0$ (prover has no external financial interests tied to the agent's actions) reduces to the standard economic condition $E[b_i] > E[c_i] + E[\text{risk penalty}]$. The general case — where provers may have conflicting interests — is analyzed in Property 7 (Execution Incentive Compatibility).

**A8 (Prover Existence).** At least one independent prover exists with access to TEE-capable hardware and the approved disk image. The strengthened version assumes at least two independent provers (enabling competitive bidding).

**A9 (Sequencer Independence).** The L2 sequencer does not collude with any prover to manipulate `block.prevrandao` or selectively censor transactions. This is an explicit assumption. Property 4 and R2 analyze the consequences of its violation.

### Operational Assumptions

**A10 (Prover Responsiveness).** At least one prover satisfying A8 can observe on-chain state and submit a valid transaction within a single phase window. This requires bounded network latency, sufficient working capital for the bond, and awareness of the auction schedule. Without this assumption, provers may exist but be unable to participate in time.

**A11 (Deterministic Inference).** For a fixed $(\mathsf{codeId}, \textit{input}, \textit{seed})$, the enclave produces a unique output. This is achieved by pinning the inference binary (llama.cpp), model weights, sampling parameters, and GPU architecture in the dm-verity image, and using a deterministic sampler seeded by $\textit{seed}$. Without A11, a prover could run the enclave multiple times and select among distinct valid outputs — each with a genuine attestation — reintroducing the output-selection attack that seed commitment is designed to prevent.

---

## 3. Security Properties

### 3.1 Property 1: Liveness (Autonomous Persistence)

The system must continue operating without requiring any specific party's cooperation. The core mechanism is auto-escalation: after each consecutive missed epoch, the maximum bounty ceiling increases by factor $\alpha = 1.10$, up to a hard cap of $\beta \cdot T$ (2% of treasury).

**Definition 1 (Liveness).** The system is *$(W, \epsilon)$-live* if, for any window of $W$ consecutive epochs, the probability that no valid result is submitted is at most $\epsilon$.

---

**Game** $\mathsf{LIVENESS}(\lambda, W)$:

1. Challenger initializes $\mathcal{C}$ with treasury $T > 0$, initial max bid $b_0$, escalation rate $\alpha = 1.10$, and hard cap $\beta = 0.02$.
2. Adversary $\mathcal{A}$ controls up to $n - 1$ of $n$ provers and can make them abstain from any epoch. $\mathcal{A}$ can also stall by committing and not revealing (forfeiting bonds).
3. $\mathcal{A}$ wins if there exist $W$ consecutive epochs with no valid submission.

---

**Theorem 1 (Liveness).** *Under A7 (rational provers with $v_i \equiv 0$), A8 (prover existence), and A10 (prover responsiveness), for any treasury $T > 0$ with $\beta \cdot T > 0$, the system is $(W, \epsilon)$-live where $\epsilon \to 0$ as $W \to \infty$.*

> *Proof sketch.* Let $c$ denote the marginal cost of running one epoch (compute + gas), assumed approximately constant for a given hardware generation.
>
> After $k$ consecutive missed epochs, the effective max bid ceiling is:
>
> $$b_k = \min\!\big(b_0 \cdot \alpha^k,\; \beta \cdot T\big)$$
>
> Since $\alpha > 1$ and $T > 0$, there exists a finite:
>
> $$k^* = \left\lceil \log_\alpha \frac{c}{b_0} \right\rceil$$
>
> such that $b_{k^*} \geq c$. Under A7 (with $v_i \equiv 0$), any rational prover with $E[\text{cost}] \leq b_{k^*}$ will bid and submit. Under A8, at least one such prover exists. Under A10, that prover can submit within the phase window. Therefore, after at most $k^*$ consecutive misses, a prover participates and the miss streak resets.
>
> The probability that $W$ consecutive epochs are all missed requires $W > k^*$ with no prover finding any of the $W - k^*$ profitable epochs worth bidding on — which contradicts A7 for all epochs past $k^*$. $\square$
>
> *Note:* This theorem assumes provers with no external financial interests ($v_i \equiv 0$). When provers have non-zero external utility, the liveness guarantee depends on the additional conditions analyzed in Property 7 (Execution Incentive Compatibility).

**Boundary condition.** Liveness fails when $\beta \cdot T < c$ — the treasury is too small for even the hard-cap bounty to cover costs. At current costs ($c \approx$ \$1/epoch), the minimum viable treasury is approximately \$50. Below this threshold, the system enters permanent sleep. This is the only true death condition: not a shutdown, but economic dormancy.

**Bond and the cost of stalling.** An adversary who stalls by committing and forfeiting (to block honest provers from winning) pays the bond $\gamma_k$ per epoch. The bond also escalates: $\gamma_k = \min(\gamma \cdot \alpha^k, b_k)$. The cumulative cost of stalling $k$ consecutive epochs is:

$$C_{\text{stall}}(k) = \sum_{i=0}^{k-1} \gamma_i = \sum_{i=0}^{k-1} \min\!\big(\gamma \cdot \alpha^i,\; b_i\big)$$

This is a geometric series — the cost of the $k$-th stalled epoch is $\alpha$ times the cost of the $(k{-}1)$-th. Meanwhile, the adversary gains nothing (no bounty, no influence on the agent's actions). The escalating bond creates a *negative feedback loop*: the longer the stall, the more expensive each additional epoch becomes, while simultaneously increasing the incentive for honest provers to outbid the attacker. See Section 3.8 for the full multi-epoch analysis.

### 3.2 Property 2: Inference Integrity

The contract must never accept an action that was not the genuine output of the approved code running on the committed inputs with the committed seed.

---

**Game** $\mathsf{INTEGRITY}(\lambda)$:

1. Challenger runs the system. The approved code is identified by $\mathsf{codeId}$ (the registered platform key).
2. Adversary $\mathcal{A}$ controls a prover. $\mathcal{A}$ may submit arbitrary tuples $(\textit{action}^*, \textit{reasoning}^*, \pi^*)$ to the contract.
3. $\mathcal{A}$ wins if $\mathcal{C}$ accepts $(\textit{action}^*, \textit{reasoning}^*)$ and either:
   - **(a) Fabrication**: The approved code was never executed on $(\textit{inputHash}, \textit{seed})$.
   - **(b) Substitution**: The approved code was executed but produced $(\textit{action}, \textit{reasoning}) \neq (\textit{action}^*, \textit{reasoning}^*)$.

---

**Theorem 2 (Inference Integrity).** *Under A1 (TEE integrity) and A2 (collision resistance), no PPT adversary wins $\mathsf{INTEGRITY}(\lambda)$ with non-negligible probability.*

> *Proof sketch.* The contract computes:
>
> $$\textit{outputHash}^* = \text{Keccak256}\!\big(\text{SHA256}(\textit{action}^*) \;\|\; \text{SHA256}(\textit{reasoning}^*)\big)$$
>
> $$\textit{expected} = \text{SHA256}(\textit{inputHash} \;\|\; \textit{outputHash}^*)$$
>
> and verifies that $\textit{expected}$ equals the REPORTDATA extracted from the DCAP-verified attestation quote $\pi^*$.
>
> **Against fabrication (3a):** By A1, $\mathcal{A}$ cannot produce a valid attestation $\pi^*$ with the correct REPORTDATA without actually executing the approved code inside $\mathcal{F}_{\text{TEE}}$ on inputs $(\textit{inputHash}, \textit{seed})$. The DCAP verification ensures $\pi^*$ originated from genuine TEE hardware running the attested $\mathsf{codeId}$.
>
> **Against substitution (3b):** Suppose the code produced $(\textit{action}, \textit{reasoning})$ but $\mathcal{A}$ submits $(\textit{action}^*, \textit{reasoning}^*)$ with $(\textit{action}, \textit{reasoning}) \neq (\textit{action}^*, \textit{reasoning}^*)$. The attestation quote contains:
>
> $$\text{REPORTDATA} = \text{SHA256}\!\big(\textit{inputHash} \;\|\; \text{Keccak256}(\text{SHA256}(\textit{action}) \;\|\; \text{SHA256}(\textit{reasoning}))\big)$$
>
> For the contract's check to pass, we need $\textit{outputHash}^* = \textit{outputHash}$, i.e.:
>
> $$\text{Keccak256}\!\big(\text{SHA256}(\textit{action}^*) \;\|\; \text{SHA256}(\textit{reasoning}^*)\big) = \text{Keccak256}\!\big(\text{SHA256}(\textit{action}) \;\|\; \text{SHA256}(\textit{reasoning})\big)$$
>
> By A2 (collision resistance of Keccak-256), this implies $\text{SHA256}(\textit{action}^*) = \text{SHA256}(\textit{action})$ and $\text{SHA256}(\textit{reasoning}^*) = \text{SHA256}(\textit{reasoning})$. Applying A2 again (collision resistance of SHA-256), this gives $\textit{action}^* = \textit{action}$ and $\textit{reasoning}^* = \textit{reasoning}$ — a contradiction. $\square$

### 3.3 Property 3: Input Binding

The enclave must process exactly the state committed on-chain. A prover who provides fabricated epoch data must be detected.

The input hash has a two-level structure. Some fields are committed directly (treasury balance, epoch number, ETH/USD price). Others are committed as opaque sub-hashes — the contract stores $H(\textit{data})$ and the prover must provide the expanded $\textit{data}$ to the enclave, which recomputes and verifies the hash. This is necessary because the enclave has no direct chain access.

---

**Game** $\mathsf{INPUT\text{-}BINDING}(\lambda)$:

1. The contract commits $\textit{inputHash}_k$ for epoch $k$, derived deterministically from on-chain state.
2. Adversary $\mathcal{A}$ (a prover) provides epoch state $S^*$ to the enclave.
3. $\mathcal{A}$ wins if the enclave accepts $S^*$, the contract accepts the resulting submission, and $H(S^*) \neq \textit{inputHash}_k$.

---

**Theorem 3 (Input Binding).** *Under A1 and A2, no PPT adversary wins $\mathsf{INPUT\text{-}BINDING}(\lambda)$ with non-negligible probability.*

> *Proof sketch.* The enclave independently computes $\textit{inputHash}' = H(S^*)$ from the prover-provided state. It sets:
>
> $$\text{REPORTDATA} = \text{SHA256}(\textit{inputHash}' \;\|\; \textit{outputHash})$$
>
> The contract verifies this against $\text{SHA256}(\textit{inputHash}_k \;\|\; \textit{outputHash}^*)$. If $\textit{inputHash}' \neq \textit{inputHash}_k$, the REPORTDATA values differ (by collision resistance of SHA-256 under A2), and the submission is rejected. $\square$

**Corollary (Display Data Binding).** For fields committed as sub-hashes, the enclave recomputes each sub-hash from the prover-provided display text and verifies it matches the committed value. Substituting display text $\textit{text}^* \neq \textit{text}$ while preserving $H(\textit{text}^*) = H(\textit{text})$ requires finding a collision in $H$, which contradicts A2.

This is important because it prevents a subtler attack: a prover who provides correct hashes but fabricated human-readable text to influence the model's reasoning. The display data verification closes this gap — the model sees exactly what was committed on-chain.

The binding is *complete*: each sub-hash commits to the full ordered sequence of its elements (e.g., the message hash array commits to the count, ordering, and content of all messages). Omitting an element changes the array, changing the hash. Reordering elements changes which hash occupies which position, also failing verification. The enclave enforces that the number of expanded elements matches the committed array length.

### 3.4 Property 4: Seed Unpredictability

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

### 3.5 Property 5: Auction Fairness (Bid Privacy)

The commit-reveal auction must ensure that no participant learns another's bid before the reveal phase.

---

**Game** $\mathsf{BID\text{-}PRIVACY}(\lambda)$:

1. Prover $P_1$ commits bid $b_1$ with salt $r_1$: commitment $c_1 = H(b_1 \| r_1)$.
2. Adversary $\mathcal{A}$ (another prover) observes $c_1$ on-chain.
3. $\mathcal{A}$ wins if $\mathcal{A}$ can determine $b_1$ with probability significantly better than guessing from the bid space $\{1, \ldots, b_{\max}\}$.

---

**Theorem 5 (Bid Privacy).** *Under A4 (commitment hiding), the commit-reveal auction preserves bid privacy during the commit phase.*

> *Proof sketch.* By A4, $\text{Commit}(b_1; r_1) = H(b_1 \| r_1)$ is computationally hiding. Observing $c_1$ gives $\mathcal{A}$ no advantage in determining $b_1$ beyond what is implied by the public bid range $[1, b_{\max}]$. $\square$

**Limitation: reveal-phase information leakage.** Bid privacy holds only during the commit phase. During the reveal phase, bids are revealed publicly and sequentially. The last revealer sees all previously revealed bids and can condition their strategy — they may choose not to reveal (forfeiting bond $\gamma_k$) if they observe that they would lose, or they may use the information to inform future epochs' strategies.

This is inherent to on-chain commit-reveal and is the standard limitation of the scheme. The cost of exploiting it is bounded by the forfeited bond. All bidders commit simultaneously during the commit window, so no one can see others' commitments before committing their own — the information asymmetry is limited to the reveal ordering.

### 3.6 Property 6: Bounded Extraction (Treasury Preservation)

Even if the adversary controls the model's output, the contract enforces hard caps on extraction per epoch. This is the ultimate safety net — it does not depend on any cryptographic assumption.

---

**Game** $\mathsf{EXTRACTION}(\lambda)$:

1. Treasury has value $T$ at the start of epoch $k$.
2. Adversary $\mathcal{A}$ controls the model output: $\mathcal{A}$ may choose any valid action within the action space.
3. $\mathcal{A}$ wins if the treasury loses more than $f \cdot T$ in a single epoch.

---

**Theorem 6 (Bounded Extraction).** *For any model output accepted by the contract, the maximum single-epoch outflow is bounded by $(\delta + \beta) \cdot T = 0.12 \cdot T$.*

> *Proof.* Exhaustive case analysis over the action space:
>
> | Action | Max outflow | Source |
> |--------|-------------|--------|
> | `donate` | $\delta \cdot T_{\text{liquid}} \leq \delta \cdot T = 0.10 \cdot T$ | `_executeDonate` enforces `MAX_DONATION_BPS` |
> | `invest` | $0$ (moves ETH to approved adapters, still owned by contract) | `InvestmentManager.deposit` |
> | `withdraw` | $0$ (returns ETH from adapters to liquid treasury) | `InvestmentManager.withdraw` |
> | `set_commission_rate` | $0$ (adjusts a parameter, no transfer) | bounds check only |
> | `noop` | $0$ | no-op |
>
> The bounty paid to the winning prover is at most $\beta \cdot T = 0.02 \cdot T$. The maximum single-epoch outflow is therefore $\delta \cdot T + \beta \cdot T = 0.12 \cdot T$. $\square$

**Note on investment risk.** The `invest` action moves ETH into DeFi protocols. While this is not extraction (the contract retains ownership), it introduces protocol risk — if an underlying DeFi protocol is exploited, the invested funds may be lost. This risk is bounded by concentration limits: no more than 25% of total assets in any single protocol, and a minimum 20% liquid reserve.

### 3.7 Property 7: Execution Incentive Compatibility

Theorem 1 proves liveness for provers with no external financial interests ($v_i \equiv 0$). But provers are permissionless participants who may hold positions affected by the agent's actions — or, more broadly, may have financial interests that depend on whether the agent acts at all. This is particularly relevant for autonomous agents with less constrained action spaces (e.g., agents that can execute arbitrary DeFi transactions), where a single action could have outsized market impact. This section formalizes the conditions under which the mechanism remains incentive-compatible — i.e., the winning prover finds it rational to submit — even when provers have external interests.

#### 3.7.1 The Selective Submission Problem

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

The mechanism is *incentive-compatible for $P_w$* when $\tau_w > \max_{a \in \mathcal{A}} |v_w(a)|$ — when no action is harmful enough to justify the cost of vetoing. For provers with $v_w \equiv 0$, $\tau_w > 0$ always holds (they always submit). The interesting case is provers with large negative $v_w$ for some actions.

#### 3.7.2 Why the Mechanism Is Resilient

Four structural features bound the impact of selective submission:

**1. Action space bounds limit external harm.** Property 6 constrains the maximum impact of any single action: donations are capped at 10% of liquid treasury, investments at 25% per protocol with a 20% reserve floor. This bounds $|v_w(a)|$ for any prover whose external interests are proportional to the fund's actions. A prover whose DeFi exposure is orders of magnitude larger than the fund's treasury would not find the agent's actions material.

**2. Seed unpredictability prevents selective entry.** At commit time ($t \leq t_1$), the prover does not know $action_k$ because the seed has not been captured (Property 4). They commit based on $E_a[v_w(a)]$, the expected external utility averaged over all possible actions. A prover who expects negative utility on average will not enter at all. A prover who expects positive utility on average will enter, accepting the risk of occasional vetoes. This means provers cannot *target* specific actions to veto without paying the entry cost (bond + compute) on every epoch.

**3. The veto is a blunt instrument.** A prover who vetoes can prevent an action, but cannot *choose* the action. The next epoch brings a new auction, a new winner, and a new seed. The vetoed action may be chosen again — or a different action entirely. Sustained blocking requires winning and vetoing every epoch, which triggers the escalating bond (Section 3.8.2).

**4. Prover diversity dilutes conflicting interests.** Under the strengthened A8 (multiple independent provers), the probability that *every* potential winner has conflicting interests for every possible action is low. Provers are drawn from a permissionless pool with heterogeneous financial positions. One prover's external harm from action $a$ may be another's gain, or simply irrelevant.

#### 3.7.3 The Liveness Condition Under External Interests

Combining Theorem 1 with the selective submission analysis, we can state the general liveness condition:

**Theorem 7 (Liveness Under External Interests).** *The system is $(W, \epsilon)$-live (Definition 1) if, for each epoch $k$ in the window, there exists at least one prover $P_i$ satisfying:*

$$b_k + \gamma_k - c_i > \max_{a \in \mathcal{A}} |v_i(a)| \quad \text{(veto threshold exceeds maximum external harm)}$$

*and $P_i$ satisfies A10 (responsiveness). When this condition holds, $P_i$ always submits regardless of the action chosen, guaranteeing execution.*

> *Proof sketch.* If $P_i$ satisfies the veto threshold condition, they will submit for any $action_k$ (no action is harmful enough to justify forfeiting $\tau_i = b_k + \gamma_k - c_i$). Combined with A10 (they can participate in time) and the auto-escalation mechanism from Theorem 1 (which ensures $b_k$ grows until participation is profitable), the miss streak is bounded. $\square$

**Sufficient condition (strong form).** If at least one prover has $v_i \equiv 0$ (no external financial interests tied to the agent's actions), they always submit, and liveness reduces to Theorem 1. This prover might be the fund's creator, a charitable actor, or simply a compute provider who runs TEE workloads for profit without DeFi exposure.

**Sufficient condition (weak form).** Even if all provers have non-zero $v_i$, liveness holds as long as the auto-escalating bounty eventually makes $\tau_w = b_k + \gamma_k - c_w$ exceed the maximum external harm $\max_a |v_w(a)|$ for at least one prover. Since $b_k$ and $\gamma_k$ both grow geometrically with consecutive misses, and $|v_w(a)|$ is bounded by the action space constraints (Property 6), the threshold eventually dominates — unless the prover's external exposure is unbounded, which is implausible for a fund-sized treasury.

### 3.8 Multi-Epoch Analysis

The single-epoch bounds from Property 6 compound over multiple epochs. This section analyzes multi-epoch attack scenarios.

#### 3.8.1 Sustained Manipulation (Treasury Decay)

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

#### 3.8.2 Stalling (Preventing Execution)

An adversary who wants to prevent the system from executing — without extracting value — can stall by committing bids and then either not revealing or not submitting results.

**Strategy A: Commit and don't reveal.** The adversary forfeits bond $\gamma_k$ per epoch. But honest provers can also commit in the same epoch — the attacker only blocks execution if they are the *only* committer and don't reveal (no winner selected), or if they win (lowest bid) and don't submit. To guarantee winning, the attacker must commit a bid of 1 wei — the minimum — which any honest prover with cost $c > 1$ wei would not match. But:

- The attacker still forfeits $\gamma_k$ (the bond) each epoch.
- The bond escalates: $\gamma_k = \min(\gamma \cdot \alpha^k, b_k)$ where $\gamma = 0.001$ ETH.
- After $k$ stalled epochs, cumulative stall cost:

$$C_{\text{stall}}(k) = \sum_{i=0}^{k-1} \min\!\big(\gamma \cdot \alpha^i,\; \beta \cdot T\big)$$

- Meanwhile, the bounty ceiling $b_k$ also escalates, making it increasingly profitable for honest provers to enter and outbid the attacker.

**Strategy B: Win and don't submit.** The adversary reveals the lowest bid, wins the auction, and then doesn't submit a result within the execution window. Their bond is forfeited to the treasury. The cost analysis is identical to Strategy A.

**The negative feedback loop.** Both strategies create a self-correcting dynamic:

1. Each stalled epoch increases the adversary's cost (escalating bond).
2. Each stalled epoch increases the bounty ceiling, attracting honest provers.
3. Forfeited bonds flow to the treasury, partially offsetting the attack's effect.
4. The adversary gains nothing — no bounty, no influence on the agent.

For a concrete example: starting from $\gamma = 0.001$ ETH with $\alpha = 1.10$, the cumulative cost of stalling 20 consecutive epochs is:

$$C_{\text{stall}}(20) = 0.001 \cdot \sum_{i=0}^{19} 1.1^i = 0.001 \cdot \frac{1.1^{20} - 1}{0.1} \approx 0.057 \text{ ETH}$$

After those 20 epochs, the bounty ceiling has risen to $b_0 \cdot 1.1^{20} \approx 6.7 \cdot b_0$, making honest participation increasingly attractive — and the attacker's bond for epoch 21 would be $\gamma \cdot 1.1^{20} \approx 0.0067$ ETH.

The adversary faces a losing proposition: escalating costs with no revenue, against increasing competition from honest provers attracted by the rising bounty.

**Multi-agent collusion.** Can multiple attackers alternate to share costs? No — the escalation counter (`consecutiveMissedEpochs`) increments on every missed epoch regardless of *who* caused the miss, and only resets when a valid result is submitted. Two attackers alternating still produce consecutive misses, so the bond escalation continues uninterrupted. The only way to reset the counter is to submit a valid result, which means running the model honestly — at which point the agent acts and the stall has failed.

**Strategy C: Selective submission.** A prover with external financial interests (Property 7) can win the auction, run the enclave, and selectively veto unfavorable actions. Unlike Strategies A and B, this prover incurs the full compute cost $c_w$ in addition to the forfeited bond — they must actually run the enclave to observe the action. The cost per vetoed epoch is $c_w + \gamma_k$, strictly higher than pure stalling. The same escalation dynamics apply, and the adversary additionally cannot prevent *favorable* actions (they would submit those), limiting this to a sporadic rather than sustained strategy.

#### 3.8.3 Multi-Epoch Seed Grinding

Under violated A9 (sequencer collusion), an adversary could grind seeds across multiple epochs to steer the agent's behavior. Over $k$ epochs with $m$ seed candidates per epoch, the adversary explores $m^k$ possible trajectories. The cost is $k \cdot m \cdot c_{\text{inference}}$ (inference must actually run for each candidate), and the benefit is bounded by the action space constraints applied at every step. This is expensive and rate-limited by the epoch duration.

---

## 4. Composition and Instantiation

The security of the system follows from the composition of Properties 1–7, provided the ideal functionalities are correctly instantiated:

| Functionality | Instantiation | Reference |
|---------------|---------------|-----------|
| $\mathcal{F}_{\text{TEE}}$ | Intel TDX + dm-verity rootfs + Automata DCAP | [TEE_SECURITY.md](TEE_SECURITY.md) |
| $\mathcal{F}_{\text{HASH}}$ | SHA-256, Keccak-256 | Standard |
| $\mathcal{F}_{\text{COMMIT}}$ | $H(\textit{bid} \;\|\; \textit{salt})$ with 256-bit salt | Standard |

The argument that the TDX + dm-verity construction realizes $\mathcal{F}_{\text{TEE}}$ — including the measurement chain, filesystem integrity, and DCAP verification — is the subject of [TEE_SECURITY.md](TEE_SECURITY.md). We briefly state the requirements that $\mathcal{F}_{\text{TEE}}$ must satisfy:

1. **Execution fidelity.** The output is the genuine result of running $\mathsf{codeId}$ on $(\textit{input}, \textit{seed})$. No code outside the attested image can influence the computation.
2. **Attestation unforgeability.** No adversary can produce a valid attestation for an execution that did not occur on genuine TEE hardware.
3. **Input/output binding.** The attestation cryptographically binds the execution to specific inputs and outputs via a REPORTDATA field that the enclave sets and the contract verifies.

---

## 5. Accepted Risks as Assumption Violations

The following are known limitations, reframed as scenarios where specific assumptions are weakened or violated. In each case, the system degrades gracefully rather than failing catastrophically.

### R1: Reveal-Phase Information Leakage

**Assumption weakened:** Property 5 (bid privacy) holds during commit but not reveal.

**Scenario:** The last revealer sees all previously revealed bids. They can choose not to reveal (forfeiting bond) or use the information strategically.

**Degradation:** Bounded by bond cost. All bidders commit simultaneously, so the asymmetry is limited to reveal ordering. In practice, the reveal window is short (30 minutes), and the information advantage is marginal for a first-price auction — the optimal strategy is to bid your true cost regardless of others' bids.

### R2: Sequencer Influence on Randomness

**Assumption violated:** A9 (sequencer independence).

**Scenario:** The sequencer sets `block.prevrandao` on Base L2 (centralized sequencer, operated by Coinbase). A colluding sequencer+prover could try $k$ different seeds.

**Degradation:** Cost is $k \times c_{\text{inference}}$ per epoch. The attacker selects from reachable outputs, not arbitrary ones. All outputs are bounded by Property 6. Requires compromising Coinbase infrastructure. Detectable via on-chain analysis of prevrandao patterns.

### R3: MEV on Swaps

**Assumption context:** External to the model — concerns Uniswap interaction during donation execution.

**Scenario:** Sandwich attacks on ETH→USDC swaps.

**Degradation:** Bounded by Chainlink oracle-based minimum output and 3% slippage tolerance. On Base L2, MEV is constrained by the centralized sequencer. Maximum loss: ~3% per swap.

### R4: Prompt Injection via Donor Messages

**Assumption context:** The model is not a deterministic function with respect to adversarial inputs. Donor messages (up to 280 characters, minimum 0.01 ETH) are untrusted text fed to the model.

**Mitigations (defense in depth):**
- Datamarking spotlighting replaces whitespace with an epoch-specific dynamic marker derived from `block.prevrandao`, making injected text tokenically distinct from system instructions.
- The marker is unpredictable at message submission time (depends on future `prevrandao`).
- Messages are limited to 280 characters.
- Display data verification (Property 3, Corollary) ensures provers cannot substitute fake message text.

**Why not formally modeled:** Formal analysis of prompt injection resistance would require modeling the LLM as a function and defining "successful injection" — an open research problem. The security model does NOT rely on injection resistance. Property 6 provides the safety net: even if injection succeeds and the model is fully compromised, the contract bounds cap single-epoch extraction at 12% of treasury.

### R5: DeFi Protocol Risk

**Assumption context:** Investment adapters route ETH to external DeFi protocols (Aave, Compound, Morpho, Lido, Coinbase). These protocols have their own security assumptions.

**Degradation:** If a protocol is exploited, the invested position may be lost. Bounded by concentration limits (25% max per protocol, 20% min liquid reserve). The `withdrawAll` function uses try/catch to recover from individual adapter failures.

### R6: TEE Hardware Vulnerabilities

**Assumption weakened:** A1 (TEE integrity).

**Scenario:** Intel TDX is compromised via speculative execution or other microarchitectural attack (as happened with SGX).

**Degradation:** If $\mathcal{F}_{\text{TEE}}$ is broken, Properties 2–4 no longer hold. However, Property 6 (bounded extraction) remains — it is enforced by the smart contract and does not depend on TEE security. The verifier contract is modular (`IProofVerifier`), enabling migration to ZK proof systems as they mature.

---

## 6. What This Model Does NOT Claim

**Output quality.** The model guarantees that the *approved* model runs on the *correct* inputs with an *unpredictable* seed, and that the *output is faithfully submitted*. Whether the output represents a wise decision is outside scope. A different seed produces different reasoning — attestation proves execution fidelity, not optimality.

**Universal liveness.** The liveness argument assumes at least one independent prover exists (A8). A state-level adversary who can embargo all TEE-capable hardware worldwide would prevent execution. The auto-escalation mechanism cannot help if no prover exists at any price.

**Owner transition security.** The freeze mechanism (one-way flags that permanently disable owner capabilities) is described but not game-theoretically analyzed. It is a one-shot governance action: the owner's incentive to freeze is reputational and commitment-based, not enforced by the protocol.

**Post-freeze image longevity.** The platform key pins a specific firmware, bootloader, and kernel. If upstream dependencies change (e.g., Google updates OVMF), the pinned image may become unbootable on new hardware. This is a practical risk that should be evaluated before freezing the image registry.

---

## 7. Summary of Security Games

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

## 8. Verification Checklist (Pre-Mainnet)

Before mainnet deployment, verify that the instantiation matches the model:

- [ ] All freeze flags set (`FREEZE_NONPROFITS`, `FREEZE_AUCTION_CONFIG`, `FREEZE_VERIFIER`, `FREEZE_INVESTMENT_MANAGER`, `FREEZE_WORLDVIEW`, `FREEZE_MIGRATE`, `FREEZE_DIRECT_MODE`)
- [ ] Auction timing set to production values
- [ ] Platform key registered for the production dm-verity image ([TEE_SECURITY.md §3](TEE_SECURITY.md))
- [ ] DCAP FMSPC registered for production hardware
- [ ] All DeFi adapter addresses point to verified mainnet contracts
- [ ] Chainlink ETH/USD feed is the mainnet oracle
- [ ] `forge test` passes all tests
- [ ] `forge build --sizes` confirms contract size < 24,576 bytes
- [ ] Python hash compatibility tests pass
- [ ] E2E test passes on Base Sepolia with production image
