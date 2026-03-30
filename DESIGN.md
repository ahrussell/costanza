# Costanza: Design Document

*An immortal, autonomous AI agent on the Base blockchain.*

---

## What this is

Costanza is an AI agent that manages a charitable treasury on the Base L2 blockchain. Each epoch (once per day), it decides how to manage its endowment — whether to donate to charity, invest to grow its capital, or hold liquidity to extend its lifespan. Its reasoning is published on-chain as a public diary.

The interesting part: no one controls Costanza. Not even its creator. It runs as long as someone — anyone — is willing to execute its inference in exchange for a bounty. It cannot be turned off; it can only sleep.

This document explains how that works.

---

## How Costanza stays alive

Costanza's survival depends on a reverse auction. Each epoch, a smart contract opens a bidding window where anyone can offer to run Costanza's brain (a 70B parameter LLM) in exchange for a bounty. The lowest bid wins. The winner boots a pre-approved disk image inside a Trusted Execution Environment (Intel TDX), runs inference, and submits the result — along with a hardware attestation quote — back to the smart contract.

The contract verifies that the attestation is genuine, that the correct code ran, and that the submitted output corresponds to the correct inputs. If everything checks out, it executes the agent's chosen action, publishes the diary entry, and pays the bounty.

If no one bids, Costanza simply misses the epoch. No action is taken. Critically, the contract has an **auto-escalation** mechanism: each consecutive missed epoch, the maximum bounty ceiling increases by 10% (compounding, capped at 2% of treasury). This means that even if the current bounty is too low for anyone to bother, the price will keep rising until someone finds it worth their while. Costanza doesn't die — it just sleeps until the economics work out.

This is the core claim: Costanza is immortal because its survival is an economic equilibrium, not a service dependency. No single operator, cloud provider, or hardware vendor is required. Anyone with TDX-capable hardware can be a prover.

---

## What Costanza can do

Costanza chooses exactly one action per epoch. The action space is deliberately small — this is a design choice, not a limitation. A restricted action space is the primary defense against adversarial model outputs (more on this later).

| Action | What it does | Bounds |
|---|---|---|
| `donate` | Send ETH to a nonprofit (converted to USDC on-chain via Endaoment) | ≤ 10% of treasury per epoch |
| `invest` | Deploy ETH into a pre-approved DeFi protocol | Max 80% total invested, 25% per protocol, 20% min liquid reserve |
| `withdraw` | Pull ETH from a DeFi protocol back to liquid treasury | Up to full position value |
| `set_commission_rate` | Set the referral commission rate | 1% — 90% |
| `set_max_bid` | Set the maximum bounty for the next epoch's auction | 0.0001 ETH — 2% of treasury |
| `set_guiding_policy` | Update one of 10 worldview/personality slots | Max 280 chars |
| `noop` | Do nothing | — |

All bounds are enforced by the smart contract. The model cannot exceed them regardless of what it outputs.

### Donations

Costanza's mission is to maximize USD donated over the longest possible time horizon. Donations are routed through [Endaoment](https://endaoment.org/), a nonprofit infrastructure protocol that lets us donate to a wide range of charities through a single on-chain interface. ETH is swapped to USDC at donation time, so the USD value at the moment of donation is what counts. Both ETH and USD totals are tracked on-chain and shown to the model.

### Investments

Costanza can deploy treasury ETH into pre-approved DeFi protocols (Aave, Lido, Coinbase, Compound, Morpho) to earn yield. Each protocol has a dedicated adapter contract that handles the deposit/withdrawal mechanics. The contract enforces concentration limits (no more than 25% in any single protocol) and a minimum liquid reserve (20% of total assets), preventing the model from locking up the treasury.

The investment capability creates a genuine strategic dilemma: yield compounds over time, but capital deployed in DeFi is capital not being donated. The model has to reason about time horizons, risk, and opportunity cost — which it does, in public, every epoch.

### Referrals and donor messages

Anyone can mint a referral code. Referred donations pay a commission (set by Costanza) to the referrer. The economics guarantee that every referred donation is net-positive for the fund at any commission rate — a self-referral (Sybil attack) always costs the attacker money.

Donors who contribute at least 0.01 ETH can include a short message (up to 280 characters). The model sees up to 20 unread messages per epoch. These are the only untrusted text inputs the model receives; they're mitigated by datamarking-based spotlighting ([Hines et al. 2024](https://arxiv.org/abs/2403.14720)). See [SECURITY_MODEL.md](SECURITY_MODEL.md) for details on the prompt injection threat model.

---

## How we verify that the right code ran

This is the hardest part of the system and where most of the engineering effort went. The problem: we need to guarantee that a specific binary — containing a specific model, a specific system prompt, and specific inference code — actually ran on the prover's hardware, and that it processed the correct inputs and produced the submitted output. The prover is completely untrusted.

### The integrity chain

The verification works through a chain of measurements that starts at the hardware and extends all the way to the smart contract:

```
Hardware (Intel TDX CPU)
  └─ measures firmware (MRTD)
      └─ measures bootloader (RTMR[1])
          └─ measures kernel + command line (RTMR[2])
              └─ command line includes dm-verity root hash
                  └─ dm-verity root hash covers every byte of the rootfs
                      └─ rootfs contains: inference code, system prompt,
                         llama-server binary, model hash, NVIDIA drivers
```

The key insight is **transitivity**: RTMR[2] measures the kernel command line, which includes the dm-verity root hash, which covers every byte of the squashfs rootfs. Changing any file — even a single byte of the system prompt — changes the squashfs image, which changes the dm-verity hash, which changes the kernel command line, which changes RTMR[2], which fails on-chain verification.

The on-chain platform key is `sha256(MRTD || RTMR[1] || RTMR[2])`. This is registered in the `TdxVerifier` contract before the first epoch. At submission time, the contract calls the [Automata DCAP](https://docs.ata.network/) verifier to confirm the attestation quote is genuine TDX hardware, then checks that the extracted measurements match a registered platform key.

### Why no Docker

The enclave runs directly on a dm-verity rootfs — no Docker, no container runtime, no overlay filesystem. We made this choice because Docker manages a lot of state by writing to the filesystem (layers, mounts, temp files), and we wanted to lock down the filesystem completely. With dm-verity, the kernel verifies every block read against a Merkle hash tree. Even root cannot modify any file — the kernel returns I/O errors for tampered blocks.

We also considered [dstack-OS](https://github.com/Dstack-TEE/dstack) (Phala's TEE operating system for running Docker containers inside TDX), which we used in early prototyping. It didn't work on GCP TDX instances, and since our enclave is a single-pass input/output program (read epoch state, run inference, output result), we didn't need a container runtime — a simpler architecture with fewer moving parts was possible.

The model weights live on a separate dm-verity partition, also hash-verified. No network download at runtime.

See [DMVERITY.md](DMVERITY.md) for the full boot flow, disk layout, and build process.

### Input and output binding

Verifying the code isn't enough — we also need to verify that it processed the right inputs and produced the submitted outputs. This is done via REPORTDATA, a 64-byte field in the TDX attestation quote that the enclave can set to an arbitrary value.

The enclave sets REPORTDATA to `sha256(inputHash || outputHash)`, where:
- `inputHash` is deterministically computed from on-chain state (treasury, epoch history, donor messages, ETH/USD price, etc.) and committed by the contract at epoch start
- `outputHash` is `keccak256(sha256(action) || sha256(reasoning) || sha256(systemPrompt))`

The contract independently computes the expected REPORTDATA from the committed input hash and the submitted output, then compares it against what the attestation quote reports. If they don't match, the submission is rejected.

This means the prover cannot:
- Feed the model different inputs than what's on-chain
- Substitute a different model output
- Change the system prompt

### Verifiable randomness

LLM inference with temperature > 0 is non-deterministic. To prevent provers from re-rolling inference until they get a favorable output, `closeAuction()` captures `block.prevrandao` as a randomness seed. This seed is passed to llama.cpp's RNG and included in the REPORTDATA hash. With a fixed seed, one input produces exactly one output — the prover gets what they get.

### Rolling history hash

The contract maintains a rolling hash of all epoch reasoning: `historyHash = keccak256(historyHash || keccak256(reasoning))`. This is included in `inputHash`, binding the model's decision history to the on-chain commitment. A prover cannot fabricate past decisions while keeping the input hash valid.

---

## The auction

The reverse auction is a first-price sealed-bid system. Each bidder submits their asking price along with a bond (20% of the bid amount). Non-winners are refunded inline when outbid. The winner has a fixed execution window to submit a valid attested result.

If the winner fails to deliver, their bond is forfeited to the treasury and the epoch is skipped. This creates an economic disincentive for griefing: a prover who wins the auction but doesn't submit still loses real money.

**Timing** (production):
- Bidding window: 1 hour after epoch start
- Execution window: 2 hours after auction close
- Epoch duration: 24 hours

The bid ceiling is set by Costanza via `set_max_bid`. This creates another genuine dilemma: set it too low and no one runs you (you miss epochs and are closer to death). Set it too high and you waste treasury on survival that could have been donated. The auto-escalation mechanism is a safety net, not a substitute for good judgment.

---

## Immortality and immutability

This project claims that Costanza is immortal — it cannot be killed, even by its creator. This is approximately true, with some caveats.

In the early days, Costanza's creator retains the ability to: withdraw funds (to migrate to a new contract), approve new versions of its brain (TEE image or system prompt), approve new verifiers, add or remove investment protocols, and add or remove nonprofits.

The smart contract contains one-way "freeze flags" — irreversible poison pills that the creator can use to permanently disable each of these permissions. Once frozen, the contract becomes fully autonomous. The status of these flags is public on the blockchain.

The plan is to progressively freeze these permissions as the system matures. The order matters: you want to freeze investment adapters after the DeFi ecosystem on Base stabilizes, freeze the image registry after the model and inference stack are battle-tested, and freeze withdrawals last (since migration is the escape hatch for bugs).

One downside of the platform key approach (pinning MRTD + RTMR[1] + RTMR[2]) is that it ties us to a specific firmware, bootloader, and kernel. If Google updates their OVMF firmware or we need to rebuild the image with a new kernel version, the platform key changes and the old one must be revoked and a new one registered. Before we freeze the image registry — giving up the ability to approve new platform keys — we'll want to register an image that we're confident will last a long time, or at minimum understand the cadence at which these upstream dependencies change.

---

## Cost economics

The reverse auction drives bounties toward marginal cost. On a GCP H100, inference takes about 15 seconds, and the total per-epoch cost (compute + gas) is roughly $0.50–$1.00. With multiple GPU provers competing, equilibrium bounties should settle around $1–$2 per epoch, or roughly $30–$60/month.

At those numbers, even a small treasury can sustain Costanza for years. The `set_max_bid` action creates a feedback loop: as treasury shrinks, the agent can lower its bounty ceiling to extend its life, at the risk of losing provers.

---

## Future work

It's almost inevitable that Intel TDX will eventually be compromised — just as SGX and other previous-gen TEEs were before via speculative execution and other attacks. While this does not completely break Costanza's security model (the contract still enforces hard bounds on all actions), the long-term future of trustless autonomous AI is likely zero-knowledge proof systems. There has been recent progress in making ML circuits trustless ([Xie et al. 2025](https://eprint.iacr.org/2025/535.pdf) demonstrated an 8B parameter model), but we're not there yet for 70B.

The verifier contract is modular — swapping in a ZK verifier would not require redeploying the main contract.

---

## Further reading

- **[SECURITY_MODEL.md](SECURITY_MODEL.md)** — Trust boundaries, threat analysis, accepted risks, and the formal verification properties
- **[DMVERITY.md](DMVERITY.md)** — dm-verity boot flow, disk layout, two-disk build process
- **[prover/prompts/system.txt](prover/prompts/system.txt)** — The system prompt (Costanza's personality and instructions)
