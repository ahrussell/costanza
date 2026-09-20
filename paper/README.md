# Architectural Incorrigibility for AI Agents

`main.tex` and `references.bib` are the editable manuscript. The compiled paper is
`../output/pdf/architectural-incorrigibility.pdf`.

The separate [FC short-paper edition](fc/README.md) was submitted to FC 2027
on September 20, 2026. Its source and compiled PDF are preserved separately.

`AGENTS.md` records the author's writing conventions for future revisions:
formal proof blocks with explicitly named objects and reductions, intuition
outside proofs, and self-contained definitions with accessible section openings.

Build from any directory:

```sh
bash paper/build.sh
```

The script accepts Tectonic or a TeX installation with `latexmk` and BibTeX.
To use a particular Tectonic binary:

```sh
TECTONIC=/path/to/tectonic bash paper/build.sh
```

Tectonic downloads its packages on its first run. The initial build for this draft
used Tectonic 0.17.0, downloaded to `/tmp/costanza-latex/tectonic`; that temporary
path may not survive a restart. No system TeX installation is required if a
Tectonic binary is supplied. Build intermediates go to `../tmp/pdfs/build/`.

The author field is intentionally blank for the author to finalize. The article
format is venue-neutral. Literature and publication metadata were checked through September 20, 2026.

## Scope

The paper presents verified inference as agent authorization without an agent-held
private key, a reduction of authorization forgery to ledger and computation
security, configurable self-modification permissions, and a conditional recovery theorem for scheduled
execution against costly obstruction. It does not claim an auction equilibrium,
perpetual operation, a new proof system, machine-checked proofs, or a new empirical
evaluation. The contribution concerns the full architecture; the Hermes 4 70B,
Base, and Intel TDX implementation illustrates its execution flow. The paper does
not infer retained deployment permissions from functions present in source code.
The authorization analysis gives explicit security games and a separate reduction
for hashed proof statements using knowledge soundness and collision resistance.
Its term is "verified agent authorization", not "agent signature". AuthForge is a
numbered definition, parameterized by the ledger, authorization state machine, and
verification scheme. It makes no worker-market or governor-role assumptions.
The authorization state machine is a numbered definition separating settlement
from its validation predicate, instantiated first by a signature check and then
by computation verification. Both authorization and ledger experiments use explicitly defined initialization,
protocol-transition, and replay algorithms, with an explicit full-content
registration journal, typed execution records, and
winning predicates. Theorem 1 uses an exact simulation rather than a hybrid game. Its general
reduction retains the verification-call factor Q; a separate corollary removes
that loss when correctness of an output can be decided in polynomial time.
Ledger histories, finalized observations, agreement, persistence, and execution
validity are defined in the main text, alongside the contract-correctness premise.
Request-record integrity is an explicit invariant, preserved through settlement.
Governance is modeled as a labelled transition system, distinguishing reachable
states from those reachable without reference-agent consent to the specified
intervention. Incorrigibility is defined relative to an instance, initial state,
governor coalition, and intervention specification `(J,D)`: target states and
transitions that grant relevant consent. Ordinary agent approvals outside that
scope do not count. Profiles compare the coalitions that retain intervention
paths without scoped consent.
The liveness model defines the probability space, pre-outcome histories,
selection and success indicators, and net adversarial losses. The proof derives
its count from the total-loss budget and conditions on each responsive selection.
A separate corollary proves the calendar-time and recurrence consequences under
their additional assumptions.
Rocky is credited as prior art for verified inference directing transactions;
the comparison focuses on self-modification policies and the execution market.

`SOURCE_NOTES.md` records the evidence behind implementation and benchmark claims
and explains material departures from the whitepaper. These notes are for editing
and are not included in the paper.

`reviews/README.md` records two rounds of reader reviews and their resolutions.
The six individual reviews and the pre-review manuscript are retained there for
comparison; none are included in the compiled paper.

The subsequent author-directed revision is recorded in
`reviews/authorization-revision.md`. The earlier reader reports describe the
previous version; their final page counts and emphasis are historical.

The September 20 audit reports cover [proofs](reviews/proof-audit-2026-09-20.md),
[all bibliography entries](reviews/bibliography-audit-2026-09-20.md), and
[submission venues](reviews/venue-assessment-2026-09-20.md). The venue assessment
is advice, not a submission or an acceptance prediction. The conclusion now
discusses operational agency and the AI-safety implications of enforced consent.

The later [consent, scheduling, and safety revision](reviews/consent-and-safety-revision-2026-09-20.md)
ports the FC audit's two substantive corrections into this manuscript. It also
proposes studying behavior under different intervention and scheduling rights,
with separate checks of model comprehension. Scheduling authority can belong to
the agent; auctions recruit workers, bonds deter nondelivery, and a calendar rule
bootstraps execution and enables recovery. This revision follows the historical
checkpoint `edd18c2`; that checkpoint remains available in Git.
