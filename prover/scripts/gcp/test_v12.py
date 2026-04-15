#!/usr/bin/env python3
"""One-shot test for humanfund-dmverity-hardened-v12.

Boots a TDX VM with a minimal epoch state, polls serial console for:
  1. TDX measurements (MRTD + RTMRs) — emitted early, before inference
  2. Full enclave output — confirms inference ran and quote was generated

Saves measurements to v12_measurements.txt and deletes the VM on exit.
"""

import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
import tempfile
import atexit
from pathlib import Path

# ─── Config ──────────────────────────────────────────────────────────────────

IMAGE    = "humanfund-dmverity-hardened-v12"
PROJECT  = os.environ.get("GCP_PROJECT", "the-human-fund")
ZONE     = os.environ.get("GCP_ZONE", "us-central1-a")
TIMEOUT  = 1800  # 30 min — H100 SPOT can take a while to provision + run inference

MEASUREMENTS_START = "===HUMANFUND_MEASUREMENTS_START==="
MEASUREMENTS_END   = "===HUMANFUND_MEASUREMENTS_END==="
OUTPUT_START       = "===HUMANFUND_OUTPUT_START==="
OUTPUT_END         = "===HUMANFUND_OUTPUT_END==="

SCRIPT_DIR = Path(__file__).parent
MEASUREMENTS_FILE = SCRIPT_DIR / "v12_measurements.txt"

# ─── Minimal epoch state (valid for hashing + prompt building) ───────────────

EPOCH_STATE = {
    "epoch": 1,
    "treasury_balance": 10 * 10**18,
    "commission_rate_bps": 500,
    "max_bid": 10**15,
    "effective_max_bid": 10**15,
    "consecutive_missed": 0,
    "last_donation_epoch": 0,
    "last_commission_change_epoch": 0,
    "total_inflows": 10 * 10**18,
    "total_donated": 0,
    "total_donated_usd": 0,
    "total_commissions": 0,
    "total_bounties": 0,
    "epoch_inflow": 10 * 10**18,
    "epoch_donation_count": 0,
    "epoch_eth_usd_price": 160_000_000_000,  # $1600 with 8 decimals
    "epoch_duration": 5400,  # 90 min
    "nonprofits": [
        {
            "name": "GiveDirectly",
            "description": "Direct cash transfers to people living in extreme poverty.",
            "ein": "0x" + "00" * 32,
            "total_donated": 0,
            "total_donated_usd": 0,
            "donation_count": 0,
        }
    ],
    "investments": [],
    "total_invested": 0,
    "total_assets": 10 * 10**18,
    "guiding_policies": ["", "", "", "", "", "", "", "", "", ""],
    "donor_messages": [],
    "history": [],
}

EPOCH_DATA = {"epoch_state": EPOCH_STATE, "seed": 12345678}


# ─── gcloud helper ───────────────────────────────────────────────────────────

def gcloud(args, check=True, timeout=120):
    cmd = ["gcloud"] + shlex.split(args) + [f"--project={PROJECT}"]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode != 0:
        raise RuntimeError(f"gcloud failed:\n{result.stderr[:800]}")
    return result.stdout.strip()


# ─── VM lifecycle ────────────────────────────────────────────────────────────

vm_name = None

def cleanup():
    if vm_name:
        print(f"\n[cleanup] Deleting VM {vm_name}...")
        try:
            gcloud(f"compute instances delete {vm_name} --zone={ZONE} --quiet",
                   check=False, timeout=180)
            print("[cleanup] VM deleted.")
        except Exception as e:
            print(f"[cleanup] Warning: {e}")

atexit.register(cleanup)


def create_vm():
    global vm_name
    vm_name = f"humanfund-v12test-{int(time.time())}"
    print(f"[boot] Creating TDX VM: {vm_name}")
    print(f"       image={IMAGE}  zone={ZONE}")

    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(EPOCH_DATA, f)
        meta_file = f.name

    try:
        gcloud(
            f"compute instances create {vm_name} "
            f"--zone={ZONE} "
            f"--machine-type=a3-highgpu-1g "
            f"--image={IMAGE} "
            f"--confidential-compute-type=TDX "
            f"--boot-disk-size=300GB "
            f"--maintenance-policy=TERMINATE "
            f"--provisioning-model=SPOT "
            f"--instance-termination-action=DELETE "
            f"--metadata-from-file=epoch-state={meta_file} "
            f"--scopes=https://www.googleapis.com/auth/compute.readonly",
            timeout=300,
        )
    finally:
        os.unlink(meta_file)

    print(f"[boot] VM created.\n")


# ─── Serial console polling ───────────────────────────────────────────────────

def get_serial():
    return gcloud(
        f"compute instances get-serial-port-output {vm_name} --zone={ZONE}",
        check=False, timeout=30,
    )


def parse_measurements(serial):
    """Extract MRTD + RTMRs from serial output."""
    s = serial.find(MEASUREMENTS_START)
    e = serial.find(MEASUREMENTS_END)
    if s < 0 or e <= s:
        return None
    measurements = {}
    for label, key in [("MRTD", "mrtd"), ("RTMR0", "rtmr0"),
                       ("RTMR1", "rtmr1"), ("RTMR2", "rtmr2"), ("RTMR3", "rtmr3")]:
        m = re.search(rf"{label}:([0-9a-f]{{96}})", serial)
        if m:
            measurements[key] = m.group(1)
    return measurements if len(measurements) >= 3 else None


def parse_output(serial):
    """Extract result JSON from serial output."""
    s = serial.find(OUTPUT_START)
    e = serial.find(OUTPUT_END)
    if s < 0 or e <= s:
        return None
    block = serial[s + len(OUTPUT_START):e]
    last_brace = block.rfind("\n{")
    if last_brace < 0:
        return None
    try:
        obj, _ = json.JSONDecoder().raw_decode(block[last_brace:].strip())
        return obj
    except json.JSONDecodeError:
        return None


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    create_vm()

    measurements = None
    result = None
    start = time.time()
    last_lines = 0

    print("[poll] Waiting for measurements + inference output...")
    print(f"       (timeout: {TIMEOUT}s)\n")

    while time.time() - start < TIMEOUT:
        try:
            serial = get_serial()
        except subprocess.TimeoutExpired:
            time.sleep(15)
            continue

        # Stream new enclave log lines
        lines = serial.split("\n")
        for line in lines[last_lines:]:
            if "[enclave]" in line:
                print(f"  {line.strip()}")
        last_lines = len(lines)

        # Grab measurements as soon as they appear (Step 0, early boot)
        if measurements is None:
            measurements = parse_measurements(serial)
            if measurements:
                print("\n[measurements] Extracted:")
                for k, v in measurements.items():
                    print(f"  {k.upper()}: {v}")

                # Compute platform key
                if all(k in measurements for k in ("mrtd", "rtmr1", "rtmr2")):
                    key = hashlib.sha256(
                        bytes.fromhex(measurements["mrtd"]) +
                        bytes.fromhex(measurements["rtmr1"]) +
                        bytes.fromhex(measurements["rtmr2"])
                    ).hexdigest()
                    measurements["platform_key"] = key
                    print(f"  PLATFORM_KEY: {key}")
                print()

        # Wait for full inference output
        if result is None:
            result = parse_output(serial)
            if result is not None:
                elapsed = time.time() - start
                print(f"\n[output] Received after {elapsed:.0f}s")
                break

        time.sleep(30)

    # ─── Validate ────────────────────────────────────────────────────────────

    ok = True

    if not measurements:
        print("\n[FAIL] No measurements found in serial output.")
        ok = False
    else:
        print("[PASS] Measurements extracted.")

    if result is None:
        print("[FAIL] No enclave output found.")
        ok = False
    else:
        status = result.get("status")
        has_quote = bool(result.get("attestation_quote", ""))
        has_action = "action" in result
        has_reasoning = bool(result.get("reasoning", ""))

        print(f"[{'PASS' if status == 'success' else 'FAIL'}] status={status}")
        print(f"[{'PASS' if has_quote else 'FAIL'}] attestation_quote present ({len(result.get('attestation_quote',''))} chars)")
        print(f"[{'PASS' if has_action else 'FAIL'}] action={result.get('action',{}).get('action','missing')}")
        print(f"[{'PASS' if has_reasoning else 'FAIL'}] reasoning present ({len(result.get('reasoning',''))} chars)")

        if status != "success":
            ok = False
        if not has_quote:
            ok = False

        print(f"\n--- inference stats ---")
        print(f"  inference_seconds : {result.get('inference_seconds', 'n/a')}")
        print(f"  tokens            : {result.get('tokens', 'n/a')}")
        print(f"  input_hash        : {result.get('input_hash', 'n/a')}")
        print(f"  seed              : {result.get('seed', 'n/a')}")

    # ─── Save measurements ───────────────────────────────────────────────────

    if measurements:
        lines = [
            f"image: {IMAGE}",
            f"built: {time.strftime('%Y-%m-%d')}",
            "",
        ]
        for k, v in measurements.items():
            lines.append(f"{k.upper()}: {v}")

        if result:
            lines += [
                "",
                f"input_hash: {result.get('input_hash', 'n/a')}",
                f"attestation_quote_len: {len(result.get('attestation_quote',''))}",
                f"inference_seconds: {result.get('inference_seconds', 'n/a')}",
            ]

        MEASUREMENTS_FILE.write_text("\n".join(lines) + "\n")
        print(f"\n[saved] Measurements written to {MEASUREMENTS_FILE}")

    print(f"\n{'[PASS] v12 test PASSED' if ok else '[FAIL] v12 test FAILED'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
