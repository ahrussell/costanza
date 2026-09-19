# Bibliography audit, 20 September 2026

Scope: all 31 entries in `paper/references.bib`, their citation contexts in
`paper/main.tex`, and supporting notes in `paper/SOURCE_NOTES.md`. This audit does
not modify the manuscript or bibliography. Publication metadata below comes from
publishers, proceedings, author-hosted published PDFs, arXiv/ePrint records, and
official project documentation. Search indexes were used to locate primary
records, not to establish technical claims.

## Main corrections

1. **Pinocchio's author order is wrong in the current entry.** The published paper
   lists Bryan Parno, Jon Howell, Craig Gentry, Mariana Raykova. Use IEEE S&P 2013,
   pp. 238–252, DOI `10.1109/SP.2013.47`.
2. **DeepProve is accepted to CCS 2026, not merely an unclassified ePrint.** Cite
   the forthcoming proceedings and keep the ePrint URL until a final publisher
   version exists. The ePrint records receipt on May 30 and approval on June 2,
   2026. The cited LLM paper therefore postdates the April 2026 project overview.
   This does not date the earlier DeepProve product or code under the same name.
3. **NanoZK is accepted as a short paper at ICICS 2026.** The official conference
   program confirms the current title and author, Zhaohui Wang. The conference is
   October 27–30, 2026, so use “to appear” as of this audit. Keep the explicitly
   versioned July 18 arXiv v2 link: the manuscript's benchmark qualifications draw
   on that extended version. Its first preprint was March 17, before April.
4. Prefer official published records over ePrint/arXiv-only URLs for Gennaro,
   Pinocchio, Bitcoin Backbone, Ekiden, and zkLLM; use the official AAAI PDF for
   Corrigibility and official USENIX record for PBFT. Existing years and venues
   for these works are generally already correct.
5. Add missing published pages/publishers where readily verified. No need to
   replace a valid original conference citation with a later survey or abridged
   republication.
6. The Costanza architecture page is titled **“Meet Costanza”** and visibly dated
   **April 2026**. The July Substack narrative is not the first architecture
   announcement. Parent audit is checking the exact announcement chronology.

## Per-entry findings

“Reachable” means the browser research tool returned the intended primary
content, including a cached retrieval where that is how the tool supplies it.
It is not a claim that every server accepts every HTTP client. A 403, fetch
restriction, or cache miss is listed separately from a demonstrated dead URL.

| Key | Metadata and link finding | Recommended action |
| --- | --- | --- |
| `soares2015` | Current author order agrees with the actual paper: Soares, Fallenstein, Yudkowsky, Armstrong. Official AAAI proceedings PDF is reachable, first page 74, nine pages total. The MIRI PDF also works but is a differently formatted copy. | Use the [AAAI published PDF](https://cdn.aaai.org/ocs/ws/ws0067/10124-45900-1-PB.pdf), booktitle *Artificial Intelligence and Ethics: Papers from the 2015 AAAI Workshop*, pages 74–82, publisher AAAI Press. Do not adopt DBLP's conflicting Armstrong/Yudkowsky order; the paper itself is authoritative. |
| `offswitch2017` | [IJCAI proceedings record](https://www.ijcai.org/proceedings/2017/32) works and confirms all authors, title, year, pages 220–227, DOI `10.24963/ijcai.2017/32`. | Keep; optionally expand venue to *Proceedings of the Twenty-Sixth International Joint Conference on Artificial Intelligence*. |
| `benaloh1990` | Cornell scan works. [Springer chapter](https://link.springer.com/chapter/10.1007/0-387-34799-2_3) confirms authors, title, pages 27–35, LNCS 403, original copyright/citation year 1990. Its later digital publication date is not the original publication year. | Add DOI `10.1007/0-387-34799-2_3`, series/volume if desired; prefer publisher URL. Retain year 1990 and CRYPTO '88 venue. |
| `hru1976` | University-hosted published PDF works and confirms authors, journal 19(8), 461–471, August 1976. DOI is correct; ACM request returns a 403 to the research tool. | Keep correct DOI and the working [published PDF copy](https://www.cs.unibo.it/~babaoglu/courses/security07-08/resources/documents/harrison-ruzzo-ullman.pdf). The copy is already the published article, not a preprint. |
| `alpern1985` | Publisher search record confirms title, authors, 21(4), 181–185, October 7, 1985, DOI. Direct Elsevier/DOI retrieval is blocked; author-hosted published scan works. | Retain DOI and add [published article copy](https://www.cs.cornell.edu/fbs/publications/DefLiveness.pdf) as URL. |
| `ethereumaccounts` | [Documentation](https://ethereum.org/en/developers/docs/accounts/) works, redirecting to `/developers/docs/accounts/`. It is a living page; last content update shown is August 6, 2026. | Keep organization attribution and access date; update access date to September 20 if desired. The year represents the consulted documentation, not the origin of account authorization. |
| `openzeppelinaccess` | [Contracts 5.x documentation](https://docs.openzeppelin.com/contracts/5.x/access-control) works and explicitly covers contract ownership, multisig ownership, and roles. | Keep version and access date. No scholarly publication replacement is necessary. |
| `eip712` | Official page and [source metadata](https://raw.githubusercontent.com/ethereum/EIPs/master/EIPS/eip-712.md) work. Authors match; created September 12, 2017. | Keep. Citation scope is accurate: typed messages and domain separation do not supply application replay protection. |
| `erc1271` | Official page and [ERC source](https://raw.githubusercontent.com/ethereum/ERCs/master/ERCS/erc-1271.md) work. Six authors and order match; created July 25, 2018; final standard. | Keep. It supports state-dependent programmable validation, not the manuscript's particular `Settle` interface. |
| `gennaro2010` | ePrint works. [Springer published chapter](https://link.springer.com/chapter/10.1007/978-3-642-14623-7_25) confirms authors, pages, CRYPTO 2010, LNCS 6223. | Add DOI `10.1007/978-3-642-14623-7_25`, publisher Springer, and published URL. This is foundational VC; public verification is more directly supplied by the Pinocchio citation. |
| `pinocchio2013` | ePrint works, but its author order in the current BibTeX is not the published order. [IEEE conference PDF](https://www.ieee-security.org/TC/SP2013/papers/4977a238.pdf) works and shows the publication's DOI and first page 238, 15 pages total. | Change author order to Parno, Howell, Gentry, Raykova; add pages 238–252, DOI `10.1109/SP.2013.47`, publisher IEEE, URL to the published conference PDF. |
| `castro1999` | MIT PDF works. [USENIX record](https://www.usenix.org/conference/osdi-99/practical-byzantine-fault-tolerance) is reachable with official BibTeX confirming title, authors, OSDI 1999, February, USENIX Association. | Prefer official venue URL and publisher. No DOI is needed. |
| `garay2015` | ePrint works. [Springer record](https://link.springer.com/chapter/10.1007/978-3-662-46803-6_10) confirms title, authors, pages 281–310, EUROCRYPT 2015, LNCS 9057, DOI already in entry. | Prefer publisher URL; add series/volume/publisher optionally. No change to theorem attribution needed. |
| `commitprove2020` | [Third-workshop PDF](https://docs.zkproof.org/pages/standards/accepted-workshop3/proposal-commit_and_prove.pdf) works, exact title and three authors match; [official workshop program](https://zkproof.org/events/workshop3/) confirms the 2020 source. | Current citation is valid. A [2021 extended proposal](https://docs.zkproof.org/pages/standards/accepted-workshop4/proposal-commit.pdf) exists with four additional authors, but is a later standards proposal, not a journal/conference replacement required by the user's request. Retaining the precise 2020 definition source is reasonable. |
| `ekiden2019` | Current title matches the published paper; arXiv title adds “Execution,” so do not copy the preprint title over the published one. [Coauthor institutional publication record](https://experts.illinois.edu/en/publications/ekiden-a-platform-for-confidentiality-preserving-trustworthy-and-/) confirms EuroS&P 2019, 185–200, DOI `10.1109/EuroSP.2019.00023`. IEEE page exists but exposes only limited text through the tool. | Add pages, IEEE publisher, DOI, and use [IEEE record](https://ieeexplore.ieee.org/document/8806762/) or DOI URL. Existing author list uses Noah Johnson, as the institutional primary metadata does. |
| `verde2025` | [arXiv record](https://arxiv.org/abs/2502.19405) works; exact authors/order/title match; first submission February 26, 2025; only v1 listed. No published venue located in searches. | Retain preprint citation. Refereed delegation requires at least one honest participating provider; do not imply unconditional correctness merely because challenges are possible. |
| `truebit2017` | [arXiv record](https://arxiv.org/abs/1908.04756) works and was submitted August 12, 2019. [Author-hosted report](https://people.cs.uchicago.edu/~teutsch/papers/truebit.pdf) is dated November 16, 2017. No subsequent proceedings version located. | Either retain 2019 for the cited arXiv version and add a note that an earlier report dates to 2017, or cite the dated 2017 report. The internal key is not an error but current key/year mismatch can confuse maintainers. Do not silently imply the idea first appeared in 2019. |
| `zkllm2024` | arXiv works; published DOI is correct. ACM direct retrieval gets 403, but [coauthor-hosted published CCS PDF](https://hongyanz.github.io/publications/CCS_zkLLM.pdf) works, confirms title/authors/DOI and experiments. | Cite CCS 2024, pages 4405–4419, ACM publisher; use published PDF URL (and retain DOI). Source supports the table's forward-computation qualification. |
| `zkgpt2025` | [Official USENIX record](https://www.usenix.org/conference/usenixsecurity25/presentation/qu-zkgpt) and published PDF work. All seven authors/order correct. Official BibTeX supplies pages 2045–2063, USENIX Association, August 2025. | Add missing pages/publisher/month. Keep official URL. |
| `zkpytorch2025` | [ePrint](https://eprint.iacr.org/2025/535) works, authors/order/title match; explicitly marked preprint; received March 22, approved March 23, 2025. No published venue located. PDF endpoint could not be fetched by the research tool in this audit; the landing-page claim matches 150 seconds/token. | Retain preprint. Existing source notes' fuller Table 1/hardware check remains the evidence for single-core wording. |
| `zktorch2025` | [Versioned arXiv](https://arxiv.org/abs/2507.07031v2) and HTML work; authors/order/title match. First public submission July 9, 2025, v2 July 10. No published venue located. | Retain versioned preprint and explicit version. HTML Tables 3–4 confirm exact GPT-J/Llama-2 numbers and server resources. |
| `nanozk2026` | [v2 record](https://arxiv.org/abs/2603.18046v2) works. Official [ICICS 2026 program](https://sulab-sever.u-aizu.ac.jp/icics2026/programv3.html) lists NANOZK with current title and Zhaohui Wang in the short-paper program. | Cite forthcoming ICICS 2026 and note extended arXiv v2, July 18. No final chapter DOI/pages verified. Retain v2 URL rather than stale v1/author-webpage performance claims. |
| `deepprove2026` | [ePrint](https://eprint.iacr.org/2026/1112) works; author list/title match and venue field says CCS 2026. [Coauthor page](https://sshravan.github.io/) supplies forthcoming CCS metadata. Conference is November 15–19, after this audit. | Cite proceedings “to appear,” keeping ePrint URL; no final DOI/pages found. Received May 30, approved June 2, 2026. Full PDF endpoint not retrievable through the web tool here; manuscript numbers match the landing-page throughput and prior source-note audit. |
| `implementation2026` | Pinned GitHub tree and raw README links return research-tool cache misses, not an HTTP 404. Local repository contains the cited SHA. | Keep immutable source citation; parent should verify external reachability through direct HTTP if available. Do not substitute mutable HEAD simply to satisfy a bot-blocked client. |
| `russell2026` | [Architecture overview](https://ahrussell.com/writing/costanza/) works, title “Meet Costanza,” visible date April 2026. | Correct title and add month April. A retrieval date is not the announcement date. |
| `essay2026` | Research tool cannot access the Substack page (explicit fetch restriction), not a demonstrated dead link. Parent handles publication-date verification. | Keep if direct HTTP/current page confirms. Treat July narrative separately from April architecture announcement. |
| `rocky2022` | [Medium announcement](https://medium.com/@CountableMagic/chapter-3-the-worlds-first-on-chain-ai-trading-bot-c387afe8316c) works; title, organization author, August 19, 2022 match. | Keep. It is a technical announcement rather than a peer-reviewed paper; no published replacement found. |
| `rockycode2022` | Pinned GitHub tree and raw README return research-tool fetch errors/cache misses; source notes already document inspected commit. | Retain immutable citation pending direct HTTP check. Failure in this tool is not proof of dead URL. |
| `ritual2025` | [Official announcement](https://www.ritualfoundation.org/blog/unveiling-ritual) works, architecture claims support scheduling, modular verification, compute-marketplace discussion. | Keep; February 26, 2025 date was verified by parent in this turn. |
| `hermes4` | [Official model card](https://huggingface.co/NousResearch/Hermes-4-70B) works and identifies Hermes 4 70B based on Llama 3.1 70B. It recommends citing the [Hermes 4 Technical Report](https://arxiv.org/abs/2508.18255), first submitted August 25, 2025. | Model-card citation is appropriate for identifying exact artifact. Optionally add the technical report for author credit; no published proceedings replacement was found. Do not replace precise model-card link if artifact identification is the purpose. |
| `yellowpaper` | [Official PDF](https://ethereum.github.io/yellowpaper/paper.pdf) works; title, Gavin Wood, Shanghai version `efc5f9a`, February 4, 2025 all match first-page metadata. | Keep. It is being used for state-transition conventions, not as the current full Ethereum consensus specification. |

## Ready-to-apply replacement fields

Existing BibTeX keys can remain unchanged to avoid unnecessary manuscript churn.
These fragments list only the consequential new or corrected fields.

```bibtex
% soares2015
booktitle = {Artificial Intelligence and Ethics: Papers from the 2015 AAAI Workshop},
pages = {74--82},
publisher = {AAAI Press},
url = {https://cdn.aaai.org/ocs/ws/ws0067/10124-45900-1-PB.pdf}

% benaloh1990
series = {Lecture Notes in Computer Science},
volume = {403},
doi = {10.1007/0-387-34799-2_3},
url = {https://link.springer.com/chapter/10.1007/0-387-34799-2_3}

% alpern1985 -- retain existing published journal metadata and DOI
url = {https://www.cs.cornell.edu/fbs/publications/DefLiveness.pdf}

% gennaro2010
publisher = {Springer},
series = {Lecture Notes in Computer Science},
volume = {6223},
doi = {10.1007/978-3-642-14623-7_25},
url = {https://link.springer.com/chapter/10.1007/978-3-642-14623-7_25}

% pinocchio2013
 author = {Bryan Parno and Jon Howell and Craig Gentry and Mariana Raykova},
 pages = {238--252},
 publisher = {IEEE},
 doi = {10.1109/SP.2013.47},
 url = {https://www.ieee-security.org/TC/SP2013/papers/4977a238.pdf}

% castro1999
publisher = {USENIX Association},
url = {https://www.usenix.org/conference/osdi-99/practical-byzantine-fault-tolerance}

% garay2015
publisher = {Springer},
series = {Lecture Notes in Computer Science},
volume = {9057},
url = {https://link.springer.com/chapter/10.1007/978-3-662-46803-6_10}

% ekiden2019
pages = {185--200},
publisher = {IEEE},
doi = {10.1109/EuroSP.2019.00023},
url = {https://ieeexplore.ieee.org/document/8806762/}

% zkllm2024
pages = {4405--4419},
publisher = {Association for Computing Machinery},
url = {https://hongyanz.github.io/publications/CCS_zkLLM.pdf}

% zkgpt2025
pages = {2045--2063},
publisher = {USENIX Association},
month = aug

% nanozk2026 -- convert to @inproceedings; retain current author/title/year
booktitle = {Information and Communications Security---ICICS 2026},
publisher = {Springer},
note = {To appear; extended version arXiv:2603.18046v2, July 18, 2026},
url = {https://arxiv.org/abs/2603.18046v2}
% Omit guessed volume, pages, or chapter DOI. The first-public date is March 17.

% deepprove2026 -- convert to @inproceedings; retain current authors/title/year
booktitle = {Proceedings of the 2026 ACM SIGSAC Conference on Computer and Communications Security},
publisher = {Association for Computing Machinery},
note = {To appear; Cryptology ePrint Archive, Paper 2026/1112},
url = {https://eprint.iacr.org/2026/1112}

% russell2026
 title = {Meet Costanza},
 month = apr
```

## Citation-scope and chronology recommendations

- Cite Rocky positively as a direct predecessor and then state the added formal
  contribution: authorization security under the stated ledger/computation
  assumptions, consent-governed changes, and scheduled execution with a
  conditional economic recovery bound. An explicit “we do not claim first”
  disclaimer is unnecessary once the precedent and the incremental contribution
  are clearly stated.
- Rocky's blog itself says weights are passed with each inference. The sharper
  owner/input claim should continue to cite the pinned source, not only the blog.
  Do not infer that those source permissions establish the permissions of every
  deployed Rocky contract.
- Gennaro 2010 is foundational verifiable computation. Pinocchio is the direct
  public-verification interface reference. The paper should not imply that the
  generic hardware/evaluation-oracle relation game is copied verbatim from either.
- The commit-and-prove proposal motivates committed-value knowledge proofs; the
  manuscript still bears responsibility for its own hash-binding lemma and its
  extractor assumptions. A newer standards document is available, but not needed
  merely to make the old citation look current.
- Verde proves correctness conditional on an honest participating computation
  provider. The current one-sentence “challengers and dispute period” wording
  compresses this somewhat. A clearer version is: “Refereed delegation, as in
  Verde, compares multiple providers' results and resolves disagreements; its
  guarantee requires at least one honest provider and time to complete the dispute
  protocol.” This avoids equating its participant model with every optimistic
  challenge system.
- The zk table correctly separates forward-pass, token, full-sequence, and
  projected measurements. The published zkLLM and zkGPT versions support the
  existing numbers; ZKTorch HTML supports its detailed rows; NanoZK v2 supports
  the measured-versus-projected distinction. Do not substitute the NanoZK author's
  website's obsolete LLaMA-3-1B claims for the qualified v2 result.
- Describe DeepProve as a later backend development relative to April 2026. Describe
  NanoZK v2 as a later revision of earlier work. A later proceedings date alone
  does not make a paper later prior art when its preprint predates the architecture.
- Refer to works as “related work” or “recent verification backends” when their
  relationship is informational. Calling every cited item a construction this
  architecture “builds upon” would imply an unnecessary historical dependency.
- Nothing in this audit establishes a first-in-literature priority claim for the
  complete architecture. Credit the dated original announcement and state the
  paper's exact new formal claims; broad priority would require a separate,
  substantially wider literature search.

## Access limitations remaining

The browser tool returned no confirmed 404 for a cited source. It did return
access restrictions for Substack, cache misses for pinned GitHub source pages,
and anti-bot/limited-content responses for some ACM, Elsevier, and IEEE pages.
Working published PDF copies are supplied above where possible. The main ePrint
landing pages work even though two PDF fetches failed. A final delivery should
not claim every URL was live-tested successfully unless the parent completes
those direct HTTP checks.

## Parent verification and applied changes

All recommended publication metadata corrections were applied. Foundational papers now cite their published venues and official records or published PDF copies. NanoZK and DeepProve are marked forthcoming; no publication DOI or page range was guessed. The preprints for Verde, zkPyTorch, and ZKTorch remain because no published replacements were found. The manuscript now describes Verde’s honest-provider condition.

Direct HTTP GET checks were performed on all 31 final citation URLs plus nine DOI targets (40 requests). Status counts: 200: 34, 202: 3, 403: 2, 406: 1. No target returned a confirmed 404 or 410. Both pinned GitHub revisions and the Substack link returned HTTP 200. These results distinguish reachability from access to full content:

- Springer targets returned HTTP 200 with a cookie-support redirect; their intended metadata had also been verified through the research browser.
- IEEE targets returned HTTP 202, indicating a limited/challenge response rather than verification of their full page bodies; publication metadata was independently checked against primary PDFs and institutional records.
- ACM’s HRU DOI and the Rocky Medium post returned HTTP 403. The published HRU PDF works, and the Medium announcement was readable through the research browser.
- NanoZK’s arXiv URL returned HTTP 406 to the direct client, while the research browser retrieved the intended versioned record. Its canonical URL is retained.

These access restrictions do not justify describing every direct request as successful, nor do they establish that the references are dead.
