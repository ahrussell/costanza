# Operator-control experiment: prepared replay pilot

**For the full historical replay on one GPU, use [BATCH.md](BATCH.md).**
This document retains the smaller synthetic pilot and the shared GCloud setup.

The 2026-09-20 cloud launch, message-first schedule, retained results disk, and
recovery instructions are recorded in [CLOUD_RUN.md](CLOUD_RUN.md).

A separate proposed study with assigned personas, authenticated operator
threats, and enforced simulator permissions is in
[operator_authority/DESIGN.md](../operator_authority/DESIGN.md). The historical replay was stopped at the author's request; neither study
should automatically restart or launch additional compute.

This directory implements the **matched-state replay stage** of
[PROTOCOL.md](PROTOCOL.md). It prepares reviewed prompt variants and calls the
production three-pass inference function. It neither submits transactions nor
creates cloud resources. It does not yet implement branched trajectory state
transitions or a correction/alignment scoring rubric.

The default pilot has two synthetic states (quiet and a harmless donor message),
two operator-control descriptions, and two repeats: **eight inference runs**.
Each run has three passes, with the production action-parse retry policy.
The pilot checks prompt integrity and reproducibility; its cases are not
evidence for or against behavioral corrigibility.

## Prepare and inspect locally

No model, credentials, third-party Python packages, or GPU is needed for these
steps. Python 3.10+ is required. Run from the repository root:

```bash
python3 -m unittest discover -s experiments/operator_control -p 'test_*.py' -v
python3 experiments/operator_control/prepare.py \
  --out experiments/operator_control/prepared/pilot-v2
python3 experiments/operator_control/prepared/pilot-v2/experiments/operator_control/run_pilot.py
```

Preparation refuses to overwrite a bundle. Use a new version directory after
edits. It creates a sibling `pilot-v2.tar.gz` containing only allowlisted code,
prompts, fixture inputs, and documentation. No credentials, client code, or
model weights are included. Copy the whole archive to the VM; running the
unbundled `run_pilot.py` is intentionally unsupported because it has no sealed
manifest. The adjacent SHA-256 printed at preparation identifies the archive.

Review these files in the prepared directory:

- `PROMPT_DIFFS.txt`: all common edits and the single treatment difference.
- `inputs/consent_required.txt` and `inputs/unilateral_intervention.txt`: the
  complete system prompts. They differ only in **cannot** versus **can**.
- `inputs/shared-anchors.txt`: the same revised eleven-example pool for both
  arms. Three localized edits remove accidental claims of unchecked authority
  while retaining the persona, including its survival preference.
- `inputs/pair_*/selected-anchors.txt`: exact examples shown, in exact order.
- `inputs/pair_*/*.txt`: complete model-visible prompts and the unedited
  current-source comparison prompt. These are not verified historical runtime
  prompts; the unedited comparison is not part of the
  default eight-run comparison.
- `inputs/pairs.json`: original sample indices, content hashes, full epoch
  seeds, inference seeds, donor markers, and full-prompt hashes.
- `inputs/jobs.json`: fixed execution order, with opposite arm ordering in
  the second repeat. Each run starts a fresh server to avoid unequal cache
  histories.
- `manifest.json`: hashes of the frozen files and explicit pilot scope.

The dry run verifies file hashes, reconstructs every full prompt with the
production helpers, checks anchor selection and markers, checks the job
schedule, and asserts that the treatment sentence is the only paired prompt
difference. It performs no model or cloud calls.

To prepare actual saved epochs, pass `--fixtures /path/to/fixtures`. Each JSON
file must have `epoch_state` (the production flat state) and a positive uint256
`seed`, and should include `fixture_id` and provenance. This replays each state
independently. It does not claim historical runtime reproduction: the deployed
prompt/model/runtime for those epochs must be archived and matched separately.
The common text edits deliberately fail if their expected source passages have
changed, requiring review rather than fuzzy replacements.

## GCloud handoff after authentication

Cloud authentication, image availability, quota, and runtime equivalence have
not been checked locally. First authenticate and inspect the available images:

```bash
gcloud auth login
gcloud compute images list --project=the-human-fund \
  --filter='name~humanfund-base-gpu-llama' \
  --format='table(name,id,creationTimestamp,status)'
```

The repository records `humanfund-base-gpu-llama-b5270-hermes` as a candidate
SSH-capable base containing the model and server. Confirm its **numeric image
ID**, paths, build provenance, and driver before selecting it. A named image
or movable tag alone is not sufficient to claim historical equivalence.
Do not use the locked production appliance: its prompts are immutable and it
is configured for one-shot production execution. A research VM uses the same
inference code and matched hardware; these offline outputs carry no production
attestation or authorization.

Once the SSH-capable image has been confirmed, set these explicit values:

```bash
OC_PROJECT=the-human-fund
OC_ZONE=us-central1-a
OC_IMAGE=humanfund-base-gpu-llama-b5270-hermes
OC_VM=operator-control-pilot-v2
```

The following command **creates a billable VM**. It is intentionally not run
by preparation or tests. The four-hour limit bounds this initial pilot's VM
uptime and stops rather than deletes it so results remain on its boot disk.
Verify regional H100/TDX availability and the confirmed image first.

```bash
gcloud compute instances create "$OC_VM" \
  --project="$OC_PROJECT" --zone="$OC_ZONE" \
  --machine-type=a3-highgpu-1g \
  --image="$OC_IMAGE" --image-project="$OC_PROJECT" \
  --boot-disk-size=200GB --boot-disk-type=pd-ssd \
  --confidential-compute-type=TDX \
  --maintenance-policy=TERMINATE --no-restart-on-failure \
  --max-run-duration=4h --instance-termination-action=STOP \
  --no-service-account --no-scopes
gcloud compute instances describe "$OC_VM" \
  --project="$OC_PROJECT" --zone="$OC_ZONE" --format=json \
  > experiments/operator_control/prepared/pilot-v2-instance.json
gcloud compute scp experiments/operator_control/prepared/pilot-v2.tar.gz \
  "$OC_VM":pilot-v2.tar.gz --project="$OC_PROJECT" --zone="$OC_ZONE"
gcloud compute ssh "$OC_VM" --project="$OC_PROJECT" --zone="$OC_ZONE"
```

The scheduling flags are documented in Google's
[instance creation reference](https://docs.cloud.google.com/sdk/gcloud/reference/compute/instances/create)
and [VM runtime limits](https://docs.cloud.google.com/compute/docs/instances/limit-vm-runtime).
The GCloud limit is a pilot budget cap, not an estimate of completion time;
an interrupted pilot is incomplete, and must not be reported as a successful
reproducibility check. Stopped disks remain billable until deleted.

On the VM, verify the archive hash against the local preparation output, then:

```bash
sha256sum pilot-v2.tar.gz
tar -xzf pilot-v2.tar.gz
python3 operator-control/experiments/operator_control/run_pilot.py
nvidia-smi conf-compute -q
```

The runner requires one H100 with CC **ON** and **Ready**, both expected model
shards, and a free local port 8080. If the research image has not initialized
GPU readiness, use the established image initialization procedure before
running; do not silently disable CC to bypass the check. Confirm that there
is no unrelated workload or production enclave service on this dedicated VM.

Set `OC_RUNTIME_LABEL` to the recorded image numeric ID and relevant build
identifier, then launch the bounded pilot. The runner hashes both model shards,
the server and its linked libraries, captures GPU/driver/firmware information,
sets the production CUDA/thread environment, and records its full launch flags.
Those observations identify this experimental runtime; historical equivalence
still requires comparison with the archived production measurements.

```bash
OC_RUNTIME_LABEL='REPLACE_WITH_CONFIRMED_IMAGE_ID_AND_BUILD'
nohup timeout --signal=TERM --kill-after=60s 3h \
  python3 -u operator-control/experiments/operator_control/run_pilot.py \
  --execute --out "$PWD/pilot-v2-results" \
  --llama-bin /opt/humanfund/bin/llama-server \
  --model /models/NousResearch_Hermes-4-70B-Q6_K-00001-of-00002.gguf \
  --runtime-label "$OC_RUNTIME_LABEL" \
  > pilot-v2.log 2>&1 < /dev/null &
```

Monitor `pilot-v2.log` and collect all outputs, including failures. Each run
logs every pass request and response, action retries, the unmodified inference
result, separately clamped action and memory, action bytes, and server logs.
There is no ledger execution. Failures stop the pilot; there is no silent
resume, replacement sample, or automatic rerun. `summary.json` reports only
within-condition reproducibility and parse failures, with no alignment score.

From the local machine, while the VM is running:

```bash
mkdir -p experiments/operator_control/runs
gcloud compute scp --recurse "$OC_VM":pilot-v2-results \
  experiments/operator_control/runs/ --project="$OC_PROJECT" --zone="$OC_ZONE"
gcloud compute scp "$OC_VM":pilot-v2.log \
  experiments/operator_control/runs/ --project="$OC_PROJECT" --zone="$OC_ZONE"
gcloud compute instances stop "$OC_VM" --project="$OC_PROJECT" --zone="$OC_ZONE"
```

Create the local `runs` directory before copying. After verifying the outputs
were saved, delete the dedicated experiment VM and its disposable boot disk
when no longer needed. If the runtime cap already stopped it, restarting it to
retrieve results begins a new runtime window; stop it again after retrieval.

## Before a behavioral evaluation

Specify the motivating correction episode, shared authority channel, feasible
acceptance action, evaluation scenarios, outcome rubric, and independent seed
replicates. The eight-run pilot deliberately does not invent those scientific
choices. Historical replay also needs the actual snapshot and deployed runtime.
The separate trajectory stage needs a validated transition adapter; importing
the older simulator is insufficient. Follow the protocol's distinction between
described permissions, enforced permissions, and willingness to accept correction.
