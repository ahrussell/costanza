#!/bin/bash
# The Human Fund — Build full dm-verity GCP image (two-disk, nohup)
#
# Creates a GCP disk image with full dm-verity rootfs.
# Uses three disks: boot (build), staging (temp), output (final image).
# All long-running work runs via nohup on the VM to survive SSH timeouts.

set -euo pipefail

GCP_PROJECT="${GCP_PROJECT:-the-human-fund}"
GCP_ZONE="${GCP_ZONE:-us-central1-a}"
USE_GPU=true
ENABLE_SSH=false
IMAGE_NAME=""
BASE_IMAGE=""
VM_NAME="humanfund-builder-$(date +%s)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

while [[ $# -gt 0 ]]; do
    case $1 in
        --gpu) USE_GPU=true; shift ;;
        --cpu) USE_GPU=false; shift ;;
        --name) IMAGE_NAME="$2"; shift 2 ;;
        --base-image) BASE_IMAGE="$2"; shift 2 ;;
        --project) GCP_PROJECT="$2"; shift 2 ;;
        --debug) ENABLE_SSH=true; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

[ -z "$IMAGE_NAME" ] && IMAGE_NAME="humanfund-dmverity-$($USE_GPU && echo gpu || echo cpu)-v5"

echo "═══ The Human Fund — GCP Image Builder ═══"
echo "  Base: ${BASE_IMAGE:-scratch}"
echo "  Image: $IMAGE_NAME"
echo "  VM: $VM_NAME"
echo "  SSH: $($ENABLE_SSH && echo "ENABLED (debug)" || echo "DISABLED (production)")"
echo ""

OUTPUT_DISK="${VM_NAME}-output"
IMAGE_CREATED=false

cleanup() {
    echo ""
    gcloud compute instances delete "$VM_NAME" \
        --project="$GCP_PROJECT" --zone="$GCP_ZONE" --quiet 2>/dev/null || true
    if ! $IMAGE_CREATED; then
        gcloud compute disks delete "$OUTPUT_DISK" \
            --project="$GCP_PROJECT" --zone="$GCP_ZONE" --quiet 2>/dev/null || true
    fi
    echo "  Cleaned."
}
trap cleanup EXIT

vm_run() {
    # ServerAlive*: kill the session after ~30s of unresponsiveness (3*10s)
    # so a wedged SSH (e.g. VM died mid-build) doesn't hang the polling loop.
    gcloud compute ssh "$VM_NAME" --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
        --ssh-flag="-o ConnectTimeout=30" \
        --ssh-flag="-o ServerAliveInterval=10" \
        --ssh-flag="-o ServerAliveCountMax=3" \
        --command="$1" 2>&1
}
vm_scp() {
    gcloud compute scp "$1" "$VM_NAME:$2" --project="$GCP_PROJECT" --zone="$GCP_ZONE" 2>&1
}

# ─── Step 1: Create VM ──────────────────────────────────────────────

echo "─── Step 1: VM ───"

DISK_SIZE=100

IMAGE_FLAGS="--image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud"
[ -n "$BASE_IMAGE" ] && IMAGE_FLAGS="--image=$BASE_IMAGE"

# auto-delete=no: if the builder VM dies mid-build (host maintenance,
# preemption, etc.) the output disk survives and Step 5 can finish
# manually. The cleanup() function still deletes it on a script-controlled
# bail (gated on $IMAGE_CREATED).
OUTPUT_DISK_FLAG="name=$OUTPUT_DISK,size=${DISK_SIZE}GB,type=pd-ssd,device-name=output,auto-delete=no"

gcloud compute instances create "$VM_NAME" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
    --machine-type=c3-standard-8 $IMAGE_FLAGS \
    --boot-disk-size=300GB --boot-disk-type=pd-ssd \
    --create-disk="$OUTPUT_DISK_FLAG" \
    --create-disk="size=100GB,type=pd-ssd,auto-delete=yes,device-name=staging" \
    --confidential-compute-type=TDX \
    --no-restart-on-failure --maintenance-policy=TERMINATE 2>&1 | tail -5

for i in $(seq 1 30); do
    vm_run "echo ready" 2>/dev/null && break; sleep 10
done

# Format staging disk
vm_run "
    STAGING=\$(readlink -f /dev/disk/by-id/google-staging)
    sudo mkfs.ext4 -q \$STAGING && sudo mkdir -p /mnt/staging && sudo mount \$STAGING /mnt/staging
"

# ─── Step 2: Install enclave code ───────────────────────────────────

if [ -n "$BASE_IMAGE" ]; then
    echo "─── Step 2: Using base image ───"
else
    echo "─── Step 2: Installing from scratch (TODO) ───"
    echo "Use --base-image for now."
    exit 1
fi

echo "─── Uploading enclave code ───"
find "$PROJECT_ROOT/prover/enclave" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
tar czf /tmp/tee-upload.tar.gz -C "$PROJECT_ROOT" prover/enclave/ prover/prompts/ 2>/dev/null
vm_scp "/tmp/tee-upload.tar.gz" "/tmp/"
vm_run "cd /tmp && tar xzf tee-upload.tar.gz && sudo cp -r prover/enclave /opt/humanfund/ && sudo cp prover/prompts/system.txt /opt/humanfund/system_prompt.txt && sudo cp prover/prompts/voice_anchors.txt /opt/humanfund/voice_anchors.txt 2>/dev/null || true"

# ─── Upload pinned NVIDIA RIMs (driver + VBIOS) ───────────────────────
# These are NVIDIA-signed Reference Integrity Manifests containing the
# golden measurements the enclave's gpu_attest.py will match the live
# GPU's attestation report against. Refresh procedure lives in
# prover/scripts/gcp/nvidia_artifacts/README.md.
NVIDIA_ARTIFACTS_DIR="$PROJECT_ROOT/prover/scripts/gcp/nvidia_artifacts"
if [ ! -f "$NVIDIA_ARTIFACTS_DIR/driver_rim.xml" ] || [ ! -f "$NVIDIA_ARTIFACTS_DIR/vbios_rim.xml" ]; then
    echo "FATAL: NVIDIA RIMs missing from $NVIDIA_ARTIFACTS_DIR/"
    echo "  Run prover/scripts/gcp/fetch_nvidia_rims.py on an H100 VM and commit the output."
    exit 1
fi
echo "─── Uploading NVIDIA RIMs ───"
vm_scp "$NVIDIA_ARTIFACTS_DIR/driver_rim.xml" "/tmp/driver_rim.xml"
vm_scp "$NVIDIA_ARTIFACTS_DIR/vbios_rim.xml" "/tmp/vbios_rim.xml"
vm_run "sudo mkdir -p /opt/humanfund/nvidia && sudo cp /tmp/driver_rim.xml /tmp/vbios_rim.xml /opt/humanfund/nvidia/"

# Only bake SSH key in debug mode — production images must not have SSH keys
if $ENABLE_SSH; then
    LOCAL_PUBKEY="$HOME/.ssh/google_compute_engine.pub"
    if [ -f "$LOCAL_PUBKEY" ]; then
        vm_scp "$LOCAL_PUBKEY" "/tmp/test_key.pub"
        vm_run "sudo mkdir -p /home/andrewrussell/.ssh && sudo cp /tmp/test_key.pub /home/andrewrussell/.ssh/authorized_keys && sudo chmod 700 /home/andrewrussell/.ssh && sudo chmod 600 /home/andrewrussell/.ssh/authorized_keys && sudo chown -R andrewrussell:andrewrussell /home/andrewrussell/.ssh"
        echo "  SSH key baked for testing."
    fi
fi

# Systemd services
$USE_GPU && vm_run 'sudo tee /etc/systemd/system/humanfund-gpu-cc.service > /dev/null << "EOF"
[Unit]
Description=CC GPU
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "for i in 1 2 3; do nvidia-smi conf-compute -srs 1 2>/dev/null && break; sleep 3; done"
[Install]
WantedBy=multi-user.target
EOF' && vm_run "sudo systemctl daemon-reload && sudo systemctl enable humanfund-gpu-cc"

vm_run 'sudo tee /etc/systemd/system/humanfund-enclave.service > /dev/null << "EOF"
[Unit]
Description=The Human Fund TEE Enclave
After=network-online.target humanfund-gpu-cc.service
[Service]
Type=oneshot
RemainAfterExit=yes
Environment=MODEL_PATH=/models/NousResearch_Hermes-4-70B-Q6_K-00001-of-00002.gguf
Environment=LLAMA_SERVER_BIN=/opt/humanfund/bin/llama-server
Environment=LD_LIBRARY_PATH=/opt/humanfund/bin
Environment=CUBLAS_WORKSPACE_CONFIG=:4096:8
Environment=OMP_NUM_THREADS=1
Environment=GPU_ATTESTATION_ENABLED=0
ExecStart=/opt/humanfund/venv/bin/python3 -m enclave.enclave_runner
WorkingDirectory=/opt/humanfund
[Install]
WantedBy=multi-user.target
EOF'
vm_run "sudo systemctl daemon-reload && sudo systemctl enable humanfund-enclave"

# ─── Step 3: Upload build script and run via nohup ───────────────────

echo "─── Step 3: Running build via nohup ───"
vm_scp "$SCRIPT_DIR/vm_build_all.sh" "/tmp/vm_build_all.sh"
BUILD_ENV=""
$ENABLE_SSH && BUILD_ENV="ENABLE_SSH=1 " && echo "  ⚠ DEBUG BUILD: SSH enabled (different dm-verity hash → won't pass production attestation)"
vm_run "sudo bash -c '${BUILD_ENV}nohup bash /tmp/vm_build_all.sh > /mnt/staging/build.log 2>&1 &'"

# ─── Step 4: Poll for completion ────────────────────────────────────

echo "─── Step 4: Polling... ───"
for i in $(seq 1 60); do
    sleep 30
    STATUS=$(vm_run "cat /mnt/staging/build_status 2>/dev/null" || echo "SSH_ERR")
    STATUS=$(echo "$STATUS" | tr -d '[:space:]')

    if [ "$STATUS" = "SUCCESS" ]; then
        echo "  ✓ Build complete!"
        # Non-fatal hash echoes — a transient SSH hiccup here used to bail
        # the script under set -e/pipefail before Step 5 could run, leaving
        # the artifacts on the VM and the trap deleting the output disk.
        ROOTFS_HASH=$(vm_run "cat /mnt/staging/rootfs-verity-roothash" | tr -d '[:space:]' || echo "")
        MODELS_HASH=$(vm_run "cat /mnt/staging/models-verity-roothash 2>/dev/null" | tr -d '[:space:]' || echo "")
        [ -n "$ROOTFS_HASH" ] && echo "  Rootfs hash: $ROOTFS_HASH"
        [ -n "$MODELS_HASH" ] && echo "  Models hash: $MODELS_HASH"
        break
    elif echo "$STATUS" | grep -q "FAILED"; then
        echo "  ✗ Build failed: $STATUS"
        vm_run "tail -20 /mnt/staging/build.log" || true
        exit 1
    else
        PROGRESS=$(vm_run "tail -1 /mnt/staging/build.log 2>/dev/null" | head -c 80 || echo "?")
        echo "  [$(( i * 30 ))s] $PROGRESS"
    fi
done

# ─── Step 5: Create GCP image from output disk ──────────────────────

echo "─── Step 5: Creating image ───"
gcloud compute instances stop "$VM_NAME" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --quiet 2>&1 | tail -3
gcloud compute instances detach-disk "$VM_NAME" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --disk="$OUTPUT_DISK" 2>&1
gcloud compute images delete "$IMAGE_NAME" --project="$GCP_PROJECT" --quiet 2>/dev/null || true

# gcloud sync-mode HTTP read timeout is 5min, but image creation from a
# 100GB pd-ssd often takes longer. The op continues server-side after a
# client timeout, so swallow the client-side non-zero and poll for READY.
# (`gcloud compute images create` doesn't accept --async — would be the
# cleaner approach if it existed.)
gcloud compute images create "$IMAGE_NAME" --project="$GCP_PROJECT" \
    --source-disk="$OUTPUT_DISK" --source-disk-zone="$GCP_ZONE" --family=humanfund-tee \
    --guest-os-features=UEFI_COMPATIBLE,GVNIC,TDX_CAPABLE 2>&1 || true

echo "  Waiting for image to become READY..."
for i in $(seq 1 45); do
    sleep 20
    IMG_STATUS=$(gcloud compute images describe "$IMAGE_NAME" --project="$GCP_PROJECT" --format="value(status)" 2>/dev/null || echo "")
    if [ "$IMG_STATUS" = "READY" ]; then
        echo "  ✓ Image $IMAGE_NAME ready (after $((i*20))s)"
        IMAGE_CREATED=true
        break
    fi
    echo "  [$((i*20))s] image status: ${IMG_STATUS:-unknown}"
done

if ! $IMAGE_CREATED; then
    echo "  ✗ Image did not become READY within 15min — leaving output disk for inspection"
    exit 1
fi

# Image captured — output disk is no longer needed
gcloud compute disks delete "$OUTPUT_DISK" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --quiet 2>&1 || true
echo ""
echo "═══ BUILD COMPLETE ═══"
echo "  Image:       $IMAGE_NAME"
echo "  Rootfs hash: $ROOTFS_HASH"
[ -n "${MODELS_HASH:-}" ] && echo "  Models hash: $MODELS_HASH"
