# Consent, scheduling, and safety revision - September 20, 2026

This records the author-directed revision after the independent FC proof and
reviewer reports. It is a local editorial and consistency review, not a new
independent subagent audit or external peer review.

## Full-paper corrections

- Added a numbered request-record integrity invariant. Every eligible request
  at a reachable invocation must reconstruct from its retained provenance;
  its physical record remains immutable until consumption or invalidation.
  Theorem 1 assumes this invariant and invokes it at the reconstruction step.
- Added intervention specifications `(J,D)`: target states and transitions that
  grant relevant consent. Updated path consent, reachability, incorrigibility,
  and all profile indices consistently. An ordinary agent-approved payment
  before a unilateral model replacement no longer counts as consent to that
  replacement. The reference agent remains fixed across mutable governance.
- The checkpoint `edd18c2` remains in Git; the working full paper and artifacts
  now include these repairs as explicitly requested by the author.

## Framing and exposition

The FC edition adds transitions between authorization, consent, execution, and
implementation. It omits secondary payment formulas, benchmark timings, and a
calendar-tail calculation to make room. Its two formal proofs remain intact.

Both editions explain timing as another agent-governable right. The recorded
schedule opens auctions for replaceable workers; bonds mitigate nondelivery;
a calendar rule initialized at deployment supplies initial and recovery
opportunities without needing a fresh agent decision. Actual attempts, ledger
access, funding, responsive participation, and timing bounds remain premises.

The full title is now **Architectural Incorrigibility for AI Agents**. The FC
title is **Short Paper: Architectural Incorrigibility for AI Agents through Smart Contracts**.
The concept is not inherently specific to blockchains. This construction uses a
smart-contract blockchain, explicitly introduced as the source of the formal
ledger abstraction. The titles do not suggest inference itself occurs on-chain.

Both abstracts mention the proposed alignment-research use. In FC this replaces
the abstract's enumeration of the three recovery-bound terms, which remain
explained beside the theorem.

## Research claim and sources

Greenblatt et al. (2024) motivate the behavioral training-cue claim. Hua et al.
(ICLR 2026) motivate the activation-steering claim in a deliberately trained
evaluation-aware model; the published proceedings version is cited. Neither
paper tests this architecture or establishes an effect of reduced operator power.
Primary links and claim boundaries are recorded in `../SOURCE_NOTES.md`.

The proposed experiment varies intervention and scheduling permissions while
holding model and tasks fixed, exposes inspectable contract evidence, and
compares enforcement with description-only controls. It checks policy
comprehension separately from behavioral or activation changes. A proof of
enforcement does not establish model understanding. Simulations retain outside
operator control, and restricting a canonical runtime does not prevent humans
from training other copies. No new behavioral result or safety benefit is claimed.

## Artifact validation

- Full paper: 25 pages, bibliography on pages 24-25, all 33 references cited.
- FC: eight main-text pages and two bibliography pages, all 19 references cited.
- Both final LaTeX logs have no warnings, unresolved references, or overfull or
  underfull boxes. The full build's first pass briefly reports a sub-point box
  overflow while cross-references are unresolved; the final pass is clean.
- Citation keys and cross-reference labels resolve, with no duplicate labels.
- Final PDF pages were rendered and inspected; affected pages were rechecked
  after later title and abstract edits.
- FC title block and metadata remain anonymous. Its LNCS class and bibliography
  style match the official publisher files byte for byte; no layout compression
  or appendices were introduced.
- Source archives contain the current manuscript and bibliography. The FC
  archive excludes repository notes, review reports, and agent instructions.

No submission, deployment changes, new experiments, or new commit were made.

The subsequent title/abstract wording pass adds "for AI Agents" to the FC title
and uses the author's "testing model alignment and behavior" phrasing in both
abstracts. The FC running title is abbreviated to fit the standard header.
