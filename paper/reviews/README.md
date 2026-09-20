# Reader review and revision record

The latest author-directed changes are recorded in
[Consent, scheduling, and safety revision](consent-and-safety-revision-2026-09-20.md).
That revision ports the FC proof repairs into the full paper and adds a sourced
experimental-use proposal. It received local consistency and artifact checks,
not a new independent subagent audit.

**Version note:** These two rounds concern the version committed as `958aa6e`.
The later author-directed reframing and abstract review are recorded in
[authorization-revision.md](authorization-revision.md). The earlier reports and
resolution record below are retained as history.

Two review rounds were completed with three subagents, respectively reading as
an educated nontechnical reader, a software engineer, and an academic in formal
methods/access control. The primary editor also reviewed the full manuscript
through all three perspectives, checked the mathematical changes, and inspected
the rendered PDF. These are simulated reader reviews, not external peer review.

## Review files

- [Round 1: general reader](round1-general.md)
- [Round 1: engineer](round1-engineer.md)
- [Round 1: academic](round1-academic.md)
- [Round 2: general reader](round2-general.md)
- [Round 2: engineer](round2-engineer.md)
- [Round 2: academic](round2-academic.md)
- [Pre-review manuscript](before-self-review.tex)

The reports are preserved as written. Their requested final corrections have
been incorporated; an item in a report is not necessarily an outstanding issue.

## Editor's section-by-section review

| Passage | Nontechnical stopping point | Engineer's obstacle | Academic issue and revision |
| --- | --- | --- | --- |
| Abstract | The old version described research activities more clearly than the recovery conclusion. | The obstruction-budget premise was not apparent. | The final summary names availability, affordability, a minimum success chance, a minimum unrecoverable obstruction cost, and continuing attempts. It describes a probability bound, not a deterministic deadline. |
| Introduction | The fund example works; the roadmap needed findings. | The architecture's roles were understandable. | The contribution is described as an application of established tools and elementary probability. The distinction between behavioral cooperation and enforced authority remains explicit. |
| Section 2 | The first formulas are an acceptable stopping point, after the transfer and stored-data examples. | Partial functions, relation semantics, soundness, and request binding needed local explanations. | Update semantics remain separate from authorization. Verified approval is tied to a specified computation, not the executor's identity. |
| Section 3 | The reader can follow the permission table, indirect-route example, and repair dependency while skipping set notation. | Path supports and approval families previously arrived without a worked route. | The difficult issue was attribution across program/verifier changes. The analysis now fixes a reference agent relation, distinguishes edge labels from mutable predicates, and makes the proposition about restricted-graph reachability. Profile inclusion is a partial order; implementation comparison is a preorder. |
| Section 4 | The old section lacked an entry point. The new opening explains payment, deposits, and the conditional recovery result. | An unexplained auction and many parameters hid the mechanism. | The lifecycle precedes equations; the theorem uses one-based attempts and a success probability conditional on prior history and responsive selection before the outcome. The proof spends its space on this conditioning rather than routine algebra. |
| Section 5 | Hardware and proof details may lose this reader, but the opening now explains why costs and repair dependencies matter. | Attestation terminology and benchmark workloads needed explanation. | Equivalent verification alternatives can preserve availability without changing authority. The benchmark table still distinguishes measured forward passes, tokens, full sequences, and projections. |
| Section 6 | The labeled implementation observations supply the gist. | Contract-specific names are connected to earlier requirements. | The opening says source review makes the architecture concrete; it does not claim a new operational feasibility demonstration or general joint-governance implementation. |
| Section 7 | The three practical consequences can be scanned without following the literature. | The connection between design obligations is explicit. | Classical access-control safety now supplies the reachability lineage alongside monotone access structures and verifiable computation. |
| Conclusion | The conclusions can be stated without mathematical terminology. | Authority and execution conditions remain distinct. | The conclusion includes both the repair conflict and the possibility of improving availability through equivalent backends. |

## Substantive corrections

1. **Protected approval has a fixed reference.** A governor-installed program
   that always approves is not consent from the protected agent, even when its
   output has a valid computation proof. The program-change step retains its
   governor label. This fixes an actual ambiguity, not just terminology.
2. **A coalition cannot manufacture a computation's consent.** The proposition
   characterizes approval requirements along feasible paths. Computation
   feasibility is retained; conservative abstractions only bound authority.
3. **Profile comparisons use containment, not counts.** Different groups may
   have different powers even if their lists or coalition sizes are equal.
   A bilateral rule whose agent can never approve need not be distinguished
   from a disabled operation by feasible-path families; the text now says only
   that full families record feasible routes requiring approval.
4. **Recovery needs opportunities and a lower bound on obstruction cost.** The
   revised theorem starts after the first `m_*` failures, defines `T = infinity`
   when no success occurs, and permits nonresponsive winners to succeed. Only
   their failures must incur the stipulated net loss. The probability argument
   concerns post-threshold responsive attempts.
5. **Repair redundancy need not add authority.** Permanent dormancy requires
   permanent loss of the needed backend and no alternate repair route. An
   independent backend already accepted for the same relation can preserve
   availability without changing approval requirements.

## Exposition and length decisions

The editor consulted the primary texts of Harrison--Ruzzo--Ullman, Alpern--Schneider,
and Ekiden for construction and exposition as well as citation. The adopted
patterns are a continuing example before formal reachability, intuition before
property definitions, and a workflow before protocol details. The paper keeps
the simple reachability proof short, replaces the capped geometric closed form
with the directly meaningful bond-loss sum, and adds a numerical reading of the
recovery theorem. No extra theorem machinery or glossary was added.

Round 2 found no remaining structural comprehension gap for the engineer, and no
missing section/subsection orientation for the general reader. The academic
review accepted the revised formal core under its explicit assumptions and
requested only local clarifications. Those clarifications and the editor's
additional consistency fixes are incorporated in the final manuscript.

The numerical example is illustrative: a 10% offer increase reaches 3 from 1
after 12 misses; a loss budget of 100 and minimum loss of 20 permit five failed
adversarial opportunities; two responsive chances with conditional success at
least 0.9 give a failure bound of 0.01 by attempt 19. No empirical measurements
or machine-checked proof claims were added.

## Final artifact checks

The revised PDF compiles without warnings and has 12 pages, including 21
references. All pages were visually inspected, with affected pages rendered
again after layout changes. Citation keys and cross-references resolve; the
source bundle contains the current manuscript and all six reader reports.

## September 20 independent audits

- [Proof audit and repairs](proof-audit-2026-09-20.md)
- [Bibliography metadata, links, and chronology](bibliography-audit-2026-09-20.md)
- [Submission venue assessment](venue-assessment-2026-09-20.md)

These were performed by separate subagents at the author's request. The parent
reviewed and incorporated the proof and citation corrections, revised the final
discussion, and checked the rebuilt artifact. They are agent reviews, not external
human peer reviews or machine-checked proofs.
