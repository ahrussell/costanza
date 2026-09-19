# Round 2: educated nontechnical skim reader

Scope: abstract/introduction, followed by the opening prose of every section and subsection. This review concerns the public explanation of the claims, not their technical proofs.

## Remaining changes

1. **The recovery summaries omit the minimum cost that makes the finite-budget argument work.** The abstract says "every obstructed attempt consumes an attacker's finite budget"; the introduction says each obstruction incurs an unrecoverable loss, so a finite budget buys finitely many delays. A reader can reasonably conclude that any positive loss suffices. Losses that keep shrinking would not support that conclusion. In both summaries, say **"each obstruction incurs at least a fixed positive loss"** or **"obstruction has a minimum unrecoverable cost."** In Section 4.3's opening, replace "costs the attacker money it cannot recover" with "costs the attacker at least a fixed amount it cannot recover."

2. **The abstract's recovery claim leaves out the workers' continuing chance of success.** Available and affordable workers could keep failing. The later Section 4.3 opening explains this clearly, but the abstract is meant to stand on its own. Minimal replacement for its theorem summary: "For continued execution, we prove a conditional recovery bound: with available, affordable workers that retain a minimum chance of success, and a minimum unrecoverable cost for obstruction, a finite attack budget yields a failure-probability bound that falls toward zero over repeated attempts." This also distinguishes the declining *bound* from a claim that the actual failure probability strictly decreases on every attempt.

3. **Section 3.3's "A shorter list means more protection" teaches the wrong comparison.** A smaller list could contain a different governor group and protect against different parties, as the later paragraph correctly explains. Replace with **"Removing groups from a list strengthens protection against that intervention."** No extra explanation is needed.

4. **Section 4.3's heading says "finite cost," but the condition is a finite attack budget and a lower bound on cost.** "Recovery under a finite attack budget" better tells a skimming reader what the section proves.

5. **Section 6's first sentence claims the implementation shows "the architecture's feasibility."** From this opening alone I would read that as an operational demonstration. The next sentences limit the evidence to a source-level mapping, and the joint-permission feature is an extension. Replace "shows both the architecture's feasibility and the need to inspect its permissions and payment rules separately" with **"makes the architecture concrete and illustrates why its permissions and payment rules must be inspected separately."**

## Skim-path coverage

I found no additional orientation gap in the openings of Sections 2.1–2.4, 3.1–3.2, 3.4, 4.1–4.2, 4.4, 5.1–5.2, 7, or 8. Each states the subject and its role before specialist detail. Section 3.2's small two-route display is followable from its surrounding prose; Section 5's opening explains why implementation choices belong after the recovery argument. Additional introductions or glossaries would add length without fixing a remaining skim-path failure.
