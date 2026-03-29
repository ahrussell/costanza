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
from .bid_strategy import estimate_bid, clamp_bid
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
            image=config["gcp_snapshot"],
            machine_type="a3-highgpu-1g",
            inference_timeout=config.get("enclave_timeout", 900),
        )
    elif config["tee_client"] == "gcp-cpu":
        from .tee_clients.gcp import GCPTEEClient
        return GCPTEEClient(
            project=config["gcp_project"],
            zone=config["gcp_zone"],
            image=config.get("gcp_snapshot_cpu", "humanfund-tee-cpu-70b"),
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

            # Read full contract state
            logger.info("Reading contract state...")
            epoch_state = chain.read_contract_state()
            contract_state = chain.build_contract_state_for_tee(epoch_state)

            # Read system prompt (for prompt building inside TEE)
            prompt_path = Path(config["system_prompt_path"])
            system_prompt = prompt_path.read_text().strip()

            # Get randomness seed
            seed = auction["randomness_seed"]
            logger.info("Seed: %d", seed)

            # Run TEE inference
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
                logger.info("Submitting result (verifier=%d, policy_slot=%d)...",
                           verifier_id, policy_slot)

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
