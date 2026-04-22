#!/usr/bin/env python3
"""Fetch pinned NVIDIA RIMs for the current H100 + driver.

Must run on a live GCP H100 VM (e.g. `a3-highgpu-1g`) because the SDK
derives RIM identifiers from the live GPU's driver + VBIOS versions.
The fetched XML files are then scp'd back to a developer workstation
and committed to `prover/scripts/gcp/nvidia_artifacts/` so that every
subsequent dm-verity build measures the same pinned firmware version.

Typical workflow:

  gcloud compute instances create humanfund-rim-fetch \\
      --zone=us-central1-a \\
      --machine-type=a3-highgpu-1g \\
      --image-family=nvidia-...-ubuntu-2404 \\
      --provisioning-model=SPOT

  gcloud compute ssh humanfund-rim-fetch --zone=us-central1-a
      # on VM:
      sudo apt install -y nvidia-driver-580-open
      python3 -m venv venv && source venv/bin/activate
      pip install nv-attestation-sdk==2.7.0 nv-local-gpu-verifier==2.7.0
      python3 fetch_nvidia_rims.py --out /tmp/rims/
      exit

  gcloud compute scp --recurse \\
      humanfund-rim-fetch:/tmp/rims/*.xml \\
      prover/scripts/gcp/nvidia_artifacts/
  gcloud compute instances delete humanfund-rim-fetch

The fetcher intentionally does NOT apply the enclave's OCSP monkey-
patch — it runs during build prep where network access is fine, and
we want the fetch-time OCSP check to catch NVIDIA-side revocations
before we bake a RIM into the dm-verity image.
"""

import argparse
import os
import secrets
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="Fetch NVIDIA RIMs for local GPU")
    parser.add_argument("--out", type=Path, required=True,
                        help="Output directory for driver_rim.xml and vbios_rim.xml")
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)

    try:
        from verifier import cc_admin
        from verifier.cc_admin_utils import CcAdminUtils
        from verifier.config import BaseSettings, HopperSettings
    except ImportError as e:
        sys.exit(f"nv-local-gpu-verifier not installed: {e}")

    # A random nonce is fine here — the RIMs themselves aren't nonce-
    # bound, we just need to drive the evidence-collection path to
    # discover the running driver / VBIOS versions.
    nonce_hex = secrets.token_hex(32)
    evidence_list = cc_admin.collect_gpu_evidence_local(
        nonce_hex, ppcie_mode=False, no_gpu_mode=False,
    )
    if not evidence_list:
        sys.exit("Failed to collect GPU evidence — is the driver loaded and the GPU visible?")

    gpu = evidence_list[0]
    driver_version = gpu.get_driver_version()
    vbios_version = gpu.get_vbios_version().lower()
    print(f"Driver version: {driver_version}")
    print(f"VBIOS version:  {vbios_version}")

    # The SDK derives RIM IDs from live evidence via these helpers.
    # Their exact signatures vary slightly across SDK versions, so we
    # wrap the calls tolerantly and fail loud if the shape changes.
    settings = HopperSettings()
    chip = gpu.get_gpu_architecture()

    try:
        driver_rim_id = CcAdminUtils.get_driver_rim_file_id(driver_version, settings, chip)
    except TypeError:
        # Older signatures took just (driver_version, settings).
        driver_rim_id = CcAdminUtils.get_driver_rim_file_id(driver_version, settings)
    print(f"Driver RIM ID:  {driver_rim_id}")

    # VBIOS RIM derivation needs project IDs from the evidence.
    project = gpu.get_project()
    project_sku = gpu.get_project_sku()
    chip_sku = gpu.get_chip_sku()
    vbios_rim_id = CcAdminUtils.get_vbios_rim_file_id(
        project, project_sku, chip_sku, vbios_version,
    )
    print(f"VBIOS RIM ID:   {vbios_rim_id}")

    driver_rim = _fetch_rim(driver_rim_id, settings)
    vbios_rim = _fetch_rim(vbios_rim_id, settings)

    driver_path = args.out / "driver_rim.xml"
    vbios_path = args.out / "vbios_rim.xml"
    driver_path.write_bytes(driver_rim)
    vbios_path.write_bytes(vbios_rim)
    print(f"Wrote {driver_path} ({len(driver_rim)} bytes)")
    print(f"Wrote {vbios_path} ({len(vbios_rim)} bytes)")

    # Write a provenance file alongside the XMLs so the committed
    # artifacts always carry the driver + VBIOS versions they match.
    (args.out / "PROVENANCE.txt").write_text(
        f"driver_version: {driver_version}\n"
        f"vbios_version:  {vbios_version}\n"
        f"driver_rim_id:  {driver_rim_id}\n"
        f"vbios_rim_id:   {vbios_rim_id}\n"
    )


def _fetch_rim(rim_id, settings) -> bytes:
    """Try a few SDK call shapes — the helper has churned across versions."""
    from verifier.cc_admin_utils import CcAdminUtils
    for attempt in (
        lambda: CcAdminUtils.fetch_rim_file(rim_id, settings),
        lambda: CcAdminUtils.fetch_rim_file(rim_id),
    ):
        try:
            result = attempt()
        except TypeError:
            continue
        return result.encode() if isinstance(result, str) else result
    sys.exit(f"Could not fetch RIM {rim_id} — SDK API shape changed?")


if __name__ == "__main__":
    main()
