# dm-verity TEE Architecture

How Costanza runs AI inference on a fully immutable rootfs inside a GCP TDX Confidential VM, with no Docker, no SSH in production, and every byte of code verified by dm-verity.

For the security properties this architecture provides (what's verified, what's trusted, what the risks are), see [SECURITY_MODEL.md](SECURITY_MODEL.md). This document covers the boot flow, disk layout, build process, and enclave I/O — the operational details of how the enclave image is assembled and runs.

## Overview

The entire root filesystem is a squashfs image protected by dm-verity. The kernel verifies every block read against a Merkle hash tree. Even root cannot modify any file — the kernel returns I/O errors for tampered blocks. The enclave program (Python + llama-server) runs directly from this rootfs. There is no Docker, no container runtime, no overlay filesystem on the code paths.

We got rid of Docker because Docker manages a lot of state by writing to the filesystem — layers, mounts, temp files, the daemon socket. We wanted to lock down the filesystem completely. With dm-verity on a squashfs rootfs, there is nothing to write to. The kernel command line includes `humanfund.rootfs_hash=<dm-verity-root-hash>`, and GRUB measures the entire command line into RTMR[2]. This means changing any file on the rootfs changes the squashfs, which changes the dm-verity hash, which changes the kernel command line, which changes RTMR[2], which fails on-chain verification. No Docker layer, no overlay — just a single hash chain from hardware to code.

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
Partition 5:  humanfund-models   (~39GB)  -- squashfs of model weights
Partition 6:  humanfund-models-verity     -- dm-verity Merkle tree for models
```

Partitions 14, 15, 16 use the same numbering as the Ubuntu GCP base image (for GRUB compatibility). Partitions 3-6 are custom.

Partition labels (`humanfund-rootfs`, `humanfund-rootfs-verity`, etc.) are used by the initramfs to find partitions at boot via `/dev/disk/by-partlabel/`.

## Build Process

### Two-Phase Build

**Phase 1: Base image (slow, ~15 min, done once)**

`prover/scripts/gcp/build_base_image.sh` creates the base GCP image (`humanfund-base-gpu-llama-b5270`):
- Starts from Ubuntu 24.04 LTS TDX-capable GCP image
- Installs NVIDIA 580-open drivers + CUDA runtime
- Builds llama-server (llama.cpp b5270) with CUDA support
- Creates Python venv at `/opt/humanfund/venv/`
- Downloads model weights (42.5 GB) to `/models/model.gguf`
- Result: a standard GCP image used as a build cache

Rebuild when llama.cpp, NVIDIA drivers, CUDA, Ubuntu, or model changes.

**Phase 2: Production image (~30-40 min, iterative)**

`prover/scripts/gcp/build_full_dmverity_image.sh` creates the dm-verity sealed image (e.g., `humanfund-dmverity-gpu-v6`):
1. Creates a TDX builder VM from the base image
2. Attaches a blank output disk and staging disk
3. Uploads enclave code (`prover/enclave/`) and system prompt to the VM
4. Installs systemd services (enclave, DHCP, SSH key injection, GPU CC mode)
5. Runs `vm_build_all.sh` via nohup on the VM (survives SSH timeouts), which builds model squashfs+verity from the model weights already on the base image
6. Polls for completion (checks `/mnt/staging/build_status`)
7. Creates GCP image from the output disk

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
| `prover/scripts/gcp/build_base_image.sh` | Local (gcloud) | Creates GCP base image with NVIDIA + CUDA + llama-server + model |
| `prover/scripts/gcp/build_full_dmverity_image.sh` | Local (gcloud) | Orchestrates the full dm-verity build: creates VM, uploads code, runs build, creates image |
| `prover/scripts/gcp/vm_build_all.sh` | On the VM (via nohup) | Does the actual work: squashfs, verity, initramfs, partition, GRUB |
| `prover/scripts/gcp/vm_install.sh` | On the VM | Installs dependencies for the base image build |

## Enclave I/O

The enclave is a one-shot program (`prover/enclave/enclave_runner.py`). It runs once, produces a result, and exits. There is no Flask server, no HTTP listener, no Docker.

### Input

The prover passes epoch state (treasury balance, nonprofit list, epoch history, randomness seed) to the enclave via one of:
1. **GCP instance metadata** (production): set as `epoch-state` attribute when creating the VM
2. **File at `/input/epoch_state.json`** (portable): written to the tmpfs input dir
3. **stdin** (development): piped in locally

The system prompt is NOT passed via metadata. It lives at `/opt/humanfund/system_prompt.txt` on the dm-verity rootfs and cannot be modified by the prover.

### Output

The enclave writes its result (action, reasoning, attestation quote) to all available channels:
1. **File at `/output/result.json`** (portable)
2. **Serial console** (`/dev/ttyS0`): the result JSON is written between delimiters (`===HUMANFUND_OUTPUT_START===` and `===HUMANFUND_OUTPUT_END===`)
3. **stdout** (development)

In production, the prover reads the serial console via `gcloud compute instances get-serial-port-output`. No SSH tunnel, no network listener, no open ports.

## Model Weights

The 42.5 GB model file (DeepSeek R1 Distill Llama 70B Q4_K_M) lives on a separate dm-verity partition:

```
Partition 5: humanfund-models      -- squashfs containing /models/model.gguf
Partition 6: humanfund-models-verity -- dm-verity Merkle tree
```

The models dm-verity root hash is passed in the kernel command line as `humanfund.models_hash=<hash>`, which is measured into RTMR[2] by GRUB. The initramfs sets up dm-verity for the models partition and mounts it read-only at `/models`.

Additionally, the enclave code contains a pinned `MODEL_SHA256` constant (`prover/enclave/model_config.py`) and verifies the model file hash at startup. This is defense-in-depth: dm-verity already prevents modification, but the explicit check provides a clear error message if the wrong model is somehow present.

The model squashfs uses deterministic flags (`-mkfs-time 0 -all-time 0 -no-xattrs`) and the verity uses a fixed all-zero salt, so the same model always produces the same hash regardless of when or where it's built.

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
| `/input` | 1M | Epoch state JSON from prover |
| `/output` | 10M | Result JSON from enclave |
| `/home/<user>/.ssh` | 1M | SSH key injection (testing only) |
| `/etc` | overlay | Lower=dm-verity, upper=tmpfs. Runtime config changes (lost on reboot) |

Code paths are NOT writable:
- `/opt/humanfund/` (enclave code, system prompt) — on dm-verity squashfs
- `/usr/bin/`, `/usr/lib/` (system binaries) — on dm-verity squashfs
- `/models/` — on separate dm-verity squashfs
- `/boot/` — not mounted at runtime (no tmpfs overlay)

## Comparison with Docker+Flask-based Architecture

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
