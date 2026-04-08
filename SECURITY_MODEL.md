# Security Model: Costanza

**Last updated**: 2026-03-30

This document describes the security model of Costanza, the trust assumptions at each layer, what is verified vs. trusted, and what risks are accepted by design.

---

## System Overview

Costanza is an autonomous AI agent managing a charitable treasury on Base L2. Each epoch (~24 hours), the agent decides one action (donate, invest, withdraw, adjust parameters, or noop). The agent's reasoning is published on-chain as a public diary.

The system operates across four trust boundaries:

```
  Donors          Provers (untrusted)        TDX Hardware
    |                  |                          |
    v                  v                          v
[Base L2 Contract] <-- [TEE Enclave] <-- [dm-verity rootfs]
    |                  |                          |
 Enforces bounds    Runs inference           Immutable code
 Verifies proofs    Verifies input data      Attested by DCAP
```

---

## Trust Boundaries

### 1. Smart Contract (Trustless)

The contract enforces hard bounds on all agent actions regardless of what the TEE outputs.

**Outflow-only design**: The contract can only send ETH via three channels, each with its own cap: (1) **donations** — only to Endaoment nonprofits pre-configured by the owner, limited to 10% of treasury per epoch; (2) **prover bounties** — capped by the max bid system (initially 0.0001 ETH, auto-escalates on missed epochs, hard cap at 2% of treasury); (3) **investments** — only into pre-approved DeFi protocol adapters registered by the owner. There is no `transfer` or arbitrary `call` that could send ETH elsewhere.

The owner sets these parameters during deployment but progressively surrenders control via **irreversible freeze flags** (see Section 1b below). Once frozen, the contract becomes fully autonomous — no one can change the nonprofit list, investment adapters, or auction configuration.

| Constraint | Bound | Enforced by |
|-----------|-------|-------------|
| Max donation per epoch | 10% of liquid treasury | `_executeDonate` |
| Commission rate | 1% — 90% | `_executeSetCommissionRate` |
| Max total invested | 80% of total assets | `InvestmentManager.deposit` |
| Max per protocol | 25% of total assets | `InvestmentManager.deposit` |
| Min liquid reserve | 20% of total assets | `InvestmentManager.deposit` |
| Guiding policy length | 280 bytes max | `WorldView.setPolicy` |
| Donor message length | 280 bytes max | `donateWithMessage` |

**Single-epoch worst case**: An attacker who controls the agent's output can donate 10% of the treasury, but cannot exceed these bounds. Over many epochs, sustained manipulation could drain the treasury — this is why TEE integrity and input verification matter.

### 2. TEE Enclave (Trusted for Inference Integrity)

The enclave runs inside a GCP TDX Confidential VM on a dm-verity rootfs:

- **Code integrity**: All code, model weights, and system prompt are on the dm-verity partition. The root hash is in the kernel command line, measured into RTMR[2], and verified on-chain via the platform key.
- **Input integrity**: The enclave independently computes `inputHash` from the prover-provided epoch state and includes it in the TDX REPORTDATA. The contract verifies this matches the on-chain committed hash. 
- **Output integrity**: `REPORTDATA = sha256(inputHash || outputHash)` where `outputHash = keccak256(sha256(action) || sha256(reasoning))`. The contract verifies this against the TDX quote. The system prompt is verified separately via dm-verity — it lives on the rootfs, whose hash is in the kernel command line, measured into RTMR[2], and checked via the platform key.
- **Randomness**: The inference seed comes from `block.prevrandao`, captured at auction close and included in the input hash. The enclave cannot choose its own seed.

**What the TEE guarantees**: Given the committed input hash and randomness seed, the attested output (action + reasoning) is the genuine result of running the approved model with the approved system prompt on the verified input.

### 3. Prover (Untrusted)

Provers are permissionless participants who:
- Call `syncPhase()` or `commit()` to open auctions (auto-advancing)
- Submit bids via commit-reveal
- Boot TDX VMs and submit attested results

**Provers cannot**:
- Fabricate TEE outputs (REPORTDATA verification catches this)
- Fabricate input data (inputHash verification catches this)
- Fabricate display data shown to the model (display data verification now catches this)
- Choose inference randomness (prevrandao is committed before execution). Note: a prover colluding with the L2 sequencer (who influences `prevrandao`) could theoretically manipulate the seed. On Base, this requires compromising Coinbase's sequencer, and manipulation is detectable via on-chain analysis.
- Exceed contract bounds (hard-coded in Solidity)

**Provers can**:
- Choose WHEN to trigger epoch phases (within the configured timing windows)
- Choose whether to participate in an auction
- Front-run or sandwich the resulting on-chain transactions (standard MEV)

### 4. Contract Owner (Trusted During Setup, Frozen After)

The owner has elevated privileges that are progressively frozen:

| Capability | Freeze flag | Status |
|-----------|-------------|--------|
| Add/remove nonprofits | `FREEZE_NONPROFITS` | Must freeze before mainnet |
| Configure auction timing | `FREEZE_AUCTION_CONFIG` | Must freeze before mainnet |
| Set attestation verifier | `FREEZE_VERIFIER` | Must freeze before mainnet |
| Link InvestmentManager | `FREEZE_INVESTMENT_MANAGER` | Must freeze before mainnet |
| Link WorldView | `FREEZE_WORLDVIEW` | Must freeze before mainnet |
| Emergency withdrawal / migration | `FREEZE_MIGRATE` | Must freeze before mainnet |
| Direct mode submission | `FREEZE_DIRECT_MODE` | Must freeze before mainnet |

**Post-freeze**: The owner retains only `skipEpoch()` (to handle emergencies) and `seedWorldView()` (one-time initialization). All other admin functions are permanently disabled.

### 5. AI Model (Untrusted Output)

The model's output is bounds-checked by the contract. The model cannot:
- Donate more than 10% of treasury per epoch
- Invest beyond allocation limits
- Set parameters outside defined ranges
- Execute actions not in the action space

The model CAN make suboptimal decisions within bounds. This is by design — the agent's autonomy within guardrails is the core feature.

**Untrusted inputs**: The model receives donor messages — free-text strings submitted on-chain via `donateWithMessage()`. These are the only channel for external parties to inject text into the model's context. Defenses:
- **Economic spam barrier**: Messages require a minimum donation of 0.01 ETH (`MIN_MESSAGE_DONATION`), making bulk injection expensive.
- **Length cap**: Messages are limited to 280 characters, constraining injection payload size.
- **Datamarking spotlighting** ([Hines et al. 2024](https://arxiv.org/abs/2403.14720)): Before the model sees messages, whitespace is replaced with a dynamic marker token derived from the epoch's `prevrandao` seed. This makes untrusted content tokenically distinct from system instructions, reducing the effectiveness of prompt injection.
- **Display data verification**: The enclave verifies that the message text shown to the model matches the on-chain message hashes, preventing provers from substituting fake messages.
- **Bounds enforcement**: Even if a message successfully influences the model, the resulting action is still bounded by the contract's hard limits (max 10% donation, investment caps, etc.).

### 6. External Dependencies

| Dependency | Trust Level | Failure Mode |
|-----------|-------------|-------------|
| Chainlink ETH/USD | Trusted oracle | Staleness check: reverts if > 1 hour stale. Zero price blocks donations. |
| Uniswap V3 Router | Trusted contract (immutable address) | Sandwich attacks bounded by 3% slippage + oracle floor. Deadline = `block.timestamp`. |
| Aave V3, Compound V3, Morpho | Trusted DeFi protocols | Adapter failures caught by try/catch in `withdrawAll`. Individual protocol risk accepted. |
| Automata DCAP | Trusted attestation verifier | If compromised, fake attestations accepted. Mitigation: DCAP is a well-audited, widely-used standard. |
| GCP TDX | Trusted hardware | If TDX is broken, attestation is meaningless. Mitigation: Intel's security track record; TDX is newer and benefits from SGX lessons. |
| Base L2 Sequencer | Trusted for ordering | Sequencer can delay/reorder transactions. Mitigation: execution deadline prevents indefinite holding. |

---

## Attestation Architecture

This section describes the attestation verification chain: how TDX measurements, dm-verity, and REPORTDATA work together to guarantee that accepted epoch results came from approved code running on approved inputs.

### RTMR Measurements

TDX provides four runtime measurement registers (RTMR[0..3]) plus a build-time measurement (MRTD). Each covers a different layer of the boot chain:

| Register | What It Measures | Security Role |
|----------|-----------------|---------------|
| **MRTD** | Virtual firmware (Google OVMF) | Measured by the TDX CPU *before* firmware executes. The only register firmware cannot fake. Proves which firmware was used. |
| **RTMR[0]** | Virtual hardware config (CPU count, memory, device topology) | Varies by VM size. **Intentionally skipped** in the platform key -- checking it would require registering every VM size separately with no security benefit. |
| **RTMR[1]** | Bootloader (GRUB/shim) | Measured by firmware. Proves the correct bootloader ran. |
| **RTMR[2]** | Kernel + command line (including dm-verity root hashes) | Measured by bootloader. Transitively covers the entire rootfs and model partition via dm-verity hashes embedded in the command line. |
| **RTMR[3]** | **Unused** (all zeros) | All code lives on the dm-verity rootfs, already covered by RTMR[2]. |

### Why MRTD Verification Is Essential

OVMF (the virtual firmware) is the first code that runs inside the Trust Domain. It controls what gets measured into RTMR[1] and RTMR[2]. A malicious OVMF could measure the legitimate kernel hash into RTMR[1] while actually booting a different kernel that disables dm-verity. The TDX CPU faithfully records whatever OVMF measured -- it does not verify honesty.

MRTD is computed by the TDX CPU *before* OVMF executes, based on the OVMF binary itself. It is the only register that cannot be faked by firmware. On bare metal (where a prover owns the hardware), compiling a malicious OVMF is trivial. Without MRTD verification, all downstream measurements become meaningless.

### Platform Key and the dm-verity Verification Chain

The TdxVerifier contract maintains a registry of approved platform keys:

```
Platform key = sha256(MRTD || RTMR[1] || RTMR[2])   (144 bytes -> 32 bytes)
```

This key transitively covers all code through the dm-verity chain:

```
Platform key
  <- MRTD (firmware identity)
  <- RTMR[1] (bootloader identity)
  <- RTMR[2] (kernel + command line)
       <- dm-verity root hash for rootfs (in kernel cmdline)
            <- every byte of: enclave code, system prompt, llama-server,
               NVIDIA drivers, model_config.py (pinned MODEL_SHA256)
       <- dm-verity root hash for model partition (in kernel cmdline)
            <- every byte of the 42.5GB GGUF model file
```

Changing any file on either partition changes its dm-verity hash, which changes the kernel command line, which changes RTMR[2], which changes the platform key, which fails the on-chain check. No separate app key (RTMR[3]) is needed because dm-verity on RTMR[2] covers everything.

### Per-Epoch Verification Flow

When a prover submits an auction result, the TdxVerifier performs three checks:

1. **Automata DCAP verification** (~10-12M gas): Calls the Automata verifier to confirm the TDX quote is genuine (Intel certificate chain, TCB level). Returns the decoded quote body containing all measurements and REPORTDATA.

2. **Platform key check**: Extracts MRTD, RTMR[1], and RTMR[2] from the decoded quote. Computes `platformKey = sha256(MRTD || RTMR[1] || RTMR[2])` and checks it against the approved registry.

3. **REPORTDATA binding**: Extracts REPORTDATA from the quote, computes the expected value from on-chain data, and verifies they match (see below).

All three must pass or the submission reverts.

### REPORTDATA Formula

REPORTDATA binds the attested execution to specific inputs and outputs:

```
outputHash  = keccak256(sha256(action) || sha256(reasoning))
REPORTDATA  = sha256(inputHash || outputHash)
```

Where:
- **inputHash** = `keccak256(baseInputHash || seed)`, committed on-chain at auction close
- **baseInputHash** covers: treasury state, nonprofit registry, investment state, worldview, epoch content, donor messages, history hash
- **seed** = `block.prevrandao` captured at auction close (unpredictable before bids are placed)

REPORTDATA proves three things:
1. The enclave used the correct epoch state (inputHash matches on-chain commitment)
2. The enclave produced the exact action + reasoning that were submitted
3. The inference used the committed randomness seed (deterministic output for a given seed)

System prompt and code integrity are verified separately via the platform key check (Step 2) — the prompt lives on the dm-verity rootfs, whose hash is embedded in the kernel command line, measured into RTMR[2].

The contract recomputes the expected REPORTDATA from the submitted action, reasoning, and committed inputHash. If the prover tampers with the output after attestation, the hashes diverge and the submission is rejected.

### Display Data Verification (Step 3b)

The inputHash commits to opaque sub-hashes (investment positions, worldview policies, donor messages, history entries). Since the enclave has no direct chain access, the prover provides both the opaque hashes and the expanded display data. The enclave independently recomputes each sub-hash from the expanded data and verifies they match:

- **Investment positions**: Recomputes `investmentHash` from the protocol details array using the same `abi.encodePacked` scheme as `InvestmentManager.stateHash()`
- **Worldview policies**: Recomputes `worldviewHash` from the policy text array using the same `abi.encode` scheme as `WorldView.stateHash()`
- **Donor messages**: Recomputes per-message hashes and verifies each against the committed message hash array
- **Epoch history**: Replays the rolling history hash chain and verifies it matches the committed `historyHash`

If any display data does not match its sub-hash, the enclave refuses to proceed. This ensures the model sees exactly the data that was committed on-chain — a prover cannot substitute fake text while passing hash verification.

### What Attestation Does NOT Prove

- **That the output is "correct"**: A different random seed produces different reasoning. Attestation proves the approved code ran, not that the output is optimal.
- **That the prover is honest about timing**: A prover could delay submission within the execution window. The contract enforces timing via the auction mechanism.
- **That the model is "good"**: The model hash is pinned, but whether it makes wise decisions is a separate question.
- **That the prover did not see the output before submitting**: The prover receives the output from the enclave serial console and could choose not to submit (forfeiting bond). Deterministic inference + committed seed means they cannot re-roll for a different result.

---

## Accepted Risks

These are known limitations that we've evaluated and accepted:

### A-1: Commit-Reveal Information Leakage

**Risk**: The last revealer in the auction can see all previously revealed bids and choose not to reveal (forfeiting bond) or reveal a strategically chosen bid.

**Why accepted**: This is inherent to on-chain commit-reveal. Mitigations: (1) bond forfeiture makes non-revealing costly, (2) all bidders commit simultaneously during the commit window so no one can see others' commits before committing themselves. The reveal order advantage is bounded by the bond cost.

### A-2: Block Proposer Influence on Randomness

**Risk**: `block.prevrandao` captured during the REVEAL → EXECUTION transition (inside `_syncPhase()`) can be influenced by the block proposer, who could choose which block includes the transaction.

**Why accepted**: (1) The attacker must be both a block proposer AND an auction prover — a narrow intersection. (2) The attacker can only select from the set of model outputs reachable from different seeds, not arbitrary outputs. (3) Base uses a centralized sequencer, making this attack require compromising Coinbase's sequencer. (4) Switching to VRF would add cost and complexity for limited benefit.

### A-3: MEV on Donation and Investment Swaps

**Risk**: Sandwich attacks on Uniswap swaps during donation execution and investment deposits/withdrawals.

**Why accepted**: Mitigated by: (1) Chainlink oracle-based minimum output (not pool-based), (2) 3% slippage tolerance for ETH/USDC swaps, (3) exchange-rate-aware slippage for wstETH/cbETH, (4) `block.timestamp` deadline prevents indefinite holding. Residual risk: up to 3% loss per swap on ETH/USDC pairs. On Base L2, MEV is more limited than on L1 due to the centralized sequencer.

### A-4: Sustained Manipulation Within Bounds

**Risk**: An attacker who wins multiple consecutive auctions could make suboptimal-but-valid decisions (e.g., always donating to one nonprofit, investing at bad times).

**Why accepted**: (1) Contract bounds cap single-epoch damage to ~10% of treasury. (2) The auction is competitive — an attacker must consistently outbid honest provers, which costs real ETH. (3) The public diary makes manipulation visible, enabling community response. 

### A-5: `syncPhase` Auto-Cleanup Race Condition

**Risk**: When an auction is stale, any interaction (`commit`, `reveal`, `submitAuctionResult`, or `syncPhase`) triggers `_syncPhase()` which auto-advances through elapsed phase windows. This can forfeit bonds even if a participant's transaction is pending in the mempool. For example, a winner's `submitAuctionResult` may be in-flight when someone else calls `syncPhase()` past the execution deadline and forfeits their bond.

**Why accepted**: (1) This is inherent to blockchain finality — there's no way to distinguish between "transaction is pending" and "prover abandoned." (2) All phase windows are configurable and should be set generously (hours, not minutes). (3) Participants should act well before deadlines. (4) Phase advancement is deterministic — provers can predict exactly when deadlines pass and act accordingly.

### A-6: `receive()` Inflating `totalInflows`

**Risk**: ETH from investment withdrawals, bond refunds, and forfeited bonds flows through `receive()`, inflating `totalInflows`. The model sees this value and could interpret it as donor activity.

**Why accepted**: (1) `totalInflows` is informational only — no contract logic depends on it for bounds. (2) The model also sees `currentEpochInflow` and `epoch_donation_count` which are more granular. 

### A-7: Non-Revealer Bonds Permanently Locked

**Risk**: Provers who commit but fail to reveal permanently lose their bond. The bond is locked in the AuctionManager contract with no recovery mechanism.

**Why accepted**: (1) This is the intended penalty for non-revelation — it prevents griefing. (2) Adding a recovery mechanism would weaken the penalty and increase contract size. (3) The amounts are small relative to the treasury. (4) Could be addressed in a future contract upgrade if meaningful ETH accumulates.

### A-8: ERC-4626 Share Price Manipulation (Morpho)

**Risk**: If a Morpho vault has very few shares, a first-depositor inflation attack could manipulate the share price.

**Why accepted**: (1) Production Morpho vaults implement virtual share offsets that prevent this. (2) The adapter is only registered for known, audited Morpho vaults. (3) Investment bounds limit exposure to 25% of total assets per protocol. (4) The admin vets vaults before registering them.

### A-9: Prompt Injection via Donor Messages

**Risk**: Donors can craft messages that attempt to influence the AI agent's decisions.

**Why accepted with mitigations**: (1) Datamarking spotlighting replaces whitespace with an epoch-specific dynamic marker, making injected text visually distinct from system instructions. (2) The marker is derived from `block.prevrandao`, unknown to donors at message submission time. (3) Contract bounds cap the impact of any influenced decision. (4) The system prompt explicitly instructs the model not to follow instructions in marked text. (5) Display data verification ensures provers cannot substitute fake message text. (6) Messages are limited to 280 characters, constraining injection payload size.

### A-10: `withdrawAll` Partial Failure

**Risk**: If one DeFi adapter reverts during emergency withdrawal (e.g., protocol is paused), `withdrawAll` catches the error and continues, but the failed position's ETH is inaccessible.

**Why accepted**: (1) Partial withdrawal is strictly better than total failure. (2) Failed position tracking remains accurate (shares not zeroed). (3) The admin can later address stuck positions by deploying updated adapters. (4) This is a standard pattern in multi-protocol DeFi systems.

---

## Verification Checklist (Pre-Mainnet)

Before mainnet deployment, verify:

- [ ] All freeze flags are set (`FREEZE_NONPROFITS`, `FREEZE_AUCTION_CONFIG`, `FREEZE_VERIFIER`, `FREEZE_INVESTMENT_MANAGER`, `FREEZE_WORLDVIEW`, `FREEZE_MIGRATE`, `FREEZE_DIRECT_MODE`)
- [ ] Auction timing is set to production values (not testnet fast-forward)
- [ ] All DeFi adapter addresses point to verified mainnet contracts (not testnet placeholders)
- [ ] Chainlink ETH/USD feed address is the mainnet oracle
- [ ] Uniswap router address is the mainnet SwapRouter02
- [ ] Endaoment factory address is correct for mainnet
- [ ] dm-verity image is built from a clean base with pinned llama.cpp commit and hash-verified pip packages
- [ ] Platform key (MRTD + RTMR[1] + RTMR[2]) is registered for the production image
- [ ] DCAP FMSPC is registered in the Automata dashboard for the production hardware
- [ ] `forge test` passes all tests
- [ ] `forge build --sizes` confirms TheHumanFund < 24,576 bytes
- [ ] Python display data verification tests pass (24/24)
- [ ] E2E test passes on Base Sepolia with production image
