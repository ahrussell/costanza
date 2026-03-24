#!/bin/bash
# The Human Fund — GPU TEE VM Setup Script
#
# Run during snapshot creation on a fresh GCP TDX Confidential VM.
# Installs NVIDIA drivers, CUDA, llama.cpp (GPU), model weights, and enclave code.
#
# Usage:
#   # SCP this script to the VM and run as root:
#   sudo bash setup_gpu.sh
#
# After this script completes, create a disk image from the VM's boot disk.
# That image becomes the snapshot that runners boot from.

set -euo pipefail

INSTALL_DIR="/opt/humanfund"
MODEL_DIR="$INSTALL_DIR/model"
ENCLAVE_DIR="$INSTALL_DIR/enclave"
LLAMA_CPP_TAG="b5170"

# DeepSeek R1 Distill Llama 70B Q4_K_M
MODEL_URL="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Llama-70B-GGUF/resolve/main/DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf"
MODEL_SHA256="a4b1781e2f4ee59a0c048b236c5765e6c4b770c6c6a4e1f02ba42e1daae2dfe2"
MODEL_FILENAME="DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf"

echo "═══ The Human Fund — GPU TEE Setup ═══"
echo "  Install dir: $INSTALL_DIR"
echo "  llama.cpp tag: $LLAMA_CPP_TAG"
echo "  Model: $MODEL_FILENAME"

# ─── System dependencies ─────────────────────────────────────────────────

echo ""
echo "═══ Installing system dependencies ═══"
apt-get update -qq
apt-get install -y -qq cmake git build-essential python3 python3-pip python3-venv curl xxd

# ─── NVIDIA drivers + CUDA ───────────────────────────────────────────────

echo ""
echo "═══ Installing NVIDIA drivers + CUDA ═══"

if ! command -v nvidia-smi &>/dev/null; then
    # Install CUDA toolkit (includes drivers)
    apt-get install -y -qq nvidia-driver-550 nvidia-cuda-toolkit
    echo "  NVIDIA drivers installed"
else
    echo "  NVIDIA drivers already installed"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
fi

# Activate Confidential Computing GPU Ready State (required for TDX VMs)
# Without this, CUDA silently fails and llama.cpp falls back to CPU
echo "  Activating CC GPU Ready State..."
nvidia-smi conf-compute -srs 1 2>/dev/null || true
sleep 2

# ─── Build llama.cpp with CUDA ───────────────────────────────────────────

echo ""
echo "═══ Building llama.cpp (CUDA) ═══"

cd /tmp
if [ ! -d "llama.cpp" ]; then
    git clone --depth 1 --branch "$LLAMA_CPP_TAG" https://github.com/ggerganov/llama.cpp.git
fi
cd llama.cpp
mkdir -p build && cd build
cmake .. -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release
cmake --build . --config Release -j$(nproc)

# Install binary
cp bin/llama-server "$INSTALL_DIR/llama-server"
chmod +x "$INSTALL_DIR/llama-server"
echo "  llama-server built and installed"

# ─── Python environment ──────────────────────────────────────────────────

echo ""
echo "═══ Setting up Python environment ═══"

python3 -m venv "$INSTALL_DIR/venv"
source "$INSTALL_DIR/venv/bin/activate"
pip install --quiet flask pycryptodome eth_abi
echo "  Python venv created with flask, pycryptodome, eth_abi"

# ─── Download model ──────────────────────────────────────────────────────

echo ""
echo "═══ Downloading model weights ═══"

mkdir -p "$MODEL_DIR"
MODEL_PATH="$MODEL_DIR/$MODEL_FILENAME"

if [ -f "$MODEL_PATH" ]; then
    echo "  Model already exists, verifying hash..."
    ACTUAL_HASH=$(sha256sum "$MODEL_PATH" | awk '{print $1}')
    if [ "$ACTUAL_HASH" = "$MODEL_SHA256" ]; then
        echo "  Hash verified: ${ACTUAL_HASH:0:16}..."
    else
        echo "  Hash mismatch! Re-downloading..."
        rm -f "$MODEL_PATH"
    fi
fi

if [ ! -f "$MODEL_PATH" ]; then
    echo "  Downloading $MODEL_FILENAME (~42.5 GB)..."
    curl -L -o "$MODEL_PATH" "$MODEL_URL"
    ACTUAL_HASH=$(sha256sum "$MODEL_PATH" | awk '{print $1}')
    if [ "$ACTUAL_HASH" != "$MODEL_SHA256" ]; then
        echo "  ERROR: Hash mismatch after download!"
        echo "    Expected: $MODEL_SHA256"
        echo "    Actual:   $ACTUAL_HASH"
        exit 1
    fi
    echo "  Hash verified: ${ACTUAL_HASH:0:16}..."
fi

# ─── Install enclave code ────────────────────────────────────────────────

echo ""
echo "═══ Installing enclave code ═══"

# The enclave code should be SCP'd to /tmp/enclave/ before running this script,
# or cloned from the repo. For snapshot creation, we expect it at /tmp/enclave/.
if [ -d "/tmp/enclave" ]; then
    mkdir -p "$ENCLAVE_DIR"
    cp -r /tmp/enclave/* "$ENCLAVE_DIR/"
    echo "  Enclave code installed from /tmp/enclave/"
else
    echo "  WARNING: No enclave code found at /tmp/enclave/"
    echo "  You'll need to SCP the tee/enclave/ directory before creating the snapshot."
    mkdir -p "$ENCLAVE_DIR"
fi

# ─── Install boot script ─────────────────────────────────────────────────

echo ""
echo "═══ Installing boot script ═══"

if [ -f "/tmp/boot.sh" ]; then
    cp /tmp/boot.sh "$INSTALL_DIR/boot.sh"
    chmod +x "$INSTALL_DIR/boot.sh"
    echo "  boot.sh installed"
else
    echo "  WARNING: No boot.sh found at /tmp/boot.sh"
fi

# Create systemd service for auto-start on boot
cat > /etc/systemd/system/humanfund-tee.service << 'EOF'
[Unit]
Description=The Human Fund TEE Enclave
After=network.target

[Service]
Type=forking
ExecStart=/opt/humanfund/boot.sh
Restart=no
Environment=PATH=/opt/humanfund/venv/bin:/usr/local/bin:/usr/bin:/bin
WorkingDirectory=/opt/humanfund

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable humanfund-tee.service
echo "  systemd service installed and enabled"

# ─── Cleanup ─────────────────────────────────────────────────────────────

echo ""
echo "═══ Cleaning up ═══"
rm -rf /tmp/llama.cpp
apt-get clean
echo "  Build artifacts cleaned"

echo ""
echo "═══ Setup complete ═══"
echo "  Install dir: $INSTALL_DIR"
echo "  Model: $MODEL_PATH"
echo "  llama-server: $INSTALL_DIR/llama-server"
echo "  Enclave code: $ENCLAVE_DIR"
echo "  Boot script: $INSTALL_DIR/boot.sh"
echo ""
echo "Next steps:"
echo "  1. Verify GPU: nvidia-smi"
echo "  2. Create disk image from this VM's boot disk"
echo "  3. Boot a new VM from the image and extract RTMR measurements"
echo "  4. Register the image key on-chain"
