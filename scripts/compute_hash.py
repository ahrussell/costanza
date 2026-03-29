#!/usr/bin/env python3
"""Compute input hash from JSON state — used by Foundry FFI tests.

Usage:
    echo '{"state_hash_inputs": {...}, "nonprofits": [...], ...}' | python scripts/compute_hash.py

Outputs the 32-byte hash as a 0x-prefixed hex string to stdout.
"""
import json
import sys
from pathlib import Path

# Add project root to path so we can import the enclave module
sys.path.insert(0, str(Path(__file__).parent.parent))

from tee.enclave.input_hash import compute_input_hash


def main():
    state = json.loads(sys.stdin.read())
    hash_bytes = compute_input_hash(state)
    print("0x" + hash_bytes.hex())


if __name__ == "__main__":
    main()
