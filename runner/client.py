#!/usr/bin/env python3
"""The Human Fund — Auction Runner Client

Designed to run as a cron job (e.g., every 5 minutes). Checks the current
auction phase and takes the appropriate action:

  IDLE       → startEpoch()
  COMMIT     → calculate bid, commit (if not already committed)
  REVEAL     → reveal bid (if committed but not revealed)
  EXECUTION  → if winner, run TEE inference and submit result
  SETTLED    → clear state, wait for next epoch

Usage:
    # Cron entry (every 5 minutes)
    */5 * * * * cd /path/to/thehumanfund && python -m runner.client

    # Manual run with notifications
    python -m runner.client --ntfy-channel my-channel
"""

import sys
import time
import traceback

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


def get_tee_client(config):
    """Create the appropriate TEE client based on config."""
    if config["tee_client"] == "gcp-gpu":
        from .tee_clients.gcp import GCPTEEClient
        return GCPTEEClient(
            project=config["gcp_project"],
            zone=config["gcp_zone"],
            snapshot=config["gcp_snapshot"],
            machine_type="a3-highgpu-1g",
        )
    elif config["tee_client"] == "gcp-cpu":
        from .tee_clients.gcp import GCPTEEClient
        return GCPTEEClient(
            project=config["gcp_project"],
            zone=config["gcp_zone"],
            snapshot=config.get("gcp_snapshot_cpu", "humanfund-tee-cpu-70b"),
            machine_type="c3-standard-4",
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

    print(f"Epoch {epoch} | Phase: {PHASE_NAMES.get(phase, phase)} | "
          f"Winner: {auction['winner'][:10]}..." if auction['winner'] != '0x' + '0' * 40 else
          f"Epoch {epoch} | Phase: {PHASE_NAMES.get(phase, phase)}")

    # Load saved state
    saved = load_state(state_dir, current_epoch=epoch)

    if phase == IDLE:
        # Try to start epoch
        start_epoch(chain, dry_run=dry_run)
        notify_epoch_started(ntfy, epoch)

    elif phase == COMMIT:
        if not saved.get("committed"):
            # Calculate bid
            gas_price = chain.get_gas_price()
            max_bid = chain.get_effective_max_bid()
            eth_usd_raw = chain.get_eth_usd_price()
            eth_usd = eth_usd_raw / 1e8 if eth_usd_raw > 1e6 else 2000.0

            bid = estimate_bid(
                gas_price, machine_type=config.get("gcp_machine_type", "a3-highgpu-1g"),
                eth_usd_price=eth_usd, margin=config["bid_margin"],
            )
            bid = clamp_bid(bid, max_bid)
            print(f"  Bid estimate: {bid/1e18:.6f} ETH (max: {max_bid/1e18:.6f} ETH)")

            saved = commit_bid(chain, bid, state_dir=state_dir, dry_run=dry_run)
            notify_bid_committed(ntfy, epoch, bid / 1e18)
        else:
            print("  Already committed, waiting for commit window to close")
            # Try closing commit if window has passed
            close_commit(chain, dry_run=dry_run)

    elif phase == REVEAL:
        if saved.get("committed") and not saved.get("revealed"):
            reveal_bid(chain, saved, dry_run=dry_run)
            saved["revealed"] = True
            save_state(saved, state_dir)
            notify_bid_revealed(ntfy, epoch, saved["bid_amount"] / 1e18)
        elif not saved.get("committed"):
            print("  Didn't commit this epoch, skipping reveal")
        else:
            print("  Already revealed, waiting for reveal window to close")
            # Try closing reveal if window has passed
            close_reveal(chain, dry_run=dry_run)

    elif phase == EXECUTION:
        winner = auction["winner"]
        if winner.lower() == chain.account.address.lower():
            bounty_wei = auction["winning_bid"]
            print(f"  WE WON! Starting TEE inference... (bounty: {bounty_wei/1e18:.6f} ETH)")
            notify_auction_won(ntfy, epoch, bounty_wei / 1e18)

            # Read full contract state and run TEE
            # TODO: implement full state reading
            # For now, this is a placeholder showing the flow
            tee_client = get_tee_client(config)
            machine_type = config.get("gcp_machine_type", "a3-highgpu-1g")

            # Read system prompt
            from pathlib import Path
            prompt_path = Path(config["system_prompt_path"])
            system_prompt = prompt_path.read_text().strip()

            # This would normally call chain.read_contract_state()
            # and build epoch context. For now, raise NotImplementedError
            # to show the intended flow.
            print("  NOTE: Full state reading not yet implemented")
            print("  The flow would be:")
            print("    1. chain.read_contract_state()")
            print("    2. Build epoch context")
            print("    3. tee_client.run_epoch(state, context, prompt, seed)")
            print("    4. submit_result()")
            print("    5. Compute profit/loss and notify")

            # After submit_result(), the flow would be:
            # receipt = submit_result(chain, action_bytes, reasoning, proof, ...)
            # eth_usd_raw = chain.get_eth_usd_price()
            # eth_usd = eth_usd_raw / 1e8 if eth_usd_raw > 1e6 else 2000.0
            # cost = estimate_cost(
            #     gas_used=receipt["gasUsed"],
            #     gas_price_wei=receipt["effectiveGasPrice"],
            #     vm_minutes=tee_result["vm_minutes"],
            #     machine_type=machine_type,
            #     eth_usd_price=eth_usd,
            # )
            # notify_result_submitted(ntfy, epoch, action_name,
            #                         bounty_eth=bounty_wei / 1e18, cost=cost)

        else:
            print(f"  Lost auction to {winner[:10]}...")
            notify_auction_lost(ntfy, epoch, winner)

    elif phase == SETTLED:
        clear_state(state_dir)
        print("  Epoch settled, state cleared")

    else:
        print(f"  Unknown phase: {phase}")


def main():
    config = load_config()
    try:
        run(config)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        traceback.print_exc()
        notify_error(config.get("ntfy_channel"), "?", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
