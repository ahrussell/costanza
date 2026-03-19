#!/bin/bash
# Start llama-server (GPU) and the enclave runner inside the TEE container.
# The model must be mounted at $MODEL_PATH by the runner before boot.
# Verifies SHA-256 against the hash baked into the image.

set -e

echo "=== The Human Fund — TEE Enclave (GPU) ==="

# Check NVIDIA GPU
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || {
  echo "WARNING: nvidia-smi not available — falling back to CPU mode"
  GPU_LAYERS=0
}

# Verify model is present
if [ ! -f "$MODEL_PATH" ]; then
  echo "FATAL: Model not found at $MODEL_PATH"
  echo "  The runner must mount the model file before booting the TEE."
  echo "  Expected: $MODEL_PATH"
  echo "  SHA-256:  $MODEL_SHA256"
  exit 1
fi

# Verify model integrity
echo "Verifying model SHA-256..."
ACTUAL_SHA=$(sha256sum "$MODEL_PATH" | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$MODEL_SHA256" ]; then
  echo "FATAL: model hash mismatch!"
  echo "  expected: $MODEL_SHA256"
  echo "  got:      $ACTUAL_SHA"
  exit 1
fi
echo "Model verified: $(du -h "$MODEL_PATH" | cut -f1)"

# Start llama-server with GPU acceleration
# -ngl $GPU_LAYERS: offload layers to GPU (-1 = all)
# -c 16384: context window
llama-server \
  -m "$MODEL_PATH" \
  -ngl "${GPU_LAYERS:--1}" \
  -c 16384 \
  --host 0.0.0.0 \
  --port "$LLAMA_SERVER_PORT" \
  2>&1 | sed 's/^/[llama] /' &

LLAMA_PID=$!
echo "llama-server started (PID $LLAMA_PID, GPU layers: ${GPU_LAYERS:--1})"

# Start the enclave runner (it handles waiting for llama-server internally)
python3 enclave_runner.py
