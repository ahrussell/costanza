# FC short-paper edition

This is a separate venue-specific distillation of the full paper checkpointed at
`edd18c2`. The author explicitly permits changes to style, notation, and prose for
the FC audience. Changes to this edition do not implicitly authorize changes to
the full manuscript. The author subsequently explicitly requested that its
consent and request-integrity corrections be ported to the full paper, along with
the new safety-research and scheduling framing; those changes are now present.

Use unmodified Springer LNCS layout. FC 2027 short papers have at most eight pages
of main text, excluding references, and no appendices. Use anonymous authorship
and a title beginning `Short Paper:`. Retain formal proofs and self-contained
assumptions, with motivation outside formal environments. Keep authorization
security separate from governance and worker-market assumptions.

Do not imply that an auction alone establishes responsiveness, a net cost for
every failure, transaction inclusion, or indefinite funding. Preserve reference
agent identity when analyzing mutable governance rules. The partial order is on
intervention profiles, not syntactic circuit descriptions. Use verified agent
authorization, not agent signatures.

The independent FC audit added two requirements. An intervention specification
is a pair (J,D): target states and an explicitly declared scope of transitions
whose reference authorization grants consent to that intervention or delegates
the relevant right. Paths without scoped consent may contain ordinary agent
approvals outside D. Never revert to counting any prior agent approval as
consent to an unrelated intervention. Compare profiles for fixed (J,D), reference
agent, governor identities, and environment.

The authorization theorem explicitly assumes request-record integrity: eligible
records remain immutable and retain matching registration/snapshot provenance
through every correctly executed reachable state. Creation-time registration
alone is not enough. Changes require consumption or invalidation as appropriate.

This is a preparation directory, not authorization to submit a paper. Keep private
editorial notes out of the review PDF and submission source bundle.

Prefer transitions and room for the main ideas over minor payment formulas or
benchmark details. Preserve the formal proofs and their assumptions. The safety
proposal concerns behavior under inspectable intervention and scheduling rights;
do not equate enforcement with model understanding or claim a measured safety
benefit. Distinguish behavioral training-cue results from activation interventions
in deliberately trained evaluation-aware models. Scheduling can be agent-governed;
auctions reduce operator dependence, bonds deter nondelivery, and a calendar rule
bootstraps execution and enables recovery without a fresh agent decision.

The author subsequently preferred architectural incorrigibility as the central
title concept. The current title is "Short Paper: Architectural Incorrigibility for AI Agents through Smart Contracts"; earlier reviewer title recommendations are historical.
The property is broader than blockchains; the title names this construction's
mechanism. Introduce the smart-contract blockchain explicitly, then use "ledger"
for the formal abstraction. Inference itself need not occur on-chain.
The abstract explicitly proposes the alignment-research use without claiming
that the experiment has been performed.
