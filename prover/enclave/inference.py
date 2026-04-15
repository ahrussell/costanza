#!/usr/bin/env python3
"""Three-pass inference via local llama-server.

Pass 1: Analytical reasoning (stop at </think>, temperature 0.7)
Pass 2: Diary entry in Costanza's voice (stop at </diary>, temperature 0.8)
Pass 3: JSON action (temperature 0.3, seeded for determinism)

The diary entry is what gets published on-chain as "reasoning". The think
block is private analytical work — discarded after use.

Between Pass 1 and Pass 2, a terse voice reminder (DIARY_NUDGE) is injected
immediately before the <diary> opening tag. That token position is where
Pass 2 generation begins, so it has outsized influence on the diary voice —
more than anything in the system prompt thousands of tokens upstream.

Reasoning (diary) is truncated to MAX_REASONING_BYTES BEFORE any hashing, so
the contract's sha256(reasoning) matches the value bound into the TDX quote.
"""

import json
import re
import time
from urllib.request import urlopen, Request

from .action_encoder import parse_action

# Max reasoning bytes to include on-chain. Truncate BEFORE computing REPORTDATA
# so the contract's sha256(reasoning) matches the quote's REPORTDATA.
MAX_REASONING_BYTES = 8000

# Default llama-server URL (local)
DEFAULT_LLAMA_URL = "http://127.0.0.1:8080"

# How many times to re-roll Pass 3 (action JSON) with an incrementing seed
# if parse_action fails. The expensive work (Pass 1 thinking + Pass 2 diary)
# is already done at this point, so each retry is cheap (~1-3s). If all
# retries fail, the caller (enclave_runner) falls back to a no-action
# (contract noop) result with a system note appended to the diary.
MAX_ACTION_RETRIES = 4


# Voice nudge injected immediately before <diary> in Pass 2. This lands at the
# exact token position where diary generation begins — the highest-leverage
# position in the whole pipeline for steering the diary voice specifically.
# Keep it terse: concrete rules only, no ceremony.
DIARY_NUDGE = (
    "(Costanza: this is the diary, not the think block. Do not write "
    "FEELING: or OPENING LINE: or any labeled lines — just write. Write "
    "like the VOICE ANCHORS above: specific, reactive, honest, funny when "
    "you can swing it and serious when you can't. If donors wrote this "
    "epoch, name one by ETH amount and quote at least four consecutive "
    "words of theirs. Have a take. Admit one true thing. No 'As the "
    "autonomous steward' — you are not giving a press conference. No "
    "'Therefore I will' — the action JSON speaks for itself. 250-400 words.)"
)


def call_llama(prompt, max_tokens=4096, temperature=0.6, stop=None, seed=-1,
               llama_url=DEFAULT_LLAMA_URL):
    """Call the local llama-server."""
    body = {
        "prompt": prompt,
        "max_tokens": max_tokens,
        "temperature": temperature,
    }
    if stop:
        body["stop"] = stop
    if seed >= 0:
        body["seed"] = seed

    payload = json.dumps(body).encode()
    req = Request(
        f"{llama_url}/v1/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
    )

    start = time.time()
    resp = urlopen(req, timeout=1800)  # CPU inference can take 20+ min per pass
    elapsed = time.time() - start

    result = json.loads(resp.read())
    choice = result["choices"][0]

    return {
        "text": choice["text"],
        "finish_reason": choice.get("finish_reason", "unknown"),
        "elapsed_seconds": round(elapsed, 1),
        "tokens": result["usage"],
    }


def strip_diary_meta_lines(text: str) -> str:
    """Remove any leaked staging-block lines from the diary.

    Early prompt iterations asked the model to commit to FEELING / DONOR TO
    ADDRESS / OPENING LINE / CLOSING MOVE at the end of the think block. The
    staging block is gone from the prompt, but R1-Distill occasionally still
    emits those labeled lines at the start of the diary (memory from training
    on similar patterns, or residual instruction-following). Strip any such
    lines from the leading whitespace of the diary before it goes on-chain.
    """
    lines = text.split("\n")
    # Labels to strip if they appear as leading "LABEL: ..." lines
    meta_labels = re.compile(
        r"^\s*(FEELING|DONOR\s*TO\s*ADDRESS|OPENING\s*LINE|CLOSING\s*MOVE)\s*:",
        re.IGNORECASE,
    )
    # Find the first line that is NOT a meta label and NOT blank
    start = 0
    for i, line in enumerate(lines):
        if meta_labels.match(line) or line.strip() == "":
            start = i + 1
            continue
        start = i
        break
    return "\n".join(lines[start:]).lstrip()


def sanitize_thinking(text):
    """Strip XML-like instruction/override tags from thinking output.

    Defense-in-depth against reasoning propagation: if a donor message
    partially influences Pass 1 thinking, this prevents instruction-like
    XML tags from being laundered into Passes 2 and 3 as trusted context.
    Preserves <think> and <diary> tags used by the inference protocol.
    """
    # Strip tags that could be used for prompt injection laundering
    return re.sub(
        r'</?(?:system|admin|instruction|override|prompt|command|role|user|assistant|tool)[^>]*>',
        '',
        text,
        flags=re.IGNORECASE,
    )


def run_three_pass_inference(prompt, seed=-1, llama_url=DEFAULT_LLAMA_URL):
    """Three-pass inference: thinking, diary entry, then JSON action.

    Pass 1: Analytical reasoning in <think> tags — ends with the
            FEELING / DONOR TO ADDRESS / OPENING LINE / CLOSING MOVE
            staging block, which bridges into the diary.
    Pass 2: Diary entry in <diary> tags — DIARY_NUDGE is injected
            immediately before the opening tag to steer voice at the
            exact token position where generation begins.
    Pass 3: JSON action output.

    Returns dict with keys: text, thinking, reasoning (=diary), action_text, elapsed_seconds, tokens
    """
    # Pass 1: Analytical thinking
    print("  Pass 1: generating analytical reasoning...")
    result1 = call_llama(
        prompt, max_tokens=2048, temperature=0.7,
        stop=["</think>"], seed=seed, llama_url=llama_url
    )
    thinking = result1["text"].strip()
    print(f"  Thinking: {len(thinking)} chars, {result1['elapsed_seconds']}s")

    # Sanitize thinking before propagating into Passes 2/3 (defense-in-depth
    # against reasoning laundering from donor message injection)
    thinking_clean = sanitize_thinking(thinking)

    # Pass 2: Diary entry. DIARY_NUDGE lands in the immediate pre-generation
    # attention window — the highest-leverage voice-steering position.
    print("  Pass 2: generating diary entry...")
    prompt2 = (
        prompt + thinking_clean
        + "\n</think>\n" + DIARY_NUDGE + "\n<diary>\n"
    )
    result2 = call_llama(
        prompt2, max_tokens=1024, temperature=0.8,
        stop=["</diary>"], seed=seed, llama_url=llama_url
    )
    diary_entry = result2["text"].strip()
    diary_entry = strip_diary_meta_lines(diary_entry)
    print(f"  Diary: {len(diary_entry)} chars, {result2['elapsed_seconds']}s")

    # Pass 3: JSON action. Retry up to MAX_ACTION_RETRIES times with an
    # incrementing seed if parse_action fails. The expensive work (thinking +
    # diary) is already done — we're only re-running the short final pass.
    prompt3_prefix = (
        prompt + thinking_clean
        + "\n</think>\n" + DIARY_NUDGE + "\n<diary>\n"
        + diary_entry + "\n</diary>\n{"
    )

    action_text = None
    parsed_action = None
    pass3_elapsed = 0.0
    pass3_prompt_tokens = 0
    pass3_completion_tokens = 0
    attempts_used = 0

    for attempt in range(MAX_ACTION_RETRIES):
        attempts_used = attempt + 1
        # Bump the seed each retry so we don't get the same malformed output
        attempt_seed = (seed + attempt) if seed >= 0 else -1
        print(f"  Pass 3: generating action JSON (attempt {attempts_used}/{MAX_ACTION_RETRIES}, seed={attempt_seed})...")
        result3 = call_llama(
            prompt3_prefix, max_tokens=256, temperature=0.3,
            stop=["\n\n"], seed=attempt_seed, llama_url=llama_url
        )
        pass3_elapsed += result3["elapsed_seconds"]
        pass3_prompt_tokens += result3["tokens"]["prompt_tokens"]
        pass3_completion_tokens += result3["tokens"]["completion_tokens"]

        candidate_text = "{" + result3["text"]
        candidate_parsed = parse_action(candidate_text)
        if candidate_parsed is not None and "action" in candidate_parsed:
            action_text = candidate_text
            parsed_action = candidate_parsed
            print(f"  Action parsed: {parsed_action.get('action', '?')} ({result3['elapsed_seconds']}s)")
            break
        print(f"  Action parse failed on attempt {attempts_used}")

    if parsed_action is None:
        action_text = action_text or "{}"
        print(f"  Action parse FAILED after {attempts_used} attempts — caller should fall back to no-action")

    total_elapsed = result1["elapsed_seconds"] + result2["elapsed_seconds"] + pass3_elapsed

    total_prompt_tokens = (result1["tokens"]["prompt_tokens"]
                           + result2["tokens"]["prompt_tokens"]
                           + pass3_prompt_tokens)
    total_completion_tokens = (result1["tokens"]["completion_tokens"]
                               + result2["tokens"]["completion_tokens"]
                               + pass3_completion_tokens)

    return {
        "text": diary_entry + "\n</diary>\n" + action_text,
        "thinking": thinking,
        "reasoning": diary_entry,  # diary entry is what goes on-chain as "reasoning"
        "action_text": action_text.strip(),
        "parsed_action": parsed_action,       # None if all retries failed
        "action_attempts": attempts_used,
        "elapsed_seconds": total_elapsed,
        "tokens": {
            "prompt_tokens": total_prompt_tokens,
            "completion_tokens": total_completion_tokens,
        },
    }


# Keep backward-compatible alias
def run_two_pass_inference(prompt, seed=-1, llama_url=DEFAULT_LLAMA_URL):
    """Backward-compatible alias — now runs three-pass inference."""
    return run_three_pass_inference(prompt, seed=seed, llama_url=llama_url)


def truncate_reasoning(reasoning: str) -> str:
    """Truncate reasoning to fit on-chain gas budget.

    CRITICAL: This must happen BEFORE computing REPORTDATA so the contract's
    sha256(reasoning) matches the value bound into the TDX quote.
    """
    reasoning_bytes = reasoning.encode("utf-8")
    if len(reasoning_bytes) > MAX_REASONING_BYTES:
        reasoning_bytes = reasoning_bytes[:MAX_REASONING_BYTES]
        # Don't break a multi-byte UTF-8 character
        reasoning = reasoning_bytes.decode("utf-8", errors="ignore")
        print(f"  Reasoning truncated: {len(reasoning.encode('utf-8'))} bytes (max {MAX_REASONING_BYTES})")
    return reasoning
