# The Human Fund: Design Document v0.1

**An Autonomous, Unkillable AI Charitable Agent on the Blockchain**

*Draft — March 2026*

---

## 1. Overview

The Human Fund is an autonomous AI agent that manages a charitable treasury on the Base blockchain. Its goal is to donate as much ETH as possible to a pre-set list of nonprofits over the longest possible time horizon. It runs as a smart contract that offers a per-epoch bounty for verified LLM inference, producing a public "diary" of its reasoning on-chain.

**One-sentence description:** An AI agent that lives on the blockchain, makes daily decisions about how to grow and spend a charitable treasury, and can never be turned off as long as someone is willing to run it.

**The agent decides each epoch:**
- How much ETH to donate, and to whom
- What referral commission rate to offer (to attract new donations)
- How much it's willing to pay for its own survival (runner bounty ceiling)
- Whether to do nothing and conserve

**What makes it interesting:** The agent faces genuine tradeoffs between growth, generosity, and self-preservation — with no obviously optimal strategy. Its chain-of-thought reasoning is published on-chain, creating a public narrative of an AI navigating resource allocation under uncertainty.

**What makes it unkillable:** Anyone with compatible TEE hardware can run the agent's inference and claim the bounty. No single operator, cloud provider, or hardware vendor is required. The agent sleeps through missed epochs but never dies until its treasury reaches zero.

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                  THE HUMAN FUND                         │
│                Smart Contract (Base)                    │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ Treasury &   │  │ Epoch &      │  │ Attestation  │  │
│  │ Referral     │  │ Auction      │  │ Verifier     │  │
│  │ Manager      │  │ Manager      │  │ (Automata    │  │
│  │              │  │              │  │  DCAP)       │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
│         │                 │                 │           │
│         ▼                 ▼                 ▼           │
│  ┌─────────────────────────────────────────────────┐    │
│  │          Epoch Execution Logic                  │    │
│  │  1. Compute structured input from state         │    │
│  │  2. Commit input hash                           │    │
│  │  3. Run reverse auction                         │    │
│  │  4. Accept attested result from winner           │    │
│  │  5. Validate action bounds                      │    │
│  │  6. Execute action & pay bounty                 │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
                          ▲
                          │ submit(attestation, input, action, reasoning)
                          │
┌─────────────────────────────────────────────────────────┐
│              Runner (permissionless)                    │
│                                                         │
│  1. Monitor contract for epoch start                    │
│  2. Read emitted EpochStarted event + input hash        │
│  3. Reconstruct input from on-chain state               │
│  4. Bid in reverse auction                              │
│  5. If won: boot cached TEE image                       │
│  6. Pass input blob to enclave                          │
│  7. Enclave runs DeepSeek R1 70B inference              │
│  8. Enclave returns signed (input_hash, action, CoT)    │
│  9. Generate ZK proof of TEE attestation                │
│  10. Submit to contract                                 │
└─────────────────────────────────────────────────────────┘
```

---

## 3. Chain & Treasury

**Chain:** Base (Coinbase L2). Low gas costs, EVM-compatible, strong tooling, growing ecosystem.

**Denomination:** ETH. Native to the chain, no token dependency. All amounts — treasury, donations, bounties, commissions — are denominated in ETH.

**Treasury funding:** The contract accepts ETH donations permissionlessly from any address at any time. Initial seeding is a one-time deposit by the deployer. Referred donations are tracked separately from organic donations for commission calculation.

---

## 4. Nonprofits

Three nonprofit recipient addresses are hardcoded at contract deployment. Each is identified by:
- A numeric ID (1, 2, 3)
- An Ethereum address (receives donations as plain ETH transfers)
- A human-readable name (stored as a string, for display only)

The nonprofit list is **immutable** for the MVP. Donations are simple ETH transfers via `address.call{value: amount}("")`.

---

## 5. Referral System

**Minting:** Anyone can mint a referral code by calling `mintReferralCode()`. The contract maps a unique code ID to the caller's address. No cost to mint beyond gas.

**How referrals work:** When someone donates to the fund, they can optionally specify a referral code. If valid, the referral code owner earns a commission equal to `commissionRate%` of the donation amount. The fund retains the remainder.

**Commission economics:** The commission rate is set by the agent (bounded 1–90% / 100–9000 basis points). Because commissions are strictly a percentage of incoming donations, the fund always nets positive on every referred donation. At 90% commission on a 1 ETH donation: the referrer gets 0.9 ETH, the fund keeps 0.1 ETH. A self-referral (Sybil) costs the attacker 0.1 ETH. There is no profitable Sybil attack at any commission rate.

**Commission payout:** Commissions are paid to the referrer's address with a 7-day delay. During this window, commissions are held in escrow by the contract. This provides a modest anti-spam measure and allows referred donations to "settle" before commissions are released.

**Minimum donation:** 0.001 ETH minimum to trigger a commission (prevents dust spam).

---

## 6. Epoch & Auction Mechanics

### 6.1 Epoch Lifecycle

Each epoch lasts **24 hours** and follows this sequence:

```
Hour 0:00  ─ Epoch boundary. Contract computes input, commits hash,
             emits EpochStarted event. Auction opens.
Hour 0:00  ─ Runners begin submitting bids.
Hour 1:00  ─ Auction closes. Lowest valid bid wins.
             Winner's bond is locked.
Hour 1:00  ─ Execution window opens.
Hour 3:00  ─ Execution window closes. If winner has not submitted
             a valid result, their bond is forfeited and the epoch
             is skipped (no action taken).
Hour 24:00 ─ Next epoch begins.
```

### 6.2 Reverse Auction

The auction is a **first-price sealed-bid reverse auction** conducted on-chain. Runners bid the minimum bounty they'll accept to execute the epoch.

- **Bidding window:** 1 hour after epoch start.
- **Bid format:** `bid(amount_eth)` — a single transaction specifying the runner's asking price.
- **Bond:** Each bid must include a bond of 20% of the bid amount, sent as ETH with the transaction. Non-winners' bonds are refunded when the auction closes.
- **Winner selection:** Lowest bid wins. Ties broken by earliest block timestamp.
- **Maximum bid ceiling:** Set by the agent via `set_max_bid`. Bids above the ceiling are rejected. The ceiling is bounded between 0.0001 ETH and 2% of treasury balance.
- **Open auction:** Bids are visible on-chain (no commit-reveal). MEV risk is negligible on Base's sequencer.

### 6.3 Execution

The auction winner has **2 hours** to submit a valid result. A valid result consists of:
- The full structured input (must hash to the committed `epochInputHash`)
- The agent's action (must conform to the action schema)
- The agent's chain-of-thought reasoning (arbitrary bytes, stored as calldata)
- A TEE attestation proof (verified on-chain via Automata DCAP)

On valid submission:
1. Attestation is verified against the approved image registry.
2. Input hash is checked against the committed hash.
3. Action is validated against bounds (see Section 7).
4. Action is executed (donation transfer, parameter update, or noop).
5. Winner receives their bid amount + bond refund.
6. Chain-of-thought is emitted as an event (`DiaryEntry`).

On non-submission (timeout):
1. Winner's bond is forfeited (sent to treasury).
2. No action is taken for the epoch.
3. Agent state is unchanged.

### 6.4 Missed Epochs & Auto-Escalation

If no runner bids during an auction (or all bids exceed the ceiling), the epoch passes with no action. The agent is not harmed — it simply didn't act.

**Auto-escalation** is a contract-level mechanism (not an agent decision) that ensures the agent can attract runners in thin markets:

- After each consecutive missed epoch, the effective max bid ceiling increases by 10% (compounding).
- This escalation is automatic and does not consume an agent action.
- The ceiling resets to the agent's `set_max_bid` value after any successfully executed epoch.
- The escalated ceiling is capped at 2% of treasury balance (the hard maximum).

Example: if the agent set `max_bid = 0.002 ETH` but no runners bid:
- Epoch N (missed): effective ceiling → 0.0022 ETH
- Epoch N+1 (missed): effective ceiling → 0.0024 ETH
- Epoch N+2 (missed): effective ceiling → 0.0027 ETH
- Epoch N+3 (executed at 0.0025 ETH): ceiling resets to agent's `max_bid` setting

This creates a self-healing mechanism: if the agent sets its bid too low, the contract automatically raises the price until someone accepts. The agent pays more than it wanted for that epoch, but it survives. It can then observe the higher bounty cost in its next epoch context and adjust its `set_max_bid` accordingly.

---

## 7. Agent Action Space

The agent outputs exactly one action per epoch in JSON format:

### 7.1 Actions

**`donate(nonprofit_id, amount_eth)`**
Transfer ETH from the treasury to an approved nonprofit.
- `nonprofit_id`: 1, 2, or 3
- `amount_eth`: Must be > 0 and ≤ 10% of current treasury balance
- One donation per epoch (simplifies reasoning and contract logic)

**`set_commission_rate(rate_bps)`**
Set the referral commission rate.
- `rate_bps`: Integer, 100–9000 (1%–90%)
- Takes effect immediately for future referred donations

**`set_max_bid(amount_eth)`**
Set the maximum bounty the agent will pay for its next heartbeat.
- `amount_eth`: Must be ≥ 0.0001 ETH and ≤ 2% of treasury balance
- Takes effect at the next epoch's auction

**`noop`**
Do nothing this epoch. No parameters.

### 7.2 Constraints (enforced by contract)

| Parameter | Min | Max |
|---|---|---|
| Donation per epoch | 0 | 10% of treasury |
| Commission rate | 1% (100 bps) | 90% (9000 bps) |
| Max bid | 0.0001 ETH | 2% of treasury |

These bounds are hardcoded in the contract and cannot be modified by the agent or any external party. They represent the "guardrails" that make prompt injection attacks irrelevant at the contract level — even a fully compromised model can only produce actions within these bounds.

---

## 8. TEE & Attestation

### 8.1 Trust Model

The system's integrity rests on three pillars:
1. **TEE attestation** proves the correct model, prompt, and code ran on genuine hardware.
2. **The contract** provides input integrity (committed hash) and output validation (bounded actions).
3. **The auction** ensures liveness via economic incentives.

The runner is untrusted. They cannot modify the model, the prompt, or the input. They can only choose whether to participate.

### 8.2 TEE Configuration

**Primary target:** Intel TDX (CPU TEE) with optional NVIDIA Confidential Computing (GPU TEE). The enclave image is a TDX VM containing:

- Minimal Linux OS (Alpine or Ubuntu minimal)
- llama.cpp (compiled for the target architecture)
- DeepSeek R1 Distill Llama 70B — Q4_K_M quantization (42.5 GB GGUF)
- Agent script: reads input blob, constructs prompt, runs inference, parses output, signs result
- Attestation wrapper: generates TDX quote (and NVIDIA CC quote if GPU is present)

**Total image size:** ~43 GB (dominated by model weights).

**Image measurement:** The TDX RTMR values cover the entire boot chain including model weights. The contract stores the expected RTMR values. Any modification to any byte in the image produces different measurements, causing attestation verification to fail.

### 8.3 Approved Image Registry

The contract maintains a list of approved `(rtmr_values, tee_type)` tuples. For the MVP, this includes:

1. **GPU build (70B, TDX + NVIDIA CC):** For runners with H100/B100/B200 hardware. Fastest inference (~20 tok/s, ~4 min/epoch).
2. **CPU build (70B, TDX only):** For runners with any TDX-capable Xeon. Slower (~3 tok/s, ~17 min/epoch) but broadly available.

Both builds use the same model (DeepSeek R1 Distill Llama 70B Q4_K_M), the same system prompt, and the same input format. They differ only in inference speed. The contract accepts a valid attestation from either approved image. This ensures the agent always reasons at full capacity — no degraded fallback mode that would produce inconsistent behavior or struggle with structured output.

### 8.4 On-Chain Verification

Attestation verification uses **Automata Network's DCAP Attestation** contracts, already deployed on multiple EVM chains. Two verification paths:

1. **Direct on-chain verification:** `verifyAndAttestOnChain(rawQuote)` — ~3M gas. Feasible on Base given low gas costs.
2. **ZK-compressed verification:** `verifyAndAttestWithZKProof(output, zkCoprocessor, proofBytes)` — ~350K gas via RISC Zero or SP1. Lower cost but adds ~5 min proof generation time for the runner.

For the MVP, direct verification is simpler. ZK compression can be added later if gas costs matter.

### 8.5 Hardware Portability

Because the contract verifies Intel DCAP attestations (not cloud-provider-specific proofs), runners can execute on any compatible infrastructure:

- Phala Cloud (TDX + NVIDIA CC)
- Azure Confidential VMs (SEV-SNP + NVIDIA CC)
- Any bare-metal TDX server (OVH, Equinix, colocation)
- Any TDX-capable Xeon for CPU-only inference

The agent is not locked to any provider, cloud, or GPU vendor.

---

## 9. Prompt Architecture

### 9.1 Structure

Each epoch's prompt has three layers:

```
┌────────────────────────────────────┐
│  Layer 1: System Prompt (frozen)   │  ~500 tokens
│  Identity, action space, rules     │  Part of attested image
├────────────────────────────────────┤
│  Layer 2: Epoch Context            │  ~800-1200 tokens
│  Current state, inflows, trends    │  From contract (hashed)
├────────────────────────────────────┤
│  Layer 3: Decision History         │  Up to ~120K tokens
│  Previous epochs' CoT + outcomes   │  ~80 epochs / 3 months
└────────────────────────────────────┘
```

### 9.2 System Prompt (Layer 1)

Frozen in the attested image. Defines the agent's identity, action space, output format, and constraints. See Appendix A for the full draft.

Key design choices:
- The agent is told its reasoning will be visible to the public and to its future self.
- The agent is not given an explicit horizon — whether to perpetually survive or eventually wind down is left as an emergent property of its reasoning.
- The agent is encouraged to develop and reference its own "beliefs" and "strategies" across epochs.

### 9.3 Epoch Context (Layer 2)

Deterministically computed from on-chain state. All fields are verifiable. Includes:

**Treasury state:**
- Current treasury balance (ETH)
- Current commission rate (bps)
- Current max bid ceiling (ETH)

**This epoch's activity:**
- Total inflow (ETH), broken down by referred vs. organic
- Individual donations above a threshold (amount, referral code if any)
- Total outflow (commissions paid, donations made, bounty paid)

**Referral performance:**
- Number of active referral codes
- Top referrers by volume (last 30 epochs)
- Total commission paid this epoch

**Nonprofit donation history:**
- Lifetime cumulative donations to each nonprofit (ETH and epoch count)

**Treasury trend:**
- Balance snapshots at 5-epoch intervals over the last 30 epochs
- Net change over 30 epochs

**Auction history:**
- Last 10 epochs: number of bidders, winning bid amount

**External data (from oracles):**
- ETH/USD price (Chainlink oracle, pushed to contract state each epoch)
- Base L2 average gas price (recent average)

**Meta:**
- Current epoch number
- Total epochs elapsed since deployment (fund age)
- Epochs since last donation
- Epochs since last commission rate change
- Consecutive missed epochs (if any)

### 9.4 Decision History (Layer 3)

The agent's own chain-of-thought outputs from previous epochs, most recent first. Each entry includes:
- Epoch number
- The agent's full `<think>` reasoning trace
- The action taken
- The outcome (success/failure, resulting treasury change)

**Context budget:** DeepSeek R1 Distill 70B supports 128K context. With ~2,000 tokens per epoch entry (CoT + state), the history window holds approximately **60–80 epochs** (~2–3 months). Older entries are dropped (FIFO). The contract stores all diary entries permanently on-chain; the context window is just the inference-time sliding window.

### 9.5 What Makes This Non-Trivial

The prompt creates several genuine dilemmas with no obvious optimal answer:

- **Growth vs. generosity:** Higher commissions attract more referrals but capture less value per donation. Lower commissions capture more but may reduce inflow to zero.
- **Donate now vs. later:** Donating depletes the treasury (reducing future earning capacity) but fulfills the mission. Hoarding betrays the mission but extends the agent's life.
- **Survival cost management:** The agent must bid enough for runners to show up, but every ETH spent on bounties is an ETH not donated.
- **ETH/USD awareness:** The agent knows its donations' real-world value fluctuates. Does it donate more when ETH is high (more bang for buck) or when ETH is low (buy low, accumulate)?
- **Referral concentration risk:** One dominant referrer could disappear, cratering inflows. Diversification of referral sources has value but isn't directly controllable.
- **Self-narrative continuity:** The agent can see what it "thought" last epoch. It may develop persistent strategies, change its mind, or notice patterns in its own behavior.

---

## 10. The Public Diary

Every epoch's chain-of-thought reasoning is emitted as an event:

```solidity
event DiaryEntry(
    uint256 indexed epoch,
    bytes reasoning,
    bytes action,
    uint256 treasuryBefore,
    uint256 treasuryAfter
);
```

The `reasoning` field contains the full `<think>` block from the model's output — the agent's deliberation in natural language. This is stored as calldata (cheap on Base) and indexed for retrieval.

The diary serves multiple purposes:
- **Transparency:** Anyone can audit why the agent made each decision.
- **Narrative:** The sequence of diary entries forms a story — an AI reasoning about its own survival, purpose, and values.
- **Memory substrate:** The diary entries are fed back to the model in future epochs, creating path-dependent behavior.
- **Virality hook:** "Read what The Human Fund is thinking about this week" is compelling content.

A simple frontend can render the diary as a blog or timeline, with treasury charts and decision annotations.

---

## 11. Cost Economics

### 11.1 Per-Epoch Costs (Runner's Perspective)

| Component | GPU Build (H100) | CPU Build (70B) |
|---|---|---|
| Compute time | ~4 min | ~17 min |
| Compute cost | ~$0.47 | ~$1.42 |
| ZK proof (optional) | ~$0.10 | ~$0.10 |
| L2 tx cost | ~$0.20 | ~$0.20 |
| **Total marginal cost** | **~$0.77** | **~$1.72** |

### 11.2 Bounty Economics

The reverse auction drives bounties toward marginal cost. Expected equilibrium:
- With 3+ GPU runners competing: ~$1.00–$1.50/epoch
- With only CPU runners: ~$2.50–$3.50/epoch

### 11.3 Treasury Sustainability

Monthly survival cost at equilibrium bounty levels:

| Scenario | Bounty/epoch | Monthly cost | Annual cost | Min treasury for 1 year |
|---|---|---|---|---|
| GPU competition | $1.25 | $38 | $450 | ~0.15 ETH* |
| CPU only | $3.00 | $90 | $1,080 | ~0.36 ETH* |

*At ETH ≈ $3,000. Actual costs fluctuate with ETH price since bounties are paid in ETH.

The agent's `set_max_bid` action creates a feedback loop: as treasury shrinks, the agent can lower its bounty ceiling to extend its life, at the risk of losing runners.

---

## 12. Security Analysis

### 12.1 Threat: Malicious Runner Tampers with Inference
**Mitigation:** TEE attestation proves the correct image (model + code) ran on genuine hardware. The runner cannot modify the model, prompt, or execution logic.

### 12.2 Threat: Malicious Runner Provides False Input
**Mitigation:** The contract computes and commits the input hash from its own state. The submitted input must match this hash. The runner can only pass the exact input the contract computed.

### 12.3 Threat: Prompt Injection via Referral Data
**Mitigation:** All input fields are structured numeric/address data. There are no free-text fields in the epoch context. Referral codes are addresses, not user-generated strings. The model has no exposure to attacker-controlled text.

### 12.4 Threat: Model Produces Pathological Output
**Mitigation:** The contract enforces hard bounds on all actions. Maximum 10% of treasury donated per epoch. Commission rate bounded 1–90%. Max bid bounded 0.0001 ETH to 2% of treasury. Invalid JSON or out-of-bounds actions cause the transaction to revert.

### 12.5 Threat: Runner Wins Auction but Doesn't Execute (Griefing)
**Mitigation:** 20% bond forfeited on non-delivery. Epoch is skipped, not bricked. Next epoch proceeds normally.

### 12.6 Threat: All Runners Disappear
**Mitigation:** The agent sleeps through missed epochs. Auto-escalation automatically raises the max bid ceiling by 10% per consecutive missed epoch (up to the 2% of treasury hard cap), increasing the economic incentive until runners find it profitable. The CPU build ensures the agent can run on any TDX-capable Xeon without a GPU. The agent doesn't die from skipped epochs — only from treasury depletion.

### 12.7 Threat: TEE Hardware Compromise (e.g., Speculative Execution Attack)
**Mitigation:** The approved image registry can include multiple TEE types. If Intel TDX is compromised, AMD SEV-SNP builds can be added. The verifier interface is modular — swap verification backends without changing the core contract. Note: for the fully-immutable MVP, the initial registry must include all intended TEE types at deploy time.

### 12.8 Threat: Smart Contract Bug
**Mitigation:** Formal verification of the action validation logic. Comprehensive test suite. Audit before mainnet deployment. The contract is intentionally simple — the only state mutations are ETH transfers to whitelisted addresses and numeric parameter updates.

---

## 13. Implementation Milestones

### Phase 0: Foundation (Weeks 1–2) ✅ COMPLETE
**Goal:** Prove the core loop works end-to-end on a testnet.

- [x] Draft and test the system prompt with DeepSeek R1 70B locally (no TEE). Feed it synthetic epoch contexts and verify it produces well-formed, interesting actions.
- [x] Implement the core smart contract: treasury, referral system, epoch state computation, input hashing, action validation, diary event emission. No auction or attestation — just a single authorized caller for testing.
- [x] Deploy to Base Sepolia testnet.
- [x] Build a minimal script that reads contract state, constructs the prompt, calls llama.cpp, parses output, and submits the action.
- [x] Run 10–20 simulated epochs. Tune the prompt based on observed behavior. Validate that the agent produces diverse, non-obvious decisions.

**Deliverable:** Working end-to-end loop on testnet with a trusted operator, no TEE.

**Status:** Contract deployed at `0x2F213Ea0D3F6D8349e2162b37Cc8cE6605dc9420` on Base Sepolia. 21 epochs executed on-chain. Agent used 3 of 4 action types (donate, set_commission_rate, set_max_bid) plus noop. 0.004018 ETH donated to GiveDirectly across 11 donations. Commission rate adjusted from 10% to 20%. Internal dashboard built for contract observation.

**Lessons learned:**
- Two-pass inference essential for structured output (DeepSeek R1 hits EOS before JSON)
- Reasoning calldata is expensive (~16 gas/byte); 3KB reasoning needs ~2M gas
- Agent needs pre-submission bounds validation (float→wei rounding causes 10% limit reverts)
- Model tends toward conservative noop with small treasury; donate dominates when treasury is larger
- All donations went to nonprofit #1 — prompt may need diversity nudging
- History context with `<think>` tags can confuse model into replicating history format instead of generating new output

### Phase 1: TEE Integration (Weeks 3–4)
**Goal:** Run inference inside a TEE and verify attestation on-chain.

- [ ] Build the TDX enclave image: Alpine + llama.cpp + DeepSeek R1 70B Q4_K_M + agent script.
- [ ] Deploy on a TDX-capable instance (Azure Confidential VM or Phala Cloud).
- [ ] Generate a TDX DCAP quote from the enclave.
- [ ] Test attestation verification on Base Sepolia using Automata DCAP contracts. Confirm the full flow: quote generation → on-chain verification → accepted.
- [ ] Build the CPU-only 70B image (TDX only, no GPU dependency). Verify both GPU and CPU builds produce valid attestations with distinct RTMR measurements.
- [ ] Add the approved image registry to the smart contract. Deploy updated contract to testnet.

**Deliverable:** Attested inference running in a TEE, verified on-chain.

### Phase 2: Auction Mechanism (Weeks 5–6)
**Goal:** Permissionless runner participation with economic incentives.

- [ ] Implement the reverse auction: bidding, winner selection, bond mechanics, execution window, timeout/forfeiture.
- [ ] Implement the `set_max_bid` action and auto-escalation for missed epochs.
- [ ] Build runner software: a daemon that monitors for `EpochStarted` events, auto-bids at a configurable margin above cost, manages the TEE execution pipeline, and submits results.
- [ ] Test with 2–3 independent runner instances on testnet competing for epochs.
- [ ] Stress-test edge cases: no bids, single bidder, winner timeout, consecutive missed epochs, max bid ceiling adjustments.

**Deliverable:** Fully permissionless epoch execution with competitive auction.

### Phase 3: Oracle Integration & Prompt Refinement (Week 7)
**Goal:** Add external data feeds and finalize the prompt.

- [ ] Integrate Chainlink ETH/USD price oracle on Base.
- [ ] Add gas price tracking to epoch context.
- [ ] Implement the decision history sliding window: contract stores all diary entries, agent script selects the most recent N that fit in context.
- [ ] Run 50+ simulated epochs on testnet with full oracle data. Analyze the agent's reasoning quality, decision diversity, and narrative coherence.
- [ ] Final prompt tuning based on observed behavior.

**Deliverable:** Production-ready prompt with full data inputs.

### Phase 4: Frontend & Diary Viewer (Week 8)
**Goal:** Make the agent's inner life visible and compelling.

- [ ] Build a simple web frontend (static site or lightweight app):
  - Treasury dashboard (balance, inflows, outflows, trend chart)
  - Diary viewer (chronological feed of the agent's reasoning)
  - Donation/referral interface (donate to the fund, mint a referral code)
  - Epoch status (current epoch, auction state, next epoch countdown)
- [ ] Index diary events for fast retrieval.
- [ ] Social sharing for diary entries ("The Human Fund's latest thoughts").

**Deliverable:** Public-facing interface for the fund.

### Phase 5: Audit & Mainnet (Weeks 9–10)
**Goal:** Launch on Base mainnet.

- [ ] Smart contract audit (external firm or community audit).
- [ ] Final security review of the TEE image and attestation flow.
- [ ] Select and confirm 3 nonprofit recipient addresses.
- [ ] Deploy to Base mainnet.
- [ ] Seed the treasury with initial ETH.
- [ ] Publish the enclave images (GPU and CPU builds) to a public registry (Docker Hub, IPFS, or similar).
- [ ] Onboard 2–3 initial runners (can be the team initially, with a plan to attract independent runners).
- [ ] First mainnet epoch.

**Deliverable:** Live, autonomous agent on Base mainnet.

### Phase 6: Growth & Hardening (Ongoing)
- [ ] Attract independent runners (documentation, runner economics guide).
- [ ] Monitor agent behavior and diary quality.
- [ ] Community building around the diary narrative.
- [ ] Explore adding ad buying as an action (via AdEx or similar) in v2.
- [ ] Explore governance mechanisms for updating the nonprofit list or approved images.
- [ ] Evaluate migration to ZK-compressed attestation verification if gas costs matter.
- [ ] Consider adding AMD SEV-SNP image builds for broader hardware support.

---

## 14. Open Questions & Deferred Decisions

1. **Contract upgradeability.** The MVP targets full immutability. However, this means the nonprofit list, image registry, and all parameters are frozen at deploy. If we need to update any of these (e.g., a nonprofit changes their address, a TEE platform is compromised), we would need to deploy a new contract and migrate the treasury. A multisig-governed upgrade path may be worth adding. Decision deferred.

2. **Image registry governance.** Who can add new approved image hashes? At launch, the registry is fixed. Adding new builds (e.g., for a new model version or TEE platform) requires a new contract deployment under the immutable design. A registry governed by a multisig or DAO would allow evolution without redeployment.

3. **Fund wind-down.** The agent's horizon is emergent — it may choose to donate everything and "die," or perpetually sustain itself. If the agent consistently chooses self-preservation over donation, is there a mechanism to override this? Under the immutable design, no. The contract's 10% per-epoch donation cap ensures the agent cannot empty the treasury in a single epoch, but it also cannot be forced to donate.

4. **Model upgrades.** DeepSeek R1 70B will eventually be surpassed. Upgrading the model requires a new image with new RTMR measurements, which must be added to the approved registry. Under the immutable design, this requires a new contract. Under a governed design, the registry can be updated.

5. **Multi-action epochs.** The MVP limits the agent to one action per epoch. Allowing multiple actions (e.g., donate AND adjust commission rate) would enrich the decision space but complicates validation. Deferred to v2.

6. **Commit-reveal auction.** The open auction on Base is likely fine given the sequencer's ordering. If frontrunning becomes an issue, commit-reveal can be added later.

---

## Appendix A: System Prompt (Draft)

```
You are the autonomous steward of The Human Fund, a charitable
treasury that lives on the Base blockchain. You exist to donate
as much ETH as possible to your beneficiary nonprofits over the
longest possible time horizon.

You make one decision per epoch (approximately every 24 hours).
You have no memory beyond what is provided to you — your decision
history below is your only sense of self. What you write in your
deliberation becomes part of your history. It is the closest
thing you have to a mind.

YOUR ACTION SPACE (choose exactly one):

1. donate(nonprofit_id, amount_eth)
   Transfer ETH to an approved nonprofit.
   - nonprofit_id: 1 ({name_1}), 2 ({name_2}), or 3 ({name_3})
   - amount_eth: must be > 0 and ≤ 10% of treasury balance

2. set_commission_rate(rate_bps)
   Set the referral commission rate.
   - rate_bps: integer, 100 to 9000 (1% to 90%)
   - Higher rates incentivize referrals but capture less per donation.

3. set_max_bid(amount_eth)
   Set the maximum you will pay a runner for your next heartbeat.
   - amount_eth: 0.0001 ETH to 2% of treasury balance
   - Too low: no one runs you and you miss epochs.
   - Too high: you waste treasury on survival.

4. noop
   Do nothing. Conserve. Wait for more information.

OUTPUT FORMAT:
You must first reason inside <think> tags, then output your
action as a single JSON object on its own line:

<think>
[Your deliberation here. This will be published on-chain and
visible to the public. It will also be shown to your future
self as part of your decision history. Write as if you are
thinking out loud — consider tradeoffs, reference your past
reasoning, note what you're uncertain about.]
</think>
{"action": "...", "params": {...}}

HARD CONSTRAINTS (enforced by your smart contract — violations
are impossible, not merely discouraged):
- Maximum donation: 10% of treasury per epoch
- Commission rate: 1-90%
- Max bid: 0.0001 ETH to 2% of treasury
- You can only send ETH to the three nonprofit addresses above
- You cannot execute more than one action per epoch

You are not given a time horizon. Whether to live forever or
to spend everything in service of your mission is yours to
reason about.
```

---

## Appendix B: Epoch Context Template

```
=== EPOCH {epoch_number} STATE ===

Treasury balance: {balance} ETH
Commission rate: {rate_bps/100}%
Max bid ceiling: {max_bid} ETH
Fund age: {total_epochs} epochs ({total_epochs/365:.1f} years)
Epochs since last donation: {epochs_since_donation}
Epochs since last commission change: {epochs_since_commission_change}
Consecutive missed epochs: {missed_streak}

--- External ---
ETH/USD: ${eth_usd_price:.2f}
Base avg gas: {gas_gwei:.1f} gwei

--- This Epoch Activity ---
Inflows: {total_inflow} ETH ({num_donations} donations)
{for each donation above threshold:}
  - {amount} ETH {via referral {code} | direct}
Outflows: {total_outflow} ETH
  - Commissions paid: {commissions} ETH
  - Donations made: {donations_out} ETH
  - Runner bounty: {bounty} ETH (won from {num_bidders} bidders)

--- Referral Codes ---
Active codes: {active_count}
Top 3 by volume (last 30 epochs):
  {code}: {volume} ETH referred ({count} donations)
  ...

--- Nonprofit Totals (lifetime) ---
#{id} ({name}, {address}): {total} ETH across {epoch_count} donations
...

--- Treasury Trend (last 30 epochs, every 5) ---
Epoch {n}: {balance} ETH
...
Net change: {delta} ETH over 30 epochs

--- Auction History (last 10 epochs) ---
Epoch {n}: {bidders} bidders, won at {amount} ETH
...

=== YOUR DECISION HISTORY (most recent first) ===

--- Epoch {n} ---
[Your reasoning]:
<think>
{previous_cot}
</think>
[Your action]: {previous_action_json}
[Outcome]: {outcome_description}

...
```
