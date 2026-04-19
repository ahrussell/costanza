#!/usr/bin/env python3
"""Voice-anchor parsing and seed-deterministic rotation.

The full `voice_anchors.txt` file lives on the dm-verity rootfs and
contains 10 sample diary entries under a short header. At inference time
we only show the model 5 of the 10 so the anchors stay fresh epoch to
epoch (models are sensitive to repeated in-context exemplars — rotating
keeps voice drift low while reducing token pressure).

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
from typing import Tuple, List


# How many of the N entries to show the model per epoch. Fixed at
# deploy time (anchors file is part of the measured rootfs), but may
# be retuned during testing by rebuilding the image.
VOICE_ANCHOR_K = 5

# Divider that opens each entry: e.g. "─── Entry 1 ─────..."
_ENTRY_OPEN_RE = re.compile(r"^─── Entry (\d+) ─+\s*$")

# Divider that closes each entry: a line of bar chars. Tolerates a
# trailing newline but requires at least a handful of bars to avoid
# false matches on short horizontal rules.
_ENTRY_CLOSE_RE = re.compile(r"^─{3,}\s*$")


def parse_anchors(text: str) -> Tuple[str, List[str]]:
    """Split `voice_anchors.txt` into (header, [entry1, entry2, ...]).

    Each entry in the returned list is a complete self-contained block,
    starting at its opening `─── Entry N ───` divider and ending at the
    matching closing divider (inclusive). Concatenating selected entries
    with double newlines reproduces a valid `voice_anchors.txt`-style
    document.

    The header is every line before the first entry open divider,
    right-stripped of trailing whitespace but with internal formatting
    preserved.
    """
    lines = text.splitlines()
    total = len(lines)

    # Find all entry-open positions
    opens = [i for i, line in enumerate(lines) if _ENTRY_OPEN_RE.match(line)]
    if not opens:
        # No entries — treat the whole text as header.
        return text.rstrip(), []

    header = "\n".join(lines[: opens[0]]).rstrip()

    entries: List[str] = []
    for idx, start in enumerate(opens):
        # Search for the matching close: the first close-divider line at
        # position > start and before the next entry-open (if any).
        next_open = opens[idx + 1] if idx + 1 < len(opens) else total
        close_idx = None
        # Skip the opening divider itself when looking for a close.
        for j in range(start + 1, next_open):
            if _ENTRY_CLOSE_RE.match(lines[j]):
                close_idx = j
                break

        if close_idx is None:
            # Unterminated entry — grab everything up to the next open.
            close_idx = next_open - 1

        entry = "\n".join(lines[start : close_idx + 1]).rstrip()
        entries.append(entry)

    return header, entries


def select_anchors(header: str, entries: List[str], seed: int, k: int = VOICE_ANCHOR_K) -> str:
    """Pick `k` of `N` entries deterministically from `seed`, preserving
    original order.

    Returns a single string combining the header and the selected
    entries. The header is always included verbatim — only the sample
    diary entries rotate.

    If there are `k` or fewer entries, all entries are returned. If the
    seed is 0 or negative (pre-genesis edge), a fixed deterministic
    fallback of `seed = 0` is used — same selection every epoch, which
    is no worse than the pre-rotation behavior.
    """
    if not entries:
        return header.rstrip()

    if k >= len(entries):
        body = "\n\n".join(entries)
        return header.rstrip() + "\n\n" + body if header else body

    # Python's random.Random accepts any hashable seed, including large
    # ints. Bound negative or missing seeds to 0 for determinism.
    rng_seed = seed if (isinstance(seed, int) and seed > 0) else 0
    rng = random.Random(rng_seed)
    indices = sorted(rng.sample(range(len(entries)), k))
    body = "\n\n".join(entries[i] for i in indices)
    return header.rstrip() + "\n\n" + body if header else body
