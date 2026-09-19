# Round 1: software-engineer reader

Reviewer perspective: a capable software engineer who understands processes, APIs, authorization checks, and ordinary hash/signature concepts, but has limited cryptography, auction theory, or formal-methods background. This is an independent reading of the current `main.tex`, not a correctness certification.

## Overall diagnosis

The abstract, introduction, and most of Section 2 now communicate the architecture. The reader understands that a contract holds durable state and a budget; replaceable workers supply verified model outputs; and authorization may combine a model decision with wallet approvals. The reader also understands why “who may change the rules?” and “will anyone execute them?” are distinct questions.

The paper still fails the requested engineer test at two points **before proofs begin**:

1. Section 3.2 introduces four layers of set notation and subtle approval attribution in one pass. The reader understands the motivating upgrade bypass, then loses the correspondence between that example and the equation.
2. Section 4 begins a fairly specific auction model without explaining its operational lifecycle. The reader is asked to track reward ceilings, bids, miss counts, stall counts, capped escalation, worker failure, liquidity costs, and admissible bids before being told the simple recovery argument in plain language.

The best fix is not a larger glossary or more formal preamble. Use one running example through Section 3, and give Section 4 an operational story followed by a numerical reading of its theorem. Sections 5–6 also need short “why this section matters” openings.

## Highest-priority revisions

1. **Before Section 4.1, state its claim in everyday terms.** For example: “Preserving the program and removing shutdown authority do not ensure that a worker will run it. We examine one payment mechanism: raise the maximum fee after missed attempts, and require an exclusive worker to post a deposit that it loses for non-delivery. If the fee eventually covers a willing worker's costs and each attempt to keep that worker out consumes a finite attack budget, recovery has a calculable delay bound.” This gives every subsequent parameter a purpose.
2. **Explain the auction lifecycle before its economic equations.** A request opens; workers quote fees; one eligible bid wins; that worker posts a bond; it either submits verified output and receives the quoted fee or misses the deadline and loses the bond; another attempt may open. Say why an exclusive winner is used and identify it as the modeled mechanism, not a requirement of the architecture. Define a reverse auction parenthetically as workers competing to provide the service at a lower fee. Define a first-price payment as paying the winner its own quoted fee, if that detail remains material.
3. **Add one fully instantiated authority example before the closure equation.** For governors G1 and G2, direct overwrite needs both; module replacement needs G1; after replacement, an initialization call is permissionless. The path labels are `{G1}`, then `{}`; their union is `{G1}`. The reader can now parse the equation as “collect every path's needed approvals, then include coalitions with extra members.”
4. **Give the liveness theorem a numerical reading before or immediately after it.** Retain the existing 12-miss reward example. With a loss budget of 100, minimum loss 20, and conditional delivery success at least 0.9, there are at most five costly obstructions; after 12 + 5 + 2 = 19 opportunities the probability of no success is at most 0.01. Explain that these are opportunities, not minutes or blocks, and that the conditions—not the arithmetic—carry the theorem's substance.
5. **Use plain-language bridges into the incorrigibility profile and blocking equation.** Before the profile: “For each protected operation, record the governor groups that can cause it without obtaining a new agent decision. Fewer such groups means more protection against outside intervention.” Before blocking: “An approval rule also tells us which absences disable every available route.”
6. **Reduce in-line exceptions that interrupt the main construction.** In particular, the delegation/vacuous-verifier paragraph in Section 3.2 needs a separate named example or paragraph. It is conceptually essential, but currently interrupts the first explanation of path support.
7. **Add Section 5's missing thesis.** It supplies two ways to implement the computation check introduced in Section 2; the tradeoff is which party or mathematics supplies integrity and how much executing/proving costs. State that before details about measured boot, accelerator protection, or quantization.
8. **Make the case study a mapping rather than an audit surprise.** Begin with the question being tested: which of the abstract permissions and liveness conditions are actually realized by the source? State the main result early: the code demonstrates replaceable paid execution but retains administrative paths and backend dependencies. Readers then understand why the subsequent implementation details matter.

## Section-by-section reading

### Abstract

**Can the engineer follow?** Yes. “Verified model outputs can authorize ledger updates” is now a meaningful central sentence, and the architecture's policy flexibility is clear.

**Remaining friction:** “derive conditions and bounds for recovery” does not tell the reader what the key bound says. The abstract could state the result at the same level as the consent/repair result: under sufficient funding and worker availability, a finite obstruction budget can delay but cannot indefinitely prevent successful execution. This must remain explicitly conditional and scoped to the modeled auction.

**Do not add:** names of every mathematical object or the full theorem hypotheses. The current abstraction level is appropriate.

### 1. Introduction

**Can the engineer follow?** Yes. The fund example is effective. The separation between behavioral corrigibility and contract authority is clear.

**Remaining friction:** The final paragraph is a table of contents, not quite a preview of what is learned. Replace or expand it with the two findings: authority must include indirect governance paths, and greater consent requirements can block repair; execution additionally needs an economically and operationally feasible path. Section numbers can be attached to those statements.

**Useful continuity:** Reuse this same fund in Section 3 instead of introducing a new storage-module scenario without connecting it to the fund's ledger state.

### 2. A ledger-governed agent

#### 2.1 Ledger state and proposed updates

**Can the engineer follow?** Yes. Separating update semantics from authorization corresponds well to an API operation and its access-control middleware.

**Small first notation break:** The arrow `\rightharpoonup` is unexplained. “Partial” needs a parenthetical: the function is undefined if state preconditions fail. No proof or formal-methods lookup should be needed to understand this API.

**Potential ambiguity:** Is `s` the complete ledger or only the agent's application state? It says “relevant ledger state” and then uses application-level semantics. Add one sentence saying it includes any ledger fields needed to decide these updates and their authorization; unrelated state can be omitted. That is enough for this readership.

**Good existing choices:** Structured `u` versus auxiliary `z`; a storage request belongs in `u`; explicit no-op; and execution-time preconditions all clarify implementation concerns.

#### 2.2 Verifiable computation as approval

**Can the engineer follow?** Mostly, but the first unfamiliar concept is the relation `R_theta`.

**Exact break:** “The accepted computation is a relation” followed immediately by `R_theta(x,r,y)=1`. Engineers recognize functions. They may interpret a relation as extra cryptographic machinery rather than a yes/no specification. Lead with: “Let R be the checkable statement ‘y is an allowed result of running this specified program on these inputs.’” Then explain that deterministic execution admits exactly one output; looser semantics can admit several.

**Second break:** `Verify` is clear as an API but “binding hash commitment,” “soundness,” and “domain-separated” are not yet explained. Briefly gloss them in place: hashes identify the exact data, soundness means invalid results cannot obtain accepted evidence under the backend assumptions, and domain binding prevents reusing an approval for a different chain/contract/request. The existing EIP-712 sentence can remain as a concrete implementation aside rather than the explanatory backbone.

**One high-value conceptual sentence:** “This does not ask the blockchain to rerun the LLM; it asks the blockchain to validate compact or otherwise cheaply checkable evidence.” Qualify “compact/cheap” by backend if necessary; a TEE report and the chosen proof system can have different verification costs. The current reader can infer this, but the architecture depends on it.

**Preserve:** The distinction between proving a model produced an update and assessing whether the update is desirable.

#### 2.3 Governors and authorization policies

**Can the engineer follow?** Yes. The Boolean formula is familiar and the account-versus-human distinction is useful.

**Possible overload:** `A`, `a`, `G_i`, `g_i`, `P`, `rho`, and `Auth` appear quickly. This is manageable because each has a concrete meaning, but keep the explicit “principal versus Boolean approval” sentence. A small code-like check could replace some prose, but another formal display is unnecessary.

**Potential misreading to prevent:** `A` is not a wallet that can choose to sign on demand. Its approval means that the specified computation actually produced the update for this request. Restate this when transitioning into coalition language in Section 3; otherwise later “controls A's approvals” sounds like possession of a signing key.

#### 2.4 Security assumptions

**Can the engineer follow?** Yes, given the short glosses of soundness/binding above.

**Improve:** Expand TEE at first use; it is currently expanded only later. The section appropriately separates ledger correctness from liveness. Do not reintroduce key-custody or ledger-governance hedging.

### 3. Intervention authority as a graded property

#### 3.1 Direct permissions and their order

**Can the engineer follow?** The opening does; the notation paragraph may not.

**Exact break:** `Gamma_u(s) subseteq 2^P` and `C subseteq D` arrive before explaining that `2^P` means all sets of principals. Add the gloss or avoid power-set notation on first use: “List all groups whose approvals suffice; this list is Gamma.” Then supply the formal notation.

**“Monotone” can be familiarized in one sentence:** Adding another valid approval cannot make an otherwise approved request fail. The current “Additional approvals may be ignored” is true but less direct.

**Minimal example:** For `a AND g1`, the sufficient sets include `{A,G1}` and `{A,G1,G2}`; the former is minimal. This prepares Section 3.2 without more abstraction.

**Intervention target definition:** The idea is understandable. “History predicates can be represented by adding monitor state” is a formal verification aside that arrives unnecessarily early for this reader. Move it into a footnote, or briefly explain: “If the target depends on earlier events, record the needed history in the state.”

**Subheading accuracy:** “Direct permissions and their order” does not explain an order until later. “Direct permissions and protected changes” would match the content more closely.

#### 3.2 Closure under governance paths

**Can the engineer follow before the proof?** Not reliably. This is the clearest failure of the requested test.

**What works:** The first paragraph's bypass example. The reader recognizes the problem immediately.

**Where the reader gets lost:** The example is followed by graph exactness, environment transitions, minimal coalitions, labeled paths, support, upward closure, delegation attribution, vacuous verification, and prior approvals. The engineer cannot keep the single underlying operation—union the approvers along each path—in view.

**Suggested order:**

1. Walk through the two-edge example with explicit sets.
2. State the algorithm in ordinary terms: for each feasible path, collect its required approvers; a coalition can use the path if it contains them all.
3. Define minimal labels and display the equation.
4. State the proposition and proof.
5. Discuss complete graphs, delegation, and verifiers as modeling requirements, using a named verifier-replacement example.

**Important conceptual ambiguity:** “using only approvals it controls” is intuitive for governors but opaque for `A`, which cannot manufacture arbitrary approvals. Say explicitly whether a path already incorporates the existence of every computation-backed decision it uses. If yes, this is a reachability/capability result conditional on those valid decisions being obtainable along that path, not a claim that a coalition containing A can make the LLM approve anything. The later capability-versus-race caveat addresses scheduling but does not fully address this question.

**Profile introduction:** The definition arrives immediately after a scheduling qualification and is easy to misread as a new unrelated object. Add the plain-English purpose first. Explain the intersection with `2^G` as “discard every route that needs a new agent approval.”

**Good detail:** Bilateral and disabled operations have the same external profile but differ in whether anyone can perform the intervention. This is an important implication, not a tedious technicality; retain it.

**What to cut or relocate if length grows:** The fixed-point computation is useful implementation context but less important than the worked example. `kappa` is a secondary summary. The genuine-freeze proposition can be shortened or moved to the case-study linkage; it currently prolongs a very long subsection.

#### 3.3 Consent and availability are dual

**Can the engineer follow?** Yes, especially the broken-backend repair example.

**Small break:** “hitting sets” should be described as groups that intersect every sufficient approval group, before naming the established term. The equation itself is short and understandable with that gloss.

**Clarify domain:** For a complete repair plan, use the effective path approval family from the prior section, rather than leaving unclear whether this reuses direct permissions or introduces another object. The engineer should be able to see that an alternative repair path also supplies an alternative way around an unavailable signer.

**Scannability:** “Consent can block recovery” would communicate the result more immediately than “Consent and availability are dual.” The latter is mathematically suggestive but the former states the consequence.

### 4. Conditional liveness of paid execution

**Can the engineer follow before the proof?** Currently only with substantial reconstruction. This section is the main rewrite priority.

#### 4.1 Recovery, recurrence, and successful action

**Missing section-level bridge:** Why is an auction needed after a section about authorization? State that it addresses willingness and opportunity to execute a still-authorized program.

**First sentence:** “Classical liveness requires eventual progress rather than the absence of forbidden transitions” is correct but compares against unnamed safety. Simply explain liveness as “the system eventually does something it is supposed to do,” then distinguish possible execution from repeated execution from useful effects.

**Terminology:** “Action recurrence” uses the earlier action vocabulary after the output model was generalized to updates. “Application progress” or “nontrivial update recurrence” may be clearer; define usefulness relative to an explicit application property if kept formal. It need not be a theorem here.

**Unused notation:** `S_t` is introduced and not used later. Remove it unless the theorem will use it.

**Operational break:** “first-price reverse auction with an exclusive winner” needs the lifecycle described above. “numeraire” can simply be “unit of account.”

#### 4.2 The feasibility threshold

**Missing lead-in:** State the question before the equation: after how many failures does the maximum offered fee become high enough to make execution worthwhile?

**Parameter interpretation:** The equation is manageable if grouped into two limits: the treasury may spend at most a fraction `beta` of its available funds, and the escalating fee stops growing after `K` misses. Explicitly define `b0` as initial ceiling and `alpha` as growth multiplier.

**Avoid readers reconstructing units:** `c`, `qd`, and `ell` are expected worker costs; `b` is the quoted payment, paid only on success. The current equation is fine once those meanings are explicit.

**Phrase to replace:** “Fix an admissible profitable bid” reads like an unstated technical definition. Say “Choose a fee at which at least one eligible worker is willing and able to execute,” and then name it `bar b`. Keep the caveat that this does not ensure selection.

**Question readers will have later:** How does worker failure probability `q` relate to the theorem's `p`? State that `q` is used in an individual profitability calculation, while the theorem needs a stronger success bound that holds after every possible prior history. They need not coincide. Otherwise readers look for a missing `p = 1-q` substitution.

#### 4.3 A finite-budget delay bound

**Give the result before its assumption list:** “Once the fee is sufficient, there are only two possible causes of a failed opportunity in this model: a responsive worker fails, or an attacker pays to obstruct it. A finite loss budget bounds the second kind; a uniform success probability bounds runs of the first.” This makes the theorem's proof almost inevitable without trivializing its key assumption.

**Numbering ambiguity:** The text says “from attempt m* onward” while the conclusion uses “first m* + N + n attempts.” Define attempts consistently as 1-based with the first m* failures occurring before the reward is feasible; or explicitly index the initial miss count from zero. This is easy to repair and avoids readers suspecting an off-by-one error.

**Assumption list:** Mostly substantive and readable after the operational bridge. “Settlement can complete independently of whether the proposed application action succeeds” should use “requested update” and explain that paying for a correct no-op or a failed external call must still be possible.

**Proof:** Once the reader understands the model, the proof is approachable. Its important part is that the success probability must remain bounded after the adversary observes previous results, not an independence assumption. Give that fact space; do not bury it under additional preliminary notation.

**Probability one:** Explain once as “the probability of never recovering is zero under these indefinitely maintained assumptions.” This does not mean a finite maximum delay when `p < 1`.

**Escalating-bond equation:** This is an optional refinement rather than a new central result. Start with “Increasing the forfeited bond can reduce the number of obstructions an attacker can afford.” Define `(x)_+ = max(x,0)` in place. Consider putting the closed-form geometric sum in a footnote/appendix and retain the simpler “sum the successive bonds until the attack budget is exhausted” description in the main text. The current formula adds notation just as readers have finally absorbed the main bound.

#### 4.4 Selective non-delivery and resource limits

**Can the engineer follow?** Yes. Sunk inference cost versus remaining submission cost is well motivated, and the inequality is understandable.

**Clarify motivation:** A worker might benefit from suppressing a particular fund transfer, or dislike a result after computing it. One example makes external benefit `v` concrete.

**Useful implication to retain:** Bonding discourages withholding but cannot promise that every computed output will be published. That directly limits what verified execution means.

**Ending:** Strong and clear. The finite-resource bound is elementary and appropriately brief. It separates operating independence from free computation.

### 5. Instantiating verifiable execution

**Can the engineer follow?** The high-level choice is recoverable, but the section assumes too much hardware-attestation and ML-verification vocabulary to meet the requested effort level without local explanations.

**Missing section intro:** Explain that this section fills in the `Verify` function, and that its trust assumptions and cost feed back into Sections 3 and 4.

#### 5.1 Attested execution

**First unexplained terms:** measured program, quote, measured boot, attestation roots, collateral. Give the core mechanism in one sentence: hardware signs a statement identifying the program and its input/output, and the verifier checks the signer and approved program identity. Then the limitations follow naturally.

**“Collateral availability”** is particularly opaque; say availability of the certificates/revocation information needed to validate reports if that is what is intended.

**Verde aside:** “Refereed delegation” needs one clause: another party can challenge the reported computation and trigger an adjudication procedure. Otherwise this aside adds a third backend without explaining it. An appendix or related-work placement may be cleaner if it does not affect the model.

#### 5.2 LLM inference proofs

**Opening:** Good distinction between public correctness and privacy, but unpack the cryptographic acronym by its useful effect first: an untrusted worker produces a proof that the agreed computation was followed. The expansions of “succinct non-interactive arguments” do not themselves help this reader.

**Benchmark table:** Useful factual care, but dense with fields that are only meaningful to a specialist. Explain “forward pass” versus “autoregressive response” before the table: one model evaluation versus generating a sequence token by token. Explain why a number for one cannot directly establish the cost of the other. Width-128/256 results need “small components” as a plain-language interpretation.

**Ordering issue:** “the particular 70B model and multi-pass runtime considered here” appears before the case study has introduced the model. Refer forward explicitly to the case study, or say “does not by itself establish feasibility for much larger agents.”

**Strong synthesis paragraph:** The final paragraph connecting portability, cost, OR-verifier integrity, and model availability back to prior sections is valuable. Keep it and make the opening similarly connective.

### 6. A source-level case study

**Can the engineer follow?** Mostly, after glossing contract-specific vocabulary.

**Main issue:** The section initially reads as scope disclaimers followed by implementation specifics; its result emerges only at the end. Put the conclusion up front: an implementation demonstrates the execution pattern while retaining routes that prevent the strongest incorrigibility claim.

**Terms needing brief expansion:** TDX (the hardware backend), dm-verity (integrity-checked filesystem), commit–reveal (bids committed before their values are disclosed), and EVM (Ethereum execution environment) if first use. These should not force an engineer into four browser lookups merely to understand the mapping.

**Good details:** The exact `freeze` flags explain an indirect path concretely. The payment-first/revert distinction is familiar and persuasive to a software engineer. Preserve both, but tie them directly to the effective-path and settlement hypotheses rather than presenting them as a list of unrelated implementation flaws.

**Narrative opportunity:** This is the real-world instance of Section 3's graph example. A tiny edge path in prose—owner calls freeze; sunset flag is set; auctions stop—would make the relationship immediate.

### 7. Related work and implications

**Can the engineer follow?** Yes. It is concise and makes the contribution's scope credible.

**Improve:** The first two paragraphs summarize families of work but could name the specific conceptual inheritance: access structures describe acceptable approval groups; reachability captures permissions gained through sequences; liveness reasoning bounds recovery under explicit environmental conditions. This tells the engineer which background material is worth looking up.

**Best existing paragraph:** The three design consequences are concrete and connect all sections. These consequences should also be visible earlier in the introduction.

### 8. Conclusion

**Can the engineer follow?** Yes.

**Possible addition:** Explicitly state the conditional obstruction result in plain English, rather than ending only with a list of prerequisites. The reader should leave with both halves of the contribution: indirect intervention paths determine authority; a viable execution market with costly, bounded obstruction yields a recovery guarantee under the stated availability conditions.

## Suggested second-pass acceptance checks

- Read only section openings and conclusion: can the engineer explain why each section is present and how it follows from the previous one?
- Cover every display equation: does the surrounding prose still convey the result's meaning and why it matters?
- For every symbol in the recovery theorem, can the reader point to a concrete auction event or monetary quantity introduced before the theorem?
- For the closure equation, can the reader calculate one path support without rereading the definition?
- Are the full relation, program identity, and actual agent decision clearly distinguished from the worker that transports their evidence?
- Does the reader understand that the liveness theorem is conditional on exhausting all causes of excluded honest workers—not a general consequence of merely bonding workers?
