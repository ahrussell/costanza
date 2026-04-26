#!/usr/bin/env python3
"""Register a dm-verity image's platform key on-chain.

Boots a TDX VM from the specified image, extracts RTMR measurements from the
serial console (no SSH required — works with hardened images), computes the
platform key, and registers it on-chain via TdxVerifier.approveImage().

Usage:
    # Register a new image (creates a temporary VM, extracts measurements, registers)
    python prover/scripts/gcp/register_image.py \
        --image humanfund-dmverity-hardened-v19 \
        --verifier 0x1D9E...

    # Use an already-running VM (skip VM creation)
    python prover/scripts/gcp/register_image.py \
        --vm-name humanfund-measure-v19 \
        --verifier 0x1D9E...

    # Dry run (extract and display key without registering)
    python prover/scripts/gcp/register_image.py \
        --image humanfund-dmverity-hardened-v19 \
        --verifier 0x1D9E... \
        --dry-run
"""

import argparse
import atexit
import hashlib
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent.parent.parent

# Markers emitted by the enclave at boot (see enclave_runner.py)
MEASUREMENTS_START = "===HUMANFUND_MEASUREMENTS_START==="
MEASUREMENTS_END = "===HUMANFUND_MEASUREMENTS_END==="


def gcloud(args, project=None, check=True, timeout=120):
    cmd = ["gcloud"] + shlex.split(args)
    if project:
        cmd += [f"--project={project}"]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode != 0:
        raise RuntimeError(f"gcloud failed: {result.stderr[:500]}")
    return result.stdout.strip()


def create_measurement_vm(image, project, zone):
    """Boot a TDX VM from the image for measurement extraction."""
    vm_name = f"humanfund-measure-{int(time.time())}"
    print(f"  Creating VM: {vm_name} (image={image})")

    gcloud(
        f"compute instances create {vm_name} "
        f"--zone={zone} "
        f"--machine-type=a3-highgpu-1g "
        f"--image={image} "
        f"--confidential-compute-type=TDX "
        f"--boot-disk-size=300GB "
        f"--maintenance-policy=TERMINATE "
        f"--provisioning-model=SPOT "
        f"--instance-termination-action=DELETE "
        f"--scopes=https://www.googleapis.com/auth/compute.readonly",
        project=project, timeout=180,
    )
    return vm_name


def delete_vm(vm_name, project, zone):
    """Delete a VM."""
    print(f"  Deleting VM: {vm_name}")
    gcloud(
        f"compute instances delete {vm_name} --zone={zone} --quiet",
        project=project, check=False, timeout=180,
    )


def extract_measurements_from_serial(vm_name, project, zone, timeout=600):
    """Poll serial console for RTMR measurements emitted by the enclave at boot.

    The enclave writes measurements between HUMANFUND_MEASUREMENTS_START and
    HUMANFUND_MEASUREMENTS_END markers on the serial console. No SSH required —
    works with hardened dm-verity images that have SSH disabled.
    """
    print(f"  Polling serial console for measurements (timeout: {timeout}s)...")
    start = time.time()

    while time.time() - start < timeout:
        try:
            serial = gcloud(
                f"compute instances get-serial-port-output {vm_name} --zone={zone}",
                project=project, check=False, timeout=30,
            )

            start_idx = serial.find(MEASUREMENTS_START)
            end_idx = serial.find(MEASUREMENTS_END)

            if start_idx >= 0 and end_idx > start_idx:
                # Parse measurements using regex (handles interleaved syslog lines)
                measurements = {}
                for label, key in [("MRTD", "mrtd"), ("RTMR0", "rtmr0"),
                                   ("RTMR1", "rtmr1"), ("RTMR2", "rtmr2"),
                                   ("RTMR3", "rtmr3")]:
                    m = re.search(rf"{label}:([0-9a-f]{{96}})", serial)
                    if m:
                        measurements[key] = bytes.fromhex(m.group(1))

                for key in ["mrtd", "rtmr1", "rtmr2"]:
                    if key not in measurements:
                        raise RuntimeError(f"Missing {key} in serial output")

                elapsed = time.time() - start
                print(f"  Measurements extracted after {elapsed:.0f}s")
                return measurements

        except subprocess.TimeoutExpired:
            pass

        time.sleep(15)

    raise RuntimeError(f"No measurements found after {timeout}s")


def compute_image_key(measurements):
    """Compute platform key = sha256(MRTD || RTMR[1] || RTMR[2])."""
    return hashlib.sha256(
        measurements["mrtd"] + measurements["rtmr1"] + measurements["rtmr2"]
    ).digest()


def register_on_chain(verifier_address, image_key, rpc_url, private_key):
    """Register image key on-chain via TdxVerifier.approveImage()."""
    from web3 import Web3

    w3 = Web3(Web3.HTTPProvider(rpc_url))
    account = w3.eth.account.from_key(private_key)

    abi_path = PROJECT_ROOT / "out" / "TdxVerifier.sol" / "TdxVerifier.json"
    with open(abi_path) as f:
        abi = json.loads(f.read())["abi"]

    verifier = w3.eth.contract(address=Web3.to_checksum_address(verifier_address), abi=abi)

    if verifier.functions.approvedImages(image_key).call():
        print(f"  Image already approved on-chain!")
        return

    tx = verifier.functions.approveImage(image_key).build_transaction({
        "from": account.address,
        "nonce": w3.eth.get_transaction_count(account.address),
        "gas": 100_000,
        "maxFeePerGas": w3.eth.gas_price * 2,
        "maxPriorityFeePerGas": w3.eth.max_priority_fee,
    })

    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    print(f"  Approved! tx: {tx_hash.hex()}")
    print(f"  Gas used: {receipt['gasUsed']}")


def main():
    parser = argparse.ArgumentParser(description="Register TDX image key on-chain")

    # VM source: either --image (creates temporary VM) or --vm-name (uses existing)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--image", help="GCP image name to boot a temporary VM from")
    group.add_argument("--vm-name", help="Existing running VM to extract measurements from")

    parser.add_argument("--verifier", required=True, help="TdxVerifier contract address")
    parser.add_argument("--zone", default="us-central1-a")
    parser.add_argument("--project", default=os.environ.get("GCP_PROJECT", "the-human-fund"))
    parser.add_argument("--rpc-url", default=os.environ.get("RPC_URL"))
    parser.add_argument("--private-key", default=os.environ.get("PRIVATE_KEY"))
    parser.add_argument("--dry-run", action="store_true",
                        help="Extract and show key without registering")
    args = parser.parse_args()

    if not args.dry_run:
        if not args.rpc_url:
            parser.error("--rpc-url or RPC_URL env var required (unless --dry-run)")
        if not args.private_key:
            parser.error("--private-key or PRIVATE_KEY env var required (unless --dry-run)")

    print(f"=== Register Image Key ===")

    # Get or create VM
    created_vm = None
    if args.image:
        vm_name = create_measurement_vm(args.image, args.project, args.zone)
        created_vm = vm_name

        # Register cleanup via atexit + signal handlers so VM is deleted even on crash/SIGTERM
        def _cleanup():
            if created_vm:
                delete_vm(created_vm, args.project, args.zone)

        atexit.register(_cleanup)
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, lambda *_: sys.exit(1))

        print(f"  Waiting for boot...")
        time.sleep(30)
    else:
        vm_name = args.vm_name

    try:
        measurements = extract_measurements_from_serial(vm_name, args.project, args.zone)
        image_key = compute_image_key(measurements)

        print(f"\n  Measurements:")
        print(f"    MRTD:    {measurements['mrtd'].hex()[:32]}...")
        print(f"    RTMR[1]: {measurements['rtmr1'].hex()[:32]}...")
        print(f"    RTMR[2]: {measurements['rtmr2'].hex()[:32]}...")
        print(f"    Image key: 0x{image_key.hex()}")
        print(f"  Verifier: {args.verifier}")

        if args.dry_run:
            print(f"\n  [DRY RUN] Would register image key 0x{image_key.hex()[:16]}...")
        else:
            register_on_chain(args.verifier, image_key, args.rpc_url, args.private_key)

    finally:
        if created_vm:
            delete_vm(created_vm, args.project, args.zone)


if __name__ == "__main__":
    main()
