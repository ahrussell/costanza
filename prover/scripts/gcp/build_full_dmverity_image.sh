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
SKIP_MODEL=false
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
        --skip-model) SKIP_MODEL=true; shift ;;
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
    gcloud compute ssh "$VM_NAME" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --command="$1" 2>&1
}
vm_scp() {
    gcloud compute scp "$1" "$VM_NAME:$2" --project="$GCP_PROJECT" --zone="$GCP_ZONE" 2>&1
}

# ─── Step 1: Create VM ──────────────────────────────────────────────

echo "─── Step 1: VM ───"

DISK_SIZE=50
$SKIP_MODEL || DISK_SIZE=100

IMAGE_FLAGS="--image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud"
[ -n "$BASE_IMAGE" ] && IMAGE_FLAGS="--image=$BASE_IMAGE"

gcloud compute instances create "$VM_NAME" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
    --machine-type=c3-standard-8 $IMAGE_FLAGS \
    --boot-disk-size=300GB --boot-disk-type=pd-ssd \
    --create-disk="name=$OUTPUT_DISK,size=${DISK_SIZE}GB,type=pd-ssd,device-name=output" \
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
vm_run "cd /tmp && tar xzf tee-upload.tar.gz && sudo cp -r prover/enclave /opt/humanfund/ && sudo cp prover/prompts/system.txt /opt/humanfund/system_prompt.txt 2>/dev/null || true"

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
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
Environment=MODEL_PATH=/models/model.gguf
Environment=LLAMA_SERVER_BIN=/opt/humanfund/bin/llama-server
Environment=LD_LIBRARY_PATH=/opt/humanfund/bin
ExecStart=/opt/humanfund/venv/bin/python3 -m enclave.enclave_runner
WorkingDirectory=/opt/humanfund
[Install]
WantedBy=multi-user.target
EOF'
vm_run "sudo systemctl daemon-reload && sudo systemctl enable humanfund-enclave && sudo mkdir -p /models"

# Download model weights
if ! $SKIP_MODEL; then
    echo "─── Downloading model weights (42.5GB) ───"
    MODEL_URL="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Llama-70B-GGUF/resolve/main/DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf"
    MODEL_SHA256="181a82a1d6d2fa24fe4db83a68eee030384986bdbdd4773ba76424e3a6eb9fd8"
    vm_run "
        if [ ! -f /models/model.gguf ]; then
            sudo wget --progress=dot:giga -O /models/model.gguf '$MODEL_URL'
        fi
        ACTUAL=\$(sha256sum /models/model.gguf | awk '{print \$1}')
        if [ \"\$ACTUAL\" != '$MODEL_SHA256' ]; then
            echo \"FATAL: Hash mismatch! Expected: $MODEL_SHA256 Actual: \$ACTUAL\"
            exit 1
        fi
        echo \"Model verified: \$(du -h /models/model.gguf | cut -f1)\"
    "
fi

# ─── Step 3: Upload build script and run via nohup ───────────────────

echo "─── Step 3: Running build via nohup ───"
vm_scp "$SCRIPT_DIR/vm_build_all.sh" "/tmp/vm_build_all.sh"
SSH_ENV=""
$ENABLE_SSH && SSH_ENV="ENABLE_SSH=1 " && echo "  ⚠ DEBUG BUILD: SSH enabled (different dm-verity hash → won't pass production attestation)"
vm_run "sudo bash -c '${SSH_ENV}nohup bash /tmp/vm_build_all.sh > /mnt/staging/build.log 2>&1 &'"

# ─── Step 4: Poll for completion ────────────────────────────────────

echo "─── Step 4: Polling... ───"
for i in $(seq 1 60); do
    sleep 30
    STATUS=$(vm_run "cat /mnt/staging/build_status 2>/dev/null" || echo "SSH_ERR")
    STATUS=$(echo "$STATUS" | tr -d '[:space:]')

    if [ "$STATUS" = "SUCCESS" ]; then
        echo "  ✓ Build complete!"
        ROOTFS_HASH=$(vm_run "cat /mnt/staging/rootfs-verity-roothash" | tr -d '[:space:]')
        echo "  Rootfs hash: $ROOTFS_HASH"
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
gcloud compute images create "$IMAGE_NAME" --project="$GCP_PROJECT" \
    --source-disk="$OUTPUT_DISK" --source-disk-zone="$GCP_ZONE" --family=humanfund-tee \
    --guest-os-features=UEFI_COMPATIBLE,GVNIC,TDX_CAPABLE 2>&1
gcloud compute disks delete "$OUTPUT_DISK" --project="$GCP_PROJECT" --zone="$GCP_ZONE" --quiet 2>&1

IMAGE_CREATED=true
echo ""
echo "═══ BUILD COMPLETE ═══"
echo "  Image: $IMAGE_NAME"
echo "  Hash:  $ROOTFS_HASH"
