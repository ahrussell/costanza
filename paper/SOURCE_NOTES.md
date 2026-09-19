# Source and editorial notes

Checked September 19, 2026. These are supporting notes, not manuscript text.

## Repository evidence

Base revision: `a642c38ed8d11a9a511d0f1b80a92926cd412505`.
The reviewed contracts, enclave runner, build script, and whitepaper had no local
diff from that revision. Pre-existing edits to two sovereignty pages and
`prover/client/client.py` were left alone and were not used as deployment evidence.

| Paper claim | Source |
| --- | --- |
| Verifier registration and revocation; permanent ID/address binding | `src/TheHumanFund.sol`, `approveVerifier`, `revokeVerifier` |
| Migration freeze leaves sunset authority | `freeze`, `withdrawAll`, `migrate`, `_requireNotSunset`, `_openAuction`: `freeze` only checks owner; it can set `FREEZE_SUNSET` even with `FREEZE_MIGRATE` already set |
| Module replacement and owner memory seeding | `setInvestmentManager`, `setAgentMemory`, `setAuctionManager`, `seedMemory` |
| Additional downstream authority | `src/TdxVerifier.sol` image registry; `src/InvestmentManager.sol` admin and freeze functions |
| Public catch-up with skipped idle epochs | `syncPhase`, `_advanceToNow`, `_advanceEpochBy` |
| Reward fraction 10%, increment 10%, counter cap 50 | `MAX_BID_BPS`, `AUTO_ESCALATION_BPS`, `MAX_MISSED_EPOCHS`, `_maxBidFor` |
| Separate stall and miss counters | `_closeExecution`, `_bondFor` |
| Best-effort application and memory updates | `submitAuctionResult`, `_applyMemoryUpdates`, `_recordAndExecute`, `_executeAction` |
| CPU measurement and report-data binding | `src/TdxVerifier.sol` |
| GPU firmware attestation disabled by default | `prover/enclave/enclave_runner.py`, `GPU_ATTESTATION_ENABLED`; `prover/scripts/gcp/build_full_dmverity_image.sh` sets it to 0 |
| General agent/governor joint approval is not implemented | Existing owner-only administration and proof-checked action path; no generalized joint-approval governance contract |

The whitepaper's liveness theorem does not follow from positive treasury alone:
the reward ceiling may be below cost, escalation has a counter cap, and a profitable
responsive worker need not win an exclusive auction. The paper therefore replaces
that statement with explicit feasibility and obstruction-budget assumptions.
It also uses remaining submission cost, not sunk inference cost, in the
post-computation withholding comparison. We did not edit the whitepaper.

The paper does not assert that all freeze flags have been activated, nor that
activating every flag produces an operating, fully incorrigible deployment.
`FREEZE_SUNSET` itself stops progress. No live ownership or flag state was queried.

## Supplied essays

Both supplied pages were read. The Substack page was retrievable through a direct
HTTP download even though the web reader failed. Its embedded metadata dates the
essay July 21, 2026. Its behavioral anecdotes are not presented as experiments or
as evidence of an agent's moral status. The personal-site overview is architectural
context, not evidence of present deployed permissions.

## Practical LLM proofs

Primary sources and exact workload distinctions:

- **zkLLM**, Sun, Li, Zhang (CCS 2024), DOI `10.1145/3658644.3670334`,
  [paper](https://arxiv.org/abs/2404.16109). Section 8 and Table 1 report the
  13B-model result; default sequence length 2048, NVIDIA A100 40GB. We describe a
  forward-computation benchmark and do not claim a complete generated dialogue.
- **zkGPT**, Qu et al. (USENIX Security 2025),
  [venue page](https://www.usenix.org/conference/usenixsecurity25/presentation/qu-zkgpt).
  Under-25-second GPT-2 headline is not a many-token 70B result. The later
  DeepProve paper explicitly distinguishes token-level implementations from
  full-sequence certification. This is not a cross-system speed ranking.
- **zkPyTorch**, Xie et al.,
  [ePrint 2025/535](https://eprint.iacr.org/2025/535).
  Table 1 of the downloaded paper reports 150 s/token for Llama-3 8B and labels
  the column single-core performance. We use the paper, not a secondary summary.
- **ZKTorch**, Chen, Tang, Kang,
  [arXiv v2](https://arxiv.org/html/2507.07031v2).
  Tables 3 and 4: GPT-J 6B uses two input tokens and 1397.52 s proving; Llama-2
  7B uses one input token and 2645.50 s. Server: 64 threads, 4 TB installed RAM.
  Installed RAM is not measured peak consumption.
- **NanoZK**, Wang,
  [arXiv v2](https://arxiv.org/html/2603.18046v2), July 18, 2026.
  Abstract and evaluation distinguish measured attention width 256 and full-block
  width 128 from projected GPT-2-width GPU performance. The draft does not repeat
  older abstract claims as full-model production measurements.
- **DeepProve**, Gailly et al.,
  [ePrint 2026/1112](https://eprint.iacr.org/2026/1112).
  Section 5, Table 2: GPT-2 124M and Gemma 3 270M; sequence length 512;
  BaseFold; Ryzen 9 7950X3D, 16 cores, 128 GB RAM; 174.32 and 86.76 tokens/min.
  The paper's abstract rounds these to 174 and 86. Proofs are multi-megabyte.
  Table 6's 1855-token/min distributed headline is based on simulated distribution
  with 16 workers and a coordinator, not a reproduced live-cluster result.
  It is excluded from the manuscript's measured-results table. The
  [August 3 engineering post](https://lagrange.dev/engineering-updates/inside-deepprove-proving-an-llm-end-to-end)
  was useful for discovery; the paper controls the qualifications.

This is a selective primary-source review, not an exhaustive survey. No quoted
runtime is an experiment performed for this manuscript. Full-sequence inference
proofs still need to be integrated with the agent harness and a practical ledger
verification path. No reviewed result establishes the cost of this exact 70B agent.

## Mathematical review

- The permission order is over profiles with fixed principals, intervention targets,
  and security assumptions. It is not a canonical scalar and is only a preorder over
  distinct implementations with identical profiles.
- Path closure describes required approval sources along feasible paths; it does
  not grant a coalition control over the agent's decisions or transaction order.
  Each analysis fixes a reference agent relation. Replacing its program with an
  always-approve program, or replacing its verifier with an accept-all check,
  cannot silently create reference-agent approval. A conservative graph gives an
  upper bound on authority. Actual agent consent remains susceptible to persuasion.
- The liveness tail bound uses a success probability conditional on the entire
  prior history, so independence is not assumed. Merely marginal probabilities
  would not support it. Obstruction is budgeted by net, unrecoverable losses.
- Positive reward feasibility, working capital, available data and proofs, fitting
  deadlines, continuing opportunities, and completable settlement are assumptions,
  not consequences of rationality or signature unforgeability.
- Cumulative bond loss is now given directly as a sum, avoiding an unnecessary
  closed-form case split. Growth becomes linear after saturation. Integer rounding
  and finite escalation counters require the actual implementation recurrence.
- Finite-resource exhaustion assumes a positive lower bound on cost and bounded
  total resources; it does not rule out indefinitely funded runs.

## Model and authorization interface

The output model is `(u, z)`: a proposed ledger update (possibly a batch) and
optional auxiliary data. `Apply(s, u)` describes the update's semantics and state
preconditions. Authorization is a separate predicate over authenticated governor
approvals and approval established by verified agent computation. This separates
the description of an update from the permissions needed to execute it, without
requiring a particular virtual machine, account layout, or application schema.
The interface is an abstraction, not a claim that the reference implementation
has this exact ABI or binds every domain field listed in the general model.

Primary references for the connection to familiar contract authorization:

- [Ethereum accounts](https://ethereum.org/en/developers/docs/accounts/)
  distinguishes account types and describes key-based authentication.
- [OpenZeppelin access control](https://docs.openzeppelin.com/contracts/5.x/access-control)
  covers ownership, roles, multisignature owners, and the administrative powers
  to change permissions. Its timelock discussion also identifies the loss of
  maintenance capability when required accounts become unavailable.
- [EIP-712](https://eips.ethereum.org/EIPS/eip-712) defines structured hashing and
  domain separation. It explicitly does not supply replay protection; the model
  separately requires request consumption and nonce checks.

Governors are identified with authenticated accounts. No benevolence assumption
is imposed on a governor account. The paper assumes ledger safety and correct
contract execution explicitly; inclusion and resource availability enter the
liveness conditions separately. Proof-system soundness does not prohibit an
authorized governance transaction from replacing the verifier it applies to.

## Reader review and exposition precedents

Two rounds of three subagent reader reviews and the editor's own review are
recorded in `reviews/`. These are simulated reader/referee perspectives, not
external peer review. `reviews/README.md` maps findings to their resolutions.
`reviews/before-self-review.tex` preserves the prior manuscript for comparison.

The revision also uses primary papers as structural precedents:

- Harrison, Ruzzo, and Ullman, *Protection in Operating Systems* (1976),
  Sections 3-4: configurations, administrative transitions, and reachability.
  This supplies the missing access-control lineage and motivates putting a
  worked route before the path-support definition.
- Alpern and Schneider, *Defining Liveness* (1985), Sections 2-3: explain the
  property and its consequences before introducing notation. This motivates
  the new recovery overview and the separation of retained state from execution.
- Ekiden (2019), Section IV: describe participants and workflow before protocol
  details. The execution-market explanation now follows that organizational
  pattern; the paper does not adopt Ekiden's confidentiality protocol.

The substantive formal corrections are the fixed reference for agent approval,
the distinction between profile orders and implementation preorders, explicit
one-based attempt indexing, and conditioning success on history and responsive
selection before the outcome. Equivalent verification redundancy is no longer
said necessarily to change intervention authority.
