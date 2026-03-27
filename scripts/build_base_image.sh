#!/bin/bash
# The Human Fund — Build GCP Base Image (caching layer)
#
# Creates a GCP image with all the slow-to-install components pre-baked:
#   - Ubuntu 24.04 LTS TDX
#   - NVIDIA open driver 580 + CUDA toolkit
#   - llama-server built from source (pinned version)
#   - Python 3 + venv with pinned dependencies
#   - squashfs-tools, cryptsetup, gdisk (for seal_rootfs.sh)
#
# This is NOT the final production image — it's a caching layer. The
# production image is built on top of this by adding enclave code, system
# prompt, and running seal_rootfs.sh.
#
# Rebuild this when:
#   - llama.cpp version changes
#   - NVIDIA driver version changes
#   - Ubuntu base image changes
#   - Python dependencies change
#
# Usage:
#   bash scripts/build_base_image.sh
#   bash scripts/build_base_image.sh --cpu        # No NVIDIA
#   bash scripts/build_base_image.sh --tag b5271   # Different llama.cpp

set -euo pipefail

GCP_PROJECT="${GCP_PROJECT:-the-human-fund}"
GCP_ZONE="${GCP_ZONE:-us-central1-a}"
USE_GPU=true
LLAMA_CPP_TAG="b5270"
VM_NAME="humanfund-base-builder-$(date +%s)"
BUILDER_MACHINE="c3-standard-22"  # Biggest within 32-CPU quota

while [[ $# -gt 0 ]]; do
    case $1 in
        --gpu) USE_GPU=true; shift ;;
        --cpu) USE_GPU=false; shift ;;
        --tag) LLAMA_CPP_TAG="$2"; shift 2 ;;
        --project) GCP_PROJECT="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

MODE=$($USE_GPU && echo "gpu" || echo "cpu")
IMAGE_NAME="humanfund-base-${MODE}-llama-${LLAMA_CPP_TAG}"

echo "═══ The Human Fund — Base Image Builder ═══"
echo "  Project:     $GCP_PROJECT"
echo "  Machine:     $BUILDER_MACHINE (big VM for fast CUDA build)"
echo "  GPU:         $USE_GPU"
echo "  llama.cpp:   $LLAMA_CPP_TAG"
echo "  Image name:  $IMAGE_NAME"
echo "  VM:          $VM_NAME"
echo ""

# Check if image already exists
if gcloud compute images describe "$IMAGE_NAME" --project="$GCP_PROJECT" &>/dev/null; then
    echo "Image $IMAGE_NAME already exists. Delete it first or use a different tag."
    exit 1
fi

IMAGE_CREATED=false
cleanup() {
    echo ""
    if $IMAGE_CREATED; then
        echo "═══ Cleaning up (image created successfully) ═══"
        gcloud compute instances delete "$VM_NAME" \
            --project="$GCP_PROJECT" --zone="$GCP_ZONE" --quiet 2>/dev/null || true
        echo "  VM deleted."
    else
        echo "═══ Build failed — preserving VM for debugging ═══"
        echo "  SSH: gcloud compute ssh $VM_NAME --zone=$GCP_ZONE"
        echo "  Delete: gcloud compute instances delete $VM_NAME --zone=$GCP_ZONE --quiet"
    fi
}
trap cleanup EXIT

vm_run() {
    gcloud compute ssh "$VM_NAME" --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
        --command="$1" 2>&1
}

# ─── Step 1: Create VM ───────────────────────────────────────────────

echo "─── Step 1: Creating VM ($BUILDER_MACHINE) ───"

gcloud compute instances create "$VM_NAME" \
    --project="$GCP_PROJECT" \
    --zone="$GCP_ZONE" \
    --machine-type="$BUILDER_MACHINE" \
    --image-family=ubuntu-2404-lts-amd64 \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=200GB \
    --boot-disk-type=pd-ssd \
    --confidential-compute-type=TDX \
    --provisioning-model=SPOT \
    --no-restart-on-failure \
    --maintenance-policy=TERMINATE

echo "  Waiting for SSH..."
for i in $(seq 1 30); do
    if vm_run "echo ready" 2>/dev/null; then
        echo "  SSH ready after $((i * 10))s"
        break
    fi
    sleep 10
done

# ─── Step 2: System packages ─────────────────────────────────────────

echo ""
echo "─── Step 2: System packages ───"

vm_run "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3 python3-pip python3-venv \
    squashfs-tools cryptsetup-bin gdisk \
    build-essential cmake git libcurl4-openssl-dev \
    curl wget jq"
echo "  Done."

# ─── Step 3: NVIDIA ──────────────────────────────────────────────────

if $USE_GPU; then
    echo ""
    echo "─── Step 3: NVIDIA open driver + CUDA ───"
    vm_run "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        nvidia-driver-580-open nvidia-cuda-toolkit \
        2>/dev/null || echo 'Warnings OK (no GPU on builder)'"
    echo "  Done."
fi

# ─── Step 4: Build llama-server ──────────────────────────────────────

echo ""
echo "─── Step 4: Building llama-server ($LLAMA_CPP_TAG) on $BUILDER_MACHINE ───"

CUDA_FLAGS=""
if $USE_GPU; then
    CUDA_FLAGS="-DGGML_CUDA=on -DCMAKE_CUDA_ARCHITECTURES=\"90\""
fi

vm_run "
    cd /tmp
    git clone --depth 1 --branch $LLAMA_CPP_TAG https://github.com/ggml-org/llama.cpp.git
    cd llama.cpp

    if [ -f /usr/local/cuda/lib64/stubs/libcuda.so ]; then
        ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1
        export LD_LIBRARY_PATH=/usr/local/cuda/lib64/stubs:\${LD_LIBRARY_PATH:-}
    fi

    cmake -B build $CUDA_FLAGS -DCMAKE_BUILD_TYPE=Release
    cmake --build build --target llama-server -j\$(nproc)

    sudo mkdir -p /opt/humanfund/bin
    sudo cp build/bin/llama-server /opt/humanfund/bin/
    sudo cp build/bin/lib*.so /opt/humanfund/bin/ 2>/dev/null || true

    # Clean build artifacts (save disk space in the image)
    rm -rf /tmp/llama.cpp
    echo 'llama-server built and installed.'
"
echo "  llama-server at /opt/humanfund/bin/"

# ─── Step 5: Python venv ─────────────────────────────────────────────

echo ""
echo "─── Step 5: Python venv ───"

vm_run "
    sudo python3 -m venv /opt/humanfund/venv
    sudo /opt/humanfund/venv/bin/pip install --no-cache-dir \
        pycryptodome==3.21.0 \
        eth_abi==5.1.0
"
echo "  Done."

# ─── Step 6: Download model weights ──────────────────────────────────

echo ""
echo "─── Step 6: Downloading model weights (42.5GB) ───"

MODEL_URL="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Llama-70B-GGUF/resolve/main/DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf"
MODEL_SHA256="181a82a1d6d2fa24fe4db83a68eee030384986bdbdd4773ba76424e3a6eb9fd8"

vm_run "
    sudo mkdir -p /models
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

# ─── Step 7: Clean up and create image ───────────────────────────────

echo ""
echo "─── Step 7: Clean up + create image ───"

vm_run "
    sudo rm -rf /tmp/* /var/cache/apt/* /var/log/*
    sudo apt-get clean
"

echo "  Stopping VM..."
gcloud compute instances stop "$VM_NAME" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" --quiet \
    --discard-local-ssd=false 2>/dev/null || \
gcloud compute instances stop "$VM_NAME" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" --quiet

BOOT_DISK=$(gcloud compute instances describe "$VM_NAME" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
    --format='value(disks[0].source)' | xargs basename)

gcloud compute images create "$IMAGE_NAME" \
    --project="$GCP_PROJECT" \
    --source-disk="$BOOT_DISK" \
    --source-disk-zone="$GCP_ZONE" \
    --family="humanfund-base" \
    --description="Base image: Ubuntu 24.04 TDX + NVIDIA 580-open + CUDA + llama-server $LLAMA_CPP_TAG"

IMAGE_CREATED=true

echo ""
echo "═══ BASE IMAGE COMPLETE ═══"
echo "  Image:       $IMAGE_NAME"
echo "  Family:      humanfund-base"
echo "  llama.cpp:   $LLAMA_CPP_TAG"
echo "  Contents:    Ubuntu 24.04, NVIDIA 580-open, CUDA, llama-server, Python venv"
echo ""
echo "  Use with build_gcp_image.sh:"
echo "    bash scripts/build_gcp_image.sh --base-image $IMAGE_NAME"
