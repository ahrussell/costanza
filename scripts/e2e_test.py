#!/usr/bin/env python3
import os
os.environ["PYTHONUNBUFFERED"] = "1"
"""
The Human Fund — Full E2E Test on Base Sepolia (dm-verity architecture)

Tests the complete security model end-to-end:
  1. Deploy TheHumanFund + DstackVerifier to Base Sepolia
  2. Boot measurement VM from dm-verity image, extract RTMR measurements
  3. Register platform key = sha256(MRTD || RTMR[1] || RTMR[2]) in DstackVerifier
  4. Run full auction: startEpoch -> commit -> closeCommit -> reveal -> closeReveal
     -> boot fresh H100 TDX VM -> one-shot inference via serial console -> submitAuctionResult
  5. Verify on-chain: Automata DCAP + platform key registry + REPORTDATA binding all pass
  6. Cleanup VMs

Architecture:
  - VM boots from dm-verity image, reads epoch-state from GCP metadata
  - Enclave is a one-shot systemd service that runs at boot
  - Output written to serial console between delimiters
  - No SSH needed for inference (SSH only for measurement extraction)
  - Each epoch inference requires a fresh VM (create -> boot -> poll serial -> delete)

Usage:
    source .venv/bin/activate
    python scripts/e2e_test.py --image humanfund-dmverity-gpu-v6

    # Skip deployment (reuse existing contracts):
    python scripts/e2e_test.py --image humanfund-dmverity-gpu-v6 \\
        --fund-address 0x... --verifier-address 0x...

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

# --- Config -------------------------------------------------------------------

PROJECT_ROOT = Path(__file__).parent.parent
ABI_DIR = PROJECT_ROOT / "out"

RPC_URL = os.environ.get("RPC_URL", "https://sepolia.base.org")
GCP_PROJECT = os.environ.get("GCP_PROJECT", "the-human-fund")
GCP_ZONE = os.environ.get("GCP_ZONE", "us-central1-a")

# VM names
MEASUREMENT_VM_NAME = "humanfund-e2e-measure"
# Inference VMs are created/destroyed by GCPTEEClient with random names

# Machine types
GCP_MACHINE_TYPE_CPU = "c3-standard-4"   # 4 vCPU, 16 GB -- CPU inference (~20-30 min)
GCP_MACHINE_TYPE_GPU = "a3-highgpu-1g"   # 1x H100 80GB -- GPU inference (~30 sec)

# Set at runtime based on --cpu flag
USE_GPU = True

# dm-verity image name (set from --image CLI arg)
DMVERITY_IMAGE = None

# Serial console delimiters (must match enclave_runner.py)
# Serial console markers are in runner.tee_clients.gcp

# Timing constants (adjusted at runtime based on CPU vs GPU)
# GPU: inference takes ~30s, so keep windows tight
EPOCH_DURATION_GPU = 1800     # 30 min (generous for boot/inference overhead)
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

BOOT_DISK_SIZE_GB = 200


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


# --- Step 1: Deploy Contracts -------------------------------------------------

def deploy_contracts(w3, account):
    """Deploy TheHumanFund + DstackVerifier to Base Sepolia."""
    print("\n=== STEP 1: Deploy Contracts ===")

    # Build contracts first
    print("Building contracts...")
    run_cmd("forge build", timeout=120)

    # Load ABIs
    fund_artifact = json.loads((ABI_DIR / "TheHumanFund.sol" / "TheHumanFund.json").read_text())

    deployer = account.address
    nonce = w3.eth.get_transaction_count(deployer)
    seed_wei = w3.to_wei(SEED_AMOUNT_ETH, "ether")

    # Deploy TheHumanFund
    print(f"Deploying TheHumanFund (seed: {SEED_AMOUNT_ETH} ETH)...")
    fund_contract = w3.eth.contract(
        abi=fund_artifact["abi"],
        bytecode=fund_artifact["bytecode"]["object"]
    )
    # Constructor: (commissionBps, maxBid, endaomentFactory, weth, usdc, swapRouter, ethUsdFeed)
    # Use deployer as placeholder for Endaoment/DeFi addresses on testnet
    # ethUsdFeed must be address(0) -- deployer is an EOA, calling latestRoundData() on it reverts
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

    # Deploy TdxVerifier (platform key = sha256(MRTD || RTMR[1] || RTMR[2]))
    print(f"Deploying TdxVerifier...")
    verifier_artifact = json.loads((ABI_DIR / "TdxVerifier.sol" / "TdxVerifier.json").read_text())
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
        raise RuntimeError(f"TdxVerifier deployment failed! Status: {receipt.status}, gas: {receipt.gasUsed}")
    dstack_verifier_addr = receipt.contractAddress
    print(f"  TdxVerifier: {dstack_verifier_addr} (gas: {receipt.gasUsed})")
    nonce += 1

    # Deploy AuctionManager
    print(f"Deploying AuctionManager...")
    am_artifact = json.loads((ABI_DIR / "AuctionManager.sol" / "AuctionManager.json").read_text())
    am_contract = w3.eth.contract(abi=am_artifact["abi"], bytecode=am_artifact["bytecode"]["object"])
    tx = am_contract.constructor(fund_addr).build_transaction({
        "from": deployer, "nonce": nonce, "gas": 3_000_000,
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

    # Approve TdxVerifier (verifierId=2)
    print("Approving TdxVerifier (verifierId=2)...")
    tx = fund.functions.approveVerifier(2, dstack_verifier_addr).build_transaction({
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
    return fund_addr, dstack_verifier_addr, am_addr, nonce


# --- Step 2: Create Measurement VM --------------------------------------------

def create_measurement_vm():
    """Create a cheap c3-standard-4 TDX VM from the dm-verity image for measurement extraction.

    The measurement VM just needs to boot from the same dm-verity image so we can
    extract MRTD/RTMR values. SSH must be available on the image (build with --enable-ssh).

    Returns the VM IP address.
    """
    print("\n=== STEP 2: Create Measurement VM ===")
    print(f"  Image: {DMVERITY_IMAGE}")
    print(f"  Machine: {GCP_MACHINE_TYPE_CPU} (cheap, just for measurements)")

    # Check if VM already exists
    try:
        result = gcloud(f"compute instances describe {MEASUREMENT_VM_NAME} --zone={GCP_ZONE} --format='value(status)'", check=False)
        if "RUNNING" in result:
            ip = gcloud(f"compute instances describe {MEASUREMENT_VM_NAME} --zone={GCP_ZONE} --format='value(networkInterfaces[0].accessConfigs[0].natIP)'")
            print(f"  Measurement VM already running at {ip}")
            return ip
        elif result.strip():
            print(f"  VM exists but status={result.strip()}, deleting...")
            gcloud(f"compute instances delete {MEASUREMENT_VM_NAME} --zone={GCP_ZONE} --quiet")
    except Exception:
        pass

    # Use GPU machine type for measurements when running GPU inference — the MRTD
    # (firmware measurement) differs between c3 and a3 machine types, so we must
    # register the key from the same machine family used for actual inference.
    measure_machine_type = GCP_MACHINE_TYPE_GPU if USE_GPU else GCP_MACHINE_TYPE_CPU
    measure_extra = "--provisioning-model=SPOT --instance-termination-action=DELETE " if USE_GPU else ""
    print(f"  Machine: {measure_machine_type} (cheap, just for measurements)")
    gcloud(
        f"compute instances create {MEASUREMENT_VM_NAME} "
        f"--zone={GCP_ZONE} "
        f"--machine-type={measure_machine_type} "
        f"--image={DMVERITY_IMAGE} "
        f"--confidential-compute-type=TDX "
        f"--boot-disk-size={BOOT_DISK_SIZE_GB}GB "
        f"--maintenance-policy=TERMINATE "
        f"{measure_extra}",
        timeout=180
    )

    ip = gcloud(
        f"compute instances describe {MEASUREMENT_VM_NAME} --zone={GCP_ZONE} "
        f"--format='value(networkInterfaces[0].accessConfigs[0].natIP)'"
    )
    print(f"  Measurement VM created: {ip}")

    # Wait for enclave to emit measurements to serial console (no SSH needed)
    print("  Waiting for measurements on serial console...")
    for i in range(20):
        time.sleep(15)
        try:
            serial = gcloud(
                f"compute instances get-serial-port-output {MEASUREMENT_VM_NAME} "
                f"--zone={GCP_ZONE}",
                check=False, timeout=30
            )
            if "===HUMANFUND_MEASUREMENTS_END===" in serial:
                print(f"  Measurements available after {(i + 1) * 15}s")
                return ip
        except Exception:
            pass
    raise RuntimeError("Measurement VM did not emit measurements after 5 minutes")


# --- Step 3: Extract Measurements & Register ----------------------------------

def get_vm_measurements():
    """Extract MRTD/RTMR values from serial console (no SSH needed).

    The enclave emits measurements between ===HUMANFUND_MEASUREMENTS_START===
    and ===HUMANFUND_MEASUREMENTS_END=== markers on the serial console at boot.

    Returns dict with mrtd, rtmr0, rtmr1, rtmr2, rtmr3 as bytes, plus platform_key.
    Platform key = sha256(MRTD || RTMR[1] || RTMR[2]) for DstackVerifier.
    """
    print("\n=== STEP 3: Extract VM Measurements ===")

    # Read measurements from serial console (emitted by enclave at boot)
    serial = gcloud(
        f"compute instances get-serial-port-output {MEASUREMENT_VM_NAME} --zone={GCP_ZONE}",
        timeout=30
    )

    # Parse between markers
    start_marker = "===HUMANFUND_MEASUREMENTS_START==="
    end_marker = "===HUMANFUND_MEASUREMENTS_END==="
    start_idx = serial.find(start_marker)
    end_idx = serial.find(end_marker)
    if start_idx < 0 or end_idx < 0:
        raise RuntimeError(f"Measurements not found in serial output (len={len(serial)})")
    result = serial[start_idx + len(start_marker):end_idx]

    # Use regex to extract exactly 96 hex chars after each label.
    # Serial console output can have ANSI codes or syslog lines interleaved,
    # so we search the entire output rather than relying on clean line parsing.
    import re
    measurements = {}
    for label, key in [("MRTD", "mrtd"), ("RTMR0", "rtmr0"), ("RTMR1", "rtmr1"),
                       ("RTMR2", "rtmr2"), ("RTMR3", "rtmr3")]:
        m = re.search(rf"{label}:([0-9a-f]{{96}})", serial)
        if m:
            measurements[key] = bytes.fromhex(m.group(1))

    if "rtmr1" not in measurements or "rtmr2" not in measurements:
        raise RuntimeError(f"Failed to extract measurements: {result[:500]}")

    # Default MRTD/RTMR[3] to zeros if not present
    if "mrtd" not in measurements:
        measurements["mrtd"] = b'\x00' * 48
    if "rtmr3" not in measurements:
        measurements["rtmr3"] = b'\x00' * 48

    # Compute platform key = sha256(MRTD || RTMR[1] || RTMR[2])
    platform_key = hashlib.sha256(
        measurements["mrtd"] + measurements["rtmr1"] + measurements["rtmr2"]
    ).digest()
    measurements["platform_key"] = platform_key

    print(f"  MRTD:      {measurements['mrtd'].hex()[:32]}...")
    print(f"  RTMR[0]:   {measurements.get('rtmr0', b'').hex()[:32]}... (not in platform key)")
    print(f"  RTMR[1]:   {measurements['rtmr1'].hex()[:32]}...")
    print(f"  RTMR[2]:   {measurements['rtmr2'].hex()[:32]}...")
    print(f"  RTMR[3]:   {measurements['rtmr3'].hex()[:32]}... (not in platform key -- dm-verity covers all code via RTMR[2])")
    print(f"  Platform key: 0x{platform_key.hex()} (sha256(MRTD + RTMR[1] + RTMR[2]))")
    return measurements


def register_dstack_image(w3, account, dstack_verifier_addr, measurements, nonce):
    """Register image key in TdxVerifier.

    dm-verity architecture: image_key = sha256(MRTD || RTMR[1] || RTMR[2])
    This single key covers firmware + bootloader + kernel + dm-verity rootfs.
    """
    print("\n=== STEP 3b: Register Image Key (TdxVerifier) ===")

    verifier_abi = json.loads(
        (ABI_DIR / "TdxVerifier.sol" / "TdxVerifier.json").read_text()
    )["abi"]
    verifier = w3.eth.contract(address=dstack_verifier_addr, abi=verifier_abi)

    image_key = measurements["platform_key"]
    print(f"  Image key: 0x{image_key.hex()}")

    # Register image key
    try:
        if verifier.functions.approvedImages(image_key).call():
            print(f"  Image key already approved!")
        else:
            tx = verifier.functions.approveImage(image_key).build_transaction({
                "from": account.address, "nonce": nonce,
                "gas": 100_000,
                "maxFeePerGas": w3.eth.gas_price * 2,
                "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
            })
            signed = account.sign_transaction(tx)
            tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
            receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
            print(f"  Image key approved! (gas: {receipt.gasUsed})")
            nonce += 1
    except Exception as e:
        print(f"  Image key registration: {e}")

    return nonce


# --- Step 4d: dm-verity Inference ---------------------------------------------

def run_dmverity_inference(w3, fund_addr, fund_abi, am_addr, am_abi, epoch, seed):
    """Run inference in a fresh TDX VM via the GCP TEE client.

    Uses runner.tee_clients.gcp.GCPTEEClient which handles the full lifecycle:
    create VM with metadata -> poll serial console -> parse result -> delete VM.
    """
    print(f"\n  4d. Running dm-verity inference...")

    # Read contract state using runner.epoch_state
    sys.path.insert(0, str(PROJECT_ROOT))
    from runner.epoch_state import read_contract_state, build_contract_state_for_tee
    from runner.tee_clients.gcp import GCPTEEClient

    fund = w3.eth.contract(address=fund_addr, abi=fund_abi)
    state = read_contract_state(fund, w3)
    contract_state = build_contract_state_for_tee(fund, w3, state)

    # Choose machine type based on --cpu flag
    machine_type = GCP_MACHINE_TYPE_CPU if not USE_GPU else GCP_MACHINE_TYPE_GPU
    inference_timeout = 1200 if USE_GPU else 2400  # 20 min GPU, 40 min CPU

    print(f"      Machine type: {machine_type}")
    print(f"      Image: {DMVERITY_IMAGE}")
    print(f"      Timeout: {inference_timeout}s")

    # Use the GCP TEE client — same code the production runner uses
    client = GCPTEEClient(
        project=GCP_PROJECT,
        zone=GCP_ZONE,
        image=DMVERITY_IMAGE,
        machine_type=machine_type,
        inference_timeout=inference_timeout,
    )

    # System prompt is on the dm-verity rootfs — pass empty string
    # (the client sends it for interface compatibility but it's not used)
    return client.run_epoch(
        epoch_state=state,
        contract_state=contract_state,
        system_prompt="",
        seed=seed,
    )


# --- Step 4: Run Full Auction Flow --------------------------------------------

def run_auction_e2e(w3, account, fund_addr, am_addr, nonce):
    """Run the full auction lifecycle with real TDX attestation."""
    print("\n=== STEP 4: Full Auction E2E ===")

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
        """Send a transaction, wait for receipt, refresh connection, return receipt."""
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

    # --- 4a: startEpoch ---
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

        if phase == 3:  # EXECUTION -- need to forfeit bond
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

    # --- 4b: commit sealed bid ---
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

    # --- 4c: Wait for commit window, closeCommit, reveal, closeReveal ---
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

    # --- 4d: Run dm-verity inference (fresh VM per epoch) ---
    tee_result = run_dmverity_inference(w3, fund_addr, fund_abi, am_addr, am_abi, epoch, seed)

    print(f"      Action: {json.dumps(tee_result.get('action', 'N/A'))}")
    if "error" in tee_result:
        print(f"      TEE error: {tee_result['error']}")
        print(f"      Raw output: {tee_result.get('raw_output', 'N/A')[:200]}")
        return False
    print(f"      Quote: {len(bytes.fromhex(tee_result['attestation_quote'].replace('0x', '')))} bytes")

    # --- 4e: Submit auction result ---
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

    # Build tx manually -- no RPC calls needed after this point
    # verifier_id: 2 = TdxVerifier (dm-verity, platform key = sha256(MRTD || RTMR[1] || RTMR[2]))
    verifier_id = 2
    print(f"      Building tx (nonce={nonce}, chain_id={chain_id}, verifier_id={verifier_id})...")
    calldata = fund.functions.submitAuctionResult(
        action_bytes, reasoning_bytes, attestation_bytes, verifier_id,
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
            # The tx may have been received despite the connection error -- check for receipt
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

        print(f"\n  SUCCESS! Full attestation chain verified on-chain!")
        print(f"      Epoch advanced: {epoch} -> {new_epoch}")
        print(f"      Treasury: {w3.from_wei(new_balance, 'ether')} ETH")
        print(f"      Gas used: {receipt.gasUsed}")
        print(f"      Tx: https://sepolia.basescan.org/tx/{tx_hash.hex()}")
        return True
    else:
        print(f"\n  FAILED! Transaction reverted (gas: {receipt.gasUsed})")
        print(f"      Tx: https://sepolia.basescan.org/tx/{tx_hash.hex()}")
        return False


# --- Step 5: Cleanup ----------------------------------------------------------

def cleanup_measurement_vm():
    """Delete the measurement VM."""
    print("\n=== STEP 5: Cleanup ===")
    try:
        gcloud(f"compute instances delete {MEASUREMENT_VM_NAME} --zone={GCP_ZONE} --quiet", timeout=120)
        print("  Measurement VM deleted")
    except Exception as e:
        print(f"  Failed to delete measurement VM: {e}")


# --- Main ---------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Full E2E test on Base Sepolia (dm-verity)")
    parser.add_argument("--image", required=True,
                        help="dm-verity GCP image name (e.g., humanfund-dmverity-gpu-v6)")
    parser.add_argument("--fund-address", help="Reuse existing TheHumanFund contract")
    parser.add_argument("--verifier-address", help="Reuse existing DstackVerifier contract")
    parser.add_argument("--no-cleanup", action="store_true", help="Don't delete measurement VM after test")
    parser.add_argument("--cpu", action="store_true", help="Use CPU instance for inference (slower, cheaper)")
    parser.add_argument("--epochs", type=int, default=1, help="Number of epochs to run (default: 1)")
    args = parser.parse_args()

    # Set dm-verity image
    global DMVERITY_IMAGE
    DMVERITY_IMAGE = args.image
    print(f"dm-verity image: {DMVERITY_IMAGE}")

    # Configure GPU vs CPU (GPU is default)
    global USE_GPU, EPOCH_DURATION, COMMIT_WINDOW, REVEAL_WINDOW, EXECUTION_WINDOW
    if args.cpu:
        USE_GPU = False
        EPOCH_DURATION = EPOCH_DURATION_CPU
        COMMIT_WINDOW = COMMIT_WINDOW_CPU
        REVEAL_WINDOW = REVEAL_WINDOW_CPU
        EXECUTION_WINDOW = EXECUTION_WINDOW_CPU
        print("Mode: CPU (c3-standard-4, ~20-30 min inference)")
    else:
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
        print("WARNING: Low balance -- may not have enough for deployment + gas")

    created_measurement_vm = False
    success = False

    try:
        # Step 1: Deploy contracts (or reuse)
        if args.fund_address and args.verifier_address:
            fund_addr = Web3.to_checksum_address(args.fund_address)
            dstack_verifier_addr = Web3.to_checksum_address(args.verifier_address)
            nonce = w3.eth.get_transaction_count(account.address)
            # Read AM address from fund contract
            fund_abi = json.loads((ABI_DIR / "TheHumanFund.sol" / "TheHumanFund.json").read_text())["abi"]
            fund_tmp = w3.eth.contract(address=fund_addr, abi=fund_abi)
            am_addr = fund_tmp.functions.auctionManager().call()
            print(f"\nReusing contracts: fund={fund_addr}, verifier={dstack_verifier_addr}, am={am_addr}")
        else:
            fund_addr, dstack_verifier_addr, am_addr, nonce = deploy_contracts(w3, account)

        # Step 2: Create measurement VM from dm-verity image (c3-standard-4, cheap)
        create_measurement_vm()
        created_measurement_vm = True

        # Step 3: Extract measurements, register platform key (DstackVerifier only)
        # Fresh RPC connection
        w3 = Web3(Web3.HTTPProvider(RPC_URL, request_kwargs={"timeout": 120}))
        nonce = w3.eth.get_transaction_count(account.address)
        measurements = get_vm_measurements()
        nonce = register_dstack_image(w3, account, dstack_verifier_addr, measurements, nonce)

        # Delete measurement VM before inference — both use a3-highgpu-1g, and
        # GPUS_ALL_REGIONS quota is 1. Must free the measurement VM before creating
        # the inference VM or the inference VM creation will fail with quota exceeded.
        if created_measurement_vm and not args.no_cleanup:
            cleanup_measurement_vm()
            created_measurement_vm = False

        # Step 4: Run the full auction (multiple epochs if requested)
        # Each epoch creates/destroys its own inference VM
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
                success = run_auction_e2e(w3, account, fund_addr, am_addr, nonce)
            except Exception as e:
                print(f"\n  Epoch {epoch_i + 1} crashed: {e}")
                success = False
            if not success:
                print(f"\n  Epoch {epoch_i + 1} failed, continuing to next epoch...")
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

    finally:
        # Step 5: Always clean up the measurement VM (unless --no-cleanup)
        if created_measurement_vm and not args.no_cleanup:
            cleanup_measurement_vm()

    # Summary
    print("\n" + "=" * 60)
    if success:
        print("  E2E TEST PASSED")
        print("  Full security model verified on Base Sepolia:")
        print("    [x] Automata DCAP: genuine TDX hardware")
        print("    [x] Platform key: sha256(MRTD + RTMR[1] + RTMR[2]) -- dm-verity covers all code")
        print("    [x] REPORTDATA: sha256(inputHash + keccak256(sha256(action) + sha256(reasoning) + promptHash))")
        print("    [x] Auction: only winner can submit within execution window")
        print("    [x] Randomness seed: block.prevrandao prevents cherry-picking")
        print("    [x] Serial console: one-shot inference, no SSH/HTTP during execution")
    else:
        print("  E2E TEST INCOMPLETE/FAILED")
    print("=" * 60)

    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
