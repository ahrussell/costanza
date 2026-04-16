#!/usr/bin/env python3
"""Testnet CLI — quick commands for testing The Human Fund on Base Sepolia.

Usage:
    python deploy/testnet/cli.py client              # Run prover client once
    python deploy/testnet/cli.py next                # nextPhase() — advance immediately
    python deploy/testnet/cli.py reset 180 180 360   # resetAuction(3m, 3m, 6m)
    python deploy/testnet/cli.py donate 0.01         # Donate 0.01 ETH
    python deploy/testnet/cli.py message 0.002 "Hello!"  # Donate 0.002 ETH with message
    python deploy/testnet/cli.py run-epoch           # Full epoch: reset→commit→reveal→execute
    python deploy/testnet/cli.py status              # Show current epoch/phase/timing

Reads PRIVATE_KEY, RPC_URL, CONTRACT_ADDRESS from env (or .env.testnet-deploy).
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

# ─── Config ──────────────────────────────────────────────────────────────

def load_env():
    """Load from .env.testnet-deploy if present."""
    env_file = Path(__file__).parent.parent.parent / ".env.testnet-deploy"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, val = line.partition("=")
                os.environ.setdefault(key.strip(), val.strip())

    required = ["PRIVATE_KEY", "RPC_URL", "CONTRACT_ADDRESS"]
    missing = [k for k in required if not os.environ.get(k)]
    if missing:
        print(f"Missing env vars: {', '.join(missing)}")
        print("Set them or create .env.testnet-deploy")
        sys.exit(1)

    return {
        "key": os.environ["PRIVATE_KEY"],
        "rpc": os.environ["RPC_URL"],
        "contract": os.environ["CONTRACT_ADDRESS"],
    }


# ─── Helpers ─────────────────────────────────────────────────────────────

def cast_send(cfg, sig, args=None, value=None, gas=2_000_000):
    """Send a transaction via cast."""
    cmd = [
        "cast", "send", cfg["contract"], sig,
        "--private-key", cfg["key"],
        "--rpc-url", cfg["rpc"],
        "--legacy",
        "--gas-limit", str(gas),
    ]
    if args:
        cmd.extend(args)
    if value:
        cmd.extend(["--value", value])

    print(f"  → cast send {sig} {' '.join(args or [])} {f'--value {value}' if value else ''}")
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        print(f"  ✗ FAILED: {result.stderr.strip()[:200]}")
        return None
    # Extract tx hash from output
    for line in result.stdout.splitlines():
        if "transactionHash" in line:
            tx = line.split()[-1]
            print(f"  ✓ tx: {tx}")
            return tx
    print(f"  ✓ sent")
    return result.stdout


def cast_call(cfg, sig, args=None):
    """Read from contract via cast call. Returns the raw hex decoded value."""
    cmd = ["cast", "call", cfg["contract"], sig, "--rpc-url", cfg["rpc"]]
    if args:
        cmd.extend(args)
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    if result.returncode != 0:
        return None
    # cast returns "12345 [1.2345e4]" — grab just the first token
    raw = result.stdout.strip()
    return raw.split()[0] if raw else raw


def cast_decode(raw, types):
    """Decode a raw hex return value."""
    cmd = ["cast", "abi-decode", f"f()({types})", raw]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
    if result.returncode != 0:
        return raw
    return result.stdout.strip()


# ─── Commands ────────────────────────────────────────────────────────────

def cmd_status(cfg):
    """Show current contract state."""
    epoch = cast_call(cfg, "currentEpoch()(uint256)")
    am_addr = cast_call(cfg, "auctionManager()(address)")

    # Read AuctionManager phase
    phase_cmd = ["cast", "call", am_addr, "getPhase(uint256)(uint8)", epoch, "--rpc-url", cfg["rpc"]]
    phase_result = subprocess.run(phase_cmd, capture_output=True, text=True, timeout=15)
    phase = phase_result.stdout.strip().split()[0] if phase_result.returncode == 0 else "?"

    phase_names = {"0": "IDLE", "1": "COMMIT", "2": "REVEAL", "3": "EXECUTION", "4": "SETTLED"}
    phase_name = phase_names.get(phase, phase)

    balance = cast_call(cfg, "treasuryBalance()(uint256)")
    balance_eth = int(balance) / 1e18 if balance else "?"

    bond = cast_call(cfg, "currentBond()(uint256)")
    bond_eth = int(bond) / 1e18 if bond else "?"

    msg_count = cast_call(cfg, "messageCount()(uint256)")
    msg_head = cast_call(cfg, "messageHead()(uint256)")
    unread = int(msg_count) - int(msg_head) if msg_count and msg_head else "?"

    missed = cast_call(cfg, "consecutiveMissedEpochs()(uint256)")

    # Timing
    def am_call(sig):
        r = subprocess.run(
            ["cast", "call", am_addr, sig, "--rpc-url", cfg["rpc"]],
            capture_output=True, text=True, timeout=15
        )
        return r.stdout.strip().split()[0] if r.returncode == 0 and r.stdout.strip() else "0"

    cw = int(am_call("commitWindow()(uint256)"))
    rw = int(am_call("revealWindow()(uint256)"))
    ew = int(am_call("executionWindow()(uint256)"))

    print(f"\n  Contract:  {cfg['contract']}")
    print(f"  Epoch:     {epoch}")
    print(f"  Phase:     {phase_name} ({phase})")
    print(f"  Treasury:  {balance_eth} ETH")
    print(f"  Bond:      {bond_eth} ETH")
    print(f"  Messages:  {unread} unread ({msg_head}/{msg_count})")
    print(f"  Missed:    {missed} consecutive")
    print(f"  Timing:    {cw}s commit / {rw}s reveal / {ew}s exec = {cw+rw+ew}s epoch")
    print()


def cmd_next(cfg):
    """Call nextPhase() to advance immediately."""
    print("Calling nextPhase()...")
    cast_send(cfg, "nextPhase()")
    cmd_status(cfg)


def cmd_reset(cfg, commit_s, reveal_s, exec_s):
    """Call resetAuction() with new timing in seconds."""
    print(f"Calling resetAuction({commit_s}, {reveal_s}, {exec_s})...")
    cast_send(cfg, "resetAuction(uint256,uint256,uint256)", [commit_s, reveal_s, exec_s])
    cmd_status(cfg)


def cmd_donate(cfg, amount_eth):
    """Donate ETH to the fund."""
    print(f"Donating {amount_eth} ETH...")
    cast_send(cfg, "donate(uint256)", ["0"], value=f"{amount_eth}ether")


def cmd_message(cfg, amount_eth, message):
    """Donate ETH with a message."""
    print(f"Sending message with {amount_eth} ETH: \"{message}\"")
    cast_send(cfg, "donateWithMessage(uint256,string)", ["0", message], value=f"{amount_eth}ether")


def _get_current_timing(cfg):
    """Read current commit/reveal/exec windows from AuctionManager."""
    am_addr = cast_call(cfg, "auctionManager()(address)")
    def am_call(sig):
        r = subprocess.run(
            ["cast", "call", am_addr, sig, "--rpc-url", cfg["rpc"]],
            capture_output=True, text=True, timeout=15
        )
        return r.stdout.strip().split()[0] if r.returncode == 0 and r.stdout.strip() else "0"
    return am_call("commitWindow()(uint256)"), am_call("revealWindow()(uint256)"), am_call("executionWindow()(uint256)")


def cmd_run_epoch(cfg):
    """Run a full epoch: reset → open → commit → reveal → execute."""
    print("═══ Running full epoch ═══\n")

    # 1. Reset auction (keep current timing) + open auction
    cw, rw, ew = _get_current_timing(cfg)
    print(f"Step 1/7: resetAuction({cw}, {rw}, {ew}) — wipe slate, keep timing")
    cast_send(cfg, "resetAuction(uint256,uint256,uint256)", [cw, rw, ew])
    time.sleep(3)

    print("Step 2/7: syncPhase() → open auction (COMMIT)")
    cast_send(cfg, "syncPhase()")
    time.sleep(3)
    cmd_status(cfg)

    # 3. Run client → should commit
    print("Step 3/7: prover client (commit)")
    cmd_client(cfg)
    time.sleep(3)

    # 4. nextPhase → advance to REVEAL
    print("\nStep 4/7: nextPhase() → REVEAL")
    cast_send(cfg, "nextPhase()")
    time.sleep(3)

    # 5. Run client → should reveal
    print("Step 5/7: prover client (reveal)")
    cmd_client(cfg)
    time.sleep(3)

    # 6. nextPhase → advance to EXECUTION
    print("\nStep 6/7: nextPhase() → EXECUTION")
    cast_send(cfg, "nextPhase()")
    time.sleep(3)

    # 7. Run client → should execute (TEE inference)
    print("Step 7/7: prover client (execute — TEE inference)")
    cmd_client(cfg)
    time.sleep(3)

    print("\n═══ Epoch complete ═══")
    cmd_status(cfg)


def cmd_client(cfg):
    """Run the prover client once (via Docker or directly)."""
    env_file = Path(__file__).parent.parent.parent / ".env.testnet-deploy"
    docker_cmd = [
        "docker", "run", "--rm",
        "--env-file", str(env_file),
        "-v", os.path.expanduser("~/.config/gcloud") + ":/root/.config/gcloud",
        "-v", os.path.expanduser("~/.humanfund") + ":/root/.humanfund",
    ]
    # Pass through capture state dir if set
    capture_dir = os.environ.get("CAPTURE_STATE_DIR")
    if capture_dir:
        docker_cmd.extend(["-v", f"{capture_dir}:/capture", "-e", "CAPTURE_STATE_DIR=/capture"])
    docker_cmd.extend(["humanfund-prover", "--verbose", "--no-lock"])
    if capture_dir:
        docker_cmd.extend(["--capture-state", "/capture"])
    print("Running prover client (Docker)...")
    print(f"  {' '.join(docker_cmd[:6])} ...")
    try:
        subprocess.run(docker_cmd, timeout=1800)
    except subprocess.TimeoutExpired:
        print("  ✗ Timed out after 30 minutes")
    except FileNotFoundError:
        print("  Docker not found. Trying direct Python...")
        # Fallback: run directly
        subprocess.run(
            [sys.executable, "-m", "prover.client", "--verbose"],
            env={**os.environ, **{
                "PRIVATE_KEY": cfg["key"],
                "RPC_URL": cfg["rpc"],
                "CONTRACT_ADDRESS": cfg["contract"],
            }},
            timeout=900,
        )


# ─── Main ────────────────────────────────────────────────────────────────

def main():
    load_env()
    cfg = load_env.__wrapped__ if hasattr(load_env, '__wrapped__') else None
    cfg = {
        "key": os.environ["PRIVATE_KEY"],
        "rpc": os.environ["RPC_URL"],
        "contract": os.environ["CONTRACT_ADDRESS"],
    }

    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(0)

    cmd = sys.argv[1].lower()

    if cmd in ("status", "s"):
        cmd_status(cfg)
    elif cmd in ("next", "n"):
        cmd_next(cfg)
    elif cmd in ("reset", "r"):
        if len(sys.argv) != 5:
            print("Usage: cli.py reset <commit_s> <reveal_s> <exec_s>")
            print("  e.g. cli.py reset 180 180 360   (3m/3m/6m)")
            sys.exit(1)
        cmd_reset(cfg, sys.argv[2], sys.argv[3], sys.argv[4])
    elif cmd in ("donate", "d"):
        if len(sys.argv) != 3:
            print("Usage: cli.py donate <amount_eth>")
            sys.exit(1)
        cmd_donate(cfg, sys.argv[2])
    elif cmd in ("message", "msg", "m"):
        if len(sys.argv) < 4:
            print("Usage: cli.py message <amount_eth> <message>")
            sys.exit(1)
        cmd_message(cfg, sys.argv[2], " ".join(sys.argv[3:]))
    elif cmd in ("client", "c"):
        cmd_client(cfg)
    elif cmd in ("run-epoch", "run", "epoch", "e"):
        cmd_run_epoch(cfg)
    else:
        print(f"Unknown command: {cmd}")
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
