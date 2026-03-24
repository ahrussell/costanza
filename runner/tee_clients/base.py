#!/usr/bin/env python3
"""Abstract base class for TEE clients.

TEE clients handle the lifecycle of a TDX Confidential VM:
create → boot → send epoch state → receive result → delete.

Third-party runners can implement their own TEE client by subclassing
TEEClient and overriding run_epoch().
"""

from abc import ABC, abstractmethod


class TEEClient(ABC):
    @abstractmethod
    def run_epoch(self, contract_state: dict, epoch_context: str,
                  system_prompt: str, seed: int) -> dict:
        """Run inference for one epoch inside a TEE.

        Args:
            contract_state: Structured contract state for input hash verification.
            epoch_context: Pre-built epoch context string.
            system_prompt: System prompt text (hash must match approvedPromptHash).
            seed: Randomness seed from block.prevrandao.

        Returns:
            Dict with keys:
                reasoning: str — truncated reasoning text
                action: dict — parsed action JSON
                action_bytes: str — "0x..." hex-encoded action bytes
                attestation_quote: str — "0x..." hex-encoded DCAP quote
                report_data: str — "0x..." hex-encoded report data
                input_hash: str — "0x..." hex-encoded input hash
        """
        ...
