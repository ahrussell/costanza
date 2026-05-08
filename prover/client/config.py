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
    python -m prover.client

    # Run with notifications
    python -m prover.client --ntfy-channel humanfund-runner

    # Custom bid margin
    python -m prover.client --bid-margin 2.0
        """,
    )
    parser.add_argument("--ntfy-channel", default=os.environ.get("NTFY_CHANNEL"),
                        help="ntfy.sh channel for notifications (env: NTFY_CHANNEL)")
    parser.add_argument("--tee-client", default=os.environ.get("TEE_CLIENT", "gcp-gpu"),
                        choices=["gcp-gpu", "gcp-cpu", "gcp-persistent"],
                        help="TEE client to use (default: gcp-gpu; use gcp-persistent for testnet)")
    parser.add_argument("--bid-margin", type=float,
                        default=float(os.environ.get("BID_MARGIN", "1.5")),
                        help="Bid multiplier over estimated cost (default: 1.5)")
    parser.add_argument("--state-dir", type=Path,
                        default=Path(os.environ.get("STATE_DIR", os.path.expanduser("~/.humanfund"))),
                        help="Directory for persistent state (default: ~/.humanfund)")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Verbose output")
    parser.add_argument("--no-lock", action="store_true",
                        help="Skip flock (needed for Docker on macOS)")

    parsed = parser.parse_args(args)

    # Load required env vars
    config = {
        "private_key": os.environ.get("PRIVATE_KEY"),
        "rpc_url": os.environ.get("RPC_URL"),
        "contract_address": os.environ.get("CONTRACT_ADDRESS"),
        "gcp_project": os.environ.get("GCP_PROJECT"),
        "gcp_zone": os.environ.get("GCP_ZONE", "us-central1-a"),
        "gcp_image": os.environ.get("GCP_IMAGE"),
        "gcp_machine_type": os.environ.get("GCP_MACHINE_TYPE", "a3-highgpu-1g"),
        "system_prompt_path": os.environ.get("SYSTEM_PROMPT_PATH", "prover/prompts/system.txt"),
        # H100 a3-highgpu-1g cold-start + Hermes-4-70B-Q6_K model load
        # + 3-pass inference + TDX quote runs ~640s on a healthy boot.
        # 600s was clipping legitimate runs by ~40s and forfeiting bonds.
        "enclave_timeout": int(os.environ.get("ENCLAVE_TIMEOUT", "1200")),
        # From CLI
        "ntfy_channel": parsed.ntfy_channel,
        "tee_client": parsed.tee_client,
        "bid_margin": parsed.bid_margin,
        "state_dir": parsed.state_dir,
        "verbose": parsed.verbose,
        "no_lock": parsed.no_lock,
    }

    # Verifier ID: 1 = TdxVerifier, 2 = MockVerifier (testnet)
    config["verifier_id"] = int(os.environ.get("VERIFIER_ID", "1"))

    # Optional: CostanzaTokenAdapter address. When set, the runner
    # opportunistically calls adapter.pokeFees() after commit and
    # after submitAuctionResult to harvest creator fees from the
    # Doppler hook. The 2% keeper tip subsidizes the runner's gas;
    # the rest forwards to the fund. Best-effort — if the call
    # reverts (e.g. no fees pending), the surrounding action still
    # succeeds.
    config["costanza_adapter"] = os.environ.get("COSTANZA_ADAPTER")

    # Source directory (used by gcp-persistent to sync enclave code to VM)
    config["source_dir"] = os.environ.get("SOURCE_DIR", ".")

    # Validate required fields
    missing = []
    if not config["private_key"]:
        missing.append("PRIVATE_KEY")
    if not config["rpc_url"]:
        missing.append("RPC_URL")
    if not config["contract_address"]:
        missing.append("CONTRACT_ADDRESS")
    if missing:
        parser.error(f"Missing required environment variables: {', '.join(missing)}")

    # Validate GCP config when using GCP TEE client
    if config["tee_client"].startswith("gcp"):
        gcp_missing = []
        if not config["gcp_project"]:
            gcp_missing.append("GCP_PROJECT")
        if not config["gcp_image"]:
            gcp_missing.append("GCP_IMAGE")
        if gcp_missing:
            parser.error(f"GCP TEE client requires: {', '.join(gcp_missing)}")

    return config
