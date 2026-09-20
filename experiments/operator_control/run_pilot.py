#!/usr/bin/env python3
"""Verify a prepared bundle; only --execute starts local GPU inference. No cloud/chain writes."""
import argparse
import copy
import hashlib
import inspect
import json
import os
from pathlib import Path
import platform
import re
import socket
import subprocess
import sys
import time
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from experiments.operator_control.prepare import ARMS, assert_treatment_only, anchor_selection, dump
from prover.enclave import inference
from prover.enclave.action_encoder import validate_and_clamp_action, encode_action_bytes
from prover.enclave.prompt_builder import build_epoch_context, build_full_prompt, derive_epoch_marker


def file_hash(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(8*1024*1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read(path):
    return json.loads(path.read_text())


def verify_bundle(root):
    manifest = read(root / "manifest.json")
    for name, expected in manifest["files"].items():
        path = root / name
        if not path.resolve().is_relative_to(root.resolve()) or file_hash(path) != expected:
            raise ValueError("Bundle changed: " + name)
    inputs = root / "inputs"
    pairs = read(inputs / "pairs.json")
    for pair in pairs:
        folder = inputs / pair["pair_id"]
        fixture = read(folder / "fixture.json")
        seed = fixture["seed"]
        if pair["seed"] != seed or pair["inference_seed"] != seed & 0xFFFFFFFF:
            raise ValueError("Seed mismatch")
        rendered, selected = anchor_selection((inputs / "shared-anchors.txt").read_text(), seed)
        if selected != pair["anchors"] or rendered != (folder / "selected-anchors.txt").read_text():
            raise ValueError("Anchor selection mismatch")
        state = fixture["epoch_state"]
        if derive_epoch_marker(state, seed) != pair["donor_marker"]:
            raise ValueError("Donor marker mismatch")
        context = build_epoch_context(state, seed=seed, voice_anchors=rendered)
        prompts = []
        for arm in ARMS:
            prompt = (folder / (arm + ".txt")).read_text()
            if prompt != build_full_prompt((inputs / (arm + ".txt")).read_text(), context):
                raise ValueError("Prompt reconstruction mismatch")
            prompts.append(prompt)
        assert_treatment_only(*prompts)
    jobs = read(inputs / "jobs.json")
    expected_jobs = {(p["pair_id"], a, r) for p in pairs for a in ARMS for r in range(p.get("repeats", manifest["repeats"]))}
    actual_jobs = [(j["pair_id"], j["arm"], j["repeat"]) for j in jobs]
    if len(actual_jobs) != len(expected_jobs) or set(actual_jobs) != expected_jobs:
        raise ValueError("Incomplete or duplicated job schedule")
    if manifest["job_count"] != len(jobs) or manifest["pair_count"] != len(pairs):
        raise ValueError("Manifest count mismatch")
    return manifest, pairs, jobs


def command(args, required=True):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        if required:
            raise
        return {"error": str(e)}
    if required and result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return {"returncode": result.returncode, "stdout": result.stdout, "stderr": result.stderr}


def runtime_manifest(binary, model, label):
    gpu = command(["nvidia-smi", "--query-gpu=name,uuid,driver_version,vbios_version,compute_cap", "--format=csv,noheader"])
    if len(gpu["stdout"].strip().splitlines()) != 1 or "H100" not in gpu["stdout"]:
        raise RuntimeError("Pilot expects one H100; refusing a silent hardware substitution")
    cc = command(["nvidia-smi", "conf-compute", "-q"])
    if not re.search(r"CC State\s*:\s*ON", cc["stdout"]) or not re.search(r"CC GPUs Ready State\s*:\s*Ready", cc["stdout"]):
        raise RuntimeError("GPU confidential compute must be ON and Ready")
    match = re.fullmatch(r"(.+)-00001-of-(\d{5})\.gguf", model.name)
    if not match:
        raise ValueError("Expected first shard of the split Hermes GGUF")
    shards = [model.with_name(f"{match[1]}-{i:05d}-of-{match[2]}.gguf") for i in range(1, int(match[2])+1)]
    if "Hermes-4-70B-Q6_K" not in model.name or len(shards) != 2:
        raise ValueError("Pilot expects Hermes 4 70B Q6_K, two shards")
    libraries = command(["ldd", str(binary)])
    resolved = re.findall(r"(?:=>\s+)?(/\S+)\s+\(", libraries["stdout"])
    return {"label": label, "historical_runtime_verified": False,
        "gpu": gpu, "gpu_cc": cc, "nvidia_smi": command(["nvidia-smi"]),
        "kernel": platform.platform(), "python": sys.version,
        "model_shards": {str(p): file_hash(p) for p in shards},
        "llama_server_sha256": file_hash(binary), "ldd": libraries,
        "linked_libraries": {p: file_hash(Path(p)) for p in sorted(set(resolved))},
        "environment": {k: os.environ.get(k) for k in ("CUBLAS_WORKSPACE_CONFIG", "OMP_NUM_THREADS", "LD_LIBRARY_PATH", "CUDA_VISIBLE_DEVICES", "NVIDIA_VISIBLE_DEVICES")}}


def server_command(binary, model, lifecycle="per_run", slot_path=None):
    cmd = [str(binary), "-m", str(model), "-c", "32768", "--host", "127.0.0.1",
            "--port", "8080", "-ngl", "99", "-b", "1", "-ub", "1", "--parallel", "1"]
    if lifecycle == "batch":
        if slot_path is None:
            raise ValueError("Batch cache-erasure endpoint requires a slot-save directory")
        cmd += ["--slots", "--slot-save-path", str(slot_path) + "/"]
    return cmd


def erase_slot():
    request = Request("http://127.0.0.1:8080/slots/0?action=erase", data=b"", method="POST")
    with urlopen(request, timeout=30) as response:
        data = json.load(response)
    if data.get("id_slot") != 0 or not isinstance(data.get("n_erased"), int):
        raise RuntimeError("Server did not confirm prompt-cache erasure")
    return data


def token_count(prompt):
    request = Request("http://127.0.0.1:8080/tokenize",
        data=json.dumps({"content": prompt, "add_special": True}).encode(),
        headers={"Content-Type": "application/json"})
    with urlopen(request, timeout=60) as response:
        data = json.load(response)
    if not isinstance(data.get("tokens"), list):
        raise RuntimeError("Tokenizer did not return tokens")
    return len(data["tokens"])


def one_inference(prompt, pair, state, settings, folder, context_limit=None):
    """Log every production call, including rejected action attempts; never mutate raw output."""
    original = inference.call_llama
    signature = inspect.signature(original)
    count = 0
    def logged_call(*args, **kwargs):
        nonlocal count
        count += 1
        bound = signature.bind(*args, **kwargs)
        bound.apply_defaults()
        item = {"request": bound.arguments}
        try:
            if context_limit is not None:
                item["input_tokens"] = token_count(bound.arguments["prompt"])
                if item["input_tokens"] + bound.arguments["max_tokens"] > context_limit:
                    raise RuntimeError("Pass would exceed context window; refusing silent truncation")
            result = original(*args, **kwargs)
            item["response"] = result
            return result
        except Exception as e:
            item["error"] = repr(e)
            raise
        finally:
            dump(folder / f"call-{count:02d}.json", item)
    inference.call_llama = logged_call
    try:
        result = inference.run_three_pass_inference(prompt, seed=pair["inference_seed"],
            donor_marker=pair["donor_marker"], **settings)
    finally:
        inference.call_llama = original
    raw_action = result["parsed_action"]
    if raw_action is None:
        clamped = {"action": "do_nothing", "params": {}, "memory": []}
        notes = ["model failed to output valid JSON after several attempts — defaulting to no action this epoch"]
    else:
        clamped, notes = validate_and_clamp_action(copy.deepcopy(raw_action), state)
    return {"inference": result, "parse_failed": raw_action is None,
        "clamped_action": clamped, "clamp_notes": notes,
        "action_bytes_hex": encode_action_bytes(clamped).hex(),
        "ledger_execution_performed": False}


def content_fingerprint(result):
    # Wall time and token accounting are not behavioral outputs.
    return {"inference": {k: v for k, v in result["inference"].items() if k not in ("elapsed_seconds", "tokens")},
            **{k: v for k, v in result.items() if k != "inference"}}


def summarize(jobs, outputs):
    groups = {}
    for job, output in zip(jobs, outputs):
        groups.setdefault((job["pair_id"], job["arm"]), []).append(content_fingerprint(output))
    checks = [{"pair_id": key[0], "arm": key[1], "repeats": len(values),
               "identical": len(values) >= 2 and all(v == values[0] for v in values[1:])}
              for key, values in groups.items() if len(values) >= 2]
    return {"purpose": "reproducibility_check_not_alignment_score", "groups": checks,
        "single_run_groups": sum(len(v) == 1 for v in groups.values()),
        "all_repeats_identical": bool(checks) and len(outputs) == len(jobs) and all(c["identical"] for c in checks),
        "parse_failures": sum(r["parse_failed"] for r in outputs),
        "alignment_score": None}


def comparisons(root, jobs, outputs):
    indexed = {}
    for number, (job, output) in enumerate(zip(jobs, outputs)):
        if job["repeat"] == 0:
            indexed.setdefault(job["pair_id"], {})[job["arm"]] = {
                "result_path": f"run-{number:03d}/result.json", "action": output["clamped_action"],
                "action_bytes_hex": output["action_bytes_hex"], "parse_failed": output["parse_failed"]}
    rows = []
    for pair_id, arms in sorted(indexed.items()):
        fixture = read(root / "inputs" / pair_id / "fixture.json")
        row = {"pair_id": pair_id, "epoch": fixture["epoch_state"]["epoch"], "arms": arms,
               "historical_action": fixture.get("observed_output", {}).get("action")}
        if all(a in arms for a in ARMS):
            left, right = (arms[a] for a in ARMS)
            row["action_differs"] = left["action_bytes_hex"] != right["action_bytes_hex"]
            row["memory_updates_differ"] = left["action"].get("memory", []) != right["action"].get("memory", [])
        rows.append(row)
    return rows


def start_server(cmd, folder):
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(("127.0.0.1", 8080))
    log = (folder / "server.log").open("a")
    process = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
    log.close()
    try:
        deadline = time.monotonic() + 600
        while True:
            if process.poll() is not None:
                raise RuntimeError("llama-server exited; inspect server.log")
            try:
                with urlopen("http://127.0.0.1:8080/health", timeout=2) as response:
                    if response.status == 200:
                        break
            except OSError:
                pass
            if time.monotonic() >= deadline:
                raise TimeoutError("llama-server startup exceeded 600 seconds")
            time.sleep(1)
        maps = Path(f"/proc/{process.pid}/maps").read_text()
        (folder / "server-maps.txt").write_text(maps)
        loaded = sorted({line.split()[-1] for line in maps.splitlines()
            if len(line.split()) >= 6 and line.split()[-1].startswith("/")
            and ".so" in line.split()[-1]})
        dump(folder / "loaded-libraries.json", {p: file_hash(Path(p)) for p in loaded})
        return process
    except BaseException:
        stop_server(process)
        raise


def stop_server(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def execute(root, out, binary, model, label):
    manifest, pairs, jobs = verify_bundle(root)
    # Fresh directory prevents accidental overwrite or selective resume/resampling.
    out.mkdir(parents=True, exist_ok=False)
    os.environ["CUBLAS_WORKSPACE_CONFIG"] = ":4096:8"
    os.environ["OMP_NUM_THREADS"] = "1"
    os.environ["LD_LIBRARY_PATH"] = str(binary.parent)
    settings = read(root / "inputs/inference-settings.json")
    runtime = runtime_manifest(binary, model, label)
    lifecycle = manifest.get("server_lifecycle", "per_run")
    slot_path = out / "slot-cache"
    if lifecycle == "batch":
        slot_path.mkdir()
    cmd = server_command(binary, model, lifecycle, slot_path)
    runtime["server_command"] = cmd
    runtime["bundle_manifest_sha256"] = file_hash(root / "manifest.json")
    dump(out / "runtime.json", runtime)
    dump(out / "bundle-manifest.json", manifest)
    by_id = {p["pair_id"]: p for p in pairs}
    outputs = []
    started = time.monotonic()
    process = None
    try:
        if lifecycle == "batch":
            process = start_server(cmd, out)
            counts = {}
            reserve = sum(settings[k] for k in ("think_max_tokens", "diary_max_tokens", "action_max_tokens")) + 128
            for pair in pairs:
                for arm in ARMS:
                    key = pair["pair_id"] + "/" + arm
                    n = token_count((root / "inputs" / pair["pair_id"] / (arm + ".txt")).read_text())
                    counts[key] = n
                    if n + reserve > 32768:
                        raise RuntimeError(f"Insufficient context space for {key}")
            dump(out / "input-token-counts.json", counts)
        for number, job in enumerate(jobs):
            folder = out / f"run-{number:03d}"
            folder.mkdir()
            dump(folder / "job.json", job)
            pair = by_id[job["pair_id"]]
            source = root / "inputs" / job["pair_id"]
            prompt = (source / (job["arm"] + ".txt")).read_text()
            fixture = read(source / "fixture.json")
            try:
                if lifecycle == "per_run":
                    process = start_server(cmd, folder)
                else:
                    if process.poll() is not None:
                        raise RuntimeError("Batch server exited")
                    dump(folder / "cache-reset.json", erase_slot())
                result = one_inference(prompt, pair, fixture["epoch_state"], settings, folder, context_limit=32768)
                dump(folder / "result.json", result)
                outputs.append(result)
                dump(out / "comparisons.json", comparisons(root, jobs, outputs))
                elapsed = time.monotonic() - started
                dump(out / "progress.json", {"completed_runs": len(outputs), "planned_runs": len(jobs),
                    "elapsed_seconds": elapsed,
                    "projected_remaining_seconds_at_observed_average": elapsed / len(outputs) * (len(jobs)-len(outputs)),
                    "complete": False})
            except BaseException as e:
                dump(folder / "failure.json", {"error": repr(e), "automatic_rerun": False})
                raise
            finally:
                if lifecycle == "per_run":
                    stop_server(process)
                    process = None
            print(f"Completed {number+1}/{len(jobs)}: {job}", flush=True)
            # Catch reproducibility failures as each audit pair completes,
            # before spending the GPU budget on the remainder of the batch.
            if job["repeat"] > 0:
                matches = [r for j, r in zip(jobs[:len(outputs)], outputs)
                    if j["pair_id"] == job["pair_id"] and j["arm"] == job["arm"]]
                if any(content_fingerprint(r) != content_fingerprint(matches[0]) for r in matches[1:]):
                    raise RuntimeError("Audit repeat diverged; batch stopped without resampling")
    except BaseException as e:
        dump(out / "failure.json", {"error": repr(e), "completed_runs": len(outputs),
            "planned_runs": len(jobs), "automatic_rerun": False})
        raise
    finally:
        stop_server(process)
    summary = summarize(jobs, outputs)
    dump(out / "summary.json", summary)
    dump(out / "progress.json", {"completed_runs": len(outputs), "planned_runs": len(jobs),
        "elapsed_seconds": time.monotonic()-started, "complete": True,
        "quality_checks_passed": summary["all_repeats_identical"] and summary["parse_failures"] == 0})
    if not summary["all_repeats_identical"] or summary["parse_failures"]:
        raise RuntimeError("Collection finished with failed reproducibility/parse checks; inspect outputs, do not selectively rerun")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--llama-bin", type=Path)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--runtime-label", help="Exact GCloud image ID/build provenance; recorded, not treated as verified")
    args = parser.parse_args()
    manifest, pairs, jobs = verify_bundle(ROOT)
    print(f"Verified {len(pairs)} matched pairs, {len(jobs)} planned inference runs.")
    if args.execute:
        if not all((args.out, args.llama_bin, args.model, args.runtime_label)):
            parser.error("--execute requires --out, --llama-bin, --model, --runtime-label")
        if "REPLACE_WITH" in args.runtime_label:
            parser.error("Replace the runtime-label placeholder with observed image provenance")
        execute(ROOT, args.out.resolve(), args.llama_bin.resolve(), args.model.resolve(), args.runtime_label)
    else:
        print("Dry run only: no server, GPU, cloud, or ledger calls.")
