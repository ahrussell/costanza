#!/usr/bin/env python3
"""Prompt builder — constructs the full epoch context from structured contract state.

This runs INSIDE the TEE, making the prompt construction part of the attested
computation. The system prompt is received as a verified input (its hash is
pinned on-chain via approvedPromptHash).

The epoch context includes:
- Vitals (treasury, commission, ETH/USD price, lifespan estimate)
- Action bounds (max donate, commission range, investment capacity)
- Nonprofit registry
- Investment portfolio
- Worldview (guiding policies)
- Donor messages (with datamarking spotlighting)
- Decision history
- Action distribution statistics
"""

import hashlib


def build_epoch_context(state: dict) -> str:
    """Build the epoch context string from structured contract state.

    This is a placeholder — the full implementation will be extracted from
    agent/runner.py's build_epoch_context() function. For now, if the runner
    provides a pre-built epoch_context string, we use that directly.

    Args:
        state: Structured contract state dict containing all epoch data.

    Returns:
        The epoch context string to append to the system prompt.
    """
    # TODO: Extract full prompt building logic from agent/runner.py
    # For now, the runner can provide a pre-built epoch_context
    if "epoch_context" in state:
        return state["epoch_context"]

    raise NotImplementedError(
        "Full prompt building inside TEE not yet implemented. "
        "Provide epoch_context in the request."
    )


def build_full_prompt(system_prompt: str, epoch_context: str) -> str:
    """Combine system prompt + epoch context into the full inference prompt."""
    return system_prompt + "\n\n" + epoch_context + "\n\n<think>\n"
