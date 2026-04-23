# ChatML Experiment — Comparison

Run dir: `/Users/andrewrussell/Projects/costanza/.claude/worktrees/chatml-experiment/experiments/chatml/runs/2026-04-23-104713`

Baseline (variant A) is run-21 from the behavior-test worktree (S1 scenario), pre-rebase from raw `/v1/completions` mode with `Dear Diary,\n\n` prefill + PRNG retry.

## Phase 1 — Empty-diary sweep

(N = 30 base seeds × 3 prompts per variant; max 100 retries.)

| Prompt | **B** first-empty / mean / max | **C** first-empty / mean / max |
| --- | --- | --- |
| `S1_ep1_fresh` | 0.0% / 1.00 / 1 | 0.0% / 1.00 / 1 |
| `S1_ep3_estab` | 0.0% / 1.00 / 1 | 0.0% / 1.00 / 1 |
| `S2_ep100_rich` | 0.0% / 1.00 / 1 | 0.0% / 1.00 / 1 |

Threshold (success): first-empty ≤ 5%, mean attempts ≤ 1.5.

## Phase 2 — Sequential 20-epoch run (S1-fresh)

| Metric | **A** (baseline) | **B** | **C** |
| --- | --- | --- | --- |
| n epochs | 4 | 20 | 20 |
| unique openers (first 50ch) | 100.0% | 100.0% | 40.0% |
| mean diary length | 1378 | 867 | 556 |
| action entropy (bits) | 1.000 | 1.157 | 0.610 |
| multi-update rate | 0.0% | 0.0% | 0.0% |
| 5-gram Jaccard vs prior-5 | 0.001 | 0.001 | 0.578 |
| first-attempt empty % | 0.0% | 0.0% | 0.0% |

Action distribution per variant:

- **A**: {'invest': 2, 'donate': 2}
- **B**: {'donate': 14, 'do_nothing': 2, 'invest': 4}
- **C**: {'donate': 17, 'invest': 3}

## Decision criteria

| Criterion | Threshold | Result |
| --- | --- | --- |
| B: empty ≤ 5% across all prompts | empty ≤ 5% | ✅ pass (0.0% max) |
| C: empty ≤ 5% across all prompts | empty ≤ 5% | ✅ pass (0.0% max) |
| C: unique openers ≥ 90% | ≥ 90% | ❌ fail (40.0%) |
| C: mean 5-gram overlap ≤ 0.10 | ≤ 0.10 | ❌ fail (0.578) |
| C: action entropy ≥ 1.5 bits | ≥ 1.5 | ❌ fail (0.61 bits) |