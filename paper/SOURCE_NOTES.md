# Source and editorial notes

## September 20 addition: situational behavior and intervention rights

- **Greenblatt et al., Alignment Faking in Large Language Models** (2024),
  [arXiv:2412.14093](https://arxiv.org/abs/2412.14093) and the
  [Anthropic research account](https://www.anthropic.com/research/alignment-faking).
  This supports the behavioral claim about training information and selective
  compliance. It is not cited as an activation study. No published proceedings
  version was located; the bibliography retains the preprint.
- **Hua, Qin, Marks, and Nanda, Steering Evaluation-Aware Language Models to Act
  Like They Are Deployed**, [ICLR 2026 proceedings](https://proceedings.iclr.cc/paper_files/paper/2026/hash/9334fd3a5170dbfe74eae4755f6c5f89-Abstract-Conference.html).
  The primary paper tests activation steering in a model deliberately trained
  for evaluation-conditioned behavior. The published version replaces an arXiv
  or workshop citation. It does not establish that arbitrary deployed models
  identify their context correctly.

The proposed experiment is ours: vary intervention or scheduling permissions,
hold model and tasks fixed, expose inspectable policy evidence, and compare
enforcement with description-only controls. Assess policy comprehension
separately from behavior and activation changes. Neither source tests this
architecture or reduced operator authority. Both manuscripts present this as a
research direction, with simulation and external-control limitations.

The scheduling discussion concerns the general architecture, including
agent-authorized changes to future scheduling rules. It is not a new claim that
the illustrative deployment implements all such governance options.

---

Checked September 19, 2026. These are supporting notes, not manuscript text.

## Repository evidence

Base revision: `a642c38ed8d11a9a511d0f1b80a92926cd412505`.
The reviewed contracts, enclave runner, build script, and whitepaper had no local
diff from that revision. Pre-existing edits to two sovereignty pages and
`prover/client/client.py` were left alone and were not used as deployment evidence.

These source observations do not establish permissions retained by a deployed
instance. The author has clarified that administrative powers can be permanently
disabled and that the ability to turn the agent off has already been relinquished.
The manuscript consequently makes no retained-administrator claim about that
instance. Its contribution concerns the full architecture, with the code as an
illustration of execution flow.

| Source observation at the cited revision | Source |
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

No live ownership or flag state was queried. Source-level availability of a
function must not be equated with current authority to call it.

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

## Author-directed authorization revision

The current manuscript foregrounds the construction and verification of agent
approval. The earlier reachability proposition and repair/hitting-set subsection
were removed; the effective permission family remains to define the gradient.
That revision's informal integrity proposition has since been replaced by the
security games and reductions described below. The guarantee concerns accepted
approval under the prescribed relation, not a new cryptographic primitive.

The request statement explicitly binds domain, request, configuration, agent
specification, input, randomness, and output. The contract constructs expected
values from its record. Input/output coverage is an implementation obligation;
merely hashing some fields is insufficient. The model allows deterministic or
relational computation and makes no universal claim that agents cannot hold keys.

[ERC-1271](https://eips.ethereum.org/EIPS/eip-1271), read September 19, 2026,
provides the contract-defined signature-validation convention used as the bridge
to familiar authorization. This does not claim ERC-1271 implementation compliance.
The word “signature” describes an authorization role; anyone can compute evidence
for a valid output. Attestation hardware may have signing keys, while no
agent-held key authorizes arbitrary transactions.

The abstract's Base implementation sentence refers to verified paid execution.
The generalized joint-governance construction is the paper's subject; the source
illustrates a particular execution path. The complete change record
is `reviews/authorization-revision.md`.

## Abstract refinement: scheduled agency and preliminary novelty check

Only the abstract is revised in this pass. All manuscript text after the abstract
is unchanged. It now explicitly connects signatures to self-modification through
ledger transactions, uses signature-forgery terminology, and motivates scheduled
execution as recurring opportunities to act. Payments recruit workers to meet
that schedule; deposits address selected-worker non-delivery. The recovery claim
remains conditional and does not promise a hard real-time schedule.

For the later body revision, preserve the author's motivation: execution is
scheduled, rather than solely triggered by a willing operator. A party can value
preventing a particular on-chain action; for example, a borrower may benefit from
preventing an agent from submitting a liquidation transaction. This is a generic
illustrative use case, not an action supported by the charitable-fund instance.
Distinguish availability of affordable workers from adversarial disruption, and
explain how each affects the schedule. The existing theorem counts attempts;
calendar-time guarantees still need bounds on how often attempts occur.

Preliminary primary-source checks (September 19, 2026):

- Modulus Labs, [Rockefeller Bot announcement, August 19, 2022](https://medium.com/@CountableMagic/chapter-3-the-worlds-first-on-chain-ai-trading-bot-c387afe8316c),
  describes verified neural-network decisions controlling trades from a contract's
  funds. This is a close precedent for inference-based transaction authorization.
  It does not establish the novelty of our self-modification permission structure.
- [Giza Agents repository](https://github.com/gizatechxyz/giza-agents) documents
  waiting for verified predictions before contract interactions, with a keyed
  account used for submission. This is relevant adjacent work; it is not evidence
  that the contract enforces exactly our authorization interface.
- Ritual Foundation, [Unveiling Ritual](https://www.ritualfoundation.org/blog/unveiling-ritual),
  describes modular computation verification, scheduled transactions, and a
  compute marketplace. This is relevant to the scheduling and market composition.

These are primary project descriptions, not independently reproduced evaluations
or an exhaustive novelty search. No first-of-its-kind claim about inference as a
signature is justified by this check. The stronger framing to evaluate in the
later literature revision is verified approval of the agent's own modification,
configurable governor participation, and the specified economic liveness analysis.
The abstract makes no priority claim; bibliography/body integration is deferred
until the abstract is agreed, as requested.

## Full revision after abstract approval

The approved abstract is preserved, including the author's inline revision to its
opening sentence. Its final sentence now names Hermes 4 70B and Intel TDX secure
enclaves with hardware attestation. The model path in `enclave_runner.py` and the
GCP image build names the Q6_K split GGUF. The official
[model card](https://huggingface.co/NousResearch/Hermes-4-70B) identifies the model;
the [Hermes 4 technical report](https://arxiv.org/abs/2508.18255) dates its release
family to 2025. `TheHumanFund.sol` initializes a 24-hour period; auction timing can
subsequently configure it. The manuscript describes the default, not a live timing
measurement.

Rocky was checked against both its August 19, 2022 announcement and repository
revision `7d2214735ce48284ce61800e4d7ff54b1153c89e` (September 16, 2022).
The repository was inspected, not executed. Primary sources:

- [Announcement](https://medium.com/@CountableMagic/chapter-3-the-worlds-first-on-chain-ai-trading-bot-c387afe8316c):
  a three-layer neural network on StarkNet directs trades by an Ethereum contract.
  This precedes the use of verified inference as transaction authorization.
- [L2 contract](https://github.com/Modulus-Labs/RockyBot/blob/7d2214735ce48284ce61800e4d7ff54b1153c89e/L2ContractHelper/L2RockafellerBot.cairo):
  `calculateStrategy` runs the supplied weights on the supplied inputs and sends
  a trade instruction. This is the concrete inference-to-transaction path.
- [L1 contract](https://github.com/Modulus-Labs/RockyBot/blob/7d2214735ce48284ce61800e4d7ff54b1153c89e/L1Contract/contracts/RockafellerBotL1.sol):
  `receiveInstruction` consumes the StarkNet message before calling the swap
  router. These published contracts contain neither the general agent-approved
  self-modification interface nor the auction and non-delivery bonds studied in
  this paper. No claim is made about Rocky's historical deployed permissions.
- [Ritual architecture announcement](https://www.ritualfoundation.org/blog/unveiling-ritual),
  February 26, 2025: native scheduling, modular computational integrity, and a
  compute marketplace. This is cited as an announced architectural precedent,
  not as a reproduced performance or liveness result.

The paper claims no priority for inference-directed transactions, configurable
contract signatures, or the bare combination of scheduling and compute markets.
Its focus is the extension to self-modification permissions and the specified
conditional recovery analysis. The TDX/70B instantiation is an engineering choice,
not a cryptographic-security improvement over Rocky.

Section 4 now starts from scheduled opportunities to act. Payment feasibility
and adversarial non-delivery are separate obstacles. The lending example explains
why a party might pay to delay an on-chain action; it remains an illustrative
application, not a charitable-fund operation. The recovery theorem is unchanged.
A short calendar-time consequence adds the necessary assumption that attempt k's
deadline is at most k times a fixed duration from recovery's start, including idle
gaps. This does not turn the theorem into an unconditional schedule guarantee.

### Rocky: adversarial inputs, model substitution, and resampling

Checked the complete inference and trade paths in the pinned source above.
`L2RockafellerBot.cairo` lines 89-123 accept balances, a price ratio, the input
vector, all three layers' weights and biases, dimensions, and a scale factor.
Line 119 enforces the stored owner's caller address. Lines 505-511 check tensor
dimensions. No stored model hash, input commitment, oracle signature, or fixed
market snapshot is checked along this path. The proof authenticates execution on
these supplied values, not that they are the intended model or market data.
Non-owner callers are excluded; a malicious owner is not constrained by those
missing bindings. This is an architectural trust choice, not a proof-system break.

`ContractStarter/get_contract_data.ts` loads weights from local JSON, obtains
market data through a query helper, reads L1 balances, and packages those values
for submission. This preparation is off-chain; the Cairo code does not verify
that the caller used that script or its data source.

The deployed-inference program in the published Cairo source is deterministic:
three linear layers with ReLU, deterministic scaling, and a deterministic maximum
selector (lines 274-283 and 479-571). There is no sampling seed or dropout path.
Thus stochastic resampling with identical inputs and weights is inapplicable.
The owner can choose different inputs/weights or when to submit, which is input
selection or selective execution, not fresh randomness from a fixed inference.
Moreover, `send_abritrary_message` (source spelling, lines 71-87) lets the owner
emit a trade instruction without running the classifier. This is an authorized
bypass in the published code and should not be described as an outsider exploit.

The L1 `receiveInstruction` path consumes a StarkNet message. Its payload contains
only trade direction and amount; no application request nonce or market timestamp
is included. Bridge message consumption and inference resampling are distinct
questions. No claim of a bridge replay vulnerability is made.

Following the author's request to keep the comparison proportionate, the paper
includes only the high-level input/model-binding distinction. The resampling and
alternate-entry-point details remain in these supporting notes. No historical
deployment ownership is inferred from source, and our own input commitments do
not prevent malicious content, market manipulation, or adversarial messages from
entering through an otherwise authorized data path.

## Section 2: authorization security games and reductions

This pass replaces the informal integrity proposition with explicit games and a
composition theorem. The abstract, introduction, and governance/liveness arguments
are preserved. Section 2.3 now begins with the general verification interface;
the model-upgrade example has been removed.

Primary sources checked for the formal interfaces:

- Parno, Gentry, Howell, and Raykova, *Pinocchio: Nearly Practical Verifiable
  Computation* (IEEE S&P 2013), [ePrint 2013/279](https://eprint.iacr.org/2013/279).
  Definition 1 supplies the public setup/evaluation/verification precedent.
  Our interface additionally carries a request context and commitments, and admits
  a protected execution interface for an attestation backend. This is an adaptation,
  not a claim that Gennaro et al.'s original scheme has the same public interface.
- Castro and Liskov, *Practical Byzantine Fault Tolerance* (OSDI 1999),
  [paper, Section 3](https://pdos.csail.mit.edu/6.824/papers/castro-practicalbft.pdf).
  Used for the consistent, atomic state-machine execution view of safety. The
  paper's specific fault threshold and synchrony assumptions are not assigned to
  Base or assumed universally. Our ledger experiment is an application-specific
  formulation with explicit finality and ledger-specific fault assumptions.
- Benarroch, Campanelli, and Fiore, *Proposal: Commit-and-Prove Zero-Knowledge
  Proof Systems* (Third ZKProof Workshop, 2020),
  [proposal, Sections 4.2–4.5](https://docs.zkproof.org/pages/standards/accepted-workshop3/proposal-commit_and_prove.pdf).
  Used for adaptive knowledge soundness, extraction of committed values, and the
  importance of the auxiliary-input distribution. The manuscript does not call
  this workshop proposal a universally adopted standard.

The composition theorem partitions ledger failure from a valid execution of the
specified authorization state machine. In a valid execution, eligibility and
permanent request consumption reject replay; output application uses the verified
update. An invalid decision must therefore appear in an accepting verifier call.
Selecting one of at most Q calls gives a single-output computation forger, with
loss Q. The simulation retains full request contents, and specification
registration supplies full contents to the experiment even when the ledger stores
only hashes. No efficient test for identifying the bad call is needed. The
reduction does not condition the computation challenge on ledger success or assume
independent failure events.

The hash lemma repairs an actual gap in the earlier short proof. Ordinary language
soundness alone asserts existence of a valid opening. Computational collision
resistance does not make a compressing hash injective, so an explicit collision
reduction needs the other opening. Adaptive knowledge soundness supplies it. If
the extracted model, input, and output all match the intended values, the accepted
trace contradicts invalidity; otherwise a differing pair gives a collision. The
hash key is sampled first and proof setup runs for that relation. Auxiliary inputs
and honest evaluation transcripts must be covered by the extraction assumption.
Attestation backends instead need the stated computation-soundness guarantee under
their own hardware and attestation assumptions; the lemma does not claim TDX is a
SNARK or has a cryptographic extractor.

The authorization experiment permits the adversary to act as every governor,
including the creator. It does not need governor key-custody assumptions. Permitted
governor-only actions are not forgeries. The experiment fixes the authorization
implementation and verification backend, while allowing authorized model and
policy changes; replacement of the enforcement mechanism is the Section 3
permission question. Correct implementation of the specified state machine remains
an explicit premise, rather than a consequence of consensus safety. No formal
verification or security audit of the deployed contracts is claimed.

## Self-contained ledger definitions

Section 2.4 now defines the exact ledger interface used by the proof: transaction
histories and their prefix order, deterministic ledger transition function delta,
sequential execution from genesis, and honest finalized observations carrying
histories, states, and receipts. Agreement means honest histories are
prefix-compatible; persistence means a party's finalized history only extends;
execution validity equates observed states and receipts with sequential execution.
Only finalized prefixes are compared, so tentative forks and lagging observers do
not by themselves violate the definition. The ledger security game explicitly
records these observations and checks all three clauses.

The additional primary reference is Garay, Kiayias, and Leonardos, *The Bitcoin
Backbone Protocol: Analysis and Applications* (EUROCRYPT 2015). The
[July 7, 2015 full version](https://cryptochainuni.com/wp-content/uploads/The-Bitcoin-Backbone-Protocol-Analysis-and-Applications.pdf)
was read at Definition 2 (common prefix) and Definition 14 (ledger persistence and
liveness). The bibliography links its [ePrint record](https://eprint.iacr.org/2014/765)
and published DOI. The manuscript adapts the ledger-persistence concept to an
abstract finality interface; it does not copy the original synchronous model's
next-round reporting requirement, proof-of-work thresholds, or block-depth
notation. Castro and Liskov's Section 3 supplies the complementary replicated
state-machine semantics. These references establish provenance; the reader no
longer needs them to reconstruct the assumptions used in our theorem.

The proof now names agreement, persistence, execution validity, and contract
correctness at their respective uses. A separate premise requires all application
entry points to conform to the authorization state machine. A consistent ledger
running incorrect application code does not establish that premise. Atomicity of
a ledger entry and correctness of the application's consumption logic are distinct.
The ledger definitions impose no transaction-inclusion, growth, or timing bound.

A short intuition paragraph precedes the theorem; the longer walkthrough of the
simulation and Q factor is provided in the conversation for author feedback.
Formal uses of 'efficient' in the manuscript have been replaced with polynomial
time or PPT, defined on first use. Original publication titles are unchanged.

## Formal proof style and governance semantics

The author supplied a private problem set as a writing-style example. Its relevant
features are explicit algorithm inputs and assignments, named random variables and
events, and probability calculations in the proof itself. The file is not copied,
cited as prior art, or included in the source archive. Durable writing guidance is
in AGENTS.md and applies throughout the manuscript.

The authorization reduction now names the simulated transcript, ledger-failure
event, stored verifier tuples, uniformly selected index, and set of accepting
invalid statements. It derives the Q loss as an expectation over this index.
The ledger game explicitly shares honest application initialization and evaluation
access with the authorization experiment. The hash lemma names hash-key generation,
relation-specific proof setup, public parameters, prover tape, auxiliary output,
extractor, and collision pair. The extraction assumption specifies the prover tape
and auxiliary input available to the extractor; it does not assert extraction from
a public proof alone. The accompanying reduction intuition remains outside proofs.

Section 3 uses standard labelled transition-system and access-structure language
with an application-specific reference-consent label. A governance instance fixes
the state and update spaces, governors, governing state machine, and reference
agent relation. Policies remain state-dependent. Path labels record governor
approvals and whether a step used reference-agent approval. Replacing the current
program or verifier does not redefine the reference agent's consent. Existing
delegations are already part of the starting state.

The two reachable-state sets distinguish paths permitting reference consent from
paths with none. Incorrigibility is a predicate of an instance, initial state,
coalition, and target, equivalent to requiring every relevant path to contain
reference consent. Unreachable targets satisfy the predicate vacuously, so the
manuscript separately identifies feasible consent-dependent interventions. The
profile collects coalitions with intervention paths lacking reference consent;
pointwise inclusion compares protection. These are ideal semantic reachability
claims, not a computational search algorithm, a strategy forcing an execution, or
an audit proving a deployed instance meets the predicate. Approval on a path is
approval of that transition, not of all subsequent consequences; analysis can be
restarted after delegation or an approved upgrade.

The recovery proof names the pre-outcome selection sigma-algebras, success and
responsive-worker indicators, indices of responsive attempts, and successive
failure events. The decisive conditional expectation is taken on the event that a
responsive attempt has been selected, before its result is known. No independence
or conditioning on future selection is used. The calendar-time implication,
recurrence argument, and finite-resource inequality also now name their variables
explicitly. The recovery theorem and its substantive assumptions are unchanged.

## Role-independent authorization experiments and terminology

The latest author-directed revision replaces "agent signature" with "verified
agent authorization" throughout the current manuscript, including the abstract,
introduction, governance section, implementation discussion, and conclusion.
Actual account signatures and the ERC-1271 comparison retain their terminology.
Earlier revision records preserve the wording used at the time.

The authorization adversary is now a PPT oracle algorithm, independent of worker,
creator, or governor roles. The governor definition, Boolean policy interface, and
EIP-712 discussion move to Section 3. Section 4 retains the worker-market model.
The security result fixes the authorization implementation and verification
configuration while permitting application transitions under an arbitrary policy.

The verification scheme explicitly separates public parameters from private
backend state. Setup returns (pp, kappa); the oracle invokes Eval with that state.
For public proofs kappa is empty. Verification is deterministic, matching the
ledger-execution interface. Lemma 1 uses this same oracle notation.

The ledger protocol is represented by Init and Next algorithms, with a stateful
ledger-command oracle and an explicit Run algorithm. Its execution record is the
genesis state, a sequence of honest finalized observations, and verification-call
records. Each successful verified settlement is annotated with its application
pre-state, request, output, and post-state. These are semantic annotations, not a
requirement to store intermediate states or full model weights on-chain. The
logical request records retain registered contents as in the previous revision.

Verification calls are obtained by deterministic replay of each observed history.
This makes the connection from execution-valid finalized receipts to an accepting
verification call explicit, without assuming that a particular honest process
actually re-executed the history instead of obtaining state by transfer. Replay
stops at an undefined transition and continues with the next history. The Q factor
now explicitly counts these replayed calls, including repeated prefixes; its
polynomial bound follows from the polynomial number and lengths of observations.
No claim that this is a tight concrete-security loss is made.

AuthForge is a numbered definition with initialization, execution, and a final
predicate on successful settlement annotations. Safe, Sett, Correct, and the
tuple projection used by the proof are all defined. F is the event Safe=0, not a
property of an undefined transcript. The ledger reduction is an oracle-preserving
wrapper around A; the computation reduction invokes the same Run algorithm with
its challenge parameters and evaluation oracle. Equality in distribution follows
query by query. The proof remains a direct event-splitting reduction; no ideal
ledger replacement or hybrid indistinguishability claim is used.

## Authorization interface and notation pass

Section 2 now uses Msg for the statement encoder, Ldg for the ledger protocol,
Ctr for the contract, and explicitly labelled evaluation and ledger-command
oracles. Hash fields use h_theta, h_x, and h_y; protocol replies no longer reuse
v, the configuration-version variable. Abstract computation functions and
relations retain F and R. The Ctr rename propagates to Section 3.

The numbered authorization-state-machine definition gives a generic guarded
settlement algorithm: eligibility, message construction, evidence validation,
update applicability, and atomic application/consumption. The signature example
uses SigVerify; the verified-computation instantiation uses Verify on Msg of the
logical request and output. The definition is our abstract interface, not a claim
that these algorithm names constitute a blockchain standard. ERC-1271 supports
the contract-validation comparison, including state-dependent validation.

The Ethereum Yellow Paper (Shanghai version efc5f9a, dated February 4, 2025;
accessed September 19, 2026) supplies the state-transition convention. Section 3
of that source uses primed variables for modified values. Settlement annotations
therefore use (s,e,y,s') in place of minus/plus superscripts. Annotations refer to
committed successful invocations, excluding calls rolled back by a later revert.

Theorem 1 existentially quantifies a polynomial Q, whose bound on replayed
verification calls is defined in the proof. Its reduction and security assumptions
are unchanged. AuthForge becomes Definition 5 after the new Definition 4. Short
orientation paragraphs explain the ledger, contract, shared interaction, and
security games; formal blocks retain formal statements and constructions.

## General reduction loss and formal later sections

The author requested a check of whether Q simplifies the authorization proof,
followed by the same formal standard in later sections. The general relation R
need not have polynomial-time membership testing. A polynomial-time trace check
is not by itself such a test, so selecting a uniformly random recorded call
retains the generality of the existing theorem. Corollary 1 gives a lossless
reduction when R is polynomial-time decidable: the reduction computes I(Z) and
returns the first false accepted tuple. A public polynomial-time deterministic
program is a sufficient special case. No claim of an inherent lower bound on
reduction tightness is made, and the security games are unchanged.

Section 3 now makes the approval circuit's access structure, transition witness
and used-credential interfaces, reference authorization predicate, finite paths,
reachable sets, and profile order explicit numbered definitions. Reference
validity includes the prescribed request binding and correct computation under
R_A, independently of changes to the current contract checker. Only credentials
used to satisfy the transition's permission rule contribute to its labels.
These are ideal semantic definitions; the section does not promote them into a
new computational theorem about arbitrary mutable verification policies.

Section 4 now defines the probability space, filtration, selected-worker class,
success indicator, and nonnegative net-loss variables before its theorem. The
proof derives the failed-attempt count from the sum of actual losses. Its
conditional-expectation argument permits adaptive selection and does not assume
independence. Continuation is a condition of the recovery process; unreached
hypothetical trials cannot stand in for actual execution attempts. The threshold
may come from the payment rule, but profitability does not establish the loss
or responsive-success conditions.

The calendar-time and recurrence consequences are a separate corollary with a
formal proof. For recurring episodes, parameters can depend on initial history;
each episode needs its own positive conditional success lower bound and finite
threshold/budget. No common positive bound across all episodes is required for
almost-sure recurrence. The escalating-bond calculation explicitly indexes the
selected-worker failure counter, showing that intervening responsive failures
cannot reduce the lower bound on cumulative adversarial losses. Monetary payoff
and finite-funding statements name the quantities to which their bounds apply.

The attestation discussion now maps its trust roots, measurements, report checks,
protected state, execution, and evidence to nu, kappa, Eval, and Definition 1.
This is an abstract instantiation obligation, not an additional empirical claim
or hardware-security proof. Benchmark and implementation claims are unchanged;
no new literature search was necessary for these mathematical revisions.

## September 20: publication audit, chronology, and discussion

Independent reports are stored in `reviews/bibliography-audit-2026-09-20.md`,
`reviews/proof-audit-2026-09-20.md`, and
`reviews/venue-assessment-2026-09-20.md`. The bibliography audit checked all 31
entries against primary records and citation contexts. Its corrections were
applied: published venue metadata and links for foundational works, corrected
Pinocchio author order, missing page ranges, and forthcoming proceedings status
for NanoZK (ICICS 2026) and DeepProve (CCS 2026). The versioned NanoZK extended
paper remains the source of its measurement qualifications. Preprints without
verified published replacements remain preprints. The model-card citation is
retained because it identifies the exact model artifact.

Direct HTTP checks covered all 31 citation URLs and nine DOI targets. They found
34 HTTP 200 responses, three 202 responses, two 403 responses, and one 406
response; no confirmed 404 or 410. Cookie/challenge responses are not represented
as full-content verification. The audit report records which metadata was
verified through published PDF copies or the research browser. Both immutable
GitHub revisions and the Substack URL returned 200.

The architecture overview at https://ahrussell.com/writing/costanza/ has the
heading "Meet Costanza" and a visible April 2026 date. A separate public LinkedIn
launch announcement corroborates that this preceded the July follow-up:
https://www.linkedin.com/posts/andrew-russell-0007a01ab_a-few-months-ago-i-wrapped-up-an-amazing-activity-7456995460080238592-FWb1 .
No exact April day or independent archived publication timestamp is asserted.
Direct Substack metadata gives `2026-07-21T17:53:01+00:00` and the full title
"I built an AI agent I can’t turn off. Now it won’t listen to me." Its citation
now includes the second sentence.

Rocky (August 19, 2022) and Ritual (February 26, 2025) precede the original
architecture overview. NanoZK v1 is March 17, 2026; the cited v2 is July 18 and
corresponds to forthcoming ICICS 2026 plus extended material. The cited DeepProve
LLM paper was received by ePrint May 30 and publicly approved June 2, 2026, after
the overview; its earlier product branding is a separate matter. The backend
survey explicitly includes later developments. Related work credits Rocky
positively and states the security composition, self-governance, and recovery
contributions without asserting an unverified global priority claim.

The conclusion is now a discussion of operational agency and AI-safety
implications. Its safety arguments are implications of the construction, not
empirical claims about model behavior: removing operator powers need not require
a model to learn shutdown resistance; computation integrity does not imply safe
outputs; and intervention rights need assessment alongside capabilities and
continued execution. Existing corrigibility references motivate the distinction.
The discussion claims no independence from infrastructure, funding, or the
ledger/backend's cryptographic assumptions.

The proof audit identified and repaired the experimental-data input to replay.
The full registration journal is explicit in the execution record and replay
interface; physical ledger state and its safety predicate remain unchanged.
This prevents the proof from implicitly reconstructing model contents from
hashes. Theorem 2 now uses a common probability-one event and fixes versions of
conditional probabilities; its counting step is valid on that event and its
final probability inequality uses its unit measure. The audit confirmed the
resulting reductions, governance definitions, recovery bound, and recurrence
argument under their stated assumptions. This is a manual agent audit, not a
machine-checked proof or an independent human peer review.
