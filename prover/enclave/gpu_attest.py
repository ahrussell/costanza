#!/usr/bin/env python3
"""Offline GPU attestation for The Human Fund enclave.

Wraps NVIDIA's `nv-local-gpu-verifier` (imported as `verifier`) to
produce a cryptographic binding between this specific epoch's inputs
and the physical GPU's firmware + identity.

Three layers of trust get stitched together here:

  1. TDX attestation (measured externally) proves the dm-verity rootfs
     is unmodified. RTMR[2] covers this file.
  2. This file's code, because it's measured by RTMR[2], is trusted to
     perform the GPU attestation correctly — no on-chain NVIDIA
     verifier needed.
  3. The GPU's SPDM attestation report (signed by NVIDIA's PKI) proves
     the running firmware matches the pinned RIM, bound to this epoch
     via `nonce = sha256(input_hash)`.

OCSP is deliberately skipped so the enclave can run fully offline.
See the OCSP monkey-patch at module load for the trade-off.
"""

import hashlib
import json
import logging
import os

logger = logging.getLogger(__name__)

# ─── OCSP monkey-patch ────────────────────────────────────────────────────

# `nv-local-gpu-verifier` unconditionally calls `ocsp.ndis.nvidia.com`
# inside `CcAdminUtils.ocsp_certificate_chain_validation()` — once for
# the GPU device cert chain and once for each RIM cert chain. There is
# no `--no-ocsp` flag in the SDK. To keep the enclave fully offline we
# replace the method with a no-op before calling `cc_admin.attest()`.
#
# Security trade-off: we lose cert-revocation detection. Compensation:
# (a) the GPU attestation report signature is still verified against
# the device cert chain rooted in NVIDIA's root CA (bundled with the
# SDK); (b) both RIM signatures are still verified against the same
# root; (c) runtime measurements still have to match the pinned RIM's
# golden values; (d) the window in which a revoked-but-not-rotated
# cert could pass is bounded by the interval between dm-verity image
# rebuilds.
#
# Re-audit this patch on every SDK version bump — the method's
# location could move, and adjacent call sites could proliferate.

def _install_ocsp_patch() -> None:
    """Replace `CcAdminUtils.ocsp_certificate_chain_validation` with a
    function that always reports success without making a network call."""
    from verifier.cc_admin_utils import CcAdminUtils

    def _ocsp_noop(cert_chain, settings, mode):
        # Return shape mirrors the real function:
        # (ok, warning, ocsp_status, revocation_reason).
        # `None` for ocsp_status is honest — we didn't actually check.
        return True, "", None, None

    CcAdminUtils.ocsp_certificate_chain_validation = staticmethod(_ocsp_noop)


_install_ocsp_patch()


# ─── Attestation entry point ──────────────────────────────────────────────

def verify_gpu_attestation(
    nonce: bytes,
    driver_rim_path: str,
    vbios_rim_path: str,
) -> None:
    """Attest the GPU firmware + identity, bound to `nonce`.

    Args:
        nonce: 32 bytes; caller passes `sha256(input_hash)` so the
            signed GPU report is cryptographically bound to this epoch.
        driver_rim_path: local path to the pinned driver RIM XML.
        vbios_rim_path: local path to the pinned VBIOS RIM XML.

    Raises:
        RuntimeError: on any verification failure. The TDX quote is
            never produced because the enclave aborts first.
    """
    if len(nonce) != 32:
        raise RuntimeError(f"GPU attest nonce must be 32 bytes, got {len(nonce)}")
    for path in (driver_rim_path, vbios_rim_path):
        if not os.path.isfile(path):
            raise RuntimeError(f"RIM not found at {path}")

    # The SDK's `collect_gpu_evidence_local` expects a hex-encoded string.
    nonce_hex = nonce.hex()

    # Import lazily so the monkey-patch has run before any verifier code
    # imports `cc_admin_utils` transitively.
    from verifier import cc_admin

    logger.info("Collecting GPU evidence (nonce=%s...)", nonce_hex[:16])
    evidence_list = cc_admin.collect_gpu_evidence_local(
        nonce_hex, ppcie_mode=False, no_gpu_mode=False,
    )
    if not evidence_list:
        raise RuntimeError("GPU evidence collection returned empty list")

    params = {
        "verbose": False,
        "test_no_gpu": False,
        "driver_rim": driver_rim_path,
        "vbios_rim": vbios_rim_path,
        "user_mode": True,
        "rim_root_cert": None,              # use SDK-bundled verifier_RIM_root.pem
        "rim_service_url": None,            # unused (RIMs are local)
        "allow_hold_cert": False,
        "ocsp_url": None,                   # unused (OCSP is no-op'd)
        "nonce": nonce_hex,
        "ppcie_mode": False,
        "ocsp_nonce_disabled": True,
        "service_key": None,
        "claims_version": "2.0",
    }

    logger.info(
        "Attesting with local RIMs (driver=%s, vbios=%s)",
        os.path.basename(driver_rim_path), os.path.basename(vbios_rim_path),
    )
    overall_status, jwt_token = cc_admin.attest(params, nonce_hex, evidence_list)

    if not overall_status:
        # Best-effort: pull any err-msg claim out of the JWT for diagnostics.
        detail = _extract_error_detail(jwt_token)
        raise RuntimeError(f"GPU attestation failed: {detail}")

    # Defense-in-depth: independently re-check the returned claims for
    # nonce match and CC mode even though `overall_status` already
    # gates on them. The JWT is SDK-signed, not NVIDIA-signed, so we
    # can read it without verifying a signature — our trust in the
    # claims is derived from `overall_status` being true.
    claims = _decode_unverified_claims(jwt_token)
    _assert_nonce_match(claims, nonce_hex)
    _assert_cc_mode_on(claims)

    logger.info("GPU attestation OK (overall_status=True, CC=ON, nonce match)")


# ─── Claim parsing helpers ────────────────────────────────────────────────

def _decode_unverified_claims(jwt_token) -> dict:
    """Decode a JWT's claims without signature verification.

    The SDK returns a JWT signed with a symmetric internal key we don't
    hold. Its role here is a structured return channel, not a trust
    boundary — we already know `overall_status` is true.
    """
    try:
        import jwt as pyjwt
    except ImportError as e:
        raise RuntimeError(f"PyJWT not available to parse claims: {e}")

    # The SDK sometimes wraps the JWT in a list-like structure. Pull
    # out the first string we find.
    token_str = jwt_token
    if isinstance(jwt_token, list):
        token_str = jwt_token[0] if jwt_token else ""
    if isinstance(token_str, bytes):
        token_str = token_str.decode()
    if not isinstance(token_str, str) or not token_str:
        return {}

    try:
        return pyjwt.decode(token_str, options={"verify_signature": False})
    except Exception:
        # Older SDK versions emit nested JWTs; fall back to a naive
        # middle-segment base64 decode so we still get something.
        parts = token_str.split(".")
        if len(parts) >= 2:
            import base64
            padded = parts[1] + "=" * (-len(parts[1]) % 4)
            try:
                return json.loads(base64.urlsafe_b64decode(padded))
            except Exception:
                return {}
        return {}


def _extract_error_detail(jwt_token) -> str:
    claims = _decode_unverified_claims(jwt_token)
    msg = claims.get("x-nv-err-message") or claims.get("error") or ""
    code = claims.get("x-nv-err-code") or claims.get("error_code") or ""
    return f"{msg} (code={code})" if (msg or code) else "(no detail in claims)"


def _assert_nonce_match(claims: dict, expected_hex: str) -> None:
    # The SDK places the supplied nonce either at the top level or
    # inside a per-GPU sub-claim. Accept either location.
    candidates = []
    for key in ("x-nv-gpu-nonce", "nonce", "x-nv-nonce"):
        if key in claims:
            candidates.append(claims[key])
    for subkey in ("submods", "x-nv-gpu-claims", "gpu_claims"):
        sub = claims.get(subkey)
        if isinstance(sub, dict):
            for key in ("x-nv-gpu-nonce", "nonce"):
                if key in sub:
                    candidates.append(sub[key])
    if not candidates:
        raise RuntimeError("GPU attestation claims missing nonce field")
    if not any(str(c).lower() == expected_hex.lower() for c in candidates):
        raise RuntimeError(
            f"GPU attestation nonce mismatch: expected {expected_hex[:16]}..., "
            f"got {candidates!r}"
        )


def _assert_cc_mode_on(claims: dict) -> None:
    # Shape varies across SDK versions; check the common spots.
    def _is_on(value) -> bool:
        return str(value).upper() in ("ON", "TRUE", "1")

    for key in ("x-nv-gpu-cc-mode", "cc_mode", "x-nv-gpu-cc-enable-status"):
        if key in claims and _is_on(claims[key]):
            return
    for subkey in ("submods", "x-nv-gpu-claims", "gpu_claims"):
        sub = claims.get(subkey)
        if isinstance(sub, dict):
            for key in ("x-nv-gpu-cc-mode", "cc_mode"):
                if key in sub and _is_on(sub[key]):
                    return
    raise RuntimeError(f"GPU attestation claims do not indicate CC mode ON: {claims}")
