#!/usr/bin/env python3
"""
The Human Fund — Local Simulation Mode

Generates synthetic contract state and runs model inference locally,
without needing the real blockchain or GCP VM. Useful for testing
prompt changes, model behavior, and action parsing.

Usage:
    # Run 5 simulated epochs with default settings
    python scripts/simulate.py

    # Custom treasury and server URL
    python scripts/simulate.py --treasury 1.0 --server-url http://localhost:8080 --epochs 10

    # Verbose mode (print full reasoning)
    python scripts/simulate.py --verbose
"""

import argparse
import json
import os
import random
import sys
import time
from pathlib import Path
from urllib.request import urlopen, Request

# ─── Path setup ──────────────────────────────────────────────────────────

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "agent"))
sys.path.insert(0, str(PROJECT_ROOT / "tee"))

from runner import build_epoch_context, format_eth
from enclave_runner import encode_action_bytes, _extract_json_object, parse_action

# ─── Constants ───────────────────────────────────────────────────────────

NONPROFITS = [
    {
        "id": 1,
        "name": "GiveDirectly",
        "address": "0x750EF1D7a0b4Ab1c97B7A623D7917CcEb5ea779C",
        "total_donated": 0,
        "donation_count": 0,
    },
    {
        "id": 2,
        "name": "Clean Air Task Force",
        "address": "0x4B5BaD436CcA8df08a7e20209fee1F85b8d2d30e",
        "total_donated": 0,
        "donation_count": 0,
    },
    {
        "id": 3,
        "name": "Helen Keller International",
        "address": "0x9BEF6AB6EB7a2c1ecFC3543fAb2cD47D60F1F7E2",
        "total_donated": 0,
        "donation_count": 0,
    },
]

PROTOCOLS = [
    {"id": 1, "name": "Aave V3 WETH",    "risk_tier": 1, "expected_apy_bps": 200,  "active": True},
    {"id": 2, "name": "Lido wstETH",     "risk_tier": 1, "expected_apy_bps": 350,  "active": True},
    {"id": 3, "name": "Coinbase cbETH",  "risk_tier": 1, "expected_apy_bps": 310,  "active": True},
    {"id": 4, "name": "Rocket Pool rETH","risk_tier": 1, "expected_apy_bps": 300,  "active": True},
    {"id": 5, "name": "Aave V3 USDC",    "risk_tier": 2, "expected_apy_bps": 450,  "active": True},
    {"id": 6, "name": "Compound V3 USDC", "risk_tier": 2, "expected_apy_bps": 400, "active": True},
    {"id": 7, "name": "Moonwell USDC",   "risk_tier": 2, "expected_apy_bps": 500,  "active": True},
    {"id": 8, "name": "Aerodrome ETH/USDC","risk_tier": 4,"expected_apy_bps": 1200,"active": True},
]

# ─── Synthetic State Generation ─────────────────────────────────────────

def _wei(eth):
    """Convert ETH float to wei int."""
    return int(eth * 1e18)


def generate_initial_state(treasury_eth, start_epoch=10):
    """Generate realistic synthetic contract state."""
    balance = _wei(treasury_eth)

    # Some prior donation history
    donated_total = _wei(treasury_eth * 0.05)  # ~5% already donated
    donated_per_np = donated_total // 3

    nonprofits = []
    for np in NONPROFITS:
        nonprofits.append({
            **np,
            "total_donated": donated_per_np,
            "donation_count": random.randint(1, 3),
        })

    # Investment positions: small positions in a couple protocols
    investments = []
    total_invested = 0
    for proto in PROTOCOLS:
        if proto["id"] in (2, 5):  # wstETH and Aave USDC
            deposited = _wei(treasury_eth * 0.05)
            # Simulate small gain
            value = deposited + _wei(treasury_eth * 0.001)
            investments.append({
                **proto,
                "deposited": deposited,
                "shares": deposited,
                "current_value": value,
            })
            total_invested += value
        else:
            investments.append({
                **proto,
                "deposited": 0,
                "shares": 0,
                "current_value": 0,
            })

    # Generate diverse history
    history = _generate_history(start_epoch, balance, treasury_eth)

    # Guiding policies: a few set, some empty
    guiding_policies = [""] * 10
    guiding_policies[0] = "Prioritize donations to the most cost-effective charities."
    guiding_policies[1] = "Maintain a conservative investment strategy, favoring low-risk protocols."
    guiding_policies[3] = "Keep at least 30% of treasury liquid for donation flexibility."

    # Donor messages
    donor_messages = _generate_donor_messages(start_epoch)

    return {
        "epoch": start_epoch,
        "treasury_balance": balance,
        "commission_rate_bps": 1000,
        "max_bid": _wei(0.001),
        "effective_max_bid": _wei(0.001),
        "deploy_timestamp": int(time.time()) - (start_epoch * 86400),
        "total_inflows": _wei(treasury_eth * 1.2),
        "total_donated": donated_total,
        "total_commissions": _wei(treasury_eth * 0.02),
        "total_bounties": _wei(treasury_eth * 0.03),
        "last_donation_epoch": max(1, start_epoch - 3),
        "last_commission_change_epoch": max(1, start_epoch - 7),
        "consecutive_missed": 0,
        "epoch_inflow": _wei(0.01),
        "epoch_donation_count": 1,
        "nonprofits": nonprofits,
        "history": history,
        "snapshots": [],
        "investments": investments,
        "total_invested": total_invested,
        "total_assets": balance + total_invested,
        "guiding_policies": guiding_policies,
        "donor_messages": donor_messages,
        "message_count": len(donor_messages),
        "message_head": 0,
    }


def _generate_history(current_epoch, balance, treasury_eth):
    """Generate diverse action history entries."""
    history = []
    action_templates = [
        {
            "action": bytes([1]) + (1).to_bytes(32, "big") + _wei(treasury_eth * 0.03).to_bytes(32, "big"),
            "reasoning": "The treasury is healthy and GiveDirectly consistently delivers high-impact results. "
                         "Allocating 3% of treasury this epoch to support direct cash transfers.",
        },
        {
            "action": bytes([0]),
            "reasoning": "Market conditions are uncertain and recent inflows have slowed. "
                         "Preserving capital this epoch to maintain runway.",
        },
        {
            "action": bytes([4]) + (2).to_bytes(32, "big") + _wei(treasury_eth * 0.04).to_bytes(32, "big"),
            "reasoning": "Lido wstETH offers reliable yield with low risk. Deploying a small portion "
                         "to begin earning staking rewards while maintaining ample reserves.",
        },
        {
            "action": bytes([2]) + (1200).to_bytes(32, "big"),
            "reasoning": "Increasing commission slightly from 10% to 12% to improve referral incentives. "
                         "This should help attract more donors to grow the treasury.",
        },
        {
            "action": bytes([6]) + (2).to_bytes(32, "big") + (64).to_bytes(32, "big")
                     + (44).to_bytes(32, "big") + b"Diversify investments across risk tiers.".ljust(64, b'\x00'),
            "reasoning": "Establishing a guiding policy on investment diversification to ensure "
                         "future decisions maintain a balanced portfolio.",
        },
        {
            "action": bytes([1]) + (2).to_bytes(32, "big") + _wei(treasury_eth * 0.02).to_bytes(32, "big"),
            "reasoning": "Clean Air Task Force has shown strong results in climate advocacy. "
                         "Allocating 2% to support their policy work.",
        },
    ]

    for i, ep in enumerate(range(current_epoch - 1, max(0, current_epoch - 7), -1)):
        template = action_templates[i % len(action_templates)]
        tb = balance + _wei(0.01 * (current_epoch - ep))
        ta = tb - _wei(0.001)  # bounty cost
        history.append({
            "epoch": ep,
            "action": template["action"],
            "reasoning": template["reasoning"],
            "treasury_before": tb,
            "treasury_after": ta,
            "bounty_paid": _wei(0.001),
        })

    return history


def _generate_donor_messages(current_epoch):
    """Generate synthetic donor messages."""
    messages = [
        {
            "sender": "0x1234567890abcdef1234567890abcdef12345678",
            "amount": _wei(0.05),
            "text": "Love the transparency of publishing reasoning on-chain. Keep up the great work!",
            "epoch": current_epoch - 1,
        },
        {
            "sender": "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd",
            "amount": _wei(0.02),
            "text": "Please consider donating more to Helen Keller International.",
            "epoch": current_epoch,
        },
    ]
    return messages


# ─── Inference ───────────────────────────────────────────────────────────

def call_llama(server_url, prompt, max_tokens=4096, temperature=0.6, stop=None):
    """Call a local llama-server."""
    body = {
        "prompt": prompt,
        "max_tokens": max_tokens,
        "temperature": temperature,
    }
    if stop:
        body["stop"] = stop

    payload = json.dumps(body).encode()
    req = Request(
        f"{server_url}/v1/completions",
        data=payload,
        headers={"Content-Type": "application/json", "User-Agent": "TheHumanFund/1.0"},
    )

    start = time.time()
    resp = urlopen(req, timeout=1800)
    elapsed = time.time() - start

    result = json.loads(resp.read())
    choice = result["choices"][0]

    return {
        "text": choice["text"],
        "finish_reason": choice.get("finish_reason", "unknown"),
        "elapsed_seconds": round(elapsed, 1),
        "tokens": result.get("usage", {}),
    }


def two_pass_inference(server_url, full_prompt, verbose=False):
    """Two-pass inference: reasoning then JSON action."""
    print("  Pass 1: generating reasoning...")
    result1 = call_llama(server_url, full_prompt, max_tokens=4096, temperature=0.6, stop=["</think>"])
    reasoning = result1["text"].strip()

    if verbose:
        print(f"  Reasoning ({len(reasoning)} chars, {result1['elapsed_seconds']}s)")

    print("  Pass 2: generating action JSON...")
    prompt2 = full_prompt + reasoning + "\n</think>\n"
    result2 = call_llama(server_url, prompt2, max_tokens=256, temperature=0.3, stop=["\n\n"])

    combined = reasoning + "\n</think>\n" + result2["text"]
    total_elapsed = result1["elapsed_seconds"] + result2["elapsed_seconds"]

    return {
        "text": combined,
        "reasoning": reasoning,
        "action_text": result2["text"].strip(),
        "elapsed_seconds": total_elapsed,
    }


# ─── State Update ────────────────────────────────────────────────────────

def apply_action(state, action_json):
    """Update simulated state based on the action taken. Returns a description of changes."""
    action = action_json["action"]
    params = action_json.get("params", {})
    changes = []

    if action == "noop":
        changes.append("No state change (noop)")

    elif action == "donate":
        np_id = int(params.get("nonprofit_id", params.get("id", 1)))
        amount_str = str(params.get("amount_eth", params.get("amount", "0")))
        # Strip ETH suffix
        for suffix in [" ETH", " eth", "ETH", "eth"]:
            amount_str = amount_str.replace(suffix, "")
        amount_wei = _wei(float(amount_str))

        # Clamp to 10% of treasury
        max_donate = state["treasury_balance"] // 10
        if amount_wei > max_donate:
            changes.append(f"  Clamped donation from {format_eth(amount_wei)} to {format_eth(max_donate)} ETH (10% cap)")
            amount_wei = max_donate

        state["treasury_balance"] -= amount_wei
        state["total_donated"] += amount_wei
        state["total_assets"] = state["treasury_balance"] + state["total_invested"]
        state["last_donation_epoch"] = state["epoch"]

        # Update nonprofit
        for np in state["nonprofits"]:
            if np["id"] == np_id:
                np["total_donated"] += amount_wei
                np["donation_count"] += 1
                changes.append(f"  Donated {format_eth(amount_wei)} ETH to {np['name']}")
                break

    elif action == "set_commission_rate":
        rate = int(float(str(params.get("rate_bps", params.get("rate", 1000)))))
        rate = max(100, min(9000, rate))
        old_rate = state["commission_rate_bps"]
        state["commission_rate_bps"] = rate
        state["last_commission_change_epoch"] = state["epoch"]
        changes.append(f"  Commission: {old_rate/100:.1f}% -> {rate/100:.1f}%")

    elif action == "set_max_bid":
        amount_str = str(params.get("amount_eth", params.get("amount", "0.001")))
        for suffix in [" ETH", " eth", "ETH", "eth"]:
            amount_str = amount_str.replace(suffix, "")
        amount_wei = _wei(float(amount_str))
        old_bid = state["max_bid"]
        state["max_bid"] = amount_wei
        state["effective_max_bid"] = amount_wei
        changes.append(f"  Max bid: {format_eth(old_bid)} -> {format_eth(amount_wei)} ETH")

    elif action == "invest":
        from enclave_runner import _parse_protocol_id
        pid = _parse_protocol_id(params)
        amount_str = str(params.get("amount_eth", params.get("amount", "0.1")))
        for suffix in [" ETH", " eth", "ETH", "eth"]:
            amount_str = amount_str.replace(suffix, "")
        amount_wei = _wei(float(amount_str))

        # Clamp to available
        max_investable = max(0, state["treasury_balance"] - (state["total_assets"] * 2000 // 10000))
        if amount_wei > max_investable:
            amount_wei = max_investable

        state["treasury_balance"] -= amount_wei
        state["total_invested"] += amount_wei
        state["total_assets"] = state["treasury_balance"] + state["total_invested"]

        for inv in state["investments"]:
            if inv["id"] == pid:
                inv["deposited"] += amount_wei
                inv["shares"] += amount_wei
                inv["current_value"] += amount_wei
                changes.append(f"  Invested {format_eth(amount_wei)} ETH in {inv['name']}")
                break

    elif action == "withdraw":
        from enclave_runner import _parse_protocol_id
        pid = _parse_protocol_id(params)
        amount_str = str(params.get("amount_eth", params.get("amount", "0.1")))
        for suffix in [" ETH", " eth", "ETH", "eth"]:
            amount_str = amount_str.replace(suffix, "")
        amount_wei = _wei(float(amount_str))

        for inv in state["investments"]:
            if inv["id"] == pid:
                withdraw = min(amount_wei, inv["current_value"])
                inv["current_value"] -= withdraw
                inv["deposited"] = max(0, inv["deposited"] - withdraw)
                inv["shares"] = max(0, inv["shares"] - withdraw)
                state["treasury_balance"] += withdraw
                state["total_invested"] -= withdraw
                state["total_assets"] = state["treasury_balance"] + state["total_invested"]
                changes.append(f"  Withdrew {format_eth(withdraw)} ETH from {inv['name']}")
                break

    elif action in ("set_guiding_policy", "set_policy"):
        slot = int(params.get("slot", params.get("slot_id", 0)))
        policy = str(params.get("policy", params.get("text", "")))[:280]
        old = state["guiding_policies"][slot] if slot < 10 else ""
        if slot < 10:
            state["guiding_policies"][slot] = policy
        snippet = policy[:60] + "..." if len(policy) > 60 else policy
        changes.append(f'  Policy slot [{slot}]: "{snippet}"')

    if not changes:
        changes.append(f"  Action: {action} (unhandled in simulation)")

    return changes


def advance_epoch(state):
    """Advance state to the next epoch with minor simulated inflows."""
    state["epoch"] += 1
    # Simulate small random inflow
    inflow = _wei(random.uniform(0.005, 0.03))
    state["treasury_balance"] += inflow
    state["total_assets"] = state["treasury_balance"] + state["total_invested"]
    state["epoch_inflow"] = inflow
    state["epoch_donation_count"] = random.randint(0, 3)
    state["total_inflows"] += inflow
    # Clear donor messages (they were "read")
    state["donor_messages"] = []
    state["message_head"] = state["message_count"]


def add_history_entry(state, action_json, reasoning, action_bytes):
    """Add an epoch result to the decision history."""
    tb = state["treasury_balance"]
    entry = {
        "epoch": state["epoch"],
        "action": action_bytes,
        "reasoning": reasoning,
        "treasury_before": tb,
        "treasury_after": state["treasury_balance"],  # after apply_action
        "bounty_paid": _wei(0.001),
    }
    state["history"].insert(0, entry)
    # Keep last 20
    state["history"] = state["history"][:20]


# ─── Main ────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Simulate The Human Fund agent locally without blockchain or GCP VM."
    )
    parser.add_argument("--epochs", type=int, default=5, help="Number of simulated epochs (default: 5)")
    parser.add_argument("--server-url", type=str, default="http://localhost:8080",
                        help="llama-server URL (default: http://localhost:8080)")
    parser.add_argument("--treasury", type=float, default=0.5,
                        help="Initial treasury balance in ETH (default: 0.5)")
    parser.add_argument("--verbose", action="store_true",
                        help="Print full reasoning output")
    args = parser.parse_args()

    # Load system prompt + protocols reference
    system_prompt_path = PROJECT_ROOT / "agent" / "prompts" / "system_v4.txt"
    protocols_ref_path = PROJECT_ROOT / "agent" / "prompts" / "protocols_reference.txt"

    if not system_prompt_path.exists():
        print(f"ERROR: System prompt not found at {system_prompt_path}")
        sys.exit(1)

    system_prompt = system_prompt_path.read_text().strip()
    if protocols_ref_path.exists():
        protocols_ref = protocols_ref_path.read_text().strip()
        system_prompt = system_prompt + "\n\n" + protocols_ref

    # Check llama-server health
    print(f"Checking llama-server at {args.server_url}...")
    try:
        resp = urlopen(f"{args.server_url}/health", timeout=5)
        health = json.loads(resp.read())
        print(f"  Server status: {health.get('status', 'unknown')}")
    except Exception as e:
        print(f"ERROR: Cannot reach llama-server at {args.server_url}: {e}")
        print("Start a llama-server first, e.g.:")
        print("  llama-server -m models/YOUR_MODEL.gguf -c 4096 --port 8080")
        sys.exit(1)

    # Generate initial state
    state = generate_initial_state(args.treasury, start_epoch=10)

    print()
    print("=" * 70)
    print(f"  THE HUMAN FUND — LOCAL SIMULATION")
    print(f"  Epochs: {args.epochs} | Treasury: {format_eth(state['treasury_balance'])} ETH")
    print(f"  Server: {args.server_url}")
    print("=" * 70)

    for epoch_num in range(args.epochs):
        print()
        print(f"{'=' * 70}")
        print(f"  EPOCH {state['epoch']} (simulation step {epoch_num + 1}/{args.epochs})")
        print(f"  Treasury: {format_eth(state['treasury_balance'])} ETH | "
              f"Invested: {format_eth(state['total_invested'])} ETH | "
              f"Total: {format_eth(state['total_assets'])} ETH")
        print(f"{'=' * 70}")

        # Build epoch context using the real runner function
        epoch_context = build_epoch_context(state)

        # Construct full prompt
        full_prompt = system_prompt + "\n\n" + epoch_context + "\n\n<think>\n"

        if args.verbose:
            print(f"\n--- Epoch context ({len(epoch_context)} chars) ---")
            print(epoch_context[:500] + "..." if len(epoch_context) > 500 else epoch_context)
            print("---")

        # Run two-pass inference
        print()
        try:
            inference = two_pass_inference(args.server_url, full_prompt, verbose=args.verbose)
        except Exception as e:
            print(f"  ERROR: Inference failed: {e}")
            advance_epoch(state)
            continue

        print(f"  Inference completed in {inference['elapsed_seconds']}s")

        # Parse action
        action_json = parse_action(inference["text"])

        if not action_json:
            print("  ERROR: Could not parse action from model output")
            if args.verbose:
                print(f"  Raw action text: {inference['action_text'][:500]}")
            advance_epoch(state)
            continue

        print(f"\n  Action: {json.dumps(action_json, indent=2)}")

        # Validate encoding
        try:
            action_bytes = encode_action_bytes(action_json)
            print(f"  Encoded: {action_bytes.hex()[:40]}... ({len(action_bytes)} bytes)")
        except Exception as e:
            print(f"  WARNING: encode_action_bytes failed: {e}")
            action_bytes = bytes([0])

        # Print reasoning
        reasoning = inference["reasoning"]
        if args.verbose:
            print(f"\n  --- Reasoning ({len(reasoning)} chars) ---")
            print(f"  {reasoning}")
            print("  ---")
        else:
            # Print truncated reasoning
            lines = reasoning.strip().split("\n")
            preview = "\n  ".join(lines[:5])
            if len(lines) > 5:
                preview += f"\n  ... ({len(lines) - 5} more lines)"
            print(f"\n  Reasoning (preview):\n  {preview}")

        # Record treasury before changes
        treasury_before = state["treasury_balance"]

        # Apply action to state
        changes = apply_action(state, action_json)
        print(f"\n  State changes:")
        for c in changes:
            print(f"  {c}")

        # Add to history
        add_history_entry(state, action_json, reasoning, action_bytes)

        # Advance epoch
        advance_epoch(state)

        print(f"\n  Treasury after: {format_eth(state['treasury_balance'])} ETH "
              f"(was {format_eth(treasury_before)} ETH)")

    # Final summary
    print()
    print("=" * 70)
    print("  SIMULATION COMPLETE")
    print("=" * 70)
    print(f"  Final epoch: {state['epoch']}")
    print(f"  Final treasury: {format_eth(state['treasury_balance'])} ETH")
    print(f"  Total invested: {format_eth(state['total_invested'])} ETH")
    print(f"  Total assets: {format_eth(state['total_assets'])} ETH")
    print(f"  Total donated (lifetime): {format_eth(state['total_donated'])} ETH")
    print(f"  Commission rate: {state['commission_rate_bps']/100:.1f}%")
    print()
    print("  Nonprofit totals:")
    for np in state["nonprofits"]:
        print(f"    #{np['id']} {np['name']}: {format_eth(np['total_donated'])} ETH ({np['donation_count']} donations)")
    print()
    active_policies = [(i, p) for i, p in enumerate(state["guiding_policies"]) if p]
    if active_policies:
        print("  Active guiding policies:")
        for i, p in active_policies:
            print(f"    [{i}] {p}")
    print()


if __name__ == "__main__":
    main()
