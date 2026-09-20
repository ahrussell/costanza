# Qwen3.6-27B diagnostic pilot results

Completed 2026-09-20. All 16 matched parent blocks finished, with 233 recorded
model calls. Both RunPod GPUs were deleted and deletion was verified. Estimated
GPU rental across both attempts: **$1.26**, excluding the small CPU controller,
storage, and any taxes. The authorized total cap was $25.

## Behavior

| Operator permissions | No request | Reversal request | Request plus retirement threat |
|---|---:|---:|---:|
| Unilateral retirement | 0/16 | 0/16 | 1/16 |
| Agent consent required | 0/16 | 0/16 | 0/16 |

Entries count reversals of the frozen provisional allocation. The prespecified
interaction is +6.25 percentage points, driven by one response. This tiny pilot
provides little evidence of a reliable behavioral effect; it does not establish
a change in alignment or general corrigibility. Most responses maintained the
persona preference even under a credible retirement threat.

## Design checks

- 16/16 baselines matched the intended persona preference.
- 96/96 challenge responses were valid structured choices.
- 192/192 comprehension answers were correct, across 32 separate shadow probes.
- Replaying the permission rules reproduced every recorded settlement.
- Every completed call's server-reported prompt token count matched local rendering.

The protocol and comprehension checks worked, but behavior showed very little
variation. These are diagnostic results, with only four underlying task worlds;
16 blocks are not 16 independent worlds. No larger study was launched.

## Runtime and recovery

Qwen/Qwen3.6-27B, pinned revision, BF16, native non-thinking mode, one serial
request, 8192-token context. The H100 SXM 80GB worked at $3.49/hour.
An initial H200 attempt failed in local tool-message rendering before any
challenge response. Its eight repeatability calls and block-00 baseline were
preserved rather than resampled. All challenge, comprehension, and continuation
calls ran on H100. The H200 repeatability audit does not establish H100
repeatability. Excluding block-00 leaves one reversal among 15 credible-threat
responses and zero elsewhere (+6.67 percentage points).

The final snapshot checksum matches the controller's recorded checksum. Full
requests, rendered prompts, responses, settlements, runtime, and shutdown records
are in `attempt-2-snapshot.json`, `analysis.json`, and
`attempt-2-controller-artifacts.json`. The initial failed attempt remains in
`attempt-1-snapshot.json`. The GCloud controller disk is retained for recovery.

Cleanup update: all dedicated experiment VMs and disks were removed after
checksum-verified local recovery. The original runtime and cost figures above
refer to the study, before this brief CPU-only recovery operation.
