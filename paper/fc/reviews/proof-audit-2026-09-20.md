# Independent FC proof audit — September 20, 2026

Scope: `paper/fc/main.tex`, read independently before comparison with the full
manuscript and its earlier audit. This review covers the computation and ledger
experiments, authorization reduction, governance definitions and profile order,
and the adaptive recovery proof. No manuscript files were edited. Line numbers
refer to the FC draft as first read; revisions can move them.

## Assessment

The authorization reduction and recovery inequality are mathematically correct
under the intended request-provenance invariant and the explicitly stated
stochastic premises. Condensation preserved the essential exact-simulation,
conditional-probability, and null-set arguments. I found one substantive mismatch
between the governance definition and intervention-specific consent, and one
request-invariant clarification needed to make the authorization proof's premise
unambiguous. Neither requires changing a numerical bound.

## 1. Scope consent to the intervention being protected

**Priority: substantive definition/interpretation issue. Locations: 142–170,
especially 154–159.**

The current `Reach^0` excludes every path containing any reference-agent
authorization. Therefore any earlier operational approval can establish the
defined incorrigibility, even when it says nothing about the protected
intervention. The mathematics of the stated definition is consistent; it is the
claimed connection to intervention consent that is too strong.

For example, take three states `s0, s1, sbad`, one governor `g`, and target
`J={sbad}`. The only transitions are

```
s0 -- ordinary payment, E=empty, b=1 --> s1
s1 -- replace model, E={g}, b=0 --> sbad.
```

For coalition `{g}`, `Reach^0(s0;{g})={s0}`, so the current definition declares
the instance incorrigible at `s0` for model replacement. Nevertheless the agent
authorized only a payment; the governor can then replace it unilaterally.
The existing sentence about consent to delegation does not cover this example:
there was no delegation.

### Recommended compact repair

Use an explicit intervention specification `(J,D)`, where
`D subseteq S x U x S` is a declared consent scope. Reference authorization of
a transition in `D` approves the protected intervention or delegates the right
to perform it. The governance specification supplies `D`; the analysis does not
infer an intention or a causal authorization scope from arbitrary model output.

For a labelled transition `s --u,E,b--> s'`, define

```
b_D = b * 1[(s,u,s') in D].
```

Define `Reach^0_D` using paths whose scoped bits are all zero, and replace the
incorrigibility condition by `Reach^0_D(s0;K) intersect J = empty`. Importantly,
ordinary agent-authorized actions outside `D` are allowed on these paths. Thus
the example above has a path to `J` without scoped consent and is correctly
classified as unprotected.

Profiles should be indexed by fixed pairs `(J_j,D_j)` and compared using the
same reference agent, governor identities, target meanings, and environmental
semantics. Upward closure and reverse componentwise inclusion remain valid:
enlarging a coalition preserves every witness path, regardless of its scoped
bits.

Retain the precise limitation: the property is relative to its initial state
and permits scoped consent somewhere on the path, including an expressly
specified delegation. It does not require a fresh authorization at every
later use of a delegated right. Broadly choosing `D` to contain unrelated
operations would weaken the specification again, so at least one sentence
should say that ordinary operational approvals do not count as model-change
consent.

A local invariant quantified over every reachable state is another possible
definition. It is less suitable for this short edition because explicit
delegation would then require modelling when a protection is released or
re-established. The `(J,D)` repair preserves the intended initial-state
reachability framework with less machinery.

## 2. State the request-provenance invariant at settlement, not only creation

**Priority: formal-interface clarification. Locations: 61, 92, 98, 102, 125.**

Line 125 uses the fact that every successfully settled request reconstructs to
matching full contents. Line 98 says that request creation uses registration
and snapshot procedures, but it does not explicitly state that later state
updates preserve those contents and their provenance while a request remains
eligible. `Apply` is otherwise an arbitrary partial state update.

If “a request fixes” at line 61 already means immutable outstanding request
contents, this is a clarification of an intended premise. Under a literal
reading that permits record mutation, it is needed for the theorem:

1. Register request `e` with model `theta0` through the prescribed procedures.
2. A permitted update changes its physical model commitment to `H(theta1)`
   while leaving the same request eligible and retaining its old provenance.
3. Submit valid evidence for `theta1` and the new physical record.

The ledger and contract can execute every specified check correctly, and no
invalid computation is proved. Nevertheless `Req` returns failure because the
registered `theta0` does not match the physical record. `Correct` is false,
giving an authorization win that is not a computation forgery. This is not a
hash collision or a cryptographic attack; it is an omitted record invariant.

**Minimal repair:** after the journal paragraph, state that every eligible
request at every correctly executed reachable invocation retains matching
registration and snapshot provenance. Changes either pass through the same
registration mechanism or invalidate the outstanding request. The proof can
then explicitly invoke this invariant when concluding `Req != bottom`.
This need not put full model contents on chain or add a ledger-security term.

## Checks that passed

### Computation interface and commitments: 61–84

- Program, input, randomness, domain, request identifier, version, and output
  are bound by the message and ledger record. Worker-selected expected hashes
  are not silently trusted.
- The forgery experiment concerns the actual supplied contents, not merely
  the existential validity of some hash opening. The omitted full-paper
  extraction lemma has been replaced by an explicit backend assumption and
  an accurate explanation of why knowledge soundness is relevant.
- Collision resistance alone is not described as mathematical injectivity.
- The public proving and protected-attestation cases have a common oracle
  interface. Valid copied or publicly generated proofs are not forgeries.
- Fixing randomness prevents resampling only for a unique specified output;
  the draft correctly retains this qualification and permits withholding.
- Polynomially bounded interactions are distinguished from polynomial-time
  decidability of the semantic output relation. This distinction matters to
  the general theorem's `Q` factor.

### Ledger and authorization experiment: 89–110

- The required ledger predicates are self-contained. No inclusion/liveness
  property is accidentally imported into the authorization theorem.
- Deterministic state execution includes the consensus execution context.
  Atomic update plus permanent consumption supplies application replay
  protection, conditional on the stated contract implementation.
- The registration journal is passed to reconstruction and replay, and
  branch/invocation provenance prevents merging different registrations by
  request number alone. Reconstruction does not require a preimage search.
- Physical ledger execution and ledger safety remain journal-independent.
- Initialization and transition algorithms give the VC reduction an
  executable simulation interface. Backend secrets remain behind its
  forwarded evaluation oracle.
- The fixed-contract/verifier scope is stated before governance is discussed.
  The paper does not claim that Theorem 1 automatically survives arbitrary
  verifier upgrades.

### Authorization proof and `Q`: 114–134

- Subject to finding 2's invariant, a bad settlement on a safe ledger has an
  accepted false computation tuple in replay. No relation-membership test is
  needed to establish this event inclusion mathematically.
- Duplicate replayed invocations do not hurt the argument; they only affect
  the polynomial bound on the record list.
- The uniform index is independent of the simulated execution. Padded indices
  lose, giving exactly `E[|I(Z)|/Q]` rather than only an unexplained union
  bound.
- Every ledger query uses the same algorithms and every evaluation query is
  forwarded. Equality of distributions is exact. A hybrid game would add
  notation without repairing or strengthening any argument here.
- The identity ledger adversary has the same setup and oracle distribution.
- If output correctness is polynomial-time decidable, choosing the first
  invalid accepted tuple removes `Q`. Determinism is sufficient only when the
  program can be recomputed in polynomial time; it is not necessary.

### Governance mathematics: 137–170

- The reference authorization specification remains fixed when policies or
  implementations change. Replacement-model approval does not automatically
  count as the original agent's approval.
- Credentials actually used, rather than arbitrary attached evidence,
  determine transition labels.
- Reachability is existential and is not presented as an adversarial
  strategy that forces agreement or controls transaction order.
- The length-zero path and `s0 notin J` convention are consistent.
- Coalition families are upward closed, and reverse inclusion is a partial
  order on profiles, not on syntactically distinct circuits or systems.
- Targets unreachable even with consent are correctly identified as a
  vacuous protection case.
- Comparisons should expressly fix governor identities in addition to the
  other listed comparison parameters; the scoped-profile repair is a natural
  place to include those two words.

### Recovery theorem and proof: 175–216

- The worker utility expression is algebraically correct under the stated
  payment, expected cost, forfeiture, and capital-cost model. It proves
  affordability only, not participation or selection.
- The process requires actual attempts until success. It does not invent
  probabilistic opportunities after auction/ledger advancement stops.
- On an unsuccessful prefix, the pathwise budget bounds nonresponsive
  failures by `floor(W/d_min)`, leaving at least `n` responsive selections.
- Each `tau_j` is selected using pre-outcome history. On
  `E_(j-1) intersect {tau_j=i}`, earlier selected outcomes and the selection
  at `i` are measurable in `F_i`, so the conditional-expectation identity is
  justified. No independence or optional-stopping hypothesis is missing.
- The common probability-one event is used correctly in the counting
  inclusion. Its null complement contributes no mass to the conditional
  expectation inequality.
- The base case `E_0=Omega`, induction, and final inclusion give the stated
  tail inequality, including `p=1` and zero attacker budget.
- Taking the tail limit gives eventual success with probability one under
  these premises. The calendar-time statement needs, and states, an upper
  bound that includes spacing between attempts.
- Recurrence is not silently inferred from single-episode recovery. The
  draft explicitly requires the premises again after each success.
- Empty auctions, censorship, unavailable inputs, refundable adversarial
  deposits, and finite funding are identified as ways the theorem's premises
  can fail. No unconditional schedule or anti-censorship result is proved.

## Recommendation

Repair the scope of intervention consent and make the eligible-request
provenance invariant explicit. Keep the numerical bounds and direct proof
strategy. Further proof compression is not advisable: the event inclusion in
Theorem 1 and the pre-outcome measurability step in Theorem 2 are the parts a
reader needs to see, and they have survived the distillation intact.

## Post-revision verification

I re-read only the two repaired interfaces and their consequences in the revised
FC manuscript, without repeating the unrelated proof audit.

**Request-record integrity — resolved (98, 115, 125).** The experiment now
requires matching provenance for every eligible request in a correctly
reachable state and immutability of the physical record until consumption or
invalidation. Theorem 1 explicitly assumes that condition. Its proof invokes
it after obtaining eligibility from contract correctness, so a bad settlement
on a safe ledger can fail only computation correctness. The earlier permitted
record-mutation counterexample is excluded by an explicit assumption, rather
than silently assigned to ledger or computation insecurity. The exact
simulation and probability bound need no alteration.

**Intervention-scoped consent — resolved (150–168).** The intervention
specification supplies `(J,D)`, and a path is excluded from `Reach^0_D` only
when it contains a reference authorization on a transition in `D`. The ordinary
payment in the earlier counterexample is outside `D`, so it no longer hides
the subsequent unilateral model replacement. Profiles consistently use the
scoped coalition families and hold the reference agent, governors, intervention
specifications, and environment fixed. Upward closure and the partial order
therefore survive the change.

**Worked migration example — correct under its stated closed-model intent
(170).** Taking model replacement and migration as the scoped operations,
governor-only replacement followed by replacement-model migration yields the
coalition family `{{G1}}`. Requiring reference consent for replacement instead
leaves no path to migration without scoped consent, yielding the empty family.
Ordinary payments cannot affect these conclusions because the example excludes
them from changes to migration rights and from the consent scope.

One small wording clarification is recommended before treating the first exact
family as fully specified: replace “If G1 can replace the model” by “If model
replacement requires only G1's approval.” Ability alone does not logically
exclude an additional approval-free replacement route; the latter wording
states the intended permission rule directly. This is a local precision issue,
not a defect in the repaired definitions.

### Remaining scope limitations, not defects

- The supplied scope `D` determines which authorizations count as consent to
  the particular intervention. The definitions do not infer a model's intent
  or verify that this supplied scope is appropriate for a deployed contract.
- The property remains relative to the initial state and permits an expressly
  scoped delegation to satisfy the consent requirement for later uses. It is
  not fresh approval of every action after delegation; the text says so.
- The authorization reduction still assumes a fixed contract and verifier
  plus request-record integrity. The governance model does not by itself prove
  a deployment or upgrade preserves those premises.

No numerical bound or unrelated proof step needs revision as a consequence of
these repairs.
