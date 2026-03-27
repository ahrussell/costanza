#!/bin/bash
# Build the output disk with dm-verity partitions
# Runs ON the builder VM. Reads squashfs/verity from /mnt/staging.
# Writes to /dev/disk/by-id/google-output.
set -euo pipefail

OUTPUT=$(readlink -f /dev/disk/by-id/google-output)
echo "Output disk: $OUTPUT"

ROOTFS_SQ="/mnt/staging/rootfs.squashfs"
ROOTFS_V="/mnt/staging/rootfs.verity"
ROOTFS_HASH=$(cat /mnt/staging/rootfs-verity-roothash)

ROOTFS_SQ_SIZE=$(stat -c%s "$ROOTFS_SQ")
ROOTFS_V_SIZE=$(stat -c%s "$ROOTFS_V")

# Check for models
MODELS_HASH=""
if [ -f /mnt/staging/models-verity-roothash ]; then
    MODELS_HASH=$(cat /mnt/staging/models-verity-roothash)
fi

# ─── Copy EFI and /boot from the boot disk ────────────────────────────

BOOT_DISK=$(findmnt -n -o SOURCE / | sed 's/p[0-9]*$//')
echo "Boot disk: $BOOT_DISK"

# Read boot disk partition info
EFI_START=$(sgdisk -i 15 "$BOOT_DISK" | grep 'First sector' | awk '{print $3}')
EFI_END=$(sgdisk -i 15 "$BOOT_DISK" | grep 'Last sector' | awk '{print $3}')
EFI_SIZE=$((EFI_END - EFI_START + 1))
BOOT_START=$(sgdisk -i 16 "$BOOT_DISK" | grep 'First sector' | awk '{print $3}')
BOOT_END=$(sgdisk -i 16 "$BOOT_DISK" | grep 'Last sector' | awk '{print $3}')
BOOT_SIZE=$((BOOT_END - BOOT_START + 1))
BIOS_START=$(sgdisk -i 14 "$BOOT_DISK" | grep 'First sector' | awk '{print $3}')
BIOS_END=$(sgdisk -i 14 "$BOOT_DISK" | grep 'Last sector' | awk '{print $3}')
BIOS_SIZE=$((BIOS_END - BIOS_START + 1))

# ─── Partition the output disk ────────────────────────────────────────

echo ""
echo "Partitioning output disk..."

# Wipe the output disk
sgdisk --zap-all "$OUTPUT"

# Calculate rootfs partition sizes (in sectors)
rootfs_sectors=$(( (ROOTFS_SQ_SIZE + 511) / 512 + 4096 ))
rootfs_v_sectors=$(( (ROOTFS_V_SIZE + 511) / 512 + 4096 ))

# Create partitions matching the boot disk layout for BIOS/EFI
# Partition 14: BIOS boot (same location as boot disk)
sgdisk -n 14:$BIOS_START:$BIOS_END -t 14:EF02 -c 14:"BIOS boot" "$OUTPUT"
# Partition 15: EFI System (same location as boot disk)
sgdisk -n 15:$EFI_START:$EFI_END -t 15:EF00 -c 15:"EFI System" "$OUTPUT"
# Partition 16: /boot (same location as boot disk)
sgdisk -n 16:$BOOT_START:$BOOT_END -t 16:EA00 -c 16:"Linux extended boot" "$OUTPUT"

# Partition 3: rootfs squashfs (after /boot)
ROOTFS_START=$((BOOT_END + 2048))
sgdisk -n 3:$ROOTFS_START:+${rootfs_sectors} -c 3:"humanfund-rootfs" "$OUTPUT"
ROOTFS_ACTUAL_START=$(sgdisk -i 3 "$OUTPUT" | grep 'First sector' | awk '{print $3}')
ROOTFS_ACTUAL_END=$(sgdisk -i 3 "$OUTPUT" | grep 'Last sector' | awk '{print $3}')

# Partition 4: rootfs verity
V_START=$((ROOTFS_ACTUAL_END + 2048))
sgdisk -n 4:$V_START:+${rootfs_v_sectors} -c 4:"humanfund-rootfs-verity" "$OUTPUT"
V_ACTUAL_START=$(sgdisk -i 4 "$OUTPUT" | grep 'First sector' | awk '{print $3}')

# Models if present
if [ -n "$MODELS_HASH" ]; then
    MODEL_SQ="/mnt/staging/models.squashfs"
    MODEL_V="/mnt/staging/models.verity"
    MODEL_SQ_SIZE=$(stat -c%s "$MODEL_SQ")
    MODEL_V_SIZE=$(stat -c%s "$MODEL_V")
    model_sectors=$(( (MODEL_SQ_SIZE + 511) / 512 + 4096 ))
    model_v_sectors=$(( (MODEL_V_SIZE + 511) / 512 + 4096 ))

    V_ACTUAL_END=$(sgdisk -i 4 "$OUTPUT" | grep 'Last sector' | awk '{print $3}')
    M_START=$((V_ACTUAL_END + 2048))
    sgdisk -n 5:$M_START:+${model_sectors} -c 5:"humanfund-models" "$OUTPUT"
    M_ACTUAL_START=$(sgdisk -i 5 "$OUTPUT" | grep 'First sector' | awk '{print $3}')
    M_ACTUAL_END=$(sgdisk -i 5 "$OUTPUT" | grep 'Last sector' | awk '{print $3}')
    MV_START=$((M_ACTUAL_END + 2048))
    sgdisk -n 6:$MV_START:+${model_v_sectors} -c 6:"humanfund-models-verity" "$OUTPUT"
    MV_ACTUAL_START=$(sgdisk -i 6 "$OUTPUT" | grep 'First sector' | awk '{print $3}')
fi

partprobe "$OUTPUT"
sleep 2

echo "Output disk partitions:"
sgdisk -p "$OUTPUT"

# ─── Copy BIOS boot, EFI, and /boot partitions ───────────────────────

echo ""
echo "Copying boot partitions..."

dd if="${BOOT_DISK}p14" of="${OUTPUT}p14" bs=4M status=progress 2>&1 | tail -1
dd if="${BOOT_DISK}p15" of="${OUTPUT}p15" bs=4M status=progress 2>&1 | tail -1
dd if="${BOOT_DISK}p16" of="${OUTPUT}p16" bs=4M status=progress 2>&1 | tail -1
echo "  Boot partitions copied."

# ─── Update GRUB on the output disk ──────────────────────────────────

echo ""
echo "Updating GRUB config..."

mkdir -p /mnt/output-boot
mount "${OUTPUT}p16" /mnt/output-boot

KERNEL=$(ls /mnt/output-boot/vmlinuz-* | sort -V | tail -1 | xargs basename)
INITRD=$(ls /mnt/output-boot/initrd.img-* | sort -V | tail -1 | xargs basename)
BOOT_UUID=$(blkid -s UUID -o value "${OUTPUT}p16")

GRUB_EXTRA="humanfund.rootfs_hash=$ROOTFS_HASH ro"
if [ -n "$MODELS_HASH" ]; then
    GRUB_EXTRA="$GRUB_EXTRA humanfund.models_hash=$MODELS_HASH"
fi

cat > /mnt/output-boot/grub/grub.cfg << GRUBEOF
# The Human Fund — dm-verity GRUB configuration
set default=0
set timeout=3
menuentry "The Human Fund TEE (dm-verity)" {
    search --no-floppy --fs-uuid --set=root $BOOT_UUID
    linux /$KERNEL $GRUB_EXTRA console=ttyS0,115200n8
    initrd /$INITRD
}
GRUBEOF

echo "  Kernel: $KERNEL"
echo "  GRUB extra: $GRUB_EXTRA"

# Update EFI GRUB
EFI_DIR="/mnt/output-boot"
mkdir -p /mnt/output-efi
mount "${OUTPUT}p15" /mnt/output-efi
EFI_GRUB="/mnt/output-efi/EFI/ubuntu/grub.cfg"
if [ -f "$EFI_GRUB" ]; then
    cat > "$EFI_GRUB" << EFIEOF
search.fs_uuid $BOOT_UUID root
set prefix=(\$root)/grub
configfile \$prefix/grub.cfg
EFIEOF
    echo "  EFI GRUB updated."
fi
umount /mnt/output-efi

# ─── Create initramfs with dm-verity hooks ────────────────────────────
# We need to create the initramfs hooks on the RUNNING system (boot disk)
# then copy the updated initramfs to the output disk.

echo ""
echo "Creating initramfs with dm-verity hooks..."

# Install hooks on the running system
cat > /etc/initramfs-tools/hooks/humanfund-verity << 'HOOKEOF'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0 ;; esac
. /usr/share/initramfs-tools/hook-functions
copy_exec /usr/sbin/veritysetup
manual_add_modules dm_verity
manual_add_modules dm_mod
manual_add_modules squashfs
HOOKEOF
chmod +x /etc/initramfs-tools/hooks/humanfund-verity

cat > /etc/initramfs-tools/scripts/local-premount/humanfund-verity << 'SCRIPTEOF'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0 ;; esac
. /scripts/functions

ROOTFS_HASH=""
MODELS_HASH=""
for param in $(cat /proc/cmdline); do
    case $param in
        humanfund.rootfs_hash=*) ROOTFS_HASH="${param#humanfund.rootfs_hash=}" ;;
        humanfund.models_hash=*) MODELS_HASH="${param#humanfund.models_hash=}" ;;
    esac
done

[ -z "$ROOTFS_HASH" ] && exit 0

wait_for_udev 10

ROOTFS_DATA=""
ROOTFS_VERITY=""
[ -e /dev/disk/by-partlabel/humanfund-rootfs ] && ROOTFS_DATA=/dev/disk/by-partlabel/humanfund-rootfs
[ -e /dev/disk/by-partlabel/humanfund-rootfs-verity ] && ROOTFS_VERITY=/dev/disk/by-partlabel/humanfund-rootfs-verity

if [ -z "$ROOTFS_DATA" ] || [ -z "$ROOTFS_VERITY" ]; then
    panic "humanfund: rootfs partitions not found"
fi

log_begin_msg "humanfund: Setting up rootfs dm-verity"
veritysetup open "$ROOTFS_DATA" humanfund-rootfs "$ROOTFS_VERITY" "$ROOTFS_HASH" || {
    panic "humanfund: dm-verity FAILED"
}
log_end_msg 0

export ROOT=/dev/mapper/humanfund-rootfs
echo "ROOT=/dev/mapper/humanfund-rootfs" >> /conf/param.conf

if [ -n "$MODELS_HASH" ]; then
    MODELS_DATA=""
    MODELS_VERITY=""
    [ -e /dev/disk/by-partlabel/humanfund-models ] && MODELS_DATA=/dev/disk/by-partlabel/humanfund-models
    [ -e /dev/disk/by-partlabel/humanfund-models-verity ] && MODELS_VERITY=/dev/disk/by-partlabel/humanfund-models-verity
    if [ -n "$MODELS_DATA" ] && [ -n "$MODELS_VERITY" ]; then
        log_begin_msg "humanfund: Setting up models dm-verity"
        veritysetup open "$MODELS_DATA" humanfund-models "$MODELS_VERITY" "$MODELS_HASH" || {
            panic "humanfund: models dm-verity FAILED"
        }
        log_end_msg 0
    fi
fi

log_success_msg "humanfund: dm-verity initialized"
SCRIPTEOF
chmod +x /etc/initramfs-tools/scripts/local-premount/humanfund-verity

cat > /etc/initramfs-tools/scripts/local-bottom/humanfund-mounts << 'SCRIPTEOF'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0 ;; esac
. /scripts/functions

if [ -e /dev/mapper/humanfund-models ]; then
    mkdir -p "${rootmnt}/models"
    mount -t squashfs -o ro /dev/mapper/humanfund-models "${rootmnt}/models"
fi

for dir in tmp run var/tmp var/log var/cache var/lib/systemd; do
    mkdir -p "${rootmnt}/${dir}"
    mount -t tmpfs tmpfs "${rootmnt}/${dir}" -o mode=1777,size=256M
done

mkdir -p "${rootmnt}/run/humanfund-etc"
mount -t tmpfs tmpfs "${rootmnt}/run/humanfund-etc" -o size=1M
echo "uninitialized" > "${rootmnt}/run/humanfund-etc/machine-id"
mount --bind "${rootmnt}/run/humanfund-etc/machine-id" "${rootmnt}/etc/machine-id"

mkdir -p "${rootmnt}/input" "${rootmnt}/output"
mount -t tmpfs tmpfs "${rootmnt}/input" -o size=1M
mount -t tmpfs tmpfs "${rootmnt}/output" -o size=10M
SCRIPTEOF
chmod +x /etc/initramfs-tools/scripts/local-bottom/humanfund-mounts

# Rebuild initramfs
update-initramfs -u 2>&1 | tail -3

# Copy the updated initramfs to the output disk
cp /boot/initrd.img-* /mnt/output-boot/
echo "  Initramfs updated and copied to output disk."

umount /mnt/output-boot

# ─── Write squashfs + verity to output disk partitions ────────────────

echo ""
echo "Writing dm-verity data to output disk..."

dd if="$ROOTFS_SQ" of="${OUTPUT}p3" bs=4M status=progress
dd if="$ROOTFS_V" of="${OUTPUT}p4" bs=4M status=progress

if [ -n "$MODELS_HASH" ]; then
    dd if="/mnt/staging/models.squashfs" of="${OUTPUT}p5" bs=4M status=progress
    dd if="/mnt/staging/models.verity" of="${OUTPUT}p6" bs=4M status=progress
fi

sync
echo "  All data written to output disk."
