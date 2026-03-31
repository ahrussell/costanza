#!/bin/bash
# The Human Fund — Build GCP Base Image + Model Template
#
# Creates TWO GCP images:
#   1. Base image: all slow-to-install components pre-baked
#      - Ubuntu 24.04 LTS TDX, NVIDIA 580-open + CUDA, llama-server, Python venv, model weights
#   2. Model template: disk with model squashfs + dm-verity pre-written on partitions
#      - Used by build_full_dmverity_image.sh --model-template to skip all model I/O
#
# The production image is built on top of the base image by adding enclave code
# and sealing with dm-verity. The model template provides the output disk with
# model partitions already in place, eliminating ~5 min of model compression + I/O.
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
MODEL_TEMPLATE_NAME="humanfund-model-template-${MODE}-llama-${LLAMA_CPP_TAG}"
MODEL_TEMPLATE_DISK="${VM_NAME}-model-template"

echo "═══ The Human Fund — Base Image Builder ═══"
echo "  Project:     $GCP_PROJECT"
echo "  Machine:     $BUILDER_MACHINE (big VM for fast CUDA build)"
echo "  GPU:         $USE_GPU"
echo "  llama.cpp:   $LLAMA_CPP_TAG"
echo "  Image name:  $IMAGE_NAME"
echo "  VM:          $VM_NAME"
echo ""

# Check if images already exist
if gcloud compute images describe "$IMAGE_NAME" --project="$GCP_PROJECT" &>/dev/null; then
    echo "Image $IMAGE_NAME already exists. Delete it first or use a different tag."
    exit 1
fi
if gcloud compute images describe "$MODEL_TEMPLATE_NAME" --project="$GCP_PROJECT" &>/dev/null; then
    echo "Image $MODEL_TEMPLATE_NAME already exists. Delete it first or use a different tag."
    exit 1
fi

IMAGE_CREATED=false
TEMPLATE_CREATED=false
cleanup() {
    echo ""
    if $IMAGE_CREATED; then
        echo "═══ Cleaning up (images created successfully) ═══"
        gcloud compute instances delete "$VM_NAME" \
            --project="$GCP_PROJECT" --zone="$GCP_ZONE" --quiet 2>/dev/null || true
        if ! $TEMPLATE_CREATED; then
            gcloud compute disks delete "$MODEL_TEMPLATE_DISK" \
                --project="$GCP_PROJECT" --zone="$GCP_ZONE" --quiet 2>/dev/null || true
        fi
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
    --create-disk="name=$MODEL_TEMPLATE_DISK,size=100GB,type=pd-ssd,device-name=model-template" \
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

# ─── Step 6b: Build model template disk ──────────────────────────────
#
# Creates a disk with model squashfs + verity already on the correct partitions.
# Used by build_full_dmverity_image.sh --model-template to skip all model I/O
# during production builds — the output disk is created FROM this template.

echo ""
echo "─── Step 6b: Building model template disk ───"

MODELS_HASH=$(vm_run "
    # Create model squashfs (deterministic: fixed timestamps, no xattrs)
    sudo mksquashfs /models /tmp/models.squashfs \
        -noappend -comp zstd -Xcompression-level 3 \
        -mkfs-time 0 -all-time 0 -no-xattrs \
        2>&1 | tail -3 >&2

    # Create dm-verity (deterministic: fixed zero salt)
    sudo veritysetup format /tmp/models.squashfs /tmp/models.verity \
        --data-block-size=4096 --hash-block-size=4096 --hash=sha256 \
        --salt=0000000000000000000000000000000000000000000000000000000000000000 \
        > /tmp/models-verity-info.txt 2>&1
    grep 'Root hash:' /tmp/models-verity-info.txt | awk '{print \$NF}'
" | tr -d '[:space:]')
echo "  Models hash: $MODELS_HASH"

vm_run "
    MODEL_SQ_SIZE=\$(stat -c%s /tmp/models.squashfs)
    MODEL_V_SIZE=\$(stat -c%s /tmp/models.verity)
    model_sectors=\$(( (MODEL_SQ_SIZE + 511) / 512 + 4096 ))
    model_v_sectors=\$(( (MODEL_V_SIZE + 511) / 512 + 4096 ))

    echo \"  Squashfs: \$(du -h /tmp/models.squashfs | cut -f1), Verity: \$(du -h /tmp/models.verity | cut -f1)\"

    # Partition the template disk with boot partitions (reserved) + model partitions
    TEMPLATE=\$(readlink -f /dev/disk/by-id/google-model-template)
    sudo sgdisk --zap-all \"\$TEMPLATE\"

    # Reserve boot partitions at same offsets as Ubuntu GCP images
    sudo sgdisk -n 14:2048:10239 -t 14:EF02 -c 14:'BIOS boot' \"\$TEMPLATE\"
    sudo sgdisk -n 15:10240:227327 -t 15:EF00 -c 15:'EFI System' \"\$TEMPLATE\"
    sudo sgdisk -n 16:227328:2097152 -t 16:EA00 -c 16:'Linux extended boot' \"\$TEMPLATE\"

    # Model partitions (fixed offsets, right after /boot)
    MODELS_START=2099200
    sudo sgdisk -n 5:\$MODELS_START:+\${model_sectors} -c 5:'humanfund-models' \"\$TEMPLATE\"
    MODELS_END=\$(sudo sgdisk -i 5 \"\$TEMPLATE\" | grep 'Last sector' | awk '{print \$3}')
    sudo sgdisk -n 6:\$((\$MODELS_END + 2048)):+\${model_v_sectors} -c 6:'humanfund-models-verity' \"\$TEMPLATE\"

    sudo partprobe \"\$TEMPLATE\"
    sleep 2
    echo '  Partition layout:'
    sudo sgdisk -p \"\$TEMPLATE\"

    # Write model data
    echo '  Writing model squashfs...'
    sudo dd if=/tmp/models.squashfs of=\"\${TEMPLATE}p5\" bs=4M status=progress
    echo '  Writing model verity...'
    sudo dd if=/tmp/models.verity of=\"\${TEMPLATE}p6\" bs=4M status=progress
    sudo sync

    # Verify
    sudo veritysetup verify \"\${TEMPLATE}p5\" \"\${TEMPLATE}p6\" '$MODELS_HASH'
    echo '  dm-verity verify: OK'

    # Clean up temp files
    sudo rm -f /tmp/models.squashfs /tmp/models.verity /tmp/models-verity-info.txt
"
echo "  Model template disk ready."

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

# ─── Step 7b: Create model template image ────────────────────────────

echo ""
echo "─── Step 7b: Creating model template image ───"

gcloud compute instances detach-disk "$VM_NAME" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
    --disk="$MODEL_TEMPLATE_DISK" 2>&1

gcloud compute images create "$MODEL_TEMPLATE_NAME" \
    --project="$GCP_PROJECT" \
    --source-disk="$MODEL_TEMPLATE_DISK" \
    --source-disk-zone="$GCP_ZONE" \
    --family="humanfund-model-template" \
    --description="models-hash:$MODELS_HASH" 2>&1

gcloud compute disks delete "$MODEL_TEMPLATE_DISK" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" --quiet 2>&1

TEMPLATE_CREATED=true
echo "  Model template: $MODEL_TEMPLATE_NAME"

echo ""
echo "═══ BASE IMAGE COMPLETE ═══"
echo "  Base image:      $IMAGE_NAME"
echo "  Model template:  $MODEL_TEMPLATE_NAME"
echo "  Models hash:     $MODELS_HASH"
echo "  llama.cpp:       $LLAMA_CPP_TAG"
echo ""
echo "  Build production image:"
echo "    bash prover/scripts/gcp/build_full_dmverity_image.sh \\"
echo "      --base-image $IMAGE_NAME \\"
echo "      --model-template $MODEL_TEMPLATE_NAME"
