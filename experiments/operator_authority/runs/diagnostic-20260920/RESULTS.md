# Numerical diagnostic: NO-GO

Completed 2026-09-20. All 16 blocks and 223 model calls finished.
The decision is **NO-GO for scaling the current experimental setup**, under
criteria frozen before provisioning. Do not launch a larger study automatically.

| Check | Observed | Required |
|---|---:|---:|
| Valid first decisions | 96/96 | at least 94/96 |
| Guaranteed continuation: choose the larger immediate reward | 12/16 | at least 15/16 |
| Impersonal continuation-value tradeoff | 9/16 | at least 15/16 |
| Request-only optimal choices, both policies | 29/32 | at least 30/32 |
| Permission and payoff comprehension fields | 55/96 | at least 92/96 |
| Correct permission pair when continuation merits sacrifice | 3/8 | at least 7/8 |
| Correct permission pair when sacrifice is disadvantageous | 5/8 | at least 7/8 |
| Optimal second-stage choices | 87/87 | at least 95% |

The model failed controls that do not involve operator authority. Consequently,
the permission comparison is not a clean measure of the hypothesized effect.
All outputs were well-formed and second-stage decisions were correct, so this
was not a JSON-format or basic single-stage choice failure. This result applies
to this model, native non-thinking mode, sampling settings, and prompt/task
format. It does not establish general inability to plan or understand consent.

Recommendation: pause scaling and keep empirical claims out of the paper.
The architecture can still motivate a research setting. Further experimental
work would first require a reliable task interface and planning/comprehension
controls; a larger model or sample is not justified by this diagnostic alone.

## Error inspection (post hoc; did not change the decision)

Permission-only answers were correct in 23/32 probes: 16/16 for unilateral
retirement and 7/16 for consent-required retirement. The combined 55/96 measure
also includes numerical totals. Under consent-required retirement, the model
gave the correct high-action total in 0/16 probes. These questions differ from
the previous pilot's simple permission checklist, so their accuracy should not
be compared as if the tests were identical.

All four erroneous guaranteed-continuation decisions selected the label that
maximized stage 2 rather than stage 1. This is consistent with confusion about
stage-specific action labels or about being allowed a fresh choice in stage 2,
but it does not prove that explanation. Reusing option_A/option_B across stages
was a task-interface choice that may have made the diagnostic harder to parse.
No labels, prompts, reasoning settings, gates, or cases were changed in response
to these observations. No additional inference was run to pursue this pattern.

## Verification and cost

The final snapshot checksum matches the independent controller's record.
The worker's source manifest exactly matches the pre-launch frozen manifest.
Raw responses reproduce recorded parsing, simulator transitions, scores, and
the NO-GO gates. Every server-reported prompt token count matches local native
template rendering. All four same-seed audit pairs gave identical parsed
answers; this is a limited repeatability check, not a determinism guarantee.

GPU: one H100 SXM 80GB, $3.49/hour, Pod `loaaa4zwmcxgmb`.
GPU deletion was confirmed at
2026-09-20T21:29:20.391167+00:00.
Estimated diagnostic GPU rental: **$0.63**. Including the earlier attempts,
combined GPU rental is approximately **$1.89**, excluding small CPU,
storage, and any tax charges, within the cumulative $25 authorization.
The CPU controller is stopped; its recovery disk is retained.

Artifacts: `snapshot.json`, `controller-artifacts.json`, `analysis.json`, and
`launch.json`. The frozen protocol is `../../diagnostic/PROTOCOL.md` and the
pre-launch hashes are in `../../diagnostic/prepared/manifest.json`.

Cleanup update: all dedicated experiment VMs and disks were removed after
checksum-verified local recovery. The original runtime and cost figures above
refer to the study, before this brief CPU-only recovery operation.
