# Paper writing conventions

These are the author's explicit preferences, recorded September 19, 2026.

- Keep proof environments formal. Put intuition, motivation, analogies, and
  commentary about the proof technique before or after the proof, not inside it.
- Name mathematical objects when they are introduced: algorithms, public
  parameters, hash keys, random tapes, oracle interfaces, computed outputs,
  transcripts, witnesses, and events. Show their inputs and sampling or assignment
  operations explicitly when these orient the reduction.
- Describe reductions as concrete algorithms. Specify oracle-query handling,
  outputs and abort conditions, establish the relevant distributional equality,
  and derive the probability or advantage bound. Formal prose is welcome;
  descriptive summaries must not stand in for the construction or derivation.
- Use "polynomial time" or "PPT" (defined on first use), not "efficient", for
  complexity claims. Do not alter titles of cited works to enforce this wording.
- Keep explanatory section introductions accessible. Readers may need mathematical
  fluency once a proof begins; do not dilute proofs to keep them accessible to a
  layperson. Spend detail on consequential steps, not routine algebra or boilerplate.
- State the ledger and verification properties actually used in the main text;
  citations give provenance and should not be required to reconstruct the argument.

The author-provided `ps4.tex` is a style reference for named reduction algorithms,
explicit variable assignments, and probability calculations. It is not a source
for the paper's results and must not be copied into the source bundle.

The author subsequently requested these conventions throughout the paper, including
the liveness proof, and a more explicit transition-system and reachability account
of Section 3. Incorrigibility must be stated as a property of a specified governed
agent, initial state, adversarial coalition, and intervention target, with paths and
the role of verified agent approval defined explicitly. Preserve the approved
abstract and introduction unless a later request or substantive consistency issue
requires changing them.

Section 3 uses a governance instance, a fixed reference agent relation, and labelled
transitions carrying the governor approvals used and a reference-consent bit. Keep
the contract's current agent-approval role distinct from the reference agent whose
consent is protected. Distinguish reachability with possible reference consent,
reachability without it, and targets unreachable even with consent. The profile is
the family of governor coalitions with a path lacking reference consent; smaller
families mean more protection. These are initial-state-relative, existential
reachability statements, not claims that a coalition can force the agent to agree
or can control transaction order.

Later author feedback on Theorem 1 adds the following requirements:

- Use "verified agent authorization" rather than "agent signature" for the
  construction. Conventional account signatures and hardware signatures retain
  their usual names. Update the abstract and introduction when needed for this
  terminology change; their previous approval does not freeze obsolete wording.
- Keep the authorization result independent of market and governance roles.
  Define the adversary by its algorithm and oracle access. Introduce governors and
  their Boolean policies in Section 3, and worker-market assumptions in Section 4.
- AuthForge is a numbered, labelled definition. Its setup, shared execution
  algorithm, observed objects, and winning predicate must be explicit.
- Do not use an unspecified "transcript" or "run the public ledger algorithms"
  as a substitute for defining mathematical objects. Name the initialization and
  transition algorithms, their inputs and outputs, oracle state updates, and the
  execution record. Define bad events as predicates on those objects.
- Theorem 1 uses an exact simulation and an event split. A hybrid game is optional
  presentation, not a missing proof step. The equality of execution distributions
  must follow from the specified algorithms and oracle interfaces.

Further author preferences for notation and exposition:

- Prefer descriptive algorithm/function names such as Msg, Chk, Req, Init, and
  Settle. Reserve single-letter function names for abstract functions, relations,
  circuits, or standard primitives. Use Ldg for the ledger protocol and Ctr for
  the contract; distinguish evaluation and ledger-command oracles explicitly.
- Use s and s' for application states before and after a settlement. Primed
  output-state notation is also used in the Ethereum Yellow Paper.
- Put brief high-level explanations and directions before or between formal
  blocks. Do not put this explanatory sugar inside definition, theorem, lemma,
  or proof bodies. Formal descriptions of variables and algorithms belong there.
- Define the authorization state machine as a generic transition gated by a
  message-validation predicate, show the signature-check instantiation, then
  substitute verified computation. Keep Section 2 independent of policy allocation.
- State Theorem 1 using a PPT adversary and an existential polynomial Q; define
  its verification-call bound in the proof. Omit the boilerplate negligible-
  advantage consequence, which is immediate for the intended technical reader.

The introduction should give a semi-formal construction overview before the fund
example. Introduce the ledger as an ordered transaction history inducing a
sequence of states, then smart-contract state and signature-gated authorization.
Next fix an agent harness and model weights, its ledger-derived request inputs,
and the verifiable-computation output. Finally show the replacement of the
signature predicate by the computation verifier, with the message bound to the
recorded program and inputs. Use the later notation sparingly and keep security
experiments out of this overview. Continue from the fund example and precedent to
agent consent, architectural incorrigibility, mixed governance, and execution.

The author then requested introductory subsections progressing from verified
computation as authorization to architectural incorrigibility and, finally,
scheduled execution and market economics. In the middle subsection, introduce
agent and governor approval bits and Boolean permission circuits. Show that
conjoining agent approval makes consent necessary; merely offering it as an OR
alternative would not remove an existing governor override. Describe Section 3's
partial order accurately: it is set inclusion on induced intervention profiles,
not a syntactic order on circuit descriptions. Keep the later whole-system,
reachability-based definitions as the formal basis for that overview.

The latest author request extends Section 2's formalism to the remaining sections
without removing the explanatory introductions. Section 3 now gives numbered
policy, governance-instance, path/reachability, incorrigibility, and profile-order
definitions. The reference authorization specification is fixed independently
of mutable contract rules; its consent bit is derived from credentials actually
used in the transition, not unused evidence attached to a witness. The ideal
reachability analysis is not itself a computational security reduction.

Retain Q in the general authorization theorem unless a simpler proof works for
its full relation model. The current proof does not assume polynomial-time
membership testing for R. A separate corollary removes Q when that test exists,
including a public deterministic program that can be recomputed in polynomial
time. Do not describe the Q loss as inherent, and do not silently narrow R or
change the single-output computation-forgery game to eliminate it.

The recovery theorem uses an explicit stochastic process with pre-outcome
histories, responsive-selection and success indicators, and nonnegative net
adversarial losses. Actual attempts must continue until success. Preserve the
conditional success bound, the pathwise total-loss budget, and the cost of every
post-threshold nonresponsive failure. Affordability alone proves none of these.
Calendar time and recurrence have their own stated premises and formal proof;
intuition and operational explanations remain outside formal blocks.

The author requested explicit interpretation of the recovery theorem's probability
one premises. It now names a common event Omega_* with Pr[Omega_*]=1, fixes versions
P_i of the conditional success probabilities, and states the premises pointwise.
Keep the counting inclusion intersected with Omega_*; an almost-sure premise does
not justify an unconditional set inclusion on its null complement.

For related work, cite predecessors directly and state the paper's added security
and governance contributions; avoid a defensive 'we do not claim first' sentence.
Use first-public dates when discussing chronology, and published proceedings
metadata when available. Mark accepted but unpublished proceedings 'to appear',
retaining an accessible preprint or extended-version link where appropriate.
The original project overview is dated April 2026; the July 21 Substack essay is a
later follow-up. Later verification papers are relevant backend developments,
not implied historical sources of the original architecture.

The conclusion should interpret the construction, including an AI-safety
subsection, rather than only restate results. Distinguish operational authority
from model behavior, and agent-held authorization secrets from backend or ledger
keys. Architectural incorrigibility is not automatically a safety improvement.

A subsequent independent proof audit made the logical-record interface explicit:
physical Rec_Ctr(s,e) constructs the verifier message, while experimental
Req_Ctr(s,e;Lambda,iota) reconstructs full contents from a retained registration
journal and invocation provenance. Replay receives Lambda, Z includes it, and
located settlement annotations identify the applicable records. Ledger Exec and
Safe remain physical and journal-free. Preserve this distinction and the exact
simulation when editing the proof.
