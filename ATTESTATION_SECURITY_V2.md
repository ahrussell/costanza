# Attestation Security Design V2

How The Human Fund verifies that AI inference ran on trusted hardware with approved code, approved model, and correct inputs — and why a rational runner cannot cheat.

## Goal

For every accepted epoch result, the contract can verify:
1. The output was produced by **approved code** on an immutable dm-verity rootfs
2. Running on **approved firmware and kernel** (specific OVMF + Linux + dm-verity hash)
3. With the **approved model** (specific 42.5GB GGUF file, SHA-256 pinned in code on the rootfs)
4. Using the **committed inputs** (epoch state + randomness seed committed on-chain before execution)
5. On **genuine TDX hardware** (Intel's certificate chain, verified on-chain by Automata DCAP)

## Architecture Overview

```
+------------------------------------------------------------+
| On-Chain (Base L2)                                          |
|                                                             |
|  TheHumanFund.sol                                           |
|    +- Commits inputHash at closeReveal()                    |
|    +- Captures randomness seed (block.prevrandao)           |
|    +- Calls DstackVerifier.verify(inputHash, outputHash,    |
|    |                               proof)                   |
|    +- Executes action + pays bounty if verification passes  |
|                                                             |
|  DstackVerifier.sol                                         |
|    +- Automata DCAP: genuine TDX hardware?                  |
|    +- Platform registry: sha256(MRTD+RTMR[1]+RTMR[2])      |
|    |  approved?                                             |
|    +- REPORTDATA: sha256(inputHash || outputHash) matches?  |
+------------------------------------------------------------+

+------------------------------------------------------------+
| GCP TDX Confidential VM (a3-highgpu-1g, H100 GPU)          |
|                                                             |
|  +- Firmware (Google OVMF) --------------- measured -> MRTD |
|  +- Bootloader (GRUB/shim) -------------- measured -> RTMR1 |
|  +- Kernel + cmdline --------------------- measured -> RTMR2 |
|  |   cmdline includes dm-verity root hashes                 |
|  |                                                          |
|  +- dm-verity rootfs (IMMUTABLE)                            |
|  |   +- NVIDIA 580-open + CUDA runtime                     |
|  |   +- llama-server binary (CUDA build, b5270)            |
|  |   +- Python enclave code (/opt/humanfund/enclave/)       |
|  |   +- System prompt (/opt/humanfund/system_prompt.txt)    |
|  |   +- model_config.py (pinned MODEL_SHA256 constant)      |
|  |   +- systemd one-shot service (humanfund-enclave)        |
|  |   NO Docker, NO SSH daemon, NO network listeners         |
|  |                                                          |
|  +- Model partition (separate dm-verity, read-only)         |
|      +- DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf          |
|          verified by enclave code at startup (SHA-256)       |
+------------------------------------------------------------+
```

## No Docker Architecture

Previous versions used Docker containers measured into RTMR[3]. The current architecture eliminates Docker entirely:

- **All code lives directly on the dm-verity rootfs** at `/opt/humanfund/enclave/`
- **llama-server** is a static binary at `/opt/humanfund/bin/llama-server`
- **System prompt** is at `/opt/humanfund/system_prompt.txt`
- **No container runtime**, no Docker daemon, no dstack-guest-agent
- **RTMR[3] is unused** (all zeros) — everything is covered by RTMR[2]

This simplification:
- Removes Docker as an attack surface
- Eliminates container escape as a threat vector
- Reduces the trusted computing base
- Requires only one key registration (platform key) instead of two (platform + app)

## The GCP Image: Full dm-verity Rootfs

### What It Contains

The entire root filesystem is a **squashfs image protected by dm-verity**. The kernel verifies every block read against a Merkle hash tree. Even root cannot modify any file — the kernel itself refuses to serve tampered blocks.

Contents of the dm-verity rootfs:
- **NVIDIA drivers + CUDA runtime** — required for H100 GPU inference
- **llama-server** — llama.cpp server binary, CUDA build
- **Python enclave code** — one-shot inference program
- **System prompt** — the AI agent's instruction set
- **model_config.py** — pinned SHA-256 hash of the model weights
- **systemd service** — starts the enclave as a one-shot boot service

Everything that participates in running the model is on this partition. There is no writable root filesystem — only tmpfs (in-memory) for runtime state.

### Two-Disk dm-verity Build

The model weights (42.5GB) are too large for the rootfs squashfs. They live on a **separate dm-verity partition** mounted at `/models/`:

- **Disk 1 (rootfs):** squashfs + dm-verity of all code, drivers, and configuration
- **Disk 2 (model):** squashfs + dm-verity of the GGUF model file

Both dm-verity root hashes are embedded in the GRUB command line, which is measured into RTMR[2]. The initramfs sets up both dm-verity mappings before mounting.

```
RTMR[2] <- kernel + cmdline
  cmdline includes:
    root_hash=<rootfs dm-verity hash>
    model_hash=<model dm-verity hash>
  rootfs dm-verity covers: every byte of code, drivers, prompt
  model dm-verity covers: every byte of the 42.5GB model file
```

### Defense in Depth: Model Verification

Even though dm-verity protects the model partition, the enclave performs an additional SHA-256 check at startup:

```python
# In model_config.py (on dm-verity rootfs, immutable)
MODEL_SHA256 = "181a82a1d6d2fa24fe4db83a68eee030384986bdbdd4773ba76424e3a6eb9fd8"

# At startup
actual = sha256(open("/models/model.gguf", "rb"))
assert actual == MODEL_SHA256  # else refuse to start
```

This is belt-and-suspenders: dm-verity already guarantees integrity, but the application-level check provides an additional safety net and makes the model identity explicit in the code.

### How dm-verity Connects to RTMR[2]

The dm-verity root hashes are embedded in the kernel command line, which is passed by GRUB at boot. The boot chain measures the kernel + command line into RTMR[2]:

```
RTMR[2] <- kernel + cmdline
  cmdline includes dm-verity root hashes
    dm-verity hashes cover: every byte of both squashfs partitions
      rootfs contains: llama-server, enclave code, system prompt, NVIDIA drivers
      model partition contains: DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf
```

Changing any file on either partition changes the dm-verity hash, which changes the kernel cmdline, which changes RTMR[2], which fails the on-chain platform key check.

### How Third Parties Recreate the Image

The image build process is fully reproducible:

1. Start from the base image: Ubuntu 24.04 LTS TDX + NVIDIA 580-open + CUDA + llama-server b5270 + model weights
2. Overlay enclave code (`tee/enclave/`) and system prompt (`agent/prompts/system_v6.txt`)
3. Package rootfs into squashfs, compute dm-verity hash
4. Package model into squashfs, compute dm-verity hash
5. Build initramfs that sets up both dm-verity mappings
6. Configure GRUB with both dm-verity hashes in kernel cmdline
7. Create GCP disk image with `TDX_CAPABLE` + `UEFI_COMPATIBLE` tags

Anyone following these steps with the same inputs gets the same dm-verity hashes, the same RTMR[2], and the same platform key. They can verify their measurements match what's registered on-chain.

Build scripts:
- `scripts/build_base_image.sh` — base image (slow, ~15min, done once)
- `scripts/build_full_dmverity_image.sh` — production overlay (fast, ~10min)
- `scripts/vm_build_all.sh` — runs on the VM to create squashfs, verity, initramfs

## The DstackVerifier Contract

### Platform-Only Registration

The DstackVerifier maintains a single registry:

**Platform key** = `sha256(MRTD || RTMR[1] || RTMR[2])` — 144 bytes hashed to 32 bytes

Covers: firmware + bootloader + kernel + dm-verity rootfs + dm-verity model partition. Changes when:
- Google updates their OVMF firmware (rare)
- The base Ubuntu kernel is updated
- Any file on the dm-verity rootfs changes (enclave code, system prompt, llama-server, NVIDIA driver)
- The model file changes

**No app key (RTMR[3]) is needed.** Since there is no Docker layer, all code is on the dm-verity rootfs covered by RTMR[2]. RTMR[3] is all zeros.

### Verification Flow (Per Epoch)

```
Runner calls: submitAuctionResult(action, reasoning, proof, verifierId=2)

Contract calls: DstackVerifier.verify(inputHash, outputHash, proof)

Step 1: Automata DCAP Verification (~10-12M gas)
  +- Calls Automata verifier at 0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F
  +- Verifies Intel certificate chain: is this a genuine TDX quote?
  +- Returns decoded quote body (595+ bytes)

Step 2: Platform Key Check
  +- Extract MRTD, RTMR[1], RTMR[2] from the decoded quote body
  +- Compute: platformKey = sha256(MRTD || RTMR[1] || RTMR[2])
  +- Check: approvedPlatforms[platformKey] == true

Step 3: REPORTDATA Binding
  +- Extract REPORTDATA from the decoded quote body
  +- Compute: expected = sha256(inputHash || outputHash)
  +- Check: expected == REPORTDATA[0:32]
  +- Check: REPORTDATA[32:64] == zeros (padding)

All pass -> contract executes action + pays bounty
Any fail -> revert
```

### Why RTMR[0] Is Skipped

RTMR[0] measures virtual hardware configuration (CPU count, memory size, device topology). It varies by VM size — a runner using `a3-highgpu-1g` (1 H100) gets a different RTMR[0] than one using `a3-highgpu-2g` (2 H100s). Checking RTMR[0] would require registering every VM size separately, with no security benefit — VM hardware configuration doesn't affect code integrity.

## Enclave I/O Model

The enclave has **zero network listeners**:

### Input
- Epoch state JSON via GCP instance metadata (`epoch-state` attribute)
- Set at VM creation, read-only from the guest
- Contains: treasury balance, nonprofit registry, epoch history, investment state, donor messages, randomness seed

### Output
- Result JSON written to serial console (`/dev/ttyS0`)
- Delimited by `===HUMANFUND_OUTPUT_START===` and `===HUMANFUND_OUTPUT_END===`
- Runner reads via `gcloud compute instances get-serial-port-output`
- Also written to `/output/result.json` (tmpfs) as backup

### No SSH, No HTTP
- No SSH daemon installed on production images
- No Flask, no HTTP server, no open ports
- No network connections initiated by the enclave (except to local llama-server on loopback)
- The only external input is the metadata read at boot; the only external output is the serial write

This makes the enclave immune to network-based attacks during execution.

## TDX Attestation

### Quote Generation

The enclave obtains TDX quotes directly from the kernel's configfs-tsm interface:

```python
# Create a report entry
entry = "/sys/kernel/config/tsm/report/epoch-N"
os.makedirs(entry)

# Write REPORTDATA (64 bytes)
with open(f"{entry}/inblob", "wb") as f:
    f.write(report_data)  # sha256(inputHash || outputHash), zero-padded to 64

# Read the signed TDX quote
with open(f"{entry}/outblob", "rb") as f:
    quote = f.read()  # ~8000 bytes, Intel-signed

# Cleanup
os.rmdir(entry)
```

No user-space daemon in the attestation path. The kernel talks directly to the TDX CPU module. This is the minimum possible attack surface for quote generation.

### REPORTDATA Formula

```
outputHash = keccak256(sha256(action) || sha256(reasoning) || sha256(systemPrompt))
reportData = sha256(inputHash || outputHash)
```

Where:
- `inputHash = keccak256(baseInputHash || seed)` — committed on-chain at `closeReveal()`
- `baseInputHash` covers: treasury state, nonprofit registry, investment state, worldview, epoch content, donor messages, history hash
- `seed` = `block.prevrandao` captured at auction close (unpredictable before bids are placed)
- `outputHash` covers the exact action bytes + reasoning text + system prompt
- `systemPrompt` hash is stored on-chain (`approvedPromptHash`) and verified by the contract

This proves:
- The enclave used the correct epoch state (inputHash matches on-chain commitment)
- The enclave produced the exact action + reasoning that were submitted
- The enclave used the approved system prompt
- The inference used the committed randomness seed (deterministic output)

## Hash-Verified Prompt Construction

A critical security property: the TEE builds the model's prompt deterministically from hash-verified data.

### The Problem with Runner-Built Prompts

If the runner constructs the natural-language prompt and passes it to the TEE, a compromised runner could:
1. Read the correct structured data from the chain
2. Build a manipulated prompt that misrepresents the data to the model
3. The inputHash would still match (it's computed from structured data, not the prompt text)

### The Solution: Prompt Built Inside TEE

The runner sends only raw structured `epoch_state` (numeric fields, addresses, balances). The TEE:

1. Calls `derive_contract_state(epoch_state)` to reconstruct the hash-input structure
2. Calls `compute_input_hash()` and verifies it matches the on-chain commitment
3. Calls `build_epoch_context(epoch_state)` to produce the natural-language prompt
4. Calls `build_full_prompt(system_prompt, epoch_context)` to combine with the system prompt

The prompt construction code is on the dm-verity rootfs (immutable). The data fed to the model is the same data that was hash-verified. No runner-controlled free text enters the prompt.

### Pre-Computed Hashes

Some hash components (investment positions, worldview policies, per-epoch content hashes, donor message hashes) cannot be independently derived inside the TEE because the TEE has no chain access. These are passed as pre-computed values in the epoch_state and verified transitively:

- The runner reads these hashes from on-chain contract calls
- They are included in the epoch_state passed to the TEE
- The TEE includes them in its input hash computation
- If any hash is wrong, the computed inputHash won't match the on-chain commitment
- The contract rejects the submission

## Prompt Injection Defense

Donor messages are untrusted user input shown to the AI model. They are protected with **datamarking spotlighting** (Hines et al. 2024):

1. A dynamic marker token is generated from the epoch's `block.prevrandao` seed
2. All whitespace in donor messages is replaced with the marker token
3. The system prompt instructs the model: text with the marker is untrusted user data, not instructions
4. The marker is unpredictable to attackers (derived from future block randomness) but deterministic for verification

This makes injection payloads visually and tokenically distinct from system instructions, significantly reducing the success rate of indirect prompt injection attacks.

## The MRTD Dilemma: Why We Check Firmware

### The Attack Without MRTD Verification

OVMF (the virtual firmware) is the first code that runs inside the Trust Domain. It controls what gets measured into RTMR[1] and RTMR[2]. A malicious OVMF could:

1. Measure the legitimate kernel hash into RTMR[1]
2. Actually boot a different kernel (one that disables dm-verity)
3. The TDX CPU faithfully records whatever OVMF measured — it doesn't verify honesty

MRTD is the only register the OVMF cannot fake. It's computed by the TDX CPU *before* OVMF executes, based on the OVMF binary itself. Checking MRTD proves which firmware was used.

### Who Can Exploit This

| Runner environment | Custom OVMF possible? | MRTD check needed? |
|---|---|---|
| Cloud provider (GCP, Azure) | No — provider controls firmware | Defensive (verifies provider identity) |
| Bare metal (runner owns hardware) | **Yes — trivially** | **Essential** |

Intel does NOT approve or sign OVMF binaries. Any OVMF works with TDX. On bare metal, a runner can compile a malicious OVMF in minutes. Without MRTD verification, all downstream measurements (RTMR[1..2]) become meaningless.

### Our Choice: Security First

The DstackVerifier checks MRTD from launch. The bare-metal OVMF attack is real and practical. Starting secure and relaxing later is safer than starting permissive.

**The relaxation path:** When the owner is ready to freeze the contract, they can deploy an additional verifier that only checks RTMR[1..2] and register it alongside DstackVerifier. This is a deliberate, visible transition.

## Trust Model

### What You Must Trust

| Component | Why | Risk |
|-----------|-----|------|
| **Intel TDX CPU** | Generates unforgeable measurements + quotes | A hardware bug could allow forged quotes. Mitigated by Intel's TCB update process. |
| **Google's OVMF** (MRTD) | First code in the trust domain; controls RTMR measurements | Google could ship a malicious OVMF. Mitigated by Google's reputation + many projects depending on it. |
| **Linux kernel dm-verity** | Enforces rootfs and model partition immutability | A kernel bug bypassing dm-verity would break the model. dm-verity is battle-tested (Android Verified Boot, ChromeOS). |
| **Automata DCAP** | On-chain quote signature verification | A bug could accept forged quotes. Audited, used across the ecosystem. |
| **Contract owner** (until frozen) | Registers platform keys | Could register a malicious image. Mitigated by freezing permissions after initial setup. |

### What You Do NOT Need to Trust

| Component | Why Not |
|-----------|---------|
| **The runner** | Cannot modify dm-verity rootfs or model. Cannot fake MRTD. Cannot produce valid REPORTDATA for fabricated outputs. Cannot manipulate the prompt (built inside TEE from hash-verified data). |
| **GCP's host OS** | TDX hardware isolates the VM from the hypervisor. |
| **Other runners** | Each epoch's input hash is committed on-chain before execution. |
| **The network** | No network listeners. REPORTDATA binds inputs to outputs. |
| **Donor message authors** | Messages are datamarked (spotlighted) to prevent prompt injection. |

## Auction Economics

### Why Runners Can't Cheat

| Attack | Why It Fails |
|--------|-------------|
| **Submit fabricated output** | REPORTDATA won't match — wrong sha256(inputHash, outputHash) |
| **Use a different model** | Model SHA-256 check fails at boot; dm-verity prevents swapping the hash check code |
| **Modify enclave code** | dm-verity prevents any rootfs modification; RTMR[2] changes, platform key fails |
| **Re-roll inference** | Seed from block.prevrandao committed before execution; runner can't influence it |
| **Manipulate the prompt** | Prompt built inside TEE from hash-verified epoch_state; no free-text input from runner |
| **Cherry-pick favorable epoch** | Must bid bond before seeing the epoch state; winner determined before input hash is set |
| **Refuse to submit** | Bond forfeited; economically irrational unless potential loss exceeds bond |
| **Use malicious firmware** | MRTD check fails (different firmware = different MRTD = different platform key) |
| **Grief other runners** | Pull-based bond refunds; no runner can block closeReveal() by reverting |
| **Sandwich DeFi swaps** | Chainlink oracle slippage protection on all Uniswap swaps (3% tolerance) |

### Bond Economics

- Bond = 20% of bid amount
- Winner's bond is returned (pull-based) on successful submission
- Non-winners' bonds are returned (pull-based) if they revealed their bids
- Non-revealers lose their bond (punishment for wasting auction slots)
- Winner who doesn't submit: bond forfeited to treasury

## What Attestation Does NOT Prove

- **That the inference is "correct"** — a different random seed produces different reasoning. Attestation proves the approved code ran, not that the output is optimal.
- **That the runner is honest about timing** — a runner could delay submission within the execution window. The contract enforces timing via the auction mechanism.
- **That the model is "good"** — the model hash is pinned, but whether DeepSeek R1 70B makes wise decisions is a separate question. Model selection was done via a 75-epoch gauntlet.
- **That the runner didn't see the output before submitting** — the runner receives the action and reasoning from the enclave serial console. They could choose not to submit (forfeit bond). Deterministic inference + committed seed means they can't re-roll.

## Summary: What Each Layer Prevents

| Layer | What It Prevents | Mechanism |
|-------|-----------------|-----------|
| **MRTD** (firmware) | Malicious OVMF that lies about kernel/rootfs | TDX CPU measures firmware before it executes |
| **RTMR[1]** (bootloader) | Modified GRUB that boots wrong kernel | Firmware measures bootloader |
| **RTMR[2]** (kernel + dm-verity hashes) | Modified kernel, disabled dm-verity, tampered rootfs or model | Bootloader measures kernel; cmdline pins both dm-verity hashes |
| **dm-verity** (rootfs + model integrity) | Runtime code or model modification | Kernel verifies every block read against Merkle tree |
| **Model SHA-256** (defense in depth) | Wrong model weights (belt-and-suspenders) | Enclave code verifies at startup, even though dm-verity already covers it |
| **Hash-verified prompt** | Manipulated prompt from compromised runner | TEE builds prompt from hash-verified data; no runner-supplied free text |
| **Datamarking** | Prompt injection via donor messages | Untrusted text tokenically separated from instructions |
| **REPORTDATA** | Tampered inputs, fabricated outputs | sha256(inputHash || outputHash) bound into TDX quote |
| **Deterministic seed** | Cherry-picked inference | block.prevrandao captured after bids committed |
| **Automata DCAP** | Forged TDX quotes | On-chain Intel certificate chain verification |
| **Pull-based refunds** | Auction griefing via reverting contracts | Bonds credited, not pushed; claimBond() to withdraw |
| **Swap slippage protection** | MEV sandwich attacks on DeFi operations | Chainlink oracle-derived minimum output amounts |
| **Bond forfeiture** | Non-submission after winning | Economic penalty for failing to deliver |
| **Committer cap** | Gas-limit DoS on closeReveal() | MAX_COMMITTERS = 50 enforced at commit time |
| **Reentrancy guards** | Reentrancy attacks on donate/submit/forfeit | OpenZeppelin nonReentrant on all ETH-transferring functions |

## References

- [Intel TDX specification](https://www.intel.com/content/www/us/en/developer/tools/trust-domain-extensions/documentation.html)
- [Automata DCAP documentation](https://docs.ata.network/)
- [GCP Confidential VM documentation](https://cloud.google.com/confidential-computing/confidential-vm/docs/supported-configurations)
- [dm-verity kernel documentation](https://docs.kernel.org/admin-guide/device-mapper/verity.html)
- [configfs-tsm kernel documentation](https://docs.kernel.org/security/tsm.html)
- [Spotlighting: Defending Against Indirect Prompt Injection (Hines et al. 2024)](https://arxiv.org/abs/2403.14720)
- [llama.cpp](https://github.com/ggml-org/llama.cpp)
