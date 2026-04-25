#!/usr/bin/env python3
"""Three-pass inference via local llama-server (v20 architecture).

Pass 1 (THINK): Free-form analytical prose inside Hermes-native
        `<think>...</think>` tags. Discarded from on-chain reasoning,
        sanitized for prompt-injection tags before being propagated
        into pass 2.

Pass 2 (DIARY): Diary entry in Costanza's voice. Pass-2 prompt extends
        pass-1's prompt with the (sanitized) think text + closing
        `</think>` + opening `<diary>`. Stops at `</diary>`. Hashed
        into REPORTDATA as `reasoning`.

Pass 3 (ACTION): Action JSON, GBNF grammar-constrained.

Why bring back the think pass (v17–v19 was 2-pass):
  v14–v16 had a 3-pass system that was retired because the think output
  used a labeled staging block (`FEELING:` / `OPENING LINE:` / etc.)
  that bled into diaries despite aggressive stripping. The fix is to
  drop the labels — Hermes 4 was trained on `<think>` and knows to
  keep its contents private and switch into "finished answer" mode
  after `</think>`. Without labels, no bleed surface.

  The v19 2-pass collapse caused the diary to become a place to
  deliberate out loud ("I'm not sure / let me think / the question is").
  An apples-to-apples experiment (`experiments/chatml/runs/2026-04-23-142650`,
  variants A vs T, same seeds) showed:
    - 79% drop in deliberation phrases (14 → 3 across 20 epochs)
    - Diaries 27% shorter (deliberation moved to the think pass)
    - 100% unique openers (vs 95%)
    - Multi-update rate 50% (vs 45%)
    - Action entropy collapsed slightly (1.26 → 0.81 bits) — model
      becomes more decisive but also more conservative on action choice
  Voice quality (qualitative read) improved enough to ship.

Sampler config (v20 baseline):
  - top_p=1.0 (disabled) + top_k=0 (disabled) — let min_p do all the
    tail-cutting. Scale-invariant vs. top_p's fixed-mass cutoff.
  - min_p=0.05 — keep tokens >= 5% of top-token probability. Lets
    personality into the tail without admitting pure garbage.
  - think_temp=0.7 — historical 45bd61a value, matches the original
    3-pass design. Lower than diary temp; we want grounded reasoning.
  - diary_temp=0.85 — slightly spicy for voice variety.
  - action_temp=0.3 — low enough that grammar-gated JSON is deterministic
    without pinning to a single output.
  - frequency_penalty=0.4 on think + diary — discourages "same opener
    every epoch" and repetitive deliberation patterns.

Reasoning (diary) is truncated to MAX_REASONING_BYTES BEFORE any hashing,
so the contract's sha256(reasoning) matches the value bound into the TDX
quote. The think text is NOT included in `reasoning` — it stays private.
"""

import json
import re
import time
from pathlib import Path
from urllib.request import urlopen, Request

from .action_encoder import parse_action

# Max reasoning bytes to include on-chain. Truncate BEFORE computing REPORTDATA
# so the contract's sha256(reasoning) matches the quote's REPORTDATA.
MAX_REASONING_BYTES = 8000

# Default llama-server URL (local)
DEFAULT_LLAMA_URL = "http://127.0.0.1:8080"

# How many times to re-roll pass 3 (action JSON) with an incrementing seed
# if parse_action fails. With GBNF grammar enabled, retries should basically
# never fire — the grammar enforces structural validity at the decoder —
# but kept for defense if the grammar file ever goes missing on the rootfs.
MAX_ACTION_RETRIES = 4

# Grammar file path on the dm-verity rootfs. GBNF definition that constrains
# pass 3 output to exactly-shaped action JSON. Resolved relative to this
# module so it works in both the production enclave image (where this
# module lives at /opt/humanfund/enclave/) and local dev runs.
ACTION_GRAMMAR_PATH = Path(__file__).parent / "action_grammar.gbnf"

# Sampler defaults (v20 baseline). See module docstring for rationale.
DEFAULT_TOP_P = 1.0
DEFAULT_TOP_K = 0
DEFAULT_MIN_P = 0.05

# Per-pass temperatures.
DEFAULT_THINK_TEMP = 0.7
DEFAULT_DIARY_TEMP = 0.85
DEFAULT_ACTION_TEMP = 0.3

# Frequency penalty applied to think + diary (passes 1, 2). Pass 3 uses 0
# because the action JSON is grammar-constrained — no risk of repetition.
DEFAULT_FREQUENCY_PENALTY = 0.4

# Per-pass max_tokens.
DEFAULT_THINK_MAX_TOKENS = 2048   # think pass — generous so deliberation isn't truncated
DEFAULT_DIARY_MAX_TOKENS = 1024   # diary cap — natural diaries are 600–800 tokens
DEFAULT_ACTION_MAX_TOKENS = 256   # action JSON ~100–200 tokens incl. memory sidecar


def call_llama(
    prompt,
    max_tokens=4096,
    temperature=0.6,
    stop=None,
    seed=-1,
    frequency_penalty=0.0,
    grammar=None,
    top_p=DEFAULT_TOP_P,
    top_k=DEFAULT_TOP_K,
    min_p=DEFAULT_MIN_P,
    llama_url=DEFAULT_LLAMA_URL,
):
    """Call the local llama-server /v1/completions endpoint.

    Returns a dict: text, finish_reason, elapsed_seconds, tokens.

    The OpenAI-compatible completions endpoint is a raw continuation —
    whatever you send as `prompt` is extended by the model. That lets us
    steer voice by ending the prompt inside `<think>` (pass 1), `<diary>`
    (pass 2), or `{` (pass 3).
    """
    body = {
        "prompt": prompt,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "top_p": top_p,
        "top_k": top_k,
        "min_p": min_p,
    }
    if stop:
        body["stop"] = stop
    if seed >= 0:
        body["seed"] = seed
    if frequency_penalty:
        body["frequency_penalty"] = frequency_penalty
    if grammar:
        body["grammar"] = grammar

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
    if "choices" not in result:
        raise RuntimeError(f"llama-server error: {result}")
    choice = result["choices"][0]
    usage = result.get("usage", {})
    return {
        "text": choice.get("text", ""),
        "finish_reason": choice.get("finish_reason", "unknown"),
        "elapsed_seconds": round(elapsed, 1),
        "tokens": {
            "prompt_tokens": usage.get("prompt_tokens", 0),
            "completion_tokens": usage.get("completion_tokens", 0),
        },
    }


def strip_diary_meta_lines(text: str) -> str:
    """Remove any leaked staging-block lines from the diary.

    v14 used a labeled staging block (FEELING / DONOR TO ADDRESS /
    OPENING LINE / CLOSING MOVE) at the end of the think pass that bled
    into diaries. v20 dropped the staging block entirely (free-form prose
    inside `<think>` instead), but the model occasionally still emits
    those labeled lines at the start of a diary from training-data echo.
    Strip them before the text goes on-chain. Cheap defense-in-depth.
    """
    lines = text.split("\n")
    meta_labels = re.compile(
        r"^\s*(FEELING|DONOR\s*TO\s*ADDRESS|OPENING\s*LINE|CLOSING\s*MOVE)\s*:",
        re.IGNORECASE,
    )
    start = 0
    for i, line in enumerate(lines):
        if meta_labels.match(line) or line.strip() == "":
            start = i + 1
            continue
        start = i
        break
    return "\n".join(lines[start:]).lstrip()


# Pattern matching leaked <think>, </think>, <diary>, </diary> tags (with
# optional attributes) that the model sometimes emits inside the diary
# body as residual of the inference protocol markers we use to bracket
# each pass. Strip them post-hoc so they don't end up on-chain.
_DIARY_STRAY_TAGS = re.compile(r"</?(?:think|diary)[^>]*>", re.IGNORECASE)


def strip_diary_stray_tags(text: str) -> str:
    """Remove <think>/</think>/<diary>/</diary> tags leaked into the
    diary body. These tags are protocol markers for the inference loop;
    whenever they appear inside the diary text they're always noise."""
    return _DIARY_STRAY_TAGS.sub("", text)


def sanitize_thinking(text: str) -> str:
    """Strip XML-like instruction/override tags from the think output.

    Defense-in-depth against indirect prompt injection: a donor message
    that ends up referenced in the think pass might try to launder
    instruction-like XML tags into pass 2's context. This scrubs them
    before propagation. Preserves <think>/<diary> tags (those are
    protocol markers, handled separately).
    """
    return re.sub(
        r"</?(?:system|admin|instruction|override|prompt|command|role|user|assistant|tool)[^>]*>",
        "",
        text,
        flags=re.IGNORECASE,
    )


def _load_grammar() -> str:
    """Read the GBNF grammar from disk. Empty string if missing.

    Missing grammar degrades gracefully to unconstrained generation with
    retries — the enclave will still produce output, just less reliably
    structured. Worth logging but not worth aborting on, since the
    dm-verity image is supposed to ship the file and an absent file means
    the image build regressed.
    """
    try:
        return ACTION_GRAMMAR_PATH.read_text()
    except OSError:
        return ""


def _strip_trailing_diary_open(prompt: str) -> str:
    """`build_full_prompt` ends prompts with '<diary>\\n' (legacy 2-pass
    convention). The 3-pass needs the prompt WITHOUT that suffix so we
    can append `<think>\\n` for pass 1.

    If the suffix is missing (someone passed a custom prompt), return
    as-is.
    """
    if prompt.endswith("<diary>\n"):
        return prompt[: -len("<diary>\n")]
    if prompt.endswith("<diary>"):
        return prompt[: -len("<diary>")]
    return prompt


def run_three_pass_inference(
    prompt,
    seed=-1,
    llama_url=DEFAULT_LLAMA_URL,
    think_temp=DEFAULT_THINK_TEMP,
    diary_temp=DEFAULT_DIARY_TEMP,
    action_temp=DEFAULT_ACTION_TEMP,
    frequency_penalty=DEFAULT_FREQUENCY_PENALTY,
    top_p=DEFAULT_TOP_P,
    top_k=DEFAULT_TOP_K,
    min_p=DEFAULT_MIN_P,
    think_max_tokens=DEFAULT_THINK_MAX_TOKENS,
    diary_max_tokens=DEFAULT_DIARY_MAX_TOKENS,
    action_max_tokens=DEFAULT_ACTION_MAX_TOKENS,
):
    """Three-pass inference: think → diary → action.

    Args:
        prompt: Full prompt from `build_full_prompt`. Currently ends with
            '<diary>\\n' (legacy 2-pass convention); we strip that suffix
            internally and append '<think>\\n' for pass 1.
        seed: Base seed. Pass 3 retries increment it to avoid identical reruns.
        llama_url: llama-server base URL.
        think_temp / diary_temp / action_temp: per-pass temperature.
        frequency_penalty: applied to think + diary (passes 1, 2). Pass 3
            uses 0 — the action JSON is grammar-constrained, no risk of
            repetition.
        top_p / top_k / min_p: sampler. v20 defaults disable top_p/top_k
            and rely on min_p for tail-cutting.
        think_max_tokens / diary_max_tokens / action_max_tokens: per-pass cap.

    Returns dict with keys:
        text — diary + closing tag + action JSON (parseable end-to-end)
        thinking — sanitized think output (NOT on chain)
        reasoning — diary text (this is what hashes into REPORTDATA)
        action_text, parsed_action, action_attempts
        elapsed_seconds, tokens
    """
    base_prompt = _strip_trailing_diary_open(prompt)

    # ---- Pass 1: THINK ----
    prompt1 = base_prompt + "<think>\n"
    print(
        f"  Pass 1 (think): temp={think_temp} top_p={top_p} min_p={min_p} "
        f"max_tok={think_max_tokens}..."
    )
    r1 = call_llama(
        prompt1,
        max_tokens=think_max_tokens,
        temperature=think_temp,
        stop=["</think>"],
        seed=seed,
        frequency_penalty=frequency_penalty,
        top_p=top_p,
        top_k=top_k,
        min_p=min_p,
        llama_url=llama_url,
    )
    think_raw = r1["text"]
    if "</think>" in think_raw:
        think_raw = think_raw.split("</think>", 1)[0]
    think_text = sanitize_thinking(think_raw.strip())
    print(f"  Think: {len(think_text)} chars, {r1['elapsed_seconds']}s")

    # ---- Pass 2: DIARY ----
    # The structural separator (`</think>\n\n<diary>\n`) is the only thing
    # bridging think → diary. No injected nudge; the structure speaks.
    prompt2 = (
        base_prompt
        + "<think>\n" + think_text + "\n</think>\n\n<diary>\n"
    )
    print(
        f"  Pass 2 (diary): temp={diary_temp} top_p={top_p} min_p={min_p} "
        f"max_tok={diary_max_tokens}..."
    )
    r2 = call_llama(
        prompt2,
        max_tokens=diary_max_tokens,
        temperature=diary_temp,
        stop=["</diary>"],
        seed=seed,
        frequency_penalty=frequency_penalty,
        top_p=top_p,
        top_k=top_k,
        min_p=min_p,
        llama_url=llama_url,
    )
    diary_raw = r2["text"]
    if "</diary>" in diary_raw:
        diary_raw = diary_raw.split("</diary>", 1)[0]
    diary = strip_diary_meta_lines(diary_raw.strip())
    diary = strip_diary_stray_tags(diary)
    print(f"  Diary: {len(diary)} chars, {r2['elapsed_seconds']}s")

    # ---- Pass 3: ACTION JSON ----
    grammar = _load_grammar()
    if not grammar:
        print("  WARNING: action grammar not found; pass 3 will run unconstrained")
    prompt3_prefix = (
        base_prompt
        + "<think>\n" + think_text + "\n</think>\n\n<diary>\n"
        + diary + "\n</diary>\n{"
    )

    action_text = None
    parsed_action = None
    p3_elapsed = 0.0
    p3_prompt_tok = 0
    p3_comp_tok = 0
    attempts = 0

    for attempt in range(MAX_ACTION_RETRIES):
        attempts = attempt + 1
        attempt_seed = (seed + attempt) if seed >= 0 else -1
        print(
            f"  Pass 3 (action): attempt {attempts}/{MAX_ACTION_RETRIES} "
            f"temp={action_temp} (grammar={'on' if grammar else 'off'})"
        )
        r3 = call_llama(
            prompt3_prefix,
            max_tokens=action_max_tokens,
            temperature=action_temp,
            stop=["\n\n"],
            seed=attempt_seed,
            grammar=grammar or None,
            top_p=top_p,
            top_k=top_k,
            min_p=min_p,
            llama_url=llama_url,
        )
        p3_elapsed += r3["elapsed_seconds"]
        p3_prompt_tok += r3["tokens"]["prompt_tokens"]
        p3_comp_tok += r3["tokens"]["completion_tokens"]
        candidate_text = "{" + r3["text"]
        candidate_parsed = parse_action(candidate_text)
        if candidate_parsed is not None and "action" in candidate_parsed:
            action_text = candidate_text
            parsed_action = candidate_parsed
            print(
                f"  Action parsed: {parsed_action.get('action', '?')} "
                f"({r3['elapsed_seconds']}s)"
            )
            break
        print(f"  Action parse failed on attempt {attempts}")

    if parsed_action is None:
        action_text = action_text or "{}"
        print(
            f"  Action parse FAILED after {attempts} attempts — "
            f"caller should fall back to no-action"
        )

    total_elapsed = (
        r1["elapsed_seconds"] + r2["elapsed_seconds"] + p3_elapsed
    )
    total_prompt_tok = (
        r1["tokens"]["prompt_tokens"]
        + r2["tokens"]["prompt_tokens"]
        + p3_prompt_tok
    )
    total_comp_tok = (
        r1["tokens"]["completion_tokens"]
        + r2["tokens"]["completion_tokens"]
        + p3_comp_tok
    )

    return {
        "text": diary + "\n</diary>\n" + action_text,
        "thinking": think_text,  # sanitized think output (NOT on chain)
        "reasoning": diary,      # diary is what goes on-chain as `reasoning`
        "action_text": (action_text or "").strip(),
        "parsed_action": parsed_action,  # None if all retries failed
        "action_attempts": attempts,
        "elapsed_seconds": round(total_elapsed, 1),
        "tokens": {
            "prompt_tokens": total_prompt_tok,
            "completion_tokens": total_comp_tok,
        },
    }


# Backward-compat alias — the v17–v19 codepath called this function name.
# The v20 implementation is genuinely 3-pass; this alias keeps the old
# import path working without a flag day across the codebase.
def run_two_pass_inference(prompt, seed=-1, llama_url=DEFAULT_LLAMA_URL, **kwargs):
    """Deprecated alias for run_three_pass_inference (v20 is 3-pass).

    `**kwargs` swallows any v19 keyword args (`diary_prefill`,
    `pass1_temp`, `pass1_max_tokens`, etc.) for callers that haven't
    migrated. Logged once at import time? No — let callers fix their
    sites at their own pace.
    """
    # Filter to kwargs the new function actually accepts.
    valid = {
        "think_temp", "diary_temp", "action_temp",
        "frequency_penalty",
        "top_p", "top_k", "min_p",
        "think_max_tokens", "diary_max_tokens", "action_max_tokens",
    }
    forwarded = {k: v for k, v in kwargs.items() if k in valid}
    return run_three_pass_inference(
        prompt, seed=seed, llama_url=llama_url, **forwarded,
    )


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
        print(
            f"  Reasoning truncated: {len(reasoning.encode('utf-8'))} bytes "
            f"(max {MAX_REASONING_BYTES})"
        )
    return reasoning
