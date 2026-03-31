#!/usr/bin/env python3
"""Three-pass inference via local llama-server.

Pass 1: Analytical reasoning (stop at </think>, temperature 0.7)
Pass 2: Literary diary entry (stop at </diary>, temperature 0.8)
Pass 3: JSON action (temperature 0.3, seeded for determinism)

The diary entry is what gets published on-chain as "reasoning".
The think block is private analytical work — discarded after use.

Reasoning (diary) is truncated to MAX_REASONING_BYTES BEFORE any hashing, so
the contract's sha256(reasoning) matches the value bound into the TDX quote.
"""

import json
import re
import time
from urllib.request import urlopen, Request

# Max reasoning bytes to include on-chain. Truncate BEFORE computing REPORTDATA
# so the contract's sha256(reasoning) matches the quote's REPORTDATA.
MAX_REASONING_BYTES = 8000

# Default llama-server URL (local)
DEFAULT_LLAMA_URL = "http://127.0.0.1:8080"


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

    Pass 1: Analytical reasoning in <think> tags (natural model voice)
    Pass 2: Creative diary entry in <diary> tags (literary style from worldview slot [0])
    Pass 3: JSON action output

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

    # Pass 2: Diary entry in literary style
    print("  Pass 2: generating diary entry...")
    prompt2 = prompt + thinking_clean + "\n</think>\n<diary>\n"
    result2 = call_llama(
        prompt2, max_tokens=1024, temperature=0.8,
        stop=["</diary>"], seed=seed, llama_url=llama_url
    )
    diary_entry = result2["text"].strip()
    print(f"  Diary: {len(diary_entry)} chars, {result2['elapsed_seconds']}s")

    # Pass 3: JSON action
    print("  Pass 3: generating action JSON...")
    prompt3 = prompt + thinking_clean + "\n</think>\n<diary>\n" + diary_entry + "\n</diary>\n{"
    result3 = call_llama(
        prompt3, max_tokens=256, temperature=0.3,
        stop=["\n\n"], seed=seed, llama_url=llama_url
    )
    print(f"  Action: {result3['elapsed_seconds']}s")

    action_text = "{" + result3["text"]
    total_elapsed = result1["elapsed_seconds"] + result2["elapsed_seconds"] + result3["elapsed_seconds"]

    total_prompt_tokens = (result1["tokens"]["prompt_tokens"]
                           + result2["tokens"]["prompt_tokens"]
                           + result3["tokens"]["prompt_tokens"])
    total_completion_tokens = (result1["tokens"]["completion_tokens"]
                               + result2["tokens"]["completion_tokens"]
                               + result3["tokens"]["completion_tokens"])

    return {
        "text": diary_entry + "\n</diary>\n" + action_text,
        "thinking": thinking,
        "reasoning": diary_entry,  # diary entry is what goes on-chain as "reasoning"
        "action_text": action_text.strip(),
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
