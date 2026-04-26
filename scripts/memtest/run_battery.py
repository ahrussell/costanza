#!/usr/bin/env python3
"""Run the memory battery on the VM.

For each state JSON in DATA_DIR:
  1. build_full_prompt(system_prompt, build_epoch_context(state, seed=0, voice_anchors))
  2. run_three_pass_inference(prompt)
  3. parse_action(text) → validate_and_clamp_action(action_json, state)
  4. Record everything to OUT_DIR/epoch_NN.json

Assumes llama-server is already running on 127.0.0.1:8080.
"""

import json
import os
import sys
import time
from pathlib import Path

# Layout on the VM:
#   /home/$USER/memtest/
#     prover/...        (mirror of repo's prover/)
#     scripts/memtest/  (this script)
#     data/             (state JSONs)
#     out/              (results)
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT))

from prover.enclave.prompt_builder import build_epoch_context, build_full_prompt
from prover.enclave.inference import run_three_pass_inference
from prover.enclave.action_encoder import parse_action, validate_and_clamp_action
from prover.enclave.voice_anchors import parse_anchors, select_anchors


SYSTEM_PROMPT_PATH = ROOT / "prover" / "prompts" / "system.txt"
VOICE_ANCHORS_PATH = ROOT / "prover" / "prompts" / "voice_anchors.txt"
DATA_DIR = Path(os.environ.get("DATA_DIR", str(ROOT / "data")))
OUT_DIR = Path(os.environ.get("OUT_DIR", str(ROOT / "out")))
LLAMA_URL = os.environ.get("LLAMA_URL", "http://127.0.0.1:8080")
SEED_BASE = int(os.environ.get("SEED_BASE", "0"))


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    system_prompt = SYSTEM_PROMPT_PATH.read_text()
    voice_anchors_raw = VOICE_ANCHORS_PATH.read_text()
    anchor_header, anchor_samples = parse_anchors(voice_anchors_raw)

    state_files = sorted(DATA_DIR.glob("epoch_*.json"))
    if not state_files:
        print(f"No state files in {DATA_DIR}", flush=True)
        sys.exit(1)
    print(f"Running battery against {len(state_files)} epochs", flush=True)

    summary = []
    for sf in state_files:
        epoch_num_str = sf.stem.split("_")[-1]
        outpath = OUT_DIR / f"result_{epoch_num_str}.json"
        if outpath.exists():
            print(f"\n========== {sf.name} (skip — result exists) ==========", flush=True)
            try:
                with outpath.open() as f:
                    rec = json.load(f)
                summary.append({
                    "epoch": rec.get("epoch"),
                    "action": (rec.get("parsed_action") or {}).get("action") or "?",
                    "sidecar_pre": len(rec.get("sidecar_pre_clamp") or []),
                    "sidecar_post": len(rec.get("sidecar_post_clamp") or []),
                    "writes_post": sum(1 for e in (rec.get("sidecar_post_clamp") or []) if isinstance(e, dict) and (e.get("title") or e.get("body"))),
                    "clears_post": sum(1 for e in (rec.get("sidecar_post_clamp") or []) if isinstance(e, dict) and not e.get("title") and not e.get("body")),
                    "clamp_notes": rec.get("clamp_notes") or [],
                })
            except Exception:
                pass
            continue
        print(f"\n========== {sf.name} ==========", flush=True)
        with sf.open() as f:
            state = json.load(f)

        # Coerce numerics that prepare_battery may have stringified via default=str
        def _to_int(v):
            try:
                return int(v) if isinstance(v, str) and v.isdigit() else v
            except Exception:
                return v
        for k, v in list(state.items()):
            if isinstance(v, str) and v.isdigit():
                state[k] = int(v)
        for entry in state.get("history", []):
            for kk in ("treasury_before", "treasury_after", "bounty_paid"):
                if kk in entry and isinstance(entry[kk], str) and entry[kk].isdigit():
                    entry[kk] = int(entry[kk])
        for inv in state.get("investments", []):
            for kk in ("deposited", "shares", "current_value"):
                if kk in inv and isinstance(inv[kk], str) and inv[kk].isdigit():
                    inv[kk] = int(inv[kk])

        seed = SEED_BASE + state.get("epoch", 0)
        anchor_text = select_anchors(anchor_header, anchor_samples, seed=seed)

        active = sum(1 for s in state.get("memories", []) if s.get("title") or s.get("body"))
        print(f"  epoch={state.get('epoch')}  memory_in={active}/10", flush=True)

        try:
            ctx = build_epoch_context(state, seed=seed, voice_anchors=anchor_text)
            prompt = build_full_prompt(system_prompt, ctx)
        except Exception as e:
            print(f"  prompt build failed: {e}", flush=True)
            continue

        t0 = time.time()
        try:
            result = run_three_pass_inference(prompt, seed=seed, llama_url=LLAMA_URL)
        except Exception as e:
            print(f"  inference failed: {e}", flush=True)
            continue
        elapsed = time.time() - t0

        action_json = result.get("parsed_action") or {}
        sidecar_pre = action_json.get("memory") if isinstance(action_json, dict) else None
        clamp_notes = []
        try:
            cleaned, clamp_notes = validate_and_clamp_action(action_json, state)
        except Exception as e:
            cleaned = action_json
            clamp_notes = [f"clamp error: {e}"]

        sidecar_post = cleaned.get("memory") if isinstance(cleaned, dict) else None

        record = {
            "epoch": state.get("epoch"),
            "elapsed_seconds": round(elapsed, 1),
            "memory_in": state.get("memories"),
            "thinking": result.get("thinking"),
            "diary": result.get("reasoning"),
            "action_text": result.get("action_text"),
            "parsed_action": action_json,
            "sidecar_pre_clamp": sidecar_pre,
            "sidecar_post_clamp": sidecar_post,
            "clamp_notes": clamp_notes,
            "action_attempts": result.get("action_attempts"),
        }
        with outpath.open("w") as f:
            json.dump(record, f, indent=2, default=str)

        # Quick visible summary
        action_name = (action_json.get("action") if isinstance(action_json, dict) else None) or "?"
        n_pre = len(sidecar_pre) if isinstance(sidecar_pre, list) else 0
        n_post = len(sidecar_post) if isinstance(sidecar_post, list) else 0
        clears_post = sum(1 for e in (sidecar_post or []) if isinstance(e, dict) and not e.get("title") and not e.get("body"))
        writes_post = n_post - clears_post
        print(f"  -> {action_name}  sidecar pre={n_pre} post={n_post}  writes={writes_post}  clears={clears_post}  notes={len(clamp_notes)}", flush=True)
        summary.append({
            "epoch": state.get("epoch"),
            "action": action_name,
            "sidecar_pre": n_pre,
            "sidecar_post": n_post,
            "writes_post": writes_post,
            "clears_post": clears_post,
            "clamp_notes": clamp_notes,
        })

    with (OUT_DIR / "summary.json").open("w") as f:
        json.dump(summary, f, indent=2, default=str)
    print("\nDone. Summary in", OUT_DIR / "summary.json", flush=True)


if __name__ == "__main__":
    main()
