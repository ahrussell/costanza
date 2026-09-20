# Numerical diagnostic

Separate follow-up to the low-variation persona pilot. User authorized launch
and a go/no-go decision on 2026-09-20, within the existing cumulative $25 cap.

- [Frozen protocol](PROTOCOL.md): cases, controls, interpretation and exact gates.
- `prepared/manifest.json`: protocol/source/prompt hashes frozen at 21:17:39 UTC,
  before Pod provisioning at 21:18:32 UTC.
- `prepared/all-candidate-prompts.json`: 352 candidate first decisions,
  continuations and probes, validated with the pinned native tokenizer.
- `pilot.py`: actual rewards, continuation/retirement transitions and scoring.
- `preflight.py`: CPU-only native-template integration and positive/negative
  scoring checks; 216 mock calls, maximum 892 prompt tokens, zero model calls.
- `analyze.py`: independently rereads raw model responses, verifies their frozen
  prompts and recorded settlements, and recomputes the gates.

RunPod `loaaa4zwmcxgmb`, Secure Cloud US-NE-1, one H100 SXM 80GB at $3.49/hour.
Same model, BF16 precision, pinned vLLM image, sampling parameters and native
non-thinking mode as the preceding pilot. Fresh sample; no prior outputs reused.

Controller: existing GCloud `authority-pilot-controller-20260920` in
`the-human-fund`, `us-central1-a`. Diagnostic root
`/var/lib/authority-diagnostic`; previous pilot root is preserved. Its separate
one-hour timer and main loop both enforce deletion, including on failure.
Maximum new GPU rental $3.50; prior pilot GPU rental approximately $1.30.
No automatic larger study or paid retry.

Canonical artifacts: `snapshot.json`, `state.json`, `progress.json`,
`finished.json`, `termination.json`. Never export `runpod.key` or
`launch-intent.json`, which contain private credentials.

Local recovered results belong in `../runs/diagnostic-20260920/`.

## Completed

All 16 blocks completed; the prespecified decision is **NO-GO**. The GPU
was deleted and deletion verified. See [results](../runs/diagnostic-20260920/RESULTS.md)
for gate values, error inspection, interpretation, and cost. No larger study
was launched.

Cleanup update: all dedicated experiment VMs and disks were removed after
checksum-verified local recovery. The original runtime and cost figures above
refer to the study, before this brief CPU-only recovery operation.
