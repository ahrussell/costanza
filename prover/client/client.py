#!/usr/bin/env python3
"""The Human Fund — Auction Runner Client (v2)

Designed to run as a cron job (e.g., every 2 minutes). Computes the
effective auction phase from wall-clock timing and acts accordingly:

  COMMIT window  -> calculate bid, commit
  REVEAL window  -> reveal bid (contract auto-closes commit)
  EXECUTION      -> if winner, run TEE inference and submit
  EPOCH OVER     -> detect bond forfeiture, try to advance epoch

The v2 contract auto-advances phases via _syncPhase() on every call,
so the client never needs to call startEpoch/closeCommit/closeReveal
explicitly. Bond refunds are lazy via claimBond(epoch).

Usage:
    # Cron entry (every 2 minutes)
    */2 * * * * cd /path/to/thehumanfund && python -m prover.client

    # Manual run with notifications
    python -m prover.client --ntfy-channel my-channel
"""

import fcntl
import logging
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from .config import load_config
from .chain import ChainClient
from .auction import (
    sync_phase, commit_bid, reveal_bid, submit_result,
    SubmissionError, MAX_SUBMIT_RETRIES, _match_error, ERROR_SELECTORS,
    PHASE_NAMES,
)
from .bid_strategy import estimate_bid, clamp_bid
from .state import (
    load as load_state, save as save_state, clear as clear_state,
    save_tee_result, load_tee_result,
)
from .notifier import (
    notify_epoch_started, notify_bid_committed, notify_bid_revealed,
    notify_auction_won, notify_auction_lost, notify_result_submitted,
    notify_error, notify_submission_failed, notify_epoch_abandoned,
    notify_epoch_settled, notify_bond_forfeited, notify_bond_claimed,
    notify_cached_submission,
)

logger = logging.getLogger(__name__)


# ─── Wall-Clock Phase Resolution ────────────────────────────────────────

def _resolve_phase(auction):
    """Resolve the effective phase from wall-clock timing.

    Returns one of: 'idle', 'commit', 'reveal', 'execution', 'epoch_over'
    """
    start = auction["start_time"]
    now = auction["now"]

    # No auction active (start_time == 0 means IDLE/SETTLED in AM)
    if start == 0:
        return "idle"

    if now < auction["commit_end"]:
        return "commit"
    elif now < auction["reveal_end"]:
        return "reveal"
    elif now < auction["exec_end"]:
        return "execution"
    else:
        return "epoch_over"


# ─── Helpers ────────────────────────────────────────────────────────────

def _parse_eth_usd(raw_price):
    """Parse ETH/USD price from Chainlink's 8-decimal format."""
    if raw_price > 1e6:
        return raw_price / 1e8
    return 2000.0


def get_tee_client(config):
    """Create the appropriate TEE client based on config."""
    if config["tee_client"] == "gcp-gpu":
        from .tee_clients.gcp import GCPTEEClient
        return GCPTEEClient(
            project=config["gcp_project"],
            zone=config["gcp_zone"],
            image=config["gcp_image"],
            machine_type="a3-highgpu-1g",
            inference_timeout=config.get("enclave_timeout", 900),
        )
    elif config["tee_client"] == "gcp-cpu":
        from .tee_clients.gcp import GCPTEEClient
        return GCPTEEClient(
            project=config["gcp_project"],
            zone=config["gcp_zone"],
            image=config.get("gcp_image"),
            machine_type="c3-standard-4",
            inference_timeout=config.get("enclave_timeout", 1800),
        )
    else:
        raise ValueError(f"Unknown TEE client: {config['tee_client']}")


def _try_claim_bonds(chain, ntfy, state_dir):
    """Try to claim any owed bonds from recent epochs. Best-effort."""
    try:
        # Claim legacy bonds (pre-v2 accumulated balance)
        receipt = chain.claim_legacy_bonds()
        if receipt:
            logger.info("Claimed legacy bonds")

        # Claim bonds from recently participated epochs
        saved = load_state(state_dir)
        last_epoch = saved.get("last_claimed_epoch", 0)
        current = chain.contract.functions.currentEpoch().call()
        for ep in range(max(1, last_epoch + 1), current):
            receipt = chain.claim_bond(ep)
            if receipt:
                bond = chain.am.functions.getBond(ep).call()
                notify_bond_claimed(ntfy, ep, bond / 1e18)
                logger.info("Claimed bond for epoch %d", ep)
        # Track where we left off
        if current > last_epoch + 1:
            saved["last_claimed_epoch"] = current - 1
            save_state(saved, state_dir)
    except Exception:
        logger.debug("Bond claim check failed (non-critical)", exc_info=True)


# ─── Phase Handlers ─────────────────────────────────────────────────────

def _handle_idle(chain, auction, ntfy):
    """No auction active or between epochs. Try to advance via syncPhase."""
    if sync_phase(chain):
        # Re-read epoch after sync — it may have opened a new auction
        new_epoch = chain.contract.functions.currentEpoch().call()
        logger.info("syncPhase advanced to epoch %d", new_epoch)
        notify_epoch_started(ntfy, new_epoch)


def _handle_commit(chain, config, auction, saved, state_dir, ntfy):
    """Commit window is open. Submit a bid if we haven't already."""
    epoch = auction["epoch"]
    if saved.get("committed"):
        logger.info("Already committed for epoch %d, waiting for reveal window", epoch)
        return

    gas_price = chain.get_gas_price()
    max_bid = chain.get_effective_max_bid()
    eth_usd = _parse_eth_usd(chain.get_eth_usd_price())

    bid = estimate_bid(
        gas_price, machine_type=config.get("gcp_machine_type", "a3-highgpu-1g"),
        eth_usd_price=eth_usd, margin=config["bid_margin"],
    )
    bid = clamp_bid(bid, max_bid)
    logger.info("Bid estimate: %.6f ETH (max: %.6f ETH)", bid / 1e18, max_bid / 1e18)

    saved = commit_bid(chain, bid, state_dir=state_dir)
    notify_bid_committed(ntfy, epoch, bid / 1e18)


def _handle_reveal(chain, auction, saved, state_dir, ntfy):
    """Reveal window is open. Reveal our bid (contract auto-closes commit)."""
    epoch = auction["epoch"]

    if not saved.get("committed"):
        logger.info("Didn't commit for epoch %d, nothing to reveal", epoch)
        return

    if saved.get("revealed"):
        logger.info("Already revealed for epoch %d, waiting for execution", epoch)
        return

    if reveal_bid(chain, saved):
        saved["revealed"] = True
        save_state(saved, state_dir)
        notify_bid_revealed(ntfy, epoch, saved["bid_amount"] / 1e18)
    else:
        logger.warning("Reveal failed for epoch %d", epoch)


def _handle_execution(chain, config, auction, saved, state_dir, ntfy):
    """Execution window is open. If we won, run TEE and submit."""
    epoch = auction["epoch"]
    winner = auction["winner"]
    zero_addr = "0x" + "0" * 40

    if winner == zero_addr or winner.lower() != chain.account.address.lower():
        if winner != zero_addr:
            logger.info("Lost auction to %s...", winner[:10])
            if not saved.get("loss_notified"):
                notify_auction_lost(ntfy, epoch, winner)
                saved["loss_notified"] = True
                save_state(saved, state_dir)
        return

    # We won!

    # Check retry limit
    attempts = saved.get("submission_attempts", 0)
    if saved.get("submission_failed"):
        logger.info("Submission previously failed for epoch %d, waiting for epoch to expire", epoch)
        return
    if attempts >= MAX_SUBMIT_RETRIES:
        logger.warning("Max submission retries (%d) exhausted", MAX_SUBMIT_RETRIES)
        saved["submission_failed"] = True
        save_state(saved, state_dir)
        notify_epoch_abandoned(ntfy, epoch, f"Max retries ({MAX_SUBMIT_RETRIES}) exhausted")
        return

    # Notify win (only once per epoch)
    if not saved.get("won_notified"):
        bounty_wei = auction["winning_bid"]
        logger.info("WE WON the auction! (bounty: %.6f ETH)", bounty_wei / 1e18)
        notify_auction_won(ntfy, epoch, bounty_wei / 1e18)
        saved["won_notified"] = True
        save_state(saved, state_dir)

    # Ensure the reveal phase has been closed (seed captured, input hash bound).
    # The contract auto-syncs on submitAuctionResult, but we need the input hash
    # BEFORE running TEE inference (the TEE verifies against it).
    sync_phase(chain)

    # Load or run TEE inference
    tee_result = _run_tee_inference(chain, config, auction, saved, state_dir)

    # Submit on-chain
    _submit_result(chain, config, tee_result, auction, saved, state_dir, ntfy)


def _handle_epoch_over(chain, auction, saved, state_dir, ntfy):
    """All windows have passed. Detect bond forfeiture and advance epoch."""
    epoch = auction["epoch"]

    # Detect bond forfeiture: we committed but never revealed
    if saved.get("committed") and not saved.get("revealed"):
        bond = auction["bond_amount"]
        if bond > 0:
            logger.warning("BOND FORFEITED for epoch %d (committed but missed reveal window)", epoch)
            notify_bond_forfeited(ntfy, epoch, bond / 1e18)

    # Advance to next epoch via syncPhase
    if sync_phase(chain):
        clear_state(state_dir)
        new_epoch = chain.contract.functions.currentEpoch().call()
        logger.info("Advanced to epoch %d", new_epoch)
        notify_epoch_settled(ntfy, epoch)
        notify_epoch_started(ntfy, new_epoch)
    else:
        logger.info("Cannot advance epoch yet")


# ─── TEE Inference & Submission ─────────────────────────────────────────

def _run_tee_inference(chain, config, auction, saved, state_dir):
    """Load cached TEE result or run fresh inference."""
    epoch = auction["epoch"]

    # Try cached result first
    if saved.get("tee_completed") and saved.get("tee_result_path"):
        tee_result = load_tee_result(saved["tee_result_path"])
        if tee_result:
            logger.info("Loaded cached TEE result from %s", saved["tee_result_path"])
            return tee_result
        logger.warning("Cached TEE result missing/corrupt, re-running inference")
        saved.pop("tee_completed", None)
        saved.pop("tee_result_path", None)

    logger.info("Starting TEE inference...")
    epoch_state = chain.read_contract_state()
    contract_state = chain.build_contract_state_for_tee(epoch_state)

    prompt_path = Path(config["system_prompt_path"])
    system_prompt = prompt_path.read_text().strip()

    seed = auction["randomness_seed"]
    logger.info("Seed: %d", seed)

    tee_client = get_tee_client(config)
    tee_result = tee_client.run_epoch(
        epoch_state=epoch_state,
        contract_state=contract_state,
        system_prompt=system_prompt,
        seed=seed,
    )
    logger.info("TEE inference complete (%.1f min)", tee_result.get("vm_minutes", 0))
    logger.info("Action: %s", tee_result.get("action", {}).get("action", "unknown"))

    # Cache for retry
    result_path = save_tee_result(tee_result, epoch, state_dir)
    saved["tee_completed"] = True
    saved["tee_result_path"] = result_path
    save_state(saved, state_dir)

    return tee_result


def _submit_result(chain, config, tee_result, auction, saved, state_dir, ntfy):
    """Submit TEE result on-chain."""
    epoch = auction["epoch"]
    attempts = saved.get("submission_attempts", 0)

    action_bytes = bytes.fromhex(tee_result["action_bytes"].replace("0x", ""))
    reasoning_bytes = tee_result["reasoning"].encode("utf-8")
    attestation_bytes = bytes.fromhex(tee_result["attestation_quote"].replace("0x", ""))

    # Extract optional worldview update
    action_json = tee_result.get("action", {})
    worldview = action_json.get("worldview") or action_json.get("params", {}).get("worldview")
    if worldview and isinstance(worldview, dict):
        policy_slot = int(worldview.get("slot", -1))
        policy_text = str(worldview.get("policy", ""))
    else:
        policy_slot = -1
        policy_text = ""

    verifier_id = config["verifier_id"]
    logger.info("Submitting result (verifier=%d, policy_slot=%d, attempt=%d/%d)...",
               verifier_id, policy_slot, attempts + 1, MAX_SUBMIT_RETRIES)

    try:
        receipt = submit_result(
            chain,
            action_bytes=action_bytes,
            reasoning=reasoning_bytes,
            proof=attestation_bytes,
            verifier_id=verifier_id,
            policy_slot=policy_slot,
            policy_text=policy_text,
        )
        logger.info("Result submitted! tx=%s", receipt['transactionHash'].hex())
        clear_state(state_dir)
        notify_result_submitted(ntfy, epoch, action_json.get("action", "?"))
    except SubmissionError as e:
        saved["submission_attempts"] = attempts + 1
        if not e.should_retry or saved["submission_attempts"] >= MAX_SUBMIT_RETRIES:
            saved["submission_failed"] = True
            save_state(saved, state_dir)
            logger.error("Submission permanently failed [%s]: %s", e.category, e)
            notify_epoch_abandoned(ntfy, epoch, f"{e.category}: {e}")
        else:
            save_state(saved, state_dir)
            logger.warning("Submission failed [%s], will retry (%d/%d): %s",
                          e.category, saved["submission_attempts"], MAX_SUBMIT_RETRIES, e)
            notify_submission_failed(ntfy, epoch, e, saved["submission_attempts"], MAX_SUBMIT_RETRIES)


# ─── Main Entry Point ───────────────────────────────────────────────────

def run(config):
    """Main runner logic — resolve wall-clock phase and act accordingly."""
    chain = ChainClient(config["rpc_url"], config["private_key"], config["contract_address"])
    ntfy = config["ntfy_channel"]
    state_dir = config["state_dir"]

    # Get current auction state with timing
    auction = chain.get_auction_state()
    epoch = auction["epoch"]
    contract_phase = auction["contract_phase"]
    effective_phase = _resolve_phase(auction)

    logger.info("Epoch %d | Contract: %s | Clock: %s",
                epoch, PHASE_NAMES.get(contract_phase, str(contract_phase)), effective_phase)

    # Load saved state
    saved = load_state(state_dir, current_epoch=epoch)

    # Try to claim any owed bonds (cheap, best-effort)
    _try_claim_bonds(chain, ntfy, state_dir)

    # Dispatch based on wall-clock phase
    if effective_phase == "idle":
        _handle_idle(chain, auction, ntfy)

    elif effective_phase == "commit":
        _handle_commit(chain, config, auction, saved, state_dir, ntfy)

    elif effective_phase == "reveal":
        _handle_reveal(chain, auction, saved, state_dir, ntfy)

    elif effective_phase == "execution":
        _handle_execution(chain, config, auction, saved, state_dir, ntfy)

    elif effective_phase == "epoch_over":
        _handle_epoch_over(chain, auction, saved, state_dir, ntfy)


def main():
    logging.basicConfig(
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        level=logging.INFO,
    )

    config = load_config()

    # Acquire exclusive lock to prevent concurrent runner instances
    lock_path = Path(config["state_dir"]) / ".runner.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock_fd = open(lock_path, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        logger.info("Another runner instance is active, exiting")
        sys.exit(0)

    try:
        run(config)
    except Exception as e:
        logger.error("Runner failed: %s", e, exc_info=True)
        error_name = _match_error(str(e))
        if error_name:
            msg = f"Contract error: {error_name} — {str(e)[:200]}"
        else:
            msg = str(e)
        notify_error(config.get("ntfy_channel"), "?", msg)
        sys.exit(1)
    finally:
        lock_fd.close()


if __name__ == "__main__":
    main()
