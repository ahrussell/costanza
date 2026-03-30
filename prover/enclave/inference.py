#!/usr/bin/env python3
"""Two-pass inference via local llama-server.

Pass 1: Generate reasoning (stop at </think>, temperature 0.6)
Pass 2: Generate JSON action (temperature 0.3, seeded for determinism)

Reasoning is truncated to MAX_REASONING_BYTES BEFORE any hashing, so the
contract's sha256(reasoning) matches the value bound into the TDX quote.
"""

import json
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


def run_two_pass_inference(prompt, seed=-1, llama_url=DEFAULT_LLAMA_URL):
    """Two-pass inference: reasoning (stop at </think>), then JSON action.

    Returns dict with keys: text, reasoning, action_text, elapsed_seconds, tokens
    """
    # Pass 1: Generate reasoning
    result1 = call_llama(
        prompt, max_tokens=4096, temperature=0.6,
        stop=["</think>"], seed=seed, llama_url=llama_url
    )
    reasoning = result1["text"].strip()

    # Pass 2: Generate JSON action (same seed for determinism)
    prompt2 = prompt + reasoning + "\n</think>\n{"
    result2 = call_llama(
        prompt2, max_tokens=256, temperature=0.3,
        stop=["\n\n"], seed=seed, llama_url=llama_url
    )

    action_text = "{" + result2["text"]
    combined_text = reasoning + "\n</think>\n" + action_text
    return {
        "text": combined_text,
        "reasoning": reasoning,
        "action_text": action_text.strip(),
        "elapsed_seconds": result1["elapsed_seconds"] + result2["elapsed_seconds"],
        "tokens": {
            "prompt_tokens": result1["tokens"]["prompt_tokens"] + result2["tokens"]["prompt_tokens"],
            "completion_tokens": result1["tokens"]["completion_tokens"] + result2["tokens"]["completion_tokens"],
        },
    }


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
