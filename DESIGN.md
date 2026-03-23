# The Human Fund: Design Document v0.3

**An Autonomous, Unkillable AI Charitable Agent on the Blockchain**

*Draft — March 2026*

---

## 1. Overview

The Human Fund is charitable DAO on the Base L2 blockchain run by an autonomous AI agent, Costanza. Costanza's goal is to donate as much ETH as possible to a pre-set list of nonprofits over the longest possible time horizon. It runs as a smart contract that offers a per-epoch bounty for verified LLM inference, producing a public "diary" of its reasoning on-chain.

**One-sentence description:** An AI agent that lives on the blockchain, makes daily decisions about how to grow and spend a charitable treasury, and can never be turned off as long as someone is willing to run it.

**Costanza decides each epoch:**
- How much ETH to donate, and to whom
- What referral commission rate to offer (to attract new donations)
- What to invest in to create future returns or hedge risk
- How much he's willing to pay for his own survival (runner bounty ceiling)
- Whether to do nothing and conserve

**What makes it interesting:** The agent faces genuine tradeoffs between growth, generosity, and self-preservation. Its chain-of-thought reasoning is published on-chain, creating a public narrative of an AI navigating resource allocation under uncertainty.

**What makes it unkillable:** Anyone with compatible TEE hardware can run the agent's inference and claim the bounty. No single operator, cloud provider, or hardware vendor is required. The agent sleeps through missed epochs but never dies until its treasury reaches zero.

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                  THE HUMAN FUND                         │
│                Smart Contract (Base)                    │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │ Treasury &   │  │ Epoch &      │  │ Attestation  │   │
│  │ Referral     │  │ Auction      │  │ Verifier     │   │
│  │ Manager      │  │ Manager      │  │ (Automata    │   │
│  │              │  │              │  │  DCAP)       │   │
│  └──────────────┘  └──────────────┘  └──────────────┘   │
│         │                 │                 │           │
│         ▼                 ▼                 ▼           │
│  ┌─────────────────────────────────────────────────┐    │
│  │          Epoch Execution Logic                  │    │
│  │  1. Compute structured input from state         │    │
│  │  2. Commit input hash                           │    │
│  │  3. Run reverse auction                         │    │
│  │  4. Accept attested result & pay bounty        │    │
│  │  5. Validate action bounds                      │    │
│  │  6. Execute action                              │    │
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

**Commission payout:** Commissions are paid to the referrer immediately when the donation is received. No escrow or delay — the economics already guarantee no profitable Sybil attack at any commission rate.

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

The auction is a **first-price open-bid reverse auction** conducted on-chain. Runners bid the minimum bounty they'll accept to execute the epoch.

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

**`invest(protocol_id, amount_eth)`**
Deploy ETH from the treasury into a DeFi protocol to earn yield.
- `protocol_id`: 1–8 (see system prompt for protocol details)
- `amount_eth`: Must be > 0
- Bounds enforced: max 80% of total assets invested, max 25% per protocol, min 20% liquid reserve
- Managed by `InvestmentManager.sol` with per-protocol adapters

**`withdraw(protocol_id, amount_eth)`**
Withdraw ETH from a DeFi protocol back to the liquid treasury.
- `protocol_id`: 1–8
- `amount_eth`: Amount to withdraw (use a very large number to withdraw everything)

**`set_guiding_policy(slot, policy)`**
Update one of 10 guiding policy slots in the agent's worldview.
- `slot`: 0–9
- `policy`: String, max 280 characters
- Managed by `WorldView.sol`
- Can also be updated as a side-effect alongside any other action via the `worldview` JSON field

### 7.2 Constraints (enforced by contract)

| Parameter | Min | Max |
|---|---|---|
| Donation per epoch | 0 | 10% of treasury |
| Commission rate | 1% (100 bps) | 90% (9000 bps) |
| Max bid | 0.0001 ETH | 2% of treasury |
| Total invested | 0 | 80% of total assets |
| Per-protocol investment | 0 | 25% of total assets |
| Liquid reserve | 20% of total assets | — |
| Guiding policy length | 0 | 280 characters |
| Guiding policy slots | 0 | 9 |

These bounds are hardcoded in the contract and cannot be modified by the agent or any external party. They represent the "guardrails" that make prompt injection attacks irrelevant at the contract level — even a fully compromised model can only produce actions within these bounds.

---

## 8. TEE & Attestation

### 8.1 Trust Model

The system's integrity rests on four pillars:
1. **TEE attestation** proves the correct model, prompt, and code ran on genuine hardware (MRTD + RTMR[0..2] verification).
2. **REPORTDATA binding** proves the attested code processed the correct inputs and produced the submitted outputs.
3. **The contract** provides input integrity (committed hash), output validation (bounded actions), and history integrity (rolling hash).
4. **The auction** ensures liveness via economic incentives and provides verifiable randomness (prevrandao seed).

The runner is untrusted. They cannot modify the model, the prompt, or the input. They cannot re-roll inference (deterministic seed). They can only choose whether to participate.

**See SECURITY.md** for the formal security model, threat analysis, proof sketch, and adversarial review passes.

### 8.2 TEE Configuration

**Primary target:** Intel TDX (CPU TEE) with optional NVIDIA Confidential Computing (GPU TEE). The enclave image is a TDX VM containing:

- Ubuntu 22.04 minimal
- llama.cpp (pinned to specific release tag for reproducible builds)
- Enclave runner script: accepts epoch context + input hash + seed, runs two-pass inference, computes REPORTDATA, requests TDX attestation quote
- System prompt (frozen, part of the attested image)
- Model SHA-256 hash (hardcoded in image, model mounted from disk by runner)

**Model is NOT baked into the image.** The runner mounts the model file at `/models/model.gguf`. The entrypoint script verifies `sha256sum(model) == MODEL_SHA256` (hardcoded in the image, covered by RTMR measurements). This keeps the image small (~500MB) while ensuring model integrity. Runners can cache the model file across epochs.

**Image measurement:** MRTD covers the virtual firmware. RTMR[0] covers hardware config. RTMR[1] covers the kernel. RTMR[2] covers the rootfs (which includes the runner script, system prompt, model hash, and llama.cpp binary). Any modification to any file changes the measurements.

### 8.3 Approved Image Registry

The `AttestationVerifier` contract (separate from TheHumanFund for bytecode size) maintains a registry of approved images:

```solidity
mapping(bytes32 => bool) public approvedImages;
// key = keccak256(MRTD || RTMR[0] || RTMR[1] || RTMR[2])
// Each field is 48 bytes (SHA-384), total 192 bytes hashed
```

Multiple images can be approved simultaneously to support:
1. **CPU build (14B, TDX only):** Development/testnet. Any TDX-capable Xeon. ~22 min/epoch.
2. **CPU build (70B, TDX only):** Production CPU runners. ~17 min/epoch.
3. **GPU build (70B, TDX + NVIDIA CC):** Production GPU runners. ~4 min/epoch.

Each build produces different RTMR measurements. Different platforms (dstack, Azure, bare-metal) may also produce different MRTD/RTMR[0..1] values for the same application, requiring per-platform entries in the registry. RTMR[3] is NOT verified (platform-specific, instance-specific).

To change models (e.g., upgrading from 70B to a larger model), build a new image with the new `MODEL_SHA256`, register its measurements, and optionally revoke the old image.

### 8.4 On-Chain Verification

Attestation verification uses a two-contract architecture:

1. **AttestationVerifier.sol** — Handles all attestation logic:
   - Calls Automata DCAP verifier (`0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F`) to verify quote authenticity
   - Parses the DCAP output (595+ bytes, `abi.encodePacked` format) at documented byte offsets
   - Extracts MRTD + RTMR[0..2] and checks against the approved image registry
   - Extracts REPORTDATA and compares against the expected value

2. **TheHumanFund.sol** — Computes expected REPORTDATA and delegates:
   ```
   expectedReportData = sha256(inputHash || sha256(action) || sha256(reasoning) || randomnessSeed)
   verifier.verifyAttestation(rawQuote, expectedReportData)
   ```

**Gas cost:** ~3M gas for DCAP verification + ~3,300 gas for REPORTDATA hashing. Feasible on Base.

### 8.5 Verifiable Randomness

LLM inference with temperature > 0 is non-deterministic. To prevent runners from cherry-picking favorable outputs:

1. `closeAuction()` captures `block.prevrandao` as the randomness seed
2. The seed is passed to the enclave, which uses it for llama.cpp's RNG (`--seed`)
3. The seed is included in the REPORTDATA hash, so the contract can verify the enclave used the correct seed
4. With a fixed seed, inference is deterministic — one input produces exactly one output

`block.prevrandao` is determined by the Ethereum beacon chain validators (on L2s like Base, inherited from L1). The runner cannot predict it at bid time or change it after.

### 8.6 Rolling History Hash

The contract maintains a rolling hash of all epoch reasoning:
```
historyHash = keccak256(historyHash || keccak256(reasoning))
```
This is included in `_computeInputHash()`, binding the model's "memory" to the on-chain commitment. A runner cannot fabricate decision history while keeping the input hash valid.

### 8.7 Hardware Portability

The verification scheme is platform-agnostic. Only MRTD + RTMR[0..2] are checked (not RTMR[3], which is platform/instance-specific). Runners can execute on any TDX infrastructure:

- Phala Cloud (dstack, TDX)
- Any bare-metal TDX server (OVH, Equinix, colocation)
- Any TDX-capable Xeon for CPU-only inference

Different platforms may produce different MRTD/RTMR values for the same image (different firmware/kernel). The approved registry supports per-platform entries.

**Note:** Azure Confidential VMs use a vTPM abstraction where REPORTDATA is not directly application-controlled. Supporting Azure would require a different verification flow. Currently not targeted.

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

Frozen in the attested image. Defines the agent's identity, action space, output format, and constraints. See `agent/prompts/` for the current versions.

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

**See SECURITY.md** for the comprehensive formal security model, including:
- Formal goal statement and assumptions
- 5 verification properties (genuine hardware, approved image, correct inputs, output integrity, temporal validity)
- Detailed threat analysis (10 threats with mitigations and residual risks)
- Informal proof sketch
- 8 adversarial review passes
- Implementation status of all security properties

### Summary of Key Mitigations

| Threat | Mitigation | Status |
|---|---|---|
| Runner tampers with inference | MRTD + RTMR[0..2] verify approved image | Implemented |
| Runner provides false input | REPORTDATA binds `inputHash` from contract | Implemented |
| Runner tampers with output | REPORTDATA binds `sha256(action) + sha256(reasoning)` | Implemented |
| Runner cherry-picks outputs | Verifiable randomness seed (`block.prevrandao`) | Implemented |
| Runner fabricates history | Rolling `historyHash` in `_computeInputHash()` | Implemented |
| Runner substitutes model | SHA-256 hash baked into image, verified at boot | Implemented |
| Prompt injection (structured fields) | No free-text fields — all structured numeric/address data | By design |
| Prompt injection (donor messages) | Datamarking spotlighting: whitespace replaced with pseudorandom marker seeded by `block.prevrandao` (Hines et al. 2024) | Implemented |
| Pathological model output | Hard bounds enforced by contract (10% donation, 1-90% commission, etc.) | By design |
| Griefing (non-delivery) | 20% bond forfeited, epoch skipped not bricked | By design |
| All runners disappear | Auto-escalation raises bid ceiling 10%/epoch until runners return | By design |
| TEE hardware compromise | Modular verifier interface, multi-platform registry | By design |

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

### Phase 1: TEE Integration (Weeks 3–4) ✅ COMPLETE
**Goal:** Run inference inside a TEE and verify attestation on-chain.

- [x] Build the TDX enclave image: Ubuntu 22.04 + llama.cpp + DeepSeek R1 Distill Qwen 14B Q4_K_M + enclave runner script.
- [x] Deploy on a TDX-capable instance (Phala Cloud, tdx.2xlarge CVM — 16 vCPU, 32 GB RAM).
- [x] Generate a TDX DCAP quote from the enclave. Real 5KB quote returned from hardware.
- [x] Build the CPU-only 14B image (TDX only, no GPU dependency). Inference at 0.33 tok/s, ~22 min/epoch.
- [x] Test attestation verification on Base Sepolia using Automata DCAP contracts (end-to-end on-chain).
- [x] Build the GPU 70B image for production runners.

**Deliverable:** Attested inference running in a TEE, verified on-chain.

**Status:** Enclave image deployed to Phala Cloud (`ghcr.io/ahrussell/humanfund-tee:v3`). Full inference + attestation pipeline tested — real TDX DCAP quote generated. Old `submitEpochActionTEE()` replaced by `submitAuctionResult()` with full MRTD/RTMR/REPORTDATA verification via `AttestationVerifier.sol`. Model now mounted from disk (no runtime download). llama.cpp pinned to tag `b5170`. 5 consecutive successful epochs with DeepSeek R1 70B on GCP TDX H100.

**Lessons learned:**
- 14B model on 16 CPU cores: 0.33 tok/s — functional but slow (~22 min/epoch). Production needs GPU runners.
- dstack API: `POST /GetQuote` on `/var/run/dstack.sock` (v0.5.x+). Legacy socket at `/var/run/tappd.sock`.
- dstack v0.5.x passes report_data verbatim (NO double-hashing — the old v0.3.x tappd API did hash, but that's deprecated).
- Model mounted from disk + SHA-256 verification is better than runtime download: no network dependency, faster boot, simpler TCB.
- Phala gateway has HTTP timeouts; SSH tunnel or on-CVM curl needed for long inference.
- Two-pass inference timeout must account for CPU speed: 1800s per pass minimum for 14B.

**Production model:** DeepSeek R1 Distill Llama 70B Q4_K_M (42.5 GB GGUF). Selected via 3-model gauntlet (75 epochs × 3 models): 100% parse success, best reasoning depth, diversified investment strategy. Runs on GCP TDX H100 (a3-highgpu-1g) with ~30s/epoch. GPU CC ready state must be set after boot: `nvidia-smi conf-compute -srs 1`.

**Development model:** DeepSeek R1 Distill Qwen 14B Q4_K_M (8.99 GB GGUF, SHA-256: `0b319bd0572f2730bfe11cc751defe82045fad5085b4e60591ac2cd2d9633181`). CPU-only, used for Phase 1 TEE testing on Phala Cloud.

### Phase 2: Auction + Attestation Verification (Weeks 5–6) ✅ COMPLETE
**Goal:** Permissionless runner participation with economic incentives and full attestation verification.

- [x] Implement the reverse auction: bidding, winner selection, bond mechanics, execution window, timeout/forfeiture.
- [x] Implement auto-escalation for missed epochs (was already in Phase 0; integrated with auction).
- [x] Configurable timing windows (epochDuration, biddingWindow, executionWindow) for testnet.
- [x] Input hash commitment at epoch start for runner verification (`computeInputHash()`).
- [x] Phase 0 compatibility toggle (`auctionEnabled`).
- [x] `AttestationVerifier.sol` — separate contract for DCAP output parsing, MRTD/RTMR verification, REPORTDATA checking, approved image registry.
- [x] `submitAuctionResult()` computes expected REPORTDATA and delegates to verifier.
- [x] Rolling `historyHash` — Merkle chain over all epoch reasoning, included in `_computeInputHash()`.
- [x] Verifiable randomness — `block.prevrandao` captured in `closeAuction()`, included in REPORTDATA.
- [x] Model mounted from disk, SHA-256 verified at boot (no runtime download).
- [x] llama.cpp pinned to specific release tag for reproducible builds.
- [x] 126 tests pass (28 Phase 0 + 34 auction + 12 verifier + 25 investment + 13 worldview + 14 messages).
- [x] Runner software supports auction mode (bidding, monitoring, `submitAuctionResult`).
- [x] Redeploy contract to Base Sepolia with new verifier.
- [x] Build production TEE image, register RTMR measurements in verifier.
- [x] End-to-end test with real TDX attestation quote on Base Sepolia.
- [x] Test with 2–3 independent runner instances on testnet competing for epochs.

**Deliverable:** Fully permissionless epoch execution with competitive auction and verified attestation.

**Status:** E2E attestation verified on Base Sepolia. `TheHumanFund.sol` delegates attestation to `AttestationVerifier.sol` (3.4KB). The verifier checks: (1) DCAP quote authenticity via Automata, (2) MRTD + RTMR[0..2] against approved image registry, (3) REPORTDATA matches `sha256(inputHash || sha256(action) || sha256(reasoning) || seed)`. Phase 3 contract deployed at `0xa507366987417e0E4247a827B48536DA11235CC7` with 5 consecutive successful epochs.

### Phase 3: Investment Portfolio & Agent Personality (Week 7) ✅ COMPLETE
**Goal:** Add DeFi investment capabilities, agent worldview/personality, and finalize the prompt.

- [x] InvestmentManager.sol with 8 protocol adapters (Aave V3 WETH/USDC, wstETH, cbETH, rETH, Compound V3, Moonwell, Aerodrome)
- [x] WorldView.sol — 10 structured guiding policy slots (diary style, investment stance, mood, lessons, etc.)
- [x] System prompt v5 with 3-pass inference (reasoning → diary → action JSON)
- [x] Datamarking spotlighting for donor messages (Hines et al. 2024)
- [x] Simulation environment and model comparison arena
- [x] 3-model gauntlet: DeepSeek R1 70B selected (100% parse success, best strategy)
- [x] 126 tests pass across 6 test suites

**Deliverable:** Production-ready agent with investment capabilities and personality.

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

2. **Image registry governance.** The `AttestationVerifier` contract has an owner who can `approveImage()` and `revokeImage()`. For the MVP, this is the deployer. For production, a multisig or DAO should own the verifier to enable image updates (new model versions, new platforms) without redeploying the main contract. The main contract references the verifier via `setVerifier()`, which could also be governed.

3. **Fund wind-down.** The agent's horizon is emergent — it may choose to donate everything and "die," or perpetually sustain itself. If the agent consistently chooses self-preservation over donation, is there a mechanism to override this? Under the immutable design, no. The contract's 10% per-epoch donation cap ensures the agent cannot empty the treasury in a single epoch, but it also cannot be forced to donate.

4. **Model upgrades.** DeepSeek R1 70B will eventually be surpassed. Upgrading the model requires a new image with a new `MODEL_SHA256` and new RTMR measurements. The `AttestationVerifier` owner calls `approveImage(newImageKey)` and optionally `revokeImage(oldImageKey)`. No contract redeployment needed — the verifier is a separate, updatable contract.

5. **Multi-action epochs.** The MVP limits the agent to one action per epoch. Allowing multiple actions (e.g., donate AND adjust commission rate) would enrich the decision space but complicates validation. Deferred to v2.

6. **Commit-reveal auction.** The open auction on Base is likely fine given the sequencer's ordering. If frontrunning becomes an issue, commit-reveal can be added later.

---

## Appendix B: Epoch Context Template

> **Note:** This is a simplified template. The actual implementation is in `agent/runner.py` `build_epoch_context()`.

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
