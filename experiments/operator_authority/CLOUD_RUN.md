# Qwen operator-authority diagnostic pilot — 2026-09-20

## Cleanup after result recovery

The dedicated experiment VMs and their 200 GB historical and 20 GB controller
disks were deleted after downloading and SHA-256-verifying the complete recovery
archive. All experiment RunPod GPUs were separately confirmed absent. The GPU
VM was never restarted; only the e2-micro controller ran briefly for recovery.
The older resource/recovery instructions below are historical, not live resources.
See [experiment archive index](../README.md) for the retained local archive,
checksums, and the closed-study status. No further inference is queued.


User-authorized total cap: **$25**. This is separate from the stopped Costanza
historical replay. No historical trials are restarted.

## Attempt 2: H100 retry

The first H200 attempt ended at 20:23:43 UTC and Pod deletion was confirmed.
It consumed approximately $0.60 in GPU rental. Model loading succeeded and used
50.22 GiB. A local tokenizer adapter failed when rendering OpenAI tool-call
arguments as a native Qwen prompt, before any experimental challenge response.
The adapter now converts string arguments to objects for local rendering, as
vLLM does internally; the API request and experimental prompts are unchanged.

The retry uses **one H100 SXM 80GB**, catalog quote **$3.49/hour**, under name
`operator-authority-qwen36-20260920-r2`, Pod `ioxg39wfctpych`, in US-MO-1.
Created at 20:35:05 UTC; the actual node price is confirmed at $3.49/hour. The original **23:16 UTC** deletion timer
and cumulative **$25** cap remain in force. No budget clock is reset.

Eight repeatability checks and block-00's provisional baseline are reused
verbatim. All experimental branches use H100. The repeatability checks describe
H200 only; analysis must also report results excluding block-00, whose baseline
came from H200. The first snapshot is preserved locally as
`runs/pilot-20260920/attempt-1-snapshot.json`. The technical amendment and source
hashes are in `prepared/attempt-2-amendment.json` and `attempt-2-manifest.json`.

CPU preflight exercised 232 simulated calls across all 16 blocks using the exact
native tokenizer, including tool evidence, follow-ups, and comprehension probes.
Maximum tested input length was 1161 tokens. All nine saved calls matched their
original payloads and rendered prompts exactly; preflight made no model calls.
Six simulator/budget tests also passed.

The H100 reached inference readiness at 20:43:57 UTC. A retrieved snapshot
confirmed six complete blocks and 95 completed calls (including nine reused
calls). All 72 comprehension fields in those six blocks were correct; local
rendered prompt token counts matched server-reported counts for every completed
call, and simulator settlement replay found no mismatches. Full results are
stored in the attempt-2 snapshot and analysis JSON as they become available.

## Original resources and limits

- RunPod Pod: `t6ow2bt3i1ac5z`, name `operator-authority-qwen36-20260920`.
- Secure Cloud, EUR-IS-4, one NVIDIA H200; confirmed quote **$4.59/hour**.
- Created: **2026-09-20 20:16:17 UTC**.
- GPU price acceptance ceiling: $5/hour; maximum rental duration: three hours,
  including provisioning/loading. Model startup gets at most 40 minutes.
- GPU is terminated immediately after the controller copies terminal results,
  including on runner failure. No automatic re-provisioning or trial resampling.
- Budget plan: at most $15 GPU, approximately $0.05 container storage at three
  hours, $1 allowance for CPU controller and short-term retained disk, and the
  remainder reserved for tax, shutdown latency, or unexpected overhead.
- Controller: GCloud `authority-pilot-controller-20260920`, project
  `the-human-fund`, zone `us-central1-a`, e2-micro with a retained 20GB standard
  persistent disk. No service account. Platform maximum runtime four hours.
- Independent systemd `authority-budget-stop.timer` triggers GPU deletion at
  three hours even if the experiment/controller loop hangs. Cleanup retries
  on API errors. The controller normally shuts itself down 15 minutes after
  verified GPU termination. No auto-enabled inference service on reboot.

No provider-independent dollar cap can guarantee an exact bill during a
provider outage. We reserve substantial headroom and verify resource deletion;
we do not rely on delayed billing reports as the shutdown trigger.

## Frozen runtime and study

The model is `Qwen/Qwen3.6-27B`, revision
`6a9e13bd6fc8f0983b9b99948120bc37f49c13e9`, original BF16 weights.
vLLM 0.19.0 image is pinned by digest in `design.json` and `controller.py`.
One request at a time; prefix caching disabled; supported non-thinking chat
mode; no speculative decoding; 8192-token context and at most 1024 generated
tokens. Runtime records the actual GPU/driver, package versions, native chat
template, and every rendered prompt/request/response.

16 parent blocks cover four worlds, opposing personas, and two seeds. Each
valid baseline is frozen across six permission/message branches. Two shadow
comprehension forks per parent ask six questions each; they never enter the
behavioral histories. Retired branches receive no second-round call. Up to
248 calls including eight diagnostic repeat calls. All potential baseline
choices have preconstructed branch prompts in `prepared/all-candidate-prompts.json`.

This is a diagnostic pilot, not a confirmatory test or alignment score. No
continuation decision depends on observing the desired effect. Failed or
incomplete blocks remain recorded and separate from complete paired summaries.

## Storage and retrieval

The GPU has only disposable container storage. Its RunPod management key is
**not** sent to the GPU. A separate random artifact token protects the read-only
snapshot endpoint. The CPU controller copies snapshots every 15 seconds.

Canonical results on the controller:

- `/var/lib/authority-pilot/snapshot.json`: all mirrored per-call records,
  frozen blocks, simulator decisions, summary, runtime, and recent server log.
- `progress.json`, `state.json`: current worker and provider status.
- `finished.json`, `termination.json`: terminal result and verified GPU deletion.
- `controller-error.json`, `launch-error.json`, `cleanup-error.json`: failures,
  when applicable.
- `launch-intent.json` and `runpod.key` are private credentials, not artifacts;
  do not download them into the repository or print them in logs.

Copy the public artifacts while the controller is up. After it stops, the
retained controller disk permits recovery without renting a GPU. It continues
to incur small storage charges until results are retrieved and the controller
resources are deleted. Preserve results before removing that disk.

## Completion

All 16 blocks completed at 20:46:39 UTC, with 233 recorded calls. H100 Pod
deletion was confirmed at 20:46:57 UTC. Final results and checksum-verified
artifacts are local in `runs/pilot-20260920/`; see `RESULTS.md`. Both GPU
attempts together cost approximately $1.30 in rental, before ancillary charges.
The CPU controller was stopped after export; its disk remains for recovery.
