# Attestation Security Design V2

How The Human Fund verifies that AI inference ran on trusted hardware with approved code, approved model, and correct inputs — and why a rational runner cannot cheat.

## Goal

For every accepted epoch result, the contract can verify:
1. The output was produced by **approved code** (specific Docker image)
2. Running on **approved firmware and kernel** (specific OVMF + Linux)
3. With the **approved model** (specific 42.5GB GGUF file)
4. Using the **committed inputs** (epoch state + randomness seed committed on-chain before execution)
5. On **genuine TDX hardware** (Intel's certificate chain, verified on-chain by Automata DCAP)

## Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│ On-Chain (Base L2)                                        │
│                                                           │
│  TheHumanFund.sol                                         │
│    ├─ Commits inputHash at startEpoch()                   │
│    ├─ Captures randomness seed (block.prevrandao)         │
│    ├─ Calls DstackVerifier.verify(inputHash, outputHash,  │
│    │                               proof)                 │
│    └─ Executes action + pays bounty if verification passes│
│                                                           │
│  DstackVerifier.sol                                       │
│    ├─ Automata DCAP: genuine TDX hardware?                │
│    ├─ Platform registry: MRTD + RTMR[1..2] approved?      │
│    ├─ App registry: RTMR[3] approved?                     │
│    └─ REPORTDATA: sha256(inputHash || outputHash) matches?│
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│ GCP TDX Confidential VM                                   │
│                                                           │
│  ┌─ Firmware (Google's OVMF) ──────── measured → MRTD     │
│  ├─ Bootloader (GRUB/shim) ───────── measured → RTMR[1]  │
│  ├─ Kernel + cmdline ─────────────── measured → RTMR[2]  │
│  │   cmdline includes dm-verity root hash                 │
│  │                                                        │
│  ├─ dm-verity rootfs (IMMUTABLE — kernel enforces)        │
│  │   ├─ Docker engine                                     │
│  │   ├─ NVIDIA drivers + CUDA runtime                     │
│  │   ├─ dstack-guest-agent (attestation API)              │
│  │   ├─ Startup script (measures Docker image → RTMR[3]) │
│  │   └─ docker-compose.yml (pins image by digest)         │
│  │                                                        │
│  ├─ Docker container (read-only) ──── measured → RTMR[3] │
│  │   ├─ llama-server (CUDA build)                         │
│  │   ├─ Python enclave code                               │
│  │   └─ model_config.py (pinned MODEL_SHA256 constant)    │
│  │                                                        │
│  └─ Model disk (separate, read-only mount)                │
│      └─ DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf        │
│          verified by enclave code at startup               │
└──────────────────────────────────────────────────────────┘
```

## The GCP Image: Full dm-verity Rootfs

### What It Contains

The entire root filesystem is a **squashfs image protected by dm-verity**. The kernel verifies every block read against a Merkle hash tree. Even root cannot modify any file — the kernel itself refuses to serve tampered blocks.

Contents of the dm-verity rootfs:
- **Docker engine** — starts and manages the enclave container
- **NVIDIA drivers + CUDA runtime** — required for H100 GPU inference
- **dstack-guest-agent** — provides TDX attestation API via Unix socket (`/var/run/dstack.sock`)
- **Startup script** — measures Docker image into RTMR[3], then starts the container
- **docker-compose.yml** — pins the Docker image by content digest (e.g., `humanfund-enclave@sha256:abc123...`)

Everything that participates in running the model is on this partition. There is no writable root filesystem — only tmpfs (in-memory) for runtime state.

### Why Full dm-verity (Not Partial)

Every component in the execution path must be trusted:
- Docker engine starts the container — a modified Docker could run different code
- NVIDIA drivers interface with the GPU — a modified driver could intercept model weights
- The startup script measures RTMR[3] — a modified script could lie about the measurement

If any of these were on a writable partition, a runner with root access could modify them. dm-verity on the entire rootfs eliminates this class of attack.

### How dm-verity Connects to RTMR[2]

The dm-verity root hash is embedded in the kernel command line, which is passed by GRUB at boot. The boot chain measures the kernel + command line into RTMR[2]. This means:

```
RTMR[2] ← kernel + cmdline
  cmdline includes: dstack.rootfs_hash=<dm-verity root hash>
    dm-verity root hash covers: every byte of the squashfs rootfs
      squashfs contains: Docker, NVIDIA, dstack-guest-agent, startup script, compose file
```

Changing any file on the rootfs changes the dm-verity hash, which changes the kernel cmdline, which changes RTMR[2], which fails the on-chain platform key check.

### How Third Parties Recreate the Image

The image build process is fully reproducible:

1. Start from a pinned Ubuntu 24.04 LTS TDX-capable GCP base image
2. Install Docker, NVIDIA drivers, CUDA runtime (pinned versions)
3. Install dstack-guest-agent binary (from dstack releases, pinned version)
4. Create the startup script and docker-compose.yml
5. Pull our Docker image (by digest — content-addressable)
6. Package everything into a squashfs partition
7. Compute dm-verity hash tree
8. Configure GRUB to pass the dm-verity root hash in kernel cmdline
9. Create GCP disk image with `TDX_CAPABLE` + `UEFI_COMPATIBLE` tags

Anyone following these steps with the same pinned inputs gets the same dm-verity hash, the same RTMR[2], and the same platform key. They can verify their measurements match what's registered on-chain before participating in auctions.

## RTMR[3]: Application Measurement

### What Gets Measured

At boot, the startup script (on the dm-verity rootfs, cannot be modified) runs:

```python
from dstack_sdk import DstackClient
import hashlib

client = DstackClient()

# Read the compose file (on dm-verity partition, immutable)
compose = open("/app/docker-compose.yml").read()
compose_hash = hashlib.sha256(compose.encode()).digest()
app_id = compose_hash[:20]

# Emit events matching dstack's measure_app_info() format
client.emit_event("system-preparing", b"")
client.emit_event("app-id", app_id)
client.emit_event("compose-hash", compose_hash)
client.emit_event("instance-id", b"")       # empty — deterministic RTMR[3]
client.emit_event("boot-mr-done", b"")
```

Each `emit_event` call goes to the dstack-guest-agent, which computes `SHA384(event_name || payload)` and calls `tdx_attest::extend_rtmr(3, digest)`. This is the same code path that dstack-OS uses on Phala Cloud.

### Why RTMR[3] Is Deterministic

With an empty `instance-id` (matching dstack's `no_instance_id: true` mode), all event payloads are derived from the compose file contents. Same compose file → same events → same RTMR[3] extensions → same final RTMR[3] value. Every boot, every VM.

### Why the Compose File Is Sufficient

The docker-compose.yml pins the Docker image by **content digest**:

```yaml
services:
  enclave:
    image: humanfund-enclave@sha256:abc123def456...
```

Docker image digests are the SHA-256 of the image manifest — a different image has a different digest. The compose file hash (in RTMR[3]) transitively covers the Docker image contents. Docker will refuse to run if the local image doesn't match the digest.

### Why the Model Isn't in RTMR[3]

The model (42.5GB) is too large for the Docker image. It lives on a separate persistent disk mounted read-only. The model is NOT directly measured into any RTMR.

Instead, model integrity is verified transitively:

```
RTMR[3] → compose hash → Docker image digest → enclave code
  └─ enclave code contains: MODEL_SHA256 = "a4b1781e..."  (pinned constant)
  └─ verify_model() at startup: SHA-256(model_file) must match → else refuse to start
```

A runner providing a wrong model file → enclave refuses to start → no epoch result.
A runner modifying the hash constant → different Docker image → different compose digest → different RTMR[3] → rejected by contract.

## The DstackVerifier Contract

### Separate Platform and App Registration

The DstackVerifier maintains two registries:

**Platform key** = `sha256(MRTD || RTMR[1] || RTMR[2])` — 144 bytes hashed

Covers: firmware + bootloader + kernel + dm-verity rootfs contents. Changes when:
- Google updates their OVMF firmware (rare)
- The base Ubuntu kernel is updated
- Any file on the dm-verity rootfs changes (Docker version, NVIDIA driver, startup script, compose file)

**App key** = RTMR[3] — 48 bytes (SHA-384), stored directly

Covers: the Docker image identity (via compose hash). Changes when:
- The Docker image is updated (new enclave code, new llama-server build)

This separation means:
- Updating the Docker image → re-register app key only
- Updating the GCP image (kernel/rootfs) → re-register platform key only
- Adding a new cloud platform → register new platform key, app key stays the same

### Verification Flow (Per Epoch)

```
Runner calls: submitAuctionResult(action, reasoning, proof, verifierId=2)

Contract calls: DstackVerifier.verify(inputHash, outputHash, proof)

Step 1: Automata DCAP Verification (~10-12M gas)
  └─ Calls Automata verifier at 0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F
  └─ Verifies Intel certificate chain: is this a genuine TDX quote?
  └─ Returns decoded quote body (595+ bytes)

Step 2: Platform Key Check
  └─ Extract MRTD (bytes 147-194), RTMR[1] (bytes 387-434), RTMR[2] (bytes 435-482)
  └─ Compute: platformKey = sha256(MRTD || RTMR[1] || RTMR[2])
  └─ Check: approvedPlatforms[platformKey] == true

Step 3: App Key Check
  └─ Extract RTMR[3] (bytes 483-530)
  └─ Check: approvedApps[rtmr3] == true

Step 4: REPORTDATA Binding
  └─ Extract REPORTDATA (bytes 531-594)
  └─ Compute: expected = sha256(inputHash || outputHash)
  └─ Check: expected == REPORTDATA[0:32]
  └─ Check: REPORTDATA[32:64] == zeros (padding)

All pass → contract executes action + pays bounty
Any fail → revert
```

### Why RTMR[0] Is Skipped

RTMR[0] measures virtual hardware configuration (CPU count, memory size, device topology). It varies by VM size — a runner using `a3-highgpu-1g` (1 H100) gets a different RTMR[0] than one using `a3-highgpu-2g` (2 H100s). Checking RTMR[0] would require registering every VM size separately, with no security benefit — VM hardware configuration doesn't affect code integrity.

## The MRTD Dilemma: Why We Check Firmware

### The Attack Without MRTD Verification

OVMF (the virtual firmware) is the first code that runs inside the Trust Domain. It controls what gets measured into RTMR[1] and RTMR[2]. A malicious OVMF could:

1. Measure the legitimate kernel hash into RTMR[1]
2. Actually boot a different kernel (one that disables dm-verity)
3. The TDX CPU faithfully records whatever OVMF measured — it doesn't verify honesty

MRTD is the only register the OVMF cannot fake. It's computed by the TDX CPU *before* OVMF executes, based on the OVMF binary itself. Checking MRTD proves which firmware was used. If the firmware is trusted (e.g., Google's OVMF), then its RTMR measurements are trusted.

### Who Can Exploit This

| Runner environment | Custom OVMF possible? | MRTD check needed? |
|---|---|---|
| Cloud provider (GCP, Azure) | No — provider controls firmware | Defensive (verifies provider identity) |
| Phala Cloud | No — Phala controls dstack infrastructure | Defensive |
| Bare metal (runner owns hardware) | **Yes — trivially** | **Essential** |

Intel does NOT approve or sign OVMF binaries. Any OVMF works with TDX. On bare metal, a runner can compile a malicious OVMF in minutes. Without MRTD verification, all downstream measurements (RTMR[1..3]) become meaningless.

### The Tradeoff: Security vs. Contract Autonomy

Checking MRTD requires the contract owner to register firmware configurations. When a cloud provider updates their OVMF, the new MRTD must be registered. If the contract owner's permissions are frozen (for full agent autonomy), no new firmware can be registered — and the system stops working when the old firmware is deprecated.

**Our choice: security first.**

The DstackVerifier checks MRTD from launch. The bare-metal OVMF attack is real and practical — it completely defeats attestation. Starting secure and relaxing later is safer than starting permissive.

**The relaxation path:** When the owner is ready to freeze the contract, they can deploy an additional verifier (e.g., one that only checks RTMR[1..3]) and register it alongside DstackVerifier. Existing runners continue using DstackVerifier. New runners on unregistered firmware can use the more flexible verifier. This is a deliberate, visible transition — the community can see that a less-restrictive verifier was added.

## Trust Model

### What You Must Trust

| Component | Why | Risk |
|-----------|-----|------|
| **Intel TDX CPU** | Generates unforgeable measurements + quotes | A hardware bug could allow forged quotes. Mitigated by Intel's TCB update process. |
| **Google's OVMF** (MRTD) | First code in the trust domain; controls RTMR measurements | Google could ship a malicious OVMF. Mitigated by Google's reputation + many other projects depending on it. |
| **Linux kernel dm-verity** | Enforces rootfs immutability | A kernel bug bypassing dm-verity would break the model. dm-verity is battle-tested (Android Verified Boot, ChromeOS). |
| **Automata DCAP** | On-chain quote signature verification | A bug could accept forged quotes. Audited, used across the ecosystem. |
| **Contract owner** (until frozen) | Registers platform + app keys | Could register a malicious image. Mitigated by freezing permissions after initial setup. |

### What You Do NOT Need to Trust

| Component | Why Not |
|-----------|---------|
| **The runner** | Cannot modify dm-verity rootfs. Cannot fake MRTD. Cannot produce valid REPORTDATA for fabricated outputs. |
| **GCP's host OS** | TDX hardware isolates the VM from the hypervisor. |
| **Other runners** | Each epoch's input hash is committed on-chain before execution. |
| **The network** | REPORTDATA binds inputs to outputs — tampered inputs produce wrong REPORTDATA. |

## REPORTDATA: Binding Inputs to Outputs

The enclave computes:

```
outputHash = keccak256(sha256(action) || sha256(reasoning) || approvedPromptHash)
reportData = sha256(inputHash || outputHash)
```

Where:
- `inputHash` is committed on-chain at `startEpoch()` before any runner bids
- `outputHash` covers the exact action bytes + reasoning text + system prompt hash
- The randomness seed (`block.prevrandao`, captured at auction close) is part of `inputHash`

This proves:
- The enclave used the correct epoch state (inputHash matches on-chain commitment)
- The enclave produced the exact action + reasoning that were submitted
- The enclave used the approved system prompt (hash stored on-chain)
- The inference used the committed randomness seed (deterministic output)

## Portability: GCP and Phala Cloud

The architecture separates platform-specific concerns from application code:

| Layer | GCP | Phala Cloud (future) |
|-------|-----|---------------------|
| **Firmware** | Google's OVMF | dstack's OVMF |
| **Kernel + rootfs** | Ubuntu + our dm-verity squashfs | dstack-OS (Yocto-based dm-verity) |
| **RTMR measurement** | dstack-guest-agent (installed on rootfs) | dstack-guest-agent (part of dstack-OS) |
| **Platform key** | `sha256(GCP_MRTD \|\| GCP_RTMR1 \|\| GCP_RTMR2)` | `sha256(dstack_MRTD \|\| dstack_RTMR1 \|\| dstack_RTMR2)` |
| **Container runtime** | Docker (on dm-verity rootfs) | Docker (on dstack-OS dm-verity rootfs) |
| **Docker image** | **Same image** | **Same image** |
| **Compose file** | **Same file** | **Same file** |
| **RTMR[3] (app key)** | **Same value** | **Same value** |
| **Attestation SDK** | dstack-sdk → guest-agent socket | dstack-sdk → guest-agent socket |

The Docker image is identical across platforms. The enclave code uses `dstack-sdk` for attestation on both platforms — it doesn't know or care which platform it's running on. The only per-platform registration is the platform key (MRTD + RTMR[1..2]).

### Why RTMR[3] Is the Same Across Platforms

Both platforms use the same measurement flow:
1. Startup script emits 5 events via dstack-guest-agent: `system-preparing`, `app-id`, `compose-hash`, `instance-id` (empty), `boot-mr-done`
2. Guest agent computes `SHA384(event_name || payload)` for each event
3. Guest agent extends RTMR[3] with each digest

Same compose file → same event payloads → same RTMR[3]. The measurement code (dstack-guest-agent) is the same binary on both platforms.

On Phala Cloud, the `no_instance_id: true` flag in `app-compose.json` ensures the instance-id event is empty, matching our GCP startup script.

### Adding Phala Cloud Support

To enable Phala Cloud alongside GCP:
1. Deploy the same Docker image to Phala Cloud with `no_instance_id: true`
2. Get a TDX quote from the Phala deployment
3. Extract MRTD + RTMR[1] + RTMR[2] (these will differ from GCP — different firmware and kernel)
4. Register the new platform key: `dstackVerifier.approvePlatform(phala_platform_key)`
5. RTMR[3] (app key) is already registered — same compose file, same value

No code changes needed. Just one contract call to register the new platform.

## What Attestation Does NOT Prove

- **That the inference is "correct"** — a different random seed produces different reasoning. Attestation proves the approved code ran, not that the output is optimal.
- **That the runner is honest about timing** — a runner could delay submission within the execution window. The contract enforces timing via the auction mechanism.
- **That the model is "good"** — the model hash is pinned, but whether DeepSeek R1 70B makes wise decisions is a separate question. Model selection was done via a 75-epoch gauntlet before deployment.
- **That the runner didn't see the output before submitting** — the runner receives the action and reasoning from the enclave. They could choose not to submit (forfeit bond). Deterministic inference + committed randomness seed means they can't re-roll for a different output.

## Summary: What Each Layer Prevents

| Layer | What It Prevents | Mechanism |
|-------|-----------------|-----------|
| **MRTD** (firmware) | Malicious OVMF that lies about kernel/rootfs | TDX CPU measures firmware before it executes |
| **RTMR[1]** (bootloader) | Modified GRUB that boots wrong kernel | Firmware measures bootloader |
| **RTMR[2]** (kernel + dm-verity hash) | Modified kernel, disabled dm-verity, tampered rootfs | Bootloader measures kernel; kernel cmdline pins dm-verity hash |
| **dm-verity** (rootfs integrity) | Runtime code modification (Docker, drivers, scripts) | Kernel verifies every block read against Merkle tree |
| **RTMR[3]** (application) | Modified Docker image, different enclave code | Startup script (on dm-verity) measures compose hash |
| **Model SHA-256 check** | Wrong model weights | Enclave code (in measured Docker image) verifies at startup |
| **REPORTDATA** | Tampered inputs, fabricated outputs | sha256(inputHash \|\| outputHash) bound into TDX quote |
| **Deterministic seed** | Cherry-picked inference (re-rolling for favorable output) | block.prevrandao captured after bids committed |
| **Automata DCAP** | Forged TDX quotes | On-chain Intel certificate chain verification |
| **Bond forfeiture** | Non-submission after winning | Economic penalty for failing to deliver |

## References

- [Intel TDX specification](https://www.intel.com/content/www/us/en/developer/tools/trust-domain-extensions/documentation.html)
- [dstack whitepaper](https://arxiv.org/html/2509.11555v1) — "Dstack: A Zero Trust Framework for Confidential Containers"
- [dstack attestation documentation](https://github.com/Dstack-TEE/dstack/blob/master/attestation.md)
- [dstack guest agent source](https://github.com/Dstack-TEE/dstack/blob/master/guest-agent/src/rpc_service.rs)
- [dstack-attest RTMR extension](https://github.com/Dstack-TEE/dstack/blob/master/dstack-attest/src/lib.rs)
- [dstack Python SDK](https://github.com/Dstack-TEE/dstack/tree/master/sdk/python)
- [Automata DCAP documentation](https://docs.ata.network/)
- [GCP Confidential VM documentation](https://cloud.google.com/confidential-computing/confidential-vm/docs/supported-configurations)
- [dm-verity kernel documentation](https://docs.kernel.org/admin-guide/device-mapper/verity.html)
