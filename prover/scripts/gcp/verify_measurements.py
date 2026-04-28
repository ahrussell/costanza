#!/usr/bin/env python3
"""Verify that a GCP TDX VM's measurements match the registered image key.

Extracts RTMR measurements from the serial console (no SSH required),
computes the platform key, and checks it against the on-chain registry.

Usage:
    # Verify a running VM against on-chain registry
    python prover/scripts/gcp/verify_measurements.py \
        --vm-name my-vm \
        --verifier 0x1D9E...

    # Verify an image by booting a temporary VM
    python prover/scripts/gcp/verify_measurements.py \
        --image costanza-tdx-prover-v1 \
        --verifier 0x1D9E...

    # Verify against a known key (no chain access needed)
    python prover/scripts/gcp/verify_measurements.py \
        --vm-name my-vm \
        --expected-image-key 0xabc...
"""

import argparse
import os
import sys
from pathlib import Path

# Reuse extraction logic from register_image.py
from register_image import (
    create_measurement_vm,
    delete_vm,
    extract_measurements_from_serial,
    compute_image_key,
)

PROJECT_ROOT = Path(__file__).parent.parent.parent.parent


def main():
    parser = argparse.ArgumentParser(
        description="Verify GCP TDX VM measurements against registered image key"
    )

    # VM source
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--image", help="GCP image name to boot a temporary VM from")
    group.add_argument("--vm-name", help="Existing running VM to extract measurements from")

    # Verification target
    parser.add_argument("--expected-image-key", help="Expected image key (0x...)")
    parser.add_argument("--verifier", help="TdxVerifier contract address")
    parser.add_argument("--rpc-url", default=os.environ.get("RPC_URL"))
    parser.add_argument("--zone", default="us-central1-a")
    parser.add_argument("--project", default=os.environ.get("GCP_PROJECT", "the-human-fund"))
    args = parser.parse_args()

    if not args.expected_image_key and not args.verifier:
        parser.error("Provide --expected-image-key or --verifier to verify against")

    print(f"=== Verifying RTMR Measurements ===")

    # Get or create VM
    created_vm = None
    if args.image:
        import time
        vm_name = create_measurement_vm(args.image, args.project, args.zone)
        created_vm = vm_name
        print(f"  Waiting for boot...")
        time.sleep(30)
    else:
        vm_name = args.vm_name
        print(f"  VM: {vm_name}")

    try:
        measurements = extract_measurements_from_serial(vm_name, args.project, args.zone)
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
            import json
            from web3 import Web3

            if not args.rpc_url:
                parser.error("--rpc-url or RPC_URL env var required when using --verifier")

            w3 = Web3(Web3.HTTPProvider(args.rpc_url))
            abi_path = PROJECT_ROOT / "out" / "TdxVerifier.sol" / "TdxVerifier.json"
            with open(abi_path) as f:
                abi = json.loads(f.read())["abi"]

            verifier = w3.eth.contract(
                address=Web3.to_checksum_address(args.verifier), abi=abi
            )
            approved = verifier.functions.approvedImages(image_key).call()
            if approved:
                print(f"\n  PASS: Image key is approved on-chain")
            else:
                print(f"\n  FAIL: Image key is NOT approved on-chain")
                print(f"    Register with:")
                if args.image:
                    print(f"    python prover/scripts/gcp/register_image.py --image {args.image} --verifier {args.verifier}")
                else:
                    print(f"    python prover/scripts/gcp/register_image.py --vm-name {vm_name} --verifier {args.verifier}")
                sys.exit(1)

    finally:
        if created_vm:
            delete_vm(created_vm, args.project, args.zone)


if __name__ == "__main__":
    main()
