# Revision around verified agent authorization

This revision responds to the author's rewritten abstract. It replaces the earlier
emphasis on transitive governance permissions and blocked repairs with the central
construction: verified inference supplies an agent's authorization without an
agent-held private key. No new subagent review round is claimed for this revision.

## Abstract clarity review

The author's sequence is retained: dependence on an operator; ledger state and
paid untrusted execution; inference evidence as the agent's signature; consent to
self-modification; tampering resistance; resistance to silencing; implementation.

- “Without an agent-held private key” describes the construction. “Cannot hold a
  private key” would assert a general impossibility that the paper does not prove.
  Hardware attestation can itself use keys; those authenticate the backend's
  evidence and are not a key under the agent's discretionary control.
- “Require its verified approval” replaces the less direct “permissioning changes
  ... on these verified inference outputs.” The following sentence explains the
  operation: the existing program reviews the proposed update.
- The signature analogy refers to the output together with valid evidence. It is
  authorization attributable to a program, not a new private-key signature scheme.
- Workers can alter bytes or withhold results. The integrity guarantee is that
  substituted inputs or invalid outputs cannot obtain accepted agent approval
  under the stated assumptions. Deterministic execution yields one valid result;
  a relational specification may permit several.
- Silencing resistance is described as a conditional recovery bound. The abstract
  names the categories of assumptions; Section 4 states them precisely.
- The final sentence says “execution architecture” because the reference source
  implements verified paid execution, while general joint agent/governor
  governance is an extension of its existing permission interface.

## Reweighting the paper

- The title and introduction now foreground verified inference as authorization.
- Section 2 makes the complete verification statement explicit, including the
  contract's expected input commitment, output commitment, context, nonce, and
  configuration. It defines verified agent approval and proves its integrity.
- The proof is short because its reduction is elementary. The explanation spends
  space on the implementation obligation that matters: complete coverage of
  inputs, outputs, and the agent harness, and contract-derived expected inputs.
- Section 3 retains unilateral, bilateral, and multilateral policies and the
  incorrigibility profile. Administrative reachability is conventional permission
  accounting. The separate reachability proposition and repair/hitting-set
  subsection have been removed; repair is a brief established constraint.
- Section 4 keeps the audited conditional recovery theorem and its assumptions,
  now introduced as resistance to suppression by selected workers.
- Sections 5–6 connect the backend and Base implementation directly to input
  binding, output authorization, payments, deposits, and worker replacement.
  Material implementation limits remain explicit without leading the section.
- Related work and the conclusion now follow the same contribution hierarchy.

## Convention and source checks

ERC-1271 was read from the primary specification and added as the familiar
contract-validation bridge. It permits contract-defined validation; the paper
neither claims to invent contract signatures nor claims the implementation uses
that exact interface. EIP-712 was rechecked for domain separation and its explicit
lack of application-level replay protection.

Repository checks confirmed the input snapshot commitment, enclave recomputation,
contract-side output hashing (including the persistent-state update batch), and
TDX report-data verification. The Base and model descriptions come from the cited
repository. Existing backend and governance limitations remain in Section 6.

The editor reread the revised abstract and each section opening as a nontechnical
reader, followed the authorization/permission/payment interfaces as an engineer,
and checked the two proofs and the reference-agent convention as an academic.
These are editorial checks, not external peer review or a deployment audit.

## Artifact checks

The revised PDF has 12 pages including 22 references and compiles without
warnings. All pages were rendered and visually checked; affected pages were
checked again after the last text changes. Citation keys and internal references
resolve, and the source bundle was rebuilt from the current files.

## Revision after abstract approval: schedule and prior art

The abstract's opening retains the author's concurrent inline edit. The requested
implementation names are now Hermes 4 70B and Intel TDX secure enclaves with
hardware attestation. The introduction develops the approved sequence: verified
inference as a signature, self-modification as a ledger update, configurable
permissions, scheduled opportunities to act, and the worker market. A lending
example gives an adversary a concrete reason to delay an on-chain action.

The full architecture is the contribution. The implementation illustrates the
execution flow; the manuscript no longer equates source functions with retained
administrative powers in the author's deployment. The author clarified that such
powers can be permanently disabled and shutdown authority has already been given
up. No deployment audit is claimed or needed for this revision.

Rocky's announcement and pinned source were read. It receives credit for the
precedent of verified neural inference directing transactions. The manuscript
keeps the comparison at the level of binding the program and request, authority
over self-modification (including the creator's authority), and scheduled paid
execution. Detailed checks of Rocky's input arguments, weight selection,
deterministic inference, and owner-only alternate path are in `SOURCE_NOTES.md`.
They are not used to turn the related-work section into a critique of Rocky.
Ritual is cited as an architectural precedent for scheduling, modular verification,
and a compute market. Neither comparison supports a broad first-of-its-kind claim.

The signature definition now states precisely what forgery means for this
construction: accepted evidence outside the recorded computation relation.
Producing a valid result is deliberately public and is not a conventional
private-key signature forgery. The elementary binding/soundness proof is unchanged.

The liveness section starts from the schedule. Its theorem still counts attempts;
a short consequence states the additional timing condition needed for a calendar
bound. The proof and its conditional-history requirement remain intact. The
reader-facing explanations distinguish recruitment costs from deliberate
non-delivery, and missed decisions from subsequent recovery.

Editorial review again followed the general reader through section openings, the
engineer through the authorization and market interfaces, and the academic through
binding, approval attribution, and the recovery proof. No new subagent review or
external peer review is claimed. The introduction is now left stable for the
author's review.

### Artifact verification for this revision

The final build has 13 pages including 26 references, with no TeX warnings,
missing citations, or unresolved internal references. All pages were rendered and
visually inspected; the final related-work and bibliography pages were inspected
again after the comparison was shortened. The LaTeX source bundle was refreshed.

## Introduction sequence refinement

The introduction now starts from ordinary operator control before introducing
blockchain enforcement. Verified inference is followed by a fund-recipient
example and the Rocky precedent. Agent consent to self-modification then introduces
architectural incorrigibility; mixed and graded governance follows that concept.
A footnote notes that the agent can have authority over its own execution schedule.
The abstract and all later manuscript sections are unchanged in this pass.

The rebuilt PDF remains 13 pages, with a clean final TeX log. The introduction
and schedule footnote were inspected at full-page scale, and pagination throughout
the remaining pages was visually checked. The source archive was refreshed.

## Consent, execution, and terminology

The author's replacement paragraph now connects exercising consent to scheduled
execution, explains the open worker market, and explicitly treats the centralized
operator as a potential adversary after deployment. The schedule-governance
footnote is retained. This pass changes only that paragraph in the manuscript.
“Architectural incorrigibility” is retained as the recommended term: the qualifier
locates the protection in system mechanisms and distinguishes it from willingness
to accept correction. A targeted terminology search found no established usage
requiring either compound term; Soares et al.'s original definition was rechecked.
The PDF builds cleanly, and the edited page and following pagination were inspected.

## Section 2: formal authorization security

The author requested a more formal treatment of Sections 2.3 and 2.4. The opening
upgrade example in 2.3 has been removed. The section now defines a verifiable
computation interface and chosen-input soundness game before introducing agent
signatures and governor policies.

Section 2.4 states the ledger safety experiment and contract-correctness premise,
then defines authorization forgery over finalized settlements. The theorem gives
explicit reductions to ledger failure and computation forgery, with a Q loss for
selecting one verification attempt. Its proof handles replay, stale requests,
output application, adaptive interactions, and the simulation of evaluation calls.
Governors, including the creator, may all be adversarial within their assigned
permissions. Authorized changes that remove enforcement belong to the governance
analysis, rather than being mislabeled cryptographic forgeries.

A separate lemma justifies verification over model/input/output hashes using
adaptive knowledge soundness and collision resistance. This addresses the missing
opening-extraction step in the previous informal binding argument. Standard
verifiable-computation, state-machine replication, and commit-and-prove references
are recorded in SOURCE_NOTES.md. No new primitive or implementation audit is
claimed.

The editor checked the formal reductions for adaptive challenge selection,
conditioning on ledger success, knowledge extraction, and explicit setup and
request-content assumptions. Section openings retain a plain-language account of
what is proved. The abstract and introduction are unchanged. No new subagent or
external review is claimed in this pass.

### Artifact verification for the Section 2 revision

The final PDF has 15 pages and 29 references. It compiles without TeX warnings,
undefined references, or overfull/underfull boxes. All pages were rendered;
Sections 2.2–2.4 were inspected at full-page scale, and the final lemma page was
rendered and checked again after the extraction assumption was clarified.
The source archive was refreshed and checked byte-for-byte against its 14 input
files. The abstract and introduction were compared to the start-of-turn source;
they are unchanged. Beyond Section 2, the only manuscript edit is the implementation
section's cross-reference from the former proposition to the new theorem.

## Self-contained ledger assumptions and reduction intuition

The author asked to include the ledger definitions directly in the main text.
Section 2.4 now defines histories, prefix order, the deterministic transition
function, sequential execution, and finalized observations. A numbered definition
states agreement, persistence, and execution validity. The ledger-failure game
checks these clauses explicitly. The contract-correctness assumption and theorem
premise remain separate from the consensus/ledger assumption.

The proof identifies the role of each property: agreement and persistence fix the
history, execution validity computes its states and receipts, and contract
correctness supplies request eligibility, consumption, and application semantics.
A brief intuition paragraph introduces the reduction as a construction using the
authorization forger as a subroutine. The detailed explanation of simulation and
the Q factor is kept in the conversation for the author's editorial guidance.

Garay, Kiayias, and Leonardos is added as the ledger-persistence reference, alongside
Castro and Liskov for replicated execution. Their definitions are restated for the
paper's finality interface, without importing a consensus algorithm's specific
fault threshold or timing assumptions. Every formal use of 'efficient' in main.tex
has been replaced with 'polynomial-time' or 'PPT'; bibliography titles retain their
original wording. No appendix or new subagent review was introduced.

## Formal proofs throughout and Section 3 definitions

The author's next requests extended the proof-writing preferences to the entire
paper and asked for a precise object and reachability definition underlying
architectural incorrigibility. AGENTS.md now preserves those preferences, with a
link from README.md. The private problem set informed style only.

Both Section 2 reductions now specify named parameters, algorithms, random tapes,
outputs, events, and advantage calculations. The authorization experiment carries
one sentence of reduction intuition outside its proof. Shared honest application
initialization is explicit in the ledger game. The hash proof states the extractor's
access and constructs the encoded collision pair explicitly.

Section 3 now proceeds from one-step access structures to a governance instance,
labelled transitions, finite paths, and two reachable-state sets. It then defines
incorrigibility as a property of that instance at a starting state, against a
coalition and for an intervention target. Both the no-path formulation and the
equivalent all-paths-have-consent formulation appear. A fixed reference agent is
distinguished from the contract's mutable agent-approval role. Unreachable targets,
agent-approved paths, and coalitions with paths lacking consent are kept distinct.
The profile compares the latter families by inclusion.

The liveness proof now uses named pre-outcome histories and explicit conditional
expectation to handle adaptive worker selection. Its informal explanation remains
outside the proof. Calendar-time recovery, recurrence, and the resource bound have
also been rewritten with named quantities. All three proof blocks were reviewed
for the author's conventions; later implementation and literature sections contain
no additional proofs requiring this treatment. No new subagent review is claimed.

### Artifact verification for the formalism revision

The rebuilt PDF has 18 pages and 30 references. The final TeX log contains no
warnings, unresolved references, or overfull/underfull boxes. All pages were
rendered and inspected in contact sheets; the ledger definition, all three proofs,
and the new governance definitions were also inspected at full-page scale. The
abstract and introduction match the source saved before this revision. Manuscript
changes are confined to Sections 2, 3, and 4; later sections contain no proofs and
required no edits for this request. The source archive contains 15 files, including
AGENTS.md, and was checked byte-for-byte against the editable sources.

## Algorithmic experiments and authorization terminology

The author requested separation of authorization security from market/governance
roles, a numbered AuthForge definition, formal replacement of the unspecified
transcript, and algorithms in place of phrases such as "run the public ledger
algorithms". They also requested a term other than "agent signature".

The manuscript now uses "verified agent authorization" and introduces governor
roles and their policies in Section 3. AuthForge is Definition 4, with a label used
by Theorem 1 and its proof. Setup, evaluation access, ledger initialization,
protocol transitions, the stateful command oracle, replay, and the execution record
are specified as mathematical algorithms and objects. F is defined using Safe;
the authorization winning event uses the Correct predicate on settlement records.
The reduction's simulation is the same Run algorithm as the security experiment,
with the evaluation oracle supplied by the computation challenge.

Replay explicitly captures the accepting verification call corresponding to each
execution-valid settlement, including when a ledger protocol uses state transfer.
Q counts replayed calls; repeated prefixes can increase this polynomial bound.
This detail and the logical state/receipt annotations are documented in the source
notes. The hash lemma's evaluation interface is updated consistently. The author
preferences are recorded in AGENTS.md. No new independent review is claimed.

### Artifact verification for the experiment revision

The final PDF has 19 pages and 30 references. It compiles without warnings,
unresolved references, or overfull/underfull boxes. All pages were rendered and
inspected; the renamed definitions, protocol algorithms, AuthForge, Theorem 1,
hash lemma, and relocated governance interface were checked at full-page scale.
The authorization section contains no worker, governor, or creator role labels,
and the current manuscript contains no undefined transcript terminology or use of
"agent signature". Conventional signature references remain where appropriate.
The source archive was refreshed and verified against its 15 source files.

## Descriptive notation and a generic authorization state machine

The latest author feedback requested a Section 2 notation review, a standard
signature-gated state-transition presentation followed by the computation-check
substitution, and high-level orientation outside formal blocks.

Msg replaces the statement encoder M; Ldg and Ctr distinguish ledger protocol and
contract. Evaluation and ledger-command oracles have descriptive subscripts, and
protocol responses no longer overload the configuration version. Hash components
are named for the values they commit to. Settlement records use s and s', matching
the primed-value convention in the Ethereum Yellow Paper. Section 3 follows the
contract rename.

Definition 4 now specifies the authorization state machine using eligibility,
message construction, evidence checking, application, and request consumption.
The next paragraphs give the ordinary signature instantiation and replace its
validator with computation verification. AuthForge is consequently Definition 5.
The unrelated-permissions paragraph is removed. Theorem 1 uses a PPT adversary and
an existential polynomial Q, selected as a call bound in the proof; its redundant
negligible-advantage conclusion is removed. Introductory explanation precedes the
formal components, and ledger-definition glosses are moved outside that block.
These changes retain the direct reduction and its assumptions. No new subagent
review is claimed.

### Artifact verification for the notation revision

The final PDF has 20 pages and 31 references, with no compilation warnings,
unresolved references, or overfull/underfull boxes. All pages were rendered and
reviewed in contact sheets; the revised definitions, instantiations, security
experiments, and proofs were also inspected at full-page scale. Reference spacing
was adjusted to avoid a final page containing a single citation. The abstract and
introduction are unchanged; beyond Section 2, manuscript changes consist of the
Ctr rename and bibliography formatting. The source archive was refreshed and
verified byte-for-byte against its 15 files.

## Semi-formal introductory construction

The introduction now orients the reader through the ledger, agent computation,
and authorization substitution before the charitable-fund example. Ldg maintains
an ordered transaction history inducing global states sigma_i; Ctr specifies
application updates and their authorization. The harness specification theta
fixes the model weights and processing around inference, with ledger-derived
request input x_e, randomness r_e, and output y=(u,z). A displayed comparison
shows the signature validator and computation verifier occupying the same Chk
interface. Contract-derived message binding makes the latter specific to the
recorded harness and inputs. Correct contract code, ledger security, and
verification security support the stated settlement guarantee.

The overview reuses existing notation and references; it introduces no security
game or new claim of cryptographic novelty. The established sequence from the fund
example through prior art, agent consent, graded governance, and liveness is kept.
One redundant sentence repeating the operator protection is removed. The author's
recent substitution of "operator" in the self-governance paragraph is preserved.
Manuscript edits in this revision are confined to the introduction; the abstract
and all later sections remain byte-identical to the source saved at its start.
No independent subagent review was performed in this revision.

Follow-up feedback extends this overview into three introductory subsections:
verified computation as authorization, architectural incorrigibility, and scheduled
execution with the worker market. Agent and governor approval bits illustrate a
Boolean permission circuit, including the change from g_1 to a AND g_1. The text
then explains the partial order on the circuits' induced intervention profiles,
using subset inclusion rather than numerical counts or circuit syntax. It retains
the later reachability construction and illustrates incomparability with model
weights versus the execution schedule. The schedule and economic recovery overview
now has its own subsection; a final organization paragraph closes the introduction.

### Artifact verification for the introductory overview

The final PDF has 21 pages and 31 references. It compiles without warnings,
unresolved references, or overfull/underfull boxes. The introduction was checked
at full-page scale and all pages were reviewed in contact sheets after repagination.
The source comparison confirms that the abstract and Sections 2 onward are
unchanged by this revision. The source archive was refreshed and verified against
all 15 editable source files.

## Extending Section 2's formal standard

The author requested a check of the verification-call loss and the same formal
standard in later sections, while retaining motivation and intuition around
formal blocks. This revision preserves the abstract and the author's current
introduction byte-for-byte.

The general authorization proof retains Q. Its random choice avoids requiring a
polynomial-time procedure to decide validity under the general relation R.
Corollary 1 removes the loss when such a procedure exists, including the public
deterministic-program case. The reduction computes the set of false accepted
calls and returns its first member. The experiment definitions and Theorem 1's
original assumptions are unchanged; no necessity claim is made about Q.

The governance section now has numbered definitions for permission policies,
governance instances, paths/reachability, incorrigibility, and the profile order.
The instance explicitly supplies transition witnesses, used credentials, governor
labels, and a fixed reference authorization predicate. The latter includes
computation validity and request binding. Replacing the current contract checker
does not replace the reference check; unused appended evidence does not count as
consent. The partial order is explicitly componentwise reverse inclusion of the
coalition families, and applies to profiles rather than syntactic circuits.

The recovery section introduces the stochastic process before the theorem:
probability space, pre-outcome filtration, selection and success indicators, and
nonnegative net adversarial losses. The theorem states its budget, costly-failure,
and conditional-success requirements as formulas. The proof now derives the
failed-attempt count directly from the loss variables. The adaptive conditional-
expectation argument is retained. Calendar time and recurring execution receive
a separate corollary and proof, including the conditional-history formulation
needed when episode parameters depend on earlier outcomes. Escalating bonds use
explicit counter indices and a named cumulative-loss function.

The attestation discussion maps backend assumptions to the formal verification
interface. The implementation, related-work, and conclusion sections were read
for consistency; their exposition remains unchanged because they introduce no
additional proofs. The monetary participation, withholding, and finite-funding
calculations name the quantities and their scope. No additional literature,
empirical results, or independent subagent review is claimed.

### Formal and artifact checks

The direct and lossless reductions were checked for oracle and output handling.
The governance definitions were checked for attribution across changed programs
and for the direction of profile inclusion. The recovery proof was checked for
pre-outcome measurability, adaptive selection, charging only failed obstruction,
and the distinction between actual and hypothetical attempts. The recurrence
proof conditions on each episode's initial history; it does not assume a common
positive success bound across episodes.

The final PDF has 23 pages and 31 references. It compiles without warnings,
unresolved references, or overfull/underfull boxes. All pages were rendered and
reviewed, and the new formal blocks were inspected at full-page scale. The source
bundle was refreshed and verified byte-for-byte against its 15 editable files.
The abstract and introduction, and the implementation through conclusion, match
the manuscript saved at the start of this revision.


## Reference, proof, chronology, and conclusion review (September 20, 2026)

The recovery theorem now fixes versions of the conditional probabilities and a
common event of probability one, with its assumptions stated pointwise on that
event. The proof intersects that event in its counting step and final containment.
An explanation outside the theorem distinguishes probability-one premises from
the quantitative delayed-recovery bound. The numerical result is unchanged.

An independent subagent audited all proofs. Its Section 2 repair makes registration
metadata an explicit journal supplied to request reconstruction and replay, with
invocation locators preserving provenance. Physical ledger execution and safety
remain independent of this journal. The exact simulation and authorization bound
are unchanged. Definition 1 now distinguishes polynomially bounded interactions
from the semantic winning predicate, whose decidability is not assumed. See the
proof audit for the findings and applied repairs.

A second subagent checked all 31 references against primary sources. Corrections
include published-version links, proceedings metadata, author order, page ranges,
and forthcoming publication status. Direct HTTP checks found no confirmed dead
links; publisher challenge responses and alternate verification are documented.
Chronology distinguishes the April 2026 project overview from the July follow-up,
NanoZK's March preprint from its July revision, and DeepProve's June LLM paper.
Related work now credits Rocky directly and states the added formal contributions.

The discussion interprets agency as the ability of verified computation to effect
ledger updates and exercise runtime permissions. A new AI-safety subsection
separates model willingness to accept correction from architectural intervention
rights, computation integrity from desirable behavior, and worker replacement
from unconditional persistence. A third subagent assessed current submission
venues without submitting or contacting organizers.

### Final artifact checks

The PDF contains 24 pages and 31 references. The build has no warnings, unresolved
references, or overfull/underfull boxes. All pages were rendered and reviewed in
contact sheets; revised formal blocks, discussion, and bibliography were also
inspected at full-page scale. Every bibliography URL appears in a PDF link
annotation. The abstract and introduction are byte-identical to their versions
at the start of this revision. The editable source archive includes all 18 source
and review files, verified byte-for-byte against the working files. The three new
reports document the reference audit, proof audit, and venue assessment.
