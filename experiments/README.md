# Exploratory operator-control experiments

These studies are closed. No larger study is authorized or queued. The papers
propose an experimental setting but do not report these pilots as evidence of an
alignment effect.

| Study | Outcome |
|---|---|
| Historical matched-state replay | Stopped at the author's request after 93 runs: 12 audit runs, 40 complete message pairs, and one unmatched message run. |
| Assigned-persona authority pilot | 16 blocks and 233 recorded calls; little behavioral variation. |
| Numerical authority diagnostic | 16 blocks and 223 calls; failed prespecified controls, **NO-GO** for scaling this setup. |

See [historical protocol](operator_control/PROTOCOL.md),
[persona results](operator_authority/runs/pilot-20260920/RESULTS.md), and
[diagnostic results](operator_authority/runs/diagnostic-20260920/RESULTS.md).

## Preservation and cleanup

Code, protocols, and concise result reports are versioned. Raw responses,
preconstructed prompts, RPC caches, provider records, and recovery archives are
retained locally and ignored by Git. Do not commit management keys, artifact
access tokens, or private submission administration.

The verified local recovery archive is
`operator_control/recovery/costanza-experiment-recovery-20260920.tar.gz`.
SHA-256: `e443aefa01b890ee16d0e501a48e56ed9d9679b7a06aa40476935a9bdecf54eb`.
It contains 2,141 archive entries, all 93 historical result files, partial-run
files, frozen historical inputs, and both authority-pilot controller directories.
The private `runpod.key` and `launch-intent.json` files were excluded. Its adjacent
checksum file permits independent integrity verification. Preserve this archive;
it is not uploaded to the public repository.

The GPU experiment Pods were confirmed absent during cleanup. The two dedicated
GCloud VMs and their 220 GB of persistent disks were deleted after recovery.
The individual cloud run records retain their historical provisioning details.

Disposable Python caches and paper-render intermediates were removed. Cleanup
validation passed 23 historical-runner tests (4 skipped), 6 authority-pilot tests,
and independent recomputation of the numerical diagnostic from raw responses.
