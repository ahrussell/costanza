#!/usr/bin/env bash
# RunPod first-time setup for The Human Fund
# Run this once after launching a new pod with a Network Volume.
#
# Usage: bash runpod-setup.sh
# Re-running is safe — it skips already-completed steps.

set -euo pipefail

VOLUME="/workspace"
MODEL_DIR="$VOLUME/models"
LLAMA_DIR="$VOLUME/llama.cpp"
MODEL_NAME="DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf"
MODEL_URL="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Llama-70B-GGUF/resolve/main/$MODEL_NAME"

# --- Preflight checks ---
if [ ! -d "$VOLUME" ]; then
  echo "ERROR: Network volume not mounted at $VOLUME"
  echo "Make sure you attached a Network Volume when creating the pod."
  exit 1
fi

if ! command -v nvidia-smi &>/dev/null; then
  echo "WARNING: nvidia-smi not found. GPU acceleration may not work."
else
  echo "GPU detected:"
  nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader
fi

# --- Install build dependencies ---
echo ""
echo "=== Installing build dependencies ==="
apt-get update -qq && apt-get install -y -qq cmake build-essential git wget curl > /dev/null 2>&1
echo "Done."

# --- Build llama.cpp ---
echo ""
echo "=== Setting up llama.cpp ==="
if [ -f "$LLAMA_DIR/build/bin/llama-cli" ]; then
  echo "llama.cpp already built, skipping. Delete $LLAMA_DIR to rebuild."
else
  if [ -d "$LLAMA_DIR" ]; then
    echo "Updating existing llama.cpp..."
    cd "$LLAMA_DIR" && git pull
  else
    echo "Cloning llama.cpp..."
    git clone https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
  fi
  cd "$LLAMA_DIR"
  echo "Building with CUDA support..."
  cmake -B build -DGGML_CUDA=ON 2>&1 | tail -5
  cmake --build build --config Release -j$(nproc) 2>&1 | tail -5
  echo "Build complete."
fi

# --- Download model ---
echo ""
echo "=== Downloading model ==="
mkdir -p "$MODEL_DIR"
if [ -f "$MODEL_DIR/$MODEL_NAME" ]; then
  EXPECTED_SIZE=42500000000  # ~42.5GB, approximate
  ACTUAL_SIZE=$(stat -c%s "$MODEL_DIR/$MODEL_NAME" 2>/dev/null || stat -f%z "$MODEL_DIR/$MODEL_NAME" 2>/dev/null)
  if [ "$ACTUAL_SIZE" -gt "$EXPECTED_SIZE" ]; then
    echo "Model already downloaded ($((ACTUAL_SIZE / 1073741824))GB), skipping."
  else
    echo "Model file exists but looks incomplete ($((ACTUAL_SIZE / 1073741824))GB). Re-downloading..."
    wget -c -O "$MODEL_DIR/$MODEL_NAME" "$MODEL_URL"
  fi
else
  echo "Downloading $MODEL_NAME (~42.5GB)... this will take a while."
  wget -O "$MODEL_DIR/$MODEL_NAME" "$MODEL_URL"
fi

# --- Test inference ---
echo ""
echo "=== Running test inference ==="
echo "Prompt: 'What is 2+2? Answer in one sentence.'"
echo "---"
"$LLAMA_DIR/build/bin/llama-cli" \
  -m "$MODEL_DIR/$MODEL_NAME" \
  -ngl 99 \
  -c 2048 \
  -n 128 \
  -p "What is 2+2? Answer in one sentence." \
  --no-display-prompt \
  2>/dev/null
echo ""
echo "---"
echo ""
echo "=== Setup complete ==="
echo ""
echo "To run inference manually:"
echo "  $LLAMA_DIR/build/bin/llama-cli \\"
echo "    -m $MODEL_DIR/$MODEL_NAME \\"
echo "    -ngl 99 \\"
echo "    -c 4096 \\"
echo "    -p \"Your prompt here\" \\"
echo "    --no-display-prompt"
echo ""
echo "To start llama.cpp as a server:"
echo "  $LLAMA_DIR/build/bin/llama-server \\"
echo "    -m $MODEL_DIR/$MODEL_NAME \\"
echo "    -ngl 99 \\"
echo "    -c 4096 \\"
echo "    --host 0.0.0.0 --port 8080"
