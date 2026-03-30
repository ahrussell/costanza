#!/bin/bash
# The Human Fund — GCP TDX Disk Image Builder (full dm-verity rootfs)
#
# Creates a GCP disk image where the ENTIRE root filesystem is dm-verity protected.
# Every binary that runs — NVIDIA, Python, llama-server, our code — is immutable.
# NO Docker. The enclave runs directly from the dm-verity rootfs.
#
# Security model (see ATTESTATION_SECURITY_V2.md):
#   MRTD     → Google's OVMF firmware (verified via platform key)
#   RTMR[1]  → GRUB/shim (verified via platform key)
#   RTMR[2]  → Kernel + cmdline with dm-verity root hashes (verified via platform key)
#   RTMR[3]  → Available for runtime measurements
#
# RTMR[2] transitively covers ALL code:
#   root hash → Merkle tree → every block of squashfs → Python, llama-server, enclave code
#   model hash → Merkle tree → every block of model squashfs → model weights
#
# Build process:
#   Phase 1: Create a normal Ubuntu VM, install everything
#   Phase 2: Run seal_rootfs.sh to convert root to squashfs + dm-verity
#   Phase 3: Power off, create GCP disk image
#
# Usage:
#   bash scripts/build_gcp_image.sh                    # Default: GPU image
#   bash scripts/build_gcp_image.sh --cpu              # CPU-only image
#   bash scripts/build_gcp_image.sh --name my-image    # Custom image name
#   bash scripts/build_gcp_image.sh --skip-model       # Skip 42.5GB model download
#
# Prerequisites:
#   - gcloud CLI authenticated with project access
#   - TDX-capable zone (us-central1-a)

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────

GCP_PROJECT="${GCP_PROJECT:-the-human-fund}"
GCP_ZONE="${GCP_ZONE:-us-central1-a}"
USE_GPU=true
SKIP_MODEL=false
IMAGE_NAME=""
BASE_IMAGE=""  # Pre-baked base image (skips NVIDIA/CUDA/llama-server build)
VM_NAME="humanfund-builder-$(date +%s)"

BASE_IMAGE_FAMILY="ubuntu-2404-lts-amd64"
BASE_IMAGE_PROJECT="ubuntu-os-cloud"
BUILDER_MACHINE="c3-standard-8"

# Pin llama.cpp version for reproducible builds
LLAMA_CPP_TAG="b5270"

MODEL_URL="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Llama-70B-GGUF/resolve/main/DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf"
MODEL_SHA256="181a82a1d6d2fa24fe4db83a68eee030384986bdbdd4773ba76424e3a6eb9fd8"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ─── Parse Arguments ───────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        --gpu) USE_GPU=true; shift ;;
        --cpu) USE_GPU=false; shift ;;
        --name) IMAGE_NAME="$2"; shift 2 ;;
        --base-image) BASE_IMAGE="$2"; shift 2 ;;
        --project) GCP_PROJECT="$2"; shift 2 ;;
        --zone) GCP_ZONE="$2"; shift 2 ;;
        --skip-model) SKIP_MODEL=true; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [ -z "$IMAGE_NAME" ]; then
    MODE=$($USE_GPU && echo "gpu" || echo "cpu")
    IMAGE_NAME="humanfund-dmverity-${MODE}-v5"
fi

echo "═══ The Human Fund — GCP Image Builder (full dm-verity, no Docker) ═══"
echo "  Project:      $GCP_PROJECT"
echo "  Zone:         $GCP_ZONE"
echo "  Builder VM:   $BUILDER_MACHINE"
echo "  GPU support:  $USE_GPU"
echo "  Base image:   ${BASE_IMAGE:-none (building from scratch)}"
echo "  Image name:   $IMAGE_NAME"
echo "  Skip model:   $SKIP_MODEL"
echo "  VM name:      $VM_NAME"
echo "  llama.cpp:    $LLAMA_CPP_TAG"
echo ""

# ─── Cleanup trap ──────────────────────────────────────────────────────

IMAGE_CREATED=false

cleanup() {
    echo ""
    if $IMAGE_CREATED; then
        echo "═══ Cleaning up builder VM (image created successfully) ═══"
        gcloud compute instances delete "$VM_NAME" \
            --project="$GCP_PROJECT" --zone="$GCP_ZONE" --quiet 2>/dev/null || true
        echo "  Builder VM deleted."
    else
        echo "═══ Build failed — preserving VM for debugging ═══"
        echo "  VM: $VM_NAME"
        echo "  To SSH: gcloud compute ssh $VM_NAME --zone=$GCP_ZONE"
        echo "  To delete: gcloud compute instances delete $VM_NAME --zone=$GCP_ZONE --quiet"
    fi
}
trap cleanup EXIT

# ─── Helpers ───────────────────────────────────────────────────────────

vm_run() {
    gcloud compute ssh "$VM_NAME" --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
        --command="$1" 2>&1
}

vm_scp() {
    gcloud compute scp "$1" "$VM_NAME:$2" \
        --project="$GCP_PROJECT" --zone="$GCP_ZONE" 2>&1
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 1: Create VM and install everything
# ═══════════════════════════════════════════════════════════════════════

echo "═══ PHASE 1: Install everything on a normal Ubuntu VM ═══"
echo ""

# ─── Step 1: Create builder VM ─────────────────────────────────────────

echo "─── Step 1: Creating builder VM ───"

DISK_SIZE=300
if $SKIP_MODEL; then DISK_SIZE=100; fi

IMAGE_FLAGS=""
if [ -n "$BASE_IMAGE" ]; then
    IMAGE_FLAGS="--image=$BASE_IMAGE"
else
    IMAGE_FLAGS="--image-family=$BASE_IMAGE_FAMILY --image-project=$BASE_IMAGE_PROJECT"
fi

# Create a second disk for staging squashfs/verity files during seal.
# This avoids writing temp files to the root ext4 (which gets overwritten by dd).
STAGING_DISK="${VM_NAME}-staging"
gcloud compute disks create "$STAGING_DISK" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
    --size=20GB --type=pd-ssd 2>&1 | tail -3

gcloud compute instances create "$VM_NAME" \
    --project="$GCP_PROJECT" \
    --zone="$GCP_ZONE" \
    --machine-type="$BUILDER_MACHINE" \
    $IMAGE_FLAGS \
    --boot-disk-size="${DISK_SIZE}GB" \
    --boot-disk-type=pd-ssd \
    --disk="name=$STAGING_DISK,device-name=staging,auto-delete=yes" \
    --confidential-compute-type=TDX \
    --provisioning-model=SPOT \
    --no-restart-on-failure \
    --maintenance-policy=TERMINATE

echo "  VM created. Waiting for SSH..."
for i in $(seq 1 30); do
    if vm_run "echo ready" 2>/dev/null; then
        echo "  SSH ready after $((i * 10))s"
        break
    fi
    sleep 10
done

# ─── Steps 2-4: Skip if using base image ─────────────────────────────

if [ -n "$BASE_IMAGE" ]; then
    echo ""
    echo "─── Steps 2-4: Skipped (using base image: $BASE_IMAGE) ───"
    echo "  NVIDIA, CUDA, llama-server, Python venv already installed."
    # Verify the base image has what we need
    vm_run "test -f /opt/humanfund/bin/llama-server && echo '  ✓ llama-server' || echo '  ✗ llama-server MISSING'"
    vm_run "test -f /opt/humanfund/venv/bin/python3 && echo '  ✓ Python venv' || echo '  ✗ Python venv MISSING'"
else

# ─── Step 2: Install system packages ──────────────────────────────────

echo ""
echo "─── Step 2: Installing system packages ───"

vm_run "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3 python3-pip python3-venv \
    squashfs-tools cryptsetup-bin gdisk \
    build-essential cmake git libcurl4-openssl-dev \
    curl wget jq"
echo "  System packages installed."

# ─── Step 3: Install NVIDIA drivers (GPU mode) ────────────────────────

if $USE_GPU; then
    echo ""
    echo "─── Step 3: Installing NVIDIA open driver + CUDA toolkit ───"

    # The open kernel module is required for TDX Confidential Computing.
    vm_run "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        nvidia-driver-580-open \
        nvidia-cuda-toolkit \
        2>/dev/null || echo 'Driver install warnings OK (no GPU on builder)'"
    echo "  NVIDIA driver + CUDA installed."
else
    echo ""
    echo "─── Step 3: Skipping NVIDIA (CPU mode) ───"
fi

# ─── Step 4: Build llama-server from source ───────────────────────────

echo ""
echo "─── Step 4: Building llama-server (pinned: $LLAMA_CPP_TAG) ───"

CUDA_FLAGS=""
if $USE_GPU; then
    CUDA_FLAGS="-DGGML_CUDA=on -DCMAKE_CUDA_ARCHITECTURES=\"80;90\""
fi

vm_run "
    cd /tmp
    git clone --depth 1 --branch $LLAMA_CPP_TAG https://github.com/ggml-org/llama.cpp.git
    cd llama.cpp

    # CUDA stubs for linking without a GPU present
    if [ -f /usr/local/cuda/lib64/stubs/libcuda.so ]; then
        ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1
        export LD_LIBRARY_PATH=/usr/local/cuda/lib64/stubs:\${LD_LIBRARY_PATH:-}
    fi

    cmake -B build \
        $CUDA_FLAGS \
        -DCMAKE_BUILD_TYPE=Release
    cmake --build build --target llama-server -j\$(nproc)

    # Install to /opt/humanfund/bin/
    sudo mkdir -p /opt/humanfund/bin
    sudo cp build/bin/llama-server /opt/humanfund/bin/
    sudo cp build/bin/lib*.so /opt/humanfund/bin/ 2>/dev/null || true
    echo 'llama-server built and installed.'
"
echo "  llama-server installed at /opt/humanfund/bin/"

fi  # end of "if no base image" block

# ─── Step 5: Install Python enclave code ──────────────────────────────

echo ""
echo "─── Step 5: Installing enclave code ───"

# Create Python venv (skip if base image already has it)
if [ -z "$BASE_IMAGE" ]; then
    vm_run "
        sudo python3 -m venv /opt/humanfund/venv
        sudo /opt/humanfund/venv/bin/pip install --no-cache-dir \
            pycryptodome==3.21.0 \
            eth_abi==5.1.0
        echo 'Python venv created with: pycryptodome, eth_abi'
    "
fi

# Upload enclave code
find "$PROJECT_ROOT/tee/enclave" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
tar czf /tmp/tee-upload.tar.gz -C "$PROJECT_ROOT" tee/enclave/ 2>/dev/null
vm_scp "/tmp/tee-upload.tar.gz" "/tmp/"
vm_run "cd /tmp && tar xzf tee-upload.tar.gz && sudo cp -r tee/enclave /opt/humanfund/"
echo "  Enclave code installed at /opt/humanfund/enclave/"

# Upload system prompt
if [ -f "$PROJECT_ROOT/prover/prompts/system.txt" ]; then
    vm_scp "$PROJECT_ROOT/prover/prompts/system.txt" "/tmp/system_prompt.txt"
    vm_run "sudo cp /tmp/system_prompt.txt /opt/humanfund/system_prompt.txt"
    echo "  System prompt installed."
else
    echo "  WARNING: System prompt not found at prover/prompts/system.txt"
fi

# ─── Step 6: Create systemd service ──────────────────────────────────

echo ""
echo "─── Step 6: Creating systemd service ───"

if $USE_GPU; then
    # CC GPU activation at boot
    vm_run 'sudo tee /etc/systemd/system/humanfund-gpu-cc.service > /dev/null << "EOF"
[Unit]
Description=Activate NVIDIA Confidential Computing GPU Ready State
After=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "for i in 1 2 3; do nvidia-smi conf-compute -srs 1 2>/dev/null && break; sleep 3; done"

[Install]
WantedBy=multi-user.target
EOF'
    vm_run "sudo systemctl daemon-reload && sudo systemctl enable humanfund-gpu-cc"
fi

# Main enclave service — one-shot, reads input and runs inference
vm_run 'sudo tee /etc/systemd/system/humanfund-enclave.service > /dev/null << "EOF"
[Unit]
Description=The Human Fund TEE Enclave (one-shot inference)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=MODEL_PATH=/models/model.gguf
Environment=SYSTEM_PROMPT_PATH=/opt/humanfund/system_prompt.txt
Environment=LLAMA_SERVER_BIN=/opt/humanfund/bin/llama-server
Environment=LD_LIBRARY_PATH=/opt/humanfund/bin
ExecStart=/opt/humanfund/venv/bin/python3 -m tee.enclave.enclave_runner
WorkingDirectory=/opt/humanfund
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF'

vm_run "sudo systemctl daemon-reload && sudo systemctl enable humanfund-enclave"
echo "  Systemd services installed."

# ─── Step 7: Download model weights ──────────────────────────────────

if ! $SKIP_MODEL; then
    echo ""
    echo "─── Step 7: Downloading model weights (42.5GB) ───"
    vm_run "
        sudo mkdir -p /models
        if [ ! -f /models/model.gguf ]; then
            sudo wget --progress=dot:giga -O /models/model.gguf '$MODEL_URL'
        fi
        ACTUAL=\$(sha256sum /models/model.gguf | awk '{print \$1}')
        if [ \"\$ACTUAL\" != '$MODEL_SHA256' ]; then
            echo \"FATAL: Model hash mismatch! Expected: $MODEL_SHA256 Actual: \$ACTUAL\"
            exit 1
        fi
        echo \"Model verified: \$(du -h /models/model.gguf | cut -f1)\"
    "
else
    echo ""
    echo "─── Step 7: Skipping model download ───"
    vm_run "sudo mkdir -p /models"
fi

# ═══════════════════════════════════════════════════════════════════════
# PHASE 2: Seal the rootfs with dm-verity
# ═══════════════════════════════════════════════════════════════════════

echo ""
echo "═══ PHASE 2: Seal rootfs with dm-verity ═══"
echo ""

# Format and mount the staging disk for squashfs/verity temp files
vm_run "
    STAGING_DEV=\$(readlink -f /dev/disk/by-id/google-staging)
    echo \"Staging disk: \$STAGING_DEV\"
    sudo mkfs.ext4 -q \$STAGING_DEV
    sudo mkdir -p /mnt/staging
    sudo mount \$STAGING_DEV /mnt/staging
    echo 'Staging disk mounted at /mnt/staging'
"

vm_scp "$SCRIPT_DIR/seal_rootfs.sh" "/tmp/seal_rootfs.sh"
# Pass the staging directory — seal_rootfs.sh will write temp files there
# instead of /tmp (which is on the root ext4 that gets overwritten)
vm_run "sudo STAGING_DIR=/mnt/staging bash /tmp/seal_rootfs.sh"

# Read back the root hash from the staging disk
ROOTFS_HASH=$(vm_run "cat /mnt/staging/rootfs-verity-roothash" | tr -d '[:space:]')
echo ""
echo "  Rootfs dm-verity root hash: $ROOTFS_HASH"

# ═══════════════════════════════════════════════════════════════════════
# PHASE 3: Create GCP disk image
# ═══════════════════════════════════════════════════════════════════════

echo ""
echo "═══ PHASE 3: Create GCP disk image ═══"
echo ""

echo "  Stopping VM..."
gcloud compute instances stop "$VM_NAME" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" --quiet \
    --discard-local-ssd=false 2>/dev/null || \
gcloud compute instances stop "$VM_NAME" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" --quiet

BOOT_DISK=$(gcloud compute instances describe "$VM_NAME" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
    --format='value(disks[0].source)' | xargs basename)

gcloud compute images delete "$IMAGE_NAME" \
    --project="$GCP_PROJECT" --quiet 2>/dev/null || true

gcloud compute images create "$IMAGE_NAME" \
    --project="$GCP_PROJECT" \
    --source-disk="$BOOT_DISK" \
    --source-disk-zone="$GCP_ZONE" \
    --family="humanfund-tee" \
    --description="The Human Fund TEE — full dm-verity rootfs, no Docker ($([ $USE_GPU = true ] && echo 'GPU' || echo 'CPU')), rootfs=$ROOTFS_HASH"

IMAGE_CREATED=true

echo ""
echo "═══ BUILD COMPLETE ═══"
echo ""
echo "  Image:          $IMAGE_NAME"
echo "  Rootfs hash:    $ROOTFS_HASH"
echo "  llama.cpp:      $LLAMA_CPP_TAG"
echo ""
echo "  Security:"
echo "    ✓ Entire rootfs dm-verity protected (Python, llama-server, NVIDIA, systemd)"
echo "    ✓ Model weights on separate dm-verity partition"
echo "    ✓ Root hashes in kernel cmdline → measured into RTMR[2]"
echo "    ✓ No Docker — enclave runs directly from immutable rootfs"
echo "    ✓ No SSH needed — input via metadata, output via serial console"
echo "    ✓ Read-only root with targeted tmpfs mounts (no overlay)"
echo ""
echo "  Runner flow:"
echo "    1. Create VM with epoch state in metadata"
echo "    2. VM boots, runs inference, writes result to serial console"
echo "    3. Runner reads serial output, submits to chain"
echo "    4. Delete VM"
