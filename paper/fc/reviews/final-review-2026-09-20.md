# Final skeptical FC review — September 20, 2026

Scope: independent, read-only review of `paper/fc/main.tex` and
`paper/fc/references.bib`, following both applicable `AGENTS.md` files. Line
numbers refer to the manuscript before this review's suggested edits. I first
checked the current arguments, then compared the earlier review reports. I did
not audit the deployed contracts or independently revalidate every bibliography
URL. No manuscript edits were made.

## Disposition

**Submit as a carefully scoped short paper. No new correctness blocker found.**
The argument is coherent and appropriately qualified. The main rejection risk is
that the combination of familiar techniques does not deliver enough new insight
or demonstrated utility, rather than that a reduction or probability calculation
is wrong. Another round of generic polishing is unlikely to change that risk.

I would describe the draft as **borderline / weak reject on novelty, potentially
weak accept for a reviewer who values the governance formulation and clear
separation of authorization, consent, and execution availability**. A subjective
acceptance estimate is roughly **20–35%**, not a measured venue acceptance rate
or a calibrated forecast. It is worth submitting if the author is comfortable
with substantial rejection risk. I would not delay submission for more model
experiments or claim that those experiments validate the architecture.

## Prioritized actionable findings

### 1. Make the contribution sentence match the different kinds of result

**Minor precision edit; recommended. Location: main.tex:55.**

“We specify three separate guarantees” is stronger than the result types that
follow. Authorization and recovery are theorems under stated premises; scoped
consent is a property of a supplied governance transition model, illustrated by
a small example. No theorem establishes that the illustrative implementation
has that property. Section 3 says this correctly at line 168, but the reader
should not have to repair the introductory impression later.

Concrete fix: replace the relevant clause with “Our analysis separates
authorization integrity (Section ...), scoped consent to intervention (Section
...), and recovery from costly withholding (Section ...).” Keep the surrounding
positive contribution statement and prior-art credit. This is not a request for
another theorem.

### 2. The bridge from forfeiture to the recovery premise remains an application risk

**Not a proof blocker; optional small clarification. Locations: 173–177,
187–190, 214–216.**

The theorem correctly assumes a positive *net unrecoverable* adversarial loss
for each covered nonresponsive failure. A forfeited bond realizes that premise
only if the coalition cannot recover it through a refund, reward, or recipient
it controls. Nor does forfeiture supply an eligible responsive bid or inclusion
of a settlement transaction. The current qualifications are accurate, and the
proof does not smuggle in these conclusions.

A reviewer can nevertheless fairly ask what the market construction establishes
beyond a finite-loss counting argument. If one short sentence fits, tie the
covered mechanism directly to the assumption: “For bonded withholding, the loss
premise requires missed-job penalties that the obstructing coalition cannot
recover; continued auctions and responsive settlement remain separate
premises.” This is an explanatory mapping, not a new implementation claim. Do
not add an unsupported claim that the existing deployment establishes it.

### 3. Preserve the modest implementation and AI-safety scope

**No edit required; submission constraint. Locations: 41, 219–226.**

The exact model/platform identifiers are useful, but they are not evidence that
the complete execution path satisfies the abstraction. The explicit sentence
that conformance and performance remain unevaluated is therefore essential.
The statement about CPU attestation not certifying unprotected accelerator
execution also belongs. A measured end-to-end conformance trace would strengthen
a subsequent systems paper; it is not something that can be supplied by prose
or configuration values at this stage.

The AI-safety paragraph currently proposes a research setting and asks an open
question. It does not report a behavioral result or an improvement in alignment.
That is appropriate after the pilot/diagnostic failed its go/no-go gates. Do not
add the isolated persona reversal as supporting evidence, and do not convert
the negative diagnostic into a claim about operator permissions: the control
failures prevent that interpretation. The proposed enforced-policy study is a
larger research question than those exploratory simulations answered.

## Correctness checks

* **Authorization (61–134):** the verifier message binds the recorded program,
  input, randomness, domain, version, and output. Request-record integrity is
  explicitly maintained through eligible invocations, not merely registration.
  The retained journal supplies full contents to the reduction without requiring
  hash inversion and is not a trusted component of physical ledger execution.
  On a safe ledger, a bad successful settlement yields a false accepted
  computation tuple. Uniform selection from a polynomially padded replay list
  gives exactly the stated `Q` loss. Deciding the semantic relation is not needed
  by that reduction. The tighter decidable case is stated accurately. No hybrid
  game is missing.
* **Governance (137–170):** a fixed reference specification prevents an upgraded
  model's authorization from automatically becoming original-agent consent.
  The intervention scope excludes unrelated earlier approvals from counting as
  consent. The property remains relative to the declared scope: a careless broad
  scope would be a bad specification, not a theorem establishing meaningful
  consent. Coalition families are upward closed and reverse componentwise
  inclusion is a partial order on profiles. The closed-model example supports
  its two stated profiles. Existential reachability is not confused with an
  adversarial strategy, and unreachable targets are explicitly acknowledged.
* **Recovery (179–216):** the pre-outcome filtration makes responsive selection
  measurable. The selected-failure recursion uses a conditional success bound,
  not independence. The probability-one event is carried through the counting
  inclusion. The pathwise budget bounds costly nonresponsive failures, leaving
  the required responsive opportunities. The tail bound and probability-one
  eventual success follow. Funding, actual continued attempts, and bounded
  calendar timing are distinct premises; recurrence is not inferred for free.

## Likely reviewer critique and the honest response

The strongest objection is: “Verification composed with a state machine is
standard; intervention prevention is access-control reachability; finite-cost
obstruction plus a conditional success rate yields a routine tail bound. What is
new?” The honest answer is the **application-level formulation and separation of
these guarantees for consent-protected agent operation**, especially fixed
reference identity, intervention-scoped consent, and comparisons of governance
allocations. This is a modest short-paper contribution, not a new cryptographic
primitive or a demonstrated generally live autonomous system.

Rocky and Ritual are credited for relevant overlap in the introduction. The
draft does not assert unverified deficiencies in either system or claim to be
the first proof-authorized agent. Keep that positive framing. The presence of
precedents is not itself disqualifying, but a reviewer who expects either a new
primitive or a validated system may still reject the paper. Adding more basic
lemmas, more notation, or a “first” claim would not solve that problem.

The current proof detail is proportionate for an FC audience. The formal
bookkeeping is dense, but the journal's purpose and each section's question are
introduced before the mathematics. Further compression of the two proofs would
save space at the cost of the steps reviewers actually need to inspect.

## Final recommendation

Make the single introductory precision edit, optionally add the brief
bond-to-loss explanation if it improves flow without crowding the page, then
freeze the intellectual scope and proceed with venue/format/anonymity checks.
No new behavioral experiment is needed to justify submitting this manuscript
with its current, explicitly proposed alignment-research use case.
