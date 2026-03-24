#!/usr/bin/env python3
"""Configuration for the runner client.

Loads settings from environment variables and CLI arguments.
"""

import argparse
import os
from pathlib import Path


def load_config(args=None):
    """Load configuration from CLI args and environment variables."""
    parser = argparse.ArgumentParser(
        description="The Human Fund — Auction Runner Client",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    # Run once (cron mode)
    python -m runner.client

    # Run with notifications
    python -m runner.client --ntfy-channel humanfund-runner

    # Custom bid margin
    python -m runner.client --bid-margin 2.0
        """,
    )
    parser.add_argument("--ntfy-channel", default=os.environ.get("NTFY_CHANNEL"),
                        help="ntfy.sh channel for notifications (env: NTFY_CHANNEL)")
    parser.add_argument("--tee-client", default=os.environ.get("TEE_CLIENT", "gcp-gpu"),
                        choices=["gcp-gpu", "gcp-cpu"],
                        help="TEE client to use (default: gcp-gpu)")
    parser.add_argument("--bid-margin", type=float,
                        default=float(os.environ.get("BID_MARGIN", "1.5")),
                        help="Bid multiplier over estimated cost (default: 1.5)")
    parser.add_argument("--state-dir", type=Path,
                        default=Path(os.environ.get("STATE_DIR", os.path.expanduser("~/.humanfund"))),
                        help="Directory for persistent state (default: ~/.humanfund)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Don't submit transactions, just log what would happen")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Verbose output")

    parsed = parser.parse_args(args)

    # Load required env vars
    config = {
        "private_key": os.environ.get("PRIVATE_KEY"),
        "rpc_url": os.environ.get("RPC_URL", "https://sepolia.base.org"),
        "contract_address": os.environ.get("CONTRACT_ADDRESS"),
        "gcp_project": os.environ.get("GCP_PROJECT"),
        "gcp_zone": os.environ.get("GCP_ZONE", "us-central1-a"),
        "gcp_snapshot": os.environ.get("GCP_SNAPSHOT", "humanfund-tee-gpu-70b"),
        "gcp_machine_type": os.environ.get("GCP_MACHINE_TYPE", "a3-highgpu-1g"),
        "system_prompt_path": os.environ.get("SYSTEM_PROMPT_PATH", "agent/prompts/system_v6.txt"),
        # From CLI
        "ntfy_channel": parsed.ntfy_channel,
        "tee_client": parsed.tee_client,
        "bid_margin": parsed.bid_margin,
        "state_dir": parsed.state_dir,
        "dry_run": parsed.dry_run,
        "verbose": parsed.verbose,
    }

    # Validate required fields
    missing = []
    if not config["private_key"]:
        missing.append("PRIVATE_KEY")
    if not config["contract_address"]:
        missing.append("CONTRACT_ADDRESS")
    if missing:
        parser.error(f"Missing required environment variables: {', '.join(missing)}")

    return config
