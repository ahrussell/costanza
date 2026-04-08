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
    def run_epoch(self, epoch_state: dict, contract_state: dict,
                  system_prompt: str, seed: int) -> dict:
        """Run inference for one epoch inside a TEE.

        Args:
            epoch_state: Full flat epoch state (from read_contract_state).
                The TEE derives contract_state from this for hash verification,
                then feeds it to build_epoch_context() for prompt construction.
                All data shown to the model is transitively verified via inputHash.
            contract_state: Structured contract state for input hash verification.
                Kept for backward compatibility / debugging. The TEE prefers
                epoch_state when available.
            system_prompt: System prompt text (on dm-verity rootfs, verified via image key).
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
