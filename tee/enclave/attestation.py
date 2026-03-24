#!/usr/bin/env python3
"""TDX attestation — generate DCAP quotes via configfs-tsm.

Provides two functions:
- get_tdx_quote(report_data) — get a TDX quote with custom report data
- compute_report_data(input_hash, action_bytes, reasoning, system_prompt) — compute REPORTDATA

The REPORTDATA formula:
    sha256(inputHash || outputHash)
where:
    outputHash = keccak256(sha256(action) || sha256(reasoning) || sha256(systemPrompt))
"""

import hashlib
import os

from .input_hash import _keccak256

# configfs-tsm paths (GCP, bare-metal TDX with kernel >= 6.7)
CONFIGFS_TSM_BASE = "/sys/kernel/config/tsm/report"


def _get_quote_configfs_tsm(report_data: bytes) -> bytes:
    """Get TDX quote via Linux configfs-tsm interface (GCP, bare-metal).

    Works on any TDX VM with kernel >= 6.7 and CONFIG_TSM_REPORTS enabled.
    This is the standard Linux interface for TDX attestation.
    """
    import uuid

    # Create a unique report entry
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

        print(f"  TDX quote via configfs-tsm: {len(quote)} bytes")
        return quote

    finally:
        # Clean up the report entry
        try:
            os.rmdir(entry_path)
        except OSError:
            pass


def _get_quote_dev_tdx(report_data: bytes) -> bytes:
    """Get TDX quote via /dev/tdx_guest ioctl (legacy, pre-6.7 kernels)."""
    import ctypes
    import fcntl

    # TDX_CMD_GET_REPORT0 ioctl
    # struct tdx_report_req { reportdata[64]; tdreport[1024]; }
    TDX_CMD_GET_REPORT0 = 0xC4401401  # _IOWR('T', 1, struct tdx_report_req)

    report_req = bytearray(64 + 1024)
    report_req[:64] = report_data[:64].ljust(64, b'\x00')

    fd = os.open("/dev/tdx_guest", os.O_RDWR)
    try:
        fcntl.ioctl(fd, TDX_CMD_GET_REPORT0, report_req)
        # The TD report is in bytes 64:1088
        # But we need the full DCAP quote, not just the TD report.
        # /dev/tdx_guest gives us the report; the QGS converts it to a quote.
        # For simplicity, use configfs-tsm which handles the full quote flow.
        print("WARNING: /dev/tdx_guest gives TD report, not full DCAP quote")
        print("  Use configfs-tsm (kernel >= 6.7) for full quote generation")
        return bytes(report_req[64:1088])
    finally:
        os.close(fd)


def get_tdx_quote(report_data: bytes) -> bytes:
    """Request a TDX attestation quote using the best available backend.

    Tries in order:
    1. configfs-tsm (GCP TDX, bare-metal TDX with kernel >= 6.7)
    2. /dev/tdx_guest (bare-metal TDX with older kernels)
    3. Mock mode (local testing — returns report_data as the "quote")

    Args:
        report_data: 64 bytes of custom data to bind into the quote.

    Returns:
        Raw DCAP quote bytes, suitable for on-chain verification.
    """
    # Try configfs-tsm first (GCP, bare-metal with kernel >= 6.7)
    if os.path.isdir(CONFIGFS_TSM_BASE):
        try:
            return _get_quote_configfs_tsm(report_data)
        except Exception as e:
            print(f"WARNING: configfs-tsm failed: {e}")

    # Try /dev/tdx_guest (bare-metal with older kernels)
    if os.path.exists("/dev/tdx_guest"):
        try:
            return _get_quote_dev_tdx(report_data)
        except Exception as e:
            print(f"WARNING: /dev/tdx_guest failed: {e}")

    # Mock mode (local testing)
    print("WARNING: No TDX attestation backend found (configfs-tsm, /dev/tdx_guest)")
    print("  Running outside TEE — returning report_data as mock attestation")
    return report_data


def compute_report_data(input_hash: bytes, action_bytes: bytes, reasoning: str,
                        system_prompt: str) -> bytes:
    """Compute the 64-byte report data that gets bound into the TDX quote.

    This creates a cryptographic binding between:
    - The input (epoch context hash, which includes the randomness seed)
    - The output (action + reasoning + prompt hash)
    - The TEE identity (via RTMR values in the quote)

    The contract verifies:
        REPORTDATA == sha256(inputHash || outputHash)
    where:
        promptHash  = sha256(systemPrompt)
        outputHash  = keccak256(abi.encodePacked(
                          sha256(action), sha256(reasoning), promptHash))

    The promptHash must match the contract's approvedPromptHash. This proves
    the TEE used the approved system prompt without the verifier needing to
    see the prompt text.
    """
    action_hash = hashlib.sha256(action_bytes).digest()
    reasoning_hash = hashlib.sha256(reasoning.encode("utf-8")).digest()
    prompt_hash = hashlib.sha256(system_prompt.encode("utf-8")).digest()

    # outputHash = keccak256(sha256(action) || sha256(reasoning) || sha256(prompt))
    # Must match Solidity: keccak256(abi.encodePacked(sha256(action), sha256(reasoning), approvedPromptHash))
    output_hash = _keccak256(action_hash + reasoning_hash + prompt_hash)

    # REPORTDATA = sha256(inputHash || outputHash), zero-padded to 64 bytes
    report_data = hashlib.sha256(input_hash + output_hash).digest()

    # Pad to 64 bytes (TDX report data is exactly 64 bytes)
    return report_data.ljust(64, b'\x00')
