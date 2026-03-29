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
    */5 * * * * cd /path/to/thehumanfund && python -m runner.client

    # Manual run with notifications
    python -m runner.client --ntfy-channel my-channel
"""

import fcntl
import logging
import sys
import traceback
from pathlib import Path

from .config import load_config
from .chain import ChainClient
from .auction import (
    start_epoch, commit_bid, close_commit, reveal_bid, close_reveal,
    submit_result, IDLE, COMMIT, REVEAL, EXECUTION, SETTLED, PHASE_NAMES,
)
from .bid_strategy import estimate_bid, estimate_cost, clamp_bid
from .state import load as load_state, save as save_state, clear as clear_state
from .notifier import (
    notify_epoch_started, notify_bid_committed, notify_bid_revealed,
    notify_auction_won, notify_auction_lost, notify_result_submitted,
    notify_error,
)

logger = logging.getLogger(__name__)


def get_tee_client(config):
    """Create the appropriate TEE client based on config."""
    if config["tee_client"] == "gcp-gpu":
        from .tee_clients.gcp import GCPTEEClient
        return GCPTEEClient(
            project=config["gcp_project"],
            zone=config["gcp_zone"],
            snapshot=config["gcp_snapshot"],
            machine_type="a3-highgpu-1g",
            enclave_timeout=config.get("enclave_timeout", 600),
        )
    elif config["tee_client"] == "gcp-cpu":
        from .tee_clients.gcp import GCPTEEClient
        return GCPTEEClient(
            project=config["gcp_project"],
            zone=config["gcp_zone"],
            snapshot=config.get("gcp_snapshot_cpu", "humanfund-tee-cpu-70b"),
            machine_type="c3-standard-4",
            enclave_timeout=config.get("enclave_timeout", 600),
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
        start_epoch(chain, dry_run=dry_run)
        notify_epoch_started(ntfy, epoch)

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
            reveal_bid(chain, saved, dry_run=dry_run)
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
            bounty_wei = auction["winning_bid"]
            logger.info("WE WON! Starting TEE inference... (bounty: %.6f ETH)", bounty_wei / 1e18)
            notify_auction_won(ntfy, epoch, bounty_wei / 1e18)

            tee_client = get_tee_client(config)

            prompt_path = Path(config["system_prompt_path"])
            system_prompt = prompt_path.read_text().strip()

            verifier_id = config.get("verifier_id", 1)
            logger.info("Full state reading not yet implemented — flow placeholder:")
            logger.info("  1. chain.read_contract_state()")
            logger.info("  2. Build epoch context")
            logger.info("  3. tee_client.run_epoch(state, context, prompt, seed)")
            logger.info("  4. submit_result(verifier_id=%d)", verifier_id)

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
