# dm-verity TEE Architecture

How The Human Fund runs AI inference on a fully immutable rootfs inside a GCP TDX Confidential VM, with no Docker, no SSH in production, and every byte of code verified by dm-verity.

## Overview

The entire root filesystem is a squashfs image protected by dm-verity. The kernel verifies every block read against a Merkle hash tree. Even root cannot modify any file -- the kernel returns I/O errors for tampered blocks. The enclave program (Python + llama-server) runs directly from this rootfs. There is no Docker, no container runtime, no overlay filesystem on the code paths.

**Key properties:**
- Full dm-verity rootfs on GCP TDX Confidential VMs
- No Docker -- direct execution from immutable squashfs
- No SSH in production -- input via GCP metadata, output via serial console
- Model weights on a separate dm-verity partition
- 15.3s inference on H100 with DeepSeek R1 70B Q4_K_M
- E2E verified with real TDX DCAP attestation on Base Sepolia

## Security Model

### Platform Key: MRTD + RTMR[1] + RTMR[2]

The on-chain platform key is `sha256(MRTD || RTMR[1] || RTMR[2])` -- 144 bytes hashed. This covers:

| Register | What It Measures | What It Protects |
|----------|-----------------|------------------|
| **MRTD** | Google's OVMF firmware binary | Prevents malicious firmware that could lie about downstream measurements |
| **RTMR[1]** | GRUB bootloader (shim + GRUB EFI) | Prevents modified bootloader that boots wrong kernel |
| **RTMR[2]** | Kernel + full command line | Prevents modified kernel or disabled dm-verity |

The critical insight: the kernel command line includes `humanfund.rootfs_hash=<dm-verity-root-hash>` and (when present) `humanfund.models_hash=<models-dm-verity-hash>`. GRUB measures the entire command line into RTMR[2]. This means:

```
RTMR[2] <- kernel binary + command line
  command line includes: humanfund.rootfs_hash=<hash>
    dm-verity root hash covers: every byte of the squashfs rootfs
      squashfs contains: Python, llama-server, NVIDIA drivers, enclave code,
                         system prompt, systemd services -- everything
```

Changing ANY file on the rootfs changes the squashfs, which changes the dm-verity root hash, which changes the kernel command line, which changes RTMR[2], which changes the platform key, which fails on-chain verification.

### Why No RTMR[3] Is Needed

In the previous Docker-based architecture, RTMR[3] measured the Docker compose hash to verify which container image ran. With full dm-verity rootfs, there is no Docker. All code lives directly on the rootfs, which is transitively covered by RTMR[2] via the dm-verity root hash. RTMR[3] is not extended and not checked.

### What Is NOT Verified

| Register | Why It Is Skipped |
|----------|-------------------|
| **RTMR[0]** | Measures VM hardware configuration (CPU count, memory, device topology). Varies by VM size -- an `a3-highgpu-1g` (1 H100) gets a different RTMR[0] than `a3-highgpu-2g` (2 H100s). Checking it would require registering every VM size separately, with no security benefit. |
| **RTMR[3]** | Not used. No Docker, so no compose hash to measure. All code is on the dm-verity rootfs covered by RTMR[2]. |

## Boot Flow

```
1. OVMF (measured into MRTD by TDX CPU before execution)
   |
2. GRUB (measured into RTMR[1] by OVMF)
   | loads kernel with command line:
   |   humanfund.rootfs_hash=<rootfs-hash>
   |   humanfund.models_hash=<models-hash>  (when model partition present)
   |   ro console=ttyS0,115200n8
   |
3. Kernel + command line (measured into RTMR[2] by GRUB)
   | boots with initramfs containing dm-verity hooks
   |
4. Initramfs (local-premount hook: humanfund-verity)
   | Parses rootfs_hash and models_hash from /proc/cmdline
   | Runs: veritysetup open /dev/disk/by-partlabel/humanfund-rootfs \
   |         humanfund-rootfs /dev/disk/by-partlabel/humanfund-rootfs-verity <hash>
   | If models partition present:
   |   veritysetup open /dev/disk/by-partlabel/humanfund-models \
   |     humanfund-models /dev/disk/by-partlabel/humanfund-models-verity <hash>
   | Sets ROOT=/dev/mapper/humanfund-rootfs
   |
5. Initramfs (local-bottom hook: humanfund-mounts)
   | Mounts /dev/mapper/humanfund-models as /models (squashfs, read-only)
   | Creates targeted tmpfs mounts for writable dirs:
   |   /tmp, /run, /var/tmp, /var/log, /var/cache, /var/lib
   |   /input (1M), /output (10M)
   |   /home/<user>/.ssh (for SSH key injection during testing)
   | Overlays /etc (lower=dm-verity, upper=tmpfs) for runtime config
   | Bind-mounts /etc/machine-id from tmpfs
   |
6. Kernel mounts /dev/mapper/humanfund-rootfs as / (squashfs, read-only)
   |
7. systemd starts
   | humanfund-dhcp.service: DHCP via dhclient (auto-detects interface)
   | humanfund-ssh-keys.service: fetches SSH keys from GCP metadata (testing only)
   | humanfund-gpu-cc.service: nvidia-smi conf-compute -srs 1 (CC mode)
   | humanfund-enclave.service: runs one-shot enclave program
   |
8. Enclave runs (one-shot, then exits)
   | Reads epoch state from GCP metadata or /input/epoch_state.json
   | Reads system prompt from /opt/humanfund/system_prompt.txt (dm-verity)
   | Starts llama-server, runs two-pass inference
   | Generates TDX attestation quote via configfs-tsm
   | Writes result to serial console + /output/result.json
```

## Disk Layout

The output disk (which becomes the GCP image) has 6 partitions:

```
Partition 14: BIOS boot          (4MB)    -- legacy BIOS compatibility
Partition 15: EFI System         (106MB)  -- GRUB EFI, shim
Partition 16: /boot              (913MB)  -- kernel, initramfs, grub.cfg
Partition 3:  humanfund-rootfs   (~5.4GB) -- squashfs of entire root filesystem
Partition 4:  humanfund-rootfs-verity (~46MB) -- dm-verity Merkle tree for rootfs
Partition 5:  humanfund-models   (~43GB)  -- squashfs of model weights (optional)
Partition 6:  humanfund-models-verity     -- dm-verity Merkle tree for models (optional)
```

Partitions 14, 15, 16 use the same numbering as the Ubuntu GCP base image (for GRUB compatibility). Partitions 3-6 are custom.

Partition labels (`humanfund-rootfs`, `humanfund-rootfs-verity`, etc.) are used by the initramfs to find partitions at boot via `/dev/disk/by-partlabel/`.

## Build Process

### Two-Phase Build

**Phase 1: Base image (slow, ~15 min, done once)**

`scripts/build_base_image.sh` creates `humanfund-base-gpu-llama-b5270`:
- Starts from Ubuntu 24.04 LTS TDX-capable GCP image
- Installs NVIDIA 580-open drivers + CUDA runtime
- Builds llama-server (llama.cpp b5270) with CUDA support
- Creates Python venv at `/opt/humanfund/venv/`
- Downloads model weights (42.5 GB) to `/models/model.gguf`
- Verifies model SHA-256
- Result: a standard GCP image used as a build cache

Rebuild this only when llama.cpp, NVIDIA drivers, CUDA, or Ubuntu versions change.

**Phase 2: Production image (fast, ~10 min, iterative)**

`scripts/build_full_dmverity_image.sh` creates the dm-verity sealed image (e.g., `humanfund-dmverity-gpu-v6`):
1. Creates a TDX builder VM from the base image
2. Attaches two extra disks: output (for the final image) and staging (for temp files)
3. Uploads enclave code (`prover/enclave/`) and system prompt to the VM
4. Installs systemd services (enclave, DHCP, SSH key injection, GPU CC mode)
5. Optionally downloads model weights (if not in base image or `--skip-model` used)
6. Runs `vm_build_all.sh` via nohup on the VM (survives SSH timeouts)
7. Polls for completion (checks `/mnt/staging/build_status`)
8. Creates GCP image from the output disk

### Two-Disk Approach

The key insight that makes the build work: the sealed partitions are written to a **separate output disk**, not the boot disk. The builder VM's root filesystem stays intact (running Ubuntu) while the build script:

1. Creates a squashfs of the boot disk's entire rootfs (excluding `/proc`, `/sys`, `/dev`, `/boot`, `/models`, `/mnt`)
2. Computes dm-verity hash tree for the squashfs
3. Creates initramfs with dm-verity hooks
4. Partitions the output disk with the layout above
5. Copies boot partitions (14, 15, 16) from the boot disk to the output disk
6. Writes squashfs + verity data to output disk partitions 3-6
7. Updates GRUB config on the output disk with the dm-verity root hash in the kernel command line
8. Verifies dm-verity integrity of the output disk

After build, the GCP image is created from the output disk. The builder VM and its boot disk are discarded.

This avoids the corruption problem where sealing a live rootfs in-place can produce inconsistent squashfs (ext4 cache writes between squashfs creation and verity hash computation).

### Build Scripts

| Script | Where It Runs | Purpose |
|--------|--------------|---------|
| `scripts/build_base_image.sh` | Local (gcloud) | Creates GCP base image with NVIDIA + CUDA + llama-server + model |
| `scripts/build_full_dmverity_image.sh` | Local (gcloud) | Orchestrates the full dm-verity build: creates VM, uploads code, runs build, creates image |
| `scripts/vm_build_all.sh` | On the VM (via nohup) | Does the actual work: squashfs, verity, initramfs, partition, GRUB |
| `scripts/vm_install.sh` | On the VM | Installs dependencies for the base image build |
| `scripts/test_dmverity_boot.sh` | Local (gcloud) | Boots a VM from the image and verifies dm-verity, rootfs integrity, enclave |
| `scripts/seal_rootfs.sh` | On the VM | Legacy: seals rootfs in-place (superseded by two-disk approach) |

## Enclave I/O

The enclave is a one-shot program (`prover/enclave/enclave_runner.py`). It runs once, produces a result, and exits. There is no Flask server, no HTTP listener, no Docker.

### Input

The runner passes epoch state (treasury balance, nonprofit list, epoch history, randomness seed) to the enclave via one of:
1. **GCP instance metadata** (production): set as `epoch-state` attribute when creating the VM
2. **File at `/input/epoch_state.json`** (portable): written to the tmpfs input dir
3. **stdin** (development): piped in locally

The system prompt is NOT passed via metadata. It lives at `/opt/humanfund/system_prompt.txt` on the dm-verity rootfs and cannot be modified by the runner.

### Output

The enclave writes its result (action, reasoning, attestation quote) to all available channels:
1. **File at `/output/result.json`** (portable)
2. **Serial console** (`/dev/ttyS0`): the result JSON is written between delimiters (`===HUMANFUND_OUTPUT_START===` and `===HUMANFUND_OUTPUT_END===`)
3. **stdout** (development)

In production, the runner reads the serial console via `gcloud compute instances get-serial-port-output`. No SSH tunnel, no network listener, no open ports.

## Model Weights

The 42.5 GB model file (DeepSeek R1 Distill Llama 70B Q4_K_M) lives on a separate dm-verity partition:

```
Partition 5: humanfund-models      -- squashfs containing /models/model.gguf
Partition 6: humanfund-models-verity -- dm-verity Merkle tree
```

The models dm-verity root hash is passed in the kernel command line as `humanfund.models_hash=<hash>`, which is measured into RTMR[2] by GRUB. The initramfs sets up dm-verity for the models partition and mounts it read-only at `/models`.

Additionally, the enclave code contains a pinned `MODEL_SHA256` constant (`prover/enclave/model_config.py`) and verifies the model file hash at startup. This is defense-in-depth: dm-verity already prevents modification, but the explicit check provides a clear error message if the wrong model is somehow present.

A runner providing wrong model weights gets: dm-verity rejection (kernel I/O error) if the file is tampered, or SHA-256 mismatch (enclave refuses to start) if a different file is substituted on a different partition.

## Writable Paths

The rootfs is read-only. Only specific directories have tmpfs mounts (writes go to RAM, lost on reboot):

| Path | Size | Purpose |
|------|------|---------|
| `/tmp` | 256M | Standard temp |
| `/run` | 256M | systemd runtime |
| `/var/tmp` | 256M | Temporary files |
| `/var/log` | 256M | Log files |
| `/var/cache` | 256M | Package cache |
| `/var/lib` | 256M | Service state (systemd) |
| `/input` | 1M | Epoch state JSON from runner |
| `/output` | 10M | Result JSON from enclave |
| `/home/<user>/.ssh` | 1M | SSH key injection (testing only) |
| `/etc` | overlay | Lower=dm-verity, upper=tmpfs. Runtime config changes (lost on reboot) |

Code paths are NOT writable:
- `/opt/humanfund/` (enclave code, system prompt) -- on dm-verity squashfs
- `/usr/bin/`, `/usr/lib/` (system binaries) -- on dm-verity squashfs
- `/models/` -- on separate dm-verity squashfs
- `/boot/` -- not mounted at runtime (no tmpfs overlay)

## Threat Model

### Trust Assumptions

| What we trust | Why |
|---------------|-----|
| Intel TDX CPU | Hardware root of trust -- generates unforgeable attestation quotes |
| Google's OVMF firmware | Measured into MRTD -- verified via platform key on-chain |
| The Linux kernel | Measured into RTMR[1]+[2] -- verified via platform key |
| dm-verity implementation | Battle-tested (ChromeOS, Android) -- verifies every block read |
| Automata DCAP verifier | Audited on-chain signature verification for TDX quotes |

### What a Root Attacker Cannot Do

An attacker with root access inside the guest VM cannot:

1. **Modify any code or binary** -- dm-verity rejects tampered blocks at the kernel level (I/O error, not permission denied)
2. **Shadow files via overlay** -- no overlayfs on code paths. Only `/etc` has an overlay, and code does not live in `/etc`. There is no overlay layer on the root -- the squashfs is mounted directly. Only specific directories (`/tmp`, `/run`, `/var/lib`, `/home`, `/input`, `/output`) have tmpfs mounts.
3. **Replace model weights** -- separate dm-verity partition, plus SHA-256 check in immutable enclave code
4. **Modify kernel or initramfs** -- measured by GRUB into RTMR[1]+[2], changes detected on-chain. `/boot` is not writable at runtime.
5. **Fake RTMR measurements** -- RTMRs are append-only (extend), never clearable. MRTD is set by TDX CPU before firmware executes
6. **Use custom firmware** -- MRTD is part of the platform key, checked on-chain
7. **Produce valid attestation for fabricated output** -- REPORTDATA = sha256(inputHash || outputHash), bound into TDX quote
8. **Replace Docker images or modify the Docker daemon** -- there is no Docker

### What a Root Attacker CAN Do (and Why It Is OK)

1. **Write to tmpfs dirs** -- the enclave reads input from `/input` (which is the runner's job to provide) and the output is verified by REPORTDATA. An attacker writing to `/input` is equivalent to providing different epoch state (which is the runner's job -- they provide the input).
2. **Kill the enclave** -- no result submitted, runner forfeits bond on-chain. No economic benefit to the attacker.
3. **Read model weights** -- the model is public (GGUF download from HuggingFace)
4. **Read enclave memory via `/proc`** -- TDX protects guest memory from the host, but processes inside the guest can read each other's memory. This is acceptable because the epoch state is not secret (committed on-chain), model weights are public, and reasoning is published on-chain after submission.

### Remaining Attack Surfaces

1. **Kernel exploits** -- If the attacker finds a kernel vulnerability, they could disable dm-verity at runtime. This is the same trust boundary as all of TDX -- the kernel IS the TCB.
2. **TOCTOU on `/var/lib`** -- Services write state to `/var/lib` (tmpfs). An attacker could race a write between systemd loading a service config and the service reading it. Mitigation: critical services (humanfund-enclave) don't read config from `/var/lib`.
3. **Network-based attacks** -- sshd runs on the image (for debugging). In production, masking sshd would reduce attack surface. The enclave doesn't use the network (it reads from metadata at boot and writes to serial console).

## Comparison with Previous Docker Architecture

| Aspect | Docker Architecture (v1) | dm-verity Direct (v2, current) |
|--------|-------------------------|-------------------------------|
| Code execution | Inside Docker container | Directly on rootfs |
| RTMR[3] | Docker compose hash | Not used |
| Code measurement | Via container image digest | Via dm-verity root hash in RTMR[2] |
| I/O | SSH tunnel to Flask API | GCP metadata in, serial console out |
| Network listeners | Flask on 127.0.0.1:8090 | None |
| Model location | Mounted from host into container | Separate dm-verity partition |
| Attack surface | Docker daemon + container runtime | dm-verity kernel module only |
| Build complexity | Dockerfile + compose + startup.py | squashfs + veritysetup + initramfs hooks |
| Portability | Same Docker image across platforms | Platform-specific rootfs (different base images) |
| Attestation keys | Platform key + app key (separate) | Platform key only (app key not needed) |

## Tested Performance

- **15.3s** inference on H100 (a3-highgpu-1g) with DeepSeek R1 70B Q4_K_M
- Full e2e verified: VM boot, inference, TDX quote generation, DCAP verification on-chain, REPORTDATA match
- Production image: `humanfund-dmverity-hardened-v6`
- Base image: `humanfund-base-gpu-llama-b5270` (family: `humanfund-base`)

## On-Chain Verification

The TdxVerifier contract (`src/TdxVerifier.sol`) handles attestation verification on-chain:

- **Platform key**: `sha256(MRTD || RTMR[1] || RTMR[2])` -- registered per-image, covers firmware + bootloader + dm-verity rootfs
- **REPORTDATA**: `sha256(inputHash || outputHash)` -- binds the specific input and output to the TDX quote
- **No app key needed**: dm-verity root hash in RTMR[2] transitively covers all code, so no separate RTMR[3]-based app key is required
- **RTMR[0] intentionally skipped**: VM hardware config varies by prover (different VM sizes get different RTMR[0])

See `SECURITY_MODEL.md` for the full attestation security model and threat analysis.

## Implementation Status

Fully verified:
- dm-verity rootfs boots on GCP TDX Confidential VMs (a3-highgpu-1g with H100)
- dm-verity correctly rejects tampered blocks at the kernel level
- Boot chain measurements (MRTD, RTMR[1], RTMR[2]) are consistent across rebuilds of the same code
- Two-disk build approach produces deterministic, verifiable images
- Multiple successful epochs with real TDX DCAP attestation on Base Sepolia
- H100 GPU inference at ~15s per epoch
- google-guest-agent masked in production images (was interfering with systemd-networkd DHCP)
- Serial console I/O eliminates need for SSH in production
