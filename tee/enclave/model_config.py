#!/usr/bin/env python3
"""Model configuration — pinned SHA-256 hashes for verified model weights.

The enclave verifies the model file hash at boot time. Since this code is
measured into RTMR[3], pinning the model hash here transitively pins the
model weights to the on-chain attestation.
"""

import hashlib
import sys

# DeepSeek R1 Distill Llama 70B Q4_K_M (42.5 GB) — production model
MODEL_SHA256_70B = "a4b1781e2f4ee59a0c048b236c5765e6c4b770c6c6a4e1f02ba42e1daae2dfe2"

# DeepSeek R1 Distill Qwen 14B Q4_K_M (8.99 GB) — development model
MODEL_SHA256_14B = "0b319bd0572f2730bfe11cc751defe82045fad5085b4e60591ac2cd2d9633181"

# Map of known model hashes to names (for logging)
KNOWN_MODELS = {
    MODEL_SHA256_70B: "DeepSeek-R1-Distill-Llama-70B-Q4_K_M",
    MODEL_SHA256_14B: "DeepSeek-R1-Distill-Qwen-14B-Q4_K_M",
}


def verify_model(path: str, expected_hash: str = None) -> str:
    """Verify model file SHA-256 against known hashes.

    Args:
        path: Path to the model file.
        expected_hash: If provided, verify against this specific hash.
                      If None, verify against any known model hash.

    Returns:
        The SHA-256 hex digest of the model file.

    Raises:
        RuntimeError: If the hash doesn't match any known model (or expected_hash).
    """
    print(f"Verifying model hash: {path}")
    sha256 = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(1 << 20)  # 1MB chunks
            if not chunk:
                break
            sha256.update(chunk)

    actual_hash = sha256.hexdigest()

    if expected_hash:
        if actual_hash != expected_hash:
            raise RuntimeError(
                f"Model hash mismatch!\n"
                f"  Expected: {expected_hash}\n"
                f"  Actual:   {actual_hash}\n"
                f"  File:     {path}"
            )
        model_name = KNOWN_MODELS.get(actual_hash, "unknown")
        print(f"  Model verified: {model_name} ({actual_hash[:16]}...)")
        return actual_hash

    if actual_hash in KNOWN_MODELS:
        print(f"  Model verified: {KNOWN_MODELS[actual_hash]} ({actual_hash[:16]}...)")
        return actual_hash

    raise RuntimeError(
        f"Unknown model hash: {actual_hash}\n"
        f"  File: {path}\n"
        f"  Known models: {list(KNOWN_MODELS.values())}"
    )
