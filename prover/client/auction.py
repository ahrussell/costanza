#!/usr/bin/env python3
"""Auction state machine — idempotent handlers for each auction phase.

Designed for cron: each function checks the current state before acting,
so calling the same function multiple times is safe.
"""

import logging
import secrets

from web3.exceptions import ContractLogicError, ContractCustomError

from .chain import ChainClient
from .state import load as load_state, save as save_state, clear as clear_state
from .bid_strategy import estimate_bid, clamp_bid

logger = logging.getLogger(__name__)

# Auction phases (matches contract enum)
IDLE = 0
COMMIT = 1
REVEAL = 2
EXECUTION = 3
SETTLED = 4

PHASE_NAMES = {IDLE: "IDLE", COMMIT: "COMMIT", REVEAL: "REVEAL",
               EXECUTION: "EXECUTION", SETTLED: "SETTLED"}

# Gas limits for auction transactions
GAS_START_EPOCH = 500_000
GAS_COMMIT = 200_000
GAS_CLOSE_COMMIT = 300_000
GAS_REVEAL = 200_000
GAS_CLOSE_REVEAL = 500_000
GAS_SUBMIT_RESULT = 15_000_000  # DCAP verification is expensive


def start_epoch(chain: ChainClient, dry_run=False):
    """Start a new epoch. Idempotent — catches 'already started' revert."""
    try:
        if dry_run:
            logger.info("[DRY RUN] Would call startEpoch()")
            return True
        chain.send_tx(chain.contract.functions.startEpoch(), gas=GAS_START_EPOCH)
        logger.info("startEpoch() submitted")
        return True
    except (ContractLogicError, ContractCustomError) as e:
        err = str(e)
        if "WrongPhase" in err or "already" in err.lower() or "0x0730a2ce" in err:
            logger.info("Epoch already started (OK)")
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
        logger.info("[DRY RUN] Would commit: bid=%.6f ETH, bond=%.6f ETH", bid_wei / 1e18, bond / 1e18)
        return {"epoch": epoch, "commit_salt": salt, "bid_amount": bid_wei,
                "committed": True, "revealed": False}

    chain.send_tx(
        chain.contract.functions.commit(commit_hash),
        value=bond, gas=GAS_COMMIT,
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
    logger.info("Bid committed: %.6f ETH (bond=%.6f ETH)", bid_wei / 1e18, bond / 1e18)
    return state


def close_commit(chain: ChainClient, dry_run=False):
    """Close the commit phase. Idempotent."""
    try:
        if dry_run:
            logger.info("[DRY RUN] Would call closeCommit()")
            return True
        chain.send_tx(chain.contract.functions.closeCommit(), gas=GAS_CLOSE_COMMIT)
        logger.info("closeCommit() submitted")
        return True
    except (ContractLogicError, ContractCustomError) as e:
        err = str(e)
        if "WrongPhase" in err or "TimingError" in err or "0x0730a2ce" in err:
            logger.info("closeCommit() not ready yet (commit window still open)")
            return False
        raise


def reveal_bid(chain: ChainClient, state: dict, dry_run=False):
    """Reveal a previously committed bid."""
    bid_amount = state["bid_amount"]
    salt = bytes.fromhex(state["commit_salt"][2:])

    if dry_run:
        logger.info("[DRY RUN] Would reveal: %.6f ETH", bid_amount / 1e18)
        return True

    chain.send_tx(
        chain.contract.functions.reveal(bid_amount, salt),
        gas=GAS_REVEAL,
    )
    logger.info("Bid revealed: %.6f ETH", bid_amount / 1e18)
    return True


def close_reveal(chain: ChainClient, dry_run=False):
    """Close the reveal phase. Idempotent."""
    try:
        if dry_run:
            logger.info("[DRY RUN] Would call closeReveal()")
            return True
        chain.send_tx(chain.contract.functions.closeReveal(), gas=GAS_CLOSE_REVEAL)
        logger.info("closeReveal() submitted")
        return True
    except (ContractLogicError, ContractCustomError) as e:
        err = str(e)
        if "WrongPhase" in err or "TimingError" in err or "0x0730a2ce" in err:
            logger.info("closeReveal() not ready yet (reveal window still open)")
            return False
        raise


def submit_result(chain: ChainClient, action_bytes: bytes, reasoning: bytes,
                  proof: bytes, verifier_id=1, policy_slot=-1, policy_text="",
                  dry_run=False):
    """Submit auction result with attestation proof."""
    if dry_run:
        logger.info("[DRY RUN] Would submit result: %d action bytes, "
                     "%d reasoning bytes, %d proof bytes",
                     len(action_bytes), len(reasoning), len(proof))
        return None

    receipt = chain.send_tx(
        chain.contract.functions.submitAuctionResult(
            action_bytes, reasoning, proof, verifier_id, policy_slot, policy_text
        ),
        gas=GAS_SUBMIT_RESULT,
    )
    logger.info("Result submitted! Gas used: %d", receipt['gasUsed'])
    return receipt
