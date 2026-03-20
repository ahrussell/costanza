#!/usr/bin/env python3
"""
Create a GCP disk image snapshot with llama-server + model pre-installed.

Boots a TDX confidential VM, runs the full setup (install deps, build llama.cpp,
download model), then creates a disk image from the boot disk. Future e2e_test.py
runs will boot from this image in ~1-2 min instead of ~15 min.

Usage:
    source .venv/bin/activate
    python scripts/create_snapshot.py           # GPU snapshot (default)
    python scripts/create_snapshot.py --cpu     # CPU snapshot
    python scripts/create_snapshot.py --force   # Overwrite existing image
"""

import argparse
import os
import subprocess
import sys
import time

GCP_PROJECT = os.environ.get("GCP_PROJECT", "the-human-fund")
GCP_ZONE = os.environ.get("GCP_ZONE", "us-central1-a")
GCP_VM_NAME = "humanfund-snapshot"

GCP_MACHINE_TYPE_CPU = "c3-standard-4"
GCP_MACHINE_TYPE_GPU = "a3-highgpu-1g"

MODEL_URL = "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
MODEL_SHA256 = "0b319bd0572f2730bfe11cc751defe82045fad5085b4e60591ac2cd2d9633181"


def run_cmd(cmd, check=True, timeout=300):
    print(f"  $ {cmd[:120]}{'...' if len(cmd) > 120 else ''}")
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode != 0:
        print(f"  STDERR: {result.stderr[:500] if result.stderr else '(none)'}")
        raise RuntimeError(f"Command failed (exit {result.returncode}): {cmd[:80]}")
    return result.stdout.strip()


def gcloud(cmd, **kwargs):
    return run_cmd(f"gcloud {cmd} --project={GCP_PROJECT}", **kwargs)


def image_exists(image_name):
    try:
        result = gcloud(f"compute images describe {image_name} --format='value(status)'", check=False)
        return "READY" in result
    except Exception:
        return False


def get_startup_script(use_gpu):
    if use_gpu:
        return f"""#!/bin/bash
set -e
exec > /tmp/startup.log 2>&1
echo "=== Starting GPU setup at $(date) ==="

apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv cmake build-essential git wget libcurl4-openssl-dev

python3 -m venv /opt/humanfund-venv
source /opt/humanfund-venv/bin/activate
pip install flask web3 requests

echo "Installing NVIDIA drivers..."
apt-get install -y -qq linux-headers-$(uname -r) nvidia-driver-575-open nvidia-utils-575 2>/dev/null || true
apt-get install -y -qq nvidia-cuda-toolkit 2>/dev/null || true

echo "Building llama.cpp with CUDA..."
cd /tmp
git clone --depth 1 --branch b5170 https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=90
cmake --build build --config Release -j$(nproc) --target llama-server
cp build/bin/llama-server /usr/local/bin/

echo "Downloading model..."
mkdir -p /models
wget -q -O /models/model.gguf "{MODEL_URL}"

echo "Verifying model hash..."
ACTUAL_HASH=$(sha256sum /models/model.gguf | cut -d' ' -f1)
if [ "$ACTUAL_HASH" != "{MODEL_SHA256}" ]; then
    echo "FATAL: Model hash mismatch!"
    exit 1
fi
echo "Model hash verified."

echo "Starting llama-server (GPU)..."
nohup llama-server -m /models/model.gguf -c 4096 --host 0.0.0.0 --port 8080 -ngl 99 > /tmp/llama.log 2>&1 &

echo "Waiting for llama-server..."
for i in $(seq 1 120); do
    if curl -s http://127.0.0.1:8080/health | grep -q ok; then
        echo "llama-server ready after $((i*5))s"
        break
    fi
    sleep 5
done

echo "=== Setup complete at $(date) ==="
"""
    else:
        return f"""#!/bin/bash
set -e
exec > /tmp/startup.log 2>&1
echo "=== Starting CPU setup at $(date) ==="

apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv cmake build-essential git wget libcurl4-openssl-dev

python3 -m venv /opt/humanfund-venv
source /opt/humanfund-venv/bin/activate
pip install flask web3 requests

echo "Building llama.cpp..."
cd /tmp
git clone --depth 1 --branch b5170 https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j$(nproc) --target llama-server
cp build/bin/llama-server /usr/local/bin/

echo "Downloading model..."
mkdir -p /models
wget -q -O /models/model.gguf "{MODEL_URL}"

echo "Verifying model hash..."
ACTUAL_HASH=$(sha256sum /models/model.gguf | cut -d' ' -f1)
if [ "$ACTUAL_HASH" != "{MODEL_SHA256}" ]; then
    echo "FATAL: Model hash mismatch!"
    exit 1
fi
echo "Model hash verified."

echo "Starting llama-server (CPU)..."
nohup llama-server -m /models/model.gguf -c 4096 --host 0.0.0.0 --port 8080 -t $(nproc) > /tmp/llama.log 2>&1 &

echo "Waiting for llama-server..."
for i in $(seq 1 120); do
    if curl -s http://127.0.0.1:8080/health | grep -q ok; then
        echo "llama-server ready after $((i*5))s"
        break
    fi
    sleep 5
done

echo "=== Setup complete at $(date) ==="
"""


def create_vm(use_gpu):
    machine_type = GCP_MACHINE_TYPE_GPU if use_gpu else GCP_MACHINE_TYPE_CPU

    # Check if VM already exists
    try:
        result = gcloud(f"compute instances describe {GCP_VM_NAME} --zone={GCP_ZONE} --format='value(status)'", check=False)
        if result.strip():
            print(f"  VM '{GCP_VM_NAME}' already exists (status={result.strip()}), deleting...")
            gcloud(f"compute instances delete {GCP_VM_NAME} --zone={GCP_ZONE} --quiet", timeout=120)
    except Exception:
        pass

    startup_path = "/tmp/humanfund_snapshot_startup.sh"
    with open(startup_path, "w") as f:
        f.write(get_startup_script(use_gpu))

    print(f"Creating {machine_type} TDX spot instance...")
    gcloud(
        f"compute instances create {GCP_VM_NAME} "
        f"--zone={GCP_ZONE} "
        f"--machine-type={machine_type} "
        f"--confidential-compute-type=TDX "
        f"--provisioning-model=SPOT "
        f"--instance-termination-action=STOP "
        f'--min-cpu-platform="Intel Sapphire Rapids" '
        f"--image-family=ubuntu-2404-lts-amd64 "
        f"--image-project=ubuntu-os-cloud "
        f"--boot-disk-size=50GB "
        f"--metadata-from-file=startup-script={startup_path}",
        timeout=120
    )

    ip = gcloud(
        f"compute instances describe {GCP_VM_NAME} --zone={GCP_ZONE} "
        f"--format='value(networkInterfaces[0].accessConfigs[0].natIP)'"
    )
    print(f"  VM created: {ip}")
    return ip


def wait_for_setup():
    print("\nWaiting for setup to complete (apt install + build + model download)...")
    print("  This takes ~10-15 min for GPU, ~10 min for CPU")

    for i in range(90):  # 45 min max
        try:
            result = gcloud(
                f"compute ssh {GCP_VM_NAME} --zone={GCP_ZONE} "
                f"--command='curl -s http://127.0.0.1:8080/health 2>/dev/null || echo NOT_READY'",
                check=False, timeout=30
            )
            if '"status":"ok"' in result or '"status": "ok"' in result:
                print(f"  llama-server ready after {i * 30}s")
                return True
            elif "NOT_READY" in result:
                log = gcloud(
                    f"compute ssh {GCP_VM_NAME} --zone={GCP_ZONE} "
                    f"--command='tail -1 /tmp/startup.log 2>/dev/null || echo no_log'",
                    check=False, timeout=15
                )
                print(f"  [{i * 30}s] Waiting... {log[:80]}")
        except Exception as e:
            print(f"  [{i * 30}s] SSH not ready: {str(e)[:60]}")
        time.sleep(30)

    print("  TIMEOUT after 45 min")
    return False


def create_image(image_name, use_gpu):
    print(f"\nCreating disk image '{image_name}'...")

    # Stop VM (--discard-local-ssd needed for GPU, harmless for CPU)
    print("  Stopping VM...")
    gcloud(f"compute instances stop {GCP_VM_NAME} --zone={GCP_ZONE} --discard-local-ssd=true", timeout=180)

    # Create image from boot disk
    print("  Creating image from boot disk...")
    gcloud(
        f"compute images create {image_name} "
        f"--source-disk={GCP_VM_NAME} --source-disk-zone={GCP_ZONE} "
        f"--family=humanfund-tee --force",
        timeout=600
    )
    print(f"  Image '{image_name}' created!")


def delete_vm():
    print("\nDeleting VM...")
    try:
        gcloud(f"compute instances delete {GCP_VM_NAME} --zone={GCP_ZONE} --quiet", timeout=120)
        print("  VM deleted")
    except Exception as e:
        print(f"  Failed: {e}")


def main():
    parser = argparse.ArgumentParser(description="Create GCP disk image snapshot for fast e2e boot")
    parser.add_argument("--cpu", action="store_true", help="Create CPU snapshot (default: GPU)")
    parser.add_argument("--force", action="store_true", help="Overwrite existing image")
    parser.add_argument("--keep-vm", action="store_true", help="Don't delete VM after snapshot")
    args = parser.parse_args()

    use_gpu = not args.cpu
    image_name = f"humanfund-tee-{'gpu' if use_gpu else 'cpu'}-14b"
    mode = "GPU (a3-highgpu-1g, H100)" if use_gpu else "CPU (c3-standard-4)"

    print(f"Creating snapshot: {image_name}")
    print(f"Mode: {mode}")

    if image_exists(image_name) and not args.force:
        print(f"\nImage '{image_name}' already exists. Use --force to overwrite.")
        return 0

    try:
        create_vm(use_gpu)
        if not wait_for_setup():
            print("FATAL: Setup did not complete")
            delete_vm()
            return 1

        create_image(image_name, use_gpu)

        if not args.keep_vm:
            delete_vm()

        print(f"\n{'=' * 50}")
        print(f"  Snapshot created: {image_name}")
        print(f"  e2e_test.py will auto-detect and use it")
        print(f"{'=' * 50}")
        return 0

    except Exception as e:
        print(f"\nFATAL: {e}")
        if not args.keep_vm:
            delete_vm()
        return 1


if __name__ == "__main__":
    sys.exit(main())
