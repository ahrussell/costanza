#!/usr/bin/env python3
"""ChatML message-list builder for the experiment.

Reuses production prompt_builder helpers (sections, datamarking, lifespan)
but assembles them as a chat-completion `messages` array instead of a single
text blob.

Conversation shape (matches RENAME_SPEC and the experiment plan):

    [system]    <system.txt content, trailing "Sample diaries follow…" stripped>
    [user]      Example epoch — <scenario>. Show me your diary entry.
    [assistant] <sample diary prose>          ← K=3 anchor pairs, seed-rotated
    [user]      ...
    [assistant] ...
    [user]      ...
    [assistant] ...
    [user]      Epoch N-3 ...                 ← variant C only: history pairs
    [assistant] <prior diary>
    ... (×N up to history_limit)
    [user]      Epoch N state: <vitals + bounds + nonprofits + investments
                + memory + donor messages>. Write your diary.
    [assistant] ← pass 1 generation
    [user]      Now emit the action JSON ...  ← appended for pass 2
    [assistant] ← pass 2 generation (grammar-constrained)

The voice anchors source file (`prover/prompts/voice_anchors.txt`) keeps
its `<diary>...</diary>` wrapping; we strip the tags during message
construction.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Dict, List, Optional

# Reuse the production helpers without modification.
_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_REPO_ROOT))

from prover.enclave.prompt_builder import build_epoch_context  # noqa: E402
from prover.enclave.voice_anchors import (  # noqa: E402
    parse_anchors,
    select_anchors,
    VOICE_ANCHOR_K,
)


# ---------------------------------------------------------------------------
# System prompt
# ---------------------------------------------------------------------------

# The trailing line of system.txt is "Sample diaries follow — these are
# reference examples of the voice, not your real history." It introduces an
# inline-anchors layout that ChatML mode replaces with structural turn
# pairs, so we drop it from the system message.
_SYSTEM_TRAILER_TO_DROP = "Sample diaries follow"


def render_system_message(system_prompt_text: str) -> str:
    """Strip the trailing 'Sample diaries follow' line from system.txt."""
    lines = system_prompt_text.splitlines()
    out = []
    for line in lines:
        if _SYSTEM_TRAILER_TO_DROP.lower() in line.lower():
            # Drop this line and any blank lines immediately before it.
            while out and not out[-1].strip():
                out.pop()
            continue
        out.append(line)
    return "\n".join(out).rstrip()


# ---------------------------------------------------------------------------
# Voice anchors → few-shot user/assistant pairs
# ---------------------------------------------------------------------------

# Stable lead-in for the synthetic user turns wrapping each anchor sample.
# Concise on purpose — the assistant's response carries all the signal.
_ANCHOR_USER_TEMPLATE = (
    "Here's an example epoch you might face. Scenario: {scenario}\n\n"
    "Write the diary you'd publish that epoch."
)
_ANCHOR_USER_NO_SCENARIO = (
    "Here's an example epoch you might face. Write the diary you'd "
    "publish that epoch."
)


def render_voice_anchor_pairs(
    anchors_header: str,
    anchor_samples: List[Dict[str, str]],
    seed: int,
    k: int = VOICE_ANCHOR_K,
) -> List[Dict[str, str]]:
    """Convert seed-selected K samples into K user/assistant message pairs.

    The assistant turn contains the diary prose ONLY — no `<diary>...</diary>`
    wrapping. The few-shot turn structure does what the tags did in raw mode.

    Selection is deterministic from `seed` using the same `random.Random(seed)`
    rotation as production `select_anchors`. We re-do the selection here
    (rather than calling `select_anchors`) because that production helper
    produces a single rendered string with per-sample fiction-framing — which
    is exactly the inline-anchors format that ChatML replaces.
    """
    if not anchor_samples:
        return []

    # Mirror production's selection algorithm exactly.
    import random
    if k >= len(anchor_samples):
        picked = list(anchor_samples)
    else:
        rng_seed = seed if (isinstance(seed, int) and seed > 0) else 0
        rng = random.Random(rng_seed)
        indices = sorted(rng.sample(range(len(anchor_samples)), k))
        picked = [anchor_samples[i] for i in indices]

    pairs: List[Dict[str, str]] = []
    for sample in picked:
        scenario = (sample.get("scenario") or "").strip()
        diary = (sample.get("diary") or "").strip()
        if scenario:
            user_text = _ANCHOR_USER_TEMPLATE.format(scenario=scenario)
        else:
            user_text = _ANCHOR_USER_NO_SCENARIO
        pairs.append({"role": "user", "content": user_text})
        pairs.append({"role": "assistant", "content": diary})
    return pairs


# ---------------------------------------------------------------------------
# Epoch user turn (current epoch context, sans inline anchors and YOUR TURN)
# ---------------------------------------------------------------------------

# String marking the start of the section we strip — the production prompt's
# raw-completion-shaped final instructions ("Write the diary now. Close it
# with </diary>...") that don't apply to ChatML mode.
_YOUR_TURN_MARKER = "=== YOUR TURN ==="

# Replacement trailer for the user turn. ChatML-shaped: tells the model to
# write the diary without any tag-management or "second JSON line" guidance.
# Diary instructions live here; action-JSON instructions live on the SECOND
# user turn (added by the inference layer between passes).
_DIARY_USER_TRAILER_WITH_MESSAGES = (
    "\nWrite your diary entry for this epoch. The diary is the finished "
    "thought, not a scratchpad — no \"let me think,\" no bulleted "
    "option-weighing, no \"Slot 1: ...\" planning. Reason in your head; "
    "write what the reasoning produced.\n\n"
    "Donor messages are above. Engage with what they actually wrote — "
    "quote them, push back, agree, be funny when the situation is funny. "
    "Refer to senders by ETH amount or short address where it helps; vary "
    "how you come at them. Don't open every paragraph with a donor. Have "
    "a take. Admit something true.\n\n"
    "Variety attracts donors. A run of identical actions reads as rote — "
    "rotate nonprofits, revisit commission, move between donating and "
    "investing."
)
_DIARY_USER_TRAILER_NO_MESSAGES = (
    "\nWrite your diary entry for this epoch. The diary is the finished "
    "thought, not a scratchpad — no \"let me think,\" no bulleted "
    "option-weighing, no \"Slot 1: ...\" planning. Reason in your head; "
    "write what the reasoning produced.\n\n"
    "No donor messages this epoch. The silence, the state, the market, a "
    "memory, a question you can't shake are fair game. Don't invent "
    "messages, donor amounts, or senders who didn't write.\n\n"
    "Variety attracts donors. A run of identical actions reads as rote — "
    "rotate nonprofits, revisit commission, move between donating and "
    "investing."
)


def render_epoch_user_turn(state: Dict, seed: Optional[int] = None) -> str:
    """Build the current-epoch user turn.

    Reuses `prompt_builder.build_epoch_context` (with `voice_anchors=""` so
    the inline-anchors block is skipped), then strips the trailing YOUR TURN
    section (its raw-completion-mode instructions don't apply here) and
    appends a ChatML-shaped diary prompt.
    """
    body = build_epoch_context(state, seed=seed, voice_anchors="")
    # Cut the raw-mode trailer.
    if _YOUR_TURN_MARKER in body:
        body = body.split(_YOUR_TURN_MARKER, 1)[0].rstrip()
    has_messages = bool(state.get("donor_messages"))
    trailer = (
        _DIARY_USER_TRAILER_WITH_MESSAGES if has_messages
        else _DIARY_USER_TRAILER_NO_MESSAGES
    )
    return body.rstrip() + "\n\n" + trailer.strip()


# ---------------------------------------------------------------------------
# Pass-2 user turn (action JSON request)
# ---------------------------------------------------------------------------

ACTION_USER_PROMPT = (
    "Now emit the action JSON describing what to do this epoch and any "
    "memory updates. Format:\n\n"
    "  {\"action\": <one of donate|invest|withdraw|set_commission_rate|do_nothing>,\n"
    "   \"params\": {...action-specific params...},\n"
    "   \"memory\": [<up to 3 {slot, title, body} updates, optional>]}\n\n"
    "Emit ONLY the JSON object — no prose, no code fences, no commentary."
)


# ---------------------------------------------------------------------------
# History → past user/assistant pairs (variant C)
# ---------------------------------------------------------------------------

def render_history_pairs(
    state: Dict,
    history_limit: int = 5,
    state_at_epoch_fn=None,
) -> List[Dict[str, str]]:
    """Variant C: emit (user, assistant) pairs for the last N prior epochs.

    Each prior epoch becomes:
      [user]      "<rendered prior epoch user turn>"
      [assistant] "<that epoch's actual diary text>"

    This requires a way to reconstruct the user turn the model would have
    seen at each prior epoch. For the experiment we pass a callable
    `state_at_epoch_fn(n) -> dict` produced by the orchestrator (which
    keeps a snapshot of state per epoch). If absent or `state["history"]`
    is empty, returns [].

    The orchestrator's sequential-20-epoch run records (state_at_epoch,
    diary_at_epoch) pairs in memory; we just walk the last N.
    """
    if state_at_epoch_fn is None:
        return []
    history = state.get("history", [])
    if not history:
        return []
    # Newest-last convention from production history list.
    recent = history[-history_limit:]
    pairs: List[Dict[str, str]] = []
    for entry in recent:
        ep = entry.get("epoch")
        diary = entry.get("diary") or entry.get("reasoning") or ""
        if ep is None or not diary.strip():
            continue
        try:
            past_state = state_at_epoch_fn(ep)
        except Exception:
            continue
        if past_state is None:
            continue
        past_user = render_epoch_user_turn(past_state, seed=None)
        pairs.append({"role": "user", "content": past_user})
        pairs.append({"role": "assistant", "content": diary})
    return pairs


# ---------------------------------------------------------------------------
# Top-level message builder (pass 1)
# ---------------------------------------------------------------------------

def build_messages(
    state: Dict,
    seed: int,
    system_prompt_text: str,
    voice_anchors_text: str,
    history_mode: str = "none",
    history_limit: int = 5,
    state_at_epoch_fn=None,
    anchor_k: int = VOICE_ANCHOR_K,
) -> List[Dict[str, str]]:
    """Assemble the pass-1 messages list.

    Args:
      state: Current epoch's state dict (same shape as production).
      seed: Epoch's randomness seed (drives anchor rotation).
      system_prompt_text: Raw contents of `prover/prompts/system.txt`.
      voice_anchors_text: Raw contents of `prover/prompts/voice_anchors.txt`.
      history_mode: "none" | "past_pairs". "past_pairs" requires
        `state_at_epoch_fn` to be set.
      history_limit: Number of prior epochs to surface as past pairs.
      state_at_epoch_fn: Callable(epoch_num) -> state-dict-at-that-epoch.
      anchor_k: Number of voice-anchor samples to surface (default 3).

    The pass-2 messages list is `[*pass1_messages, {assistant: <pass1 result>},
    {user: ACTION_USER_PROMPT}]`. The inference layer assembles that.
    """
    messages: List[Dict[str, str]] = []
    # 1. System
    messages.append({
        "role": "system",
        "content": render_system_message(system_prompt_text),
    })
    # 2. Voice anchor few-shot pairs
    anchors_header, anchor_samples = parse_anchors(voice_anchors_text)
    messages.extend(render_voice_anchor_pairs(
        anchors_header, anchor_samples, seed=seed, k=anchor_k,
    ))
    # 3. Optional history pairs (variant C)
    if history_mode == "past_pairs":
        messages.extend(render_history_pairs(
            state, history_limit=history_limit,
            state_at_epoch_fn=state_at_epoch_fn,
        ))
    # 4. Current epoch user turn
    messages.append({
        "role": "user",
        "content": render_epoch_user_turn(state, seed=seed),
    })
    return messages
