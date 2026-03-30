#!/usr/bin/env python3
"""Extract RTMR measurements from a GCP TDX VM and register the image key on-chain.

Usage:
    python scripts/register_image.py --vm-name my-vm --verifier 0x... --zone us-central1-a
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent


def gcloud(args, check=True, timeout=120):
    result = subprocess.run(
        f"gcloud {args}", shell=True, capture_output=True, text=True, timeout=timeout
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"gcloud failed: {result.stderr[:200]}")
    return result.stdout.strip()


def extract_measurements(vm_name, zone):
    """Get RTMR measurements from a running TDX VM."""
    extract_script = PROJECT_ROOT / "scripts" / "extract_measurements.py"
    gcloud(f"compute scp {extract_script} {vm_name}:/tmp/extract_measurements.py --zone={zone}", timeout=30)
    result = gcloud(
        f"compute ssh {vm_name} --zone={zone} "
        f"--command='sudo python3 /tmp/extract_measurements.py'",
        timeout=30,
    )

    measurements = {}
    for line in result.split("\n"):
        line = line.strip()
        for prefix in ["MRTD:", "RTMR0:", "RTMR1:", "RTMR2:", "RTMR3:"]:
            if line.startswith(prefix):
                key = prefix.rstrip(":").lower()
                measurements[key] = bytes.fromhex(line.split(":")[1])

    for key in ["mrtd", "rtmr1", "rtmr2"]:
        if key not in measurements:
            raise RuntimeError(f"Failed to extract {key}: {result[:500]}")

    return measurements


def register_tdx(verifier_address, image_key, rpc_url, private_key):
    """Register image key on-chain via TdxVerifier.approveImage()."""
    from web3 import Web3

    w3 = Web3(Web3.HTTPProvider(rpc_url))
    account = w3.eth.account.from_key(private_key)

    abi_path = PROJECT_ROOT / "out" / "TdxVerifier.sol" / "TdxVerifier.json"
    with open(abi_path) as f:
        abi = json.loads(f.read())["abi"]

    verifier = w3.eth.contract(address=Web3.to_checksum_address(verifier_address), abi=abi)

    # Check if already approved
    if verifier.functions.approvedImages(image_key).call():
        print(f"  Image already approved on-chain!")
        return

    nonce = w3.eth.get_transaction_count(account.address)
    tx = verifier.functions.approveImage(image_key).build_transaction({
        "from": account.address,
        "nonce": nonce,
        "gas": 100_000,
        "maxFeePerGas": w3.eth.gas_price * 2,
        "maxPriorityFeePerGas": w3.eth.max_priority_fee,
    })

    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    print(f"  Image approved! tx: {tx_hash.hex()}")
    print(f"  Gas used: {receipt['gasUsed']}")


def main():
    parser = argparse.ArgumentParser(description="Register TDX image key on-chain")
    parser.add_argument("--vm-name", required=True, help="Running GCP TDX VM to extract measurements from")
    parser.add_argument("--verifier", required=True, help="TdxVerifier contract address")
    parser.add_argument("--zone", default="us-central1-a", help="GCP zone")
    parser.add_argument("--rpc-url", default=os.environ.get("RPC_URL"),
                        help="Base RPC URL (env: RPC_URL)")
    parser.add_argument("--private-key", default=os.environ.get("PRIVATE_KEY"),
                        help="Private key for signing (env: PRIVATE_KEY)")
    args = parser.parse_args()

    if not args.rpc_url:
        parser.error("--rpc-url or RPC_URL env var required")
    if not args.private_key:
        parser.error("--private-key or PRIVATE_KEY env var required")

    print(f"=== Register Image Key ===")
    print(f"  VM: {args.vm_name}")

    measurements = extract_measurements(args.vm_name, args.zone)

    print(f"\n  Measurements:")
    print(f"    MRTD:    {measurements['mrtd'].hex()[:32]}...")
    print(f"    RTMR[0]: {measurements.get('rtmr0', b'').hex()[:32]}...")
    print(f"    RTMR[1]: {measurements['rtmr1'].hex()[:32]}...")
    print(f"    RTMR[2]: {measurements['rtmr2'].hex()[:32]}...")
    print(f"    RTMR[3]: {measurements.get('rtmr3', b'').hex()[:32]}...")

    # Image key = sha256(MRTD || RTMR[1] || RTMR[2]) — matches DstackVerifier.sol
    image_key = hashlib.sha256(
        measurements["mrtd"] + measurements["rtmr1"] + measurements["rtmr2"]
    ).digest()
    print(f"    Image key: 0x{image_key.hex()}")
    print(f"  Verifier: {args.verifier}")
    register_tdx(args.verifier, image_key, args.rpc_url, args.private_key)


if __name__ == "__main__":
    main()
