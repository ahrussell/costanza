# Submission venue assessment — September 20, 2026

This assessment concerns the current manuscript, *Verifiable Inference as Agent Authorization: Architectural Incorrigibility and Liveness*. I read its construction, governance definitions, conditional recovery analysis, implementation account, and the author's writing conventions. Venue facts below come from official calls checked on September 20, 2026. Assessments of fit and likely reviewer concerns are my judgment, not acceptance predictions. No submission or contact with organizers has been made.

## Recommendation

**WTSC is my best fit for the contribution at its present scale. FC 2027's short-paper track is the best verified opportunity to try immediately.** A full journal article at ACM DLT is the alternative if retaining the detailed presentation matters more than a conference deadline. I would not initially aim at a main cryptography conference or a main machine-learning conference: this paper combines established primitives into a useful architecture and formalizes its guarantees; it does not introduce a new proof system, learning method, or substantial experimental result.

The current paper has three different kinds of contribution: a security composition result, a framework for comparing governance permissions, and a conditional recovery bound. Its strongest selling point is their application to operator-independent agents, including the creator as an ordinary permission holder. Its mathematical arguments are deliberately elementary. That can be appropriate for a focused workshop or application-oriented short paper; additional notation by itself will not make the work a stronger full-conference theory submission.

## Ranked shortlist

### 1. Workshop on Trusted Smart Contracts (WTSC), associated with Financial Cryptography

**Best topical and proportional fit; next call not verified yet.** WTSC's stated interests include execution models, authentication, access rights, governance, verification, resilience, and economic sustainability. Its 2026 call offered peer-reviewed papers in Springer LNCS, with a 15-page LNCS limit excluding references and appendices. It also invited inquiries about short papers, work in progress, demos, and posters. The 2026 event and deadlines have passed. I did not find a confirmed WTSC 2027 paper call; the 2026 rules are evidence of the series' fit, not a promise about next year's format or dates. [Official WTSC 2026 call](https://www.ifca.ai/fc26/wtsc/cfp.html).

**My assessment:** the audience should understand why verified authorization and mutable administrative permissions belong in the same model. The paper does not have to pretend to be a new cryptographic primitive. Compress the broad backend survey and move selected technical detail to an appendix if the next call retains that format. Add one fully worked governance instance showing a non-obvious bypass and its repair; this would demonstrate that the framework does useful work beyond introducing names.

### 2. Financial Cryptography and Data Security 2027 — short paper

**Best immediate archival opportunity, with a real but uncertain chance.** The official deadline is **September 24, 2026, 23:59 AoE**, extended from September 17. Short papers have an **8-page LNCS limit excluding references, with no appendices**. They receive peer review and appear in the proceedings; the track explicitly welcomes novel applications and work in progress. Regular papers allow 15 pages plus references and appendices. The conference is February 8–12, 2027 in Barbados. [Official FC 2027 call](https://www.ifca.ai/fc27/cfp.html).

**My assessment:** the short track suits a concise architecture-and-guarantees contribution better than an expansive full paper. Keep the authorization theorem, one clear governance example, and the conditional recovery statement; sharply reduce backend comparisons and implementation detail. Do not cut the hypotheses that make the claims true. Fitting the present exposition into eight LNCS pages is a substantive rewrite, not a template conversion. The regular track is a stretch because reviewers may regard the reduction and geometric tail bound as standard composition arguments and ask for stronger validation or a less immediate theoretical consequence.

### 3. ACM Distributed Ledger Technologies: Research and Practice (DLT)

**Best journal-shaped home for the full treatment.** ACM describes DLT as a peer-reviewed, interdisciplinary journal covering theory, deployment, formal verification, smart-contract governance, and security. Its scope accommodates both a construction and a practice-oriented instantiation. [Official ACM journal call](https://www.acm.org/binaries/content/assets/publications/dlt-cfp.pdf), [journal site](https://dl.acm.org/journal/dlt).

**My assessment:** a journal route gives room to retain the self-contained definitions and proofs and to revise in response to reviewers. I would strengthen the implementation section before choosing it: identify an immutable code revision, give one reproducible complete execution with cost and timing, and distinguish the implemented permissions from the generalized architecture. There is no need to invent a large benchmark campaign. A small, defensible artifact would answer the most obvious practical objections. I could verify the journal's scope, but its current author-guideline pages blocked automated access; I therefore do not assert a current page limit, APC, review duration, or special-issue deadline. Recheck those details before formatting a submission.

### 4. ACM TRUST 2027 — Secure and Resilient AI Systems or Trustworthy AI in Systems and Infrastructure

**An open interdisciplinary alternative with more preparation time.** The official call lists abstract registration on **October 24, 2026** and paper submission on **October 31, 2026**. It accepts theories, architectures, systems, and governance contributions, uses double-blind review, and permits nine ACM two-column pages including appendices, with additional pages for references and a required GenAI-use disclosure. It is scheduled for March 7–9, 2027 with hybrid participation. [Official TRUST 2027 call](https://eigtrust.acm.org/trust2027/cfp/), [conference page](https://eigtrust.acm.org/trust2027/).

**My assessment:** this can reach readers interested in who controls an agent's runtime, although they may be less familiar with ledger semantics. Present architectural incorrigibility as a precise allocation of intervention powers, not as a general safety improvement. A concrete discussion of safety consequences and limited emergency authority would help. The call fits; I have less evidence about this venue's established audience and selection norms than for FC/WTSC, so I rank it below them. Its broader scope is not evidence that acceptance is easier.

### 5. Advances in Financial Technologies (AFT) — a future full-paper target

**Strong audience fit, but a stretch and not an open 2026 opportunity.** AFT covers smart-contract verification, protocol governance, secure hardware, auctions, and mechanism design. Its 2026 call permitted 20 LIPIcs pages excluding the title page and bibliography, with open-access proceedings. Submission closed May 27, 2026; no verified 2027 deadline is reported here. [Official AFT 2026 call](https://aft.ifca.ai/aft26/CFP.html).

**My assessment:** to justify waiting for this route, strengthen at least one pillar: a meaningful mechanized governance case study, empirical market/availability evidence, or a mechanism result that establishes more of the current liveness assumptions. The recovery theorem assumes that every failed nonresponsive attempt consumes adversarial budget and that responsive attempts retain a conditional success probability; it does not derive those facts from an auction equilibrium. Reviewers interested in economic mechanisms will notice that distinction. More market terminology would not substitute for such a result.

## Other venues checked

- **BSS 2026 (Blockchain Security and Scalability):** unusually close topical wording includes verifiable agent actions and decentralized governance. Its deadline is today, September 20, 2026; the published format is six IEEE pages including references, with up to two extra pages subject to confirmation. I would not rush a severely shortened version just to meet this date. The submission page also says parts of its 2026 review process remain subject to confirmation. [Call](https://inbss.com/call-for-papers.html), [submission rules](https://inbss.com/submission.html).
- **AISec at ACM CCS:** a credible AI-security workshop series, including autonomous-agent containment and position papers. Its 2026 deadline was July 24 and is closed. A future edition could suit a version emphasizing the security consequences of removing operator override, but it is not a current submission option. [Official AISec 2026 call](https://aisec.cc/).
- **PAgE at PLDI:** a good community for agent runtime semantics and formal control. Its 2026 call distinguished archival ten-page research papers from non-archival six-page contributions, but that event is over and a successor call has not been verified here. A non-archival presentation would be useful feedback rather than a substitute for publication. [Official PAgE 2026 call](https://pldi26.sigplan.org/home/page-2026).
- **NANDA at IEEE TPS 2026:** a related decentralized-agent workshop, but its September 17 deadline has passed and its four-page limit including references is too restrictive for the present proofs. [Official workshop call](https://projectnanda.org/workshops/ieeetps26/).

## Smallest useful preparation before submission

1. State the contribution in one paragraph as a security construction plus a governance analysis and a conditional execution guarantee. Credit prior verified-model transaction authorization without making the paper's value depend on priority over that whole idea.
2. Add one complete, finite governance example whose coalition profiles can be checked by the reader. The important payoff is identifying a path that bypasses apparent consent requirements and showing exactly which rule removes it.
3. If presenting the implementation as evidence of practicality, record one reproducible execution and the precise hardware/code/model configuration. Otherwise consistently call it an illustrative implementation and make no new performance claim.
4. Retain the strong hypotheses in the recovery result. Explain which are delivered by the contracts and which require an external worker, network, and funding model.
5. Prepare the venue's format and anonymization separately from the full public paper. Follow the selected venue's AI-assistance disclosure policy; TRUST and AISec explicitly require disclosure. Do not submit overlapping versions to archival venues concurrently.

My practical choice would be **a focused FC short-paper attempt now only if an eight-page version can preserve the argument without rushing correctness; otherwise a WTSC submission when its next call is confirmed**. If the priority is to publish the present extended treatment, choose the journal route and add the small implementation/governance case study first. These are alternatives, not a proposal to submit the same paper simultaneously.
