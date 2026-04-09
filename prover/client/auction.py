#!/usr/bin/env python3
"""Auction actions — commit, reveal, submit, sync.

With the v2 contract, phase advancement is automatic (via syncPhase).
The client only needs to call the action appropriate for the current
wall-clock phase. Each action auto-syncs the contract state first.
"""

import logging
import secrets

from web3 import Web3
from web3.exceptions import ContractLogicError, ContractCustomError

from .chain import ChainClient, build_error_selector_map
from .state import save as save_state

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
GAS_SYNC_PHASE = 800_000       # syncPhase may chain through multiple transitions
GAS_COMMIT = 800_000           # commit auto-syncs (may open auction)
GAS_REVEAL = 500_000           # reveal auto-syncs (may close commit)
GAS_SUBMIT_RESULT = 15_000_000 # DCAP verification is expensive; auto-syncs (may close reveal)
GAS_CLAIM_BOND = 100_000

MAX_SUBMIT_RETRIES = 2  # Max submission attempts before giving up on an epoch

# Build error selector map from contract ABIs at import time.
ERROR_SELECTORS = build_error_selector_map("TheHumanFund", "AuctionManager")

# Map error names to submission categories
_ERROR_CATEGORIES = {
    "TimingError": ("timing_expired", False, "Execution window expired"),
    "ProofFailed": ("proof_failed", False, "Proof verification failed (image key or DCAP issue)"),
    "WrongPhase": ("wrong_phase", False, "Auction not in execution phase"),
    "AlreadyDone": ("already_done", False, "Result already submitted"),
}

# Errors that are expected during normal cron operation (timing races)
_EXPECTED_ERRORS = {"WrongPhase", "TimingError", "AlreadyDone"}


class SubmissionError(Exception):
    """Raised when submitAuctionResult fails with a classified error."""
    def __init__(self, category, message, should_retry=False):
        self.category = category
        self.should_retry = should_retry
        super().__init__(message)


def _match_error(err_str):
    """Match an error string against known error selectors and names."""
    for selector, name in ERROR_SELECTORS.items():
        if selector in err_str or name in err_str:
            return name
    return None


def classify_submit_error(err):
    """Classify a submitAuctionResult error into a category.

    Returns (category, should_retry, message).
    """
    err_str = str(err)
    error_name = _match_error(err_str)
    if error_name and error_name in _ERROR_CATEGORIES:
        return _ERROR_CATEGORIES[error_name]

    # Bare revert from DCAP verification — transient, worth retrying
    if "execution reverted" in err_str and "'0x'" in err_str:
        return ("bare_revert", True, "DCAP verification bare revert (transient)")

    # On-chain reverts with high gas usage (>1M) are likely DCAP verification failures.
    # These are transient (Automata infrastructure on Base Sepolia) — worth retrying.
    if "Transaction reverted on-chain" in err_str:
        return ("dcap_revert", True, f"On-chain revert (likely DCAP): {err_str[:200]}")

    return ("unknown", False, f"Unknown submission error: {err_str[:200]}")


def is_expected_revert(err: str) -> bool:
    """Check if a revert is a known timing/phase error that should be silently retried."""
    error_name = _match_error(err)
    return error_name is not None and error_name in _EXPECTED_ERRORS


def sync_phase(chain: ChainClient):
    """Call syncPhase() on the contract to advance through elapsed phases.

    Returns True if successful, False on expected revert, raises on unexpected error.
    """
    try:
        chain.sync_phase(gas=GAS_SYNC_PHASE)
        return True
    except (ContractLogicError, ContractCustomError, RuntimeError) as e:
        if isinstance(e, RuntimeError) or is_expected_revert(str(e)):
            logger.info("syncPhase() no-op or not ready — %s", str(e)[:80])
            return False
        raise


def commit_bid(chain: ChainClient, bid_wei: int, state_dir=None):
    """Generate salt, compute commit hash, submit bid with bond.

    The contract's commit() calls _syncPhase() first, which opens the
    auction if needed. Returns the saved state dict.
    """
    salt = "0x" + secrets.token_hex(32)
    salt_bytes = bytes.fromhex(salt[2:])

    commit_hash = Web3.keccak(bid_wei.to_bytes(32, "big") + salt_bytes)

    bond = chain.get_current_bond()
    epoch = chain.contract.functions.currentEpoch().call()

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


def reveal_bid(chain: ChainClient, state: dict):
    """Reveal a previously committed bid.

    The contract's reveal() calls _syncPhase() first, which closes
    the commit window if needed. Returns True on success.
    """
    bid_amount = state.get("bid_amount")
    commit_salt = state.get("commit_salt")

    if bid_amount is None or not commit_salt:
        logger.error("Cannot reveal: missing bid_amount or commit_salt in state")
        return False

    salt = bytes.fromhex(commit_salt[2:])

    try:
        chain.send_tx(
            chain.contract.functions.reveal(bid_amount, salt),
            gas=GAS_REVEAL,
        )
        logger.info("Bid revealed: %.6f ETH", bid_amount / 1e18)
        return True
    except (ContractLogicError, ContractCustomError, RuntimeError) as e:
        if isinstance(e, RuntimeError) or is_expected_revert(str(e)):
            logger.info("reveal() not ready or window passed — %s", str(e)[:80])
            return False
        raise


def submit_result(chain: ChainClient, action_bytes: bytes, reasoning: bytes,
                  proof: bytes, verifier_id=1, policy_slot=-1, policy_text=""):
    """Submit auction result with attestation proof.

    The contract's submitAuctionResult() calls _syncPhase() first,
    which closes the reveal window and captures the seed if needed.

    Raises:
        SubmissionError: On classified contract revert (with category and should_retry).
    """
    try:
        receipt = chain.send_tx(
            chain.contract.functions.submitAuctionResult(
                action_bytes, reasoning, proof, verifier_id, policy_slot, policy_text
            ),
            gas=GAS_SUBMIT_RESULT,
        )
        logger.info("Result submitted! Gas used: %d", receipt['gasUsed'])
        return receipt
    except (ContractLogicError, ContractCustomError, RuntimeError) as e:
        category, should_retry, message = classify_submit_error(e)
        logger.error("submitAuctionResult() failed [%s]: %s", category, message)
        raise SubmissionError(category, message, should_retry=should_retry) from e
