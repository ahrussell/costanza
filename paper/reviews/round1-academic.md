# Round 1: specialist academic review

Reviewed `paper/main.tex` as it stood at the beginning of the self-review round. Scope: formal methods, authorization, distributed-systems liveness, and proof exposition. No manuscript edits made. The mathematical ideas are tractable; the principal problem is that the identity of an approval source changes silently between the computation model and the reachability model. The liveness bound is sound under its stated strong hypotheses, with a few useful indexing and conditioning repairs.

## Required repairs, in priority order

### 1. Fix what counts as agent approval throughout a governance path

Sections 2.2–2.3 define agent approval as successful verification under the current specification and verifier. Section 3.2 instead says that a governor-installed vacuous verifier supplies no agent approval. Those are different semantics. The discrepancy also occurs without a bad verifier: a governor can replace the model by a constant-output program that approves a treasury migration. A perfectly sound proof of that new program is not independent consent from the original agent. If the final transition still gets label `A`, the external treasury-intervention profile misses the governor-only path.

Use a fixed reference for each analysis. Suggested text:

> For each intervention analysis, fix a reference agent approval relation in the initial configuration, including its specification and request-binding rules. The label A records a fresh approval satisfying this relation that the transition actually requires. Evidence accepted only because a governor changed the program, parser, or verifier does not count as A unless it still establishes that reference approval. The new computation remains an execution precondition; the authority that enabled its acceptance is recorded by the earlier transition labels.

Then give the exact two-step example: governor G1 installs a constant-approval program; execution of that program migrates the treasury. The supports of the two steps are `{G1}` and the empty set, so the path support is `{G1}`. This is a more informative example than verifier replacement alone because it shows that correct computation and independent consent are different properties.

This convention does not need a full successor-agent identity theory. A path in which the reference agent approves its own replacement already contains A; its later steps cannot make that path governor-only. A later, separate assessment can choose the successor as its reference. Do not claim that the fixed-reference analysis measures every possible notion of identity through arbitrary updates.

State at the transition-graph definition that labels are mapped to these fixed reference sources. Do not merely reuse the mutable contract's Boolean variable named `a` after a reconfiguration.

### 2. Do not say a coalition can freely supply a computed agent approval

The proposition currently says a coalition uses approvals it “controls,” and the converse says it “supplies” its selected approvals. This is conventional for signing-key coalitions, but A is a constrained computation. Being in `{A,G1}` does not make the reference program accept a particular update.

Use a standard restricted-graph formulation and make the claim about required approval sources:

> For a set C of approval sources, retain precisely those transition alternatives whose required approval set is contained in C. Then C belongs to the effective approval family for J exactly when J is reachable in this restricted graph.

The graph must retain the actual non-authorization preconditions, including realizability of any required computation output. For a conservative graph that ignores some such preconditions, the result is an upper bound on intervention authority. The proof is simply: a restricted path has each label contained in C, hence its union is contained in C; conversely, a path whose union is contained in C uses only retained edges. There is no need to assert that C can compel A to approve.

Call this an approval-requirement characterization or authorization-reachability characterization. Keep the distinction between existential reachability and forcing an intervention against a scheduler. This is where the specialist most needs a precise convention, not more proof algebra.

### 3. Inclusion gives a partial order on profiles, not on implementations

Section 3.2 says “This order is partial” after defining a comparison of systems. Distinct implementations can have equal profiles: the manuscript itself gives bilateral and disabled operations with the same external family. Antisymmetry therefore fails for systems.

Exact repair:

> Componentwise inclusion is a partial order on intervention profiles. It induces a preorder on implementations: different systems may have the same profile.

The incomparable G1-only and G2-only examples are good. Preserve them. The external-family/full-family distinction is important and already correctly explained.

### 4. Attribute reachability to access-control safety analysis

The nearest prior formal construction is not only monotone secret-sharing access structures. It is the classical access-control safety question: whether a subject can acquire a right through a sequence of administrative commands. Cite Harrison, Ruzzo, and Ullman, *Protection in Operating Systems*, CACM 19(8), 461–471, 1976, DOI 10.1145/360303.360333. [Primary paper](https://www.cs.unibo.it/~babaoglu/courses/security07-08/resources/documents/harrison-ruzzo-ullman.pdf).

Their Section 3 introduces configurations and transition closure, interleaving definitions with a concrete ownership example; Section 4 asks whether a right can leak along a computation. This is the right structural precedent. Say that the paper applies this style of analysis to reference-agent consent and ledger governance. Avoid presenting permission closure itself as an original primitive. The finite-graph propagation algorithm is valid, but is not a general algorithm for arbitrary smart-contract programs; a sentence limiting it to an explicit finite abstraction suffices.

### 5. Tighten, rather than lengthen, the liveness theorem

The budget-counting plus history-conditional tail argument is correct. It correctly avoids an independence assumption. The strongest hypothesis is the exhaustive selection assumption: after escalation, every failed opportunity either gives a responsive worker a chance or charges a bounded-budget adversary. Rewards and bonds alone do not derive that hypothesis.

Suggested repairs:

- Say before the theorem, in ordinary language: if each obstruction spends money that the adversary cannot recover, only finitely many opportunities can be obstructed; thereafter repeated genuine opportunities yield the geometric tail.
- Define attempts as one-based or zero-based. The clean one-based statement is: after the first `m_*` failed attempts, the bid is feasible beginning with attempt `m_*+1`. This matches the displayed bound and the `p=1` conclusion.
- Make explicit that the theorem assumes enough opportunities occur to reach every finite horizon under discussion. An attempt bound does not by itself bound calendar time or produce the next transaction.
- Write the success lower bound as conditional on the history **and selection of a responsive worker**, with selection fixed before its delivery outcome. This avoids silently conditioning on an event defined using the eventual outcome.
- Use `0 < p <= 1`. Either state the inequality for `n >= 1` or declare the `n=0` bound to be 1, avoiding the irrelevant `0^0` corner at `p=1`.
- In the recurrence consequence, say that the hypotheses hold conditionally after **each** success and that opportunities continue. Each next-success time is finite almost surely; a countable union of zero-probability failures gives recurrence. This two-sentence argument is sufficient.

The bound on cumulative escalating bonds is correct, including the case where the ceiling is below the nominal initial bond. The notation `(k-h)_+` is not defined; define it as `max{k-h,0}`. The fixed profitable bid must remain feasible under all bonds reached in the episode, since the utility threshold depends on bond loss and liquidity. The theorem's current persistent-worker assumption is intended to cover this; state it plainly when introducing the fixed bid.

### 6. Qualify the repair deadlock exactly

The hitting-set identity is correct. For a complete repair target, explicitly use minimal supports from the effective reachability family, rather than implying that an arbitrary complete plan is a one-step operation. Non-authorization feasibility is held fixed in this identity.

The example should say that the backend **remains** unavailable. A temporary outage does not imply permanent dormancy. Suggested conclusion:

> While that backend remains unavailable, no new reference-agent approval can be produced. If every repair path requires such an approval and none was issued in advance, authorized repair is blocked; permanent loss of the backend then makes the dormancy permanent.

“Adding an independent backend changes the intervention profile” is too categorical. A backend that proves the same relation can improve execution availability while leaving approval coalitions unchanged. Emergency governor authority does change the profile; equivalent-verifier redundancy need not. This is a useful positive design distinction, not just a caveat.

## Section-by-section reader audit

| Section | Where the academic reader slows or loses the model | Repair |
|---|---|---|
| Abstract | The motivation and intended result classes are clear. “Recovery” is not yet linked to finite obstruction cost. | Name that premise in one short clause; avoid packing more notation or backend detail here. |
| Introduction | Clear distinction between behavioral and architectural corrigibility. The paper's mathematical contribution can appear larger than its actual elementary characterization. | Describe the contribution as an analysis/framework with conditional bounds, not a new authorization theory. Keep the concrete fund example. |
| 2.1 | `Apply` is a familiar state-machine abstraction. Separation of effect and authority is good. | No major repair. A no-op can still settle/pay; remind the reader later that accepted execution and application effects differ. |
| 2.2 | General relation and commitment interface are conventional. “Verification establishes approval” becomes ambiguous under replacement. | Introduce the reference/current-predicate distinction needed for Section 3. Exact bit-level proof-security definitions are unnecessary for this architecture paper. |
| 2.3 | Treating A as a principal suggests key-holder discretion it does not have. | Say “approval sources” when forming the finite set; explain that A is a verified decision source. |
| 2.4 | Assumptions are clear and appropriately explicit. | Preserve the conditional model; do not add a long list of hypothetical trust failures. |
| 3.1 | Arbitrary Boolean predicates are not literally equivalent to monotone families. | Define a coalition as permitted to submit any subset of its approvals, or explicitly restrict to monotone policies. “Additional approvals may be ignored” is the right convention but should be part of the definition. |
| 3.2 | This is the only section where a specialist can currently lose the intended semantics: mutable A identity, coalition control of a computation, and system/profile order. | Apply repairs 1–4. Spend explanatory space on the replacement example; compress the tautological closure proof. |
| 3.3 | The mathematics is immediate, but relating hardware failure to unavailable approval is useful. | Apply repair 6. Keep one worked repair example. |
| 4.1 | Three notions of progress are useful, but arrive before a section-level explanation of why money is needed. | Add a short section opening connecting absence of authority to lack of willing execution. Define “useful” as application-dependent if retained. |
| 4.2 | The utility calculation and ceiling rule are easy but parameter-heavy. | Introduce the economic question before equations. A fixed viable bid is an assumption about the episode, not a conclusion from the reward schedule. |
| 4.3 | Proof idea is simple; hypothesis bookkeeping is harder than the proof. | Lead with budget depletion + repeated chance. Keep the history-conditional step explicit; avoid expanding elementary arithmetic. |
| 4.4 | Good use of sunk cost; finite-resource observation is accurate. | Define the outside benefit as incremental relative to delivery, as currently done. Keep the proof-free finite-resource observation brief. |
| 5 | Backend comparison is appropriately careful but can read like a separate survey. | Open with its role: which mechanisms can supply the same approval relation, and what availability/cost they impose. State clearly that alternate equivalent backends need not change authority. |
| 6 | Source-level scope is honest; bullet observations substantiate earlier distinctions. | Tie each observation to the corresponding definition or theorem assumption, avoiding generic claims about implementation maturity. |
| 7 | Missing classical access-control safety lineage makes the permission closure sound newer than it is. | Add HRU alongside Benaloh–Leichter and describe the synthesis accurately. |
| 8 | The conclusion is concise and faithful apart from the undefined approval reference. | State the strongest claim as absence of paths bypassing the designated/reference agent approval. |

## Primary examples consulted for construction and exposition

- [Harrison–Ruzzo–Ullman](https://www.cs.unibo.it/~babaoglu/courses/security07-08/resources/documents/harrison-ruzzo-ullman.pdf): relevant for administrative-command transition systems, reachability, and the choice to interleave definitions with one continuing example. This manuscript can use the same pattern without adopting their full access-matrix formalism.
- [Alpern–Schneider, *Defining Liveness*](https://www.cs.cornell.edu/fbs/publications/DefLiveness.pdf): opens each property class with intuition and examples, then formalizes it and explains the two important consequences of the definition. That pattern suits Sections 3 and 4 better than successive equation-first subsections. Its distinction between finite prefixes and eventual progress also motivates saying explicitly what supplies future execution opportunities here.
- [Benaloh–Leichter, *Generalized Secret Sharing and Monotone Functions*](https://www.cs.cornell.edu/courses/cs754/2001fa/bena88.pdf): appropriate existing citation for monotone access structures. The manuscript should retain the standard construction but avoid equating a permission formula with the ability to force an output of a constrained computation.

## Overall disposition

Revise, then re-review Section 3's examples against the formal labels. The paper does not need more theorem machinery. It needs one coherent approval-provenance convention, an honest connection to access-control safety, and better explanation of the economic selection hypothesis. The liveness proof merits more attention than the elementary closure equivalence, because the history conditioning is the genuinely delicate step.
