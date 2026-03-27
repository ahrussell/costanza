#!/bin/bash
# The Human Fund — Test dm-verity Boot
#
# Boots a VM from the dm-verity image and verifies:
#   1. Kernel boots from squashfs root (dm-verity)
#   2. Root filesystem is read-only (writes fail with EROFS)
#   3. Targeted tmpfs mounts work (/tmp, /run, /input, /output writable)
#   4. /opt/humanfund/enclave/ is present and immutable
#   5. llama-server binary exists
#   6. Python venv works
#   7. Serial console output is readable
#
# Usage:
#   bash scripts/test_dmverity_boot.sh                           # Default image
#   bash scripts/test_dmverity_boot.sh --image my-image          # Custom image
#   bash scripts/test_dmverity_boot.sh --machine c3-standard-4   # No GPU (cheaper)
#
# This does NOT require an H100. A cheap c3-standard-4 SPOT instance works
# for testing the boot chain. GPU inference is tested separately.

set -euo pipefail

GCP_PROJECT="${GCP_PROJECT:-the-human-fund}"
GCP_ZONE="${GCP_ZONE:-us-central1-a}"
IMAGE_NAME="humanfund-dmverity-gpu-v5-test"
MACHINE_TYPE="c3-standard-4"  # Cheap, no GPU needed for boot test
VM_NAME="humanfund-boottest-$(date +%s)"

while [[ $# -gt 0 ]]; do
    case $1 in
        --image) IMAGE_NAME="$2"; shift 2 ;;
        --machine) MACHINE_TYPE="$2"; shift 2 ;;
        --project) GCP_PROJECT="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

echo "═══ The Human Fund — dm-verity Boot Test ═══"
echo "  Image:   $IMAGE_NAME"
echo "  Machine: $MACHINE_TYPE"
echo "  VM:      $VM_NAME"
echo ""

# Cleanup trap
cleanup() {
    echo ""
    echo "─── Cleaning up ───"
    gcloud compute instances delete "$VM_NAME" \
        --project="$GCP_PROJECT" --zone="$GCP_ZONE" --quiet 2>/dev/null || true
    echo "  VM deleted."
}
trap cleanup EXIT

# ─── Step 1: Create test VM with sample epoch state ──────────────────

echo "─── Step 1: Creating test VM ───"

# Sample epoch state (the enclave will try to read this from metadata)
# Use --metadata-from-file to avoid gcloud's special character parsing issues
METADATA_FILE=$(mktemp)
cat > "$METADATA_FILE" << 'EOFMETA'
{"epoch_context":"=== TEST EPOCH ===\nThis is a test.","seed":42,"input_hash":"0x0000000000000000000000000000000000000000000000000000000000000001"}
EOFMETA

gcloud compute instances create "$VM_NAME" \
    --project="$GCP_PROJECT" \
    --zone="$GCP_ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image="$IMAGE_NAME" \
    --boot-disk-size=100GB \
    --confidential-compute-type=TDX \
    --provisioning-model=SPOT \
    --no-restart-on-failure \
    --maintenance-policy=TERMINATE \
    --metadata-from-file="epoch-state=$METADATA_FILE"

rm -f "$METADATA_FILE"

echo "  VM created."

# ─── Step 2: Wait for boot and check serial console ─────────────────

echo ""
echo "─── Step 2: Waiting for boot (monitoring serial console) ───"
echo "  The VM boots into a dm-verity rootfs. This takes ~60-90s."
echo ""

BOOT_SUCCESS=false
for i in $(seq 1 30); do
    sleep 10
    SERIAL=$(gcloud compute instances get-serial-port-output "$VM_NAME" \
        --project="$GCP_PROJECT" --zone="$GCP_ZONE" 2>/dev/null || echo "")

    # Check for key boot milestones
    if echo "$SERIAL" | grep -q "humanfund: dm-verity initialized"; then
        echo "  ✓ dm-verity initialized ($(( i * 10 ))s)"
    fi
    if echo "$SERIAL" | grep -q "humanfund: Mounting models"; then
        echo "  ✓ Models partition mounted"
    fi
    if echo "$SERIAL" | grep -q "humanfund: Creating tmpfs mounts"; then
        echo "  ✓ Tmpfs mounts created"
    fi

    # Check for login prompt (boot complete) or enclave output
    if echo "$SERIAL" | grep -q "login:\|===HUMANFUND_OUTPUT"; then
        echo "  ✓ Boot complete ($(( i * 10 ))s)"
        BOOT_SUCCESS=true
        break
    fi

    # Check for kernel panic or dm-verity failure
    if echo "$SERIAL" | grep -q "Kernel panic\|dm-verity FAILED\|panic"; then
        echo "  ✗ BOOT FAILED — kernel panic or dm-verity error"
        echo ""
        echo "  Last 30 lines of serial output:"
        echo "$SERIAL" | tail -30
        exit 1
    fi

    echo "  ... waiting ($(( i * 10 ))s)"
done

if ! $BOOT_SUCCESS; then
    echo "  ✗ Boot did not complete within 300s"
    echo ""
    echo "  Serial output (last 50 lines):"
    gcloud compute instances get-serial-port-output "$VM_NAME" \
        --project="$GCP_PROJECT" --zone="$GCP_ZONE" 2>/dev/null | tail -50
    exit 1
fi

# ─── Step 3: SSH in and run verification checks ─────────────────────
# Note: SSH works because sshd is on the dm-verity rootfs (immutable).
# The runner won't use SSH in production — this is just for testing.

echo ""
echo "─── Step 3: Verification checks via SSH ───"

# Wait for SSH
echo "  Waiting for SSH..."
for i in $(seq 1 12); do
    if gcloud compute ssh "$VM_NAME" --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
        --command="echo SSH_OK" 2>/dev/null | grep -q SSH_OK; then
        echo "  SSH ready."
        break
    fi
    sleep 10
done

vm_run() {
    gcloud compute ssh "$VM_NAME" --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
        --command="$1" 2>&1
}

echo ""
echo "  === Root filesystem checks ==="

# Check root is squashfs (dm-verity)
ROOT_FS=$(vm_run "mount | grep ' / ' | head -1")
echo "  Root mount: $ROOT_FS"
if echo "$ROOT_FS" | grep -q "squashfs"; then
    echo "  ✓ Root is squashfs (dm-verity)"
else
    echo "  ✗ Root is NOT squashfs! dm-verity may not be working."
    echo "    Got: $ROOT_FS"
fi

# Check root is read-only
RO_CHECK=$(vm_run "touch /test-write 2>&1 || echo EROFS_OK")
if echo "$RO_CHECK" | grep -q "EROFS_OK\|Read-only"; then
    echo "  ✓ Root is read-only (writes blocked)"
else
    echo "  ✗ Root appears writable! Security issue."
fi

# Check tmpfs mounts
echo ""
echo "  === Tmpfs mount checks ==="
for dir in /tmp /run /input /output; do
    FS_TYPE=$(vm_run "df -T $dir 2>/dev/null | tail -1 | awk '{print \$2}'" || echo "unknown")
    WRITABLE=$(vm_run "touch ${dir}/test-write 2>/dev/null && echo YES && rm ${dir}/test-write || echo NO")
    if echo "$FS_TYPE" | grep -q "tmpfs" && echo "$WRITABLE" | grep -q "YES"; then
        echo "  ✓ $dir is tmpfs and writable"
    else
        echo "  ✗ $dir — type=$FS_TYPE writable=$WRITABLE"
    fi
done

# Check enclave code
echo ""
echo "  === Enclave installation checks ==="
for f in /opt/humanfund/bin/llama-server /opt/humanfund/enclave/enclave_runner.py /opt/humanfund/venv/bin/python3; do
    EXISTS=$(vm_run "test -f $f && echo YES || echo NO")
    if echo "$EXISTS" | grep -q "YES"; then
        echo "  ✓ $f exists"
    else
        echo "  ✗ $f MISSING"
    fi
done

# Check Python works
PYTHON_CHECK=$(vm_run "/opt/humanfund/venv/bin/python3 -c 'from tee.enclave.enclave_runner import main; print(\"IMPORT_OK\")'")
if echo "$PYTHON_CHECK" | grep -q "IMPORT_OK"; then
    echo "  ✓ Python enclave imports work"
else
    echo "  ✗ Python import failed: $PYTHON_CHECK"
fi

# Check system prompt
PROMPT_CHECK=$(vm_run "test -f /opt/humanfund/system_prompt.txt && wc -c /opt/humanfund/system_prompt.txt || echo MISSING")
echo "  System prompt: $PROMPT_CHECK"

# Check NVIDIA driver (may not work without GPU)
NVIDIA_CHECK=$(vm_run "nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo 'no GPU (expected on test VM)'")
echo "  NVIDIA: $NVIDIA_CHECK"

# Check dm-verity status
echo ""
echo "  === dm-verity status ==="
DM_STATUS=$(vm_run "dmsetup status 2>/dev/null || echo 'no dm devices'")
echo "  dm-mapper: $DM_STATUS"

CMDLINE=$(vm_run "cat /proc/cmdline")
echo "  Kernel cmdline: $CMDLINE"
if echo "$CMDLINE" | grep -q "humanfund.rootfs_hash"; then
    echo "  ✓ dm-verity root hash in kernel cmdline"
else
    echo "  ✗ dm-verity root hash NOT in kernel cmdline"
fi

# Check TDX
echo ""
echo "  === TDX checks ==="
TDX_CHECK=$(vm_run "ls /sys/kernel/config/tsm/report/ 2>/dev/null && echo TSM_OK || echo NO_TSM")
echo "  configfs-tsm: $TDX_CHECK"
TDX_DEV=$(vm_run "ls /dev/tdx_guest 2>/dev/null && echo DEV_OK || echo NO_DEV")
echo "  /dev/tdx_guest: $TDX_DEV"

# Check serial output from enclave (if it ran)
echo ""
echo "  === Enclave output check ==="
SERIAL_FINAL=$(gcloud compute instances get-serial-port-output "$VM_NAME" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" 2>/dev/null || echo "")

if echo "$SERIAL_FINAL" | grep -q "===HUMANFUND_OUTPUT_START==="; then
    echo "  ✓ Enclave wrote output to serial console"
    # Extract and show the output
    OUTPUT=$(echo "$SERIAL_FINAL" | sed -n '/===HUMANFUND_OUTPUT_START===/,/===HUMANFUND_OUTPUT_END===/p' | head -5)
    echo "  $OUTPUT"
else
    echo "  ⓘ No enclave output on serial (may not have run yet, or model missing)"
    # Check systemd service status
    ENCLAVE_STATUS=$(vm_run "systemctl status humanfund-enclave 2>&1 | head -10" || echo "unknown")
    echo "  Service status: $ENCLAVE_STATUS"
fi

# ─── Summary ─────────────────────────────────────────────────────────

echo ""
echo "═══ Boot Test Summary ═══"
echo "  Image: $IMAGE_NAME"
echo "  Root: $(echo "$ROOT_FS" | grep -o 'squashfs\|ext4\|unknown' || echo 'unknown')"
echo "  dm-verity: $(echo "$CMDLINE" | grep -o 'humanfund.rootfs_hash=[a-f0-9]*' || echo 'NOT FOUND')"
echo "  TDX: $(echo "$TDX_CHECK" | grep -o 'TSM_OK\|NO_TSM')"
