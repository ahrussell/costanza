#!/bin/bash
# Run the full gauntlet on the GCP VM
# Downloads models, runs each one through 75 epochs, merges results
#
# Usage: Upload this + gauntlet.py to the VM, then run:
#   sudo bash /tmp/run_gauntlet_vm.sh

set -euo pipefail

MODEL_DIR="/mnt/ssd"
SERVER_PORT=8080
SERVER_URL="http://localhost:${SERVER_PORT}"
RESULTS_DIR="/tmp/gauntlet_results"
LLAMA_SERVER="/usr/local/bin/llama-server"
PROJECT_DIR="/tmp/thehumanfund"

mkdir -p "$RESULTS_DIR"

# ─── Ensure CC GPU ready state ──────────────────────────────────────────
echo "Setting GPU CC ready state..."
nvidia-smi conf-compute -srs 1 2>/dev/null || true
nvidia-smi -pm 1 2>/dev/null || true
sleep 2

# Verify GPU is accessible
python3 -c "
import ctypes
cuda = ctypes.CDLL('libcuda.so.1')
result = cuda.cuInit(0)
if result != 0:
    print(f'ERROR: CUDA init failed with code {result}')
    exit(1)
print('GPU OK: CUDA initialized')
"

# ─── Model definitions ──────────────────────────────────────────────────
declare -A MODELS
declare -A MODEL_URLS
declare -A MODEL_FILES

MODELS[deepseek-r1-70b]="DeepSeek R1 Distill 70B"
MODEL_FILES[deepseek-r1-70b]="DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf"
MODEL_URLS[deepseek-r1-70b]="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Llama-70B-GGUF/resolve/main/DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf"

MODELS[llama-3.3-70b]="Llama 3.3 70B Instruct"
MODEL_FILES[llama-3.3-70b]="Llama-3.3-70B-Instruct-Q4_K_M.gguf"
MODEL_URLS[llama-3.3-70b]="https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/resolve/main/Llama-3.3-70B-Instruct-Q4_K_M.gguf"

MODELS[qwq-32b]="Qwen QwQ 32B"
MODEL_FILES[qwq-32b]="QwQ-32B-Q4_K_M.gguf"
MODEL_URLS[qwq-32b]="https://huggingface.co/Qwen/QwQ-32B-GGUF/resolve/main/qwq-32b-q4_k_m.gguf"

MODEL_ORDER="deepseek-r1-70b llama-3.3-70b qwq-32b"

# ─── Download models ────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  DOWNLOADING MODELS"
echo "═══════════════════════════════════════════════════════════════"

for model_key in $MODEL_ORDER; do
    model_file="${MODEL_DIR}/${MODEL_FILES[$model_key]}"
    if [ -f "$model_file" ]; then
        size=$(du -sh "$model_file" | cut -f1)
        echo "  ✓ ${MODELS[$model_key]}: already downloaded ($size)"
    else
        echo "  ↓ Downloading ${MODELS[$model_key]}..."
        wget -q --show-progress -O "$model_file" "${MODEL_URLS[$model_key]}"
        size=$(du -sh "$model_file" | cut -f1)
        echo "  ✓ Downloaded: $size"
    fi
done

echo ""
echo "All models ready. Disk usage:"
du -sh ${MODEL_DIR}/*.gguf
df -h ${MODEL_DIR}
echo ""

# ─── Run gauntlet for each model ────────────────────────────────────────

kill_server() {
    pkill -f llama-server 2>/dev/null || true
    sleep 3
    pkill -9 -f llama-server 2>/dev/null || true
    sleep 2
}

wait_for_server() {
    local max_wait=300  # 5 minutes for large models
    local waited=0
    echo "  Waiting for server to load model..."
    while [ $waited -lt $max_wait ]; do
        if curl -s "${SERVER_URL}/health" 2>/dev/null | grep -q '"ok"'; then
            echo "  Server ready after ${waited}s"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
        if [ $((waited % 30)) -eq 0 ]; then
            echo "  Still loading... (${waited}s)"
        fi
    done
    echo "  ERROR: Server did not become ready after ${max_wait}s"
    return 1
}

echo "═══════════════════════════════════════════════════════════════"
echo "  RUNNING GAUNTLET"
echo "═══════════════════════════════════════════════════════════════"
echo ""

GAUNTLET_START=$(date +%s)

for model_key in $MODEL_ORDER; do
    model_file="${MODEL_DIR}/${MODEL_FILES[$model_key]}"
    model_name="${MODELS[$model_key]}"
    output_file="${RESULTS_DIR}/${model_key}.json"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  MODEL: ${model_name} (${model_key})"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Kill any existing server
    kill_server

    # Start llama-server with this model
    echo "  Starting llama-server..."
    nohup ${LLAMA_SERVER} \
        -m "$model_file" \
        -ngl 99 \
        -c 8192 \
        --host 0.0.0.0 \
        --port ${SERVER_PORT} \
        > /tmp/llama_${model_key}.log 2>&1 &

    SERVER_PID=$!
    echo "  Server PID: ${SERVER_PID}"

    # Wait for server to be ready
    if ! wait_for_server; then
        echo "  SKIPPING ${model_name} — server failed to start"
        echo "  Log tail:"
        tail -20 /tmp/llama_${model_key}.log
        kill_server
        continue
    fi

    # Check GPU memory usage
    echo "  GPU memory:"
    nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader

    # Run the gauntlet
    MODEL_START=$(date +%s)
    echo "  Running 75-epoch gauntlet..."

    cd "$PROJECT_DIR"
    python3 scripts/gauntlet.py run \
        --model-name "$model_name" \
        --server-url "$SERVER_URL" \
        --epochs 75 \
        --output "$output_file" \
        2>&1 | tee /tmp/gauntlet_${model_key}.log

    MODEL_END=$(date +%s)
    MODEL_ELAPSED=$((MODEL_END - MODEL_START))
    echo ""
    echo "  ${model_name} completed in $((MODEL_ELAPSED / 60))m $((MODEL_ELAPSED % 60))s"

    # Kill server before next model
    kill_server
done

GAUNTLET_END=$(date +%s)
TOTAL_ELAPSED=$((GAUNTLET_END - GAUNTLET_START))

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  MERGING RESULTS"
echo "═══════════════════════════════════════════════════════════════"

# Merge all results into arena format
cd "$PROJECT_DIR"
RESULT_FILES=""
for model_key in $MODEL_ORDER; do
    f="${RESULTS_DIR}/${model_key}.json"
    if [ -f "$f" ]; then
        if [ -n "$RESULT_FILES" ]; then
            RESULT_FILES="${RESULT_FILES},"
        fi
        RESULT_FILES="${RESULT_FILES}${f}"
    fi
done

python3 scripts/gauntlet.py merge \
    --input-files "$RESULT_FILES" \
    --output "${RESULTS_DIR}/arena_gauntlet.json"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  GAUNTLET COMPLETE"
echo "  Total time: $((TOTAL_ELAPSED / 60))m $((TOTAL_ELAPSED % 60))s"
echo "  Results: ${RESULTS_DIR}/"
echo "═══════════════════════════════════════════════════════════════"

ls -lh ${RESULTS_DIR}/*.json
