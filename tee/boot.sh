#!/bin/bash
# The Human Fund — TEE VM Boot Script
#
# Runs at VM startup (via systemd or GCP startup-script metadata).
# Measures enclave code and model weights into RTMR[3], then starts services.
#
# Trust chain:
#   RTMR[1]+[2] attest the boot loader + kernel (measured by firmware)
#   → This script is part of the measured rootfs
#   → It extends RTMR[3] with hashes of enclave code and model weights
#   → A modified script would change RTMR[2], failing verification
#   → Modified enclave code would change RTMR[3], failing verification

set -euo pipefail

ENCLAVE_DIR="/opt/humanfund/enclave"
MODEL_DIR="/opt/humanfund/model"
LLAMA_SERVER="/opt/humanfund/llama-server"
RTMR_BASE="/sys/kernel/config/tsm/rtmrs"
LOG_PREFIX="[humanfund-boot]"

echo "$LOG_PREFIX Starting The Human Fund TEE boot sequence..."

# ─── Step 1: Measure enclave code into RTMR[3] ──────────────────────────

echo "$LOG_PREFIX Measuring enclave code into RTMR[3]..."

# Hash all Python files in deterministic order (sorted paths, concatenated content)
CODE_HASH=$(find "$ENCLAVE_DIR" -type f -name '*.py' | sort | xargs cat | sha384sum | awk '{print $1}')
echo "$LOG_PREFIX   Code hash (SHA-384): ${CODE_HASH:0:32}..."

# Extend RTMR[3] via configfs-tsm
if [ -d "$RTMR_BASE" ]; then
    RTMR_ENTRY="$RTMR_BASE/humanfund-code"
    mkdir -p "$RTMR_ENTRY"
    echo 3 > "$RTMR_ENTRY/index"
    echo -n "$CODE_HASH" | xxd -r -p > "$RTMR_ENTRY/digest"
    echo "$LOG_PREFIX   RTMR[3] extended with code hash"
else
    echo "$LOG_PREFIX   WARNING: configfs-tsm not available, skipping RTMR extension (mock mode)"
fi

# ─── Step 2: Verify and measure model weights ───────────────────────────

echo "$LOG_PREFIX Verifying model weights..."

MODEL_FILE=$(find "$MODEL_DIR" -name '*.gguf' | head -1)
if [ -z "$MODEL_FILE" ]; then
    echo "$LOG_PREFIX ERROR: No .gguf model file found in $MODEL_DIR"
    exit 1
fi

# Verify model hash against pinned values in enclave code
python3 -c "
import sys
sys.path.insert(0, '$ENCLAVE_DIR/..')
from enclave.model_config import verify_model
verify_model('$MODEL_FILE')
" || {
    echo "$LOG_PREFIX ERROR: Model verification failed!"
    exit 1
}

# Hash model for RTMR[3] extension
echo "$LOG_PREFIX Hashing model for RTMR[3] (this may take ~30-60 seconds)..."
MODEL_HASH=$(sha384sum "$MODEL_FILE" | awk '{print $1}')
echo "$LOG_PREFIX   Model hash (SHA-384): ${MODEL_HASH:0:32}..."

if [ -d "$RTMR_BASE" ]; then
    RTMR_ENTRY="$RTMR_BASE/humanfund-model"
    mkdir -p "$RTMR_ENTRY"
    echo 3 > "$RTMR_ENTRY/index"
    echo -n "$MODEL_HASH" | xxd -r -p > "$RTMR_ENTRY/digest"
    echo "$LOG_PREFIX   RTMR[3] extended with model hash"
else
    echo "$LOG_PREFIX   WARNING: configfs-tsm not available, skipping RTMR extension (mock mode)"
fi

# ─── Step 3: Start llama-server ──────────────────────────────────────────

echo "$LOG_PREFIX Starting llama-server..."

# Detect GPU and activate Confidential Computing (required for TDX VMs)
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo "unknown")
    echo "$LOG_PREFIX   GPU detected: $GPU_INFO"

    # Activate CC GPU Ready State — without this, CUDA silently fails and
    # llama.cpp falls back to CPU inference without any obvious error
    echo "$LOG_PREFIX   Activating Confidential Computing GPU Ready State..."
    nvidia-smi conf-compute -srs 1 2>/dev/null || true
    sleep 2
    CC_STATE=$(nvidia-smi conf-compute -grs 2>&1 | grep -o 'ready\|not-ready' || echo "unknown")
    echo "$LOG_PREFIX   CC GPU state: $CC_STATE"
    if [ "$CC_STATE" = "not-ready" ]; then
        echo "$LOG_PREFIX   WARNING: CC GPU not ready, retrying..."
        nvidia-smi conf-compute -srs 1
        sleep 5
    fi

    GPU_LAYERS="${GPU_LAYERS:--1}"  # -1 = all layers on GPU
    LLAMA_ARGS="-ngl $GPU_LAYERS"
else
    echo "$LOG_PREFIX   No GPU detected, using CPU inference"
    LLAMA_ARGS=""
fi

nohup "$LLAMA_SERVER" \
    -m "$MODEL_FILE" \
    $LLAMA_ARGS \
    -c 16384 \
    --host 127.0.0.1 --port 8080 \
    > /var/log/llama-server.log 2>&1 &

LLAMA_PID=$!
echo "$LOG_PREFIX   llama-server started (PID=$LLAMA_PID)"

# Wait for llama-server to be ready
echo "$LOG_PREFIX   Waiting for llama-server to load model..."
for i in $(seq 1 120); do
    if curl -s http://127.0.0.1:8080/health 2>/dev/null | grep -q '"status"'; then
        echo "$LOG_PREFIX   llama-server ready after $((i * 5))s"
        break
    fi
    if ! kill -0 $LLAMA_PID 2>/dev/null; then
        echo "$LOG_PREFIX ERROR: llama-server exited unexpectedly"
        cat /var/log/llama-server.log | tail -20
        exit 1
    fi
    sleep 5
done

# Verify model is actually on GPU (detect silent CPU fallback)
if command -v nvidia-smi &>/dev/null; then
    GPU_MEM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
    echo "$LOG_PREFIX   GPU memory used: ${GPU_MEM:-0} MiB"
    if [ -n "$GPU_MEM" ] && [ "$GPU_MEM" -lt 1000 ]; then
        echo "$LOG_PREFIX FATAL: Model not loaded on GPU (only ${GPU_MEM} MiB used). Silent CPU fallback!"
        echo "$LOG_PREFIX CC state: $(nvidia-smi conf-compute -grs 2>&1)"
        tail -20 /var/log/llama-server.log
        exit 1
    fi
fi

# ─── Step 4: Start enclave runner ────────────────────────────────────────

echo "$LOG_PREFIX Starting enclave runner on 127.0.0.1:8090..."

cd /opt/humanfund
ENCLAVE_HOST=127.0.0.1 ENCLAVE_PORT=8090 \
    nohup python3 -u -m enclave.enclave_runner \
    > /var/log/enclave-runner.log 2>&1 &

ENCLAVE_PID=$!
echo "$LOG_PREFIX   enclave_runner started (PID=$ENCLAVE_PID)"

# Wait for enclave runner health
for i in $(seq 1 24); do
    if curl -s http://127.0.0.1:8090/health 2>/dev/null | grep -q '"ok"'; then
        echo "$LOG_PREFIX   Enclave runner ready after $((i * 5))s"
        break
    fi
    sleep 5
done

echo "$LOG_PREFIX Boot complete. Enclave ready for inference."
