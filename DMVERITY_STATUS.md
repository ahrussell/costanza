# dm-verity Full Rootfs — Implementation Status

## What Was Implemented

### Architecture: Full dm-verity rootfs, no Docker, no SSH needed

The entire root filesystem is a squashfs image verified by dm-verity at the kernel level. Every binary that runs — Python, llama-server, NVIDIA drivers, systemd — is immutable. The enclave runs directly from the rootfs (no Docker containers, no overlays).

**Input:** Epoch state via GCP instance metadata (or file at `/input/epoch_state.json`)
**Output:** Result via serial console (`/dev/ttyS0`) (or file at `/output/result.json`)

### Key Scripts

| Script | Purpose |
|--------|---------|
| `scripts/build_base_image.sh` | Creates GCP base image with NVIDIA + CUDA + llama-server + Python venv (slow, ~15min, done once) |
| `scripts/build_full_dmverity_image.sh` | Creates production dm-verity image from base (~10min, uses nohup + two-disk approach) |
| `scripts/vm_build_all.sh` | Runs on the VM via nohup: creates squashfs, verity, partitions output disk, copies boot, updates GRUB |
| `scripts/test_dmverity_boot.sh` | Boots a VM from the image and verifies dm-verity, rootfs, SSH, enclave |

### Two-Disk Build Approach

The key insight that makes the build work: we use a **separate output disk** for the dm-verity partitions. The builder VM's boot disk stays intact (running Ubuntu), while the sealed rootfs is written to a clean second disk. After build, we create the GCP image from the output disk, not the boot disk.

**Disk layout of the output disk:**
```
Partition 14: BIOS boot (4MB)
Partition 15: EFI System (106MB) — GRUB, shim
Partition 16: /boot (913MB) — kernel, initramfs, grub.cfg
Partition 3:  humanfund-rootfs (5.4GB) — squashfs of entire root
Partition 4:  humanfund-rootfs-verity (46MB) — dm-verity Merkle tree
Partition 5:  humanfund-models (optional) — squashfs of model weights
Partition 6:  humanfund-models-verity (optional) — dm-verity for models
```

### Boot Chain

```
1. OVMF (MRTD) loads GRUB from EFI partition
2. GRUB (RTMR[1]) loads kernel with cmdline:
   humanfund.rootfs_hash=<hash> ro console=ttyS0,115200n8
3. Kernel (RTMR[2]) boots with initramfs containing:
   - humanfund-verity premount script: runs veritysetup
   - humanfund-mounts local-bottom script: creates tmpfs mounts
4. Initramfs sets up dm-verity:
   veritysetup open /dev/disk/by-partlabel/humanfund-rootfs \
     humanfund-rootfs /dev/disk/by-partlabel/humanfund-rootfs-verity <hash>
5. Kernel mounts /dev/mapper/humanfund-rootfs as / (squashfs, read-only)
6. Initramfs creates targeted tmpfs mounts:
   /tmp, /run, /var/tmp, /var/log, /var/cache, /var/lib, /home,
   /input, /output, /etc/machine-id (bind mount)
7. systemd starts, detects TDX confidential virtualization
8. humanfund-enclave.service runs the one-shot enclave program
```

### What's Verified

The dm-verity root hash in the kernel cmdline is measured into **RTMR[2]** by GRUB. This transitively verifies EVERY file on the rootfs:

```
RTMR[2] contains kernel cmdline
  → cmdline contains rootfs_hash=<hash>
    → hash is root of Merkle tree over 1M+ data blocks
      → every 4KB block of the squashfs is verified on read
        → squashfs contains: Python, llama-server, NVIDIA, enclave code, systemd
```

An attacker with root access CANNOT:
- Modify any file on the rootfs (dm-verity blocks it at the kernel level)
- Shadow files via overlay (no overlay layer exists — only targeted tmpfs for specific dirs)
- Replace Docker images (no Docker)
- Modify the Docker daemon (no Docker)
- Swap the kernel or initramfs (measured by GRUB into RTMR[1]+[2])

### What's NOT Yet Working

1. **SSH access to the booted VM** — The google-guest-agent (which injects SSH keys) was interfering with `systemd-networkd` DHCP config. Last fix: masked the guest agent. Need to verify this fixes the network issue. Alternatively, SSH isn't needed in production (serial console is the I/O channel).

2. **The enclave program hasn't been tested on the dm-verity image yet** — systemd starts the service, but we haven't confirmed it runs to completion. The model is not present on the `--skip-model` test images.

3. **RTMR[3] extension** — configfs-tsm RTMR extension wasn't producing non-zero values in earlier tests. This is independent of the dm-verity rootfs work and needs debugging.

4. **GCP auth expired** — Can't interact with GCP until `gcloud auth login` is run.

### Likely Remaining Issues

- **`google-guest-agent` network interference**: The last build masks the guest agent. This should fix networking but hasn't been tested yet (auth expired before test).
- **`/etc/resolv.conf`**: May need a tmpfs bind mount for DNS resolution.
- **`systemd-resolved`**: Needs `/var/lib/systemd` which we provide via tmpfs, should work.

## Threat Model

### Trust Assumptions

| What we trust | Why |
|---------------|-----|
| Intel TDX CPU | Hardware root of trust — generates unforgeable attestation quotes |
| Google's OVMF firmware | Measured into MRTD — verified via platform key on-chain |
| The Linux kernel | Measured into RTMR[1]+[2] — verified via platform key |
| dm-verity implementation | Battle-tested (ChromeOS, Android) — verifies every block read |
| Automata DCAP verifier | Audited on-chain signature verification for TDX quotes |

### What the runner (attacker with root) CANNOT do

1. **Modify any file on the rootfs** — dm-verity rejects tampered blocks at the kernel level. Not just "permission denied" — the kernel returns I/O errors for any block that doesn't match the Merkle tree hash.

2. **Shadow files via overlay** — There is no overlayfs layer on the root. The squashfs is mounted directly. Only specific directories (`/tmp`, `/run`, `/var/lib`, `/home`, `/input`, `/output`) have tmpfs mounts. An attacker can write to these tmpfs dirs, but:
   - `/opt/humanfund/` (enclave code) is NOT on a tmpfs — it's on the read-only squashfs
   - `/usr/bin/` (system binaries) is NOT on a tmpfs
   - `/etc/systemd/` (service config) is NOT on a tmpfs

3. **Replace the model weights** — The model is on a separate dm-verity partition (when present). Additionally, the enclave code verifies the model SHA-256 at startup from a pinned constant in the immutable rootfs.

4. **Modify the kernel or initramfs** — These are on the `/boot` partition, which is NOT writable at runtime (no tmpfs overlay on `/boot`). Even if an attacker could write there, GRUB measures the kernel + cmdline into RTMR[2] — any change is detected.

5. **Fake RTMR measurements** — RTMR values can only be EXTENDED (append-only), never cleared or overwritten. And MRTD is set by the TDX module during VM creation — completely outside the guest's control.

6. **Use custom firmware** — Bare-metal attackers could use custom OVMF, but we verify MRTD as part of the platform key. Custom firmware → different MRTD → rejected by the smart contract.

### What the runner CAN do (and why it's OK)

1. **Write to tmpfs dirs** (`/tmp`, `/var/lib`, `/home`, `/input`, `/output`) — These are intentionally writable. The enclave code reads input from `/input` and writes output to `/output`. An attacker writing to `/input` is equivalent to providing different epoch state (which is the runner's job — they provide the input). The output is verified by REPORTDATA in the TDX quote.

2. **Kill the enclave process** — This just means no result is submitted. The runner forfeits their bond on-chain. No economic benefit to the attacker.

3. **Read the model weights** — The model is not confidential (it's a public GGUF download). Confidentiality of inference data (epoch state, reasoning) is protected by TDX's memory encryption in transit.

4. **Read memory via `/proc`** — TDX protects guest memory from the host, but processes INSIDE the guest can read each other's memory via `/proc/<pid>/mem`. Since the attacker has root inside the guest, they could read the enclave's memory. This is acceptable because:
   - The epoch state is not secret (it's committed on-chain before inference)
   - The model weights are public
   - The reasoning is published on-chain after submission

### Remaining Attack Surfaces

1. **Kernel exploits** — If the attacker finds a kernel vulnerability, they could disable dm-verity at runtime. This is the same trust boundary as all of TDX — the kernel IS the TCB.

2. **TOCTOU on `/var/lib`** — Services write state to `/var/lib` (tmpfs). An attacker could race a write between systemd loading a service config and the service reading it. Mitigation: critical services (humanfund-enclave) don't read config from `/var/lib`.

3. **Network-based attacks** — sshd runs on the image (for debugging). In production, masking sshd would reduce attack surface. The enclave doesn't use the network (it reads from metadata at boot and writes to serial console).

## Next Steps

1. **Fix networking** — Verify the masked google-guest-agent fixes the DHCP issue
2. **Test enclave execution** — Boot with model weights and verify inference runs
3. **Fix RTMR[3]** — Debug configfs-tsm extension
4. **Full e2e test** — Deploy contract, register image, run auction with real attestation
5. **Write RUNNER_README.md** — Instructions for 3rd parties to build and run their own TEE
