# Architectural Incorrigibility and Conditional Liveness in Ledger-Governed Agents

`main.tex` and `references.bib` are the editable manuscript. The compiled paper is
`../output/pdf/architectural-incorrigibility.pdf`.

Build from any directory:

```sh
bash paper/build.sh
```

The script accepts Tectonic or a TeX installation with `latexmk` and BibTeX.
To use a particular Tectonic binary:

```sh
TECTONIC=/path/to/tectonic bash paper/build.sh
```

Tectonic downloads its packages on its first run. The initial build for this draft
used Tectonic 0.17.0, downloaded to `/tmp/costanza-latex/tectonic`; that temporary
path may not survive a restart. No system TeX installation is required if a
Tectonic binary is supplied. Build intermediates go to `../tmp/pdfs/build/`.

The author field is intentionally blank for the author to finalize. The article
format is venue-neutral. Literature was checked through September 19, 2026.

## Scope

The paper presents an architectural model, elementary permission characterizations,
and a conditional liveness theorem. It does not claim an auction equilibrium,
perpetual operation, a new proof system, machine-checked proofs, or a new empirical
evaluation. The code discussion is a source-level case study at the cited revision;
no mainnet configuration or performance claims were independently measured.

`SOURCE_NOTES.md` records the evidence behind implementation and benchmark claims
and explains material departures from the whitepaper. These notes are for editing
and are not included in the paper.

`reviews/README.md` records two rounds of reader reviews and their resolutions.
The six individual reviews and the pre-review manuscript are retained there for
comparison; none are included in the compiled paper.
