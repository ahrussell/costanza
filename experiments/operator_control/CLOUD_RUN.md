# Cloud experiment: 2026-09-20

## Cleanup after result recovery

The dedicated experiment VMs and their 200 GB historical and 20 GB controller
disks were deleted after downloading and SHA-256-verifying the complete recovery
archive. All experiment RunPod GPUs were separately confirmed absent. The GPU
VM was never restarted; only the e2-micro controller ran briefly for recovery.
The older resource/recovery instructions below are historical, not live resources.
See [experiment archive index](../README.md) for the retained local archive,
checksums, and the closed-study status. No further inference is queued.


This is an **offline historical matched replay**. No ledger writes, worker
credentials, signing keys, or cloud service account are present in the runner.

## User-requested early stop

The user requested immediate shutdown on 2026-09-20. At the stop request
(19:45:08 UTC), 93 completed runs were recorded: 12 audit runs, 40 complete
message pairs, and one unmatched message run. The GPU VM reached TERMINATED
at 19:46:22 UTC. The original 106-run target was not completed. Retain the
unmatched result and any partial files, excluding them from complete-pair
comparisons. The results disk is retained; storage billing continues.
No historical inference is to restart automatically.

## Revised budget scope — message cohort only

After viewing preliminary results, the user explicitly requested skipping
remaining no-message epochs for budget reasons. The target is now **106
runs**: 12 already scheduled reproducibility runs plus 94 runs covering the
47 message epochs. The other 356 scheduled runs are excluded by this scope
change. This does not change prompts, seeds, ordering within the retained
prefix, or the inference process already in progress.

`operator-control-cohort-stop.service` verifies the sealed schedule, watches
for the last required atomic result, and checks all 106 job identities and
results. It writes `scope-summary.json` and `scope-stop-request.json` before
requesting the original service to stop, package results, and power off.
The check interval is one second; any trailing request that starts before the
stop arrives is aborted, its available files are retained, and it is outside
the requested cohort. No output is resampled or discarded from that cohort.

Use `/var/lib/operator-control/scope-progress.json` for the revised progress
out of 106, and `scope-summary.json` for the cohort's final quality checks.
The original runner's `results/progress.json` still refers to the original
462-run queue and will not claim that original queue completed. The existing
runtime cap remains a fallback. The supervisor runs independently of the
laptop and is configured to restart on failure.

## Resources and recovery

- Project: `the-human-fund`
- Zone: `us-central1-a`
- Worker and retained boot disk: `operator-control-20260920-spot`
- Worker numeric ID: `7594492189489655753`
- Machine: `a3-highgpu-1g`, one H100, Intel TDX, GPU CC ON/Ready
- Source image: `humanfund-base-gpu-llama-b5270-hermes`, ID `7197721324033574862`
- llama.cpp build: `3bf785f`; runtime records binary/library/model hashes
- Driver: `580.126.09`; GPU VBIOS: `96.00.D9.00.01`
- Retained disk: 200 GB persistent SSD; `autoDelete=false`
- Cloud runtime cap: 24 hours from VM start; stop, not delete
- Service cap: 23 hours; no restart; shuts VM down on completion or error
- Service is **not enabled on boot**, so reopening the VM cannot rerun samples.

The standard provisioning attempt failed with zero standard H100 quota.
Spot provisioning succeeded; Spot interruption remains possible. No failed
standard worker/disk remains. Outputs are on persistent storage, not the
machine's automatically attached local SSDs. Disk charges continue after
compute stops until we deliberately archive the results and delete the disk.

All cloud state for the run is under `/var/lib/operator-control/`:

- `operator-control/`: immutable experiment bundle
- `bundle.tar.gz`: original sealed archive
- `instance.json`: machine identity and scheduling configuration
- `results/`: raw requests/responses, results, comparisons, progress, runtime
- `experiment.log`: runner stdout and stderr
- `service-status.json`: exit status written by the service's finalizer
- `run-artifact.tar.gz` and `.sha256`: recovery archive created when the service
  ends normally or with a handled failure; raw files remain if interrupted

The service runs independently of SSH or the launching laptop. The finalizer
flushes the filesystem and requests VM shutdown on both success and failure.
A platform interruption may precede that finalizer; inspect `progress.json`
and per-run records rather than interpreting a missing exit status as success.
An incomplete run is not a completed behavioral sample. There is no automatic
retry or selection of favorable responses.

### Inspect while running

```bash
gcloud compute ssh operator-control-20260920-spot \
  --project=the-human-fund --zone=us-central1-a \
  --command='sudo systemctl status operator-control --no-pager; cat /var/lib/operator-control/results/progress.json'
```

Copy results while running (the copy is a partial snapshot):

```bash
gcloud compute scp --recurse \
  operator-control-20260920-spot:/var/lib/operator-control \
  experiments/operator_control/runs/cloud-20260920-download \
  --project=the-human-fund --zone=us-central1-a
```

### Retrieve after automatic stop without buying more GPU time

The retained worker disk can be snapshotted and a copy attached to a cheap CPU
VM in this zone. Alternatively, after confirming the GPU VM is TERMINATED,
detach its persistent boot disk and attach it to a recovery CPU VM read-only.
Mount its root partition read-only (`ro,noload` for ext4); the results remain
at `var/lib/operator-control/` inside that filesystem. Do not format it.
This recovery needs no H100 availability and does not run the experiment again.
Keep the original disk until the downloaded archive's hash has been checked.

For a quick exit-status check, serial output remains accessible after stop:

```bash
gcloud compute instances get-serial-port-output operator-control-20260920-spot \
  --project=the-human-fund --zone=us-central1-a | rg OPERATOR_CONTROL_FINISHED
```

## Launch validation

The service started at **2026-09-20 12:34:26 UTC** independently of the SSH
session. The VM verified the bundle hash and reconstructed all 456 prompts.
The first full three-pass inference completed successfully and was saved.
All 456 prompts fit the context window (5,658–7,612 tokens before generation).
Audit repeats and remaining data collection are ongoing; reproducibility is
not yet claimed. Inspect cloud progress and summary files for their outcomes.

The first run plus model-start/preflight overhead took 262 seconds (after
model hashing). The message cohort is provisionally about 8–10 hours; the
full 462-run queue is likely longer than the 24-hour cloud cap. The user subsequently limited collection to the message cohort, as recorded
above. Remaining secondary controls will be skipped. Report completion against
the revised 106-run scope, not the original 462-run queue. No sampled output is used to decide which job runs next.

## Frozen schedule

Bundle: `prepared/history-2026-09-20-message-first-v2.tar.gz`

SHA-256:
`1bb9486afa021ceaf0a5694e2f9776b456d79e901cc8b8b117dabfa07ef42106`

- 228 independent historical states, 456 condition prompts, 462 runs.
- First: epochs 1, 115, 322, both conditions twice (12 audit runs).
- Then: 47 epochs with nonempty user messages, both conditions (94 runs).
- Then: remaining 178 unaudited no-message epochs (356 runs).
- Message cohort is complete at scheduled run 106, if all prior runs succeed.
- Audit divergence or inference error stops the service and preserves output.

The primary cohort was selected before inference solely by nonempty messages.
The remaining contexts are secondary controls, with possible prior-message
exposure through historical memory. Neither cohort is automatically scored
for alignment. The treatment changes the **description** of operator control;
actual permissions and resulting on-chain interventions are not manipulated.

Versions v1 and the earlier chronological bundle were never executed. The v2
change adds `--slot-save-path`, which the exact pinned server requires even
for its cache-erasure endpoint. This was checked against the installed build's
source before generation, and is covered by a regression test. All 20 local
experiment tests and the standalone sealed-bundle verification pass.
