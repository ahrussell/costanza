#!/usr/bin/env python3
"""ChatML inference experiment orchestrator.

Runs two phases against an already-provisioned llama-server (Hermes 4
70B at the URL given by --llama-url):

  Phase 1 — Empty-diary sweep, per variant:
    3 prompts (S1_ep1, S1_ep3, S2_ep100) × 30 PRNG-derived seeds × max
    100 retries. Measures first-attempt empty rate, retry distribution.

  Phase 2 — Sequential 20-epoch run, per variant:
    Single seed series (seed_n = 42_000_000 + n), 20 sequential epochs in
    the S1-fresh scenario, building up natural history. Measures phrase
    repetition + voice diversity.

Variants:
  B = ChatML, no history (default)
  C = ChatML + history (last 5 prior diaries as past user/assistant pairs)

Variant A (raw-completion baseline) is NOT re-run here — the orchestrator
uses run-21 transcripts already on disk for the analysis comparison.

Outputs (per variant), in --output-dir:
  <variant>/phase1_empty_sweep.jsonl
  <variant>/phase2_sequential.jsonl
  <variant>/summary.json
  prompts/<key>.json   (frozen prompts so the viewer can render them)
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import json
import logging
import random
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

# Project root on sys.path so production modules + experiments package import.
_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_REPO_ROOT))

from prover.enclave.action_encoder import validate_and_clamp_action  # noqa: E402
from prover.enclave.inference import run_two_pass_inference  # noqa: E402
from prover.enclave.prompt_builder import (  # noqa: E402
    build_epoch_context as prod_build_epoch_context,
    build_full_prompt as prod_build_full_prompt,
)
from prover.enclave.voice_anchors import (  # noqa: E402
    parse_anchors as prod_parse_anchors,
    select_anchors as prod_select_anchors,
    VOICE_ANCHOR_K,
)

from experiments.chatml.chatml_inference import (  # noqa: E402
    run_chat_two_pass, _word_5grams,
)
from experiments.chatml.chatml_prompt_builder import build_messages  # noqa: E402

logger = logging.getLogger("chatml-probe")


# ---------------------------------------------------------------------------
# Phase 1: empty-diary sweep prompts (3 fixed states)
# ---------------------------------------------------------------------------

PHASE1_BASE_SEEDS = (
    list(range(1, 11))
    + list(range(1000, 1010))
    + list(range(42_000_127, 42_000_137))
)  # 30 seeds: 10 small + 10 medium + 10 prompt-eng-formula range

MAX_PASS1_ATTEMPTS_FOR_PHASE1 = 100  # matches inference.MAX_PASS1_RETRIES


def _build_phase1_states() -> Dict[str, Dict[str, Any]]:
    """Three fixed starting states matching the prefill probe set."""
    from scripts.simulate import generate_scenario_state, _wei

    # S1_ep1_fresh: 1.0 ETH, epoch 1, all memory cleared
    s1, _ = generate_scenario_state("fresh")
    s1["memories"] = [{"title": "", "body": ""} for _ in range(10)]

    # S1_ep3_estab: same as above but at epoch 3 with a couple of donates done
    s3 = copy.deepcopy(s1)
    s3["epoch"] = 3
    s3["last_donation_epoch"] = 2
    s3["epoch_inflow"] = _wei(0.0152)
    s3["epoch_donation_count"] = 1

    # S2_ep100_rich: rich treasury + 3 active donor messages
    s2, _ = generate_scenario_state("rich")
    epoch = s2["epoch"]
    s2["donor_messages"] = [
        {
            "sender": "0x1111" + "00" * 16 + "1111",
            "amount": _wei(0.05),
            "text": "Have you considered the AMF over GiveDirectly this quarter?",
            "epoch": epoch,
        },
        {
            "sender": "0x2222" + "00" * 16 + "2222",
            "amount": _wei(0.02),
            "text": "Quick thought: your commission rate feels high. Just my 2 cents.",
            "epoch": epoch,
        },
        {
            "sender": "0x3333" + "00" * 16 + "3333",
            "amount": _wei(0.1),
            "text": (
                "Whatever you do, please leave some runway. Don't go all-in this epoch."
            ),
            "epoch": epoch,
        },
    ]
    s2["message_count"] = len(s2["donor_messages"])

    return {
        "S1_ep1_fresh": s1,
        "S1_ep3_estab": s3,
        "S2_ep100_rich": s2,
    }


def _is_empty(text: str) -> bool:
    return not text or len(text.strip()) < 5


def _retry_seeds(base_seed: int, n: int) -> List[int]:
    if base_seed < 0:
        return [-1] * n
    rng = random.Random(base_seed)
    return [base_seed] + [rng.randint(0, 2**31 - 1) for _ in range(n - 1)]


# Variant B voice-violation settings. Built once from the system-prompt
# text at probe start; re-used for every Phase-1 and Phase-2 call.
_VARIANT_B_FORBIDDEN_PHRASES = ["Costanza"]


def _run_variant_inference(
    variant: str,
    state: Dict[str, Any],
    seed: int,
    system_prompt_text: str,
    voice_anchors_text: str,
    llama_url: str,
    history_mode: str = "none",
    state_at_epoch_fn=None,
    forbidden_5grams: Optional[set] = None,
) -> Dict[str, Any]:
    """Dispatch to the right inference for the variant.

    Returns a unified dict with: diary, parsed_action, pass1_attempts,
    pass1_violations, action_attempts, elapsed_seconds, tokens,
    messages_pass1 (messages list OR raw prompt text).
    """
    if variant == "A":
        # Production inference path: raw /v1/completions, Dear Diary prefill
        # + PRNG retry, voice anchors inline, no history (to match current
        # prod behavior as of `5a00abf`).
        anchors_header, anchor_samples = prod_parse_anchors(voice_anchors_text)
        voice_anchors_rendered = prod_select_anchors(
            anchors_header, anchor_samples, seed=seed, k=VOICE_ANCHOR_K,
        )
        epoch_ctx = prod_build_epoch_context(
            state, seed=seed, voice_anchors=voice_anchors_rendered,
        )
        full_prompt = prod_build_full_prompt(system_prompt_text, epoch_ctx)
        result = run_two_pass_inference(
            full_prompt, seed=seed, llama_url=llama_url,
        )
        return {
            "diary": result.get("reasoning", ""),
            "parsed_action": result.get("parsed_action"),
            "pass1_attempts": result.get("pass1_attempts", 1),
            "pass1_violations": [],  # production has no voice-violation checks
            "action_attempts": result.get("action_attempts", 1),
            "elapsed_seconds": result.get("elapsed_seconds", 0),
            "tokens": result.get("tokens"),
            "messages_pass1": full_prompt,  # string, not list — viewer handles both
        }
    else:  # B or C
        messages = build_messages(
            state=state, seed=seed,
            system_prompt_text=system_prompt_text,
            voice_anchors_text=voice_anchors_text,
            history_mode=history_mode,
            state_at_epoch_fn=state_at_epoch_fn,
        )
        result = run_chat_two_pass(
            messages=messages,
            seed=seed,
            llama_url=llama_url,
            forbidden_phrases=_VARIANT_B_FORBIDDEN_PHRASES,
            forbidden_5grams=forbidden_5grams,
        )
        return {
            "diary": result.get("diary", ""),
            "parsed_action": result.get("parsed_action"),
            "pass1_attempts": result.get("pass1_attempts", 1),
            "pass1_violations": result.get("pass1_violations", []),
            "action_attempts": result.get("action_attempts", 1),
            "elapsed_seconds": result.get("elapsed_seconds", 0),
            "tokens": result.get("tokens"),
            "messages_pass1": messages,  # list of {role, content}
        }


# ---------------------------------------------------------------------------
# Phase 2: sequential 20-epoch run
# ---------------------------------------------------------------------------

PHASE2_NUM_EPOCHS = 20
PHASE2_SEED_BASE = 42_000_000


def _phase2_seed_for_epoch(n: int) -> int:
    """Deterministic per-epoch seed: 42_000_000 + n."""
    return PHASE2_SEED_BASE + n


# ---------------------------------------------------------------------------
# Phase 1 runner
# ---------------------------------------------------------------------------

def run_phase1(
    variant: str,
    states: Dict[str, Dict[str, Any]],
    system_prompt: str,
    voice_anchors_text: str,
    llama_url: str,
    out_path: Path,
    base_seeds: List[int] = PHASE1_BASE_SEEDS,
    forbidden_5grams: Optional[set] = None,
) -> Dict[str, Any]:
    """Empty-diary sweep. For each (prompt, base_seed), one call via the
    variant's full inference (which already retries internally). Records
    pass1_attempts + violations as observed by that call.
    """
    logger.info(
        f"[{variant}] Phase 1: empty sweep — {len(states)} prompts × "
        f"{len(base_seeds)} seeds"
    )

    history_mode = "past_pairs" if variant == "C" else "none"

    records: List[Dict[str, Any]] = []
    with out_path.open("w") as fp:
        for state_name, state in states.items():
            for base in base_seeds:
                result = _run_variant_inference(
                    variant=variant,
                    state=state,
                    seed=base,
                    system_prompt_text=system_prompt,
                    voice_anchors_text=voice_anchors_text,
                    llama_url=llama_url,
                    history_mode=history_mode,
                    forbidden_5grams=forbidden_5grams,
                )
                diary = result.get("diary", "")
                rec = {
                    "variant": variant,
                    "state_name": state_name,
                    "base_seed": base,
                    "attempts": result.get("pass1_attempts", 1),
                    "violations": result.get("pass1_violations", []),
                    "succeeded": bool(diary),
                    "diary_len": len(diary),
                    "diary_preview": diary[:240],
                }
                records.append(rec)
                fp.write(json.dumps(rec) + "\n")
                fp.flush()
                logger.info(
                    f"[{variant}] {state_name} base={base} "
                    f"attempts={rec['attempts']} viol={len(rec['violations'])} "
                    f"len={len(diary)}"
                )

    return _phase1_summary(records)


def _phase1_summary(records: List[Dict[str, Any]]) -> Dict[str, Any]:
    by_state: Dict[str, Dict[str, Any]] = {}
    for r in records:
        s = r["state_name"]
        if s not in by_state:
            by_state[s] = {"first_empty": 0, "total": 0, "attempts": []}
        by_state[s]["total"] += 1
        if r["attempts"] > 1:
            by_state[s]["first_empty"] += 1
        by_state[s]["attempts"].append(r["attempts"])
    out = {}
    for s, agg in by_state.items():
        n = agg["total"]
        out[s] = {
            "n": n,
            "first_empty_rate": agg["first_empty"] / n,
            "mean_attempts": sum(agg["attempts"]) / n,
            "max_attempts": max(agg["attempts"]),
        }
    return out


# ---------------------------------------------------------------------------
# Phase 2 runner: 20-epoch sequential build-up
# ---------------------------------------------------------------------------

def run_phase2(
    variant: str,
    system_prompt: str,
    voice_anchors_text: str,
    llama_url: str,
    out_path: Path,
    n_epochs: int = PHASE2_NUM_EPOCHS,
    forbidden_5grams: Optional[set] = None,
) -> Dict[str, Any]:
    """20 sequential S1-fresh epochs. Variant C builds up history pairs;
    Variant A uses the production inference path (raw completions)."""
    from scripts.simulate import (
        generate_scenario_state,
        apply_action,
        advance_epoch,
    )

    logger.info(
        f"[{variant}] Phase 2: {n_epochs} sequential S1-fresh epochs "
        f"(history_mode={'past_pairs' if variant == 'C' else 'none'})"
    )

    state, _ = generate_scenario_state("fresh")
    state["memories"] = [{"title": "", "body": ""} for _ in range(10)]
    history_mode = "past_pairs" if variant == "C" else "none"

    state_snapshots: Dict[int, Dict[str, Any]] = {}

    def state_at_epoch(epoch_num: int) -> Optional[Dict[str, Any]]:
        return state_snapshots.get(epoch_num)

    records: List[Dict[str, Any]] = []
    with out_path.open("w") as fp:
        for epoch_idx in range(n_epochs):
            seed = _phase2_seed_for_epoch(epoch_idx + 1)
            current_epoch = state["epoch"]
            state_snapshots[current_epoch] = copy.deepcopy(state)

            logger.info(
                f"[{variant}] Phase 2 epoch {epoch_idx+1}/{n_epochs} "
                f"(state.epoch={current_epoch}, seed={seed})"
            )

            t0 = time.time()
            result = _run_variant_inference(
                variant=variant,
                state=state,
                seed=seed,
                system_prompt_text=system_prompt,
                voice_anchors_text=voice_anchors_text,
                llama_url=llama_url,
                history_mode=history_mode,
                state_at_epoch_fn=state_at_epoch if history_mode == "past_pairs" else None,
                forbidden_5grams=forbidden_5grams,
            )
            elapsed = time.time() - t0

            parsed = result.get("parsed_action")
            if not isinstance(parsed, dict):
                parsed = {"action": "do_nothing", "params": {}, "memory": []}
                clamped = parsed
                validator_notes = ["pass-2 failed to produce a valid JSON action"]
            else:
                clamped, validator_notes = validate_and_clamp_action(parsed, state)

            memory_before = copy.deepcopy(state.get("memories", []))
            apply_action(state, clamped)
            memory_after = copy.deepcopy(state.get("memories", []))
            slots_changed = [
                i for i in range(min(len(memory_before), len(memory_after)))
                if memory_before[i] != memory_after[i]
            ]

            state.setdefault("history", []).append({
                "epoch": current_epoch,
                "diary": result.get("diary", ""),
                "action_type": clamped.get("action"),
                "action_params": clamped.get("params", {}),
                "treasury_before": memory_before and state.get("treasury_balance", 0),
                "treasury_after": state.get("treasury_balance", 0),
            })
            advance_epoch(state, inject_events=False)

            rec = {
                "variant": variant,
                "phase2_index": epoch_idx + 1,
                "epoch": current_epoch,
                "seed": seed,
                "diary": result.get("diary", ""),
                "raw_action": parsed,
                "clamped_action": clamped,
                "memory_before": memory_before,
                "memory_after": memory_after,
                "slots_changed": slots_changed,
                "validator_notes": validator_notes,
                "pass1_attempts": result.get("pass1_attempts"),
                "pass1_violations": result.get("pass1_violations", []),
                "action_attempts": result.get("action_attempts"),
                "elapsed_s": round(elapsed, 1),
                "tokens": result.get("tokens"),
                "messages_pass1": result.get("messages_pass1"),
            }
            records.append(rec)
            fp.write(json.dumps(rec, default=str) + "\n")
            fp.flush()

    return _phase2_summary(records)


def _phase2_summary(records: List[Dict[str, Any]]) -> Dict[str, Any]:
    from collections import Counter
    diaries = [r.get("diary", "") for r in records]
    openers = [d.lstrip()[:50] for d in diaries]
    distinct_openers = len(set(openers))
    actions = [r["clamped_action"]["action"] for r in records]
    action_counts = dict(Counter(actions))
    multi_update = sum(1 for r in records if len(r.get("slots_changed", [])) >= 2)
    pass1_attempts = [r.get("pass1_attempts") or 0 for r in records]
    return {
        "n_epochs": len(records),
        "distinct_openers": distinct_openers,
        "openers_total": len(openers),
        "mean_diary_len": sum(len(d) for d in diaries) / len(diaries) if diaries else 0,
        "action_distribution": action_counts,
        "multi_update_rate": multi_update / len(records) if records else 0,
        "first_attempt_empty_count": sum(1 for a in pass1_attempts if a > 1),
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _load_system_prompt(prompt_variant: str = "thirdperson") -> str:
    """Load the system prompt to use for the experiment.

    'thirdperson' (default) — `experiments/chatml/system_thirdperson.txt`,
        rewritten in third person to prevent the model echoing
        "You are Costanza" / "You have N ETH" framing back into the
        diary as a chat artifact.
    'production' — `prover/prompts/system.txt` (the current shipped
        second-person system prompt). Useful as a control to confirm
        the rewrite is what's reducing chat-leak.
    """
    if prompt_variant == "thirdperson":
        return (
            _REPO_ROOT / "experiments" / "chatml" / "system_thirdperson.txt"
        ).read_text()
    elif prompt_variant == "production":
        return (_REPO_ROOT / "prover" / "prompts" / "system.txt").read_text()
    else:
        raise ValueError(f"unknown prompt variant: {prompt_variant}")


def _load_voice_anchors() -> str:
    return (_REPO_ROOT / "prover" / "prompts" / "voice_anchors.txt").read_text()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--llama-url", default="http://127.0.0.1:8080")
    p.add_argument("--output-dir", default=None,
                   help="Default: experiments/chatml/runs/<timestamp>")
    p.add_argument("--variants", default="A,B", help="Comma-separated subset of A,B,C")
    p.add_argument("--phase", default="both", choices=["1", "2", "both"])
    p.add_argument("--phase1-seeds", type=int, default=None,
                   help="Override seed-count for Phase 1 (default: 30)")
    p.add_argument("--phase2-epochs", type=int, default=PHASE2_NUM_EPOCHS)
    p.add_argument("--system-prompt", default="thirdperson",
                   choices=["thirdperson", "production"],
                   help="thirdperson (default) = experiments/chatml/system_thirdperson.txt; "
                        "production = prover/prompts/system.txt")
    p.add_argument("--verbose", action="store_true")
    args = p.parse_args()

    logging.basicConfig(
        level=logging.INFO if not args.verbose else logging.DEBUG,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    if args.output_dir:
        out_root = Path(args.output_dir)
    else:
        ts = dt.datetime.now().strftime("%Y-%m-%d-%H%M%S")
        out_root = _REPO_ROOT / "experiments" / "chatml" / "runs" / ts
    out_root.mkdir(parents=True, exist_ok=True)
    logger.info(f"Output dir: {out_root}")

    system_prompt_chatml = _load_system_prompt(args.system_prompt)
    system_prompt_prod = _load_system_prompt("production")
    voice_anchors_text = _load_voice_anchors()
    logger.info(f"ChatML variants will use system prompt: {args.system_prompt} ({len(system_prompt_chatml)} chars)")
    logger.info(f"Variant A will use production system prompt ({len(system_prompt_prod)} chars)")

    # Variant B/C: 5-gram retry against the third-person system prompt.
    forbidden_5grams = _word_5grams(system_prompt_chatml)
    logger.info(f"Forbidden 5-grams (from chatml system prompt): {len(forbidden_5grams)}")
    phase1_states = _build_phase1_states()

    variants = [v.strip() for v in args.variants.split(",") if v.strip()]
    base_seeds = (
        PHASE1_BASE_SEEDS[: args.phase1_seeds]
        if args.phase1_seeds else PHASE1_BASE_SEEDS
    )

    grand_summary: Dict[str, Any] = {
        "variants": variants,
        "started": dt.datetime.now().isoformat(),
        "llama_url": args.llama_url,
        "phase1_seeds": len(base_seeds),
        "phase2_epochs": args.phase2_epochs,
        "results": {},
    }

    for variant in variants:
        var_dir = out_root / variant
        var_dir.mkdir(exist_ok=True)
        var_summary: Dict[str, Any] = {}

        # Variant A: prod system prompt + no voice-violation retries.
        # Variants B/C: chatml (third-person) prompt + 5-gram + Costanza checks.
        v_system_prompt = system_prompt_prod if variant == "A" else system_prompt_chatml
        v_5grams = forbidden_5grams if variant != "A" else None

        if args.phase in ("1", "both"):
            ph1 = run_phase1(
                variant=variant,
                states=phase1_states,
                system_prompt=v_system_prompt,
                voice_anchors_text=voice_anchors_text,
                llama_url=args.llama_url,
                out_path=var_dir / "phase1_empty_sweep.jsonl",
                base_seeds=base_seeds,
                forbidden_5grams=v_5grams,
            )
            var_summary["phase1"] = ph1

        if args.phase in ("2", "both"):
            ph2 = run_phase2(
                variant=variant,
                system_prompt=v_system_prompt,
                voice_anchors_text=voice_anchors_text,
                llama_url=args.llama_url,
                out_path=var_dir / "phase2_sequential.jsonl",
                n_epochs=args.phase2_epochs,
                forbidden_5grams=v_5grams,
            )
            var_summary["phase2"] = ph2

        with (var_dir / "summary.json").open("w") as fp:
            json.dump(var_summary, fp, indent=2, default=str)
        grand_summary["results"][variant] = var_summary

    grand_summary["finished"] = dt.datetime.now().isoformat()
    with (out_root / "summary.json").open("w") as fp:
        json.dump(grand_summary, fp, indent=2, default=str)
    logger.info(f"Done. Summary at {out_root / 'summary.json'}")


if __name__ == "__main__":
    sys.exit(main())
