# FC short-paper edition

**Short Paper: Architectural Incorrigibility for AI Agents through Smart Contracts**

This is a separate distillation of the full paper checkpointed in commit
`edd18c2` (`Checkpoint full paper after formal proof and reference review`).
That historical checkpoint remains in Git. At the author's subsequent request,
the full manuscript now also incorporates the scoped-consent and request-integrity
corrections, the safety-research proposal, and the agent-governed scheduling framing.

## Files and build

- Editable manuscript: `main.tex`
- Selected bibliography: `references.bib`
- Compiled paper: `../../output/pdf/fc-short-paper.pdf`
- Standalone source archive: `../../output/fc-latex-source.zip`
- Editorial decisions and verification record: `EDITORIAL_NOTES.md`
- Abstract/intro review, independent proof audit, and FC reviewer assessment:
  `reviews/README.md`

From the repository root:

```sh
bash paper/fc/build.sh
```

The script uses Tectonic or `latexmk`. An explicit Tectonic path is supported:

```sh
TECTONIC=/path/to/tectonic bash paper/fc/build.sh
```

Build intermediates go to `tmp/pdfs/fc-build/`. The standalone archive has its
own compilation instructions and does not depend on the full manuscript or
repository layout.

## Venue format

The draft has **eight pages of main text and two pages of references**, with
19 bibliography entries and no appendices. It uses the unmodified Springer
LNCS class and bibliography style, anonymous authorship, and the required
`Short Paper:` title prefix. It makes no margin, font-size, or spacing reductions.

Format checked against the [FC 2027 call for papers](https://www.ifca.ai/fc27/cfp.html)
and [ethics guidance](https://www.ifca.ai/fc27/ethics.html) on September 20, 2026.
The class and bibliography style come from the official
[Springer LNCS author template](https://link.springer.com/series/558/information-for-authors-and-editors)
(`llncs.cls`, version 2.25, September 3, 2026).

## Review status

This edition was submitted to FC 2027 as a short paper on September 20, 2026. The PDF builds without
LaTeX warnings and has been checked visually on every page. A subsequent
independent subagent proof audit and skeptical FC review are recorded in
`reviews/`. The audit prompted scoped intervention consent and an explicit
request-record integrity premise. No machine-checked proof or new empirical
evaluation is claimed.

The manuscript contains an anonymous AI-assistance declaration describing the
actual drafting and review workflow. Springer requires disclosure and author
accountability; see its [manuscript-preparation policy](https://www.springernature.com/gp/policies/editorial-policies/ai-manuscript-preparation).
The author reviewed and approved the final submission.

The source archive excludes this repository-specific README, editorial notes,
agent instructions, implementation links, and source provenance notes. The
illustrative deployment is described in the paper without naming or linking the
author's project.

## Final submission preparation

A final independent [skeptical review](reviews/final-review-2026-09-20.md) found
no new correctness blocker. Its one wording correction is incorporated, the PDF
is rebuilt and visually verified, and the source archive is refreshed. See
the private local `submission/` directory for portal metadata and artifact hashes.
The portal confirms that the paper is submitted and ready for review.
