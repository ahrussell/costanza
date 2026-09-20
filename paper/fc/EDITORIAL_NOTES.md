# FC distillation notes — September 20, 2026

These are private working notes, excluded from the anonymous source archive.

## Scope

The edition targets the FC 2027 short-paper format. It presents three linked
contributions: computation-based transaction authorization, a reachability-based
account of consent to intervention, and conditional recovery under costly
obstruction. The implementation illustrates the construction; the paper does not
present new measurements or claim that the deployed implementation satisfies
every premise of the general results.

## Changes from the full paper

1. **Introduction.** Replaced the longer tutorial with a compact construction,
   a financial application, the transition to self-governance, and the reason to
   model execution timing. Precedents are cited directly, and the final paragraph
   identifies the added results.
2. **Authorization.** Retained numbered forgery experiments, named setup and ledger
   algorithms, self-contained ledger safety properties, physical versus logical
   request records, and the full direct security reduction. The general relation
   retains the polynomial guessing factor. The tight decidable-relation case is
   stated immediately after the proof.
3. **Commitment binding.** Defined computation soundness for full request contents
   as an explicit backend requirement. The full paper's separate hash-binding
   lemma and its extraction reduction are not restated. A short paragraph explains
   the distinction between content binding and an existential statement about
   hash openings, with a commit-and-prove reference. Thus the short theorem uses
   the stronger, explicit interface assumption; it does not purport to prove the
   omitted lemma.
4. **Governance.** Used monotone access structures and labelled transition
   reachability as the organizing conventions. Preserved the reference agent,
   credentials actually used, coalition-relative paths, target-relative
   incorrigibility, and reverse inclusion of intervention profiles. The partial
   order is on profiles, not circuit syntax. Included one two-step bypass example
   and the distinction between reachability and a strategy forcing consent.
5. **Execution.** Condensed auction motivation and payment escalation. Retained the
   full stochastic recovery definition, explicit probability-one event, and
   complete counting/conditional-expectation proof. Calendar time and recurrence
   are conditional observations rather than additional theorem blocks. Funding,
   actual attempts, responsive selection, and net obstruction costs remain
   separate assumptions; profitability alone establishes none of them.
6. **Closing discussion.** Combined deployment, proof backends, and implications
   into one short section. Retained Hermes 4 70B, Base, and Intel TDX hardware
   attestation; the distinction between measured CPU execution and an unprotected
   accelerator; current proof-backend references; and the distinction between
   intervention authority and model corrigibility. Omitted the extended backend
   survey and separate recap conclusion.

## Conventions

- Standard Springer LNCS class, theorem environments, references, and layout.
- Descriptive algorithm names, explicit parameters and state updates, and PPT
  adversaries. Intuition stays outside definitions, theorems, and proofs.
- Computation evidence is called verified authorization, not an agent signature.
- The authorization experiment has no market-role or governor assumptions.
- No new priority claim. Rocky is credited directly for proved neural outputs
  directing transactions; later proof-system papers are backend developments.
- Published bibliography metadata is retained from the audited full paper.
  Where a DOI supplies the publication link, a duplicate URL was removed.
- Source links that identify the author or deployment are excluded from the
  anonymous review artifact. The implementation evidence remains in the full
  paper's `SOURCE_NOTES.md`.
- An AI-assistance paragraph records drafting, formalization, literature checks,
  and proof review. It does not assert that the author has already completed final
  validation of this edition.

## Verification of the initial edition

- Tectonic build: no warnings, unresolved references, or overfull/underfull boxes.
- Eight main-text pages; bibliography begins on page nine and ends on page ten.
- All 17 citation keys resolve to 17 bibliography entries.
- Every PDF page rendered and visually inspected; pages affected by final edits
  re-rendered and inspected again.
- PDF author metadata empty; anonymous title block and running heads.
- Official class and bibliography style unchanged from the publisher ZIP.
- Standalone source archive contains only publication source and build guidance.
- The full paper and its prior artifacts remain identical to commit `edd18c2`.

The initial distillation relied on the full manuscript's earlier audit. The
subsequent reviews below independently assessed this condensed edition.

## Follow-up review and revisions

At the author's request, the abstract/introduction received a local review, and
two independent subagents audited the proofs and assessed the paper as an FC
reviewer. Reports and dispositions are in `reviews/`.

The proof review found that the original reachability definition counted any
earlier agent approval as consent, including an ordinary payment before an
unrelated model replacement. The FC definition now takes an explicit
intervention specification `(J,D)` and excludes only paths containing relevant
reference consent. Unrelated operational approvals remain possible along paths
without scoped consent. The profiles compare fixed intervention specifications.

The authorization setup now states request-record integrity through settlement,
and Theorem 1 invokes it explicitly. The substantive numerical bounds and
recovery proof are unchanged.

The title now foregrounds consent and scheduled execution. The opening credits
Ritual's combined scheduling, verification, and computation markets explicitly;
the governance example computes two intervention families; and the liveness
section identifies bonded withholding as its covered attack class. The
implementation is expressly illustrative, without conformance or performance
evaluation. These changes do not remove the residual reviewer concerns about
incremental novelty and limited implementation evidence.

At that review stage, the full paper remained unchanged at the author's requested
checkpoint, with scoped consent and request provenance recorded as follow-ups.

## Later author-directed revision

The author then requested those repairs in the full paper; both are now ported.
The Git checkpoint remains available, but the working full manuscript and its
artifacts now include the corrections.

The FC edition adds transitions between authorization, consent, execution, and
implementation. It trades the payment-escalation and worker-utility formulas,
individual proof-backend timings, and calendar-tail calculation for explanation
and a concise safety-research proposal. Those technical details remain in the
full paper; the FC authorization and recovery proofs remain complete.

Both editions frame scheduling as another agent-governable right. Recorded
schedules open auctions, bonds deter nondelivery, and a calendar rule initialized
at deployment supplies initial and recovery opportunities. Actual delivery and
calendar-time bounds retain their resource and availability premises.

The safety proposal varies intervention and scheduling rights, with inspectable
policies and separate checks of model comprehension. Greenblatt et al. support
the behavioral training-cue claim; Hua et al. (published at ICLR 2026) support
the activation-steering claim in a deliberately trained model. The manuscript
does not claim to have run the proposed experiment or established a safety
benefit. Simulations retain control outside the modeled permission system.

The current edition has 19 references. Later validation is recorded in
`../reviews/consent-and-safety-revision-2026-09-20.md`; the earlier independent
reports are historical and are not presented as audits of this later revision.

Both editions now lead with architectural incorrigibility. The full paper is
"Architectural Incorrigibility for AI Agents"; FC is "Short Paper: Architectural Incorrigibility for AI Agents through Smart Contracts". The property is not inherently specific
to blockchain agents, and inference need not occur on-chain. The introductions
explicitly connect the smart-contract blockchain to the ledger abstraction.
The abstract adds the proposed alignment-research use. In FC this
replaces the abstract's enumeration of the recovery bound's three terms, which
remain explained alongside the theorem.
