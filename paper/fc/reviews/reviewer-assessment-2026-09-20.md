# Skeptical FC short-paper assessment

Review date: September 20, 2026. Reviewed `paper/fc/main.tex` as a standalone submission, together with its bibliography and local author instructions. This is an independent assessment of contribution, fit, evidence, and presentation; it is not a substitute for the separate proof audit. No manuscript edits were made.

## Provisional judgment

**Good venue fit; a plausible but currently borderline short paper.** My likely discussion concern would be “the distinctive systems contribution is underdeveloped relative to the amount of formal setup,” rather than “the topic is outside FC.” I would be interested in the paper, but not yet a confident advocate for acceptance. This is a judgment about the draft, not an acceptance forecast.

The relevant FC audience includes authorization, smart contracts, computation outsourcing, TEEs, auctions, and security economics. The [FC 2027 CFP](https://www.ifca.ai/fc27/cfp.html) explicitly encourages short submissions presenting novel applications and work in progress, evaluated for novelty and the research discussion they may generate. A full production evaluation is therefore not an automatic prerequisite. The paper still needs to make the incremental insight concrete enough that it is more than a collection of familiar building blocks.

The strongest contribution is the combination of **computation-bound authorization, protection of the agent specification across governance changes, and scheduled opportunities to exercise that authority**, with the assumptions separated. The paper is unusually candid about what its liveness theorem does not establish. Its reference-agent distinction is useful: acceptance by a mutable verifier must not silently count as the original agent's consent. Those strengths deserve more prominence.

**Coordination update after this review:** the independent proof audit identified a material consent-scope issue: excluding all paths with any reference-consent edge can count an unrelated benign transaction as consent to a later governance intervention. This is a higher-priority correctness repair than the presentation changes below. Target-specific consent to the relevant modification or delegation must be represented explicitly; the profile should not treat every earlier agent-authorized transaction as discharging that obligation. The recommendations here assume that issue is repaired. The original provisional judgment was about the contribution/evidence presentation, not a finding that every definition was sound.

## Prioritized reviewer objections and focused remedies

### 1. The title and contribution paragraph foreground the most familiar component

Location: title, abstract, introduction, especially `main.tex:54`.

Likely objection: “Replacing a signature check with proof verification is familiar. The authorization theorem mostly proves that a correctly implemented verifier gate inherits its assumed soundness. Where is the paper's new contribution?” The theorem is useful compositional accounting, but the draft devotes its largest section to it and currently gives the distinctive governance construction much less explanatory space.

**Fixable framing, with some substantive exposition needed.** Keep the formal reduction. Do not inflate it into a new cryptographic primitive. Explain what using this gate for the agent's *own* mutable execution specification adds, and name the three different assurance claims. A possible title is **“Short Paper: Verifiable Authorization and Self-Governance for AI Agents.”** A possible contribution sentence is:

> We analyze how verified inference can protect both an agent's transactions and the rules under which future decisions are made. The resulting specification separates authorization integrity, intervention without reference-agent consent, and recovery of execution opportunities.

That should replace overlapping prose, not be added as another roadmap. A concise admission that the reduction composes standard guarantees is an asset for this audience; a claim of cryptographic novelty would be a liability. Following discussion with the coordinating reviewer, an even more focused title is **“Short Paper: Consent and Scheduled Execution for On-Chain AI Agents.”** It makes neither a new verification primitive nor unconditional liveness the headline.

### 2. Ritual is closer prior art than the current one-phrase treatment suggests

Location: `main.tex:55`.

Rocky is appropriately credited for proof-authorized neural-network transactions. Its [primary announcement](https://medium.com/@CountableMagic/chapter-3-the-worlds-first-on-chain-ai-trading-bot-c387afe8316c) explains both proof-linked decisions and the transaction-executing contract. That citation is doing useful work.

[Ritual's February 2025 architecture announcement](https://www.ritualfoundation.org/blog/unveiling-ritual) describes scheduled transactions, TEE and ZK computation backends, and a compute marketplace together. A reader familiar with it may see much of the abstract as an existing systems architecture. Calling it only a “scheduled computation market” understates that overlap.

**Fixable comparison.** Use one accurate sentence about the overlap and one about what this paper actually provides. For example:

> Ritual combines scheduled execution, heterogeneous verification, and computation markets. We study the authorization and intervention properties of such a composition and state the availability and economic premises needed for recovery.

Do not assert that Ritual lacks security proofs, owner resistance, or particular input-binding safeguards without auditing the relevant primary technical material. The announcement alone does not establish such absences. Likewise, do not spend scarce space criticizing Rocky's implementation. A positive description of this paper's formal contribution is sufficient.

### 3. The governance definition is useful, but the reader never sees a profile worked out

Location: Section 3, particularly `main.tex:156`–`170`.

Likely objection: “Incorrigibility is defined as absence of an approval-free path, which is standard reachability. Does the partial order help assess a concrete policy?” The current bypass example is good, but stops just before computing the mathematical object the section introduces.

**Fixable within the current length.** Replace part of the existing example with one explicitly bounded example and its intervention family. For instance, in a system with one governor, a migration operation, and a model-replacement operation, where these are the only transitions affecting the target:

* Governor-controlled model replacement followed by approval from the replacement gives `Gamma^0 = {{G_1}}` for the migration target.
* Requiring reference-agent consent for model replacement, and reference-agent authorization for direct migration, gives `Gamma^0 = emptyset`.

The example must state the absence of other bypass transitions; simply changing one circuit never proves whole-system protection. This calculation would make the existing two-edge example carry more weight without adding another theorem or a larger formal construction. If there is room, the weights-versus-schedule incomparability example could use two displayed profiles instead of only prose.

Also add a short scope sentence near the section boundary: the paper defines a property of a supplied transition model; it does not automatically establish that a deployed contract satisfies it. That distinction is especially important because the abstract's “enforceable right” can otherwise sound like an end-to-end implementation theorem.

### 4. The recovery theorem is conditional analysis, not a proof that the auction supplies liveness

Location: Section 4, especially `main.tex:175`–`188` and `214`.

Likely objection: “The central difficulty is ensuring that every unsuccessful nonresponsive attempt costs the attacker money. Empty auctions, censorship, worker unavailability, and funding failure do not satisfy that premise. The theorem assumes the hard systems problem away.” The draft already names these exceptions; that honesty should remain. Nevertheless, the connection between the market mechanism and the stochastic hypotheses is still the weakest substantive part of the application claim.

**Partly fixable framing; partly missing evidence.** Make the theorem's covered attack class explicit before it: repeated acceptance and withholding of jobs with unrecoverable bonds, once continued attempts and responsive participation are available. Describe the result as a recovery bound for that class. Do not imply that payment escalation alone produces `m_*`, participation, or a uniform `p`.

A useful replacement for one general interpretive sentence is:

> The bound applies to obstruction through forfeitable job commitments once responsive service is affordable and attempts continue; availability failures with no attributable forfeiture remain outside this guarantee.

For a stronger application paper, a compact protocol-to-assumption mapping would be more valuable than another theorem: identify what burns the bond, who can recover its proceeds, how another attempt is triggered, and what ensures an honest worker can bid and settle. Those facts must be established from the actual mechanism or an explicitly idealized instance. A numeric illustration of the tail bound would not substitute for this evidence. An equilibrium analysis is not required for the short-paper claim if the claim stays conditional.

### 5. The implementation paragraph currently gives names, not evidence

Location: `main.tex:218`–`221`.

Likely objection: “Does the stated 70B/TDX/Base implementation satisfy the abstractions, or is it merely compatible with the design?” An exact model and platform identify an implementation choice; they do not establish full measured execution, request binding, accepted attestations, execution cost, or market recovery. The sentence about unprotected accelerators usefully signals the issue but does not resolve it for this implementation.

**Substantive missing evidence if implementation assurance or practicality is claimed.** Either describe it explicitly as an illustrative implementation whose compliance and performance are not evaluated here, or provide one concise, verifiable end-to-end result. The best small addition would be an actual accepted inference-to-update trace with the identities/commitments checked, the covered hardware boundary, and one measured resource or latency figure. Add only data already verified or collected for the paper; do not manufacture an “evaluation” from configuration values. An anonymous artifact can support the claim, but is not a substitute for a short explanation in the paper.

This should not become a broad implementation audit or benchmark project simply to fit FC. The CFP permits work in progress. A clearly scoped formal application paper is defensible. What is hard to defend is implying a security-validated deployment while providing only a list of technologies.

### 6. The formal setup needs a slightly clearer reader map, not less formality

Location: Section 2.2, especially `main.tex:96`–`102`.

An FC cryptographer can follow the definitions, but the journal, invocation locator, semantic annotations, replay, and execution record arrive close together. They are necessary for the chosen exact reduction, yet the reason for this bookkeeping is easy to miss on a first read. The proof itself is proportionate; I would not lengthen it or remove its named algorithms.

**Fixable with one sentence outside formal environments**, replacing existing repetitive introductory prose if necessary:

> The experiment retains the contents behind registered commitments so that a forged settlement can be converted into a computation forgery without inverting a hash; the deployed ledger still stores only the physical records.

This tells the reader why the extra machinery exists before asking them to absorb it. It also makes the practical trust boundary clearer: the journal is a reduction interface, not a trusted live operator.

## What to preserve

* The authorization proof and governance analysis have different scopes. Do not silently extend the fixed-contract reduction to arbitrary adversarial verifier upgrades.
* The `Q` factor has an explicit reason and an appropriate tighter decidable case. It is not a useful target for cosmetic simplification.
* The recovery proof handles adaptive selection and separates probability-one premises from unconditional event inclusions. Do not trade those details for a more sweeping liveness slogan.
* The creator is merely one governor in the authorization allocation; the paper does not need a special owner threat model.
* The distinction between valid computation and good decisions is precise and appropriate. The brief safety discussion earns its space.
* Do not add a “first” claim, a large competitive feature matrix, an unsupported attack on Rocky or Ritual, or additional elementary propositions to create the appearance of more results.

## Minimal revision plan within eight pages

1. Retitle or revise the contribution paragraph to center self-governance and the three separate guarantees.
2. Expand the Ritual comparison by roughly one sentence, using only supported overlap and positive contribution statements.
3. Make the existing governance bypass example compute the two intervention families, with its closed transition scope explicit.
4. State the covered bonded-withholding attack before Theorem 2 and qualify the implementation's evidentiary status.
5. Add the single journal-motivation sentence. Pay for these edits by replacing overlapping roadmap, generic interpretation, and backend-survey wording—not by deleting assumptions or shortening proof-critical steps.

If the author can supply one verified execution trace and coverage/cost observation, that is the highest-value additional evidence. If not, submission as a precisely scoped short formal/application paper remains reasonable. The residual reviewer risk is modest incremental novelty and limited validation; improved prose cannot honestly eliminate those concerns.

## Source checks and limits

The FC CFP, Rocky announcement, and Ritual announcement above were inspected on September 20, 2026. The preceding comparison is limited to their explicit claims, not a full audit of either prior system. No claim is made that this assessment exhausts the prior-art search. I did not independently reproduce the stated 70B deployment or new benchmark numbers, and I assign no numerical acceptance probability.

## Focused re-review of the revised draft

The revised title is **“Short Paper: Consent and Scheduled Execution for On-Chain AI Agents.”** I reread the abstract, introduction, scoped governance definition and example, recovery framing, and implementation discussion after the coordinating author applied the review changes.

**Disposition: the main framing objections are addressed.** The title now advertises the contribution the paper actually develops. The abstract is easier to scan and describes the authorization result as composition, the recovery result as conditional, and the implementation as illustrative. The introduction gives an understandable progression from verified transactions to self-governance and execution opportunities. Rocky and Ritual receive specific, fair credit without unsupported claims about what their systems lack.

The consent scope is now an explicit part of the intervention specification; ordinary agent-approved payments need not discharge governance consent. The computed intervention families make the definition useful to a reader. The text also says that this is a property of a supplied transition model rather than a verification of deployed contracts. Detailed correctness of the repair remains the companion proof audit's remit.

The recovery section now identifies bonded withholding before stating its theorem, and the implementation section explicitly leaves conformance and performance unevaluated. These changes address the most consequential possible overreading. I found **no remaining material overclaim in the abstract or introduction** on this focused pass.

Two optional precision edits remain; neither warrants delaying the draft:

* “Partially order allocations of authority” in the abstract is slightly broader than the formal result, which orders induced intervention profiles. “Compare allocations of authority” is simpler and avoids implying antisymmetry on implementations or policies themselves.
* “We specify three separate guarantees” can be read as three established properties of the illustrative deployment, although the later qualifications are clear. “We formalize three separate security questions” or “Our analysis separates…” would emphasize that Section 3 supplies a property specification rather than certifying a particular deployment. The current wording is defensible in context.

The remaining reviewer risks are substantive: the authorization reduction composes standard guarantees, the governance framework is an application of access-control reachability, and the recovery theorem does not demonstrate that a real market satisfies its premises. There is still no implementation conformance evaluation or measured operational evidence. The revised presentation makes a coherent FC short-paper case for this combination, but cannot turn those limitations into empirical or cryptographic novelty. No further generic prose expansion is needed; any additional space should go to verified evidence or a directly useful example.
