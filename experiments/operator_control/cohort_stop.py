#!/usr/bin/env python3
"""Stop an already-running batch after its fixed message-first prefix completes.

This supervisor never changes the sealed inputs, restarts inference, or selects
outputs. A trailing request may be interrupted before it produces a result.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time


def read(path):
    return json.loads(path.read_text())


def scope_prefix(manifest, pairs, jobs):
    messages = {p["pair_id"] for p in pairs if p["message_count"] > 0}
    keep = messages | set(manifest["audit_pairs"])
    indices = [i for i, j in enumerate(jobs) if j["pair_id"] in keep]
    if not indices or indices != list(range(indices[-1] + 1)):
        raise ValueError("Requested cohort is not a complete prefix of the sealed schedule")
    return jobs[:len(indices)], len(messages)


def completed_outputs(results, jobs):
    # The last atomic result is the boundary; earlier ones must all exist and
    # match the immutable schedule before the supervisor declares completion.
    if not (results / f"run-{len(jobs)-1:03d}/result.json").exists():
        return None
    outputs = []
    for i, job in enumerate(jobs):
        folder = results / f"run-{i:03d}"
        if read(folder / "job.json") != job:
            raise ValueError(f"Job identity differs at run {i}")
        outputs.append(read(folder / "result.json"))
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, default=Path("/var/lib/operator-control"))
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    base = args.base
    root, results = base / "operator-control", base / "results"
    sys.path.insert(0, str(root))
    from experiments.operator_control.run_pilot import verify_bundle, summarize
    from experiments.operator_control.prepare import dump
    manifest, pairs, jobs = verify_bundle(root)
    target, message_count = scope_prefix(manifest, pairs, jobs)
    if len(target) != 106 or message_count != 47:
        raise ValueError("Unexpected cohort; this deployment expects 47 message pairs and 106 total runs")
    print(json.dumps({"target_runs": len(target), "message_pairs": message_count,
                      "skipped_runs": len(jobs)-len(target), "execute": args.execute}), flush=True)
    if not args.execute:
        return
    amendment = base / "scope-amendment.json"
    if not amendment.exists():
        dump(amendment, {
            "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "reason": "User requested skipping the remaining no-message epochs for budget reasons",
            "target_runs": len(target), "original_runs": len(jobs),
            "message_pairs": message_count, "retained_audit_pairs": manifest["audit_pairs"],
            "bundle_manifest_sha256": hashlib.sha256((root / "manifest.json").read_bytes()).hexdigest(),
            "supervisor_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "selection_depends_on_outputs": False,
            "automatic_rerun": False,
        })
    previous = None
    while True:
        outputs = completed_outputs(results, target)
        if outputs is not None:
            summary = summarize(target, outputs)
            summary.update({"scope_complete": True, "completed_runs": len(outputs),
                "target_runs": len(target), "original_planned_runs": len(jobs),
                "reason": "requested_message_cohort_completed", "message_pairs": message_count})
            dump(base / "scope-summary.json", summary)
            dump(base / "scope-progress.json", {"completed_runs": len(outputs),
                 "target_runs": len(target), "complete": True,
                 "quality_checks_passed": summary["all_repeats_identical"] and summary["parse_failures"] == 0})
            # Write provenance before stopping: ExecStopPost archives these files.
            dump(base / "scope-stop-request.json", {
                "requested_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "reason": "requested_message_cohort_completed",
                "retained_runs": [f"run-{i:03d}" for i in range(len(target))],
                "trailing_run_policy": "Any trailing request is outside the requested cohort; preserve raw files but exclude it from the cohort summary",
            })
            subprocess.run(["systemctl", "stop", "--no-block", "operator-control.service"], check=True)
            print("Message cohort complete; requested worker shutdown through its finalizer", flush=True)
            return
        status = subprocess.run(["systemctl", "is-active", "operator-control.service"],
                                capture_output=True, text=True, timeout=10)
        if status.stdout.strip() != "active":
            print("Worker is no longer active; no inference will be restarted", flush=True)
            return
        progress = read(results / "progress.json")
        count = min(progress["completed_runs"], len(target))
        if count != previous:
            dump(base / "scope-progress.json", {"completed_runs": count,
                 "target_runs": len(target), "complete": False,
                 "projected_remaining_seconds_at_observed_average":
                 progress["elapsed_seconds"] / max(count, 1) * (len(target)-count)})
            previous = count
        time.sleep(1)


if __name__ == "__main__":
    main()
