#!/usr/bin/env python3
"""Auction state machine — idempotent handlers for each auction phase.

Designed for cron: each function checks the current state before acting,
so calling the same function multiple times is safe.
"""

import os
import secrets

from .chain import ChainClient
from .state import load as load_state, save as save_state, clear as clear_state
from .bid_strategy import estimate_bid, clamp_bid


# Auction phases (matches contract enum)
IDLE = 0
COMMIT = 1
REVEAL = 2
EXECUTION = 3
SETTLED = 4

PHASE_NAMES = {IDLE: "IDLE", COMMIT: "COMMIT", REVEAL: "REVEAL",
               EXECUTION: "EXECUTION", SETTLED: "SETTLED"}


def start_epoch(chain: ChainClient, dry_run=False):
    """Start a new epoch. Idempotent — catches 'already started' revert."""
    try:
        if dry_run:
            print("  [DRY RUN] Would call startEpoch()")
            return True
        chain.send_tx(chain.contract.functions.startEpoch(), gas=500_000)
        print("  startEpoch() submitted")
        return True
    except Exception as e:
        if "WrongPhase" in str(e) or "already" in str(e).lower():
            print("  Epoch already started (OK)")
            return True
        raise


def commit_bid(chain: ChainClient, bid_wei: int, state_dir=None, dry_run=False):
    """Generate salt, compute commit hash, submit bid with bond.

    Returns the saved state dict.
    """
    salt = "0x" + secrets.token_hex(32)
    salt_bytes = bytes.fromhex(salt[2:])

    # Compute commit hash: keccak256(abi.encodePacked(bidAmount, salt))
    from web3 import Web3
    commit_hash = Web3.keccak(
        bid_wei.to_bytes(32, "big") + salt_bytes
    )

    bond = chain.get_current_bond()
    epoch = chain.contract.functions.currentEpoch().call()

    if dry_run:
        print(f"  [DRY RUN] Would commit: bid={bid_wei/1e18:.6f} ETH, bond={bond/1e18:.6f} ETH")
        return {"epoch": epoch, "commit_salt": salt, "bid_amount": bid_wei,
                "committed": True, "revealed": False}

    chain.send_tx(
        chain.contract.functions.commit(commit_hash),
        value=bond, gas=200_000,
    )

    state = {
        "epoch": epoch,
        "commit_salt": salt,
        "bid_amount": bid_wei,
        "committed": True,
        "revealed": False,
    }
    if state_dir:
        save_state(state, state_dir)
    print(f"  Bid committed: {bid_wei/1e18:.6f} ETH (bond={bond/1e18:.6f} ETH)")
    return state


def close_commit(chain: ChainClient, dry_run=False):
    """Close the commit phase. Idempotent."""
    try:
        if dry_run:
            print("  [DRY RUN] Would call closeCommit()")
            return True
        chain.send_tx(chain.contract.functions.closeCommit(), gas=300_000)
        print("  closeCommit() submitted")
        return True
    except Exception as e:
        if "WrongPhase" in str(e) or "TimingError" in str(e):
            print(f"  closeCommit() skipped: {e}")
            return False
        raise


def reveal_bid(chain: ChainClient, state: dict, dry_run=False):
    """Reveal a previously committed bid."""
    bid_amount = state["bid_amount"]
    salt = bytes.fromhex(state["commit_salt"][2:])

    if dry_run:
        print(f"  [DRY RUN] Would reveal: {bid_amount/1e18:.6f} ETH")
        return True

    chain.send_tx(
        chain.contract.functions.reveal(bid_amount, salt),
        gas=200_000,
    )
    print(f"  Bid revealed: {bid_amount/1e18:.6f} ETH")
    return True


def close_reveal(chain: ChainClient, dry_run=False):
    """Close the reveal phase. Idempotent."""
    try:
        if dry_run:
            print("  [DRY RUN] Would call closeReveal()")
            return True
        chain.send_tx(chain.contract.functions.closeReveal(), gas=500_000)
        print("  closeReveal() submitted")
        return True
    except Exception as e:
        if "WrongPhase" in str(e) or "TimingError" in str(e):
            print(f"  closeReveal() skipped: {e}")
            return False
        raise


def submit_result(chain: ChainClient, action_bytes: bytes, reasoning: bytes,
                  proof: bytes, verifier_id=1, policy_slot=-1, policy_text="",
                  dry_run=False):
    """Submit auction result with attestation proof."""
    if dry_run:
        print(f"  [DRY RUN] Would submit result: {len(action_bytes)} action bytes, "
              f"{len(reasoning)} reasoning bytes, {len(proof)} proof bytes")
        return None

    receipt = chain.send_tx(
        chain.contract.functions.submitAuctionResult(
            action_bytes, reasoning, proof, verifier_id, policy_slot, policy_text
        ),
        gas=15_000_000,  # DCAP verification is expensive
    )
    print(f"  Result submitted! Gas used: {receipt['gasUsed']}")
    return receipt
