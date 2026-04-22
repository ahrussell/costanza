#!/usr/bin/env python3
"""Two-pass inference via local llama-server (v19 architecture).

Pass 1: Diary entry in Costanza's voice. Prompt ends with '<diary>\\n',
        model generates continuation, stops at '</diary>'. No think/
        scratchpad pass — the diary IS the reasoning, shaped by the
        system prompt and voice anchors.

Pass 2: Action JSON, grammar-constrained (GBNF). Takes the full prompt
        plus the completed diary plus '</diary>\\n{' and generates the
        rest of the JSON object. The grammar guarantees structurally
        valid output, so retries exist only as defense against the
        grammar file being missing or malformed.

Why 2-pass instead of 3-pass:
  - The v14-v16 <think> scratchpad bled into diaries as labeled lines
    ("FEELING:", "OPENING LINE:") despite aggressive stripping. v19
    removed the scratchpad entirely.
  - Implicit reasoning happens inside the diary pass — giving the model
    a separate think block just doubled generation time and generated
    scratchpad artifacts.
  - Two passes with GBNF on pass 2 gives us structurally-valid action
    JSON every time, so retries are rare and cheap when they do fire.

Sampler config (v19 baseline):
  - top_p=1.0 (disabled) + top_k=0 (disabled) — let min_p do all the
    tail-cutting. Scale-invariant vs. top_p's fixed-mass cutoff.
  - min_p=0.05 — keep tokens >= 5% of top-token probability. Lets
    personality into the tail without admitting pure garbage.
  - pass1_temp=0.85 — slightly spicy for voice variety.
  - pass2_temp=0.3 — low enough that grammar-gated JSON is deterministic
    without pinning to a single output.
  - frequency_penalty=0.4 on pass 1 — discourages the "same opener every
    epoch" failure mode we saw in v14-v16.

Reasoning (diary) is truncated to MAX_REASONING_BYTES BEFORE any hashing,
so the contract's sha256(reasoning) matches the value bound into the TDX
quote.
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

# How many times to re-roll pass 2 (action JSON) with an incrementing seed
# if parse_action fails. With GBNF grammar enabled, retries should basically
# never fire — the grammar enforces structural validity at the decoder —
# but kept for defense if the grammar file ever goes missing on the rootfs.
MAX_ACTION_RETRIES = 4

# Grammar file path on the dm-verity rootfs. GBNF definition that constrains
# pass 2 output to exactly-shaped action JSON. Resolved relative to this
# module so it works in both the production enclave image (where this
# module lives at /opt/humanfund/enclave/) and local dev runs.
ACTION_GRAMMAR_PATH = Path(__file__).parent / "action_grammar.gbnf"

# Sampler defaults (v19 baseline). See module docstring for rationale.
DEFAULT_TOP_P = 1.0
DEFAULT_TOP_K = 0
DEFAULT_MIN_P = 0.05
DEFAULT_PASS1_TEMP = 0.85
DEFAULT_PASS2_TEMP = 0.3
DEFAULT_PASS1_FREQUENCY_PENALTY = 0.4

# Pass 1 max_tokens. 1024 is comfortable headroom — diaries cap around
# 600-800 tokens naturally; 512 caused mid-sentence truncation in testing.
DEFAULT_PASS1_MAX_TOKENS = 1024

# Pass 2 max_tokens. Action JSON is ~100-200 tokens tops even with the
# worldview sidecar; 256 gives headroom for verbose worldview policy text.
DEFAULT_PASS2_MAX_TOKENS = 256

# Diary pre-fill. Without it, Hermes 4 70B emits `</diary>` as its first
# generation token roughly 80% of the time on the production prompt — even
# under greedy decoding. Probing with a 15-seed sweep + temp=0 confirms the
# model genuinely scores the empty-diary continuation highest; it's not a
# sampling artifact. Pre-filling pass 1 with a 3-character opener that the
# model can grammatically continue from drops the empty rate to 0% across
# the same sweep.
#
# The prefill is prepended back into the returned diary text so on-chain
# `reasoning` still reads as a complete diary entry. Hashing is unaffected:
# REPORTDATA = sha256(reasoning) sees the whole string including the prefix.
DEFAULT_DIARY_PREFILL = "It "


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
    steer voice by ending the prompt inside a <diary> block.
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

    v14 used a staging block (FEELING / DONOR TO ADDRESS / OPENING LINE /
    CLOSING MOVE) at the end of the think pass, bridging into the diary.
    v19 removed the staging block and the think pass entirely, but the
    model occasionally still emits those labeled lines at the start of
    a diary from training-data echo. Strip them before the text goes
    on-chain.
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


def sanitize_thinking(text):
    """Strip XML-like instruction/override tags from model output.

    Defense-in-depth against indirect prompt injection: if a donor message
    partially influenced generation, this prevents instruction-like XML
    tags from being laundered into subsequent passes (or on-chain) as
    trusted context. Preserves <think>/<diary> tags used by the inference
    protocol.

    Retained even though v19 dropped the think pass — the diary output
    may still contain donor-seeded text that we want to scrub of
    authority-simulating markup.
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


def run_two_pass_inference(
    prompt,
    seed=-1,
    llama_url=DEFAULT_LLAMA_URL,
    pass1_temp=DEFAULT_PASS1_TEMP,
    pass2_temp=DEFAULT_PASS2_TEMP,
    pass1_frequency_penalty=DEFAULT_PASS1_FREQUENCY_PENALTY,
    top_p=DEFAULT_TOP_P,
    top_k=DEFAULT_TOP_K,
    min_p=DEFAULT_MIN_P,
    pass1_max_tokens=DEFAULT_PASS1_MAX_TOKENS,
    pass2_max_tokens=DEFAULT_PASS2_MAX_TOKENS,
    diary_prefill=DEFAULT_DIARY_PREFILL,
):
    """Two-pass inference: diary, then grammar-constrained action JSON.

    Args:
        prompt: Full prompt ending with '<diary>\\n' (from build_full_prompt).
        seed: Base seed. Pass 2 retries increment it to avoid identical reruns.
        llama_url: llama-server base URL.
        pass1_temp / pass2_temp: per-pass temperature.
        pass1_frequency_penalty: pass 1 only. Discourages phrase repetition
            across the diary body (addresses "same opener every epoch" drift).
        top_p / top_k / min_p: sampler. v19 defaults disable top_p/top_k
            and rely on min_p for tail-cutting.
        pass1_max_tokens / pass2_max_tokens: per-pass generation cap.
        diary_prefill: short string appended to the pass-1 prompt and
            prepended back to the returned diary text. See
            DEFAULT_DIARY_PREFILL docstring above for rationale. Pass "" to
            disable (used in tests that need exact prompt/diary assertions).

    Returns dict with keys: text, thinking, reasoning (=diary), action_text,
    parsed_action, action_attempts, elapsed_seconds, tokens.

    `thinking` is always "" in v19 — retained in the return shape for
    backward compatibility with downstream consumers.
    """
    # Pass 1: Diary. Prompt ends with '<diary>\n'; we append diary_prefill
    # so the model continues from a non-empty string instead of jumping to
    # '</diary>'. The model continues, stops at '</diary>'.
    print(
        f"  Pass 1: diary temp={pass1_temp} fp={pass1_frequency_penalty} "
        f"top_p={top_p} min_p={min_p} max_tok={pass1_max_tokens} "
        f"prefill={diary_prefill!r}..."
    )
    pass1_prompt = prompt + diary_prefill
    r1 = call_llama(
        pass1_prompt,
        max_tokens=pass1_max_tokens,
        temperature=pass1_temp,
        stop=["</diary>"],
        seed=seed,
        frequency_penalty=pass1_frequency_penalty,
        top_p=top_p,
        top_k=top_k,
        min_p=min_p,
        llama_url=llama_url,
    )
    # Stitch the prefill back onto the model's continuation so the diary
    # text reads naturally on-chain. lstrip() avoids accidental double
    # spaces if the model started its continuation with whitespace.
    raw_diary = diary_prefill + r1["text"].lstrip() if diary_prefill else r1["text"]
    # Belt-and-suspenders: clip at </diary> in case the stop token was
    # missed (rare with llama-server's decoded-text stop matching, but
    # not impossible with unusual tokenizers).
    if "</diary>" in raw_diary:
        raw_diary = raw_diary.split("</diary>", 1)[0]
    diary = strip_diary_meta_lines(raw_diary.strip())
    diary = strip_diary_stray_tags(diary)
    print(f"  Diary: {len(diary)} chars, {r1['elapsed_seconds']}s")

    # Pass 2: Action JSON. Grammar-constrained output guaranteed valid.
    # Prompt extension: original prompt + diary + </diary>\n{ so the model
    # picks up generation of a JSON object continuing from the '{'. The
    # `diary` string already includes the prefill prefix, so the assembled
    # context exactly mirrors what pass 1 generated.
    grammar = _load_grammar()
    if not grammar:
        print("  WARNING: action grammar not found; pass 2 will run unconstrained")
    prompt2 = prompt + diary + "\n</diary>\n{"

    action_text = None
    parsed_action = None
    p2_elapsed = 0.0
    p2_prompt_tok = 0
    p2_comp_tok = 0
    attempts = 0

    for attempt in range(MAX_ACTION_RETRIES):
        attempts = attempt + 1
        attempt_seed = (seed + attempt) if seed >= 0 else -1
        print(
            f"  Pass 2: action JSON attempt {attempts}/{MAX_ACTION_RETRIES} "
            f"temp={pass2_temp} (grammar={'on' if grammar else 'off'})..."
        )
        r2 = call_llama(
            prompt2,
            max_tokens=pass2_max_tokens,
            temperature=pass2_temp,
            stop=["\n\n"],
            seed=attempt_seed,
            grammar=grammar or None,
            top_p=top_p,
            top_k=top_k,
            min_p=min_p,
            llama_url=llama_url,
        )
        p2_elapsed += r2["elapsed_seconds"]
        p2_prompt_tok += r2["tokens"]["prompt_tokens"]
        p2_comp_tok += r2["tokens"]["completion_tokens"]
        candidate_text = "{" + r2["text"]
        candidate_parsed = parse_action(candidate_text)
        if candidate_parsed is not None and "action" in candidate_parsed:
            action_text = candidate_text
            parsed_action = candidate_parsed
            print(
                f"  Action parsed: {parsed_action.get('action', '?')} "
                f"({r2['elapsed_seconds']}s)"
            )
            break
        print(f"  Action parse failed on attempt {attempts}")

    if parsed_action is None:
        action_text = action_text or "{}"
        print(
            f"  Action parse FAILED after {attempts} attempts — "
            f"caller should fall back to no-action"
        )

    total_elapsed = r1["elapsed_seconds"] + p2_elapsed
    total_prompt_tok = r1["tokens"]["prompt_tokens"] + p2_prompt_tok
    total_comp_tok = r1["tokens"]["completion_tokens"] + p2_comp_tok

    return {
        "text": diary + "\n</diary>\n" + action_text,
        "thinking": "",  # v19 has no think pass; kept for shape compatibility
        "reasoning": diary,  # diary is what goes on-chain as "reasoning"
        "action_text": action_text.strip(),
        "parsed_action": parsed_action,  # None if all retries failed
        "action_attempts": attempts,
        "elapsed_seconds": total_elapsed,
        "tokens": {
            "prompt_tokens": total_prompt_tok,
            "completion_tokens": total_comp_tok,
        },
    }


# Backward-compat alias — older callers may still import the three-pass name.
# The v19 implementation is purely two-pass; this alias keeps that import
# path working without a flag day.
def run_three_pass_inference(prompt, seed=-1, llama_url=DEFAULT_LLAMA_URL):
    """Deprecated alias for run_two_pass_inference (v19 is 2-pass)."""
    return run_two_pass_inference(prompt, seed=seed, llama_url=llama_url)


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
