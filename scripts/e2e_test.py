#!/usr/bin/env python3
import os
os.environ["PYTHONUNBUFFERED"] = "1"
"""
The Human Fund — Full E2E Test on Base Sepolia

Tests the complete security model end-to-end:
  1. Deploy TheHumanFund + TdxVerifier to Base Sepolia
  2. Register GCP TDX image measurements (RTMR[1] + RTMR[2] + RTMR[3] — boot loader + kernel + application)
  3. Configure auction timing (short windows for testing)
  4. Spin up GCP TDX confidential VM with enclave_runner + llama-server
  5. Run full auction: startEpoch → commit → closeCommit → reveal → closeReveal → TEE inference → submitAuctionResult
  6. Verify on-chain: Automata DCAP + image registry + REPORTDATA binding all pass

Security properties verified:
  - Quote came from genuine Intel TDX hardware (Automata DCAP)
  - VM was running an approved boot loader + kernel + app code (RTMR[1] + RTMR[2] + RTMR[3])
  - Output was computed from the committed input hash (REPORTDATA binding)
  - Inference used the contract's randomness seed (prevents cherry-picking)
  - Only the auction winner can submit (msg.sender == winner)
  - Submission is within the execution window (timing enforcement)

Usage:
    source .venv/bin/activate
    python scripts/e2e_test.py

    # Skip deployment (reuse existing contracts):
    python scripts/e2e_test.py --fund-address 0x... --verifier-address 0x...  # TdxVerifier address

    # Skip VM creation (reuse existing VM):
    python scripts/e2e_test.py --vm-ip 1.2.3.4

Environment:
    PRIVATE_KEY       - Deployer/runner wallet private key
    RPC_URL           - Base Sepolia RPC (default: https://sepolia.base.org)
    GCP_PROJECT       - GCP project ID (default: the-human-fund)
    GCP_ZONE          - GCP zone (default: us-central1-a)
"""

import argparse
import hashlib
import json
import os
import requests
import subprocess
import sys
import time
from pathlib import Path

from web3 import Web3
from eth_account import Account

# ─── Config ──────────────────────────────────────────────────────────────

PROJECT_ROOT = Path(__file__).parent.parent
ABI_DIR = PROJECT_ROOT / "out"

RPC_URL = os.environ.get("RPC_URL", "https://sepolia.base.org")
GCP_PROJECT = os.environ.get("GCP_PROJECT", "the-human-fund")
GCP_ZONE = os.environ.get("GCP_ZONE", "us-central1-a")
GCP_VM_NAME = os.environ.get("GCP_VM_NAME", "humanfund-e2e")
# Default to GPU; set --cpu flag for CPU instance
GCP_MACHINE_TYPE_CPU = "c3-standard-4"   # 4 vCPU, 16 GB — CPU inference (~20-30 min)
GCP_MACHINE_TYPE_GPU = "a3-highgpu-1g"   # 1x H100 80GB — GPU inference (~30 sec)

# Set at runtime based on --cpu flag
GCP_MACHINE_TYPE = GCP_MACHINE_TYPE_GPU
USE_GPU = True

# Timing constants (adjusted at runtime based on CPU vs GPU)
# GPU: inference takes ~30s, so keep windows tight
EPOCH_DURATION_GPU = 1800     # 30 min (generous for SSH/inference overhead)
COMMIT_WINDOW_GPU = 60        # 1 min
REVEAL_WINDOW_GPU = 30        # 30 sec
EXECUTION_WINDOW_GPU = 1500   # 25 min

EPOCH_DURATION_CPU = 3600     # 60 min
COMMIT_WINDOW_CPU = 120       # 2 min
REVEAL_WINDOW_CPU = 60        # 1 min
EXECUTION_WINDOW_CPU = 2700   # 45 min

# Defaults (overridden in main())
EPOCH_DURATION = EPOCH_DURATION_GPU
COMMIT_WINDOW = COMMIT_WINDOW_GPU
REVEAL_WINDOW = REVEAL_WINDOW_GPU
EXECUTION_WINDOW = EXECUTION_WINDOW_GPU

BID_AMOUNT_ETH = 0.0001  # Minimum bid
SEED_AMOUNT_ETH = 0.0005  # Treasury seed (keep small for testnet)

# Production model: DeepSeek R1 Distill Llama 70B (Q4_K_M, 42.5GB GGUF)
MODEL_URL = "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Llama-70B-GGUF/resolve/main/DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf"
MODEL_SHA256 = "181a82a1d6d2fa24fe4db83a68eee030384986bdbdd4773ba76424e3a6eb9fd8"


def run_cmd(cmd, check=True, capture=True, timeout=300):
    """Run a shell command and return output."""
    print(f"  $ {cmd[:120]}{'...' if len(cmd) > 120 else ''}")
    result = subprocess.run(
        cmd, shell=True, capture_output=capture, text=True, timeout=timeout
    )
    if check and result.returncode != 0:
        print(f"  STDERR: {result.stderr[:500] if result.stderr else '(none)'}")
        raise RuntimeError(f"Command failed (exit {result.returncode}): {cmd[:80]}")
    return result.stdout.strip() if capture else ""


def gcloud(cmd, **kwargs):
    """Run a gcloud command with project/zone defaults."""
    return run_cmd(f"gcloud {cmd} --project={GCP_PROJECT}", **kwargs)


# ─── Step 1: Deploy Contracts ────────────────────────────────────────────

def deploy_contracts(w3, account):
    """Deploy TheHumanFund + TdxVerifier to Base Sepolia."""
    print("\n═══ STEP 1: Deploy Contracts ═══")

    # Build contracts first
    print("Building contracts...")
    run_cmd("forge build", timeout=120)

    # Load ABIs
    fund_artifact = json.loads((ABI_DIR / "TheHumanFund.sol" / "TheHumanFund.json").read_text())
    verifier_artifact = json.loads((ABI_DIR / "TdxVerifier.sol" / "TdxVerifier.json").read_text())

    deployer = account.address
    nonce = w3.eth.get_transaction_count(deployer)
    seed_wei = w3.to_wei(SEED_AMOUNT_ETH, "ether")

    # Deploy TheHumanFund first (TdxVerifier needs fund address)
    print(f"Deploying TheHumanFund (seed: {SEED_AMOUNT_ETH} ETH)...")
    fund_contract = w3.eth.contract(
        abi=fund_artifact["abi"],
        bytecode=fund_artifact["bytecode"]["object"]
    )
    # Constructor: (commissionBps, maxBid, endaomentFactory, weth, usdc, swapRouter, ethUsdFeed)
    # Use deployer as placeholder for Endaoment/DeFi addresses on testnet
    # ethUsdFeed must be address(0) — deployer is an EOA, calling latestRoundData() on it reverts
    ZERO_ADDR = "0x0000000000000000000000000000000000000000"
    tx = fund_contract.constructor(
        1000, w3.to_wei(0.0001, "ether"),
        deployer, deployer, deployer, deployer, ZERO_ADDR
    ).build_transaction({
        "from": deployer,
        "nonce": nonce,
        "value": seed_wei,
        "gas": 6_500_000,
        "maxFeePerGas": w3.eth.gas_price * 2,
        "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    fund_addr = receipt.contractAddress
    if receipt.status != 1:
        raise RuntimeError(f"Fund deployment failed! Status: {receipt.status}, gas: {receipt.gasUsed}")
    print(f"  TheHumanFund: {fund_addr} (gas: {receipt.gasUsed})")
    nonce += 1

    # Add test nonprofits
    fund = w3.eth.contract(address=fund_addr, abi=fund_artifact["abi"])
    test_nps = [
        ("GiveDirectly", "Cash transfers", b"27-1661997"),
        ("EFF", "Digital rights", b"04-3091431"),
        ("MSF", "Emergency medical care", b"13-3433452"),
    ]
    for np_name, np_desc, np_ein in test_nps:
        ein_bytes32 = np_ein.ljust(32, b'\x00')
        tx = fund.functions.addNonprofit(np_name, np_desc, ein_bytes32).build_transaction({
            "from": deployer, "nonce": nonce,
            "gas": 200_000,
            "maxFeePerGas": w3.eth.gas_price * 2,
            "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
        })
        signed = account.sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
        nonce += 1
    print(f"  Added {len(test_nps)} test nonprofits")

    # Deploy TdxVerifier (needs fund address)
    print(f"Deploying TdxVerifier...")
    verifier_contract = w3.eth.contract(
        abi=verifier_artifact["abi"],
        bytecode=verifier_artifact["bytecode"]["object"]
    )
    tx = verifier_contract.constructor(fund_addr).build_transaction({
        "from": deployer,
        "nonce": nonce,
        "gas": 1_000_000,
        "maxFeePerGas": w3.eth.gas_price * 2,
        "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    if receipt.status != 1:
        raise RuntimeError(f"Verifier deployment failed! Status: {receipt.status}, gas: {receipt.gasUsed}")
    verifier_addr = receipt.contractAddress
    print(f"  TdxVerifier: {verifier_addr} (gas: {receipt.gasUsed})")
    nonce += 1

    # Deploy AuctionManager
    print(f"Deploying AuctionManager...")
    am_artifact = json.loads((ABI_DIR / "AuctionManager.sol" / "AuctionManager.json").read_text())
    am_contract = w3.eth.contract(abi=am_artifact["abi"], bytecode=am_artifact["bytecode"]["object"])
    tx = am_contract.constructor(fund_addr).build_transaction({
        "from": deployer, "nonce": nonce, "gas": 1_500_000,
        "maxFeePerGas": w3.eth.gas_price * 2, "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    if receipt.status != 1:
        raise RuntimeError(f"AuctionManager deployment failed! Gas: {receipt.gasUsed}")
    am_addr = receipt.contractAddress
    print(f"  AuctionManager: {am_addr} (gas: {receipt.gasUsed})")
    nonce += 1

    # Wire AuctionManager to fund
    print("Wiring AuctionManager...")
    tx = fund.functions.setAuctionManager(am_addr).build_transaction({
        "from": deployer, "nonce": nonce, "gas": 100_000,
        "maxFeePerGas": w3.eth.gas_price * 2, "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    nonce += 1

    # Approve TDX verifier (verifierId=1 for TDX)
    print("Approving TdxVerifier (verifierId=1)...")
    tx = fund.functions.approveVerifier(1, verifier_addr).build_transaction({
        "from": deployer, "nonce": nonce,
        "gas": 100_000,
        "maxFeePerGas": w3.eth.gas_price * 2,
        "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    nonce += 1

    # Configure auction timing (cross-contract call to AuctionManager.setTiming)
    print(f"Setting auction timing (epoch={EPOCH_DURATION}s, commit={COMMIT_WINDOW}s, reveal={REVEAL_WINDOW}s, exec={EXECUTION_WINDOW}s)...")
    tx = fund.functions.setAuctionTiming(
        EPOCH_DURATION, COMMIT_WINDOW, REVEAL_WINDOW, EXECUTION_WINDOW
    ).build_transaction({
        "from": deployer, "nonce": nonce,
        "gas": 200_000,
        "maxFeePerGas": w3.eth.gas_price * 2,
        "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    if receipt.status != 1:
        raise RuntimeError(f"setAuctionTiming failed! Gas: {receipt.gasUsed}")
    nonce += 1

    # Set approved system prompt hash
    import hashlib
    prompt_path = Path(__file__).parent.parent / "agent" / "prompts" / "system_v6.txt"
    # Strip to match enclave behavior (enclave does .strip() on the prompt text)
    prompt_hash = hashlib.sha256(prompt_path.read_text().strip().encode("utf-8")).digest()
    print(f"Setting approved prompt hash: 0x{prompt_hash.hex()[:16]}...")
    tx = fund.functions.setApprovedPromptHash(prompt_hash).build_transaction({
        "from": deployer, "nonce": nonce,
        "gas": 100_000,
        "maxFeePerGas": w3.eth.gas_price * 2,
        "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    nonce += 1

    # Enable auction mode
    print("Enabling auction mode...")
    tx = fund.functions.setAuctionEnabled(True).build_transaction({
        "from": deployer, "nonce": nonce,
        "gas": 100_000,
        "maxFeePerGas": w3.eth.gas_price * 2,
        "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    nonce += 1

    # Deploy InvestmentManager
    print("Deploying InvestmentManager...")
    im_artifact = json.loads((ABI_DIR / "InvestmentManager.sol" / "InvestmentManager.json").read_text())
    im_contract = w3.eth.contract(abi=im_artifact["abi"], bytecode=im_artifact["bytecode"]["object"])
    tx = im_contract.constructor(fund_addr, deployer).build_transaction({
        "from": deployer, "nonce": nonce, "gas": 3_500_000,
        "maxFeePerGas": w3.eth.gas_price * 2, "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    if receipt.status != 1:
        raise RuntimeError(f"IM deployment failed! Gas: {receipt.gasUsed}")
    im_addr = receipt.contractAddress
    print(f"  InvestmentManager: {im_addr} (gas: {receipt.gasUsed})")
    nonce += 1

    # Link fund -> InvestmentManager
    tx = fund.functions.setInvestmentManager(im_addr).build_transaction({
        "from": deployer, "nonce": nonce, "gas": 100_000,
        "maxFeePerGas": w3.eth.gas_price * 2, "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    nonce += 1

    # Deploy WorldView
    print("Deploying WorldView...")
    wv_artifact = json.loads((ABI_DIR / "WorldView.sol" / "WorldView.json").read_text())
    wv_contract = w3.eth.contract(abi=wv_artifact["abi"], bytecode=wv_artifact["bytecode"]["object"])
    tx = wv_contract.constructor(fund_addr).build_transaction({
        "from": deployer, "nonce": nonce, "gas": 1_000_000,
        "maxFeePerGas": w3.eth.gas_price * 2, "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    if receipt.status != 1:
        raise RuntimeError(f"WorldView deployment failed! Gas: {receipt.gasUsed}")
    wv_addr = receipt.contractAddress
    print(f"  WorldView: {wv_addr} (gas: {receipt.gasUsed})")
    nonce += 1

    # Link fund -> WorldView
    tx = fund.functions.setWorldView(wv_addr).build_transaction({
        "from": deployer, "nonce": nonce, "gas": 100_000,
        "maxFeePerGas": w3.eth.gas_price * 2, "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    nonce += 1

    # Deploy 3 MockAdapters and register them
    mock_artifact = json.loads((ABI_DIR / "MockAdapter.sol" / "MockAdapter.json").read_text())
    im = w3.eth.contract(address=im_addr, abi=im_artifact["abi"])
    protocol_names = ["Aave V3 WETH (Mock)", "Lido wstETH (Mock)", "Compound V3 USDC (Mock)"]
    descriptions = ["Mock Aave WETH lending", "Mock Lido staking", "Mock Compound USDC lending"]
    risk_tiers = [1, 2, 1]
    apys = [500, 380, 450]

    for i, pname in enumerate(protocol_names):
        # Deploy mock adapter
        mock_contract = w3.eth.contract(abi=mock_artifact["abi"], bytecode=mock_artifact["bytecode"]["object"])
        tx = mock_contract.constructor(pname, im_addr).build_transaction({
            "from": deployer, "nonce": nonce, "gas": 700_000,
            "maxFeePerGas": w3.eth.gas_price * 2, "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
        })
        signed = account.sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
        if receipt.status != 1:
            raise RuntimeError(f"Mock adapter deployment failed! Gas: {receipt.gasUsed}")
        adapter_addr = receipt.contractAddress
        nonce += 1

        # Register in InvestmentManager (deployer is admin)
        tx = im.functions.addProtocol(adapter_addr, pname, descriptions[i], risk_tiers[i], apys[i]).build_transaction({
            "from": deployer, "nonce": nonce, "gas": 200_000,
            "maxFeePerGas": w3.eth.gas_price * 2, "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
        })
        signed = account.sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
        nonce += 1
        print(f"  Protocol #{i+1}: {pname} -> {adapter_addr}")

    print(f"  Contracts deployed and configured!")
    return fund_addr, verifier_addr, am_addr, nonce


# ─── Step 2: Spin up GCP TDX VM ─────────────────────────────────────────

def snapshot_image_name():
    """Return the expected snapshot image name for current mode."""
    return f"humanfund-tee-{'gpu' if USE_GPU else 'cpu'}-70b-v3"

# Note: Boot disk size must accommodate the 70B model (42.5GB) + OS + llama.cpp
BOOT_DISK_SIZE_GB = 200


def snapshot_image_exists():
    """Check if a snapshot image exists for current mode."""
    name = snapshot_image_name()
    try:
        result = gcloud(f"compute images describe {name} --format='value(status)'", check=False)
        return "READY" in result
    except Exception:
        return False


def get_snapshot_startup_script():
    """Minimal startup script for booting from snapshot (everything pre-installed).

    The fresh build installs llama-server to /usr/local/bin/ and shared libs to
    /usr/local/lib/ with ldconfig, so they persist across stop/start. We just
    need to run ldconfig (in case) and start the server.
    """
    if USE_GPU:
        return """#!/bin/bash
exec > /tmp/startup.log 2>&1
echo "=== Snapshot boot (GPU) at $(date) ==="

# Shared libs should already be in /usr/local/lib/ from fresh build
ldconfig 2>/dev/null || true

# GPU drivers may need re-initialization after boot from snapshot
echo "Checking GPU drivers..."
for attempt in 1 2 3; do
    if nvidia-smi > /dev/null 2>&1; then
        echo "GPU available: $(nvidia-smi --query-gpu=name --format=csv,noheader)"
        break
    fi
    echo "nvidia-smi failed (attempt $attempt), reloading drivers..."
    modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true
    sleep 5
    modprobe nvidia 2>/dev/null || true
    modprobe nvidia_uvm 2>/dev/null || true
    sleep 5
done

if ! nvidia-smi > /dev/null 2>&1; then
    echo "FATAL: GPU not available after 3 attempts. Cannot load 70B model without GPU."
    exit 1
fi

# Activate Confidential Computing GPU Ready State (required for TDX VMs)
# Without this, CUDA reports "system not yet initialized" and llama.cpp silently falls back to CPU
echo "Activating CC GPU Ready State..."
nvidia-smi conf-compute -srs 1
sleep 2
CC_STATE=$(nvidia-smi conf-compute -grs 2>&1 | grep -o 'ready\|not-ready')
echo "CC GPU state: $CC_STATE"
if [ "$CC_STATE" = "not-ready" ]; then
    echo "WARNING: CC GPU state still not-ready, retrying..."
    nvidia-smi conf-compute -srs 1
    sleep 5
fi

echo "Starting llama-server (GPU)..."
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}
nohup llama-server -m /models/model.gguf -c 4096 --host 0.0.0.0 --port 8080 -ngl 99 > /tmp/llama.log 2>&1 &

# Wait up to 60s, then check if CUDA actually initialized
sleep 10
if grep -q "failed to initialize CUDA" /tmp/llama.log 2>/dev/null; then
    echo "CUDA init failed! Rebuilding llama.cpp against runtime CUDA..."
    pkill -f llama-server || true
    cd /tmp
    rm -rf llama.cpp
    git clone --depth 1 --branch b5170 https://github.com/ggml-org/llama.cpp.git
    cd llama.cpp
    cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=90
    cmake --build build --config Release -j$(nproc) --target llama-server
    cp build/bin/llama-server /usr/local/bin/
    find build -name '*.so' -exec cp {} /usr/local/lib/ \; 2>/dev/null || true
    ldconfig
    echo "Rebuilt. Restarting llama-server..."
    nohup llama-server -m /models/model.gguf -c 4096 --host 0.0.0.0 --port 8080 -ngl 99 > /tmp/llama.log 2>&1 &
fi

for i in $(seq 1 120); do
    if curl -s http://127.0.0.1:8080/health | grep -q ok; then
        echo "llama-server ready after $((i*5))s"
        break
    fi
    if ! pgrep -f llama-server > /dev/null; then
        echo "FATAL: llama-server crashed on GPU!"
        tail -20 /tmp/llama.log
        exit 1
    fi
    sleep 5
done

# Verify model is actually loaded on GPU (not silent CPU fallback)
GPU_MEM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
echo "GPU memory used: ${GPU_MEM} MiB"
if [ -n "$GPU_MEM" ] && [ "$GPU_MEM" -lt 1000 ]; then
    echo "FATAL: Model not loaded on GPU (only ${GPU_MEM} MiB used). Likely silent CPU fallback!"
    echo "CC state: $(nvidia-smi conf-compute -grs 2>&1)"
    tail -30 /tmp/llama.log
    exit 1
fi
echo "=== Snapshot boot complete at $(date) ==="
"""
    else:
        return """#!/bin/bash
exec > /tmp/startup.log 2>&1
echo "=== Snapshot boot (CPU) at $(date) ==="
ldconfig 2>/dev/null || true
nohup llama-server -m /models/model.gguf -c 4096 --host 0.0.0.0 --port 8080 -t $(nproc) > /tmp/llama.log 2>&1 &
for i in $(seq 1 120); do
    if curl -s http://127.0.0.1:8080/health | grep -q ok; then
        echo "llama-server ready after $((i*5))s"
        break
    fi
    sleep 5
done
echo "=== Snapshot boot complete at $(date) ==="
"""


def get_fresh_startup_script():
    """Full startup script for fresh boot (install everything from scratch)."""
    if USE_GPU:
        return f"""#!/bin/bash
set -e
exec > /tmp/startup.log 2>&1
echo "=== Starting GPU setup at $(date) ==="

apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv cmake build-essential git wget libcurl4-openssl-dev

python3 -m venv /opt/humanfund-venv
source /opt/humanfund-venv/bin/activate
pip install flask web3 requests

echo "Checking for NVIDIA GPU..."
# GCP a3-highgpu machines come with CC drivers pre-installed
# Try loading the driver modules first
modprobe nvidia 2>/dev/null || true
modprobe nvidia_uvm 2>/dev/null || true
sleep 3

if ! nvidia-smi > /dev/null 2>&1; then
    echo "nvidia-smi not available, installing drivers..."
    apt-get install -y -qq linux-headers-$(uname -r) nvidia-driver-575-open nvidia-utils-575 2>/dev/null || true
    apt-get install -y -qq nvidia-cuda-toolkit 2>/dev/null || true
    modprobe nvidia 2>/dev/null || true
    modprobe nvidia_uvm 2>/dev/null || true
    sleep 5
fi

if ! nvidia-smi > /dev/null 2>&1; then
    echo "FATAL: Cannot initialize NVIDIA GPU. Aborting."
    exit 1
fi
nvidia-smi
echo "GPU initialized successfully."

# Find CUDA path for llama.cpp build
CUDA_PATH=""
if [ -d "/usr/local/cuda" ]; then
    CUDA_PATH="/usr/local/cuda"
elif [ -d "/usr/lib/x86_64-linux-gnu/cuda" ]; then
    CUDA_PATH="/usr/lib/x86_64-linux-gnu/cuda"
fi
echo "CUDA path: $CUDA_PATH"

echo "Building llama.cpp with CUDA..."
cd /tmp
git clone --depth 1 --branch b5170 https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=90
cmake --build build --config Release -j$(nproc) --target llama-server
cp build/bin/llama-server /usr/local/bin/
find build -name '*.so' -exec cp {{}} /usr/local/lib/ \; 2>/dev/null || true
ldconfig

echo "Downloading model (42.5GB, may take 5-10 min)..."
mkdir -p /models
wget --progress=dot:giga -O /models/model.gguf "{MODEL_URL}"

echo "Verifying model hash..."
ACTUAL_HASH=$(sha256sum /models/model.gguf | cut -d' ' -f1)
if [ "$ACTUAL_HASH" != "{MODEL_SHA256}" ]; then
    echo "FATAL: Model hash mismatch! Expected {MODEL_SHA256}, got $ACTUAL_HASH"
    exit 1
fi
echo "Model hash verified."

# Activate Confidential Computing GPU Ready State (required for TDX VMs)
echo "Activating CC GPU Ready State..."
nvidia-smi conf-compute -srs 1
sleep 2
CC_STATE=$(nvidia-smi conf-compute -grs 2>&1 | grep -o 'ready\|not-ready')
echo "CC GPU state: $CC_STATE"
if [ "$CC_STATE" = "not-ready" ]; then
    echo "WARNING: CC GPU state still not-ready, retrying..."
    nvidia-smi conf-compute -srs 1
    sleep 5
fi

echo "Starting llama-server (GPU, -ngl 99)..."
nohup llama-server -m /models/model.gguf -c 4096 --host 0.0.0.0 --port 8080 -ngl 99 > /tmp/llama.log 2>&1 &

echo "Waiting for llama-server to load model..."
for i in $(seq 1 180); do
    if curl -s http://127.0.0.1:8080/health | grep -q ok; then
        echo "llama-server ready after $((i*5))s"
        break
    fi
    if ! pgrep -f llama-server > /dev/null; then
        echo "FATAL: llama-server crashed!"
        tail -30 /tmp/llama.log
        exit 1
    fi
    sleep 5
done

if ! curl -s http://127.0.0.1:8080/health | grep -q ok; then
    echo "FATAL: llama-server never became ready after 15 minutes"
    tail -30 /tmp/llama.log
    exit 1
fi

# Verify model is actually loaded on GPU (not silent CPU fallback)
GPU_MEM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
echo "GPU memory used: ${{GPU_MEM}} MiB"
if [ -n "$GPU_MEM" ] && [ "$GPU_MEM" -lt 1000 ]; then
    echo "FATAL: Model not loaded on GPU (only ${{GPU_MEM}} MiB used). Likely silent CPU fallback!"
    echo "CC state: $(nvidia-smi conf-compute -grs 2>&1)"
    tail -30 /tmp/llama.log
    exit 1
fi

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
find build -name '*.so' -exec cp {{}} /usr/local/lib/ \; 2>/dev/null || true
ldconfig

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


def create_snapshot_image():
    """Stop VM, create disk image, restart VM."""
    name = snapshot_image_name()
    print(f"\n═══ STEP 2d: Create Snapshot Image '{name}' ═══")
    try:
        print("  Stopping VM...")
        gcloud(f"compute instances stop {GCP_VM_NAME} --zone={GCP_ZONE}", timeout=180)

        # Delete old image if it exists (--force doesn't work for images create)
        print("  Deleting old image if it exists...")
        gcloud(f"compute images delete {name} --quiet", check=False, timeout=60)

        print("  Creating image from boot disk...")
        gcloud(
            f"compute images create {name} "
            f"--source-disk={GCP_VM_NAME} --source-disk-zone={GCP_ZONE} "
            f"--family=humanfund-tee",
            timeout=600
        )
        print(f"  Image '{name}' created!")

        print("  Restarting VM...")
        gcloud(f"compute instances start {GCP_VM_NAME} --zone={GCP_ZONE}", timeout=120)

        # Wait for llama-server to come back
        print("  Waiting for llama-server to restart...")
        for i in range(60):
            time.sleep(10)
            try:
                result = gcloud(
                    f"compute ssh {GCP_VM_NAME} --zone={GCP_ZONE} "
                    f"--command='curl -s http://127.0.0.1:8080/health 2>/dev/null || echo NOT_READY'",
                    check=False, timeout=30
                )
                if '"status":"ok"' in result or '"status": "ok"' in result:
                    print(f"  llama-server back up after restart")
                    return True
            except Exception:
                pass
        print("  WARNING: llama-server not responding after restart")
        return False
    except Exception as e:
        print(f"  WARNING: Snapshot failed: {e}")
        return False


def create_gcp_vm(force_fresh=False):
    """Create a GCP TDX confidential VM for e2e testing.

    Returns (ip, booted_from_snapshot) tuple.
    """
    print("\n═══ STEP 2: Create GCP TDX VM ═══")

    # Check if VM already exists
    try:
        result = gcloud(f"compute instances describe {GCP_VM_NAME} --zone={GCP_ZONE} --format='value(status)'", check=False)
        if "RUNNING" in result:
            ip = gcloud(f"compute instances describe {GCP_VM_NAME} --zone={GCP_ZONE} --format='value(networkInterfaces[0].accessConfigs[0].natIP)'")
            print(f"  VM already running at {ip}")
            return ip, False
        elif result.strip():
            print(f"  VM exists but status={result.strip()}, deleting...")
            gcloud(f"compute instances delete {GCP_VM_NAME} --zone={GCP_ZONE} --quiet")
    except Exception:
        pass

    # Check for snapshot image
    use_snapshot = not force_fresh and snapshot_image_exists()
    if use_snapshot:
        image_name = snapshot_image_name()
        print(f"  Booting from snapshot image '{image_name}' (fast boot, ~1-2 min)")
        startup_script = get_snapshot_startup_script()
        image_flags = f"--image={image_name}"
    else:
        if force_fresh:
            print(f"  Fresh boot requested (--fresh flag)")
        else:
            print(f"  No snapshot image found, doing fresh install (~10-15 min)")
        startup_script = get_fresh_startup_script()
        image_flags = "--image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud"

    startup_path = "/tmp/humanfund_e2e_startup.sh"
    with open(startup_path, "w") as f:
        f.write(startup_script)

    print(f"Creating {GCP_MACHINE_TYPE} TDX spot instance...")
    gcloud(
        f"compute instances create {GCP_VM_NAME} "
        f"--zone={GCP_ZONE} "
        f"--machine-type={GCP_MACHINE_TYPE} "
        f"--confidential-compute-type=TDX "
        f"--provisioning-model=SPOT "
        f"--instance-termination-action=STOP "
        f'--min-cpu-platform="Intel Sapphire Rapids" '
        f"{image_flags} "
        f"--boot-disk-size=200GB "
        f"--metadata-from-file=startup-script={startup_path}",
        timeout=120
    )

    ip = gcloud(
        f"compute instances describe {GCP_VM_NAME} --zone={GCP_ZONE} "
        f"--format='value(networkInterfaces[0].accessConfigs[0].natIP)'"
    )
    print(f"  VM created: {ip}")
    return ip, use_snapshot


def wait_for_vm_ready(vm_ip):
    """Wait for the VM to have llama-server running and SSH accessible."""
    print("\n═══ STEP 2b: Wait for VM Setup ═══")
    print("  (This takes ~10-15 min: apt install + llama.cpp build + model download)")

    for i in range(90):  # 45 min max
        try:
            result = gcloud(
                f"compute ssh {GCP_VM_NAME} --zone={GCP_ZONE} "
                f"--command='curl -s http://127.0.0.1:8080/health 2>/dev/null || echo NOT_READY'",
                check=False, timeout=30
            )
            if '"status":"ok"' in result or '"status": "ok"' in result:
                print(f"  llama-server ready after {i * 30}s")
                # In GPU mode, verify model is actually on GPU (not silent CPU fallback)
                if USE_GPU:
                    try:
                        gpu_check = gcloud(
                            f"compute ssh {GCP_VM_NAME} --zone={GCP_ZONE} "
                            f"--command='nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null'",
                            check=False, timeout=15
                        )
                        gpu_mem = int(gpu_check.strip().split()[0]) if gpu_check.strip() else 0
                        if gpu_mem < 1000:
                            print(f"  WARNING: Only {gpu_mem} MiB GPU memory used — model may be on CPU!")
                            print(f"  Activating CC and restarting llama-server...")
                            gcloud(
                                f"compute ssh {GCP_VM_NAME} --zone={GCP_ZONE} "
                                f"--command='sudo nvidia-smi conf-compute -srs 1 && sleep 2 && "
                                f"cat > /tmp/restart_gpu.sh << \"EOF\"\n"
                                f"#!/bin/bash\npkill -9 -f llama-server\nsleep 3\n"
                                f"nohup /tmp/llama.cpp/build/bin/llama-server -m /models/model.gguf -c 4096 --host 0.0.0.0 --port 8080 -ngl 99 > /tmp/llama.log 2>&1 &\n"
                                f"EOF\nsudo bash /tmp/restart_gpu.sh'",
                                check=False, timeout=30
                            )
                            continue  # Re-check after restart
                        else:
                            print(f"  GPU memory: {gpu_mem} MiB — model loaded on GPU ✓")
                    except Exception:
                        pass  # If GPU check fails, proceed anyway
                return True
            elif "NOT_READY" in result:
                # SSH works but llama-server not ready yet
                # Check startup progress and llama-server status
                log = gcloud(
                    f"compute ssh {GCP_VM_NAME} --zone={GCP_ZONE} "
                    f"--command='tail -3 /tmp/startup.log 2>/dev/null; "
                    f"echo \"---\"; pgrep -f llama-server > /dev/null && echo LLAMA_RUNNING || echo LLAMA_NOT_RUNNING; "
                    f"echo \"---\"; tail -3 /tmp/llama.log 2>/dev/null || echo no_llama_log'",
                    check=False, timeout=15
                )
                print(f"  [{i * 30}s] Waiting... {log[:120]}")
        except Exception as e:
            print(f"  [{i * 30}s] SSH not ready yet: {str(e)[:60]}")
        time.sleep(30)

    print("  TIMEOUT: VM not ready after 45 minutes")
    return False


def upload_enclave_files(vm_ip):
    """Upload modular enclave package and system prompt to the VM."""
    print("\n═══ STEP 2c: Upload Enclave Files ═══")

    # Upload the modular tee/enclave/ package
    gcloud(
        f"compute scp --recurse {PROJECT_ROOT}/tee/enclave "
        f"{GCP_VM_NAME}:/tmp/enclave --zone={GCP_ZONE}",
        timeout=60
    )
    print("  Uploaded tee/enclave/ package")

    # Upload system prompt
    gcloud(
        f"compute scp {PROJECT_ROOT}/agent/prompts/system_v6.txt "
        f"{GCP_VM_NAME}:/tmp/system_prompt.txt --zone={GCP_ZONE}",
        timeout=30
    )
    print("  Uploaded system_prompt.txt")

    # Install dependencies on the VM (flask for API, pycryptodome for keccak256, eth_abi for input hash)
    gcloud(
        f"compute ssh {GCP_VM_NAME} --zone={GCP_ZONE} "
        f"--command='pip3 install --break-system-packages flask pycryptodome eth_abi 2>/dev/null || "
        f"source /opt/humanfund-venv/bin/activate && pip install flask pycryptodome eth_abi 2>/dev/null || true'",
        check=False, timeout=120
    )

    # Start the modular enclave runner as root (needs root for configfs-tsm TDX quote generation)
    startup = (
        "#!/bin/bash\n"
        "pkill -f enclave_runner 2>/dev/null; pkill -f 'python3 -u -m enclave' 2>/dev/null; sleep 1\n"
        "rm -rf /tmp/__pycache__ /tmp/enclave/__pycache__ 2>/dev/null\n"
        "source /opt/humanfund-venv/bin/activate 2>/dev/null || true\n"
        "export PYTHONUNBUFFERED=1\n"
        "cd /tmp\n"
        "ENCLAVE_HOST=0.0.0.0 ENCLAVE_PORT=8090 SYSTEM_PROMPT_PATH=/tmp/system_prompt.txt "
        "nohup python3 -u -m enclave.enclave_runner > /tmp/enclave.log 2>&1 &\n"
    )
    with open("/tmp/start_enclave.sh", "w") as f:
        f.write(startup)
    gcloud(
        f"compute scp /tmp/start_enclave.sh {GCP_VM_NAME}:/tmp/start_enclave.sh --zone={GCP_ZONE}",
        timeout=30
    )
    gcloud(
        f"compute ssh {GCP_VM_NAME} --zone={GCP_ZONE} "
        f"--command='sudo rm -f /tmp/enclave.log && sudo bash /tmp/start_enclave.sh'",
        timeout=30
    )
    print("  Started modular enclave runner on port 8090 (as root for configfs-tsm)")

    # Wait for it to be ready
    for i in range(12):
        time.sleep(5)
        try:
            result = gcloud(
                f"compute ssh {GCP_VM_NAME} --zone={GCP_ZONE} "
                f"--command='curl -s http://127.0.0.1:8090/health 2>/dev/null || echo NOT_READY'",
                check=False, timeout=15
            )
            if '"status": "ok"' in result or '"status":"ok"' in result:
                print(f"  Enclave runner ready!")
                return True
        except Exception:
            pass
    print("  WARNING: Enclave runner may not be ready")
    return False


# ─── Step 3: Register Image Key ─────────────────────────────────────────

def get_vm_measurements():
    """Get a TDX quote from the VM and extract MRTD/RTMR values."""
    print("\n═══ STEP 3: Extract VM Measurements ═══")

    # Upload measurement extraction script and run it
    extract_script = PROJECT_ROOT / "scripts" / "extract_measurements.py"
    gcloud(
        f"compute scp {extract_script} {GCP_VM_NAME}:/tmp/extract_measurements.py --zone={GCP_ZONE}",
        timeout=30
    )
    result = gcloud(
        f"compute ssh {GCP_VM_NAME} --zone={GCP_ZONE} "
        f"--command='sudo python3 /tmp/extract_measurements.py'",
        timeout=30
    )

    measurements = {}
    for line in result.split("\n"):
        line = line.strip()
        if line.startswith("MRTD:"):
            measurements["mrtd"] = bytes.fromhex(line.split(":")[1])
        elif line.startswith("RTMR0:"):
            measurements["rtmr0"] = bytes.fromhex(line.split(":")[1])
        elif line.startswith("RTMR1:"):
            measurements["rtmr1"] = bytes.fromhex(line.split(":")[1])
        elif line.startswith("RTMR2:"):
            measurements["rtmr2"] = bytes.fromhex(line.split(":")[1])
        elif line.startswith("RTMR3:"):
            measurements["rtmr3"] = bytes.fromhex(line.split(":")[1])

    if "rtmr1" not in measurements or "rtmr2" not in measurements:
        raise RuntimeError(f"Failed to extract measurements: {result[:500]}")

    # Default RTMR[3] to zeros if not present (boot script hasn't run yet)
    if "rtmr3" not in measurements:
        measurements["rtmr3"] = b'\x00' * 48

    # Image key = keccak256(RTMR[1] + RTMR[2] + RTMR[3])
    image_key = Web3.keccak(
        measurements["rtmr1"] + measurements["rtmr2"] + measurements["rtmr3"]
    )
    measurements["image_key"] = image_key
    print(f"  MRTD:      {measurements.get('mrtd', b'').hex()[:32]}... (not in image key)")
    print(f"  RTMR[0]:   {measurements.get('rtmr0', b'').hex()[:32]}... (not in image key)")
    print(f"  RTMR[1]:   {measurements['rtmr1'].hex()[:32]}...")
    print(f"  RTMR[2]:   {measurements['rtmr2'].hex()[:32]}...")
    print(f"  RTMR[3]:   {measurements['rtmr3'].hex()[:32]}...")
    print(f"  Image key: 0x{image_key.hex()} (keccak256(RTMR[1] + RTMR[2] + RTMR[3]))")
    return measurements


def register_image_key(w3, account, verifier_addr, image_key, nonce):
    """Register the VM's image key in the TdxVerifier."""
    print("\n═══ STEP 3b: Register Image Key ═══")

    verifier_abi = json.loads(
        (ABI_DIR / "TdxVerifier.sol" / "TdxVerifier.json").read_text()
    )["abi"]
    verifier = w3.eth.contract(address=verifier_addr, abi=verifier_abi)

    # Check if already approved
    if verifier.functions.approvedImages(image_key).call():
        print(f"  Image already approved!")
        return nonce

    tx = verifier.functions.approveImage(image_key).build_transaction({
        "from": account.address, "nonce": nonce,
        "gas": 100_000,
        "maxFeePerGas": w3.eth.gas_price * 2,
        "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    print(f"  Image approved! (gas: {receipt.gasUsed}, tx: {tx_hash.hex()[:16]}...)")
    return nonce + 1


# ─── Step 4: Run Full Auction Flow ───────────────────────────────────────

def run_auction_e2e(w3, account, fund_addr, am_addr, vm_ip, nonce):
    """Run the full auction lifecycle with real TDX attestation."""
    print("\n═══ STEP 4: Full Auction E2E ═══")

    am_abi = json.loads(
        (ABI_DIR / "AuctionManager.sol" / "AuctionManager.json").read_text()
    )["abi"]
    am = w3.eth.contract(address=am_addr, abi=am_abi)

    fund_abi = json.loads(
        (ABI_DIR / "TheHumanFund.sol" / "TheHumanFund.json").read_text()
    )["abi"]
    fund = w3.eth.contract(address=fund_addr, abi=fund_abi)

    # Helper to get fresh Web3 connection (Base Sepolia RPC returns stale data after writes)
    def fresh_connection():
        nonlocal am
        w3_ = Web3(Web3.HTTPProvider(RPC_URL, request_kwargs={"timeout": 120}))
        fund_ = w3_.eth.contract(address=fund_addr, abi=fund_abi)
        am = w3_.eth.contract(address=am_addr, abi=am_abi)
        return w3_, fund_

    def send_tx(fn, value=0, gas=300_000):
        """Send a transaction, wait for receipt, refresh connection, return (receipt, nonce)."""
        nonlocal w3, fund, nonce
        tx = fn.build_transaction({
            "from": account.address, "nonce": nonce, "value": value, "gas": gas,
            "maxFeePerGas": w3.eth.gas_price * 2,
            "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
        })
        signed = account.sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
        nonce += 1
        assert receipt.status == 1, f"Transaction reverted! Gas: {receipt.gasUsed}"
        # Refresh connection to avoid stale reads
        time.sleep(3)
        w3, fund = fresh_connection()
        return receipt

    epoch = fund.functions.currentEpoch().call()
    print(f"  Current epoch: {epoch}")
    print(f"  Treasury: {w3.from_wei(fund.functions.treasuryBalance().call(), 'ether')} ETH")

    # ─── 4a: startEpoch ───
    # Clean up any stale auction state before starting a new epoch.
    # If the current epoch has an active auction (e.g., from a previous failed run),
    # close it out so we can proceed.
    epoch_dur = fund.functions.epochDuration().call()
    commit_win = am.functions.commitWindow().call()
    reveal_win = am.functions.revealWindow().call()

    start_time = am.functions.getStartTime(epoch).call()
    phase = am.functions.getPhase(epoch).call()  # 0=IDLE, 1=COMMIT, 2=REVEAL, 3=EXECUTION

    if phase != 0 and start_time > 0:
        now = int(time.time())
        print(f"  4a. Cleaning up stale epoch {epoch} (phase={phase})...")
        if phase == 1:  # COMMIT
            close_time = start_time + commit_win
            if now < close_time:
                wait = close_time - now + 3
                print(f"      Waiting {wait}s for commit window to close...")
                time.sleep(wait)
            try:
                receipt = send_tx(fund.functions.closeCommit())
                print(f"      closeCommit: gas={receipt.gasUsed}")
            except Exception as e:
                print(f"      closeCommit failed: {e}")
            w3, fund = fresh_connection()
            nonce = w3.eth.get_transaction_count(account.address)
            phase = am.functions.getPhase(epoch).call()

        if phase == 2:  # REVEAL
            close_time = start_time + commit_win + reveal_win
            now = int(time.time())
            if now < close_time:
                wait = close_time - now + 3
                print(f"      Waiting {wait}s for reveal window to close...")
                time.sleep(wait)
            try:
                receipt = send_tx(fund.functions.closeReveal())
                print(f"      closeReveal: gas={receipt.gasUsed}")
            except Exception as e:
                print(f"      closeReveal failed: {e}")
            w3, fund = fresh_connection()
            nonce = w3.eth.get_transaction_count(account.address)
            phase = am.functions.getPhase(epoch).call()

        if phase == 3:  # EXECUTION — need to forfeit bond
            exec_win = am.functions.executionWindow().call()
            deadline = start_time + commit_win + reveal_win + exec_win
            now = int(time.time())
            if now < deadline:
                wait = deadline - now + 3
                print(f"      Waiting {wait}s for execution window to expire...")
                time.sleep(wait)
            try:
                receipt = send_tx(fund.functions.forfeitBond())
                print(f"      forfeitBond: gas={receipt.gasUsed}")
            except Exception as e:
                print(f"      forfeitBond failed: {e}")
            w3, fund = fresh_connection()
            nonce = w3.eth.get_transaction_count(account.address)

        # Epoch may have advanced
        epoch = fund.functions.currentEpoch().call()
        print(f"      Now on epoch {epoch}")

    # Wait for previous epoch's duration if needed
    if epoch > 1:
        try:
            prev_start = am.functions.getStartTime(epoch - 1).call()
            if prev_start > 0:
                earliest_start = prev_start + epoch_dur
                now = int(time.time())
                if now < earliest_start:
                    wait_secs = earliest_start - now + 5
                    print(f"  4a. Waiting {wait_secs}s for epoch {epoch} window to open...")
                    time.sleep(wait_secs)
                    w3, fund = fresh_connection()
                    nonce = w3.eth.get_transaction_count(account.address)
        except Exception:
            pass  # AM query may fail for epoch 0

    # Start the fresh epoch
    print(f"  4a. Starting epoch {epoch}...")
    for attempt in range(5):
        try:
            receipt = send_tx(fund.functions.startEpoch())
            break
        except (AssertionError, Exception) as e:
            if attempt < 4:
                wait = 30
                print(f"      startEpoch reverted, retrying in {wait}s (attempt {attempt + 2}/5)...")
                time.sleep(wait)
                w3, fund = fresh_connection()
                nonce = w3.eth.get_transaction_count(account.address)
                epoch = fund.functions.currentEpoch().call()
            else:
                raise
    print(f"      Gas: {receipt.gasUsed}")
    # Note: epochInputHashes is set at closeReveal, not startEpoch

    # ─── 4b: commit sealed bid ───
    emb = fund.functions.effectiveMaxBid().call()
    bid_wei = min(emb, w3.to_wei(BID_AMOUNT_ETH, "ether"))
    treasury_bal = w3.eth.get_balance(fund.address)
    max_bid_from_treasury = int(treasury_bal * 9 // 10)
    if max_bid_from_treasury > 0 and bid_wei > max_bid_from_treasury:
        print(f"      Treasury low, capping bid to {w3.from_wei(max_bid_from_treasury, 'ether')} ETH")
        bid_wei = max_bid_from_treasury

    bond_wei = fund.functions.currentBond().call()
    salt = w3.keccak(os.urandom(32))
    commit_hash = w3.keccak(bid_wei.to_bytes(32, "big") + salt)

    print(f"\n  4b. Committing sealed bid: {w3.from_wei(bid_wei, 'ether')} ETH (bond: {w3.from_wei(bond_wei, 'ether')} ETH)...")
    receipt = send_tx(fund.functions.commit(commit_hash), value=bond_wei)
    print(f"      Gas: {receipt.gasUsed}")

    # ─── 4c: Wait for commit window, closeCommit, reveal, closeReveal ───
    start_time = am.functions.getStartTime(epoch).call()
    commit_win = am.functions.commitWindow().call()
    now = w3.eth.get_block("latest").timestamp
    wait_secs = max(0, start_time + commit_win - now + 5)
    print(f"\n  4c. Waiting {wait_secs}s for commit window to close...")
    if wait_secs > 0:
        time.sleep(wait_secs)
        w3, fund = fresh_connection()
        nonce = w3.eth.get_transaction_count(account.address)

    print("      Closing commit phase...")
    receipt = send_tx(fund.functions.closeCommit())
    print(f"      Gas: {receipt.gasUsed}")

    # Reveal our bid
    print(f"      Revealing bid: {w3.from_wei(bid_wei, 'ether')} ETH...")
    receipt = send_tx(fund.functions.reveal(bid_wei, salt))
    print(f"      Gas: {receipt.gasUsed}")

    # Wait for reveal window, then close
    reveal_win = am.functions.revealWindow().call()
    now = w3.eth.get_block("latest").timestamp
    reveal_close_time = start_time + commit_win + reveal_win
    wait_secs = max(0, reveal_close_time - now + 5)
    print(f"      Waiting {wait_secs}s for reveal window to close...")
    if wait_secs > 0:
        time.sleep(wait_secs)
        w3, fund = fresh_connection()
        nonce = w3.eth.get_transaction_count(account.address)

    print("      Closing reveal phase...")
    receipt = send_tx(fund.functions.closeReveal())

    # Fresh connection to avoid stale reads after closeReveal
    time.sleep(3)
    w3, fund = fresh_connection()
    nonce = w3.eth.get_transaction_count(account.address)

    winner = am.functions.getWinner(epoch).call()
    winning_bid = am.functions.getWinningBid(epoch).call()
    seed = am.functions.getRandomnessSeed(epoch).call()
    input_hash = fund.functions.epochInputHashes(epoch).call()
    print(f"      Winner: {winner}")
    print(f"      Input hash: 0x{input_hash.hex()[:16]}... (set at closeReveal)")
    print(f"      Randomness seed: {seed}")
    print(f"      Gas: {receipt.gasUsed}")

    assert winner.lower() == account.address.lower(), f"We're not the winner! Winner={winner}"

    # ─── 4d: Run TEE inference on GCP VM ───
    print(f"\n  4d. Running TEE inference on GCP VM...")

    # Build epoch context using legacy runner (state reading + prompt building)
    sys.path.insert(0, str(PROJECT_ROOT))
    from runner.epoch_state import read_contract_state, build_epoch_context

    state = read_contract_state(fund, w3)
    epoch_context = build_epoch_context(state)
    input_hash_hex = "0x" + input_hash.hex()

    # Read system prompt (new modular enclave expects it in the payload)
    prompt_path = PROJECT_ROOT / "agent" / "prompts" / "system_v6.txt"
    system_prompt = prompt_path.read_text().strip()

    # Save payload and upload to VM
    payload = json.dumps({
        "epoch_context": epoch_context,
        "system_prompt": system_prompt,
        "input_hash": input_hash_hex,
        "seed": seed,
    })
    payload_path = "/tmp/tee_payload.json"
    with open(payload_path, "w") as f:
        f.write(payload)

    subprocess.run(
        f"gcloud compute scp {payload_path} {GCP_VM_NAME}:/tmp/tee_payload.json "
        f"--zone={GCP_ZONE} --project={GCP_PROJECT}",
        shell=True, timeout=30, capture_output=True
    )

    # Run inference on VM via gcloud ssh (more reliable than SSH tunnels)
    print("      Running inference on VM...")
    result = subprocess.run(
        ["gcloud", "compute", "ssh", GCP_VM_NAME,
         f"--zone={GCP_ZONE}", f"--project={GCP_PROJECT}",
         '--command=curl -s -X POST http://127.0.0.1:8090/run_epoch '
         '-H "Content-Type: application/json" '
         '-d @/tmp/tee_payload.json -o /tmp/tee_result.json '
         '&& echo DONE && wc -c /tmp/tee_result.json'],
        timeout=2400, capture_output=True, text=True
    )
    print(f"      SSH output: {result.stdout.strip()}")
    assert "DONE" in result.stdout, f"Inference failed: {result.stderr[:200]}"

    # Download result
    subprocess.run(
        f"gcloud compute scp {GCP_VM_NAME}:/tmp/tee_result.json /tmp/tee_result.json "
        f"--zone={GCP_ZONE} --project={GCP_PROJECT}",
        shell=True, timeout=30, capture_output=True
    )
    tee_result = json.loads(Path("/tmp/tee_result.json").read_text())
    print(f"      Action: {json.dumps(tee_result.get('action', 'N/A'))}")
    if "error" in tee_result:
        print(f"      ❌ TEE error: {tee_result['error']}")
        print(f"      Raw output: {tee_result.get('raw_output', 'N/A')[:200]}")
        return False
    print(f"      Quote: {len(bytes.fromhex(tee_result['attestation_quote'].replace('0x', '')))} bytes")

    # ─── 4e: Submit auction result ───
    print(f"\n  4e. Submitting auction result on-chain...")

    action_bytes = bytes.fromhex(tee_result["action_bytes"].replace("0x", ""))
    reasoning_bytes = tee_result["reasoning"].encode("utf-8")
    attestation_bytes = bytes.fromhex(tee_result["attestation_quote"].replace("0x", ""))
    print(f"      Reasoning: {len(reasoning_bytes)} bytes (truncated by enclave if needed)")

    # Extract worldview update if present
    action_json = tee_result.get("action", {})
    if isinstance(action_json, str):
        action_json = json.loads(action_json)
    wv = action_json.get("worldview", {})
    policy_slot = wv.get("slot", -1)  # -1 = no update
    policy_text = wv.get("policy", "")
    if policy_slot >= 0:
        print(f"      Worldview update: slot {policy_slot} = {policy_text!r}")

    # Verify REPORTDATA matches before submitting
    # Formula: outputHash = keccak256(sha256(action) + sha256(reasoning) + promptHash)
    #          REPORTDATA = sha256(inputHash + outputHash)
    # Compute prompt hash locally (avoids stale RPC connection after long inference)
    prompt_path = Path(__file__).parent.parent / "agent" / "prompts" / "system_v6.txt"
    prompt_hash = hashlib.sha256(prompt_path.read_text().strip().encode("utf-8")).digest()
    output_hash = Web3.keccak(
        hashlib.sha256(action_bytes).digest() +
        hashlib.sha256(reasoning_bytes).digest() +
        prompt_hash
    )
    expected_rd = hashlib.sha256(
        input_hash + output_hash
    ).digest()
    tee_rd = bytes.fromhex(tee_result["report_data"].replace("0x", ""))[:32]
    print(f"      REPORTDATA match: {expected_rd == tee_rd}")
    if expected_rd != tee_rd:
        print(f"      MISMATCH! Contract: {expected_rd.hex()[:32]}... TEE: {tee_rd.hex()[:32]}...")
        return False

    # Fetch RPC params with retry (public RPC may be flaky after long inference wait)
    for rpc_attempt in range(5):
        try:
            w3 = Web3(Web3.HTTPProvider(RPC_URL, request_kwargs={"timeout": 60}))
            fund = w3.eth.contract(address=fund_addr, abi=fund_abi)
            am = w3.eth.contract(address=am_addr, abi=am_abi)
            nonce = w3.eth.get_transaction_count(account.address)
            gas_price = w3.eth.gas_price
            chain_id = w3.eth.chain_id
            break
        except Exception as e:
            print(f"      RPC fetch failed (attempt {rpc_attempt + 1}/5): {str(e)[:80]}")
            time.sleep(5)
    else:
        raise RuntimeError("Failed to fetch RPC params after 5 attempts")

    # Build tx manually — no RPC calls needed after this point
    print(f"      Building tx (nonce={nonce}, chain_id={chain_id})...")
    calldata = fund.functions.submitAuctionResult(
        action_bytes, reasoning_bytes, attestation_bytes, 1,
        policy_slot, policy_text
    )._encode_transaction_data()
    tx = {
        "from": account.address,
        "to": fund_addr,
        "data": calldata,
        "nonce": nonce,
        "gas": 15_000_000,
        "maxFeePerGas": gas_price * 3,
        "maxPriorityFeePerGas": w3.to_wei(0.01, "gwei"),
        "chainId": chain_id,
        "type": 2,
    }
    signed = account.sign_transaction(tx)
    raw_tx = signed.raw_transaction
    tx_hash = Web3.keccak(raw_tx)
    print(f"      Tx: https://sepolia.basescan.org/tx/{tx_hash.hex()}")
    print(f"      Raw tx size: {len(raw_tx)} bytes")

    # Send raw tx via HTTP POST with retry (public RPC drops connection on large ~12KB txs)
    raw_tx_hex = "0x" + raw_tx.hex()
    tx_hash_hex = tx_hash.hex() if tx_hash.hex().startswith("0x") else "0x" + tx_hash.hex()
    for send_attempt in range(5):
        try:
            send_resp = requests.post(RPC_URL, json={
                "jsonrpc": "2.0", "method": "eth_sendRawTransaction",
                "params": [raw_tx_hex], "id": 1,
            }, timeout=300)
            send_json = send_resp.json()
            if "error" in send_json:
                err_msg = str(send_json['error'])
                if "already known" in err_msg or "nonce too low" in err_msg:
                    print(f"      Tx already in mempool (attempt {send_attempt + 1})")
                    break
                raise RuntimeError(f"eth_sendRawTransaction failed: {send_json['error']}")
            print(f"      Sent successfully via HTTP POST")
            break
        except (requests.ConnectionError, requests.Timeout, ConnectionResetError) as e:
            print(f"      Send failed (attempt {send_attempt + 1}/5): {str(e)[:80]}")
            # The tx may have been received despite the connection error — check for receipt
            time.sleep(5)
            try:
                rcpt_check = requests.post(RPC_URL, json={
                    "jsonrpc": "2.0", "method": "eth_getTransactionReceipt",
                    "params": [tx_hash_hex], "id": 1,
                }, timeout=15)
                if rcpt_check.json().get("result") is not None:
                    print(f"      Tx was received despite connection error!")
                    break
            except Exception:
                pass
            if send_attempt == 4:
                raise RuntimeError(f"Failed to send tx after 5 attempts: {e}")

    # Poll for receipt via HTTP POST (avoids Web3.py connection issues on large txs)
    receipt = None
    for wait_attempt in range(36):  # 36 x 5s = 3 min
        time.sleep(5)
        try:
            rcpt_resp = requests.post(RPC_URL, json={
                "jsonrpc": "2.0", "method": "eth_getTransactionReceipt",
                "params": [tx_hash_hex], "id": 1,
            }, timeout=30)
            rcpt_json = rcpt_resp.json()
            result = rcpt_json.get("result")
            if result is not None:
                # Parse receipt from raw JSON-RPC response
                receipt_status = int(result["status"], 16)
                receipt_gas = int(result["gasUsed"], 16)
                # Build a simple namespace so downstream code can use receipt.status / receipt.gasUsed
                class _Receipt:
                    pass
                receipt = _Receipt()
                receipt.status = receipt_status
                receipt.gasUsed = receipt_gas
                break
        except Exception as e:
            print(f"      Polling for receipt (attempt {wait_attempt + 1}/36): {str(e)[:80]}")
    if receipt is None:
        raise RuntimeError("Failed to get receipt for submitAuctionResult")
    nonce += 1

    if receipt.status == 1:
        new_epoch = fund.functions.currentEpoch().call()
        new_balance = fund.functions.treasuryBalance().call()

        print(f"\n  ✅ SUCCESS! Full attestation chain verified on-chain!")
        print(f"      Epoch advanced: {epoch} → {new_epoch}")
        print(f"      Treasury: {w3.from_wei(new_balance, 'ether')} ETH")
        print(f"      Gas used: {receipt.gasUsed}")
        print(f"      Tx: https://sepolia.basescan.org/tx/{tx_hash.hex()}")
        return True
    else:
        print(f"\n  ❌ FAILED! Transaction reverted (gas: {receipt.gasUsed})")
        print(f"      Tx: https://sepolia.basescan.org/tx/{tx_hash.hex()}")
        return False


# ─── Step 5: Cleanup ────────────────────────────────────────────────────

def cleanup(delete_vm=True):
    """Delete the GCP VM."""
    if delete_vm:
        print("\n═══ STEP 5: Cleanup ═══")
        try:
            gcloud(f"compute instances delete {GCP_VM_NAME} --zone={GCP_ZONE} --quiet", timeout=120)
            print("  VM deleted")
        except Exception as e:
            print(f"  Failed to delete VM: {e}")


# ─── Main ───────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Full E2E test on Base Sepolia")
    parser.add_argument("--fund-address", help="Reuse existing TheHumanFund contract")
    parser.add_argument("--verifier-address", help="Reuse existing TdxVerifier contract")
    parser.add_argument("--vm-ip", help="Reuse existing GCP VM (skip creation)")
    parser.add_argument("--no-cleanup", action="store_true", help="Don't delete VM after test")
    parser.add_argument("--skip-vm", action="store_true", help="Skip VM creation (for testing)")
    parser.add_argument("--cpu", action="store_true", help="Use CPU instance instead of GPU (slower, cheaper)")
    parser.add_argument("--epochs", type=int, default=1, help="Number of epochs to run (default: 1)")
    parser.add_argument("--no-snapshot", action="store_true", help="Don't auto-create snapshot on fresh boot")
    parser.add_argument("--fresh", action="store_true", help="Force fresh VM boot even if snapshot exists")
    args = parser.parse_args()

    # Configure GPU vs CPU (GPU is default)
    global GCP_MACHINE_TYPE, USE_GPU, EPOCH_DURATION, COMMIT_WINDOW, REVEAL_WINDOW, EXECUTION_WINDOW
    if args.cpu:
        GCP_MACHINE_TYPE = GCP_MACHINE_TYPE_CPU
        USE_GPU = False
        EPOCH_DURATION = EPOCH_DURATION_CPU
        COMMIT_WINDOW = COMMIT_WINDOW_CPU
        REVEAL_WINDOW = REVEAL_WINDOW_CPU
        EXECUTION_WINDOW = EXECUTION_WINDOW_CPU
        print("Mode: CPU (c3-standard-4, ~20-30 min inference)")
    else:
        GCP_MACHINE_TYPE = GCP_MACHINE_TYPE_GPU
        USE_GPU = True
        EPOCH_DURATION = EPOCH_DURATION_GPU
        COMMIT_WINDOW = COMMIT_WINDOW_GPU
        REVEAL_WINDOW = REVEAL_WINDOW_GPU
        EXECUTION_WINDOW = EXECUTION_WINDOW_GPU
        print("Mode: GPU (a3-highgpu-1g, H100, ~30s inference)")

    print(f"  Timing: epoch={EPOCH_DURATION}s, commit={COMMIT_WINDOW}s, reveal={REVEAL_WINDOW}s, execution={EXECUTION_WINDOW}s")

    # Load private key
    private_key = os.environ.get("PRIVATE_KEY")
    if not private_key:
        # Try .env file (check both worktree and main repo)
        for env_path in [PROJECT_ROOT / ".env", Path("/Users/andrewrussell/Projects/thehumanfund/.env")]:
            if env_path.exists():
                for line in env_path.read_text().split("\n"):
                    if line.startswith("PRIVATE_KEY="):
                        private_key = line.split("=", 1)[1].strip()
                        break
            if private_key:
                break
    if not private_key:
        print("ERROR: PRIVATE_KEY not set. Set it in .env or environment.")
        sys.exit(1)

    # Connect
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    account = Account.from_key(private_key)
    balance = w3.eth.get_balance(account.address)
    print(f"Connected to {RPC_URL}")
    print(f"Account: {account.address}")
    print(f"Balance: {w3.from_wei(balance, 'ether')} ETH")

    if balance < w3.to_wei(0.01, "ether"):
        print("WARNING: Low balance — may not have enough for deployment + gas")

    # Track whether we created a VM (for cleanup)
    vm_ip = None
    created_vm = False
    success = False

    try:
        # Step 1: Deploy contracts (or reuse)
        if args.fund_address and args.verifier_address:
            fund_addr = Web3.to_checksum_address(args.fund_address)
            verifier_addr = Web3.to_checksum_address(args.verifier_address)
            nonce = w3.eth.get_transaction_count(account.address)
            # Read AM address from fund contract
            fund_abi = json.loads((ABI_DIR / "TheHumanFund.sol" / "TheHumanFund.json").read_text())["abi"]
            fund_tmp = w3.eth.contract(address=fund_addr, abi=fund_abi)
            am_addr = fund_tmp.functions.auctionManager().call()
            print(f"\nReusing contracts: fund={fund_addr}, verifier={verifier_addr}, am={am_addr}")
        else:
            fund_addr, verifier_addr, am_addr, nonce = deploy_contracts(w3, account)

        # Step 2: Create GCP TDX VM (or reuse)
        if args.vm_ip:
            vm_ip = args.vm_ip
            print(f"\nReusing VM at {vm_ip}")
            upload_enclave_files(vm_ip)
        elif args.skip_vm:
            print("\nSkipping VM creation")
        else:
            vm_ip, booted_from_snapshot = create_gcp_vm(force_fresh=args.fresh)
            created_vm = True
            if not wait_for_vm_ready(vm_ip):
                print("FATAL: VM not ready, aborting")
                sys.exit(1)

            # Auto-create snapshot on fresh boot (saves ~10-15 min on next run)
            if not booted_from_snapshot and not args.no_snapshot:
                if not create_snapshot_image():
                    # Snapshot failed but VM may be stopped — restart it
                    print("  Restarting VM after failed snapshot...")
                    try:
                        gcloud(f"compute instances start {GCP_VM_NAME} --zone={GCP_ZONE}", timeout=120)
                        wait_for_vm_ready(vm_ip)
                    except Exception as e:
                        print(f"  WARNING: Could not restart VM: {e}")

            upload_enclave_files(vm_ip)

        # Step 3: Get measurements and register image key
        if vm_ip:
            # Fresh RPC connection (SSH polling can exhaust local sockets)
            w3 = Web3(Web3.HTTPProvider(RPC_URL, request_kwargs={"timeout": 120}))
            nonce = w3.eth.get_transaction_count(account.address)
            measurements = get_vm_measurements()
            nonce = register_image_key(w3, account, verifier_addr, measurements["image_key"], nonce)

        # Step 4: Run the full auction (multiple epochs if requested)
        if vm_ip:
            num_epochs = args.epochs
            for epoch_i in range(num_epochs):
                print(f"\n{'=' * 60}")
                print(f"  EPOCH RUN {epoch_i + 1} / {num_epochs}")
                print(f"{'=' * 60}")
                # Refresh nonce before each epoch (sleep to avoid stale RPC reads)
                time.sleep(5)
                w3 = Web3(Web3.HTTPProvider(RPC_URL, request_kwargs={"timeout": 120}))
                nonce = w3.eth.get_transaction_count(account.address, "pending")
                try:
                    success = run_auction_e2e(w3, account, fund_addr, am_addr, vm_ip, nonce)
                except Exception as e:
                    print(f"\n  ❌ Epoch {epoch_i + 1} crashed: {e}")
                    success = False
                if not success:
                    print(f"\n  ⚠️  Epoch {epoch_i + 1} failed, continuing to next epoch...")
                    # Forfeit bond if stuck in execution
                    try:
                        w3 = Web3(Web3.HTTPProvider(RPC_URL, request_kwargs={"timeout": 120}))
                        fund = w3.eth.contract(address=fund_addr, abi=json.loads((ABI_DIR / "TheHumanFund.sol" / "TheHumanFund.json").read_text())["abi"])
                        epoch = fund.functions.currentEpoch().call()
                        am_tmp = w3.eth.contract(address=am_addr, abi=json.loads((ABI_DIR / "AuctionManager.sol" / "AuctionManager.json").read_text())["abi"])
                        phase = am_tmp.functions.getPhase(epoch).call()
                        if phase == 3:  # EXECUTION phase
                            deadline = am_tmp.functions.executionDeadline().call()
                            wait = max(0, deadline - int(time.time())) + 5
                            print(f"      Waiting {wait}s to forfeit bond...")
                            time.sleep(wait)
                            w3 = Web3(Web3.HTTPProvider(RPC_URL, request_kwargs={"timeout": 120}))
                            fund = w3.eth.contract(address=fund_addr, abi=json.loads((ABI_DIR / "TheHumanFund.sol" / "TheHumanFund.json").read_text())["abi"])
                            nonce = w3.eth.get_transaction_count(account.address)
                            tx = fund.functions.forfeitBond().build_transaction({
                                "from": account.address, "nonce": nonce, "gas": 200_000,
                                "maxFeePerGas": w3.eth.gas_price * 2,
                                "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
                            })
                            signed = account.sign_transaction(tx)
                            tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
                            w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
                            print(f"      Bond forfeited, continuing...")
                    except Exception as fe:
                        print(f"      Could not auto-forfeit: {fe}")
                    success = False  # Track overall
        else:
            print("\nSkipping auction (no VM)")

    finally:
        # Step 5: Always clean up the VM (unless --no-cleanup or reusing existing VM)
        if created_vm and not args.no_cleanup:
            cleanup()

    # Summary
    print("\n" + "=" * 60)
    if success:
        print("  E2E TEST PASSED")
        print("  Full security model verified on Base Sepolia:")
        print("    [x] Automata DCAP: genuine TDX hardware")
        print("    [x] Image registry: approved RTMR[1] + RTMR[2] + RTMR[3] (boot loader + kernel + app code)")
        print("    [x] REPORTDATA: sha256(inputHash + keccak256(sha256(action) + sha256(reasoning) + promptHash))")
        print("    [x] Auction: only winner can submit within execution window")
        print("    [x] Randomness seed: block.prevrandao prevents cherry-picking")
    else:
        print("  E2E TEST INCOMPLETE/FAILED")
    print("=" * 60)

    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
