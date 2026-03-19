#!/bin/bash
# Setup script for GCP H100 TDX VM
# Installs NVIDIA drivers, CUDA, llama.cpp (CUDA), model, and enclave_runner
set -e

echo "=== GPU TDX VM Setup ==="
echo "$(date): Starting..."

# Install NVIDIA drivers + CUDA toolkit
echo "Installing NVIDIA drivers..."
apt-get update -qq
apt-get install -y -qq linux-headers-$(uname -r) software-properties-common
# Use the NVIDIA driver package that GCP recommends for H100
apt-get install -y -qq nvidia-driver-550 nvidia-cuda-toolkit 2>/dev/null || {
    echo "Trying alternative NVIDIA install..."
    add-apt-repository -y ppa:graphics-drivers/ppa
    apt-get update -qq
    apt-get install -y -qq nvidia-driver-550
}

# Install build tools
apt-get install -y -qq build-essential cmake git python3 python3-pip curl wget

# Install Python deps
pip3 install --break-system-packages flask requests 2>/dev/null || pip3 install flask requests

# Build llama.cpp with CUDA
echo "Building llama.cpp with CUDA..."
cd /tmp
if [ ! -d llama.cpp ]; then
    git clone --depth 1 --branch b5170 https://github.com/ggml-org/llama.cpp.git
fi
cd llama.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON
cmake --build build --config Release -j$(nproc) --target llama-server
cp build/bin/llama-server /usr/local/bin/
echo "llama-server built with CUDA support"

# Download model
echo "Downloading model..."
mkdir -p /models
if [ ! -f /models/model.gguf ]; then
    wget -q --show-progress -O /models/model.gguf \
        "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
fi

# Verify model hash
ACTUAL=$(sha256sum /models/model.gguf | cut -d' ' -f1)
EXPECTED="0b319bd0572f2730bfe11cc751defe82045fad5085b4e60591ac2cd2d9633181"
if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "FATAL: Model hash mismatch!"
    echo "  Expected: $EXPECTED"
    echo "  Got:      $ACTUAL"
    exit 1
fi
echo "Model verified: $(du -h /models/model.gguf | cut -f1)"

# Start llama-server with GPU
echo "Starting llama-server with GPU..."
nohup llama-server -m /models/model.gguf -ngl 99 -c 4096 --host 0.0.0.0 --port 8080 > /tmp/llama.log 2>&1 &
echo "llama-server started (PID $!)"

echo "$(date): Setup complete!"
echo "Run enclave_runner.py separately after uploading it."
