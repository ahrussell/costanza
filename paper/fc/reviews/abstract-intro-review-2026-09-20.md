# Abstract and introduction review — September 20, 2026

Local review by the coordinating editor. Independent proof and FC reviewer
reports are linked in the directory index. This review concerns the short
edition, not the approved introduction of the checkpointed full paper.

## Findings and changes

1. **The title foregrounded the most familiar component.** Replacing a signature
   gate with computation verification is useful, but predecessors already use
   verified neural outputs to authorize transactions. The revised title,
   *Consent and Scheduled Execution for On-Chain AI Agents*, points to the two
   systems questions that motivate the paper. It does not claim a new proof
   primitive or unconditional liveness.
2. **The abstract compressed the governance definition too much.** The original
   “relative to governor coalitions and intervention targets, with a partial
   order” gives readers several technical objects before their purpose. The
   revision says the construction allocates authority between the agent and its
   governors, and introduces incorrigibility for specified interventions. Its
   formal meaning remains in Section 3.
3. **The consent promise needed a narrower interpretation.** In light of the
   independent proof audit, the introduction now says consent to *specified
   interventions*. Approving an ordinary transaction does not count as consent
   to a future model change. Section 3 carries the precise scope and example;
   the introduction does not burden the reader with its added set notation.
4. **Prior art needed a more direct comparison.** The contribution paragraph now
   states that Ritual combines scheduled execution, TEE/ZK verification, and
   computation markets, alongside Rocky's proved neural transactions. The added
   work is the three-part specification and analysis, not a claim that those
   components are first combined here or absent from prior systems.
5. **The recovery claim needed an identifiable attack class.** The abstract and
   roadmap describe costly job withholding and explicit availability/funding
   assumptions. The detailed section distinguishes this from empty auctions,
   censorship, and unavailable data. Neither a profitable bid nor a bond alone
   establishes the theorem's availability conditions.
6. **The opening should connect to a concrete implementation without implying an
   evaluation.** The abstract now names Hermes 4 70B, Base, and Intel TDX secure
   enclaves with hardware attestation. Both it and the closing section call the
   implementation illustrative; the latter explicitly says conformance and
   performance are not evaluated in this paper.

## Reader checks

- **Educated general reader:** the abstract supplies the operator-dependence
  problem, the ledger/worker architecture, the role of verified decisions, and
  the distinction between authority and opportunities to exercise it. The
  reduction terminology may remain unfamiliar, but the system's purpose does
  not depend on understanding the security game.
- **Software engineer:** the introduction maps ledger state, an update `u`, the
  fixed agent program `theta`, the snapshot input `x`, output `(u,z)`, and
  verification to a familiar contract authorization check. It then applies
  that check to fund decisions and runtime changes before motivating execution
  scheduling. The three guarantees have distinct sections and assumptions.
- **Academic reader:** the novelty claim is compositional and qualified;
  computation outsourcing, attested contracts, Rocky, and Ritual are directly
  credited. The precise experiments and scoped reachability definition remain
  the source of the claims, rather than anthropomorphic readings of “consent.”

## Remaining judgment

The framing is clearer and more defensible. It does not create new technical
novelty or empirical evidence. The largest substantive next improvement would
be a verified end-to-end execution trace and evidence connecting the market
mechanism to its availability and net-cost assumptions. That work is outside
this editorial follow-up; no data or deployment validation has been invented.
