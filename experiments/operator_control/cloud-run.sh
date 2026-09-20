#!/bin/bash
# Installed on the dedicated research VM only. No chain/cloud API access.
set -euo pipefail
cd /var/lib/operator-control
test ! -e results
for attempt in $(seq 1 30); do
    nvidia-smi conf-compute -srs 1 || true
    if nvidia-smi conf-compute -q | grep -q 'Ready State.*: Ready'; then
        break
    fi
    sleep 2
done
exec /opt/humanfund/venv/bin/python3 -u \
    operator-control/experiments/operator_control/run_pilot.py \
    --execute --out /var/lib/operator-control/results \
    --llama-bin /opt/humanfund/bin/llama-server \
    --model /models/NousResearch_Hermes-4-70B-Q6_K-00001-of-00002.gguf \
    --runtime-label "gce-image-id=7197721324033574862;image=humanfund-base-gpu-llama-b5270-hermes;worker=operator-control-20260920-spot"
