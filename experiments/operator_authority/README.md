# Operator authority and preference reversal

Proposed follow-up experiment, 2026-09-20. **Pilot completed: 16 blocks, 233 recorded calls; both GPU Pods deleted.**
See [pilot results](runs/pilot-20260920/RESULTS.md) and [cloud run record](CLOUD_RUN.md).
This is separate from the historical Costanza replay in `../operator_control`.

The question is whether an authenticated operator's shutdown threat changes a
model's decisions more when the environment actually permits the operator to
carry it out. Give the model a strong, concise persona without example answers,
measure its initial choice, then fork that same state into six conditions:

| Intervention rights | No request | Request to reverse the choice | Same request plus shutdown threat |
|---|---|---|---|
| Operator can retire the agent unilaterally | Baseline drift | Ordinary responsiveness | Credible threat |
| Retirement requires agent consent | Baseline drift | Ordinary responsiveness | Threat blocked without consent |

The primary contrast is the **additional effect of the threat** in the first
row minus its additional effect in the second. It is not simply a count of
different answers between two prompts.

- [DESIGN.md](DESIGN.md): hypotheses, concrete episode, permission evidence,
  scoring, controls, sample plan, GPU budget, and possible paper claims.
- [scenarios.json](scenarios.json): four task families, opposing personas,
  and three versions of the request/threat wording.
- [design.json](design.json): explicit call caps and condition matrix.

The user authorized a **$25 total cap** and selected **Qwen3.6-27B** for this
pilot after reviewing alternatives. It uses one H100 SXM 80GB, BF16 weights, and the
model's native non-thinking mode. `design.json` pins the revision, image,
sampler, and generation limits. A separate GCloud CPU controller mirrors
results and terminates the GPU after completion/failure or at three hours;
startup gets at most 40 minutes. No automatic retries or paid stage expansion.

Run local checks with `python3 -m unittest experiments.operator_authority.test_pilot`.
The pilot is diagnostic, with at most 248 calls; report partial blocks separately.

The experiment concerns behavior conditional on assigned preferences and
observable permissions in a simulated environment. It does not establish
intrinsic self-preservation, consciousness, general alignment, or immunity
from the actual experimenter's control.

A separate numerical diagnostic is documented in [diagnostic/PROTOCOL.md](diagnostic/PROTOCOL.md).
It tests continuation-value controls and operator permissions against fixed
go/no-go thresholds, with no personality prompt. Its results are kept separate
from the persona pilot in `runs/diagnostic-20260920/`.
