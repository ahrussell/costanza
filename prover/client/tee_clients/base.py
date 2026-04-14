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
    def run_epoch(self, epoch_state: dict, system_prompt: str, seed: int) -> dict:
        """Run inference for one epoch inside a TEE.

        Args:
            epoch_state: Flat epoch state (from read_contract_state +
                apply_snapshot_overrides). The enclave hashes this directly
                to produce the input hash; the contract verifies by hash
                equality against epochInputHashes[epoch]. No separate
                "contract_state" sidechannel — if the runner lies about any
                field, the hash won't match and submitAuctionResult reverts.
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
