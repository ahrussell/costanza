#!/usr/bin/env python3
"""Auction state machine — idempotent handlers for each auction phase.

Designed for cron: each function checks the current state before acting,
so calling the same function multiple times is safe.
"""

import logging
import secrets

from web3.exceptions import ContractLogicError, ContractCustomError

from .chain import ChainClient, build_error_selector_map
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
GAS_START_EPOCH = 800_000
GAS_COMMIT = 200_000
GAS_CLOSE_COMMIT = 300_000
GAS_REVEAL = 200_000
GAS_CLOSE_REVEAL = 500_000
GAS_SUBMIT_RESULT = 15_000_000  # DCAP verification is expensive

MAX_SUBMIT_RETRIES = 2  # Max submission attempts before giving up on an epoch

# Build error selector map from contract ABIs at import time.
# Selectors are deterministic (keccak256 of error signatures) and
# never change unless the Solidity error definitions change.
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
    """Match an error string against known error selectors and names.

    Returns the error name if found, None otherwise.
    """
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

    return ("unknown", False, f"Unknown submission error: {err_str[:200]}")


def is_expected_revert(err: str) -> bool:
    """Check if a revert is a known timing/phase error that should be silently retried."""
    error_name = _match_error(err)
    return error_name is not None and error_name in _EXPECTED_ERRORS


def start_epoch(chain: ChainClient):
    """Start a new epoch. Idempotent — catches 'already started' revert."""
    try:
        receipt = chain.send_tx(chain.contract.functions.startEpoch(), gas=GAS_START_EPOCH)
        logger.info("startEpoch() confirmed: gas=%s", receipt.get("gasUsed", "?"))
        return True
    except RuntimeError as e:
        logger.error("startEpoch() reverted on-chain: %s", e)
        return False
    except (ContractLogicError, ContractCustomError) as e:
        err = str(e)
        if "already" in err.lower() or "AlreadyDone" in err:
            logger.info("Epoch already started (OK)")
            return True
        if is_expected_revert(err):
            logger.info("startEpoch() not ready yet — %s", err[:80])
            return False
        raise


def commit_bid(chain: ChainClient, bid_wei: int, state_dir=None):
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


def close_commit(chain: ChainClient):
    """Close the commit phase. Idempotent — any revert means 'not ready yet'."""
    try:
        chain.send_tx(chain.contract.functions.closeCommit(), gas=GAS_CLOSE_COMMIT)
        logger.info("closeCommit() submitted")
        return True
    except (ContractLogicError, ContractCustomError, RuntimeError) as e:
        if isinstance(e, RuntimeError) or is_expected_revert(str(e)):
            logger.info("closeCommit() not ready yet — %s", str(e)[:80])
            return False
        raise


def reveal_bid(chain: ChainClient, state: dict):
    """Reveal a previously committed bid. Idempotent — any revert means window passed."""
    bid_amount = state["bid_amount"]
    salt = bytes.fromhex(state["commit_salt"][2:])

    try:
        chain.send_tx(
            chain.contract.functions.reveal(bid_amount, salt),
            gas=GAS_REVEAL,
        )
        logger.info("Bid revealed: %.6f ETH", bid_amount / 1e18)
        return True
    except (ContractLogicError, ContractCustomError, RuntimeError) as e:
        if isinstance(e, RuntimeError) or is_expected_revert(str(e)):
            logger.info("reveal() not ready or already done — %s", str(e)[:80])
            return False
        raise


def close_reveal(chain: ChainClient):
    """Close the reveal phase. Idempotent — any revert means 'not ready yet'."""
    try:
        chain.send_tx(chain.contract.functions.closeReveal(), gas=GAS_CLOSE_REVEAL)
        logger.info("closeReveal() submitted")
        return True
    except (ContractLogicError, ContractCustomError, RuntimeError) as e:
        if isinstance(e, RuntimeError) or is_expected_revert(str(e)):
            logger.info("closeReveal() not ready yet — %s", str(e)[:80])
            return False
        raise


def submit_result(chain: ChainClient, action_bytes: bytes, reasoning: bytes,
                  proof: bytes, verifier_id=1, policy_slot=-1, policy_text=""):
    """Submit auction result with attestation proof.

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
