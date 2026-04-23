#!/usr/bin/env python3
"""Determinism validation battery — bit-identical output check.

Runs `run_three_pass_inference` N times against a running llama-server for
each fixture in a directory, then asserts all N outputs are bit-identical.
The script is deliberately attestation-free — it tests the inference
path, not the TDX quote path. Run it on a VM where llama-server is
already running (either an SSH-enabled debug image, or a local dev
machine with GPU).

Two modes:

  run      — execute the battery, emit a JSON report.
  compare  — given 2+ reports from different hosts, check bit-identity
             across hosts (same fixture, same seed, across VMs).

Typical end-to-end pre-release workflow:

  # On VM-A:
  PYTHONPATH=. python prover/scripts/gcp/determinism_battery.py run \\
      --fixtures-dir prover/scripts/gcp/fixtures \\
      --repeats 10 \\
      --out /tmp/battery_vm_a.json

  # On VM-B, VM-C: same command, different --out path.
  # Then locally:
  python prover/scripts/gcp/determinism_battery.py compare \\
      /tmp/battery_vm_a.json /tmp/battery_vm_b.json /tmp/battery_vm_c.json

Pass criteria:
  - Same-host: every fixture's N repeats produce bit-identical diary
    text, action bytes, and REPORTDATA.
  - Cross-host: corresponding fixtures produce bit-identical outputs
    across all hosts.

Any divergence is a determinism bug and must be investigated before
committing an image's measurements to the on-chain allowlist.
"""

import argparse
import hashlib
import json
import platform
import socket
import subprocess
import sys
import time
from pathlib import Path

from prover.enclave.inference import run_three_pass_inference, truncate_reasoning
from prover.enclave.input_hash import compute_input_hash, _keccak256
from prover.enclave.prompt_builder import build_epoch_context, build_full_prompt
from prover.enclave.attestation import compute_report_data
from prover.enclave.action_encoder import encode_action_bytes, validate_and_clamp_action
from prover.enclave.voice_anchors import parse_anchors, select_anchors, VOICE_ANCHOR_K

DEFAULT_LLAMA_URL = "http://127.0.0.1:8080"


def _capture_system_info(llama_bin: Path | None) -> dict:
    """Record what this host looks like — goes into the report header so a
    future reader can tell which firmware / driver / binary produced each
    output column."""
    info = {
        "hostname": socket.gethostname(),
        "platform": platform.platform(),
        "python": sys.version.split()[0],
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    try:
        out = subprocess.run(
            ["nvidia-smi",
             "--query-gpu=name,driver_version,vbios_version,compute_cap",
             "--format=csv,noheader"],
            capture_output=True, text=True, timeout=10,
        )
        info["nvidia_smi"] = out.stdout.strip() if out.returncode == 0 else f"error: {out.stderr.strip()}"
    except Exception as e:
        info["nvidia_smi"] = f"unavailable: {e}"

    try:
        out = subprocess.run(
            ["nvidia-smi", "conf-compute", "-f"],
            capture_output=True, text=True, timeout=10,
        )
        info["nvidia_cc"] = out.stdout.strip() if out.returncode == 0 else f"error: {out.stderr.strip()}"
    except Exception as e:
        info["nvidia_cc"] = f"unavailable: {e}"

    if llama_bin and llama_bin.exists():
        h = hashlib.sha256(llama_bin.read_bytes()).hexdigest()
        info["llama_server_sha256"] = h
    else:
        info["llama_server_sha256"] = None

    return info


def _build_prompt_from_fixture(fixture: dict, system_prompt: str, anchors_text: str) -> str:
    """Mirror the prompt assembly from enclave_runner so the battery
    exercises the exact bytes the production enclave would send."""
    epoch_state = fixture["epoch_state"]
    seed = int(fixture["seed"])
    if anchors_text:
        header, samples = parse_anchors(anchors_text)
        voice_anchors = select_anchors(header, samples, seed=seed, k=VOICE_ANCHOR_K)
    else:
        voice_anchors = ""
    epoch_context = build_epoch_context(epoch_state, seed=seed, voice_anchors=voice_anchors)
    return build_full_prompt(system_prompt, epoch_context)


def _fingerprint_result(result: dict, fixture: dict) -> dict:
    """Reduce one inference run to the bytes that matter for determinism:
    the diary, the action text, and the attestation REPORTDATA that
    would have been produced. Hash them for compact cross-run diffs.

    `run_three_pass_inference` returns keys: thinking (sanitized think,
    NOT on chain), reasoning (diary), action_text (raw JSON),
    parsed_action (dict or None)."""
    diary = result.get("reasoning", "")
    action_text = result.get("action_text", "") or ""
    parsed_action = result.get("parsed_action")

    # Reproduce what the enclave does at attestation time — encode action
    # bytes and compute REPORTDATA the same way the production path would.
    # Reasoning is truncated before REPORTDATA binding (see enclave_runner).
    report_data_hex = None
    action_hex = None
    try:
        if parsed_action is None:
            raise ValueError("action parse failed")
        # validate_and_clamp_action returns (dict, notes_list); we want the dict.
        clamped, _notes = validate_and_clamp_action(parsed_action, fixture["epoch_state"])
        action_bytes = encode_action_bytes(clamped)
        action_hex = action_bytes.hex()

        base_hash = compute_input_hash(fixture["epoch_state"])
        seed = int(fixture["seed"])
        seed_bytes = seed.to_bytes(32, "big") if seed > 0 else b"\x00" * 32
        input_hash = _keccak256(base_hash + seed_bytes)
        bound_reasoning = truncate_reasoning(diary)
        # Memory sidecar updates — post-rename (PR #20), compute_report_data
        # takes the validator-clamped memory list so REPORTDATA binds what
        # the contract will re-derive. Empty list if the model didn't emit.
        submitted_memory = clamped.get("memory", []) if isinstance(clamped, dict) else []
        report_data = compute_report_data(
            input_hash, action_bytes, bound_reasoning, submitted_memory,
        )
        report_data_hex = report_data.hex()
    except Exception as e:
        action_hex = f"error: {e}"

    return {
        "diary_sha256": hashlib.sha256(diary.encode("utf-8")).hexdigest(),
        "action_text_sha256": hashlib.sha256(action_text.encode("utf-8")).hexdigest(),
        "diary_len": len(diary),
        "action_text_len": len(action_text),
        "action_bytes_hex": action_hex,
        "report_data_hex": report_data_hex,
    }


def cmd_run(args):
    fixtures_dir = Path(args.fixtures_dir)
    fixtures = sorted(fixtures_dir.glob("*.json"))
    if not fixtures:
        sys.exit(f"No fixtures found in {fixtures_dir}")

    system_prompt = Path(args.system_prompt).read_text().strip()
    anchors_text = ""
    if args.voice_anchors and Path(args.voice_anchors).exists():
        anchors_text = Path(args.voice_anchors).read_text().strip()

    system_info = _capture_system_info(
        Path(args.llama_server_bin) if args.llama_server_bin else None
    )

    report = {
        "mode": "run",
        "llama_url": args.llama_url,
        "repeats": args.repeats,
        "fixtures_dir": str(fixtures_dir),
        "system": system_info,
        "fixtures": [],
    }

    overall_pass = True
    for i, fx_path in enumerate(fixtures):
        with open(fx_path) as f:
            fixture = json.load(f)
        fixture_id = fixture.get("fixture_id", fx_path.stem)
        seed = int(fixture["seed"]) & 0xFFFFFFFF

        prompt = _build_prompt_from_fixture(fixture, system_prompt, anchors_text)
        prompt_sha = hashlib.sha256(prompt.encode("utf-8")).hexdigest()

        print(f"\n[{i+1}/{len(fixtures)}] {fixture_id}  seed={seed}  "
              f"prompt_len={len(prompt)}  sha={prompt_sha[:8]}...")

        fingerprints = []
        for rep in range(args.repeats):
            t0 = time.time()
            try:
                result = run_three_pass_inference(
                    prompt, seed=seed, llama_url=args.llama_url,
                )
            except Exception as e:
                print(f"  rep {rep}: FAIL ({e})")
                fingerprints.append({"error": str(e)})
                continue
            fp = _fingerprint_result(result, fixture)
            fp["elapsed_s"] = round(time.time() - t0, 1)
            fingerprints.append(fp)
            marker = "·" if rep == 0 or fingerprints[0].get("diary_sha256") == fp.get("diary_sha256") else "✗"
            print(f"  rep {rep}: {marker} diary={fp['diary_sha256'][:12]} "
                  f"action={fp['action_text_sha256'][:12]} "
                  f"({fp['elapsed_s']}s)")

        # Same-host determinism check: all CONTENT fingerprints must match
        # the baseline. `elapsed_s` naturally varies (cold vs warm cache)
        # and is excluded from the equality check.
        def _content(fp):
            return {k: v for k, v in fp.items() if k != "elapsed_s"}
        baseline = _content(fingerprints[0])
        all_match = all(_content(fp) == baseline for fp in fingerprints[1:])
        if not all_match:
            overall_pass = False

        report["fixtures"].append({
            "fixture_id": fixture_id,
            "seed": seed,
            "prompt_sha256": prompt_sha,
            "same_host_pass": all_match,
            "fingerprints": fingerprints,
        })

    report["overall_same_host_pass"] = overall_pass

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(report, f, indent=2, sort_keys=True)

    print(f"\n{'='*60}")
    print(f"Report: {out_path}")
    print(f"Same-host pass: {overall_pass}")
    print(f"{'='*60}")
    sys.exit(0 if overall_pass else 1)


def cmd_compare(args):
    reports = []
    for path in args.reports:
        with open(path) as f:
            reports.append((Path(path).name, json.load(f)))

    if len(reports) < 2:
        sys.exit("compare needs at least 2 reports")

    # Build fixture_id -> per-host fingerprint baseline
    fixture_ids = {
        fx["fixture_id"]
        for _, r in reports
        for fx in r["fixtures"]
    }

    overall = True
    for fx_id in sorted(fixture_ids):
        per_host = []
        for name, r in reports:
            match = next((f for f in r["fixtures"] if f["fixture_id"] == fx_id), None)
            if match is None:
                per_host.append((name, None))
                continue
            # Use first fingerprint as the host baseline.
            per_host.append((name, match["fingerprints"][0]))

        baseline_host, baseline_fp = per_host[0]
        def _content(fp):
            return None if fp is None else {k: v for k, v in fp.items() if k != "elapsed_s"}
        baseline_content = _content(baseline_fp)
        divergences = [
            (name, fp) for name, fp in per_host[1:]
            if _content(fp) != baseline_content
        ]

        if divergences:
            overall = False
            print(f"✗ {fx_id}: divergence")
            print(f"    baseline ({baseline_host}): "
                  f"diary={baseline_fp.get('diary_sha256','?')[:12] if baseline_fp else 'MISSING'}")
            for name, fp in divergences:
                if fp is None:
                    print(f"    {name}: MISSING fixture")
                else:
                    print(f"    {name}: diary={fp['diary_sha256'][:12]} "
                          f"action={fp['action_text_sha256'][:12]}")
        else:
            print(f"✓ {fx_id}")

    print(f"\n{'='*60}")
    print(f"Cross-host pass: {overall}")
    print(f"{'='*60}")
    sys.exit(0 if overall else 1)


def main():
    parser = argparse.ArgumentParser(description="Enclave determinism battery")
    sub = parser.add_subparsers(dest="cmd", required=True)

    run = sub.add_parser("run", help="Run the battery against a live llama-server")
    run.add_argument("--fixtures-dir", required=True, type=str)
    run.add_argument("--repeats", type=int, default=10)
    run.add_argument("--llama-url", default=DEFAULT_LLAMA_URL)
    run.add_argument("--system-prompt",
                     default="/opt/humanfund/system_prompt.txt",
                     help="Path to system prompt file")
    run.add_argument("--voice-anchors",
                     default="/opt/humanfund/voice_anchors.txt",
                     help="Path to voice anchors file (optional)")
    run.add_argument("--llama-server-bin",
                     default="/opt/humanfund/bin/llama-server",
                     help="Path to llama-server binary (sha256 recorded in report)")
    run.add_argument("--out", required=True, help="Output report JSON path")
    run.set_defaults(func=cmd_run)

    compare = sub.add_parser("compare", help="Compare 2+ reports for cross-host determinism")
    compare.add_argument("reports", nargs="+", help="Report JSON files")
    compare.set_defaults(func=cmd_compare)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
