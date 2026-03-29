#!/usr/bin/env python3
"""TDX attestation — generate DCAP quotes via configfs-tsm.

Provides two functions:
- get_tdx_quote(report_data) — get a TDX quote with custom report data
- compute_report_data(input_hash, action_bytes, reasoning, system_prompt) — compute REPORTDATA

The REPORTDATA formula:
    sha256(inputHash || outputHash)
where:
    outputHash = keccak256(sha256(action) || sha256(reasoning) || sha256(systemPrompt))

This runs on the dm-verity rootfs — the code cannot be modified at runtime.
"""

import hashlib
import os
import uuid

from .input_hash import _keccak256

# configfs-tsm report interface (standard Linux TDX attestation, kernel >= 6.7)
CONFIGFS_TSM_BASE = "/sys/kernel/config/tsm/report"


def get_tdx_quote(report_data: bytes, allow_mock: bool = False) -> bytes:
    """Get a TDX DCAP attestation quote via configfs-tsm.

    Args:
        report_data: 64 bytes of custom data to bind into the quote.
        allow_mock: If True, return report_data as mock quote when no TDX
                    hardware is available. Must be explicitly opted in via
                    CLI flag (--mock), not environment variable.

    Returns:
        Raw DCAP quote bytes for on-chain verification.

    Raises:
        RuntimeError: If configfs-tsm is not available (not on TDX hardware).
    """
    if os.path.isdir(CONFIGFS_TSM_BASE):
        return _get_quote_configfs_tsm(report_data)

    # Mock mode — only allowed when explicitly passed via CLI flag
    if allow_mock:
        print("WARNING: Mock attestation enabled — returning report_data as mock quote")
        print("  This will NOT pass on-chain DCAP verification!")
        return report_data

    raise RuntimeError(
        "No TDX attestation backend (configfs-tsm not found). "
        "Cannot produce a valid quote outside TEE hardware. "
        "Pass --mock to enclave_runner for local development only."
    )


def _get_quote_configfs_tsm(report_data: bytes) -> bytes:
    """Get TDX quote via Linux configfs-tsm interface.

    Works on any TDX VM with kernel >= 6.7 and CONFIG_TSM_REPORTS enabled.
    """
    entry_name = f"humanfund-{uuid.uuid4().hex[:8]}"
    entry_path = os.path.join(CONFIGFS_TSM_BASE, entry_name)

    try:
        os.makedirs(entry_path, exist_ok=True)

        # Write report_data (exactly 64 bytes)
        with open(os.path.join(entry_path, "inblob"), "wb") as f:
            f.write(report_data[:64].ljust(64, b'\x00'))

        # Read the generated quote
        with open(os.path.join(entry_path, "outblob"), "rb") as f:
            quote = f.read()

        if len(quote) < 100:
            raise RuntimeError(f"Quote too small ({len(quote)} bytes) — TDX may not be active")

        print(f"  TDX DCAP quote: {len(quote)} bytes")
        return quote

    finally:
        try:
            os.rmdir(entry_path)
        except OSError:
            pass


def compute_report_data(input_hash: bytes, action_bytes: bytes, reasoning: str) -> bytes:
    """Compute the 64-byte report data bound into the TDX quote.

    Creates a cryptographic binding between:
    - The input (epoch state, randomness seed)
    - The output (action + reasoning)
    - The TEE identity (RTMR values in the quote)

    The system prompt is verified via dm-verity image key (RTMR[2]) and no
    longer needs a separate hash in REPORTDATA.

    The contract verifies:
        REPORTDATA == sha256(inputHash || outputHash)
    where:
        outputHash = keccak256(abi.encodePacked(sha256(action), sha256(reasoning)))
    """
    action_hash = hashlib.sha256(action_bytes).digest()
    reasoning_hash = hashlib.sha256(reasoning.encode("utf-8")).digest()

    # outputHash = keccak256(sha256(action) || sha256(reasoning))
    output_hash = _keccak256(action_hash + reasoning_hash)

    # REPORTDATA = sha256(inputHash || outputHash), zero-padded to 64 bytes
    report_data = hashlib.sha256(input_hash + output_hash).digest()
    return report_data.ljust(64, b'\x00')
