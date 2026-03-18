#!/bin/bash
# Start llama-server and the enclave runner inside the TEE container.
# Downloads model on first boot, verifies SHA-256 against the hash baked into
# the image (which is covered by the RTMR attestation chain).

set -e

echo "=== The Human Fund — TEE Enclave ==="

# Download model if not already present
if [ ! -f "$MODEL_PATH" ]; then
  echo "Downloading model from $MODEL_URL ..."
  curl -L -o "$MODEL_PATH" "$MODEL_URL"
fi

# Verify model integrity
echo "Verifying model SHA-256..."
ACTUAL_SHA=$(sha256sum "$MODEL_PATH" | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$MODEL_SHA256" ]; then
  echo "FATAL: model hash mismatch!"
  echo "  expected: $MODEL_SHA256"
  echo "  got:      $ACTUAL_SHA"
  rm -f "$MODEL_PATH"
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
