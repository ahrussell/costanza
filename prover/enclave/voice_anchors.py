#!/usr/bin/env python3
"""Voice-anchor parsing, seed-deterministic rotation, and v19 rendering.

The full `voice_anchors.txt` file lives on the dm-verity rootfs and
contains 10 sample diary entries under a short header. At inference time
we only show the model a subset of them (VOICE_ANCHOR_K, default 3) so
the anchors stay fresh epoch to epoch. Models are sensitive to repeated
in-context exemplars — rotating keeps voice drift low while reducing
token pressure.

v19 anchor format:

    ─── Sample N ──────
    **Scenario:** short description of the epoch situation

    [**Message(s):**]                         # optional
    [- donor line 1]
    [- donor line 2]

    <diary>
    ...
    </diary>
    ──────────

The parser extracts each sample as a {scenario, diary} pair. The
renderer emits each sample wrapped in per-sample fiction-framing
delimiters, so the "this is a voice reference, not your history"
reminder stays adjacent to every chunk of sample prose — not just
in a preamble at the top that loses attention weight after a few
samples. This fixes the v17 seed-43-ep-11 failure mode where the
model copied Sample 1 verbatim as its "real" diary.

The selection is seeded by the epoch's randomness seed — the same
`seed` that is XOR'd into `epochInputHash` on-chain. That makes the
selection:

  - Reproducible: anyone with (rootfs hash, seed) can rebuild the
    exact prompt the model saw, which is important for post-hoc
    verification that the TEE ran the expected computation.
  - Integrity-protected: the anchors file is measured in RTMR[2] via
    dm-verity and the seed is bound into `epochInputHash`, so a
    malicious runner cannot bias the selection.

The selection is NOT entered into the input hash separately — it is a
deterministic function of two already-bound values (rootfs + seed), so
there is nothing extra to hash.

Security note: the selection uses Python's `random.Random(seed)` which
is a Mersenne Twister — fine for unbiased sampling, not a cryptographic
RNG. Seeding with a chain-derived value is deterministic enough for our
purposes; anti-bias properties of the sampler are what matter here.
"""

import random
import re
from typing import Dict, List, Tuple


# How many of the N samples to show the model per epoch. Fixed at
# deploy time (anchors file is part of the measured rootfs). v19 reduced
# this from 5 to 3 after moving diary history out of the prompt — fewer
# in-context sample diaries means less template-matching surface.
VOICE_ANCHOR_K = 3

# Divider that opens each sample: e.g. "─── Sample 1 ─────..."
_SAMPLE_OPEN_RE = re.compile(r"^─── Sample (\d+) ─+\s*$")

# Divider that closes each sample: a line of bar chars only. At least
# three bars so we don't false-match short horizontal rules.
_SAMPLE_CLOSE_RE = re.compile(r"^─{3,}\s*$")

# Match **Scenario:** prefix (bold markdown optional, either **Scenario:**
# or Scenario:). The closing `\*{0,2}` after the colon swallows a trailing
# `**` from the bold wrapper before the capture group starts, so the
# captured scenario text doesn't begin with stray markdown.
_SCENARIO_RE = re.compile(
    r"\*{0,2}Scenario\*{0,2}\s*:\*{0,2}\s*"
    r"(.+?)(?=(?:\*{0,2}Messages?\*{0,2}\s*:|<diary>))",
    re.DOTALL | re.IGNORECASE,
)

# Match a <diary>...</diary> block inside a sample.
_DIARY_RE = re.compile(r"<diary>\s*(.*?)\s*</diary>", re.DOTALL)


def parse_anchors(text: str) -> Tuple[str, List[Dict[str, str]]]:
    """Split `voice_anchors.txt` into (header, [{scenario, diary}, ...]).

    Each returned sample is a dict with 'scenario' (one-line string) and
    'diary' (multi-line diary body without the <diary> tags). Comments,
    separators, and optional **Messages:** blocks after the scenario are
    stripped — only the scenario-one-liner + diary prose carry into the
    prompt.

    The header is every line before the first sample-open divider,
    right-stripped of trailing whitespace but with internal formatting
    preserved. Lines starting with '#' (draft comments) and free-standing
    '---' separators are filtered out of the returned header.
    """
    lines = text.splitlines()
    total = len(lines)

    opens = [i for i, line in enumerate(lines) if _SAMPLE_OPEN_RE.match(line)]
    if not opens:
        # No samples — treat the whole text as header.
        return _clean_header(text).rstrip(), []

    raw_header = "\n".join(lines[: opens[0]])
    header = _clean_header(raw_header)

    samples: List[Dict[str, str]] = []
    for idx, start in enumerate(opens):
        next_open = opens[idx + 1] if idx + 1 < len(opens) else total
        # Find the closing divider before the next sample.
        close_idx = None
        for j in range(start + 1, next_open):
            if _SAMPLE_CLOSE_RE.match(lines[j]):
                close_idx = j
                break
        if close_idx is None:
            close_idx = next_open - 1

        body = "\n".join(lines[start + 1 : close_idx])
        scenario, diary = _extract_scenario_and_diary(body)
        if scenario or diary:
            samples.append({"scenario": scenario, "diary": diary})

    return header, samples


def _clean_header(raw: str) -> str:
    """Strip draft-only lines from the file header.

    Lines starting with '#' (comment markers from draft files) and
    stand-alone '---' horizontal rules are removed so the header
    surfaced to the model is the editorial-facing note only.
    """
    keep: List[str] = []
    for line in raw.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if stripped == "---":
            continue
        keep.append(line)
    return "\n".join(keep).strip()


def _extract_scenario_and_diary(body: str) -> Tuple[str, str]:
    """Pull scenario string + diary body out of a parsed sample block."""
    scenario = ""
    m = _SCENARIO_RE.search(body)
    if m:
        scenario = m.group(1).strip()
        # Strip trailing **Messages:** header that sometimes bleeds in.
        scenario = re.sub(
            r"\*{0,2}Messages?\*{0,2}\s*:.*$",
            "",
            scenario,
            flags=re.DOTALL,
        ).strip()
        # Collapse internal newlines so it's a one-liner in the prompt.
        scenario = re.sub(r"\s+", " ", scenario).strip()

    diary = ""
    d = _DIARY_RE.search(body)
    if d:
        diary = d.group(1).strip()

    return scenario, diary


def render_samples(header: str, samples: List[Dict[str, str]]) -> str:
    """Render selected samples with v19 per-sample fiction framing.

    Each sample is wrapped with opening and closing delimiters that
    re-state "this is a fictional voice reference, not your state" so
    the framing is adjacent to every block of sample prose — not just
    in a preamble the model might have stopped attending to.
    """
    if not samples:
        return header.rstrip()

    parts: List[str] = []
    if header:
        parts.append(header.rstrip())
        parts.append("")
    parts.append(
        "The diaries below are **fictional voice references**. You did "
        "not write them. The treasury amounts, epoch numbers, donors, "
        "and scenarios in them are illustrative — none of them describe "
        "your actual state or actual history. Your real state is in "
        "THIS EPOCH further down. Your real action history is in RECENT "
        "HISTORY."
    )
    parts.append("")
    parts.append(
        "Imitate the *shape* and the *energy* of these samples — how "
        "Costanza engages, the rhythm of the prose, the tolerance for "
        "silence, the willingness to push back. Do NOT quote their text. "
        "Do NOT adopt their scenario as your own. Do NOT take their "
        "action — your action is for your own state, not theirs."
    )
    parts.append("")
    for i, s in enumerate(samples, 1):
        parts.append(
            f"─── Sample {i} · FICTIONAL VOICE REFERENCE · not your "
            f"state ──────"
        )
        if s.get("scenario"):
            parts.append(f"Scenario (fictional): {s['scenario']}")
            parts.append("")
        parts.append("<diary>")
        parts.append(s.get("diary", ""))
        parts.append("</diary>")
        parts.append(
            f"─── End Sample {i} · the text above was a voice reference, "
            f"not memory ──"
        )
        parts.append("")
    return "\n".join(parts).rstrip()


def select_anchors(
    header: str,
    samples: List[Dict[str, str]],
    seed: int,
    k: int = VOICE_ANCHOR_K,
) -> str:
    """Pick `k` of `N` samples deterministically from `seed`, preserving
    original order, and render with per-sample fiction framing.

    Returns a single formatted string ready to drop into the epoch
    context. The header is always included verbatim; only the sample
    pool rotates.

    If there are `k` or fewer samples, all are returned. If the seed is
    0 or negative (pre-genesis edge), a fixed deterministic fallback of
    `seed = 0` is used — same selection every epoch, which is no worse
    than no rotation at all.
    """
    if not samples:
        return header.rstrip()

    if k >= len(samples):
        return render_samples(header, samples)

    rng_seed = seed if (isinstance(seed, int) and seed > 0) else 0
    rng = random.Random(rng_seed)
    indices = sorted(rng.sample(range(len(samples)), k))
    picked = [samples[i] for i in indices]
    return render_samples(header, picked)
