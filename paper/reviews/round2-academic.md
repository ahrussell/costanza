# Round 2: specialist academic re-review

Reviewed the revised `paper/main.tex` after the first-round changes. The central mathematical mismatch has been repaired. I found no remaining counterexample to the authorization characterization or the recovery bound under their stated assumptions. Four small clarifications below would make the formal reading cleaner; none requires additional machinery.

## Minimal final repairs

1. **Define the no-success value of the random time.** Replace “Let T be the number of the first successful attempt” with “Let T be the number of the first successful attempt, with T = infinity if no attempt succeeds.” Otherwise the random variable is technically undefined on precisely the outcome class the theorem is analyzing.

2. **Connect the two authorization families explicitly.** Section 3.1's `Gamma_u(s)` summarizes the current contract checks. Section 3.2's `Gamma_t` must use fixed reference-source attribution after reconfiguration. Add one sentence immediately before introducing `min Gamma_t`:

   > The edge families Gamma_t use this attribution to fixed approval sources; they need not use the names assigned to predicates by the current contract.

   The new reference-agent paragraph already explains the substance correctly. This sentence only prevents readers from silently identifying the two families and reintroducing the old ambiguity.

3. **State positive bond parameters in the refinement.** In the escalating-bond paragraph, give `d_0 > 0` and `bar d > 0`. This makes the “largest k” finite for finite W. One optional explanatory clause—“other failed deliveries only raise the bond counter further”—would show why the lower bound still holds when adversarial failures are interleaved with responsive failures.

4. **Specify the attempts indexed in the proof.** Write “Consider the post-threshold responsive attempts in order.” The proof is already valid, but this keeps the sequence visibly tied to the counting argument immediately above it.

## Fixed-reference approval model

The new convention resolves both cases that broke the previous reading:

- **Sound proof of a governor-installed constant program.** The installation requires G1; subsequent computation is a realizable non-authorization precondition with no reference-agent approval. The complete route therefore retains support `{G1}` and is correctly included in the external intervention family.
- **Governor-installed vacuous verifier.** Passing the new check is not reference-agent approval. The route is labeled by the actual governance authority that enabled it.
- **Agent-approved program replacement.** The route already contains A, so later execution of the successor cannot retroactively make the route governor-only. Choosing a successor as reference in a separate assessment is sufficient; no lineage formalism is necessary here.
- **Agent refusal.** Including A in an abstract source set does not make a prohibited output possible. The exact graph preserves computation feasibility, and the text explicitly distinguishes reference approval from a freely signable capability.
- **Previously issued approval.** Such evidence is part of the initial configuration and is not counted as a fresh approval. The property is therefore correctly state-relative.

The restricted-graph proposition is sound: a path is retained exactly when every selected label lies in C, equivalently their union lies in C. Its short proof is proportionate to its elementary content. The surrounding construction—not the set algebra—is now where the explanatory effort goes. The explicit finite-graph qualifier also avoids implying an automatic complete analysis of arbitrary contracts.

## Profiles and repair blocking

The partial-order/preorder distinction is now correct. Comparing profiles requires the same approval sources, reference agent, targets, and assumptions. Bilateral and disabled rules can share an external profile while differing in the full effective family; the text explains why both matter.

The repair identity is correct with other feasibility conditions held fixed. It also handles the edge cases:

- If no repair path exists, the family of minimal supports is empty, the universal condition is vacuously true, and authorization is blocked even with no unavailable source.
- If a repair path is permissionless, the minimal family contains the empty set, which no unavailable-source set intersects, so absent approvals alone cannot block it.

The repaired backend example appropriately distinguishes temporary outage from permanent loss. The claim about equivalent verification alternatives is also now qualified correctly: they may restore execution without relaxing the approval requirements. This is a useful design consequence rather than a disclaimer.

## Recovery theorem and proof

The new one-based indexing is consistent. After `m_*` failures the bid becomes affordable on attempt `m_*+1`. Among the next `N+n` failed attempts, at most N can be nonresponsive failures, so at least n are responsive failures. The illustrative `12+5+2=19` bound is correct.

Allowing a nonresponsive winner to succeed is harmless: the proof charges only its failures, while its success ends the event being bounded. Requiring the winner's class to be fixed before its delivery outcome avoids the retrospective classification problem.

The iterated conditional-expectation step is valid. Let E_r be the event that the first r post-threshold responsive attempts occur and fail before recovery. The history-conditional failure bound gives `P(E_r) <= (1-p) P(E_(r-1))`; possible termination before the next responsive attempt can only reduce this probability. Thus `P(E_n) <= (1-p)^n`. The horizon event `T > m_*+N+n` is contained in E_n. Adaptive selection from prior outcomes does not invalidate this argument, and no independence assumption is being smuggled in.

The almost-sure recovery and recurrence consequences are correct under continued attempts and hypotheses that renew conditionally after every success. The manuscript now states those assumptions before drawing either consequence.

The sum-based bond refinement is a clearer choice than the former closed form. The kth adversarial failure occurs after at least k-1 selected-worker failures, so its bond is at least the kth term of the displayed nondecreasing schedule. Intervening responsive failures can only increase that lower bound. Once the bond parameters are explicitly positive, substituting the largest affordable k for N is valid. The liquidity qualification is necessary and is retained.

## Remaining section-level assessment

- **Abstract and introduction:** claims now accurately match the conditional results. The contribution is positioned as a synthesis/application rather than a new authorization or cryptographic primitive.
- **Section 2:** effect, permission, and evidence are separated clearly. The relation-level abstraction is suitable for an architectural paper and does not need a full cryptographic experiment.
- **Section 3:** the specialist can now follow every construction without guessing the intended meaning of A. The administrative-route example and HRU connection make the notation familiar.
- **Section 4:** economic feasibility, selection, and stochastic success are visibly separate assumptions. The distinction between pricing estimate q and actual success bound p is especially useful.
- **Section 5:** backend choices are connected to the recovery assumptions, rather than presented as an unrelated benchmark survey. This pass did not reproduce or independently re-audit all benchmark numbers.
- **Section 6:** implementation observations are linked to the abstract distinctions and are appropriately limited to source-level claims.
- **Sections 7–8:** attribution and conclusions now match the modest results. The reference-agent wording is consistent with the repaired formal model.

## Disposition

The revised formal core passes this review subject to the small definitional clarifications above. Further mathematical expansion would likely hurt the paper's proportions. The next checks should focus on the compiled presentation, reference accuracy, and whether the section openings support the user's scan-reading test.
