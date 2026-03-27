#!/bin/bash
# The Human Fund — Seal Root Filesystem with dm-verity
#
# This script converts a running Ubuntu system into an immutable dm-verity rootfs.
# After sealing, the entire root filesystem is read-only and kernel-verified.
# Any tampering (even with root access) causes I/O errors.
#
# What gets sealed:
#   - The entire root filesystem (/, including NVIDIA, Python, llama-server, systemd, etc.)
#   - The model weights partition (/models/)
#
# What does NOT get sealed:
#   - /boot (contains kernel + initramfs + GRUB — measured by RTMR[1]+[2])
#   - /boot/efi (EFI system partition)
#   - Pseudo-filesystems: /proc, /sys, /dev, /run, /tmp
#
# After sealing, the disk layout is:
#   Partition 1: EFI System Partition (unchanged)
#   Partition 2: /boot ext4 (contains kernel, initramfs, GRUB)
#   Partition 14: BIOS boot (GCP uses this)
#   Partition 15: (may exist on some GCP images)
#   Partition 3: rootfs squashfs (dm-verity data)
#   Partition 4: rootfs verity hash tree
#   Partition 5: models squashfs (dm-verity data)
#   Partition 6: models verity hash tree
#
# The rootfs verity root hash is embedded in the kernel command line via GRUB.
# GRUB measures the cmdline into RTMR[2], so the root hash is part of the
# platform attestation key: sha256(MRTD || RTMR[1] || RTMR[2]).
#
# At boot:
#   1. GRUB loads kernel with cmdline containing root hash
#   2. Initramfs runs veritysetup to create verified device mapper targets
#   3. Kernel mounts dm-verity rootfs as read-only root
#   4. systemd.volatile=overlay provides tmpfs overlay for writable state
#   5. /models is mounted via dm-verity (separate partition)
#   6. Enclave runs directly from rootfs (no Docker, no overlay)
#
# IMPORTANT: Steps are ordered so that everything needing the running root
# filesystem (GRUB config, initramfs hooks) happens BEFORE the dd writes that
# overwrite the root partition. After dd, the root ext4 is destroyed and no
# programs can run from it.
#
# Usage:
#   sudo bash scripts/seal_rootfs.sh
#
# Prerequisites:
#   - Must be run as root
#   - squashfs-tools and cryptsetup-bin installed
#   - Everything you want sealed must already be installed
#   - /models/model.gguf must exist if you want model dm-verity

set -euo pipefail

echo "═══ The Human Fund — Seal Root Filesystem ═══"
echo ""
echo "This will convert the root filesystem to an immutable dm-verity image."
echo "After sealing, the system will only boot from the verified squashfs."
echo ""

# ─── Sanity checks ─────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    echo "FATAL: Must be run as root"
    exit 1
fi

for cmd in mksquashfs veritysetup sgdisk; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "FATAL: $cmd not found. Install: apt-get install squashfs-tools cryptsetup-bin gdisk"
        exit 1
    fi
done

# Find the boot disk
# NVMe: /dev/nvme0n1p1 → /dev/nvme0n1 (strip p + digits)
# SCSI: /dev/sda1 → /dev/sda (strip digits)
ROOT_SOURCE=$(findmnt -n -o SOURCE /)
if [[ "$ROOT_SOURCE" == *nvme* ]]; then
    BOOT_DISK=$(echo "$ROOT_SOURCE" | sed 's/p[0-9]*$//')
else
    BOOT_DISK=$(echo "$ROOT_SOURCE" | sed 's/[0-9]*$//')
fi
echo "Boot disk: $BOOT_DISK"

# Verify /boot is a separate partition (we need it to survive the rootfs replacement)
BOOT_DEV=$(findmnt -n -o SOURCE /boot 2>/dev/null || echo "")
if [ -z "$BOOT_DEV" ]; then
    echo "FATAL: /boot must be a separate partition (not on the root partition)"
    echo "  GCP Ubuntu images normally have /boot on partition 2."
    exit 1
fi
echo "/boot device: $BOOT_DEV"

ROOT_DEV=$(findmnt -n -o SOURCE /)
echo "Root device: $ROOT_DEV"
ROOT_PART_NUM=$(echo "$ROOT_DEV" | grep -oP '\d+$')
echo "Root partition number: $ROOT_PART_NUM"

# ─── Step 1: Verify enclave code is installed ────────────────────────

echo ""
echo "═══ Step 1: Verifying enclave installation ═══"

for f in /opt/humanfund/bin/llama-server /opt/humanfund/enclave/enclave_runner.py /opt/humanfund/venv/bin/python3; do
    if [ -f "$f" ]; then
        echo "  ✓ $f"
    else
        echo "  ✗ MISSING: $f"
        exit 1
    fi
done
echo "  Enclave code verified."

# ─── Step 2: Prepare rootfs for sealing ───────────────────────────────

echo ""
echo "═══ Step 2: Preparing rootfs ═══"

# Clean state that shouldn't be in the immutable image
rm -rf /var/log/*
rm -rf /var/cache/apt/*
rm -rf /tmp/*
rm -rf /root/.bash_history /home/*/.bash_history
# Note: Do NOT remove SSH host keys here. They're needed for SCP/SSH during
# the build process. On the production VM, SSH runs from the immutable rootfs
# anyway (keys can't be modified). The runner doesn't use SSH in production.

# Remove build tools — they're not needed at runtime and waste space
apt-get remove -y --purge build-essential cmake git 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
apt-get clean
echo "  System state cleaned."

# ─── Step 3: Create rootfs squashfs ───────────────────────────────────

echo ""
echo "═══ Step 3: Creating rootfs squashfs ═══"

# We squash the entire root, excluding:
# - Pseudo-filesystems (kernel creates these)
# - /boot (separate partition, not part of rootfs verity)
# - /models (gets its own dm-verity partition)
# - /tmp, /var/tmp, /var/cache (writable state, handled by tmpfs overlay)
# - The output file itself
# - Swap
# Use STAGING_DIR if provided (separate disk), otherwise fall back to /tmp.
# A separate staging disk avoids the problem of temp files being destroyed
# when dd overwrites the root partition. The staging disk is never overwritten.
STAGE="${STAGING_DIR:-/tmp}"
echo "  Staging directory: $STAGE"

SQUASHFS_OUT="$STAGE/rootfs.squashfs"
rm -f "$SQUASHFS_OUT"

echo "  Creating squashfs (this takes a few minutes)..."
mksquashfs / "$SQUASHFS_OUT" \
    -noappend \
    -comp zstd -Xcompression-level 3 \
    -e proc \
    -e sys \
    -e dev \
    -e run \
    -e tmp \
    -e boot \
    -e models \
    -e mnt \
    -e media \
    -e swap.img \
    -e var/cache \
    -e var/tmp \
    -e var/log \
    -e "$SQUASHFS_OUT" \
    2>&1 | tail -5

ROOTFS_SIZE=$(stat -c%s "$SQUASHFS_OUT")
echo "  Rootfs squashfs: $((ROOTFS_SIZE / 1048576)) MB"

# ─── Step 4: Create rootfs verity hash tree ───────────────────────────

echo ""
echo "═══ Step 4: Computing rootfs dm-verity hash tree ═══"

VERITY_OUT="$STAGE/rootfs.verity"
rm -f "$VERITY_OUT"

veritysetup format "$SQUASHFS_OUT" "$VERITY_OUT" \
    --data-block-size=4096 --hash-block-size=4096 --hash=sha256 \
    > $STAGE/rootfs-verity-info.txt 2>&1

ROOTFS_HASH=$(grep 'Root hash:' $STAGE/rootfs-verity-info.txt | awk '{print $NF}')
ROOTFS_SALT=$(grep 'Salt:' $STAGE/rootfs-verity-info.txt | awk '{print $NF}')
ROOTFS_BLOCKS=$(grep 'Data blocks:' $STAGE/rootfs-verity-info.txt | awk '{print $NF}')
VERITY_SIZE=$(stat -c%s "$VERITY_OUT")

echo "  Root hash:   $ROOTFS_HASH"
echo "  Salt:        $ROOTFS_SALT"
echo "  Data blocks: $ROOTFS_BLOCKS"
echo "  Verity tree: $((VERITY_SIZE / 1048576)) MB"

# Save root hash for GRUB
echo "$ROOTFS_HASH" > $STAGE/rootfs-verity-roothash

# ─── Step 5: Create models squashfs + verity (if model exists) ────────

echo ""
echo "═══ Step 5: Creating models dm-verity partition ═══"

MODEL_SQUASHFS="$STAGE/models.squashfs"
MODEL_VERITY="$STAGE/models.verity"
MODELS_HASH=""

if [ -f /models/model.gguf ]; then
    echo "  Creating models squashfs..."
    rm -f "$MODEL_SQUASHFS" "$MODEL_VERITY"
    mksquashfs /models "$MODEL_SQUASHFS" \
        -noappend -comp zstd -Xcompression-level 3 \
        2>&1 | tail -3

    MODEL_SQFS_SIZE=$(stat -c%s "$MODEL_SQUASHFS")
    echo "  Models squashfs: $((MODEL_SQFS_SIZE / 1048576)) MB"

    echo "  Computing models dm-verity..."
    veritysetup format "$MODEL_SQUASHFS" "$MODEL_VERITY" \
        --data-block-size=4096 --hash-block-size=4096 --hash=sha256 \
        > $STAGE/models-verity-info.txt 2>&1

    MODELS_HASH=$(grep 'Root hash:' $STAGE/models-verity-info.txt | awk '{print $NF}')
    MODEL_VERITY_SIZE=$(stat -c%s "$MODEL_VERITY")
    echo "  Models root hash: $MODELS_HASH"
    echo "  Models verity:    $((MODEL_VERITY_SIZE / 1048576)) MB"
else
    echo "  No model found at /models/model.gguf — skipping models verity"
fi

# ─── Step 6: Configure GRUB ──────────────────────────────────────────
#
# IMPORTANT: This must happen BEFORE the dd writes (step 9) which destroy
# the root ext4. GRUB config and initramfs are written to /boot, which is
# on a separate partition and survives the root partition replacement.

echo ""
echo "═══ Step 6: Configuring GRUB ═══"

# Build kernel cmdline additions:
# - humanfund.rootfs_hash: dm-verity root hash for rootfs
# - humanfund.models_hash: dm-verity root hash for models (optional)
# - ro: mount root read-only
#
# NOTE: We do NOT use systemd.volatile=overlay. That would create a tmpfs
# overlay over the entire rootfs, allowing ANY file to be "modified" via the
# overlay upper layer (copy-up). Instead, the initramfs creates targeted
# tmpfs mounts only for directories that genuinely need writes (/tmp, /run,
# /var/log, /var/tmp). Everything else stays on the bare dm-verity squashfs
# with no overlay — writes fail with EROFS.
GRUB_EXTRA="humanfund.rootfs_hash=$ROOTFS_HASH ro"
if [ -n "$MODELS_HASH" ]; then
    GRUB_EXTRA="$GRUB_EXTRA humanfund.models_hash=$MODELS_HASH"
fi

# Since we deleted the root partition, update-grub can't probe the filesystem
# and generates an empty config. We write grub.cfg directly instead.
#
# The key insight: GRUB just needs to load the kernel + initramfs from /boot
# (which is on its own partition, untouched by the seal). The initramfs handles
# setting up dm-verity and mounting the squashfs root.

KERNEL=$(ls /boot/vmlinuz-* | sort -V | tail -1 | xargs basename)
INITRD=$(ls /boot/initrd.img-* | sort -V | tail -1 | xargs basename)
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEV")

echo "  Kernel: $KERNEL"
echo "  Initrd: $INITRD"
echo "  /boot UUID: $BOOT_UUID"

cat > /boot/grub/grub.cfg << GRUBEOF
# The Human Fund — dm-verity GRUB configuration
# Generated by seal_rootfs.sh — do not edit manually
# rootfs hash: $ROOTFS_HASH
# models hash: ${MODELS_HASH:-none}

set default=0
set timeout=3

menuentry "The Human Fund TEE (dm-verity)" {
    search --no-floppy --fs-uuid --set=root $BOOT_UUID
    linux /$KERNEL $GRUB_EXTRA console=ttyS0,115200n8
    initrd /$INITRD
}
GRUBEOF

# Also update the EFI GRUB config to point to /boot by UUID.
# On GCP UEFI, /boot/efi/EFI/ubuntu/grub.cfg is the initial config loaded by
# the UEFI GRUB. It normally searches for the root partition's UUID, then loads
# /boot/grub/grub.cfg from there. Since we deleted the root partition, we need
# to update the EFI config to search for /boot's UUID directly.
EFI_GRUB="/boot/efi/EFI/ubuntu/grub.cfg"
if [ -f "$EFI_GRUB" ]; then
    echo "  Updating EFI GRUB config: $EFI_GRUB"
    cat > "$EFI_GRUB" << EFIEOF
search.fs_uuid $BOOT_UUID root
set prefix=(\$root)/grub
configfile \$prefix/grub.cfg
EFIEOF
    echo "  EFI GRUB updated to search for /boot UUID: $BOOT_UUID"
fi

echo "  GRUB cmdline: $GRUB_EXTRA"
echo "  GRUB configs written."

# ─── Step 7: Create initramfs hooks ──────────────────────────────────
#
# IMPORTANT: This must happen BEFORE the dd writes (step 9) which destroy
# the root ext4. update-initramfs needs to run from the live root filesystem.

echo ""
echo "═══ Step 7: Creating initramfs dm-verity hooks ═══"

# Hook: copy veritysetup + dependencies into initramfs
cat > /etc/initramfs-tools/hooks/humanfund-verity << 'HOOKEOF'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0 ;; esac
. /usr/share/initramfs-tools/hook-functions

# Copy veritysetup and its dependencies
copy_exec /usr/sbin/veritysetup
# Ensure device-mapper kernel modules are included
manual_add_modules dm_verity
manual_add_modules dm_mod
manual_add_modules squashfs
HOOKEOF
chmod +x /etc/initramfs-tools/hooks/humanfund-verity

# Boot script: mount dm-verity rootfs as the actual root
# This runs in local-premount (before the standard root mount)
cat > /etc/initramfs-tools/scripts/local-premount/humanfund-verity << 'SCRIPTEOF'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0 ;; esac
. /scripts/functions

# Parse dm-verity parameters from kernel command line
ROOTFS_HASH=""
MODELS_HASH=""
for param in $(cat /proc/cmdline); do
    case $param in
        humanfund.rootfs_hash=*) ROOTFS_HASH="${param#humanfund.rootfs_hash=}" ;;
        humanfund.models_hash=*) MODELS_HASH="${param#humanfund.models_hash=}" ;;
    esac
done

if [ -z "$ROOTFS_HASH" ]; then
    log_warning_msg "humanfund: No rootfs_hash in cmdline, skipping dm-verity"
    exit 0
fi

# Wait for partition devices to appear
wait_for_udev 10

# Find partitions by label
ROOTFS_DATA=""
ROOTFS_VERITY=""
MODELS_DATA=""
MODELS_VERITY=""

# Try by-partlabel (GPT labels)
[ -e /dev/disk/by-partlabel/humanfund-rootfs ] && ROOTFS_DATA=/dev/disk/by-partlabel/humanfund-rootfs
[ -e /dev/disk/by-partlabel/humanfund-rootfs-verity ] && ROOTFS_VERITY=/dev/disk/by-partlabel/humanfund-rootfs-verity
[ -e /dev/disk/by-partlabel/humanfund-models ] && MODELS_DATA=/dev/disk/by-partlabel/humanfund-models
[ -e /dev/disk/by-partlabel/humanfund-models-verity ] && MODELS_VERITY=/dev/disk/by-partlabel/humanfund-models-verity

if [ -z "$ROOTFS_DATA" ] || [ -z "$ROOTFS_VERITY" ]; then
    log_failure_msg "humanfund: rootfs partitions not found!"
    exit 1
fi

# Set up dm-verity for rootfs
log_begin_msg "humanfund: Setting up rootfs dm-verity"
veritysetup open "$ROOTFS_DATA" humanfund-rootfs "$ROOTFS_VERITY" "$ROOTFS_HASH" || {
    log_failure_msg "humanfund: rootfs dm-verity FAILED — disk may be tampered"
    panic "dm-verity verification failed"
}
log_end_msg 0

# Override ROOT so the standard mount logic uses our verified device
export ROOT=/dev/mapper/humanfund-rootfs
echo "ROOT=/dev/mapper/humanfund-rootfs" >> /conf/param.conf

# Set up dm-verity for models (if hash provided)
if [ -n "$MODELS_HASH" ] && [ -n "$MODELS_DATA" ] && [ -n "$MODELS_VERITY" ]; then
    log_begin_msg "humanfund: Setting up models dm-verity"
    veritysetup open "$MODELS_DATA" humanfund-models "$MODELS_VERITY" "$MODELS_HASH" || {
        log_failure_msg "humanfund: models dm-verity FAILED"
        panic "models dm-verity verification failed"
    }
    log_end_msg 0
fi

log_success_msg "humanfund: dm-verity initialized"
SCRIPTEOF
chmod +x /etc/initramfs-tools/scripts/local-premount/humanfund-verity

# Post-mount script: mount models + create targeted tmpfs mounts
cat > /etc/initramfs-tools/scripts/local-bottom/humanfund-mounts << 'SCRIPTEOF'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0 ;; esac
. /scripts/functions

# Mount dm-verity models partition (if set up in premount)
if [ -e /dev/mapper/humanfund-models ]; then
    log_begin_msg "humanfund: Mounting models (dm-verity)"
    mkdir -p "${rootmnt}/models"
    mount -t squashfs -o ro /dev/mapper/humanfund-models "${rootmnt}/models" || {
        log_failure_msg "humanfund: models mount failed"
        exit 1
    }
    log_end_msg 0
fi

# Create targeted tmpfs mounts for directories that need writes.
# Everything else stays on the bare dm-verity squashfs — writes fail with EROFS.
# This is MORE SECURE than systemd.volatile=overlay, which creates a writable
# overlay over the ENTIRE rootfs (allowing any file to be shadowed via copy-up).
log_begin_msg "humanfund: Creating tmpfs mounts for writable state"

for dir in tmp run var/tmp var/log var/cache var/lib/systemd; do
    mkdir -p "${rootmnt}/${dir}"
    mount -t tmpfs tmpfs "${rootmnt}/${dir}" -o mode=1777,size=256M
done

# /etc needs a small tmpfs for machine-id and resolv.conf
# But we DON'T want a full overlay — only specific files should be writable.
# systemd writes /etc/machine-id at boot. We bind-mount a tmpfs file over it.
mkdir -p "${rootmnt}/run/humanfund-etc"
mount -t tmpfs tmpfs "${rootmnt}/run/humanfund-etc" -o size=1M
echo "uninitialized" > "${rootmnt}/run/humanfund-etc/machine-id"
mount --bind "${rootmnt}/run/humanfund-etc/machine-id" "${rootmnt}/etc/machine-id"

# /input and /output directories for the enclave I/O
mkdir -p "${rootmnt}/input" "${rootmnt}/output"
mount -t tmpfs tmpfs "${rootmnt}/input" -o size=1M
mount -t tmpfs tmpfs "${rootmnt}/output" -o size=10M

log_end_msg 0
SCRIPTEOF
chmod +x /etc/initramfs-tools/scripts/local-bottom/humanfund-mounts

# Update initramfs
echo "  Updating initramfs..."
update-initramfs -u 2>&1 | tail -5
echo "  Initramfs updated."

# ─── Step 8: Repartition the disk ────────────────────────────────────
#
# Everything that needs the running root FS is done. From here on, we only
# manipulate raw disk sectors. After the dd writes in step 9, the root ext4
# is destroyed and no programs can run from it.

echo ""
echo "═══ Step 8: Repartitioning disk ═══"

# Calculate sector requirements (512 bytes/sector)
# Add generous padding for alignment
rootfs_sectors=$(( (ROOTFS_SIZE + 511) / 512 + 4096 ))
rootfs_verity_sectors=$(( (VERITY_SIZE + 511) / 512 + 4096 ))

if [ -n "$MODELS_HASH" ]; then
    models_sectors=$(( (MODEL_SQFS_SIZE + 511) / 512 + 4096 ))
    models_verity_sectors=$(( (MODEL_VERITY_SIZE + 511) / 512 + 4096 ))
fi

# Find where the current root partition ends and the free space begins
# We'll replace the root partition with our new partitions
# First, find the sector range of the current root partition
ROOT_START=$(sgdisk -i "$ROOT_PART_NUM" "$BOOT_DISK" | grep 'First sector' | awk '{print $3}')
echo "  Current root partition starts at sector $ROOT_START"

# Delete the current root partition (we're replacing it)
echo "  Deleting current root partition (${ROOT_PART_NUM})..."
sgdisk -d "$ROOT_PART_NUM" "$BOOT_DISK"

# Create new partitions starting where root was
CURRENT=$ROOT_START

# Helper: get actual partition start sector after sgdisk alignment
get_part_start() {
    sgdisk -i "$1" "$BOOT_DISK" | grep 'First sector' | awk '{print $3}'
}
get_part_end() {
    sgdisk -i "$1" "$BOOT_DISK" | grep 'Last sector' | awk '{print $3}'
}

# Partition 3: rootfs squashfs
sgdisk -n 3:$CURRENT:+${rootfs_sectors} -c 3:humanfund-rootfs "$BOOT_DISK"
ROOTFS_PART_START=$(get_part_start 3)
ROOTFS_PART_END=$(get_part_end 3)
echo "  rootfs partition: sectors $ROOTFS_PART_START - $ROOTFS_PART_END"

# Partition 4: rootfs verity (start after rootfs with gap)
NEXT=$((ROOTFS_PART_END + 2048))
sgdisk -n 4:$NEXT:+${rootfs_verity_sectors} -c 4:humanfund-rootfs-verity "$BOOT_DISK"
ROOTFS_V_START=$(get_part_start 4)
ROOTFS_V_END=$(get_part_end 4)
echo "  rootfs-verity partition: sectors $ROOTFS_V_START - $ROOTFS_V_END"

if [ -n "$MODELS_HASH" ]; then
    # Partition 5: models squashfs
    NEXT=$((ROOTFS_V_END + 2048))
    sgdisk -n 5:$NEXT:+${models_sectors} -c 5:humanfund-models "$BOOT_DISK"
    MODELS_PART_START=$(get_part_start 5)
    MODELS_PART_END=$(get_part_end 5)
    echo "  models partition: sectors $MODELS_PART_START - $MODELS_PART_END"

    # Partition 6: models verity
    NEXT=$((MODELS_PART_END + 2048))
    sgdisk -n 6:$NEXT:+${models_verity_sectors} -c 6:humanfund-models-verity "$BOOT_DISK"
    MODELS_V_START=$(get_part_start 6)
    MODELS_V_END=$(get_part_end 6)
    echo "  models-verity partition: sectors $MODELS_V_START - $MODELS_V_END"
fi

# Don't call partprobe — the kernel can't reload the partition table while root
# is mounted. This is fine because we write data directly to raw disk offsets
# and the GPT table is already updated by sgdisk. The next VM that boots from
# this GCP image will see the correct partition layout.

echo "  Final partition layout (GPT):"
sgdisk -p "$BOOT_DISK"

# ─── Step 9: Write squashfs + verity data to raw disk offsets ────────
#
# WARNING: After these dd writes complete, the root ext4 partition is destroyed.
# No sync, no cleanup, no further commands that need the root filesystem.
# The dd uses oflag=direct to bypass the page cache — data goes straight to disk.

echo ""
echo "═══ Step 9: Writing dm-verity data to disk ═══"

# The squashfs and verity files are on the staging disk (STAGING_DIR),
# NOT on the root ext4. This means they survive the dd that overwrites
# the root partition. No need for tmpfs staging.

# Drop kernel caches and sync before overwriting
sync
echo 3 > /proc/sys/vm/drop_caches

# Convert sector offsets to 4096-byte block offsets for fast direct I/O.
ROOTFS_SEEK_4K=$((ROOTFS_PART_START * 512 / 4096))
ROOTFS_V_SEEK_4K=$((ROOTFS_V_START * 512 / 4096))

# Disable exit-on-error — after the dd, commands may fail due to root corruption
set +e

echo "  Writing rootfs verity (seek=$ROOTFS_V_SEEK_4K x 4K)..."
dd if="$VERITY_OUT" of="$BOOT_DISK" bs=4096 seek=$ROOTFS_V_SEEK_4K status=progress conv=notrunc oflag=direct

echo "  Writing rootfs squashfs (seek=$ROOTFS_SEEK_4K x 4K)..."
dd if="$SQUASHFS_OUT" of="$BOOT_DISK" bs=4096 seek=$ROOTFS_SEEK_4K status=progress conv=notrunc oflag=direct

if [ -n "$MODELS_HASH" ]; then
    MODELS_SEEK_4K=$((MODELS_PART_START * 512 / 4096))
    MODELS_V_SEEK_4K=$((MODELS_V_START * 512 / 4096))
    echo "  Writing models verity (seek=$MODELS_V_SEEK_4K x 4K)..."
    dd if="$MODEL_VERITY" of="$BOOT_DISK" bs=4096 seek=$MODELS_V_SEEK_4K status=progress conv=notrunc oflag=direct
    echo "  Writing models squashfs (seek=$MODELS_SEEK_4K x 4K)..."
    dd if="$MODEL_SQUASHFS" of="$BOOT_DISK" bs=4096 seek=$MODELS_SEEK_4K status=progress conv=notrunc oflag=direct
fi

echo "  All dd writes complete."
echo "SEAL_COMPLETE" > "$STAGE/seal_status"
