#!/usr/bin/env python3
"""Verify that a GCP TDX VM's RTMR measurements match the registered image key.

Boots a VM from the specified snapshot (or uses an existing VM), extracts
RTMR[1..3] values, and compares against the on-chain approved image key.

Usage:
    # Verify against on-chain key
    python scripts/verify_measurements.py --contract 0x... --verifier 0x...

    # Verify against a known key
    python scripts/verify_measurements.py --expected-image-key 0xabc...

    # Use an existing running VM
    python scripts/verify_measurements.py --vm-name my-vm --zone us-central1-a
"""

import argparse
import hashlib
import json
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


def get_measurements(vm_name, zone):
    """Extract RTMR measurements from a running TDX VM."""
    extract_script = PROJECT_ROOT / "scripts" / "extract_measurements.py"

    # Upload and run extraction script
    gcloud(f"compute scp {extract_script} {vm_name}:/tmp/extract_measurements.py --zone={zone}", timeout=30)
    result = gcloud(
        f"compute ssh {vm_name} --zone={zone} "
        f"--command='sudo python3 /tmp/extract_measurements.py'",
        timeout=30,
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

    required = ["mrtd", "rtmr1", "rtmr2"]
    missing = [k for k in required if k not in measurements]
    if missing:
        raise RuntimeError(f"Failed to extract measurements: missing {missing}\nOutput: {result[:500]}")

    return measurements


def compute_image_key(measurements):
    """Compute image key = sha256(MRTD || RTMR[1] || RTMR[2]) — matches DstackVerifier.sol."""
    return hashlib.sha256(
        measurements["mrtd"] + measurements["rtmr1"] + measurements["rtmr2"]
    ).digest()


def get_onchain_image_key(contract_address, verifier_address, rpc_url):
    """Read approved image keys from the TdxVerifier contract."""
    from web3 import Web3
    w3 = Web3(Web3.HTTPProvider(rpc_url))

    abi_path = PROJECT_ROOT / "out" / "TdxVerifier.sol" / "TdxVerifier.json"
    with open(abi_path) as f:
        abi = json.loads(f.read())["abi"]

    verifier = w3.eth.contract(address=Web3.to_checksum_address(verifier_address), abi=abi)
    return verifier


def main():
    parser = argparse.ArgumentParser(description="Verify GCP TDX VM measurements against registered image key")
    parser.add_argument("--vm-name", required=True, help="Name of running GCP VM to check")
    parser.add_argument("--zone", default="us-central1-a", help="GCP zone")
    parser.add_argument("--expected-image-key", help="Expected image key (0x...)")
    parser.add_argument("--contract", help="TheHumanFund contract address")
    parser.add_argument("--verifier", help="TdxVerifier contract address")
    parser.add_argument("--rpc-url", default="https://sepolia.base.org", help="RPC URL")
    args = parser.parse_args()

    print(f"═══ Verifying RTMR Measurements ═══")
    print(f"  VM: {args.vm_name}")

    # Extract measurements
    measurements = get_measurements(args.vm_name, args.zone)
    image_key = compute_image_key(measurements)

    print(f"\n  Measurements:")
    print(f"    MRTD:    {measurements['mrtd'].hex()[:32]}...")
    print(f"    RTMR[0]: {measurements.get('rtmr0', b'').hex()[:32]}... (not verified)")
    print(f"    RTMR[1]: {measurements['rtmr1'].hex()[:32]}...")
    print(f"    RTMR[2]: {measurements['rtmr2'].hex()[:32]}...")
    print(f"    RTMR[3]: {measurements.get('rtmr3', b'').hex()[:32]}... (not verified)")
    print(f"    Image key: 0x{image_key.hex()}")

    # Compare
    if args.expected_image_key:
        expected = bytes.fromhex(args.expected_image_key.replace("0x", ""))
        if image_key == expected:
            print(f"\n  PASS: Image key matches expected value")
        else:
            print(f"\n  FAIL: Image key mismatch!")
            print(f"    Expected: 0x{expected.hex()}")
            print(f"    Actual:   0x{image_key.hex()}")
            sys.exit(1)

    elif args.verifier:
        verifier = get_onchain_image_key(args.contract, args.verifier, args.rpc_url)
        approved = verifier.functions.approvedImages(image_key).call()
        if approved:
            print(f"\n  PASS: Image key is approved on-chain")
        else:
            print(f"\n  FAIL: Image key is NOT approved on-chain")
            print(f"    Key: 0x{image_key.hex()}")
            print(f"    Register with: python scripts/register_image.py --vm-name {args.vm_name}")
            sys.exit(1)
    else:
        print(f"\n  Image key computed. Provide --expected-image-key or --verifier to verify.")


if __name__ == "__main__":
    main()
