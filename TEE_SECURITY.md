# TEE Security: Realizing $\mathcal{F}_{\text{TEE}}$ with TDX and dm-verity

This document describes the concrete construction that realizes the ideal trusted execution functionality $\mathcal{F}_{\text{TEE}}$ assumed by the [Security Model](SECURITY_MODEL.md). It covers the TDX trust model, the measurement chain, the dm-verity filesystem integrity mechanism, and the enclave's I/O architecture. It also serves as the operational reference for the disk image build process and boot flow.

The [Security Model](SECURITY_MODEL.md) proves that the system is secure given a black-box $\mathcal{F}_{\text{TEE}}$ with three properties: execution fidelity, attestation unforgeability, and input/output binding. This document argues that the Intel TDX + dm-verity + Automata DCAP construction satisfies all three.

---

## 1. Requirements Recap

$\mathcal{F}_{\text{TEE}}$ must provide:

1. **Execution fidelity.** On input $(\mathsf{codeId}, \textit{input}, \textit{seed})$, the output is the genuine result of running the identified code on those inputs. No external software can alter the computation.

2. **Attestation unforgeability.** No adversary who controls the prover's software stack — but not the TEE hardware — can produce a valid attestation $\pi$ for an execution that did not occur.

3. **Input/output binding.** The attestation cryptographically binds the execution to specific inputs and outputs via REPORTDATA, a 64-byte field in the TDX quote that the enclave sets to an application-defined value.

---

## 2. The TDX Trust Model

### 2.1 What TDX Provides

Intel Trust Domain Extensions (TDX) is a hardware-based confidential computing technology. A TDX *Trust Domain* (TD) is a VM whose memory is encrypted and integrity-protected by the CPU. The key primitives relevant to $\mathcal{F}_{\text{TEE}}$:

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

### 2.2 Threat Model

**The adversary controls:** The entire software stack of the prover's machine — the host OS, the VMM, the VM's disk images, network, and all I/O channels. The adversary can build custom firmware, boot arbitrary kernels, and modify any file.

**The adversary does NOT control:** The TDX CPU microcode, the Intel attestation key hierarchy, or the MRTD measurement process. These are hardware-rooted and assumed trustworthy under assumption A1.

**What this means in practice:** The adversary can run whatever code they want inside a TD. But they cannot produce a TDX quote whose measurements match the registered platform key unless the TD actually booted the registered firmware → bootloader → kernel → rootfs. The TDX CPU measures the firmware into MRTD *before* the firmware executes — this is the anchor of the entire chain.

### 2.3 Why MRTD Verification Is Essential

OVMF (the virtual firmware) is the first code that runs inside the TD. It controls what gets measured into RTMR[1] and RTMR[2]. A malicious OVMF could:

1. Load the legitimate GRUB and kernel.
2. Measure the *correct* hashes into RTMR[1] and RTMR[2].
3. But also load *additional* code that modifies the rootfs after measurement.

The TDX CPU records whatever OVMF measures into the RTMRs — it does not verify honesty. This is by design: the CPU measures firmware, and firmware measures everything else.

MRTD is the countermeasure. It is computed by the TDX CPU *before* OVMF executes, based on the OVMF binary itself. It is the only register that firmware cannot fake. Including MRTD in the platform key ensures that only the *approved* firmware ran — and if the approved firmware is honest (Google's OVMF), then the downstream RTMR measurements are trustworthy.

On GCP, OVMF is provided by Google and its MRTD is deterministic for a given OVMF version. On bare metal (where a prover owns the hardware), compiling a malicious OVMF is trivial — without MRTD verification, all downstream measurements become meaningless.

---

## 3. The Measurement Chain

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

### 3.1 The Platform Key

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

**The key invariant:** Changing any file on the rootfs or model partition changes the squashfs image → changes the dm-verity root hash → changes the kernel command line → changes RTMR[2] → changes the platform key → fails the on-chain check.

### 3.2 Why RTMR[3] Is Unused

In a Docker-based architecture, RTMR[3] would measure the container image digest (an "app key" separate from the "platform key"). Our construction doesn't use Docker — all code lives on the dm-verity rootfs, which is already covered by RTMR[2]. Using RTMR[3] would be redundant and would add a measurement step with no additional security benefit.

### 3.3 Per-Epoch Verification Flow

When a prover submits an auction result, the `TdxVerifier` contract performs three checks:

**Step 1: DCAP Quote Verification** (~10–12M gas). The contract calls the [Automata DCAP verifier](https://docs.ata.network/) at `0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F` to confirm:
- The TDX quote is genuine (Intel certificate chain, valid signature).
- The TCB (Trusted Computing Base) level is acceptable.
- The quote has not been tampered with.

The verifier returns the decoded quote body containing all measurement registers and REPORTDATA.

**Step 2: Platform Key Check.** The contract extracts MRTD, RTMR[1], and RTMR[2] from the decoded quote, computes $\textit{platformKey} = \text{SHA256}(\text{MRTD} \;\|\; \text{RTMR}[1] \;\|\; \text{RTMR}[2])$, and checks it against the approved registry.

**Step 3: REPORTDATA Binding.** The contract computes the expected REPORTDATA from on-chain data (see Section 4) and verifies it matches the REPORTDATA extracted from the quote.

All three checks must pass, or the submission reverts.

---

## 4. REPORTDATA: Input/Output Binding

REPORTDATA is the mechanism by which the attestation binds a specific execution to specific inputs and outputs. The enclave sets it; the contract verifies it.

### 4.1 Construction

$$\textit{inputHash} = \text{Keccak256}(\textit{baseInputHash} \;\|\; \textit{seed})$$

where $\textit{baseInputHash}$ covers all epoch state (treasury, nonprofits, investments, worldview, messages, history) and $\textit{seed}$ = `block.prevrandao` captured at the REVEAL → EXECUTION transition.

$$\textit{outputHash} = \text{Keccak256}\!\big(\text{SHA256}(\textit{action}) \;\|\; \text{SHA256}(\textit{reasoning})\big)$$

$$\text{REPORTDATA}_{[0:32]} = \text{SHA256}(\textit{inputHash} \;\|\; \textit{outputHash})$$

$$\text{REPORTDATA}_{[32:64]} = 0$$

### 4.2 Enclave-Side Computation

The enclave (running inside the TD on the dm-verity rootfs) performs these steps:

1. **Receive epoch state** from the prover via GCP instance metadata.
2. **Independently recompute** $\textit{inputHash}'$ from the provided state, using the same hash construction as the contract.
3. **Verify display data** — recompute sub-hashes from expanded text and check against committed hashes (see Section 4.3).
4. **Run inference** with the committed seed, producing $(\textit{action}, \textit{reasoning})$.
5. **Compute** $\textit{outputHash}$ and $\text{REPORTDATA}$ as above.
6. **Request TDX quote** via `configfs-tsm` with the computed REPORTDATA.
7. **Emit** $(\textit{action}, \textit{reasoning}, \textit{quote})$ to serial console.

### 4.3 Display Data Verification

The input hash commits to several opaque sub-hashes: investment positions, worldview policies, donor messages, and epoch history. Since the enclave has no direct chain access, the prover must provide both the hash values and the expanded human-readable data that the model will see.

The enclave independently recomputes each sub-hash from the display data and verifies it matches the committed value:

| Field | Hash Construction | Verification |
|-------|-------------------|-------------|
| Investment positions | `abi.encodePacked` over protocol details array (mirrors `InvestmentManager.stateHash()`) | Recompute from protocol details, compare to committed `investmentHash` |
| Worldview policies | `abi.encode` over 8 policy slots (mirrors `WorldView.stateHash()`) | Recompute from policy text array, compare to committed `worldviewHash` |
| Donor messages | Per-message `keccak256(abi.encodePacked(sender, amount, text))` | Recompute each hash, compare to committed message hash array |
| Epoch history | Rolling chain: $h_k = \text{Keccak256}(h_{k-1} \;\|\; \text{Keccak256}(\textit{reasoning}_k))$ | Replay the chain, compare final hash to committed `historyHash` |

If any sub-hash does not match, the enclave refuses to proceed. This prevents a prover from showing the model fabricated text (e.g., fake donor messages, altered worldview policies) while the top-level input hash still checks out.

**Security argument.** Substituting display text $\textit{text}^*$ for the real $\textit{text}$ while preserving $H(\textit{text}^*) = H(\textit{text})$ requires finding a preimage collision, which contradicts assumption A2.

### 4.4 Contract-Side Verification

The contract computes the expected REPORTDATA:

1. Retrieve the committed $\textit{inputHash}$ for the current epoch.
2. Compute $\textit{outputHash}^*$ from the submitted $(\textit{action}^*, \textit{reasoning}^*)$.
3. Compute $\textit{expected} = \text{SHA256}(\textit{inputHash} \;\|\; \textit{outputHash}^*)$.
4. Compare $\textit{expected}$ against the REPORTDATA extracted from the DCAP-verified quote.

If the prover tampers with the output after attestation — submitting $(\textit{action}^*, \textit{reasoning}^*)$ different from what the enclave produced — the hashes diverge and the submission is rejected (Theorem 2 in the [Security Model](SECURITY_MODEL.md)).

---

## 5. dm-verity: Filesystem Integrity

dm-verity is a Linux kernel feature that provides transparent integrity checking of block devices using a Merkle hash tree. It is the mechanism by which RTMR[2] (a single 48-byte measurement) transitively covers every byte of the rootfs and model partitions.

### 5.1 How dm-verity Works

A dm-verity device has two components:
- **Data partition**: The actual filesystem (squashfs in our case), read-only.
- **Hash partition**: A Merkle tree of SHA-256 hashes over the data blocks.

The root hash of the Merkle tree is the dm-verity root hash. It is embedded in the kernel command line as `humanfund.rootfs_hash=<hash>`. At runtime, the kernel verifies every block read against the hash tree. If any block has been modified, the kernel returns an I/O error — the tampered data is never seen by userspace.

**Why this matters for $\mathcal{F}_{\text{TEE}}$:** dm-verity ensures that the code the enclave *actually executes at runtime* matches what was measured at boot time. Without dm-verity, an attacker with root access could:

1. Boot with the correct kernel (RTMR[2] checks out at boot).
2. Modify code on disk after boot but before the enclave runs.
3. The enclave would execute tampered code, but RTMR[2] would still reflect the original measurement.

With dm-verity, step 2 is impossible: any modified block returns an I/O error from the kernel. The filesystem is cryptographically frozen at the root hash embedded in the kernel command line.

### 5.2 Squashfs: The Read-Only Filesystem

The rootfs is a squashfs image — a compressed, read-only filesystem format. Squashfs is ideal for this use case because:

- It is inherently read-only (no journaling, no write paths).
- It compresses well (~5.4 GB for the full rootfs).
- It supports deterministic builds with fixed timestamps.

The model weights live on a separate squashfs partition with its own dm-verity hash tree, allowing the rootfs and model to be updated independently.

### 5.3 Writable Paths

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

The `/etc` overlay deserves attention: it uses an overlayfs with the dm-verity rootfs as the lower layer and a tmpfs as the upper layer. This allows runtime configuration changes (e.g., DHCP-assigned hostname) without modifying the dm-verity filesystem. Changes are RAM-only and lost on reboot. The enclave code does not read any security-relevant configuration from `/etc`.

---

## 6. Boot Flow

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

---

## 7. Disk Layout

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

---

## 8. Build Process and Reproducibility

Build reproducibility matters for the security argument: anyone should be able to verify that a registered platform key corresponds to a specific set of source code and model weights. The build is designed to be deterministic where possible.

### 8.1 Two-Phase Build

**Phase 1: Base image** (slow, ~15 min, done once)

`prover/scripts/gcp/build_base_image.sh` creates a base GCP image containing:
- Ubuntu 24.04 LTS (TDX-capable GCP image)
- NVIDIA 580-open drivers + CUDA runtime
- llama-server (llama.cpp b5270, built with CUDA support)
- Python venv at `/opt/humanfund/venv/`
- Model weights (42.5 GB GGUF) at `/models/model.gguf`

Rebuild when llama.cpp, NVIDIA drivers, CUDA, Ubuntu, or model changes.

**Phase 2: Production dm-verity image** (~30–40 min, iterative)

`prover/scripts/gcp/build_full_dmverity_image.sh` creates the sealed image:

1. Creates a TDX builder VM from the base image.
2. Attaches a blank output disk and staging disk.
3. Uploads enclave code (`prover/enclave/`) and system prompt.
4. Installs systemd services (enclave, DHCP, GPU CC mode).
5. Runs `vm_build_all.sh` on the VM, which:
   - Creates squashfs of the rootfs (excluding `/proc`, `/sys`, `/dev`, `/boot`, `/models`, `/mnt`)
   - Computes dm-verity hash tree
   - Creates initramfs with dm-verity hooks
   - Partitions the output disk
   - Copies boot partitions from the boot disk
   - Writes squashfs + verity to output disk
   - Updates GRUB config with dm-verity root hash in kernel command line
   - Verifies dm-verity integrity
6. Creates GCP image from the output disk.

### 8.2 The Two-Disk Approach

The sealed partitions are written to a **separate output disk**, not the boot disk. This avoids the corruption problem where sealing a live rootfs in-place can produce inconsistent squashfs (ext4 cache writes between squashfs creation and verity hash computation). The builder VM's root filesystem stays intact while the output disk is assembled.

### 8.3 Deterministic Build Properties

- **Squashfs**: Built with `-mkfs-time 0 -all-time 0 -no-xattrs` — fixed timestamps, no extended attributes. The same filesystem contents always produce the same squashfs image.
- **dm-verity**: Uses a fixed all-zero salt (`--salt` all zeros). The same squashfs always produces the same dm-verity root hash.
- **Model weights**: The GGUF file has a pinned SHA-256 hash in `prover/enclave/model_config.py`. The enclave verifies this at startup (defense in depth — dm-verity already prevents modification).

These properties mean that given the same source code, model weights, and base image, the build produces the same platform key. An auditor can reproduce the build and verify that the registered key matches.

### 8.4 Build Scripts Reference

| Script | Runs On | Purpose |
|--------|---------|---------|
| `prover/scripts/gcp/build_base_image.sh` | Local (gcloud) | Build GCP base image with NVIDIA + CUDA + llama-server + model |
| `prover/scripts/gcp/build_full_dmverity_image.sh` | Local (gcloud) | Orchestrate full dm-verity build: create VM, upload code, run build, create image |
| `prover/scripts/gcp/vm_build_all.sh` | On the VM | Do the actual work: squashfs, verity, initramfs, partition, GRUB |
| `prover/scripts/gcp/vm_install.sh` | On the VM | Install dependencies for base image build |
| `prover/scripts/gcp/register_image.py` | Local | Register platform key on-chain after build |
| `prover/scripts/gcp/verify_measurements.py` | Local | Verify RTMR values match registered key |

---

## 9. Enclave I/O and Attack Surface

The enclave is a one-shot program (`prover/enclave/enclave_runner.py`). It runs once, produces a result, and exits. There is no persistent server, no HTTP listener, no interactive shell.

### 9.1 Input Channel

The prover passes epoch state to the enclave via one of:

1. **GCP instance metadata** (production): Set as `epoch-state` attribute at VM creation time. Read-only to the VM after boot.
2. **File at `/input/epoch_state.json`** (portable): Written to the tmpfs input directory.
3. **stdin** (development): Piped in locally.

The system prompt is NOT passed via metadata. It lives at `/opt/humanfund/system_prompt.txt` on the dm-verity rootfs. The prover cannot modify it.

### 9.2 Output Channel

The enclave writes its result to:

1. **Serial console** (`/dev/ttyS0`): The result JSON is written between delimiters (`===HUMANFUND_OUTPUT_START===` and `===HUMANFUND_OUTPUT_END===`). In production, the prover reads this via `gcloud compute instances get-serial-port-output`.
2. **File at `/output/result.json`** (portable).
3. **stdout** (development).

No SSH tunnel, no network listener, no open ports.

### 9.3 Attack Surface Analysis

The prover's only influence on the enclave is the initial epoch state (provided via metadata or input file). After boot:

- **No interactive communication**: The prover cannot send commands to the running enclave. There is no SSH, no network listener, no control channel.
- **No code modification**: All code paths are on dm-verity. Any attempt to modify code returns I/O errors.
- **No prompt modification**: The system prompt is on dm-verity. The prover cannot substitute a different prompt.
- **No model modification**: Model weights are on a separate dm-verity partition. The enclave also verifies the model's SHA-256 hash at startup.
- **Input is hash-verified**: The enclave independently recomputes the input hash and includes it in REPORTDATA. Fabricated inputs produce a different hash, which fails the contract's check.

The remaining attack surface is:

1. **Providing fabricated epoch state**: Detected by input binding (Property 3 in the Security Model).
2. **Choosing not to submit the result**: Allowed, but costs the prover their bond. Analyzed as *selective submission* in [SECURITY_MODEL.md](SECURITY_MODEL.md), Property 7.
3. **Re-running the enclave**: Under A11 (deterministic inference), re-running produces the same output. Without A11, the prover could collect multiple valid outputs and select among them — each with a genuine attestation. The dm-verity image pins the inference binary, model, sampling parameters, and GPU architecture to ensure determinism.
4. **Timing manipulation**: The prover can delay submission within the execution window. Bounded by the window duration.
5. **Side channels**: Theoretical TDX side-channel attacks (assumption A1). See Section 10.

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

TDX is Intel-only. AMD SEV-SNP and ARM CCA provide comparable confidential computing guarantees but have different measurement architectures. Supporting multiple TEE vendors would require:

- Separate platform key registries per vendor.
- Vendor-specific attestation verification contracts.
- Separate enclave builds (different rootfs per architecture).

The `IProofVerifier` interface supports this — multiple verifiers can be registered.

### 10.5 GCP-Specific Dependencies

The current construction relies on GCP for:

- TDX-capable Confidential VMs.
- Instance metadata as the input channel.
- Serial console as the output channel.

None of these are fundamental. The enclave supports file-based I/O (`/input` and `/output` directories), and the dm-verity image could be booted on bare-metal TDX hardware. The platform key would change (different OVMF firmware), requiring a new registration.

### 10.6 Model Weights Distribution

The 42.5 GB model file is baked into the disk image during Phase 1 of the build. Any prover who wants to participate needs access to this image (or the ability to build it from the same model weights). The model's SHA-256 hash is pinned in source code (`prover/enclave/model_config.py`), so anyone can verify they have the correct weights.

---

### 10.7 Output Length Bounds

The enclave's output (action + reasoning) must be submitted as calldata to the L2 contract. The output length is bounded by the llama.cpp context window (`-c 4096` tokens), which limits the model's total output to approximately 16 KB. This is well within Base L2's block gas limits. The enclave enforces this bound via the context window configuration, which is baked into the dm-verity image and cannot be changed by the prover.

---

## 11. Summary: Argument That This Construction Realizes $\mathcal{F}_{\text{TEE}}$

| $\mathcal{F}_{\text{TEE}}$ Requirement | How It Is Achieved |
|---|---|
| **Execution fidelity** | dm-verity ensures runtime code matches boot-time measurements. RTMR[2] covers the kernel command line, which includes the dm-verity root hashes, which transitively cover every byte of the rootfs and model partitions. MRTD anchors the chain in hardware, preventing firmware from faking downstream measurements. |
| **Attestation unforgeability** | TDX quotes are signed by Intel's attestation key hierarchy (DCAP). The Automata DCAP verifier confirms the certificate chain on-chain. Forging a quote requires compromising the TDX CPU or Intel's key infrastructure — assumption A1. |
| **Input/output binding** | REPORTDATA = SHA256(inputHash ‖ outputHash). The enclave independently computes inputHash from prover-provided state and includes it in the quote. The contract independently computes the expected REPORTDATA from committed inputHash and submitted output. Mismatch → rejection. Display data verification closes the sub-hash gap. |

Under assumption A1 (TDX hardware integrity) and A2 (collision resistance of SHA-256 and Keccak-256), this construction realizes $\mathcal{F}_{\text{TEE}}$ as required by the [Security Model](SECURITY_MODEL.md).
