# Round 2: software-engineer reader

## Verdict

The revised paper now meets the engineer-reader target. The two major pre-proof comprehension cliffs identified in Round 1 have been removed. Section 3 gives a concrete route before its set notation, and Section 4 gives the operational mechanism, the question each equation answers, and a numerical interpretation of the theorem. The reader may need to work through notation, but no longer has to reconstruct the purpose of a section before doing so.

The fixed-reference-agent convention is understandable. In particular, installing a correctly verified always-approve replacement does **not** count as approval from the original agent. The text also now explicitly prevents the mistaken inference that including A in a coalition lets somebody manufacture arbitrary agent decisions.

No further structural expansion is needed. Two small wording changes would improve precision and accessibility:

1. Before the first equation for `R_theta`, say that it is the yes/no statement that `y` is an allowed result of the specified program on inputs `x,r`. The function-versus-relation distinction is still introduced through notation rather than meaning.
2. Change “A shorter list means more protection against that intervention” to “Removing groups from a list increases protection against that intervention.” The former suggests cardinality is the comparison rule, whereas the following definition correctly uses set inclusion and permits incomparable profiles.

## Section-by-section test

| Section | First possible comprehension snag | Assessment and minimal remedy |
|---|---|---|
| Abstract | “Architectural incorrigibility” is unfamiliar. | Immediately defined. The reader understands indirect intervention paths, the repair tradeoff, and the conditional finite-budget recovery claim. Pass. |
| 1. Introduction | Distinction between behavioral cooperation and enforceable authority. | The fund example and shutdown examples make this concrete. The final paragraph now previews results rather than only section numbers. Pass. |
| 2.1 Updates | Partial-function arrow. | “Partial” is now explained with the insufficient-balance example. The engineer can map this to an operation that rejects an invalid state. Pass. |
| 2.2 Verified approval | “The accepted computation is a relation.” | Minor remaining snag; add the one-sentence yes/no gloss above. The overall mechanism remains understandable without it, so this is not a section-level cliff. |
| 2.3 Governors | Uppercase approval sources versus lowercase Boolean values. | Both are explained, and the familiar bilateral Boolean check carries the notation. The source-versus-executor distinction is explicit. Pass. |
| 2.4 Assumptions | Soundness and backend. | Defined locally. Ledger integrity and computation soundness are clear assumptions rather than a list of caveats. Pass. |
| 3.1 Direct authorization | Power-set notation and monotonicity. | The policy table comes first; the power set is glossed; the bilateral example explains the upward property. Pass. |
| 3.2 Update sequences | Path labels followed by provenance under replacement. | The concrete two-route diagram makes labels and unions comprehensible. The reference-agent paragraph is the most demanding pre-proof passage but explains a necessary distinction with an effective example. Pass with effort. |
| 3.3 Comparing protection | Profile tuple and componentwise ordering. | Purpose is stated first, and the incomparable-governor example explains why the comparison is not a scalar score. Replace “shorter list” as noted above. |
| 3.4 Repair | Hitting-set equation. | The opening states the dependency; the equation is translated into intersecting every sufficient set; the threshold example makes it concrete. The failed-backend example directly shows the implication. Pass. |
| 4.1 Progress | Auction terminology. | The lifecycle explains reverse auction, payment, bond, exclusive window, and subsequent attempts. No unexplained mechanism remains. Pass. |
| 4.2 Payment | Number of economic parameters. | Every parameter now has an operational meaning. The cap distinction and 12-miss example are sufficient. The profitable-bid requirement correctly covers changing bonds. Pass with effort. |
| 4.3 Recovery | The theorem's strong selection hypothesis. | The opening identifies why affordable workers can still be excluded. The theorem and immediately following caveat make clear that costly exclusion is an assumption, not something proved from the auction alone. The numerical interpretation lets readers assess the result before the proof. Pass. |
| 4.4 Withholding | External benefit `v`. | The temporary-veto explanation motivates it. The sunk-cost comparison is simple and transparent. The final finite-resource bound is proportionate. Pass. |
| 5. Verification mechanisms | TEE reports and ML-proof benchmark units. | The section opening connects mechanisms back to the model. TEE measurement is defined; the pass-versus-sequence distinction is now explained before the table. Specialist table details can be skipped without losing the section's result. Pass. |
| 6. Case study | Backend and contract-specific names. | They are explained sufficiently; the main finding is stated first. The freeze and settlement examples now visibly instantiate earlier requirements. Pass. |
| 7. Related work | Named traditions and systems. | Their contribution to the argument is explicit. The three design obligations are readable and useful. Pass. |
| 8. Conclusion | None. | Summarizes both authority and recovery and their distinct assumptions. Pass. |

## Reference-agent/provenance check

The intended distinction now reads coherently:

- A governor-approved program replacement is an administrative transition attributed to that governor.
- Running the replacement program can be computationally necessary for a later transition.
- Even a correct proof of the replacement program's output does not establish approval under the protected agent's original relation.
- Consequently that later execution does not add an A label solely because a variable or code path calls it “agent approval.”
- If the protected agent did approve the replacement, the replacement path already includes A.
- A separate analysis may designate the upgraded program as its new reference agent.

The proposition now states graph reachability rather than implying that coalition members can force arbitrary computation-backed decisions. The text keeps computational feasibility as a precondition and separately identifies existential reachability versus control over transaction ordering. This resolves the earlier engineer-level ambiguity.

One useful mental model survives a skim: **labels track where authorization came from, not merely the names of checks that pass in the current code.** That sentence could replace some wording if editing for length, but does not require an additional paragraph.

## Auction indexing and numerical interpretation

The indexing is consistent:

- Attempt 1 begins with zero failed attempts and therefore uses `b_0`.
- After `m_*` failures, attempt `m_* + 1` first has the guaranteed-feasible offer.
- In the example, `1.1^11 ≈ 2.853 < 3` and `1.1^12 ≈ 3.138 ≥ 3`; the first guaranteed-feasible attempt is number 13.
- Attempts 13 through 19 comprise seven post-threshold opportunities.
- A loss budget of 100 and minimum unrecoverable loss of 20 allow at most five unsuccessful adversarial opportunities.
- A no-success run through attempt 19 must therefore contain at least two responsive failures.
- With a conditional success probability of at least 0.9 for each such attempt, their joint failure probability is at most `0.1^2 = 0.01`.

The paper clearly distinguishes the worker's pricing estimate `q` from the actual history-conditional success bound `p`. It also correctly calls the bound an attempt count, not a wall-clock guarantee. The post-theorem prose does not promise a deterministic maximum delay when `p < 1`; the finite maximum is stated only for `p = 1`.

## Final editorial recommendation

Make the two one-sentence adjustments above, then stop expanding for this reader. The document now provides enough orientation without turning every standard mathematical step into a tutorial. Further effort is better spent on final consistency, source accuracy, and rendered layout than on additional explanatory machinery.
