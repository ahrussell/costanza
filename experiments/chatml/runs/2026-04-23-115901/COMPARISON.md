# ChatML Experiment — Comparison

Run dir: `/Users/andrewrussell/Projects/costanza/.claude/worktrees/chatml-experiment/experiments/chatml/runs/2026-04-23-115901`

Baseline (variant A) is run-21 from the behavior-test worktree (S1 scenario), pre-rebase from raw `/v1/completions` mode with `Dear Diary,\n\n` prefill + PRNG retry.

## Phase 1 — Empty-diary sweep

(N = 30 base seeds × 3 prompts per variant; max 100 retries.)

| Prompt | **A** first-empty / mean / max | **B** first-empty / mean / max |
| --- | --- | --- |
| `S1_ep1_fresh` | 0.0% / 1.00 / 1 | 30.0% / 1.33 / 3 |
| `S1_ep3_estab` | 0.0% / 1.00 / 1 | 10.0% / 1.10 / 2 |
| `S2_ep100_rich` | 0.0% / 1.00 / 1 | 0.0% / 1.00 / 1 |

Threshold (success): first-empty ≤ 5%, mean attempts ≤ 1.5.

## Phase 2 — Sequential 20-epoch run (S1-fresh)

| Metric | **A** | **B** |
| --- | --- | --- |
| n epochs | 20 | 20 |
| unique openers (first 50ch) | 100.0% | 100.0% |
| mean diary length | 1397 | 894 |
| action entropy (bits) | 1.154 | 0.992 |
| multi-update rate | 40.0% | 20.0% |
| 5-gram Jaccard vs prior-5 | 0.003 | 0.001 |
| first-attempt empty % | 0.0% | 20.0% |

Action distribution per variant:

- **A**: {'invest': 3, 'donate': 15, 'do_nothing': 1, 'withdraw': 1}
- **B**: {'donate': 15, 'do_nothing': 1, 'invest': 4}

## Decision criteria

| Criterion | Threshold | Result |
| --- | --- | --- |
| A: empty ≤ 5% across all prompts | empty ≤ 5% | ✅ pass (0.0% max) |
| B: empty ≤ 5% across all prompts | empty ≤ 5% | ❌ fail (30.0% max) |