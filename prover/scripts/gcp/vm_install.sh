#!/bin/bash
# The Human Fund — VM Installation Script (runs ON the builder VM)
#
# This script runs entirely on the GCP VM via nohup. It installs everything
# needed for the TEE enclave, then runs seal_rootfs.sh to create the dm-verity
# rootfs. Designed to survive SSH disconnects.
#
# Usage (from the VM):
#   sudo nohup bash /tmp/vm_install.sh > /tmp/install.log 2>&1 &
#
# Monitor:
#   tail -f /tmp/install.log
#   cat /tmp/install_status  # "SUCCESS" or "FAILED: <reason>"
#
# Prerequisites:
#   - /tmp/tee/ must contain the enclave code (uploaded via SCP)
#   - /tmp/seal_rootfs.sh must exist (uploaded via SCP)
#   - /tmp/system_prompt.txt must exist (uploaded via SCP)

set -euo pipefail

STATUS_FILE="/tmp/install_status"
echo "RUNNING" > "$STATUS_FILE"

trap 'echo "FAILED: line $LINENO" > "$STATUS_FILE"' ERR

log() {
    echo "[$(date +%H:%M:%S)] $1"
}

# ─── Configuration ──────────────────────────────────────────────────────

USE_GPU="${USE_GPU:-true}"
SKIP_MODEL="${SKIP_MODEL:-true}"
LLAMA_CPP_TAG="${LLAMA_CPP_TAG:-b5270}"
MODEL_URL="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Llama-70B-GGUF/resolve/main/DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf"
MODEL_SHA256="181a82a1d6d2fa24fe4db83a68eee030384986bdbdd4773ba76424e3a6eb9fd8"

log "═══ The Human Fund — VM Installation ═══"
log "  GPU: $USE_GPU"
log "  Skip model: $SKIP_MODEL"
log "  llama.cpp: $LLAMA_CPP_TAG"

# ─── Step 1: System packages ──────────────────────────────────────────

log ""
log "─── Step 1: System packages ───"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3 python3-pip python3-venv \
    squashfs-tools cryptsetup-bin gdisk \
    build-essential cmake git libcurl4-openssl-dev \
    curl wget jq
log "  System packages done."

# ─── Step 2: NVIDIA drivers ──────────────────────────────────────────

if [ "$USE_GPU" = "true" ]; then
    log ""
    log "─── Step 2: NVIDIA open driver + CUDA ───"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        nvidia-driver-580-open nvidia-cuda-toolkit \
        2>/dev/null || log "  Driver warnings OK (no GPU on builder)"
    log "  NVIDIA done."
else
    log ""
    log "─── Step 2: Skipping NVIDIA (CPU mode) ───"
fi

# ─── Step 3: Build llama-server ──────────────────────────────────────

log ""
log "─── Step 3: Building llama-server ($LLAMA_CPP_TAG) ───"
cd /tmp
if [ ! -d llama.cpp ]; then
    git clone --depth 1 --branch "$LLAMA_CPP_TAG" https://github.com/ggml-org/llama.cpp.git
fi
cd llama.cpp

# CUDA stubs for linking without GPU
if [ -f /usr/local/cuda/lib64/stubs/libcuda.so ]; then
    ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1
    export LD_LIBRARY_PATH=/usr/local/cuda/lib64/stubs:${LD_LIBRARY_PATH:-}
fi

CUDA_FLAGS=""
if [ "$USE_GPU" = "true" ]; then
    CUDA_FLAGS="-DGGML_CUDA=on -DCMAKE_CUDA_ARCHITECTURES=80;90"
fi

cmake -B build $CUDA_FLAGS -DCMAKE_BUILD_TYPE=Release
cmake --build build --target llama-server -j$(nproc)

mkdir -p /opt/humanfund/bin
cp build/bin/llama-server /opt/humanfund/bin/
cp build/bin/lib*.so /opt/humanfund/bin/ 2>/dev/null || true
log "  llama-server installed."

# ─── Step 4: Python venv ─────────────────────────────────────────────

log ""
log "─── Step 4: Python venv ───"
python3 -m venv /opt/humanfund/venv
/opt/humanfund/venv/bin/pip install --no-cache-dir \
    pycryptodome==3.21.0 \
    eth_abi==5.1.0
log "  Python venv done."

# ─── Step 5: Enclave code ────────────────────────────────────────────

log ""
log "─── Step 5: Installing enclave code ───"
if [ ! -d /tmp/tee/enclave ]; then
    log "FATAL: /tmp/tee/enclave not found"
    echo "FAILED: /tmp/tee/enclave not found" > "$STATUS_FILE"
    exit 1
fi
cp -r /tmp/tee/enclave /opt/humanfund/
if [ -f /tmp/system_prompt.txt ]; then
    cp /tmp/system_prompt.txt /opt/humanfund/system_prompt.txt
fi
log "  Enclave code installed."

# ─── Step 6: Systemd services ────────────────────────────────────────

log ""
log "─── Step 6: Systemd services ───"

if [ "$USE_GPU" = "true" ]; then
    cat > /etc/systemd/system/humanfund-gpu-cc.service << 'EOF'
[Unit]
Description=Activate NVIDIA CC GPU Ready State
After=nvidia-persistenced.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "for i in 1 2 3; do nvidia-smi conf-compute -srs 1 2>/dev/null && break; sleep 3; done"
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable humanfund-gpu-cc
fi

cat > /etc/systemd/system/humanfund-enclave.service << 'EOF'
[Unit]
Description=The Human Fund TEE Enclave (one-shot)
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
EOF

systemctl daemon-reload && systemctl enable humanfund-enclave
log "  Services installed."

# ─── Step 7: Model weights ───────────────────────────────────────────

mkdir -p /models
if [ "$SKIP_MODEL" = "true" ]; then
    log ""
    log "─── Step 7: Skipping model download ───"
else
    log ""
    log "─── Step 7: Downloading model (42.5GB) ───"
    if [ ! -f /models/model.gguf ]; then
        wget --progress=dot:giga -O /models/model.gguf "$MODEL_URL"
    fi
    ACTUAL=$(sha256sum /models/model.gguf | awk '{print $1}')
    if [ "$ACTUAL" != "$MODEL_SHA256" ]; then
        log "FATAL: Model hash mismatch!"
        echo "FAILED: model hash mismatch" > "$STATUS_FILE"
        exit 1
    fi
    log "  Model verified."
fi

# ─── Step 8: Seal rootfs ─────────────────────────────────────────────

log ""
log "─── Step 8: Sealing rootfs with dm-verity ───"
if [ ! -f /tmp/seal_rootfs.sh ]; then
    log "FATAL: /tmp/seal_rootfs.sh not found"
    echo "FAILED: seal_rootfs.sh not found" > "$STATUS_FILE"
    exit 1
fi
bash /tmp/seal_rootfs.sh

# ─── Done ─────────────────────────────────────────────────────────────

log ""
log "═══ INSTALLATION COMPLETE ═══"
echo "SUCCESS" > "$STATUS_FILE"
