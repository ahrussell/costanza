#!/usr/bin/env python3
"""ChatML two-pass inference via llama-server's /v1/chat/completions.

Two chat-completion calls in one logical conversation. Pass 1 generates
the diary; pass 2 appends pass-1's assistant response + a new user turn
asking for the action JSON, then samples with a GBNF grammar.

Mirrors the sampler config from `prover/enclave/inference.py` so the
ONLY axis that varies vs the production baseline is the endpoint
(`/v1/chat/completions` vs `/v1/completions`) and the prompt structure
(messages array vs concatenated text).

Retry-on-empty pass-1 mechanic is preserved: if the model returns an
empty assistant response (model emits `<|im_end|>` immediately),
re-roll with a PRNG-derived deterministic seed up to MAX_PASS1_RETRIES
times. We expect this to fire near-zero with ChatML (the whole point of
the experiment), but kept as defense.
"""

from __future__ import annotations

import json
import random
import time
from pathlib import Path
from typing import Any, Dict, List, Optional
from urllib.request import Request, urlopen

# Reuse production sampler defaults so only the endpoint differs.
import sys
_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_REPO_ROOT))
from prover.enclave.inference import (  # noqa: E402
    DEFAULT_LLAMA_URL,
    DEFAULT_PASS1_TEMP,
    DEFAULT_PASS2_TEMP,
    DEFAULT_PASS1_FREQUENCY_PENALTY,
    DEFAULT_TOP_P,
    DEFAULT_TOP_K,
    DEFAULT_MIN_P,
    DEFAULT_PASS1_MAX_TOKENS,
    DEFAULT_PASS2_MAX_TOKENS,
    MAX_PASS1_RETRIES,
)
from prover.enclave.action_encoder import parse_action  # noqa: E402

from experiments.chatml.chatml_prompt_builder import ACTION_USER_PROMPT


# ChatML grammar lives next to this module (constrains the FULL JSON object,
# unlike the production raw-mode grammar which assumes "{" priming).
ACTION_GRAMMAR_CHATML_PATH = (
    Path(__file__).resolve().parent / "action_grammar_chatml.gbnf"
)


def _load_grammar() -> str:
    try:
        return ACTION_GRAMMAR_CHATML_PATH.read_text()
    except OSError:
        return ""


def _pass1_retry_seeds(base_seed: int, n_attempts: int) -> List[int]:
    """Same PRNG seed schedule as production inference.py."""
    if base_seed < 0:
        return [-1] * n_attempts
    rng = random.Random(base_seed)
    return [base_seed] + [rng.randint(0, 2**31 - 1) for _ in range(n_attempts - 1)]


def call_chat(
    messages: List[Dict[str, str]],
    max_tokens: int,
    temperature: float,
    seed: int = -1,
    top_p: float = DEFAULT_TOP_P,
    top_k: int = DEFAULT_TOP_K,
    min_p: float = DEFAULT_MIN_P,
    frequency_penalty: float = 0.0,
    grammar: Optional[str] = None,
    stop: Optional[List[str]] = None,
    llama_url: str = DEFAULT_LLAMA_URL,
) -> Dict[str, Any]:
    """One POST to /v1/chat/completions. Returns dict with content + meta."""
    body: Dict[str, Any] = {
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "top_p": top_p,
        "top_k": top_k,
        "min_p": min_p,
    }
    if seed >= 0:
        body["seed"] = seed
    if frequency_penalty:
        body["frequency_penalty"] = frequency_penalty
    if grammar:
        body["grammar"] = grammar
    if stop:
        body["stop"] = stop

    payload = json.dumps(body).encode()
    req = Request(
        f"{llama_url}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    start = time.time()
    resp = urlopen(req, timeout=1800)
    elapsed = time.time() - start

    result = json.loads(resp.read())
    if "choices" not in result:
        raise RuntimeError(f"llama-server error: {result}")
    choice = result["choices"][0]
    msg = choice.get("message") or {}
    usage = result.get("usage") or {}
    return {
        "content": msg.get("content", ""),
        "finish_reason": choice.get("finish_reason", "unknown"),
        "elapsed_seconds": round(elapsed, 1),
        "tokens": {
            "prompt_tokens": usage.get("prompt_tokens", 0),
            "completion_tokens": usage.get("completion_tokens", 0),
        },
    }


def _word_5grams(text: str) -> set:
    """Word-level 5-grams (lowercased) from text."""
    words = text.lower().split()
    return set(tuple(words[i:i + 5]) for i in range(len(words) - 4))


def _check_voice_violations(
    diary: str,
    forbidden_phrases: Optional[List[str]] = None,
    forbidden_5grams: Optional[set] = None,
) -> Optional[str]:
    """Returns a string describing the violation if any, else None."""
    if not diary:
        return None
    if forbidden_phrases:
        for phrase in forbidden_phrases:
            if phrase in diary:
                return f"forbidden phrase: {phrase!r}"
    if forbidden_5grams:
        diary_grams = _word_5grams(diary)
        overlap = diary_grams & forbidden_5grams
        if overlap:
            sample = next(iter(overlap))
            return f"5-gram overlap with system prompt: {' '.join(sample)!r}"
    return None


def run_chat_two_pass(
    messages: List[Dict[str, str]],
    seed: int = -1,
    llama_url: str = DEFAULT_LLAMA_URL,
    pass1_temp: float = DEFAULT_PASS1_TEMP,
    pass2_temp: float = DEFAULT_PASS2_TEMP,
    pass1_frequency_penalty: float = DEFAULT_PASS1_FREQUENCY_PENALTY,
    top_p: float = DEFAULT_TOP_P,
    top_k: int = DEFAULT_TOP_K,
    min_p: float = DEFAULT_MIN_P,
    pass1_max_tokens: int = DEFAULT_PASS1_MAX_TOKENS,
    pass2_max_tokens: int = DEFAULT_PASS2_MAX_TOKENS,
    forbidden_phrases: Optional[List[str]] = None,
    forbidden_5grams: Optional[set] = None,
) -> Dict[str, Any]:
    """Two-pass ChatML inference.

    Pass 1: send `messages` (which ends with the diary user turn). Sample
    with diary config. Retry on:
      - Empty assistant response (<5 chars after stripping)
      - Any of `forbidden_phrases` appearing as a substring in the diary
        (e.g. ["Costanza"] to prevent third-person self-reference)
      - Any 5-gram overlap with `forbidden_5grams` (e.g. system-prompt
        5-grams to prevent verbatim system-prompt parroting)

    Pass 2: append the pass-1 assistant message + ACTION_USER_PROMPT,
    sample with action config + grammar.

    Returns: {
        diary, action_json, parsed_action,
        pass1_attempts, pass1_violations,  # list of per-attempt violation strings
        action_attempts,
        elapsed_seconds, tokens,
        pass1_messages, pass2_messages,
    }
    """
    # ---- Pass 1: diary ----
    p1_elapsed = 0.0
    p1_prompt_tok = 0
    p1_comp_tok = 0
    pass1_attempts = 0
    pass1_violations: List[str] = []
    diary = ""
    seeds = _pass1_retry_seeds(seed, MAX_PASS1_RETRIES)
    for attempt, attempt_seed in enumerate(seeds):
        pass1_attempts = attempt + 1
        print(
            f"  Pass 1: chat diary attempt {pass1_attempts}/{MAX_PASS1_RETRIES} "
            f"seed={attempt_seed} temp={pass1_temp} fp={pass1_frequency_penalty}"
        )
        r1 = call_chat(
            messages,
            max_tokens=pass1_max_tokens,
            temperature=pass1_temp,
            seed=attempt_seed,
            top_p=top_p,
            top_k=top_k,
            min_p=min_p,
            frequency_penalty=pass1_frequency_penalty,
            llama_url=llama_url,
        )
        p1_elapsed += r1["elapsed_seconds"]
        p1_prompt_tok += r1["tokens"]["prompt_tokens"]
        p1_comp_tok += r1["tokens"]["completion_tokens"]
        candidate = (r1["content"] or "").strip()
        # Strip stray <diary>/</diary> tags if the model echoed any from the
        # samples (defensive — should not happen since few-shot pairs strip
        # them, but just in case).
        candidate = candidate.replace("<diary>", "").replace("</diary>", "").strip()
        if len(candidate) < 5:
            pass1_violations.append("empty (<5 chars)")
            print(f"  Pass 1 attempt {pass1_attempts}: empty diary — re-rolling")
            continue
        # Voice-violation checks (forbidden phrases / 5-grams).
        violation = _check_voice_violations(
            candidate, forbidden_phrases, forbidden_5grams,
        )
        if violation:
            pass1_violations.append(violation)
            print(f"  Pass 1 attempt {pass1_attempts}: {violation} — re-rolling")
            continue
        # Accepted.
        diary = candidate
        print(
            f"  Diary: {len(diary)} chars, {r1['elapsed_seconds']}s "
            f"(attempt {pass1_attempts})"
        )
        break
    else:
        print(
            f"  Pass 1: ALL {MAX_PASS1_RETRIES} retries violated — proceeding "
            f"with last candidate (may be empty or violate)"
        )
        diary = candidate  # last candidate, even if it violates

    # ---- Pass 2: action JSON ----
    pass2_messages = list(messages) + [
        {"role": "assistant", "content": diary},
        {"role": "user", "content": ACTION_USER_PROMPT},
    ]
    grammar = _load_grammar()
    if not grammar:
        print(
            "  WARNING: ChatML action grammar not found at "
            f"{ACTION_GRAMMAR_CHATML_PATH}; pass 2 will be unconstrained"
        )

    MAX_ACTION_RETRIES = 4
    action_text = None
    parsed_action = None
    p2_elapsed = 0.0
    p2_prompt_tok = 0
    p2_comp_tok = 0
    action_attempts = 0
    for attempt in range(MAX_ACTION_RETRIES):
        action_attempts = attempt + 1
        attempt_seed = (seed + attempt) if seed >= 0 else -1
        print(
            f"  Pass 2: chat action JSON attempt {action_attempts}/"
            f"{MAX_ACTION_RETRIES} temp={pass2_temp} "
            f"(grammar={'on' if grammar else 'off'})"
        )
        r2 = call_chat(
            pass2_messages,
            max_tokens=pass2_max_tokens,
            temperature=pass2_temp,
            seed=attempt_seed,
            top_p=top_p,
            top_k=top_k,
            min_p=min_p,
            grammar=grammar or None,
            llama_url=llama_url,
        )
        p2_elapsed += r2["elapsed_seconds"]
        p2_prompt_tok += r2["tokens"]["prompt_tokens"]
        p2_comp_tok += r2["tokens"]["completion_tokens"]
        candidate_text = (r2["content"] or "").strip()
        candidate_parsed = parse_action(candidate_text)
        if candidate_parsed is not None and "action" in candidate_parsed:
            action_text = candidate_text
            parsed_action = candidate_parsed
            print(
                f"  Action parsed: {parsed_action.get('action', '?')} "
                f"({r2['elapsed_seconds']}s)"
            )
            break
        print(f"  Action parse failed on attempt {action_attempts}")

    if parsed_action is None:
        action_text = action_text or "{}"
        print(
            f"  Action parse FAILED after {action_attempts} attempts — "
            f"caller should fall back to no-action"
        )

    total_elapsed = p1_elapsed + p2_elapsed
    total_prompt_tok = p1_prompt_tok + p2_prompt_tok
    total_comp_tok = p1_comp_tok + p2_comp_tok

    return {
        "diary": diary,
        "action_text": (action_text or "").strip(),
        "parsed_action": parsed_action,
        "pass1_attempts": pass1_attempts,
        "pass1_violations": pass1_violations,
        "action_attempts": action_attempts,
        "elapsed_seconds": total_elapsed,
        "tokens": {
            "prompt_tokens": total_prompt_tok,
            "completion_tokens": total_comp_tok,
        },
        "pass1_messages": messages,
        "pass2_messages": pass2_messages,
    }
