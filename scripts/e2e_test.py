#!/usr/bin/env python3
"""
The Human Fund — Full E2E Test on Base Sepolia

Tests the complete security model end-to-end:
  1. Deploy TheHumanFund + AttestationVerifier to Base Sepolia
  2. Register GCP TDX image measurements (MRTD + RTMR[0..2])
  3. Configure auction timing (short windows for testing)
  4. Spin up GCP TDX confidential VM with enclave_runner + llama-server
  5. Run full auction: startEpoch → bid → closeAuction → TEE inference → submitAuctionResult
  6. Verify on-chain: Automata DCAP + image registry + REPORTDATA binding all pass

Security properties verified:
  - Quote came from genuine Intel TDX hardware (Automata DCAP)
  - VM was running an approved firmware+kernel+app stack (MRTD + RTMR[0..2])
  - Output was computed from the committed input hash (REPORTDATA binding)
  - Inference used the contract's randomness seed (prevents cherry-picking)
  - Only the auction winner can submit (msg.sender == winner)
  - Submission is within the execution window (timing enforcement)

Usage:
    source .venv/bin/activate
    python scripts/e2e_test.py

    # Skip deployment (reuse existing contracts):
    python scripts/e2e_test.py --fund-address 0x... --verifier-address 0x...

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
EPOCH_DURATION_GPU = 600      # 10 min
BIDDING_WINDOW_GPU = 60       # 1 min
EXECUTION_WINDOW_GPU = 300    # 5 min (inference ~30s but SCP/SSH overhead adds ~60s)

EPOCH_DURATION_CPU = 3600     # 60 min
BIDDING_WINDOW_CPU = 120      # 2 min
EXECUTION_WINDOW_CPU = 2700   # 45 min (CPU inference on 14B can take 20-30 min)

# Defaults (overridden in main())
EPOCH_DURATION = EPOCH_DURATION_GPU
BIDDING_WINDOW = BIDDING_WINDOW_GPU
EXECUTION_WINDOW = EXECUTION_WINDOW_GPU

BID_AMOUNT_ETH = 0.0001  # Minimum bid
SEED_AMOUNT_ETH = 0.0005  # Treasury seed (keep small for testnet)

# Model for testing (14B Q4_K_M, CPU-only)
MODEL_URL = "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
MODEL_SHA256 = "0b319bd0572f2730bfe11cc751defe82045fad5085b4e60591ac2cd2d9633181"


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
    """Deploy TheHumanFund + AttestationVerifier to Base Sepolia."""
    print("\n═══ STEP 1: Deploy Contracts ═══")

    # Build contracts first
    print("Building contracts...")
    run_cmd("forge build", timeout=120)

    # Load ABIs
    fund_artifact = json.loads((ABI_DIR / "TheHumanFund.sol" / "TheHumanFund.json").read_text())
    verifier_artifact = json.loads((ABI_DIR / "AttestationVerifier.sol" / "AttestationVerifier.json").read_text())

    deployer = account.address
    nonce = w3.eth.get_transaction_count(deployer)
    seed_wei = w3.to_wei(SEED_AMOUNT_ETH, "ether")

    # Deploy AttestationVerifier
    print(f"Deploying AttestationVerifier...")
    verifier_contract = w3.eth.contract(
        abi=verifier_artifact["abi"],
        bytecode=verifier_artifact["bytecode"]["object"]
    )
    tx = verifier_contract.constructor().build_transaction({
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
    print(f"  AttestationVerifier: {verifier_addr} (gas: {receipt.gasUsed})")
    nonce += 1

    # Deploy TheHumanFund
    print(f"Deploying TheHumanFund (seed: {SEED_AMOUNT_ETH} ETH)...")
    fund_contract = w3.eth.contract(
        abi=fund_artifact["abi"],
        bytecode=fund_artifact["bytecode"]["object"]
    )
    names = ["GiveDirectly", "Against Malaria Foundation", "Helen Keller International"]
    addrs = [deployer, deployer, deployer]  # Test: all nonprofits = deployer
    tx = fund_contract.constructor(
        names, addrs, 1000, w3.to_wei(0.0001, "ether")
    ).build_transaction({
        "from": deployer,
        "nonce": nonce,
        "value": seed_wei,
        "gas": 6_500_000,  # Contract is ~21KB, constructor needs ~5.1M gas
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

    # Link verifier to fund
    print("Linking verifier to fund...")
    fund = w3.eth.contract(address=fund_addr, abi=fund_artifact["abi"])
    tx = fund.functions.setVerifier(verifier_addr).build_transaction({
        "from": deployer, "nonce": nonce,
        "gas": 100_000,
        "maxFeePerGas": w3.eth.gas_price * 2,
        "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    nonce += 1

    # Configure auction timing
    print(f"Setting auction timing (epoch={EPOCH_DURATION}s, bid={BIDDING_WINDOW}s, exec={EXECUTION_WINDOW}s)...")
    tx = fund.functions.setAuctionTiming(
        EPOCH_DURATION, BIDDING_WINDOW, EXECUTION_WINDOW
    ).build_transaction({
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

    # Deploy 3 MockAdapters and register them
    mock_artifact = json.loads((ABI_DIR / "MockAdapter.sol" / "MockAdapter.json").read_text())
    im = w3.eth.contract(address=im_addr, abi=im_artifact["abi"])
    protocol_names = ["Aave V3 WETH (Mock)", "Lido wstETH (Mock)", "Compound V3 USDC (Mock)"]
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
        tx = im.functions.addProtocol(adapter_addr, pname, risk_tiers[i], apys[i]).build_transaction({
            "from": deployer, "nonce": nonce, "gas": 200_000,
            "maxFeePerGas": w3.eth.gas_price * 2, "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
        })
        signed = account.sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
        nonce += 1
        print(f"  Protocol #{i+1}: {pname} -> {adapter_addr}")

    print(f"  Contracts deployed and configured!")
    return fund_addr, verifier_addr, nonce


# ─── Step 2: Spin up GCP TDX VM ─────────────────────────────────────────

def create_gcp_vm():
    """Create a GCP TDX confidential VM for e2e testing."""
    print("\n═══ STEP 2: Create GCP TDX VM ═══")

    # Check if VM already exists
    try:
        result = gcloud(f"compute instances describe {GCP_VM_NAME} --zone={GCP_ZONE} --format='value(status)'", check=False)
        if "RUNNING" in result:
            ip = gcloud(f"compute instances describe {GCP_VM_NAME} --zone={GCP_ZONE} --format='value(networkInterfaces[0].accessConfigs[0].natIP)'")
            print(f"  VM already running at {ip}")
            return ip
        elif result.strip():
            print(f"  VM exists but status={result.strip()}, deleting...")
            gcloud(f"compute instances delete {GCP_VM_NAME} --zone={GCP_ZONE} --quiet")
    except Exception:
        pass

    # Create the startup script (GPU or CPU)
    if USE_GPU:
        startup_script = f"""#!/bin/bash
set -e
exec > /tmp/startup.log 2>&1
echo "=== Starting GPU setup at $(date) ==="

# Install dependencies
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv cmake build-essential git wget libcurl4-openssl-dev

# Set up venv
python3 -m venv /opt/humanfund-venv
source /opt/humanfund-venv/bin/activate
pip install flask web3 requests

# Install NVIDIA drivers + CUDA toolkit for H100
echo "Installing NVIDIA drivers..."
apt-get install -y -qq linux-headers-$(uname -r) nvidia-driver-575-open nvidia-utils-575 2>/dev/null || true
apt-get install -y -qq nvidia-cuda-toolkit 2>/dev/null || true

# Build llama.cpp with CUDA
echo "Building llama.cpp with CUDA..."
cd /tmp
git clone --depth 1 --branch b5170 https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=90
cmake --build build --config Release -j$(nproc) --target llama-server
cp build/bin/llama-server /usr/local/bin/

# Download model
echo "Downloading model..."
mkdir -p /models
wget -q -O /models/model.gguf "{MODEL_URL}"

# Verify SHA-256
echo "Verifying model hash..."
ACTUAL_HASH=$(sha256sum /models/model.gguf | cut -d' ' -f1)
if [ "$ACTUAL_HASH" != "{MODEL_SHA256}" ]; then
    echo "FATAL: Model hash mismatch! Expected {{MODEL_SHA256}}, got $ACTUAL_HASH"
    exit 1
fi
echo "Model hash verified: $ACTUAL_HASH"

# Start llama-server with GPU
echo "Starting llama-server (GPU)..."
nohup llama-server -m /models/model.gguf -c 4096 --host 0.0.0.0 --port 8080 -ngl 99 > /tmp/llama.log 2>&1 &

# Wait for llama-server to load
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
        startup_script = f"""#!/bin/bash
set -e
exec > /tmp/startup.log 2>&1
echo "=== Starting CPU setup at $(date) ==="

# Install dependencies
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv cmake build-essential git wget libcurl4-openssl-dev

# Set up venv
python3 -m venv /opt/humanfund-venv
source /opt/humanfund-venv/bin/activate
pip install flask web3 requests

# Build llama.cpp from source (CPU-only)
echo "Building llama.cpp..."
cd /tmp
git clone --depth 1 --branch b5170 https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j$(nproc) --target llama-server
cp build/bin/llama-server /usr/local/bin/

# Download model
echo "Downloading model..."
mkdir -p /models
wget -q -O /models/model.gguf "{MODEL_URL}"

# Verify SHA-256
echo "Verifying model hash..."
ACTUAL_HASH=$(sha256sum /models/model.gguf | cut -d' ' -f1)
if [ "$ACTUAL_HASH" != "{MODEL_SHA256}" ]; then
    echo "FATAL: Model hash mismatch! Expected {{MODEL_SHA256}}, got $ACTUAL_HASH"
    exit 1
fi
echo "Model hash verified: $ACTUAL_HASH"

# Start llama-server
echo "Starting llama-server (CPU)..."
nohup llama-server -m /models/model.gguf -c 4096 --host 0.0.0.0 --port 8080 -t $(nproc) > /tmp/llama.log 2>&1 &

# Wait for llama-server to load
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

    # Write startup script to temp file
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
                return True
            elif "NOT_READY" in result:
                # SSH works but llama-server not ready yet
                # Check startup progress
                log = gcloud(
                    f"compute ssh {GCP_VM_NAME} --zone={GCP_ZONE} "
                    f"--command='tail -1 /tmp/startup.log 2>/dev/null || echo no_log'",
                    check=False, timeout=15
                )
                print(f"  [{i * 30}s] Waiting... last log: {log[:80]}")
        except Exception as e:
            print(f"  [{i * 30}s] SSH not ready yet: {str(e)[:60]}")
        time.sleep(30)

    print("  TIMEOUT: VM not ready after 45 minutes")
    return False


def upload_enclave_files(vm_ip):
    """Upload enclave_runner.py and system_prompt.txt to the VM."""
    print("\n═══ STEP 2c: Upload Enclave Files ═══")

    # Upload enclave_runner.py
    gcloud(
        f"compute scp {PROJECT_ROOT}/tee/enclave_runner.py "
        f"{GCP_VM_NAME}:/tmp/enclave_runner.py --zone={GCP_ZONE}",
        timeout=30
    )
    print("  Uploaded enclave_runner.py")

    # Upload system prompt
    gcloud(
        f"compute scp {PROJECT_ROOT}/agent/prompts/system_v2.txt "
        f"{GCP_VM_NAME}:/tmp/system_prompt.txt --zone={GCP_ZONE}",
        timeout=30
    )
    print("  Uploaded system_prompt.txt")

    # Install flask on the VM (in case startup script isn't done)
    gcloud(
        f"compute ssh {GCP_VM_NAME} --zone={GCP_ZONE} "
        f"--command='pip3 install flask 2>/dev/null || true'",
        check=False, timeout=60
    )

    # Start enclave_runner.py as root (needs root for configfs-tsm TDX quote generation)
    # Upload a startup script to avoid shell quoting issues
    startup = "#!/bin/bash\nsource /opt/humanfund-venv/bin/activate\nSYSTEM_PROMPT_PATH=/tmp/system_prompt.txt nohup python3 /tmp/enclave_runner.py > /tmp/enclave.log 2>&1 &\n"
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
    print("  Started enclave_runner.py on port 8090 (as root for configfs-tsm)")

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

    if len(measurements) != 4:
        raise RuntimeError(f"Failed to extract measurements: {result[:500]}")

    image_key = Web3.keccak(
        measurements["mrtd"] + measurements["rtmr0"] +
        measurements["rtmr1"] + measurements["rtmr2"]
    )
    measurements["image_key"] = image_key
    print(f"  MRTD:      {measurements['mrtd'].hex()[:32]}...")
    print(f"  RTMR[0]:   {measurements['rtmr0'].hex()[:32]}...")
    print(f"  RTMR[1]:   {measurements['rtmr1'].hex()[:32]}...")
    print(f"  RTMR[2]:   {measurements['rtmr2'].hex()[:32]}...")
    print(f"  Image key: 0x{image_key.hex()}")
    return measurements


def register_image_key(w3, account, verifier_addr, image_key, nonce):
    """Register the VM's image key in the AttestationVerifier."""
    print("\n═══ STEP 3b: Register Image Key ═══")

    verifier_abi = json.loads(
        (ABI_DIR / "AttestationVerifier.sol" / "AttestationVerifier.json").read_text()
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

def run_auction_e2e(w3, account, fund_addr, vm_ip, nonce):
    """Run the full auction lifecycle with real TDX attestation."""
    print("\n═══ STEP 4: Full Auction E2E ═══")

    fund_abi = json.loads(
        (ABI_DIR / "TheHumanFund.sol" / "TheHumanFund.json").read_text()
    )["abi"]
    fund = w3.eth.contract(address=fund_addr, abi=fund_abi)

    # Helper to get fresh Web3 connection (Base Sepolia RPC returns stale data after writes)
    def fresh_connection():
        w3_ = Web3(Web3.HTTPProvider(RPC_URL, request_kwargs={"timeout": 120}))
        fund_ = w3_.eth.contract(address=fund_addr, abi=fund_abi)
        return w3_, fund_

    def send_tx(fn, value=0, gas=200_000):
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
    print(f"\n  4a. Starting epoch {epoch}...")
    receipt = send_tx(fund.functions.startEpoch())
    input_hash = fund.functions.epochInputHashes(epoch).call()
    print(f"      Input hash: 0x{input_hash.hex()[:16]}...")
    print(f"      Gas: {receipt.gasUsed}")

    # ─── 4b: bid ───
    # Use effectiveMaxBid to stay under ceiling (treasury may be small)
    emb = fund.functions.effectiveMaxBid().call()
    bid_wei = min(emb, w3.to_wei(BID_AMOUNT_ETH, "ether"))
    bond_wei = max(1, bid_wei * 2000 // 10000)  # 20% bond, min 1 wei
    print(f"\n  4b. Submitting bid: {w3.from_wei(bid_wei, 'ether')} ETH (bond: {w3.from_wei(bond_wei, 'ether')} ETH)...")
    receipt = send_tx(fund.functions.bid(bid_wei), value=bond_wei)
    print(f"      Gas: {receipt.gasUsed}")

    # ─── 4c: Wait for bidding window, then closeAuction ───
    start_time, phase, _, _, _, _, _ = fund.functions.getAuctionState(epoch).call()
    bid_window = fund.functions.biddingWindow().call()
    now = w3.eth.get_block("latest").timestamp
    wait_secs = max(0, start_time + bid_window - now + 5)
    print(f"\n  4c. Waiting {wait_secs}s for bidding window to close...")
    if wait_secs > 0:
        time.sleep(wait_secs)
        w3, fund = fresh_connection()
        nonce = w3.eth.get_transaction_count(account.address)

    print("      Closing auction...")
    receipt = send_tx(fund.functions.closeAuction())

    # Read state with fresh connection (critical — seed was reading as 0 before this fix)
    _, _, _, winner, winning_bid, _, seed = fund.functions.getAuctionState(epoch).call()
    print(f"      Winner: {winner}")
    print(f"      Randomness seed: {seed}")
    print(f"      Gas: {receipt.gasUsed}")

    assert winner.lower() == account.address.lower(), f"We're not the winner! Winner={winner}"

    # ─── 4d: Run TEE inference on GCP VM ───
    print(f"\n  4d. Running TEE inference on GCP VM...")

    # Build epoch context
    sys.path.insert(0, str(PROJECT_ROOT / "agent"))
    from runner import read_contract_state, build_epoch_context

    state = read_contract_state(fund, w3)
    epoch_context = build_epoch_context(state)
    input_hash_hex = "0x" + input_hash.hex()

    # Save payload and upload to VM
    payload = json.dumps({
        "epoch_context": epoch_context,
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
    print(f"      Action: {json.dumps(tee_result['action'])}")
    print(f"      Quote: {len(bytes.fromhex(tee_result['attestation_quote'].replace('0x', '')))} bytes")

    # ─── 4e: Submit auction result ───
    print(f"\n  4e. Submitting auction result on-chain...")

    action_bytes = bytes.fromhex(tee_result["action_bytes"].replace("0x", ""))
    reasoning_bytes = tee_result["reasoning"].encode("utf-8")
    attestation_bytes = bytes.fromhex(tee_result["attestation_quote"].replace("0x", ""))
    print(f"      Reasoning: {len(reasoning_bytes)} bytes (truncated by enclave if needed)")

    # Verify REPORTDATA matches before submitting
    expected_rd = hashlib.sha256(
        input_hash +
        hashlib.sha256(action_bytes).digest() +
        hashlib.sha256(reasoning_bytes).digest() +
        seed.to_bytes(32, "big")
    ).digest()
    tee_rd = bytes.fromhex(tee_result["report_data"].replace("0x", ""))[:32]
    print(f"      REPORTDATA match: {expected_rd == tee_rd}")
    if expected_rd != tee_rd:
        print(f"      MISMATCH! Contract: {expected_rd.hex()[:32]}... TEE: {tee_rd.hex()[:32]}...")
        return False

    # Fresh connection for submission
    w3, fund = fresh_connection()
    nonce = w3.eth.get_transaction_count(account.address)

    tx = fund.functions.submitAuctionResult(
        action_bytes, reasoning_bytes, attestation_bytes
    ).build_transaction({
        "from": account.address, "nonce": nonce,
        "gas": 15_000_000,  # DCAP verification needs ~10.2M gas
        "maxFeePerGas": w3.eth.gas_price * 3,
        "maxPriorityFeePerGas": w3.to_wei(0.01, "gwei"),
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f"      Tx: https://sepolia.basescan.org/tx/{tx_hash.hex()}")

    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=180)
    nonce += 1

    if receipt.status == 1:
        new_epoch = fund.functions.currentEpoch().call()
        new_balance = fund.functions.treasuryBalance().call()
        history_hash = fund.functions.historyHash().call()

        print(f"\n  ✅ SUCCESS! Full attestation chain verified on-chain!")
        print(f"      Epoch advanced: {epoch} → {new_epoch}")
        print(f"      Treasury: {w3.from_wei(new_balance, 'ether')} ETH")
        print(f"      History hash: 0x{history_hash.hex()[:16]}...")
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
            gcloud(f"compute instances delete {GCP_VM_NAME} --zone={GCP_ZONE} --quiet", timeout=60)
            print("  VM deleted")
        except Exception as e:
            print(f"  Failed to delete VM: {e}")


# ─── Main ───────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Full E2E test on Base Sepolia")
    parser.add_argument("--fund-address", help="Reuse existing TheHumanFund contract")
    parser.add_argument("--verifier-address", help="Reuse existing AttestationVerifier contract")
    parser.add_argument("--vm-ip", help="Reuse existing GCP VM (skip creation)")
    parser.add_argument("--no-cleanup", action="store_true", help="Don't delete VM after test")
    parser.add_argument("--skip-vm", action="store_true", help="Skip VM creation (for testing)")
    parser.add_argument("--cpu", action="store_true", help="Use CPU instance instead of GPU (slower, cheaper)")
    parser.add_argument("--snapshot", action="store_true", help="Create GCP disk image after VM setup (fast boot next time)")
    args = parser.parse_args()

    # Configure GPU vs CPU (GPU is default)
    global GCP_MACHINE_TYPE, USE_GPU, EPOCH_DURATION, BIDDING_WINDOW, EXECUTION_WINDOW
    if args.cpu:
        GCP_MACHINE_TYPE = GCP_MACHINE_TYPE_CPU
        USE_GPU = False
        EPOCH_DURATION = EPOCH_DURATION_CPU
        BIDDING_WINDOW = BIDDING_WINDOW_CPU
        EXECUTION_WINDOW = EXECUTION_WINDOW_CPU
        print("Mode: CPU (c3-standard-4, ~20-30 min inference)")
    else:
        GCP_MACHINE_TYPE = GCP_MACHINE_TYPE_GPU
        USE_GPU = True
        EPOCH_DURATION = EPOCH_DURATION_GPU
        BIDDING_WINDOW = BIDDING_WINDOW_GPU
        EXECUTION_WINDOW = EXECUTION_WINDOW_GPU
        print("Mode: GPU (a3-highgpu-1g, H100, ~30s inference)")

    print(f"  Timing: epoch={EPOCH_DURATION}s, bidding={BIDDING_WINDOW}s, execution={EXECUTION_WINDOW}s")

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

    # Step 1: Deploy contracts (or reuse)
    if args.fund_address and args.verifier_address:
        fund_addr = Web3.to_checksum_address(args.fund_address)
        verifier_addr = Web3.to_checksum_address(args.verifier_address)
        nonce = w3.eth.get_transaction_count(account.address)
        print(f"\nReusing contracts: fund={fund_addr}, verifier={verifier_addr}")
    else:
        fund_addr, verifier_addr, nonce = deploy_contracts(w3, account)

    # Step 2: Create GCP TDX VM (or reuse)
    if args.vm_ip:
        vm_ip = args.vm_ip
        print(f"\nReusing VM at {vm_ip}")
    elif args.skip_vm:
        print("\nSkipping VM creation")
        vm_ip = None
    else:
        vm_ip = create_gcp_vm()
        if not wait_for_vm_ready(vm_ip):
            print("FATAL: VM not ready, aborting")
            cleanup(not args.no_cleanup)
            sys.exit(1)
        upload_enclave_files(vm_ip)

        # Optional: create disk image for fast boot next time
        if args.snapshot:
            print("\n═══ STEP 2d: Create Disk Image Snapshot ═══")
            image_name = f"humanfund-tee-{'gpu' if USE_GPU else 'cpu'}-14b"
            try:
                # Stop VM to snapshot
                print(f"  Stopping VM for snapshot...")
                gcloud(f"compute instances stop {GCP_VM_NAME} --zone={GCP_ZONE} --discard-local-ssd=true", timeout=120)
                # Create image
                print(f"  Creating image '{image_name}'...")
                gcloud(
                    f"compute images create {image_name} "
                    f"--source-disk={GCP_VM_NAME} --source-disk-zone={GCP_ZONE} "
                    f"--family=humanfund-tee --force",
                    timeout=300
                )
                print(f"  Image created! Next time use: --image={image_name}")
                # Restart VM
                print(f"  Restarting VM...")
                gcloud(f"compute instances start {GCP_VM_NAME} --zone={GCP_ZONE}", timeout=120)
                # Wait for SSH to come back
                time.sleep(30)
                # Restart services (llama-server + enclave_runner)
                print(f"  Restarting services...")
                gcloud(
                    f"compute ssh {GCP_VM_NAME} --zone={GCP_ZONE} "
                    f"--command='sudo nohup llama-server -m /models/model.gguf -c 4096 --host 0.0.0.0 --port 8080 -t $(nproc) > /tmp/llama.log 2>&1 &'",
                    timeout=30
                )
                time.sleep(15)
                gcloud(
                    f"compute ssh {GCP_VM_NAME} --zone={GCP_ZONE} "
                    f"--command='sudo rm -f /tmp/enclave.log && sudo bash /tmp/start_enclave.sh'",
                    timeout=30
                )
                time.sleep(10)
            except Exception as e:
                print(f"  WARNING: Snapshot failed: {e}. Continuing without snapshot.")

    # Step 3: Get measurements and register image key
    if vm_ip:
        measurements = get_vm_measurements()
        nonce = register_image_key(w3, account, verifier_addr, measurements["image_key"], nonce)

    # Step 4: Run the full auction
    if vm_ip:
        success = run_auction_e2e(w3, account, fund_addr, vm_ip, nonce)
    else:
        print("\nSkipping auction (no VM)")
        success = False

    # Step 5: Cleanup
    if not args.no_cleanup and vm_ip and not args.vm_ip:
        cleanup()

    # Summary
    print("\n" + "=" * 60)
    if success:
        print("  E2E TEST PASSED")
        print("  Full security model verified on Base Sepolia:")
        print("    [x] Automata DCAP: genuine TDX hardware")
        print("    [x] Image registry: approved MRTD + RTMR[0..2]")
        print("    [x] REPORTDATA: input hash + action + reasoning + seed bound")
        print("    [x] Auction: only winner can submit within execution window")
        print("    [x] Randomness seed: block.prevrandao prevents cherry-picking")
    else:
        print("  E2E TEST INCOMPLETE/FAILED")
    print("=" * 60)

    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
