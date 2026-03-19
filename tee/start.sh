#!/bin/bash
# Start llama-server and the enclave runner inside the TEE container.
# The model must be mounted at $MODEL_PATH by the runner before boot.
# Verifies SHA-256 against the hash baked into the image (covered by RTMR
# attestation chain). The runner provides the model file however they want —
# the binary only cares that sha256(file) == expected hash.

set -e

echo "=== The Human Fund — TEE Enclave ==="

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

# Start llama-server in background
# CPU-only: no -ngl flag. Context 16384 tokens for the 14B model.
llama-server \
  -m "$MODEL_PATH" \
  -c 16384 \
  --host 0.0.0.0 \
  --port "$LLAMA_SERVER_PORT" \
  2>&1 | sed 's/^/[llama] /' &

LLAMA_PID=$!
echo "llama-server started (PID $LLAMA_PID)"

# Start the enclave runner (it handles waiting for llama-server internally)
python3 enclave_runner.py
