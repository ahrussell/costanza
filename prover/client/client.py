#!/usr/bin/env python3
"""The Human Fund — Auction Runner Client (v2, resilient)

Designed to run as a cron job (e.g., every 2 minutes). Uses chain state as
the source of truth and local state as advisory only.

Every run:
1. Read chain state (epoch, timing, phase, winner, seed)
2. Query chain for our participation (committed? revealed? won?)
3. Load local state (may be empty — that's OK)
4. Detect irrecoverable situations (lost commit salt → accept forfeit)
5. Dispatch based on wall-clock phase + what we CAN do
6. If we can't participate, advance the contract proactively

The ONLY unrecoverable local state is commit_salt. Everything else is
chain-queryable.

Usage:
    */2 * * * * cd /path/to/thehumanfund && python -m prover.client
    python -m prover.client --ntfy-channel my-channel
"""

import fcntl
import json
import logging
import os
import sys
import tempfile
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

ZERO_ADDR = "0x" + "0" * 40


# ─── Wall-Clock Phase Resolution ────────────────────────────────────────

def _resolve_phase(auction):
    """Resolve the effective phase from wall-clock timing."""
    start = auction["start_time"]
    now = auction["now"]

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


def _try_advance(chain, ntfy):
    """Try to advance the contract past the current epoch via syncPhase.

    If a new auction opens, sends a notification. Returns True on success.
    """
    if sync_phase(chain):
        new_epoch = chain.contract.functions.currentEpoch().call()
        new_phase = chain.am.functions.getPhase(new_epoch).call()
        if new_phase == 1:  # COMMIT — auction opened
            logger.info("Auction opened for epoch %d", new_epoch)
            notify_epoch_started(ntfy, new_epoch)
        else:
            logger.info("Advanced to epoch %d (phase %d)", new_epoch, new_phase)
        return True
    return False


def _try_claim_bonds(chain, ntfy, state_dir):
    """Try to claim any owed bonds from recent epochs. Best-effort.

    Uses a separate claim_tracker.json that survives epoch state clears.
    """
    try:
        # Claim legacy bonds (pre-v2 accumulated balance)
        chain.claim_legacy_bonds()

        # Load claim tracking state (separate from epoch state)
        claim_file = Path(state_dir) / "claim_tracker.json"
        try:
            with open(claim_file) as f:
                claim_state = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            claim_state = {}

        last_epoch = claim_state.get("last_claimed_epoch", 0)
        current = chain.contract.functions.currentEpoch().call()

        for ep in range(max(1, last_epoch + 1), current):
            receipt = chain.claim_bond(ep)
            if receipt:
                bond = chain.am.functions.getBond(ep).call()
                notify_bond_claimed(ntfy, ep, bond / 1e18)
                logger.info("Claimed bond for epoch %d", ep)

        # Persist claim progress (atomic write)
        if current > last_epoch + 1:
            claim_state["last_claimed_epoch"] = current - 1
            fd, tmp = tempfile.mkstemp(dir=str(state_dir), suffix=".tmp")
            try:
                with os.fdopen(fd, "w") as f:
                    json.dump(claim_state, f)
                os.rename(tmp, str(claim_file))
            except Exception:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
    except Exception:
        logger.debug("Bond claim check failed (non-critical)", exc_info=True)


# ─── Phase Handlers ─────────────────────────────────────────────────────

def _handle_idle(chain, auction, ntfy):
    """No auction active. Check wall-clock timing and try to advance."""
    epoch = auction["epoch"]
    now = auction["now"]

    epoch_start = chain.contract.functions.epochStartTime(epoch).call()
    commit_window = chain.am.functions.commitWindow().call()
    epoch_duration = chain.contract.functions.epochDuration().call()
    commit_end = epoch_start + commit_window
    epoch_end = epoch_start + epoch_duration

    if now < epoch_start:
        logger.info("Epoch %d starts in %ds, waiting", epoch, epoch_start - now)
        return

    if now >= epoch_end:
        # Epoch is stale — syncPhase will advance past it
        logger.info("Epoch %d is stale (%ds past), advancing", epoch, now - epoch_end)
    elif now >= commit_end:
        # Within epoch but commit window closed — nothing useful to do
        logger.info("Epoch %d commit window closed, next epoch in %ds", epoch, epoch_end - now)
        return
    # else: within commit window — syncPhase will open auction

    _try_advance(chain, ntfy)


def _handle_commit(chain, config, auction, saved, participation, state_dir, ntfy):
    """Commit window is open. Submit a bid if we haven't already."""
    epoch = auction["epoch"]

    # Chain truth: already committed?
    if participation["committed"]:
        logger.info("Already committed for epoch %d (chain-confirmed), waiting for reveal", epoch)
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


def _handle_reveal(chain, auction, saved, participation, state_dir, ntfy):
    """Reveal window is open. Reveal our bid if possible."""
    epoch = auction["epoch"]

    # Chain truth: did we commit?
    if not participation["committed"]:
        logger.info("Didn't commit for epoch %d, nothing to reveal", epoch)
        return

    # Chain truth: already revealed?
    if participation["revealed"]:
        logger.info("Already revealed for epoch %d (chain-confirmed), waiting for execution", epoch)
        return

    # We committed but haven't revealed. Do we have the salt?
    commit_salt = saved.get("commit_salt")
    bid_amount = saved.get("bid_amount")

    if not commit_salt or bid_amount is None:
        # Salt lost — cannot reveal. Bond will be forfeited.
        logger.warning("Cannot reveal for epoch %d: commit_salt or bid_amount missing "
                       "from local state. Bond will be forfeited.", epoch)
        return

    if reveal_bid(chain, saved):
        saved["revealed"] = True
        save_state(saved, state_dir)
        notify_bid_revealed(ntfy, epoch, bid_amount / 1e18)
    else:
        logger.warning("Reveal failed for epoch %d", epoch)


def _handle_execution(chain, config, auction, saved, participation, state_dir, ntfy):
    """Execution window is open."""
    epoch = auction["epoch"]

    # Case 1: No winner at all (nobody committed/revealed)
    if participation["winner"] == ZERO_ADDR:
        logger.info("No winner for epoch %d, advancing past stale epoch", epoch)
        _try_advance(chain, ntfy)
        return

    # Case 2: We didn't win
    if not participation["won"]:
        logger.info("Lost auction for epoch %d to %s...", epoch, participation["winner"][:10])
        if not saved.get("loss_notified"):
            notify_auction_lost(ntfy, epoch, participation["winner"])
            saved["loss_notified"] = True
            save_state(saved, state_dir)
        return

    # Case 3: We won!

    # Check if we already failed permanently
    if saved.get("submission_failed"):
        logger.info("Submission previously failed for epoch %d, waiting for epoch to expire", epoch)
        return

    # Check retry limit
    attempts = saved.get("submission_attempts", 0)
    if attempts >= MAX_SUBMIT_RETRIES:
        logger.warning("Max submission retries (%d) exhausted", MAX_SUBMIT_RETRIES)
        saved["submission_failed"] = True
        save_state(saved, state_dir)
        notify_epoch_abandoned(ntfy, epoch, f"Max retries ({MAX_SUBMIT_RETRIES}) exhausted")
        return

    # Notify win (once)
    if not saved.get("won_notified"):
        bounty_wei = auction["winning_bid"]
        logger.info("WE WON the auction! (bounty: %.6f ETH)", bounty_wei / 1e18)
        notify_auction_won(ntfy, epoch, bounty_wei / 1e18)
        saved["won_notified"] = True
        save_state(saved, state_dir)

    # Check if we have enough time to run TEE inference
    MIN_EXEC_TIME = 600  # 10 minutes minimum
    time_remaining = auction["exec_end"] - auction["now"]
    if time_remaining < MIN_EXEC_TIME:
        logger.warning("Only %ds left in execution window (need %ds), skipping TEE",
                       time_remaining, MIN_EXEC_TIME)
        return

    # Sync phase to capture seed (REVEAL → EXECUTION transition)
    sync_phase(chain)

    # Re-read auction state after sync — seed is now captured
    auction = chain.get_auction_state()
    logger.info("Post-sync: epoch=%d, phase=%d, seed=%d",
                auction["epoch"], auction["contract_phase"], auction["randomness_seed"])

    # Run TEE inference
    tee_result = _run_tee_inference(chain, config, auction, saved, state_dir)

    # Submit on-chain
    _submit_result(chain, config, tee_result, auction, saved, state_dir, ntfy)


def _handle_epoch_over(chain, auction, saved, participation, state_dir, ntfy):
    """All windows have passed. Detect bond forfeiture and advance epoch."""
    epoch = auction["epoch"]

    # Chain truth: detect bond forfeiture
    if participation["committed"] and not participation["revealed"]:
        bond = auction["bond_amount"]
        if bond > 0 and not saved.get("forfeit_notified"):
            logger.warning("BOND FORFEITED for epoch %d (committed but missed reveal)", epoch)
            notify_bond_forfeited(ntfy, epoch, bond / 1e18)
            saved["forfeit_notified"] = True
            save_state(saved, state_dir)

    # Advance past the expired epoch
    if _try_advance(chain, ntfy):
        clear_state(state_dir)
        logger.info("Epoch %d expired, advanced past it", epoch)
        notify_epoch_settled(ntfy, epoch)
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
    """Main runner logic — chain truth + wall-clock dispatch."""
    chain = ChainClient(config["rpc_url"], config["private_key"], config["contract_address"])
    ntfy = config["ntfy_channel"]
    state_dir = config["state_dir"]

    # 1. Read chain state (source of truth)
    auction = chain.get_auction_state()
    epoch = auction["epoch"]
    contract_phase = auction["contract_phase"]
    effective_phase = _resolve_phase(auction)

    logger.info("Epoch %d | Contract: %s | Clock: %s",
                epoch, PHASE_NAMES.get(contract_phase, str(contract_phase)), effective_phase)

    # 2. Load local state (advisory only — may be empty)
    saved = load_state(state_dir, current_epoch=epoch)

    # 3. Query chain for our participation (source of truth)
    participation = chain.check_participation(epoch)
    logger.info("Participation: committed=%s revealed=%s won=%s",
                participation["committed"], participation["revealed"], participation["won"])

    # 4. Detect irrecoverable salt loss early
    if participation["committed"] and not saved.get("commit_salt"):
        if not participation["revealed"]:
            bond = auction["bond_amount"]
            logger.warning("SALT LOST: committed on-chain but no local salt. "
                          "Bond of %.6f ETH will be forfeited.", bond / 1e18)
            if not saved.get("salt_loss_notified"):
                notify_bond_forfeited(ntfy, epoch, bond / 1e18)
                saved["salt_loss_notified"] = True
                save_state(saved, state_dir)

    # 5. Claim any owed bonds (cheap, best-effort)
    _try_claim_bonds(chain, ntfy, state_dir)

    # 6. Dispatch based on wall-clock phase
    if effective_phase == "idle":
        _handle_idle(chain, auction, ntfy)
    elif effective_phase == "commit":
        _handle_commit(chain, config, auction, saved, participation, state_dir, ntfy)
    elif effective_phase == "reveal":
        _handle_reveal(chain, auction, saved, participation, state_dir, ntfy)
    elif effective_phase == "execution":
        _handle_execution(chain, config, auction, saved, participation, state_dir, ntfy)
    elif effective_phase == "epoch_over":
        _handle_epoch_over(chain, auction, saved, participation, state_dir, ntfy)


def main():
    logging.basicConfig(
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        level=logging.INFO,
    )

    config = load_config()

    # Acquire exclusive lock
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
