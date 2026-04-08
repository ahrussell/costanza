#!/usr/bin/env python3
"""The Human Fund — Auction Runner Client

Designed to run as a cron job (e.g., every 5 minutes). Checks the current
auction phase and takes the appropriate action:

  IDLE       -> startEpoch()
  COMMIT     -> calculate bid, commit (if not already committed)
  REVEAL     -> reveal bid (if committed but not revealed)
  EXECUTION  -> if winner, run TEE inference and submit result
  SETTLED    -> clear state, wait for next epoch

Usage:
    # Cron entry (every 5 minutes)
    */10 * * * * cd /path/to/thehumanfund && python -m runner.client

    # Manual run with notifications
    python -m runner.client --ntfy-channel my-channel
"""

import fcntl
import logging
import sys
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path

from .config import load_config
from .chain import ChainClient
from .auction import (
    start_epoch, commit_bid, close_commit, reveal_bid, close_reveal,
    submit_result, SubmissionError, MAX_SUBMIT_RETRIES,
    IDLE, COMMIT, REVEAL, EXECUTION, SETTLED, PHASE_NAMES,
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
)

logger = logging.getLogger(__name__)


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


def run(config):
    """Main runner logic — check state and act."""
    chain = ChainClient(config["rpc_url"], config["private_key"], config["contract_address"])
    ntfy = config["ntfy_channel"]
    state_dir = config["state_dir"]
    dry_run = config["dry_run"]

    # Get current auction state
    auction = chain.get_auction_phase()
    epoch = auction["epoch"]
    phase = auction["phase"]

    winner = auction['winner']
    zero_addr = '0x' + '0' * 40
    if winner != zero_addr:
        logger.info("Epoch %d | Phase: %s | Winner: %s...", epoch, PHASE_NAMES.get(phase, phase), winner[:10])
    else:
        logger.info("Epoch %d | Phase: %s", epoch, PHASE_NAMES.get(phase, phase))

    # Load saved state
    saved = load_state(state_dir, current_epoch=epoch)

    if phase == IDLE:
        # Skip futile startEpoch() calls when we know the next epoch isn't eligible yet
        next_eligible = saved.get("next_eligible_time")
        if next_eligible and time.time() < next_eligible:
            eligible_dt = datetime.fromtimestamp(next_eligible, tz=timezone.utc)
            logger.info("Next epoch not eligible until %s, skipping", eligible_dt.isoformat())
            return

        started = start_epoch(chain, dry_run=dry_run)
        if started:
            notify_epoch_started(ntfy, epoch)
        elif not dry_run:
            # startEpoch failed (likely TimingError) — compute when it'll be eligible
            try:
                timing = chain.get_epoch_timing()
                saved["next_eligible_time"] = timing["next_eligible_time"]
                save_state(saved, state_dir)
                eligible_dt = datetime.fromtimestamp(
                    timing["next_eligible_time"], tz=timezone.utc)
                logger.info("Next epoch eligible at %s", eligible_dt.isoformat())
            except Exception:
                logger.debug("Could not read epoch timing", exc_info=True)

    elif phase == COMMIT:
        if not saved.get("committed"):
            gas_price = chain.get_gas_price()
            max_bid = chain.get_effective_max_bid()
            eth_usd_raw = chain.get_eth_usd_price()
            eth_usd = eth_usd_raw / 1e8 if eth_usd_raw > 1e6 else 2000.0

            bid = estimate_bid(
                gas_price, machine_type=config.get("gcp_machine_type", "a3-highgpu-1g"),
                eth_usd_price=eth_usd, margin=config["bid_margin"],
            )
            bid = clamp_bid(bid, max_bid)
            logger.info("Bid estimate: %.6f ETH (max: %.6f ETH)", bid / 1e18, max_bid / 1e18)

            saved = commit_bid(chain, bid, state_dir=state_dir, dry_run=dry_run)
            notify_bid_committed(ntfy, epoch, bid / 1e18)
        else:
            logger.info("Already committed, waiting for commit window to close")
            close_commit(chain, dry_run=dry_run)

    elif phase == REVEAL:
        if saved.get("committed") and not saved.get("revealed"):
            if reveal_bid(chain, saved, dry_run=dry_run):
                saved["revealed"] = True
                save_state(saved, state_dir)
                notify_bid_revealed(ntfy, epoch, saved["bid_amount"] / 1e18)
        elif not saved.get("committed"):
            logger.info("Didn't commit this epoch, skipping reveal")
        else:
            logger.info("Already revealed, waiting for reveal window to close")
            close_reveal(chain, dry_run=dry_run)

    elif phase == EXECUTION:
        winner = auction["winner"]
        if winner.lower() == chain.account.address.lower():
            # First check: is the execution window still open?
            # This prevents wasting money on TEE inference for an expired epoch.
            try:
                deadline = chain.get_execution_deadline()
                now = chain.w3.eth.get_block("latest")["timestamp"]
                if deadline > 0 and now >= deadline:
                    logger.warning("Execution window expired (deadline=%d, now=%d, %d sec ago). "
                                  "Skipping inference, attempting to advance epoch.",
                                  deadline, now, now - deadline)
                    started = start_epoch(chain, dry_run=dry_run)
                    if started:
                        clear_state(state_dir)
                        new_epoch = chain.contract.functions.currentEpoch().call()
                        notify_epoch_started(ntfy, new_epoch)
                    else:
                        # Compute next eligible time so we don't hammer
                        try:
                            timing = chain.get_epoch_timing()
                            saved["next_eligible_time"] = timing["next_eligible_time"]
                            save_state(saved, state_dir)
                            eligible_dt = datetime.fromtimestamp(
                                timing["next_eligible_time"], tz=timezone.utc)
                            logger.info("Next epoch eligible at %s", eligible_dt.isoformat())
                        except Exception:
                            logger.debug("Could not read epoch timing", exc_info=True)
                    return
            except Exception:
                logger.debug("Could not read execution deadline, proceeding cautiously", exc_info=True)

            # Check if we've already given up on this epoch — try to advance past it
            if saved.get("submission_failed"):
                logger.info("Submission previously failed, attempting to advance past stale epoch")
                started = start_epoch(chain, dry_run=dry_run)
                if started:
                    clear_state(state_dir)
                    new_epoch = chain.contract.functions.currentEpoch().call()
                    notify_epoch_started(ntfy, new_epoch)
                else:
                    logger.info("Cannot advance yet (epoch duration not elapsed)")
                return

            # Check retry limit
            attempts = saved.get("submission_attempts", 0)
            if attempts >= MAX_SUBMIT_RETRIES:
                logger.warning("Max submission retries (%d) exhausted, giving up", MAX_SUBMIT_RETRIES)
                saved["submission_failed"] = True
                save_state(saved, state_dir)
                notify_epoch_abandoned(ntfy, epoch, f"Max retries ({MAX_SUBMIT_RETRIES}) exhausted")
                return

            bounty_wei = auction["winning_bid"]

            # Try to load cached TEE result from a previous run
            tee_result = None
            if saved.get("tee_completed") and saved.get("tee_result_path"):
                tee_result = load_tee_result(saved["tee_result_path"])
                if tee_result:
                    logger.info("Loaded cached TEE result from %s", saved["tee_result_path"])
                else:
                    logger.warning("Cached TEE result missing/corrupt, re-running inference")
                    saved.pop("tee_completed", None)
                    saved.pop("tee_result_path", None)

            # Run TEE inference if we don't have a cached result
            if tee_result is None:
                logger.info("WE WON! Starting TEE inference... (bounty: %.6f ETH)", bounty_wei / 1e18)
                notify_auction_won(ntfy, epoch, bounty_wei / 1e18)

                logger.info("Reading contract state...")
                epoch_state = chain.read_contract_state()
                contract_state = chain.build_contract_state_for_tee(epoch_state)

                prompt_path = Path(config["system_prompt_path"])
                system_prompt = prompt_path.read_text().strip()

                seed = auction["randomness_seed"]
                logger.info("Seed: %d", seed)

                tee_client = get_tee_client(config)
                logger.info("Running TEE inference...")
                tee_result = tee_client.run_epoch(
                    epoch_state=epoch_state,
                    contract_state=contract_state,
                    system_prompt=system_prompt,
                    seed=seed,
                )
                logger.info("TEE inference complete (%.1f min)", tee_result.get("vm_minutes", 0))
                logger.info("Action: %s", tee_result.get("action", {}).get("action", "unknown"))

                # Cache result so we don't re-run the VM on retry
                if not dry_run:
                    result_path = save_tee_result(tee_result, epoch, state_dir)
                    saved["tee_completed"] = True
                    saved["tee_result_path"] = result_path
                    save_state(saved, state_dir)
                    logger.info("TEE result cached to %s", result_path)

            if dry_run:
                logger.info("[DRY RUN] Would submit result")
            else:
                # Extract result fields
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

                verifier_id = config.get("verifier_id", 2)  # 2 = TdxVerifier (dm-verity)
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
                        dry_run=dry_run,
                    )
                    logger.info("Result submitted! tx=%s", receipt['transactionHash'].hex())
                    notify_result_submitted(ntfy, epoch, tee_result.get("action", {}).get("action", "?"))
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

        else:
            logger.info("Lost auction to %s...", winner[:10])
            notify_auction_lost(ntfy, epoch, winner)

    elif phase == SETTLED:
        clear_state(state_dir)
        logger.info("Epoch settled, state cleared")

    else:
        logger.warning("Unknown phase: %s", phase)


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
        notify_error(config.get("ntfy_channel"), "?", e)
        sys.exit(1)
    finally:
        lock_fd.close()


if __name__ == "__main__":
    main()
