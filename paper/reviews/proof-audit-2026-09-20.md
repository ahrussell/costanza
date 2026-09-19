# Independent proof audit — September 20, 2026

Scope: all formal definitions and results in `paper/main.tex`, including the
authorization reduction, its decidability corollary, the committed-proof lemma,
the governance/reachability definitions, and the recovery/recurrence results.
This audit read the current manuscript independently; previous review conclusions
were not treated as evidence of correctness. Line numbers below refer to the
manuscript at the start of this audit and may shift during revision.

## Overall assessment

The inequalities and reductions are valid under the stated assumptions. I found
one substantive interface specification gap in the implementation of the exact
simulation, and two smaller formal-precision issues. None requires changing the
claimed bounds. I did not find a counterexample to the authorization bound, the
hash-collision reduction, the adaptive recovery bound, or the recurrence result
once the interfaces and probability-one events are made explicit.

## Findings requiring attention

### 1. Supply retained logical records to the replay algorithm

**Location:** lines 109, 239, 253–267, and the use of replay at lines 354 and 377.

The experiment receives full registered specifications and retains logical
request records in the protocol configuration `gamma`. However,
`Replay(sigma_0, H)` receives only the genesis state and finalized observations.
If an on-chain registration transaction contains only a model commitment,
replaying that transaction cannot recover the model contents needed by
`Req_Ctr(s,e)` and the reduction's output tuple. The current prose says that
replay uses its own logical request records but does not specify the source of
their full contents. This matters to both definability and polynomial running
time; collision resistance is not an algorithm for recovering preimages.

**Minimal repair:** expose an append-only journal `Lambda = Records_Ctr(gamma)`
of the full contents supplied at registration and the records needed for input
derivation. Associate entries with the relevant branch/ledger-entry/invocation
occurrence, rather than only a request identifier that could be reused across
different histories. At termination, pass `Lambda` to replay. `Init` and `Next`
can retain their current output interfaces because `gamma` already holds these
records. State that the instrumentation uses the journal to attach logical
annotations and checks their agreement with the corresponding commitments.

If execution validity compares these logical annotations as well as physical
ledger data, its instrumented execution routine must receive the same journal.
Alternatively, execution validity can compare physical ledger projections while
the experiment constructs logical annotations separately. This should not be
presented as requiring the ledger to store full model weights.

The reductions are otherwise unchanged: the simulator already generates the
protocol state and observes registration commands, so it can maintain the same
journal with the same distribution. Equality of the execution distributions
then includes the journal/instrumentation.

### 2. Distinguish bounded interaction from an executable winning predicate

**Location:** line 141 versus lines 380–385.

Definition 1 says that all computations in the security experiments are
polynomially bounded. Read literally as including the computation of the
winning predicate, this appears to supply a polynomial-time decision procedure
for `R`, although the general theorem deliberately does not assume one.

**Repair:** state polynomial bounds on descriptions, execution traces, algorithm
running times, and adversarial/oracle interaction; make clear that the winning
predicate uses the semantic relation `R`. Polynomial-time decidability of that
relation is the additional premise of Corollary 1. The distinction is familiar
from soundness experiments for general proof relations but should be explicit
here because it explains the `Q` loss.

The lossless corollary requires decidability, not determinism specifically.
Recomputable deterministic programs are one sufficient case; a relation with
multiple allowed outputs can also have a polynomial-time membership test.

### 3. Make the recovery proof's null-set qualification explicit

**Location:** lines 679–685, 703–708, and 729.

“Almost surely” is standard, fully formal terminology: an assertion holds on an
event of probability one. Its use in the theorem is mathematically correct.
However, the proof states a literal event inclusion after deriving inequalities
whose premises hold only with probability one. The probability bound remains
correct, but the inclusion is, strictly, only valid outside a null set.

**Repair:** let `B` be the common probability-one event on which the budget and
all costly-failure inequalities hold. The intersection is countable, so it still
has probability one. Establish `{T > M} intersect B subset E_n`, then use
`Pr(B)=1`. The parent is already replacing the theorem's prose with explicit
probability-one statements; this small adjustment makes the proof match that
presentation.

## Detailed checks that passed

### Authorization security and the lossless corollary

- Contract correctness plus a safe finalized execution gives eligibility,
  application correctness, and an accepting verifier invocation for every
  successful settlement. Consequently a bad authorization on a safe execution
  identifies an accepted false computation tuple.
- Replaying multiple histories can duplicate calls, but this does not invalidate
  the argument: it changes the polynomial upper bound `Q`, and every relevant
  invocation still appears among the sampled records.
- Selecting an index independently and uniformly from `1,...,Q` gives exactly
  `E[|I(Z)|/Q]`, including unused indices that return failure. The reduction does
  not test the potentially intractable predicate defining `I`.
- The ledger reduction is the same oracle algorithm and uses the same setup.
  The VC reduction can generate its own ledger setup/private protocol keys
  because the model gives it the public initialization and transition algorithms;
  computation-backend secrets remain behind the forwarded evaluation oracle.
- The two executions are identically distributed, rather than merely
  indistinguishable. No hybrid argument is needed.
- Once `R` is polynomial-time decidable, choosing the first member of `I(Z)`
  removes `Q` without changing the VC forgery experiment.

### Committed-proof lemma

- The lemma correctly uses extraction rather than treating collision resistance
  as mathematical injectivity or ordinary proof soundness as knowledge of an
  opening.
- Given the hash challenge key, the reduction samples the proof setup honestly,
  matching the joint hash/proof setup distribution in the VC game.
- Public evaluation-oracle calls are reproducible inside the prover, including
  their random coins. The extractor gets the inputs stated in the explicit
  extraction assumption.
- On accepted invalid contents with a valid extracted witness, at least one of
  model, input, or output differs. The commitment equations then give an actual
  pair of distinct, same-type encoded strings with equal hashes.
- The collision reduction need not decide `R`: it checks proof acceptance,
  validity of the extracted witness, and inequality of the two opening tuples.
- The claimed result is conditional on the particular extraction assumption
  written in the manuscript. It should not be read as proving that every SNARK
  or attestation backend satisfies that assumption. The manuscript already
  distinguishes attestation and states its separate obligations.

Minor notation polish, not a validity issue: write the collision adversary as
`D(1^lambda, K)` when it invokes setup on `1^lambda`; the present `D(K)` leaves the
security parameter implicit.

### Governance definitions

- The current agent-approval role and fixed reference authorization specification
  are distinct. Replacing a model/verifier cannot silently change whose consent
  is being measured.
- The reference bit comes from authenticated credentials actually used in the
  transition; attaching unused evidence does not set it.
- `Reach^0` is a subset of `Reach`. The existential reachability statement is
  correctly distinguished from a strategy that forces an execution.
- The incorrigibility condition and its universal-path formulation are
  equivalent, including the vacuous case where the target is unreachable even
  with consent.
- The family of successful governor coalitions is upward closed. Reverse
  componentwise set inclusion is a partial order on profiles, not on distinct
  governance implementations; the manuscript makes this distinction.
- The condition intentionally requires reference consent somewhere on each
  target-reaching path. It does not assert that every future modification is
  separately approved. The closing paragraph correctly records this limit.
  Stronger ongoing-consent claims would require reinitializing the analysis or a
  different property, but that is not a defect in the property currently defined.

### Recovery and recurrence

- On an unsuccessful prefix after the threshold, the budget and loss floor bound
  nonresponsive failures by `floor(W/d_min)`. Every other failed attempt in that
  prefix is a responsive selection.
- The selected indices `tau_j` are determined by pre-outcome information; the
  events used in the conditional-expectation calculation are measurable with
  respect to the stated filtration. Thus adaptive choices and correlated
  failures do not invalidate the geometric tail bound.
- The proof does not confuse a marginal success probability with the required
  conditional success lower bound.
- The recovery-process definition explicitly demands actual attempts until
  success. It therefore does not manufacture probabilistic trials after an
  auction or ledger stops advancing.
- Calendar time requires the separate bound on deadlines including gaps. The
  event containment establishing the time bound is correct.
- The recurrence argument conditions on each episode's initial history and uses
  induction plus a countable union of null events. A uniform positive lower
  bound across episodes is unnecessary; a positive within-episode bound is
  sufficient for the stated discrete recurrence result.
- Escalating bonds give the displayed cumulative-loss lower bound because the
  counter values at successive nonresponsive failures are increasing and the
  bond schedule is nondecreasing. The finite maximum `N_W` and substituted tail
  bound follow.
- The utility, withholding, and finite-resource inequalities are algebraically
  correct under their explicitly stated cost conventions.

The liveness result is conditional, as the manuscript says: affordability alone
does not establish participation, the conditional success bound, or a net cost
for every nonresponsive failure. No equilibrium, universal censorship resistance,
or unconditional calendar schedule follows from this theorem.

## Repairs applied after the parent authorized Section 2 edits

The parent asked this reviewer to implement the Section 2 repairs directly.
These changes are now present in `main.tex`; no build was run by this reviewer.

- The physical contract now exposes `Rec_Ctr(s,e)=(c,h_theta,h_x,r)` and constructs
  its verifier message from those commitments. It does not receive model
  contents or the experiment's journal.
- `gamma` explicitly retains an append-only registration journal
  `Lambda=Records_Ctr(gamma)`. Full registration contents were already part of
  the experiment's model; they are now retained and supplied to their consumers.
  `Init` and `Next` keep their existing output interfaces.
- Invocation locators distinguish a ledger prefix and invocation position.
  `Req_Ctr(s,e;Lambda,iota)` reconstructs the full request by its registration
  provenance, derives the prescribed snapshot input, and checks its hashes
  against the physical record. Missing/malformed data gives failure. Distinct
  forks or registrations are not merged by request identifier or hash alone.
- `Replay(sigma_0,H,Lambda)` receives the journal explicitly. Its verifier records
  retain their existing tuple shape, including the reconstructed logical request.
- The execution record is now `Z=(sigma_0,H,Lambda,Q)`. Successful settlement
  occurrences are located pairs `(iota,d)`, and the correctness predicate is
  `Correct_Ctr(iota,d;Lambda)`.
- `delta`, physical receipts, `Exec_delta`, and `Safe_delta` remain independent
  of the journal. The repair does not strengthen ledger safety with a claim
  about off-chain model contents.
- Theorem 1's game/event notation and reduction were updated. Exact simulation
  gives the same distribution of `(gamma,H)`, hence the same journal and `Z`.
  The decisive step explicitly invokes the registration/snapshot construction
  to obtain a reconstructible request. The runtime argument includes the
  journal and request algorithms. Corollary 1 inherits the updated `Z`, events,
  and record set without a different algorithm or bound.
- Definition 1 distinguishes polynomially bounded descriptions/traces and
  interactions from semantic evaluation of the winning predicate `R`.
- The collision adversary now explicitly receives `(1^lambda,K)`.

No numerical bound, cryptographic assumption, or profile/recovery definition was
changed by these repairs. The parent is handling the probability-one event in
the recovery proof separately.

### Follow-up check of the parent's probability-one revision

The revised Theorem 2 fixes a version `P_i` of each conditional success
probability and a common event `Omega_*` of probability one. Its premises are
pointwise on that event. The counting step and final event containment now
explicitly intersect `Omega_*`; the expectation calculation correctly uses that
its complement has measure zero. This resolves finding 3 without adding an
independence premise or changing the bound.

Section 3 refers to verified authorization through Definition 2 and its own
fixed reference specification, not through the modified `Req` algorithm's
interface. Its ideal reference-validity predicate remains consistent with the
physical/experimental distinction. No later equation or label reference requires
a change as a result of the Section 2 repairs. A textual scan found no stale
three-component `Z` or old `Req`, `Correct`, or `Replay` calls in `main.tex`.
`git diff --check` passed for the edited manuscript and this report.
