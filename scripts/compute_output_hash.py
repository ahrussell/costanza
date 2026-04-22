#!/usr/bin/env python3
"""Compute output hash from JSON {action, reasoning, updates} — used by
Foundry FFI tests in test/CrossStackHash.t.sol.

Mirrors the Solidity side via Python's compute_report_data internals:

    outputHash = keccak256(
        sha256(action) || sha256(reasoning) || _hash_submitted_updates(updates)
    )

Usage:
    echo '{"action":"0x00","reasoning":"hello","updates":[
        {"slot":1,"title":"T","body":"B"}
    ]}' | python scripts/compute_output_hash.py

Outputs the 32-byte hash as a 0x-prefixed hex string to stdout. The
contract's `TheHumanFund.computeOutputHash(action, reasoning, updates)`
view function MUST return the same value for the same inputs.
"""
import hashlib
import json
import sys
from pathlib import Path

# Add project root to path so we can import the enclave module
sys.path.insert(0, str(Path(__file__).parent.parent))

from prover.enclave.attestation import _hash_submitted_updates, _keccak256


def _decode_bytes(raw):
    """Accept either a 0x-prefixed hex string or a plain UTF-8 string."""
    if isinstance(raw, str):
        if raw.startswith("0x"):
            return bytes.fromhex(raw[2:])
        return raw.encode("utf-8")
    if isinstance(raw, bytes):
        return raw
    raise TypeError(f"unsupported bytes representation: {type(raw).__name__}")


def main():
    payload = json.loads(sys.stdin.read())
    action_bytes = _decode_bytes(payload.get("action", "0x"))
    reasoning_bytes = _decode_bytes(payload.get("reasoning", ""))
    updates = payload.get("updates", []) or []

    action_hash = hashlib.sha256(action_bytes).digest()
    reasoning_hash = hashlib.sha256(reasoning_bytes).digest()
    updates_hash = _hash_submitted_updates(updates)
    output_hash = _keccak256(action_hash + reasoning_hash + updates_hash)
    print("0x" + output_hash.hex())


if __name__ == "__main__":
    main()
