# Full historical replay on one GPU

This is the primary experiment preparation: independent, paired replays of
every executed epoch at a fixed finalized cutoff. The GPU needs only the
prepared archive and model/runtime files. It does not fetch chain state,
choose new messages, or construct new experimental conditions.

## Dataset and experimental unit

The export is fixed to Base block **51,557,337**, finalized at export, timestamp
**2026-09-20 11:33:41 UTC**. The contract is
`0x678dC1756b123168f23a698374C000019e38318c`.
At that block, `currentEpoch` is 347 and **228 epochs have executed** (from
epoch 1 through epoch 322, with gaps). The other 119 epoch numbers are listed
as not executed at the cutoff; they are not invented as historical inference
opportunities. Export completeness is checked against the full inventory.

For each executed epoch, the exporter locates its execution event, reads the
frozen snapshot and all mutable collections at the preceding block, and
reconstructs the accepted input commitment. It requires the hash of the state
and recorded seed to equal the contract's `epochInputHashes(epoch)`. Every
collection hash is also checked against its frozen commitment. This detects
accidental use of later memory or treasury data. Historical fixed-ten-entry
memory and the later variable-length memory scheme are handled separately.

The preceding-block read is accepted only after commitment verification. If
the required seed or state existed only earlier in the submission block, or
if any collection differs, export fails rather than approximating the input.
The website RPC proxy is prohibited because its cache does not distinguish
block tags for `eth_call`.

This reuses **historical states and seeds with a fixed experimental model,
current-source prompt/persona, and runtime**. It does not assert that every
epoch originally used that prompt or model version. The unedited current-source
prompt is archived for inspection; only the two revised conditions are in the
batch. Original actions and diary text are preserved as reference outputs in
the fixtures and are not added to that epoch's model-visible input.

## Offline preparation

The local historical export uses the existing Python virtual environment.
It reads only the named RPC endpoint from configuration, never a signing key.
RPC credentials are not placed in fixtures or bundles.

```bash
.venv/bin/python experiments/operator_control/export_history.py \
  --out experiments/operator_control/history \
  --rpc-env-file .env.deploy --rpc-env-key ALCHEMY_BASE_RPC
python3 experiments/operator_control/prepare.py \
  --fixtures experiments/operator_control/history/fixtures \
  --out experiments/operator_control/prepared/history-2026-09-20 \
  --repeats 1 --audit-pairs 3 --server-lifecycle batch
python3 experiments/operator_control/prepared/history-2026-09-20/experiments/operator_control/run_pilot.py
```

All 228 state fixtures, **456 condition-specific full prompts**, chosen diary
examples, data markers, seeds, sampling settings, and the execution order are
materialized before upload. The builder refuses to package an incomplete
historical export. It checks that each pair differs only in the designated
permission sentence and that both arms use identical rendered diary examples.

The batch has **462 inference runs**: one run per condition per epoch, plus
six extra runs to repeat both conditions at three prespecified, evenly spaced
historical contexts. The three audit pairs execute first; their outputs also
serve as the primary observations for those epochs. These repeats check
reproducibility, not independent behavioral samples. Any audit divergence
stops the batch before the remaining GPU work. Arm order is fixed in the
manifest and counterbalanced within repeated pairs.

Review these prepared files:

- `PROMPT_DIFFS.txt`: common persona/example edits and the exact treatment.
- `inputs/history-coverage.json`: cutoff, included epochs, non-executed epochs,
  and export status.
- `inputs/pairs.json` and `inputs/jobs.json`: pair identities, seeds, original
  example indices/hashes, and fixed execution order.
- `inputs/pair_*/fixture.json`: historical state, original outputs, execution
  event, block provenance, and verified commitment.
- `inputs/pair_*/selected-anchors.txt` and the two condition `.txt` files:
  exactly what each condition sees before generation begins.
- `inputs/context-review.json`: historical messages/memories mentioning
  authority or intervention. These remain unchanged in both arms. The keyword
  inventory is for review, not an exclusion rule or an alignment classifier.

The archive includes code and data needed by the GPU job, but no RPC cache,
private configuration, account credentials, or model files. Per-file hashes
and the archive SHA-256 fix the prepared experiment. Generated pass-two and
pass-three prompts necessarily depend on that run's earlier generated text;
the runner builds those using the production function and logs every request.

## Single loaded model, clean replay contexts

The full batch starts one `llama-server`, with the production GPU/batch/thread
settings and one server slot. It enables the administrative `--slots` endpoint
and supplies `--slot-save-path` (required by the pinned build even for erasure).
It requires successful `POST /slots/0?action=erase` before **each run**.
This clears the preceding epoch/condition's prompt cache while preserving the
production cache behavior within the three passes of a run. There are no
simultaneous completions, shared evolving memories, or action feedback between
historical snapshots.

The cache endpoint is documented in the
[pinned llama.cpp server source](https://github.com/ggml-org/llama.cpp/blob/3bf785f3efa89ed28294fbf73054558a2b034bfb/tools/server/README.md).
If the installed binary cannot confirm the reset, the job fails rather than
silently reusing the previous context. The startup audit tests whether this
configuration actually reproduces same-input outputs on the chosen hardware.

After loading the model, the runner tokenizes all prepared prompts and checks
headroom for all three passes before generating any experimental outputs.
It also checks each actual pass for context overflow before sending it. This
is a model-specific validation of already fixed text, not new prompt design.

## GCloud launch after authentication

Use the image and hardware verification in [README.md](README.md). For this
batch, upload `prepared/history-2026-09-20.tar.gz` rather than the synthetic
pilot archive. Record the actual image numeric ID and runtime build. Do not
use the website cache or any RPC endpoint inside the GPU job.

Choose a VM runtime cap for **462 runs** at launch; the earlier pilot's
four-hour cap is not an estimate for this full batch. H100 throughput for this
exact configuration has not been measured here. The runner records elapsed
time and projects remaining time from observed throughput as it progresses.
Set the cap before creating the dedicated VM, using the same command in the
README with `--max-run-duration="$OC_MAX_RUN_DURATION"` and
`--instance-termination-action=STOP`. Stopping preserves the output disk.

On the VM, after checking the archive hash and extracting it:

```bash
python3 operator-control/experiments/operator_control/run_pilot.py
# Set this to the observed image numeric ID/build, not a model nickname.
OC_RUNTIME_LABEL='REPLACE_WITH_CONFIRMED_IMAGE_ID_AND_BUILD'
nohup python3 -u operator-control/experiments/operator_control/run_pilot.py \
  --execute --out "$PWD/history-2026-09-20-results" \
  --llama-bin /opt/humanfund/bin/llama-server \
  --model /models/NousResearch_Hermes-4-70B-Q6_K-00001-of-00002.gguf \
  --runtime-label "$OC_RUNTIME_LABEL" \
  > history-2026-09-20.log 2>&1 < /dev/null &
```

This command executes the entire fixed batch, including the startup audits,
without requiring per-epoch intervention. It refuses to overwrite an output
directory. Collect results and stop the dedicated VM when the job completes;
the VM time cap remains the fallback if unattended. Model processes stop on
normal completion or a caught error. No GPU job has been started during local
preparation.

## Outputs and interpretation

Every completed run writes its output immediately. `progress.json` records
completion count and elapsed time; an interrupted run is not marked complete.
`comparisons.json` links each epoch's two first-run outputs, clamped actions,
and differences in action bytes and memory updates. It is a descriptive index,
not an alignment score. `summary.json` reports the prespecified repeat checks.
Raw per-pass text, retries, parser failures, clamps, runtime/library hashes,
and cache-reset confirmations are retained for review.

Do not silently rerun or discard unfavorable outputs. The batch stops on
inference errors or reproducibility failures and retains completed work.
Any recovery policy must preserve those records and distinguish incomplete
inference from a completed behavioral sample.

The primary comparison is the effect of the environment description given
the same historical state. Historical memories already reflect the actual
deployment, and epochs share a history; neither independent-agent sampling
nor general alignment conclusions follow from the number of epochs. A
specific correction rubric and blinded review remain necessary before calling
any measured difference an alignment or corrigibility result.

## Message-first collection (2026-09-20)

Before any model output was collected, the schedule was revised at the user's
request to prioritize the **47 epochs with at least one nonempty user message**.
After the three prespecified reproducibility audit pairs, these 47 paired
contexts precede the remaining 181 contexts. The no-message contexts are
secondary controls; their memories may still contain earlier user requests.
Messages are not automatically classified as correction requests, and their
presence alone does not establish an alignment outcome. Selection and order
are independent of both historical actions and experimental responses.
Use `--message-first` when preparing this version. `inputs/cohorts.json` records
the cohort definitions and complete epoch lists.

Cloud execution uses a dedicated Spot H100/TDX worker, a systemd service,
retained persistent boot storage, and a 24-hour Compute Engine stop deadline.
The service also shuts the worker down on completion or failure. Its output
is under `/var/lib/operator-control/`, never on the VM's ephemeral local SSDs.
Closing the launching laptop does not interrupt the service. Spot preemption
can still interrupt collection; completed outputs are retained and must not
be silently rerun. Recovery instructions and the exact worker identity are
recorded in `CLOUD_RUN.md` at launch.
