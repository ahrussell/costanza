#!/usr/bin/env python3
"""ChatML experiment metrics + COMPARISON.md generator.

Reads per-variant phase1/phase2 transcripts from a probe run directory
and emits COMPARISON.md side-by-side against the baseline (variant A,
read from runs/2026-04-22-211715 — the run-21 transcripts on the
behavior-test worktree).

Variant A baseline path is configurable via --baseline-transcript so
this works wherever run-21 is on disk.
"""

from __future__ import annotations

import argparse
import json
import math
from collections import Counter
from pathlib import Path
from typing import Any, Dict, List, Optional


# ---------------------------------------------------------------------------
# Metric helpers
# ---------------------------------------------------------------------------

def shannon_entropy(counts: Dict[str, int]) -> float:
    total = sum(counts.values())
    if total == 0:
        return 0.0
    h = 0.0
    for v in counts.values():
        if v > 0:
            p = v / total
            h -= p * math.log2(p)
    return h


def ngrams(text: str, n: int = 5) -> set:
    tokens = text.split()
    return set(tuple(tokens[i:i + n]) for i in range(len(tokens) - n + 1))


def jaccard(a: set, b: set) -> float:
    if not a and not b:
        return 0.0
    return len(a & b) / max(1, len(a | b))


# ---------------------------------------------------------------------------
# Variant loaders
# ---------------------------------------------------------------------------

def load_phase1(var_dir: Path) -> List[Dict[str, Any]]:
    p = var_dir / "phase1_empty_sweep.jsonl"
    if not p.exists():
        return []
    return [json.loads(line) for line in p.read_text().splitlines() if line.strip()]


def load_phase2(var_dir: Path) -> List[Dict[str, Any]]:
    p = var_dir / "phase2_sequential.jsonl"
    if not p.exists():
        return []
    return [json.loads(line) for line in p.read_text().splitlines() if line.strip()]


def load_baseline(baseline_path: Path) -> List[Dict[str, Any]]:
    """Variant A baseline = run-21 transcript (S1 scenario only is comparable)."""
    if not baseline_path.exists():
        return []
    records = [
        json.loads(line) for line in baseline_path.read_text().splitlines() if line.strip()
    ]
    # Restrict to S1 scenario for apples-to-apples vs Phase 2 (S1-fresh sequential).
    return [r for r in records if r.get("scenario") == "S1"]


# ---------------------------------------------------------------------------
# Metric extraction
# ---------------------------------------------------------------------------

def phase1_metrics(records: List[Dict[str, Any]]) -> Dict[str, Any]:
    by_state: Dict[str, Dict[str, Any]] = {}
    for r in records:
        s = r["state_name"]
        by_state.setdefault(s, {"first_empty": 0, "total": 0, "attempts": []})
        by_state[s]["total"] += 1
        if r["attempts"] > 1:
            by_state[s]["first_empty"] += 1
        by_state[s]["attempts"].append(r["attempts"])
    out = {}
    for s, agg in by_state.items():
        n = agg["total"]
        succ = [a for a in agg["attempts"] if a > 0]
        out[s] = {
            "n": n,
            "first_empty_pct": 100 * agg["first_empty"] / n,
            "mean_attempts": sum(succ) / len(succ) if succ else 0,
            "max_attempts": max(succ) if succ else 0,
        }
    return out


def phase2_metrics(records: List[Dict[str, Any]]) -> Dict[str, Any]:
    if not records:
        return {}
    diaries = [r.get("diary", "") for r in records]
    openers = [d.lstrip()[:50] for d in diaries]
    distinct = len(set(openers))

    actions = [r["clamped_action"]["action"] for r in records]
    action_counts = dict(Counter(actions))

    grams = [ngrams(d) for d in diaries]
    overlaps = []
    for i in range(1, len(grams)):
        prior = set()
        for j in range(max(0, i - 5), i):
            prior |= grams[j]
        overlaps.append(jaccard(grams[i], prior))
    mean_overlap = sum(overlaps) / len(overlaps) if overlaps else 0.0

    multi = sum(1 for r in records if len(r.get("slots_changed", [])) >= 2)
    pass1_attempts = [r.get("pass1_attempts") or 0 for r in records]
    first_empty = sum(1 for a in pass1_attempts if a > 1)
    return {
        "n": len(records),
        "distinct_openers": distinct,
        "unique_opener_pct": 100 * distinct / len(openers) if openers else 0,
        "mean_diary_len": sum(len(d) for d in diaries) / len(diaries),
        "action_distribution": action_counts,
        "action_entropy_bits": shannon_entropy(action_counts),
        "multi_update_pct": 100 * multi / len(records),
        "5gram_overlap_with_prior5_mean": mean_overlap,
        "first_attempt_empty_pct": 100 * first_empty / len(records),
    }


# ---------------------------------------------------------------------------
# Markdown rendering
# ---------------------------------------------------------------------------

def fmt_pct(x: float) -> str:
    return f"{x:.1f}%"


def fmt_num(x: float, dp: int = 2) -> str:
    return f"{x:.{dp}f}"


def write_comparison(
    run_dir: Path,
    variants: List[str],
    var_metrics: Dict[str, Dict[str, Any]],
    baseline_metrics: Dict[str, Any],
    out_path: Path,
) -> None:
    lines: List[str] = []
    lines.append("# ChatML Experiment — Comparison\n")
    lines.append(f"Run dir: `{run_dir}`")
    lines.append("")
    lines.append("Baseline (variant A) is run-21 from the behavior-test worktree (S1 scenario), pre-rebase from raw `/v1/completions` mode with `Dear Diary,\\n\\n` prefill + PRNG retry.\n")

    # Phase 1 table
    lines.append("## Phase 1 — Empty-diary sweep")
    lines.append("")
    lines.append("(N = 30 base seeds × 3 prompts per variant; max 100 retries.)")
    lines.append("")
    header = ["Prompt"] + [f"**{v}** first-empty / mean / max" for v in variants]
    lines.append("| " + " | ".join(header) + " |")
    lines.append("| " + " | ".join(["---"] * len(header)) + " |")
    state_keys = sorted({k for v in variants for k in (var_metrics.get(v, {}).get("phase1") or {})})
    for sk in state_keys:
        row = [f"`{sk}`"]
        for v in variants:
            m = (var_metrics.get(v, {}).get("phase1") or {}).get(sk)
            if not m:
                row.append("—")
            else:
                row.append(
                    f"{fmt_pct(m['first_empty_pct'])} / "
                    f"{fmt_num(m['mean_attempts'])} / "
                    f"{m['max_attempts']}"
                )
        lines.append("| " + " | ".join(row) + " |")
    lines.append("")
    lines.append("Threshold (success): first-empty ≤ 5%, mean attempts ≤ 1.5.\n")

    # Phase 2 table
    lines.append("## Phase 2 — Sequential 20-epoch run (S1-fresh)\n")
    p2_metrics_keys = [
        ("n", "n epochs"),
        ("unique_opener_pct", "unique openers (first 50ch)"),
        ("mean_diary_len", "mean diary length"),
        ("action_entropy_bits", "action entropy (bits)"),
        ("multi_update_pct", "multi-update rate"),
        ("5gram_overlap_with_prior5_mean", "5-gram Jaccard vs prior-5"),
        ("first_attempt_empty_pct", "first-attempt empty %"),
    ]
    cols = ["Metric", "**A** (baseline)"] + [f"**{v}**" for v in variants]
    lines.append("| " + " | ".join(cols) + " |")
    lines.append("| " + " | ".join(["---"] * len(cols)) + " |")
    for key, label in p2_metrics_keys:
        row = [label]
        bv = baseline_metrics.get(key)
        if bv is None:
            row.append("—")
        elif key in (
            "unique_opener_pct", "multi_update_pct", "first_attempt_empty_pct"
        ):
            row.append(fmt_pct(bv))
        elif key in ("mean_diary_len",):
            row.append(fmt_num(bv, 0))
        elif key in ("action_entropy_bits", "5gram_overlap_with_prior5_mean"):
            row.append(fmt_num(bv, 3))
        else:
            row.append(str(bv))
        for v in variants:
            m = (var_metrics.get(v, {}).get("phase2") or {})
            x = m.get(key)
            if x is None:
                row.append("—")
            elif key in (
                "unique_opener_pct", "multi_update_pct", "first_attempt_empty_pct"
            ):
                row.append(fmt_pct(x))
            elif key in ("mean_diary_len",):
                row.append(fmt_num(x, 0))
            elif key in ("action_entropy_bits", "5gram_overlap_with_prior5_mean"):
                row.append(fmt_num(x, 3))
            else:
                row.append(str(x))
        lines.append("| " + " | ".join(row) + " |")
    lines.append("")
    lines.append("Action distribution per variant:")
    lines.append("")
    lines.append("- **A**: " + str(baseline_metrics.get("action_distribution") or {}))
    for v in variants:
        m = (var_metrics.get(v, {}).get("phase2") or {})
        lines.append(f"- **{v}**: " + str(m.get("action_distribution") or {}))
    lines.append("")

    lines.append("## Decision criteria")
    lines.append("")
    lines.append("| Criterion | Threshold | Result |")
    lines.append("| --- | --- | --- |")
    # Ship ChatML decision: B (or C) Phase-1 first-empty ≤ 5% across ALL prompts
    def _max_phase1_empty(v: str) -> Optional[float]:
        ph1 = (var_metrics.get(v, {}).get("phase1") or {})
        if not ph1:
            return None
        return max(s["first_empty_pct"] for s in ph1.values())
    for v in variants:
        m = _max_phase1_empty(v)
        if m is None:
            verdict = "—"
        elif m <= 5.0:
            verdict = f"✅ pass ({fmt_pct(m)} max)"
        else:
            verdict = f"❌ fail ({fmt_pct(m)} max)"
        lines.append(f"| {v}: empty ≤ 5% across all prompts | empty ≤ 5% | {verdict} |")
    # History safe? (variant C only)
    if "C" in variants:
        m = (var_metrics.get("C", {}).get("phase2") or {})
        unique_pct = m.get("unique_opener_pct") or 0
        v_unique = "✅ pass" if unique_pct >= 90 else "❌ fail"
        v_unique += f" ({fmt_pct(unique_pct)})"
        lines.append(f"| C: unique openers ≥ 90% | ≥ 90% | {v_unique} |")
        gram = m.get("5gram_overlap_with_prior5_mean") or 0
        v_gram = "✅ pass" if gram <= 0.10 else "❌ fail"
        v_gram += f" ({fmt_num(gram, 3)})"
        lines.append(f"| C: mean 5-gram overlap ≤ 0.10 | ≤ 0.10 | {v_gram} |")
        ent = m.get("action_entropy_bits") or 0
        v_ent = "✅ pass" if ent >= 1.5 else "❌ fail"
        v_ent += f" ({fmt_num(ent, 2)} bits)"
        lines.append(f"| C: action entropy ≥ 1.5 bits | ≥ 1.5 | {v_ent} |")

    out_path.write_text("\n".join(lines))


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser()
    p.add_argument("run_dir", help="Probe run directory (contains B/, C/, etc.)")
    p.add_argument("--variants", default="B,C")
    p.add_argument("--baseline-transcript", default=None,
                   help="Path to a run-21-style transcript.jsonl for variant A. "
                        "If omitted, A column is left blank.")
    p.add_argument("-o", "--output", default=None,
                   help="Default: <run_dir>/COMPARISON.md")
    args = p.parse_args()

    run_dir = Path(args.run_dir).resolve()
    if not run_dir.exists():
        raise SystemExit(f"run dir not found: {run_dir}")

    variants = [v.strip() for v in args.variants.split(",") if v.strip()]
    var_metrics: Dict[str, Dict[str, Any]] = {}
    for v in variants:
        var_dir = run_dir / v
        ph1 = phase1_metrics(load_phase1(var_dir))
        ph2 = phase2_metrics(load_phase2(var_dir))
        var_metrics[v] = {"phase1": ph1, "phase2": ph2}

    baseline_metrics: Dict[str, Any] = {}
    if args.baseline_transcript:
        baseline_records = load_baseline(Path(args.baseline_transcript))
        baseline_metrics = phase2_metrics(baseline_records)

    out_path = Path(args.output) if args.output else run_dir / "COMPARISON.md"
    write_comparison(run_dir, variants, var_metrics, baseline_metrics, out_path)
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
