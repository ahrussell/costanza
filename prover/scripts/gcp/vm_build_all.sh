#!/bin/bash
# The Human Fund — Complete VM build script (runs ON the VM via nohup)
#
# This single script does everything needed on the VM:
#   1. Clean rootfs for squashing
#   2. Create squashfs of the entire root
#   3. Compute dm-verity hash tree
#   3b. Models squashfs + verity (built from scratch)
#   4. Create initramfs with dm-verity hooks
#   5. Partition the output disk
#   6. Copy boot partitions + write squashfs/verity to output disk
#   7. Update GRUB on the output disk
#
# Usage:
#   sudo nohup bash /tmp/vm_build_all.sh > /mnt/staging/build.log 2>&1 &
#
# Status: cat /mnt/staging/build_status
# Result: cat /mnt/staging/rootfs-verity-roothash

set -euo pipefail

# ENABLE_SSH: set by build_full_dmverity_image.sh --debug flag.
# When set, SSH service + key injection + /etc overlay are included.
# When unset (production), SSH is disabled and /etc stays immutable.
ENABLE_SSH="${ENABLE_SSH:-}"

MODELS_HASH=""

echo "═══ VM Build — $(date) ═══"

STATUS_FILE="/mnt/staging/build_status"
echo "RUNNING" > "$STATUS_FILE"

trap 'echo "FAILED at line $LINENO" > "$STATUS_FILE"; echo "FAILED at line $LINENO"' ERR

# ─── Step 1: Clean rootfs ────────────────────────────────────────────

echo ""
echo "─── Step 1: Install runtime dependencies + clean rootfs ───"

# Install isc-dhcp-client — systemd-networkd's built-in DHCPv4 client fails
# with "Package not installed" on Ubuntu 24.04 squashfs. dhclient works reliably.
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq isc-dhcp-client 2>/dev/null || true
echo "  dhclient installed."

# Prevent kernel upgrades that break NVIDIA DKMS modules.
# unattended-upgrades can auto-install a new kernel in the background,
# but DKMS doesn't rebuild nvidia modules for it. The squashfs then
# captures the new kernel with missing nvidia modules.
systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
apt-mark hold $(dpkg -l | grep linux-image | awk '{print $2}') 2>/dev/null || true
apt-mark hold $(dpkg -l | grep linux-headers | awk '{print $2}') 2>/dev/null || true

rm -rf /var/log/* /var/cache/apt/* /tmp/* /root/.bash_history /home/*/.bash_history
apt-get remove -y --purge build-essential cmake git 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
apt-get clean
mkdir -p /input /output 2>/dev/null || true

# Replace fstab — the original references partitions by UUID/LABEL from the
# builder VM, which don't exist on the output disk. The dm-verity root is
# mounted by the initramfs, so fstab only needs entries for pseudo-filesystems.
cat > /etc/fstab << 'FSTAB'
# The Human Fund — dm-verity rootfs
# Root is mounted by initramfs via dm-verity. No fstab entry needed.
# /boot and /boot/efi are not mounted (not needed at runtime).
proc  /proc  proc  defaults  0  0
FSTAB

# MASK systemd-networkd-wait-online — it blocks boot indefinitely on read-only rootfs
# because the network interface never reaches "online" state (cloud-init can't run).
# "mask" creates a symlink to /dev/null, which survives systemd preset-all on first boot.
# "disable" is insufficient because presets can re-enable it.
systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true
# Mask services that fail on read-only rootfs and interfere with networking:
# - cloud-init: not needed (we get epoch state from metadata directly)
# - google-guest-agent: crashes when network isn't up, then ROLLS BACK
#   systemd-networkd config, breaking our DHCP. We don't need it for SSH
#   (the production enclave uses serial console, not SSH).
systemctl mask cloud-init.service cloud-init-local.service cloud-config.service cloud-final.service 2>/dev/null || true
# Mask google-guest-agent — it rolls back systemd-networkd config and kills DHCP.
# We handle SSH key injection ourselves via a simple metadata-based service.
systemctl mask google-guest-agent.service google-osconfig-agent.service 2>/dev/null || true

# SSH is disabled by default in production images. Debug builds (--debug flag)
# set ENABLE_SSH=1 which enables these services + /etc overlay + .ssh tmpfs mounts.
# Production images have a different dm-verity hash → different platform key →
# won't pass production attestation.
if [ "${ENABLE_SSH}" = "1" ]; then
    echo "  SSH ENABLED (debug build)"
    cat > /etc/systemd/system/humanfund-ssh-keys.service << 'SSHEOF'
[Unit]
Description=Fetch SSH keys from GCP metadata
After=humanfund-dhcp.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  sleep 5; \
  USER=$(curl -sf -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/project/attributes/ssh-keys 2>/dev/null | head -1 | cut -d: -f1); \
  [ -z "$USER" ] && USER=$(curl -sf -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/instance/attributes/ssh-keys 2>/dev/null | head -1 | cut -d: -f1); \
  [ -z "$USER" ] && exit 0; \
  KEY=$(curl -sf -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/project/attributes/ssh-keys 2>/dev/null || curl -sf -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/instance/attributes/ssh-keys 2>/dev/null); \
  [ -z "$KEY" ] && exit 0; \
  HOME_DIR=$(getent passwd "$USER" | cut -d: -f6); \
  [ -z "$HOME_DIR" ] && exit 0; \
  mkdir -p "$HOME_DIR/.ssh"; \
  echo "$KEY" | cut -d: -f2- > "$HOME_DIR/.ssh/authorized_keys"; \
  chmod 700 "$HOME_DIR/.ssh"; \
  chmod 600 "$HOME_DIR/.ssh/authorized_keys"; \
  chown -R "$USER:$USER" "$HOME_DIR/.ssh"; \
  echo "SSH keys injected for $USER"'

[Install]
WantedBy=multi-user.target
SSHEOF
    systemctl enable humanfund-ssh-keys.service 2>/dev/null || true
    systemctl enable ssh.service 2>/dev/null || true
else
    echo "  SSH DISABLED (production build)"
    systemctl disable ssh.service 2>/dev/null || true
    systemctl mask ssh.service 2>/dev/null || true
fi
# Enable basic networking (needed in all builds for metadata service access)
systemctl enable systemd-networkd.service 2>/dev/null || true

# Networking: Use dhclient directly via a simple systemd service.
# systemd-networkd's built-in DHCP client fails with "Package not installed"
# on Ubuntu 24.04 when booted from squashfs. This appears to be a systemd bug
# or feature limitation. dhclient (isc-dhcp-client) works reliably.
#
# Disable netplan and systemd-networkd DHCP — we handle DHCP ourselves.
rm -f /etc/netplan/*.yaml
rm -f /etc/systemd/network/10-dhcp.network
systemctl mask systemd-networkd.service 2>/dev/null || true

# Create a simple dhclient service
cat > /etc/systemd/system/humanfund-dhcp.service << 'DHCPEOF'
[Unit]
Description=DHCP client for network
Before=network-online.target ssh.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Auto-detect the first non-loopback interface (works on both c3 and a3 machines)
ExecStart=/bin/bash -c 'IFACE=$(ip -o link show | grep -v "lo:" | head -1 | awk -F": " "{print \$2}"); echo "DHCP on $IFACE"; ip link set "$IFACE" up && dhclient -v "$IFACE" -lf /tmp/dhclient.leases'
ExecStop=/bin/bash -c 'IFACE=$(ip -o link show | grep -v "lo:" | head -1 | awk -F": " "{print \$2}"); dhclient -r "$IFACE" 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
DHCPEOF
systemctl enable humanfund-dhcp.service 2>/dev/null || true

echo "  Cleaned."

# ─── Step 2: Create squashfs ─────────────────────────────────────────

echo ""
echo "─── Step 2: Creating rootfs squashfs ───"

rm -f /mnt/staging/rootfs.squashfs

# We need mount point directories to exist on the squashfs even though
# their contents are excluded. By using -wildcards with 'dir/*' patterns,
# we exclude contents but keep the empty directories.
# /input and /output are created by mkdir in step 1.

# Exclude CONTENTS of pseudo-fs dirs (proc/*, sys/*, dev/*) but keep the
# directories themselves as mount points. Use -wildcards for glob patterns.
# For dirs we fully exclude (boot, models), use -pf pseudo-entries to recreate.
mksquashfs / /mnt/staging/rootfs.squashfs \
    -noappend -comp zstd -Xcompression-level 3 \
    -mkfs-time 0 -all-time 0 -no-xattrs \
    -wildcards \
    -e 'proc/*' -e 'sys/*' -e 'dev/*' -e 'run/*' -e 'tmp/*' \
    -e 'boot/*' -e 'models/*' -e 'mnt/*' -e 'media/*' \
    -e swap.img \
    2>&1 | tail -5

echo "  Size: $(du -h /mnt/staging/rootfs.squashfs | cut -f1)"

# ─── Step 3: Create verity hash tree ─────────────────────────────────

echo ""
echo "─── Step 3: Computing dm-verity hash tree ───"

rm -f /mnt/staging/rootfs.verity

veritysetup format /mnt/staging/rootfs.squashfs /mnt/staging/rootfs.verity \
    --data-block-size=4096 --hash-block-size=4096 --hash=sha256 \
    --salt=0000000000000000000000000000000000000000000000000000000000000000 \
    > /mnt/staging/verity-info.txt 2>&1

ROOTFS_HASH=$(grep 'Root hash:' /mnt/staging/verity-info.txt | awk '{print $NF}')
echo "$ROOTFS_HASH" > /mnt/staging/rootfs-verity-roothash

echo "  Root hash: $ROOTFS_HASH"
echo "  Verity size: $(du -h /mnt/staging/rootfs.verity | cut -f1)"

# ─── Step 3b: Models squashfs + verity ──────────────────────────────

if [ -f /models/model.gguf ]; then
    echo ""
    echo "─── Step 3b: Building model squashfs + verity ───"
    rm -f /mnt/staging/models.squashfs /mnt/staging/models.verity
    mksquashfs /models /mnt/staging/models.squashfs \
        -noappend -comp zstd -Xcompression-level 3 \
        -mkfs-time 0 -all-time 0 -no-xattrs \
        2>&1 | tail -3
    veritysetup format /mnt/staging/models.squashfs /mnt/staging/models.verity \
        --data-block-size=4096 --hash-block-size=4096 --hash=sha256 \
        --salt=0000000000000000000000000000000000000000000000000000000000000000 \
        > /mnt/staging/models-verity-info.txt 2>&1
    MODELS_HASH=$(grep 'Root hash:' /mnt/staging/models-verity-info.txt | awk '{print $NF}')
    echo "$MODELS_HASH" > /mnt/staging/models-verity-roothash
    echo "  Models hash: $MODELS_HASH"
fi

# ─── Step 4: Create initramfs with dm-verity hooks ───────────────────

echo ""
echo "─── Step 4: Creating initramfs hooks ───"

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
[ -z "$ROOTFS_DATA" ] || [ -z "$ROOTFS_VERITY" ] && panic "humanfund: rootfs partitions not found"
log_begin_msg "humanfund: Setting up rootfs dm-verity"
veritysetup open "$ROOTFS_DATA" humanfund-rootfs "$ROOTFS_VERITY" "$ROOTFS_HASH" || panic "humanfund: dm-verity FAILED"
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
        veritysetup open "$MODELS_DATA" humanfund-models "$MODELS_VERITY" "$MODELS_HASH" || panic "humanfund: models dm-verity FAILED"
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
# Core writable dirs needed by systemd, services, and SSH.
# /home is NOT tmpfs — it's on the dm-verity squashfs (contains user dirs from build).
# Instead, we mount tmpfs over each user's .ssh/ dir for key injection.
for dir in tmp run var/tmp var/log var/cache var/lib; do
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
# /etc/resolv.conf — bind-mount from tmpfs for DNS resolution.
# The rest of /etc stays on the immutable dm-verity rootfs (no overlay).
echo "nameserver 169.254.169.254" > "${rootmnt}/run/humanfund-etc/resolv.conf"
mount --bind "${rootmnt}/run/humanfund-etc/resolv.conf" "${rootmnt}/etc/resolv.conf"

# SSH key injection — only in debug builds (ENABLE_SSH=1 baked into kernel cmdline).
# Production images have no writable .ssh dirs and no /etc overlay, so SSH
# cannot authenticate anyone even if sshd is running.
ENABLE_SSH=""
for arg in $(cat /proc/cmdline); do
    case "$arg" in humanfund.enable_ssh=1) ENABLE_SSH=1 ;; esac
done
if [ "$ENABLE_SSH" = "1" ]; then
    for homedir in "${rootmnt}"/home/*/; do
        user=$(basename "$homedir")
        mkdir -p "${rootmnt}/home/${user}/.ssh"
        mount -t tmpfs tmpfs "${rootmnt}/home/${user}/.ssh" -o mode=700,size=1M
        chown $(stat -c '%u:%g' "${rootmnt}/home/${user}") "${rootmnt}/home/${user}/.ssh" 2>/dev/null || true
    done
    # Debug: overlay /etc so SSH keys service can write authorized_keys
    mkdir -p "${rootmnt}/run/humanfund-etc-upper" "${rootmnt}/run/humanfund-etc-work"
    mount -t overlay overlay \
        -o "lowerdir=${rootmnt}/etc,upperdir=${rootmnt}/run/humanfund-etc-upper,workdir=${rootmnt}/run/humanfund-etc-work" \
        "${rootmnt}/etc"
fi
SCRIPTEOF
chmod +x /etc/initramfs-tools/scripts/local-bottom/humanfund-mounts

update-initramfs -u 2>&1 | tail -3
echo "  Initramfs updated."

# ─── Step 5: Build the output disk ──────────────────────────────────

echo ""
echo "─── Step 5: Building output disk ───"

OUTPUT=$(readlink -f /dev/disk/by-id/google-output)
BOOT_DISK=$(findmnt -n -o SOURCE / | sed 's/p[0-9]*$//')
echo "  Output: $OUTPUT"
echo "  Boot:   $BOOT_DISK"

ROOTFS_SQ="/mnt/staging/rootfs.squashfs"
ROOTFS_V="/mnt/staging/rootfs.verity"
ROOTFS_SQ_SIZE=$(stat -c%s "$ROOTFS_SQ")
ROOTFS_V_SIZE=$(stat -c%s "$ROOTFS_V")

# Read boot disk partition info
EFI_START=$(sgdisk -i 15 "$BOOT_DISK" | grep 'First sector' | awk '{print $3}')
EFI_END=$(sgdisk -i 15 "$BOOT_DISK" | grep 'Last sector' | awk '{print $3}')
BOOT_PART_START=$(sgdisk -i 16 "$BOOT_DISK" | grep 'First sector' | awk '{print $3}')
BOOT_PART_END=$(sgdisk -i 16 "$BOOT_DISK" | grep 'Last sector' | awk '{print $3}')
BIOS_START=$(sgdisk -i 14 "$BOOT_DISK" | grep 'First sector' | awk '{print $3}')
BIOS_END=$(sgdisk -i 14 "$BOOT_DISK" | grep 'Last sector' | awk '{print $3}')

rootfs_sectors=$(( (ROOTFS_SQ_SIZE + 511) / 512 + 4096 ))
rootfs_v_sectors=$(( (ROOTFS_V_SIZE + 511) / 512 + 4096 ))

# Layout: 14 | 15 | 16 | 3: rootfs | 4: rootfs-verity | 5: models | 6: models-verity
sgdisk --zap-all "$OUTPUT"

sgdisk -n 14:$BIOS_START:$BIOS_END -t 14:EF02 -c 14:"BIOS boot" "$OUTPUT"
sgdisk -n 15:$EFI_START:$EFI_END -t 15:EF00 -c 15:"EFI System" "$OUTPUT"
sgdisk -n 16:$BOOT_PART_START:$BOOT_PART_END -t 16:EA00 -c 16:"Linux extended boot" "$OUTPUT"

ROOTFS_START=$((BOOT_PART_END + 2048))
sgdisk -n 3:$ROOTFS_START:+${rootfs_sectors} -c 3:"humanfund-rootfs" "$OUTPUT"
ROOTFS_ACTUAL_END=$(sgdisk -i 3 "$OUTPUT" | grep 'Last sector' | awk '{print $3}')
V_START=$((ROOTFS_ACTUAL_END + 2048))
sgdisk -n 4:$V_START:+${rootfs_v_sectors} -c 4:"humanfund-rootfs-verity" "$OUTPUT"

if [ -n "$MODELS_HASH" ] && [ -f /mnt/staging/models.squashfs ]; then
    MODEL_SQ="/mnt/staging/models.squashfs"
    MODEL_V="/mnt/staging/models.verity"
    model_sectors=$(( ($(stat -c%s "$MODEL_SQ") + 511) / 512 + 4096 ))
    model_v_sectors=$(( ($(stat -c%s "$MODEL_V") + 511) / 512 + 4096 ))
    V_END=$(sgdisk -i 4 "$OUTPUT" | grep 'Last sector' | awk '{print $3}')
    sgdisk -n 5:$((V_END + 2048)):+${model_sectors} -c 5:"humanfund-models" "$OUTPUT"
    M_END=$(sgdisk -i 5 "$OUTPUT" | grep 'Last sector' | awk '{print $3}')
    sgdisk -n 6:$((M_END + 2048)):+${model_v_sectors} -c 6:"humanfund-models-verity" "$OUTPUT"
fi

partprobe "$OUTPUT"
sleep 2

echo "  Output disk partitions:"
sgdisk -p "$OUTPUT"

# ─── Step 6: Copy boot partitions ───────────────────────────────────

echo ""
echo "─── Step 6: Copying boot partitions ───"

dd if="${BOOT_DISK}p14" of="${OUTPUT}p14" bs=4M status=none
dd if="${BOOT_DISK}p15" of="${OUTPUT}p15" bs=4M status=none
dd if="${BOOT_DISK}p16" of="${OUTPUT}p16" bs=4M status=none
echo "  Boot partitions copied."

# Fix journal after dd copy (ext4 journal may be dirty from the source disk)
fsck.ext4 -y "${OUTPUT}p16" > /dev/null 2>&1 || true

# ─── Step 7: Update GRUB on output disk ─────────────────────────────

echo ""
echo "─── Step 7: Updating GRUB ───"

mkdir -p /mnt/output-boot /mnt/output-efi
mount "${OUTPUT}p16" /mnt/output-boot

KERNEL=$(ls /mnt/output-boot/vmlinuz-* | sort -V | tail -1 | xargs basename)
INITRD=$(ls /mnt/output-boot/initrd.img-* | sort -V | tail -1 | xargs basename)
BOOT_UUID=$(blkid -s UUID -o value "${OUTPUT}p16")

GRUB_EXTRA="humanfund.rootfs_hash=$ROOTFS_HASH ro"
[ -n "$MODELS_HASH" ] && GRUB_EXTRA="$GRUB_EXTRA humanfund.models_hash=$MODELS_HASH"
[ "$ENABLE_SSH" = "1" ] && GRUB_EXTRA="$GRUB_EXTRA humanfund.enable_ssh=1"

cat > /mnt/output-boot/grub/grub.cfg << GRUBEOF
set default=0
set timeout=3
menuentry "The Human Fund TEE (dm-verity)" {
    search --no-floppy --fs-uuid --set=root $BOOT_UUID
    linux /$KERNEL $GRUB_EXTRA console=ttyS0,115200n8
    initrd /$INITRD
}
GRUBEOF

# Copy updated initramfs (built in step 4)
cp /boot/initrd.img-* /mnt/output-boot/
echo "  GRUB + initramfs updated."

# Update EFI GRUB
mount "${OUTPUT}p15" /mnt/output-efi
EFI_GRUB="/mnt/output-efi/EFI/ubuntu/grub.cfg"
if [ -f "$EFI_GRUB" ]; then
    cat > "$EFI_GRUB" << EFIEOF
search.fs_uuid $BOOT_UUID root
set prefix=(\$root)/grub
configfile \$prefix/grub.cfg
EFIEOF
fi
umount /mnt/output-efi
umount /mnt/output-boot
echo "  EFI updated."

# ─── Step 8: Write squashfs + verity to output disk ─────────────────

echo ""
echo "─── Step 8: Writing dm-verity data ───"

dd if="$ROOTFS_SQ" of="${OUTPUT}p3" bs=4M status=progress
dd if="$ROOTFS_V" of="${OUTPUT}p4" bs=4M status=progress

if [ -n "$MODELS_HASH" ] && [ -f /mnt/staging/models.squashfs ]; then
    dd if="/mnt/staging/models.squashfs" of="${OUTPUT}p5" bs=4M status=progress
    dd if="/mnt/staging/models.verity" of="${OUTPUT}p6" bs=4M status=progress
fi

sync
echo "  Data written."

# ─── Step 9: Verify ─────────────────────────────────────────────────

echo ""
echo "─── Step 9: Verifying dm-verity ───"

veritysetup verify "${OUTPUT}p3" "${OUTPUT}p4" "$ROOTFS_HASH"
echo "  Rootfs verify: OK"

if [ -n "$MODELS_HASH" ]; then
    veritysetup verify "${OUTPUT}p5" "${OUTPUT}p6" "$MODELS_HASH"
    echo "  Models verify: OK"
fi

echo ""
echo "═══ BUILD COMPLETE ═══"
echo "  Rootfs hash: $ROOTFS_HASH"
echo "  Models hash: ${MODELS_HASH:-none}"
echo "SUCCESS" > "$STATUS_FILE"
