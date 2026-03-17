#!/bin/bash
# Start llama-server and the enclave runner inside the TEE container.
# The enclave runner waits for llama-server to be healthy before accepting requests.

set -e

echo "=== The Human Fund — TEE Enclave ==="
echo "Model: $MODEL_PATH"
echo "Llama port: $LLAMA_SERVER_PORT"
echo "Enclave port: $ENCLAVE_PORT"

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
