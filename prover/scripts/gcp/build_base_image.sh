#!/bin/bash
# The Human Fund — Build GCP Base Image
#
# Creates a base GCP image with all slow-to-install components pre-baked:
#   - Ubuntu 24.04 LTS TDX, NVIDIA 580-open + CUDA, llama-server, Python venv, model weights
#
# The production dm-verity image is built on top of this base image by adding enclave
# code and sealing with dm-verity. See build_full_dmverity_image.sh.
#
# Rebuild when: llama.cpp, NVIDIA driver, Ubuntu, or model changes.
#
# Usage:
#   bash prover/scripts/gcp/build_base_image.sh
#   bash prover/scripts/gcp/build_base_image.sh --cpu
#   bash prover/scripts/gcp/build_base_image.sh --tag b5271

set -euo pipefail

GCP_PROJECT="${GCP_PROJECT:-the-human-fund}"
GCP_ZONE="${GCP_ZONE:-us-central1-a}"
USE_GPU=true
LLAMA_CPP_TAG="b5270"
# Pin to exact commit hash for supply chain integrity (git tags can be force-pushed)
# Pin to known-good commit for tag b5270 — supply chain defense against tag force-push
LLAMA_CPP_COMMIT="${LLAMA_CPP_COMMIT:-a1d711f0e47873a42cdd1e78fcc2e4d0df002534}"
VM_NAME="humanfund-base-builder-$(date +%s)"
BUILDER_MACHINE="c3-standard-22"  # Biggest within 32-CPU quota
IMAGE_NAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --gpu) USE_GPU=true; shift ;;
        --cpu) USE_GPU=false; shift ;;
        --tag) LLAMA_CPP_TAG="$2"; shift 2 ;;
        --name) IMAGE_NAME="$2"; shift 2 ;;
        --project) GCP_PROJECT="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

MODE=$($USE_GPU && echo "gpu" || echo "cpu")
[ -z "$IMAGE_NAME" ] && IMAGE_NAME="humanfund-base-${MODE}-llama-${LLAMA_CPP_TAG}"

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
        echo "  Cleaned up."
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
    ACTUAL_COMMIT=\$(git rev-parse HEAD)
    if [ -n \"$LLAMA_CPP_COMMIT\" ] && [ \"\$ACTUAL_COMMIT\" != \"$LLAMA_CPP_COMMIT\" ]; then
        echo \"SECURITY ERROR: llama.cpp commit mismatch!\"
        echo \"  Expected: $LLAMA_CPP_COMMIT\"
        echo \"  Got:      \$ACTUAL_COMMIT\"
        echo \"  Tag $LLAMA_CPP_TAG may have been force-pushed.\"
        exit 1
    fi
    echo \"llama.cpp commit: \$ACTUAL_COMMIT\"

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

# Upload requirements file and install with hash-pinned versions (supply chain defense)
gcloud compute scp "tee/enclave/requirements.txt" "$VM_NAME:/tmp/requirements.txt" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" 2>&1
vm_run "
    sudo python3 -m venv /opt/humanfund/venv
    sudo /opt/humanfund/venv/bin/pip install --no-cache-dir --require-hashes \
        -r /tmp/requirements.txt
"

# NVIDIA GPU attestation SDK. Not hash-pinned (too many transitive deps),
# but version-pinned. Post-build integrity covered by dm-verity RTMR[2].
gcloud compute scp "prover/enclave/requirements-nvidia.txt" \
    "$VM_NAME:/tmp/requirements-nvidia.txt" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" 2>&1
vm_run "
    sudo /opt/humanfund/venv/bin/pip install --no-cache-dir \
        -r /tmp/requirements-nvidia.txt
"
echo "  Done."

# ─── Step 6: Download model weights ──────────────────────────────────

echo ""
echo "─── Step 6: Downloading model weights (Hermes 4 70B Q6_K, ~58GB split) ───"

# Hermes 4 70B Q6_K is sharded across 2 GGUF files. llama.cpp auto-discovers
# shard 2 when MODEL_PATH points at shard 1 (same directory). dm-verity on
# the /models partition covers both shards; the per-file SHA256s below are
# wget-time integrity only, not a trust boundary.
MODEL_BASE_URL="https://huggingface.co/bartowski/NousResearch_Hermes-4-70B-GGUF/resolve/main/NousResearch_Hermes-4-70B-Q6_K"
SHARD1_NAME="NousResearch_Hermes-4-70B-Q6_K-00001-of-00002.gguf"
SHARD2_NAME="NousResearch_Hermes-4-70B-Q6_K-00002-of-00002.gguf"
SHARD1_SHA256="a2cdf6c2b9e5d698f14cfe30dcf23be86fb333a6eac828e559435eb76c1b7863"
SHARD2_SHA256="a26ab3bac4b8533eb30cc4ddbb4d6e8cacd7a51132085787baf1511886c71f6f"

vm_run "
    sudo mkdir -p /models
    for entry in '$SHARD1_NAME|$SHARD1_SHA256' '$SHARD2_NAME|$SHARD2_SHA256'; do
        NAME=\${entry%%|*}
        EXPECTED=\${entry##*|}
        if [ ! -f /models/\$NAME ]; then
            sudo wget --progress=dot:giga -O /models/\$NAME '$MODEL_BASE_URL'/\$NAME
        fi
        ACTUAL=\$(sha256sum /models/\$NAME | awk '{print \$1}')
        if [ \"\$ACTUAL\" != \"\$EXPECTED\" ]; then
            echo \"FATAL: Hash mismatch on \$NAME! Expected: \$EXPECTED Actual: \$ACTUAL\"
            exit 1
        fi
        echo \"Model verified: \$NAME (\$(du -h /models/\$NAME | cut -f1))\"
    done
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
echo "  Base image:  $IMAGE_NAME"
echo "  llama.cpp:   $LLAMA_CPP_TAG"
echo ""
echo "  Build production image:"
echo "    bash prover/scripts/gcp/build_full_dmverity_image.sh \\"
echo "      --base-image $IMAGE_NAME \\"
echo "      --name humanfund-dmverity-hardened-vN"
