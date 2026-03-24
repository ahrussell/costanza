#!/bin/bash
# The Human Fund — CPU TEE VM Setup Script
#
# Same as setup_gpu.sh but without NVIDIA/CUDA. Builds llama.cpp for CPU only.
# Use for cheaper inference (~22 min/epoch on c3-standard-4).
#
# Usage:
#   sudo bash setup_cpu.sh

set -euo pipefail

INSTALL_DIR="/opt/humanfund"
MODEL_DIR="$INSTALL_DIR/model"
ENCLAVE_DIR="$INSTALL_DIR/enclave"
LLAMA_CPP_TAG="b5170"

# DeepSeek R1 Distill Llama 70B Q4_K_M (same model, CPU inference)
MODEL_URL="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Llama-70B-GGUF/resolve/main/DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf"
MODEL_SHA256="a4b1781e2f4ee59a0c048b236c5765e6c4b770c6c6a4e1f02ba42e1daae2dfe2"
MODEL_FILENAME="DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf"

echo "═══ The Human Fund — CPU TEE Setup ═══"

# ─── System dependencies ─────────────────────────────────────────────────

apt-get update -qq
apt-get install -y -qq cmake git build-essential python3 python3-pip python3-venv curl xxd

# ─── Build llama.cpp (CPU only) ──────────────────────────────────────────

echo "═══ Building llama.cpp (CPU) ═══"

cd /tmp
if [ ! -d "llama.cpp" ]; then
    git clone --depth 1 --branch "$LLAMA_CPP_TAG" https://github.com/ggerganov/llama.cpp.git
fi
cd llama.cpp
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build . --config Release -j$(nproc)

mkdir -p "$INSTALL_DIR"
cp bin/llama-server "$INSTALL_DIR/llama-server"
chmod +x "$INSTALL_DIR/llama-server"

# ─── Python environment ──────────────────────────────────────────────────

python3 -m venv "$INSTALL_DIR/venv"
source "$INSTALL_DIR/venv/bin/activate"
pip install --quiet flask pycryptodome eth_abi

# ─── Download model ──────────────────────────────────────────────────────

echo "═══ Downloading model weights ═══"

mkdir -p "$MODEL_DIR"
MODEL_PATH="$MODEL_DIR/$MODEL_FILENAME"

if [ ! -f "$MODEL_PATH" ]; then
    echo "  Downloading $MODEL_FILENAME (~42.5 GB)..."
    curl -L -o "$MODEL_PATH" "$MODEL_URL"
fi

ACTUAL_HASH=$(sha256sum "$MODEL_PATH" | awk '{print $1}')
if [ "$ACTUAL_HASH" != "$MODEL_SHA256" ]; then
    echo "ERROR: Model hash mismatch! Expected=$MODEL_SHA256 Actual=$ACTUAL_HASH"
    exit 1
fi
echo "  Model verified: ${ACTUAL_HASH:0:16}..."

# ─── Install enclave code + boot script ──────────────────────────────────

mkdir -p "$ENCLAVE_DIR"
[ -d "/tmp/enclave" ] && cp -r /tmp/enclave/* "$ENCLAVE_DIR/"
[ -f "/tmp/boot.sh" ] && cp /tmp/boot.sh "$INSTALL_DIR/boot.sh" && chmod +x "$INSTALL_DIR/boot.sh"

# systemd service
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

# ─── Cleanup ─────────────────────────────────────────────────────────────

rm -rf /tmp/llama.cpp
apt-get clean

echo "═══ CPU Setup complete ═══"
echo "  Model: $MODEL_PATH"
echo "  llama-server: $INSTALL_DIR/llama-server (CPU only)"
