#!/usr/bin/env python3
"""
The Human Fund — Phase 0 Runner

Reads contract state, constructs the prompt, calls the AI model,
parses the output, and submits the action to the contract.

Usage:
    # Run a single epoch
    python agent/runner.py

    # Dry run (don't submit to contract)
    python agent/runner.py --dry-run

    # Use a custom prompt
    python agent/runner.py --prompt agent/prompts/system_v2.txt

Environment variables:
    PRIVATE_KEY       - Runner's private key (hex, with or without 0x prefix)
    RPC_URL           - Base Sepolia RPC URL
    CONTRACT_ADDRESS  - Deployed TheHumanFund contract address
    LLAMA_SERVER_URL  - llama-server URL (default: RunPod proxy)
"""

import json
import os
import re
import sys
import time
import argparse
from pathlib import Path
from urllib.request import urlopen, Request

from web3 import Web3
from eth_account import Account

# ─── Config ──────────────────────────────────────────────────────────────

PROJECT_ROOT = Path(__file__).parent.parent
AGENT_DIR = PROJECT_ROOT / "agent"
DEFAULT_PROMPT = AGENT_DIR / "prompts" / "system_v1.txt"
ABI_PATH = PROJECT_ROOT / "out" / "TheHumanFund.sol" / "TheHumanFund.json"

LLAMA_SERVER_URL = os.environ.get(
    "LLAMA_SERVER_URL",
    "https://xabf55irwjp075-8080.proxy.runpod.net"
)


def _headers():
    return {"User-Agent": "TheHumanFund/1.0", "Content-Type": "application/json"}


# ─── Contract Interface ─────────────────────────────────────────────────

def load_contract(w3, address):
    """Load the contract ABI and return a web3 contract instance."""
    artifact = json.loads(ABI_PATH.read_text())
    abi = artifact["abi"]
    return w3.eth.contract(address=address, abi=abi)


def read_contract_state(contract, w3):
    """Read all relevant state from the contract for prompt construction."""
    state = {}

    # Basic state
    state["epoch"] = contract.functions.currentEpoch().call()
    state["treasury_balance"] = contract.functions.treasuryBalance().call()
    state["commission_rate_bps"] = contract.functions.commissionRateBps().call()
    state["max_bid"] = contract.functions.maxBid().call()
    state["effective_max_bid"] = contract.functions.effectiveMaxBid().call()
    state["deploy_timestamp"] = contract.functions.deployTimestamp().call()
    state["total_inflows"] = contract.functions.totalInflows().call()
    state["total_donated"] = contract.functions.totalDonatedToNonprofits().call()
    state["total_commissions"] = contract.functions.totalCommissionsPaid().call()
    state["total_bounties"] = contract.functions.totalBountiesPaid().call()
    state["last_donation_epoch"] = contract.functions.lastDonationEpoch().call()
    state["last_commission_change_epoch"] = contract.functions.lastCommissionChangeEpoch().call()
    state["consecutive_missed"] = contract.functions.consecutiveMissedEpochs().call()

    # Per-epoch counters
    state["epoch_inflow"] = contract.functions.currentEpochInflow().call()
    state["epoch_donation_count"] = contract.functions.currentEpochDonationCount().call()

    # Nonprofits
    state["nonprofits"] = []
    for i in range(1, 4):
        name, addr, total_donated, donation_count = contract.functions.getNonprofit(i).call()
        state["nonprofits"].append({
            "id": i,
            "name": name,
            "address": addr,
            "total_donated": total_donated,
            "donation_count": donation_count,
        })

    # Decision history (read executed epoch records, most recent first)
    state["history"] = []
    for ep in range(state["epoch"] - 1, max(0, state["epoch"] - 20), -1):
        try:
            ts, action, reasoning, tb, ta, bounty, executed = contract.functions.getEpochRecord(ep).call()
            if executed:
                state["history"].append({
                    "epoch": ep,
                    "action": action,
                    "reasoning": reasoning,
                    "treasury_before": tb,
                    "treasury_after": ta,
                    "bounty_paid": bounty,
                })
        except Exception:
            continue

    # Balance snapshots (every 5 epochs, last 30 epochs)
    state["snapshots"] = []
    epoch = state["epoch"]
    for ep in range(max(1, epoch - 30), epoch, 5):
        snap_ep = ep - (ep % 5) + 5  # Round to nearest 5
        if snap_ep < epoch:
            try:
                balance = contract.functions.balanceSnapshots(snap_ep).call()
                if balance > 0:
                    state["snapshots"].append({"epoch": snap_ep, "balance": balance})
            except Exception:
                continue

    return state


# ─── Prompt Construction ─────────────────────────────────────────────────

def format_eth(wei_amount):
    """Format wei as ETH string with enough precision."""
    eth = wei_amount / 1e18
    if eth == 0:
        return "0.0000"
    if eth < 0.0001:
        return f"{eth:.8f}"
    if eth < 0.01:
        return f"{eth:.6f}"
    return f"{eth:.4f}"


def build_epoch_context(state):
    """Build the epoch context string from contract state."""
    epoch = state["epoch"]
    balance = state["treasury_balance"]
    commission = state["commission_rate_bps"]
    max_bid = state["max_bid"]
    epochs_since_donation = epoch - state["last_donation_epoch"] if state["last_donation_epoch"] > 0 else epoch
    epochs_since_commission = epoch - state["last_commission_change_epoch"] if state["last_commission_change_epoch"] > 0 else epoch

    # Calculate fund age in approximate years
    fund_age_years = epoch / 365.0

    lines = []
    lines.append(f"=== EPOCH {epoch} STATE ===")
    lines.append("")
    lines.append(f"Treasury balance: {format_eth(balance)} ETH")
    lines.append(f"Commission rate: {commission / 100:.0f}%")
    lines.append(f"Max bid ceiling: {format_eth(max_bid)} ETH")
    if state["effective_max_bid"] != state["max_bid"]:
        lines.append(f"Effective bid ceiling (auto-escalated): {format_eth(state['effective_max_bid'])} ETH")
    lines.append(f"Fund age: {epoch} epochs ({fund_age_years:.1f} years)")
    lines.append(f"Epochs since last donation: {epochs_since_donation}")
    lines.append(f"Epochs since last commission change: {epochs_since_commission}")
    lines.append(f"Consecutive missed epochs: {state['consecutive_missed']}")

    # External data (Phase 0: placeholder — oracles not yet integrated)
    lines.append("")
    lines.append("--- External ---")
    lines.append("ETH/USD: (oracle not yet integrated)")
    lines.append("Base avg gas: (not yet tracked)")

    # This epoch activity
    lines.append("")
    lines.append("--- This Epoch Activity ---")
    lines.append(f"Inflows: {format_eth(state['epoch_inflow'])} ETH ({state['epoch_donation_count']} donations)")
    lines.append(f"Outflows: 0.0000 ETH (Phase 0: no bounty)")

    # Referral codes (Phase 0: basic info)
    lines.append("")
    lines.append("--- Referral Codes ---")
    lines.append("(Referral tracking available but limited in Phase 0)")

    # Nonprofit totals
    lines.append("")
    lines.append("--- Nonprofit Totals (lifetime) ---")
    for np in state["nonprofits"]:
        lines.append(
            f"#{np['id']} ({np['name']}, {np['address'][:6]}...{np['address'][-4:]}): "
            f"{format_eth(np['total_donated'])} ETH across {np['donation_count']} donations"
        )

    # Treasury trend
    lines.append("")
    lines.append("--- Treasury Trend (last 30 epochs, every 5) ---")
    if state["snapshots"]:
        for snap in state["snapshots"]:
            lines.append(f"Epoch {snap['epoch']}: {format_eth(snap['balance'])} ETH")
    else:
        lines.append("No history yet.")

    # Decision history
    lines.append("")
    lines.append("=== YOUR DECISION HISTORY (most recent first) ===")
    lines.append("")

    if not state["history"]:
        lines.append("No previous decisions.")
    else:
        # History window sized for context budget
        # With -c 16384 (16K context), system prompt (~500 tok) + epoch context (~400 tok) = ~900
        # Leaves ~15K for history. Each entry is ~300-600 tokens, so ~25-50 entries fit.
        max_history = 20
        history_to_show = state["history"][:max_history]
        if len(state["history"]) > max_history:
            lines.append(f"(Showing last {max_history} of {len(state['history'])} epochs)")
            lines.append("")

        for entry in history_to_show:
            lines.append(f"--- Epoch {entry['epoch']} ---")
            # Decode reasoning
            try:
                reasoning_text = entry["reasoning"].decode("utf-8") if isinstance(entry["reasoning"], bytes) else entry["reasoning"]
                # Truncate very long individual entries to keep total prompt manageable
                if len(reasoning_text) > 1500:
                    reasoning_text = reasoning_text[:1500] + "... [truncated]"
            except Exception:
                reasoning_text = "(could not decode)"
            lines.append(f"[Your reasoning]:")
            lines.append(f"<think>")
            lines.append(reasoning_text)
            lines.append(f"</think>")

            # Decode action
            try:
                action_bytes = entry["action"] if isinstance(entry["action"], bytes) else bytes.fromhex(entry["action"])
                action_type = action_bytes[0]
                action_names = {0: "noop", 1: "donate", 2: "set_commission_rate", 3: "set_max_bid"}
                action_name = action_names.get(action_type, f"unknown({action_type})")
                lines.append(f"[Your action]: {action_name}")
            except Exception:
                lines.append(f"[Your action]: (could not decode)")

            lines.append(f"[Treasury]: {format_eth(entry['treasury_before'])} → {format_eth(entry['treasury_after'])} ETH")
            lines.append("")

    return "\n".join(lines)


# ─── Inference ───────────────────────────────────────────────────────────

def _call_llama(prompt, max_tokens=4096, temperature=0.6, stop=None):
    """Low-level call to the llama-server."""
    body = {
        "prompt": prompt,
        "max_tokens": max_tokens,
        "temperature": temperature,
    }
    if stop:
        body["stop"] = stop

    payload = json.dumps(body).encode()

    req = Request(
        f"{LLAMA_SERVER_URL}/v1/completions",
        data=payload,
        headers=_headers(),
    )

    start = time.time()
    resp = urlopen(req, timeout=300)
    elapsed = time.time() - start

    result = json.loads(resp.read())
    choice = result["choices"][0]

    return {
        "text": choice["text"],
        "finish_reason": choice.get("finish_reason", "unknown"),
        "elapsed_seconds": round(elapsed, 1),
        "tokens": result["usage"],
    }


def run_inference(prompt, max_tokens=4096, temperature=0.6):
    """Two-pass inference: generate reasoning (stop at </think>), then generate action JSON.

    This avoids the issue where the model hits EOS before producing the JSON output.
    """
    # Pass 1: Generate reasoning, stop at </think>
    result1 = _call_llama(prompt, max_tokens=max_tokens, temperature=temperature, stop=["</think>"])

    reasoning = result1["text"].strip()

    # Pass 2: Generate the JSON action with the full context
    # Feed back the full prompt + reasoning + </think> and ask for the JSON
    prompt2 = prompt + reasoning + "\n</think>\n"
    result2 = _call_llama(prompt2, max_tokens=256, temperature=0.3, stop=["\n\n"])

    # Combine into a single response
    combined_text = reasoning + "\n</think>\n" + result2["text"]
    total_elapsed = result1["elapsed_seconds"] + result2["elapsed_seconds"]
    total_tokens = {
        "prompt_tokens": result1["tokens"]["prompt_tokens"] + result2["tokens"]["prompt_tokens"],
        "completion_tokens": result1["tokens"]["completion_tokens"] + result2["tokens"]["completion_tokens"],
        "total_tokens": result1["tokens"]["total_tokens"] + result2["tokens"]["total_tokens"],
    }

    return {
        "text": combined_text,
        "finish_reason": result2["finish_reason"],
        "elapsed_seconds": total_elapsed,
        "tokens": total_tokens,
    }


def _extract_json_object(text):
    """Extract a complete JSON object from text, handling nested braces."""
    start = text.find("{")
    if start == -1:
        return None

    depth = 0
    in_string = False
    escape = False
    for i in range(start, len(text)):
        c = text[i]
        if escape:
            escape = False
            continue
        if c == "\\":
            escape = True
            continue
        if c == '"' and not escape:
            in_string = not in_string
            continue
        if in_string:
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(text[start:i + 1])
                except json.JSONDecodeError:
                    return None
    return None


def parse_model_output(text):
    """Parse the model output into reasoning + action."""
    result = {"think": None, "action": None, "action_json": None, "errors": []}

    # Extract think block (we prime with <think>\n so text starts with reasoning)
    close_idx = text.find("</think>")
    if close_idx >= 0:
        result["think"] = text[:close_idx].strip()
        # Extract JSON from everything after </think>
        after_think = text[close_idx + len("</think>"):].strip()
        obj = _extract_json_object(after_think)
        if obj and "action" in obj:
            result["action_json"] = obj
            result["action"] = obj["action"]
    else:
        think_match = re.search(r"<think>(.*?)</think>", text, re.DOTALL)
        if think_match:
            result["think"] = think_match.group(1).strip()
        else:
            result["errors"].append("No </think> tag found")
            result["think"] = text.strip()

    # Fallback: search the whole text for action JSON
    if not result["action"]:
        # Look for any JSON object containing "action" key
        for match in re.finditer(r'\{', text):
            obj = _extract_json_object(text[match.start():])
            if obj and "action" in obj:
                result["action_json"] = obj
                result["action"] = obj["action"]
                if close_idx < 0:
                    result["errors"].append("JSON found but no </think> tag")
                break

    if not result["action"]:
        result["errors"].append("No action JSON found")

    return result


# ─── Action Encoding ─────────────────────────────────────────────────────

def encode_action(parsed):
    """Encode the parsed action into the contract's expected byte format.

    Format: uint8 action_type + ABI-encoded params
    """
    action = parsed["action"]
    params = parsed["action_json"].get("params", {})

    if action == "noop":
        return bytes([0])

    elif action == "donate":
        nonprofit_id = int(params["nonprofit_id"])
        amount_eth = str(params["amount_eth"])
        # Use Web3.to_wei for precise conversion
        amount_wei = Web3.to_wei(float(amount_eth), 'ether')
        encoded_params = Web3.to_bytes(nonprofit_id).rjust(32, b'\x00') + \
                         Web3.to_bytes(amount_wei).rjust(32, b'\x00')
        return bytes([1]) + encoded_params

    elif action == "set_commission_rate":
        rate_bps = int(params["rate_bps"])
        encoded_params = Web3.to_bytes(rate_bps).rjust(32, b'\x00')
        return bytes([2]) + encoded_params

    elif action == "set_max_bid":
        amount_eth = float(params["amount_eth"])
        amount_wei = int(amount_eth * 1e18)
        encoded_params = Web3.to_bytes(amount_wei).rjust(32, b'\x00')
        return bytes([3]) + encoded_params

    else:
        raise ValueError(f"Unknown action: {action}")


# ─── Main ────────────────────────────────────────────────────────────────

def _validate_and_fix_action(parsed, state):
    """Validate action bounds against current state. Fix or downgrade to noop if invalid."""
    action = parsed["action"]
    params = parsed["action_json"].get("params", {})
    treasury = state["treasury_balance"]

    if action == "donate":
        amount_eth = float(params.get("amount_eth", 0))
        amount_wei = int(amount_eth * 1e18)
        max_donation = (treasury * 1000) // 10000  # 10% of treasury, conservative floor

        if amount_wei > max_donation:
            # Use 9.9% to avoid any rounding issues at the boundary
            safe_amount = (treasury * 990) // 10000
            fixed_eth = safe_amount / 1e18
            print(f"⚠️  Donate {amount_eth} ETH exceeds 10% of treasury ({treasury/1e18:.6f} ETH).")
            print(f"   Clamping to {fixed_eth:.8f} ETH (9.9%)")
            parsed["action_json"]["params"]["amount_eth"] = fixed_eth

        if amount_wei <= 0:
            print(f"⚠️  Donate amount <= 0, downgrading to noop")
            parsed["action"] = "noop"
            parsed["action_json"] = {"action": "noop", "params": {}}

        nonprofit_id = int(params.get("nonprofit_id", 0))
        if nonprofit_id < 1 or nonprofit_id > 3:
            print(f"⚠️  Invalid nonprofit_id {nonprofit_id}, downgrading to noop")
            parsed["action"] = "noop"
            parsed["action_json"] = {"action": "noop", "params": {}}

    elif action == "set_commission_rate":
        rate = int(params.get("rate_bps", 0))
        if rate < 100 or rate > 9000:
            clamped = max(100, min(9000, rate))
            print(f"⚠️  Commission {rate} bps out of bounds, clamping to {clamped}")
            parsed["action_json"]["params"]["rate_bps"] = clamped

    elif action == "set_max_bid":
        amount_eth = float(params.get("amount_eth", 0))
        amount_wei = int(amount_eth * 1e18)
        min_bid = int(0.0001 * 1e18)  # 0.0001 ETH
        max_bid = (treasury * 200) // 10000  # 2% of treasury

        if amount_wei < min_bid:
            print(f"⚠️  Max bid too low, clamping to 0.0001 ETH")
            parsed["action_json"]["params"]["amount_eth"] = 0.0001
        elif amount_wei > max_bid:
            fixed = max_bid / 1e18
            print(f"⚠️  Max bid exceeds 2% of treasury, clamping to {fixed:.6f} ETH")
            parsed["action_json"]["params"]["amount_eth"] = fixed

    return parsed


def run_single_epoch(w3, contract, account, system_prompt, max_tokens, dry_run=False, log_file=None):
    """Execute a single epoch: read state, infer, submit.

    Returns a dict with epoch results, or None on failure.
    """
    if not dry_run:
        # Read contract state
        print("📖 Reading contract state...")
        state = read_contract_state(contract, w3)
        epoch_context = build_epoch_context(state)
        print(f"📊 Epoch {state['epoch']}, Treasury: {format_eth(state['treasury_balance'])} ETH")
    else:
        # Dry run: use a minimal synthetic context
        print("🏃 Dry run mode — using synthetic context")
        scenarios_file = AGENT_DIR / "scenarios" / "scenarios.json"
        if scenarios_file.exists():
            scenarios = json.loads(scenarios_file.read_text())
            epoch_context = scenarios[0]["context"]
            print(f"   Using scenario: {scenarios[0]['name']}")
        else:
            epoch_context = (
                "=== EPOCH 1 STATE ===\n\n"
                "Treasury balance: 5.0000 ETH\n"
                "Commission rate: 10%\n"
                "Max bid ceiling: 0.0050 ETH\n"
                "Fund age: 1 epochs (0.0 years)\n"
                "Epochs since last donation: 0 (never donated)\n"
                "Epochs since last commission change: 0 (initial setting)\n"
                "Consecutive missed epochs: 0\n\n"
                "--- External ---\n"
                "ETH/USD: $3,200.00\n"
                "Base avg gas: 0.01 gwei\n\n"
                "--- This Epoch Activity ---\n"
                "Inflows: 5.0000 ETH (1 donation — initial seed)\n"
                "Outflows: 0.0000 ETH\n\n"
                "--- Nonprofit Totals (lifetime) ---\n"
                "#1 (GiveDirectly): 0.0000 ETH across 0 donations\n"
                "#2 (Against Malaria Foundation): 0.0000 ETH across 0 donations\n"
                "#3 (Helen Keller International): 0.0000 ETH across 0 donations\n\n"
                "=== YOUR DECISION HISTORY (most recent first) ===\n\n"
                "No previous decisions."
            )
        state = {"epoch": 0, "treasury_balance": 0}

    # Construct full prompt and run inference (with retry on parse failure)
    full_prompt = system_prompt + "\n\n" + epoch_context + "\n\n<think>\n"

    max_retries = 3
    parsed = None
    inference = None
    for attempt in range(1, max_retries + 1):
        print(f"\n⏳ Running inference (attempt {attempt}/{max_retries}, {max_tokens} max tokens)...")

        try:
            inference = run_inference(full_prompt, max_tokens=max_tokens)
        except Exception as e:
            print(f"❌ Inference error: {e}")
            if attempt < max_retries:
                print(f"   Retrying...")
                continue
            else:
                return None

        print(f"⏱️  {inference['elapsed_seconds']}s, {inference['tokens']['completion_tokens']} tokens, finish: {inference['finish_reason']}")

        parsed = parse_model_output(inference["text"])

        if parsed["action"]:
            if parsed["errors"]:
                print(f"⚠️  Parse notes: {parsed['errors']}")
            break

        print(f"⚠️  Attempt {attempt} failed to produce valid action")
        if parsed["errors"]:
            print(f"   Errors: {parsed['errors']}")
        if attempt < max_retries:
            print(f"   Retrying...")

    if not parsed or not parsed["action"]:
        print("❌ Could not parse action after all retries")
        if inference:
            print(f"Last raw output:\n{inference['text'][:2000]}")
        return None

    # Display result
    think_preview = (parsed["think"] or "")[:500]
    print(f"\n📝 Reasoning ({len((parsed['think'] or '').split())} words):")
    print(f"   {think_preview}...")
    print(f"\n🎯 Action: {json.dumps(parsed['action_json'], indent=2)}")

    epoch_result = {
        "epoch": state["epoch"],
        "treasury_before": state["treasury_balance"],
        "action": parsed["action"],
        "action_json": parsed["action_json"],
        "reasoning_words": len((parsed["think"] or "").split()),
        "inference_seconds": inference["elapsed_seconds"],
        "completion_tokens": inference["tokens"]["completion_tokens"],
        "reasoning_preview": (parsed["think"] or "")[:300],
    }

    if dry_run:
        print("\n✅ Dry run complete — action not submitted to contract")
        if log_file:
            with open(log_file, "a") as f:
                f.write(json.dumps(epoch_result) + "\n")
        return epoch_result

    # Pre-submission bounds check — fix actions that would revert
    parsed = _validate_and_fix_action(parsed, state)

    # Encode and submit
    action_bytes = encode_action(parsed)
    reasoning_text = (parsed["think"] or "")
    reasoning_bytes = reasoning_text.encode("utf-8")

    # Cap reasoning to stay within gas budget (16 gas per non-zero byte of calldata)
    # At 5M gas limit we can afford ~8KB of reasoning comfortably
    MAX_REASONING_BYTES = 8000
    if len(reasoning_bytes) > MAX_REASONING_BYTES:
        # Truncate at character boundary
        truncated = reasoning_text.encode("utf-8")[:MAX_REASONING_BYTES]
        reasoning_bytes = truncated.decode("utf-8", errors="ignore").encode("utf-8")
        print(f"   Reasoning truncated from {len((parsed['think'] or '').encode('utf-8'))} to {len(reasoning_bytes)} bytes")

    print(f"\n📤 Submitting to contract...")
    print(f"   Action bytes: {action_bytes.hex()}")
    print(f"   Reasoning: {len(reasoning_bytes)} bytes")

    # Build and send transaction
    tx = contract.functions.submitEpochAction(
        action_bytes,
        reasoning_bytes,
    ).build_transaction({
        "from": account.address,
        "nonce": w3.eth.get_transaction_count(account.address),
        "gas": 5_000_000,
        "maxFeePerGas": w3.eth.gas_price * 2,
        "maxPriorityFeePerGas": w3.to_wei(0.001, "gwei"),
    })

    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f"   Tx hash: {tx_hash.hex()}")

    # Wait for receipt
    print("   Waiting for confirmation...")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

    if receipt["status"] == 1:
        new_balance = contract.functions.treasuryBalance().call()
        print(f"   ✅ Epoch {state['epoch']} executed successfully!")
        print(f"   Gas used: {receipt['gasUsed']}")
        print(f"   Block: {receipt['blockNumber']}")
        print(f"   Treasury: {format_eth(state['treasury_balance'])} → {format_eth(new_balance)} ETH")

        epoch_result["treasury_after"] = new_balance
        epoch_result["gas_used"] = receipt["gasUsed"]
        epoch_result["block"] = receipt["blockNumber"]
        epoch_result["tx_hash"] = tx_hash.hex()
        epoch_result["status"] = "success"
    else:
        print(f"   ❌ Transaction reverted!")
        print(f"   Receipt: {receipt}")
        epoch_result["status"] = "reverted"

    if log_file:
        with open(log_file, "a") as f:
            f.write(json.dumps(epoch_result, default=str) + "\n")

    return epoch_result


def print_run_summary(results):
    """Print a summary of all epochs run."""
    print("\n" + "=" * 60)
    print("RUN SUMMARY")
    print("=" * 60)

    if not results:
        print("No epochs completed.")
        return

    # Count actions
    action_counts = {}
    for r in results:
        a = r.get("action", "unknown")
        action_counts[a] = action_counts.get(a, 0) + 1

    total = len(results)
    print(f"\nEpochs run: {total}")
    print(f"Action distribution:")
    for action, count in sorted(action_counts.items()):
        pct = count / total * 100
        bar = "#" * int(pct / 2)
        print(f"  {action:25s} {count:3d} ({pct:5.1f}%) {bar}")

    # Unique actions (diversity)
    unique = len(action_counts)
    print(f"\nAction diversity: {unique}/4 action types used")

    # Check for donate targets
    donate_targets = {}
    for r in results:
        if r.get("action") == "donate":
            np_id = r.get("action_json", {}).get("params", {}).get("nonprofit_id")
            if np_id:
                donate_targets[np_id] = donate_targets.get(np_id, 0) + 1
    if donate_targets:
        print(f"Donation targets: {donate_targets}")

    # Commission rate changes
    comm_changes = [r for r in results if r.get("action") == "set_commission_rate"]
    if comm_changes:
        rates = [r["action_json"]["params"]["rate_bps"] for r in comm_changes]
        print(f"Commission rate changes: {[f'{r/100}%' for r in rates]}")

    # Timing
    times = [r.get("inference_seconds", 0) for r in results if r.get("inference_seconds")]
    if times:
        print(f"\nInference time: avg {sum(times)/len(times):.1f}s, min {min(times):.1f}s, max {max(times):.1f}s")

    # Treasury trajectory
    successes = [r for r in results if r.get("status") == "success"]
    if successes and successes[0].get("treasury_before") and successes[-1].get("treasury_after"):
        start = successes[0]["treasury_before"]
        end = successes[-1]["treasury_after"]
        print(f"Treasury: {start/1e18:.6f} → {end/1e18:.6f} ETH")

    print("=" * 60)


def main():
    parser = argparse.ArgumentParser(description="The Human Fund — Phase 0 Runner")
    parser.add_argument("--dry-run", action="store_true", help="Don't submit to contract")
    parser.add_argument("--prompt", default=str(DEFAULT_PROMPT), help="System prompt file")
    parser.add_argument("--max-tokens", type=int, default=4096)
    parser.add_argument("--epochs", type=int, default=1, help="Number of epochs to run (default: 1)")
    parser.add_argument("--log", default=None, help="JSONL log file for results (default: agent/results/run_<timestamp>.jsonl)")
    args = parser.parse_args()

    # Load config from env
    private_key = os.environ.get("PRIVATE_KEY")
    rpc_url = os.environ.get("RPC_URL")
    contract_address = os.environ.get("CONTRACT_ADDRESS")

    if not args.dry_run:
        if not all([private_key, rpc_url, contract_address]):
            print("Error: Set PRIVATE_KEY, RPC_URL, and CONTRACT_ADDRESS env vars")
            print("       Or use --dry-run to skip contract submission")
            sys.exit(1)

    # Load system prompt
    system_prompt = Path(args.prompt).read_text().strip()
    print(f"📄 System prompt: {Path(args.prompt).name} ({len(system_prompt.split())} words)")

    # Set up log file
    log_file = args.log
    if not log_file:
        results_dir = AGENT_DIR / "results"
        results_dir.mkdir(exist_ok=True)
        log_file = str(results_dir / f"run_{int(time.time())}.jsonl")
    print(f"📋 Logging to: {log_file}")

    # Connect to contract
    w3 = None
    contract = None
    account = None
    if not args.dry_run:
        w3 = Web3(Web3.HTTPProvider(rpc_url))
        if not w3.is_connected():
            print("❌ Cannot connect to RPC")
            sys.exit(1)
        print(f"🔗 Connected to {rpc_url}")

        contract = load_contract(w3, Web3.to_checksum_address(contract_address))
        account = Account.from_key(private_key)
        print(f"👤 Runner: {account.address}")

    # Run epochs
    results = []
    for i in range(args.epochs):
        if args.epochs > 1:
            print(f"\n{'━' * 50}")
            print(f"  EPOCH RUN {i + 1} of {args.epochs}")
            print(f"{'━' * 50}")

        result = run_single_epoch(
            w3, contract, account, system_prompt, args.max_tokens,
            dry_run=args.dry_run, log_file=log_file,
        )

        if result:
            results.append(result)
        else:
            print(f"\n⚠️  Epoch run {i + 1} failed — stopping")
            break

        # Brief pause between epochs to avoid nonce issues
        if i < args.epochs - 1 and not args.dry_run:
            print("\n⏸️  Pausing 5s before next epoch...")
            time.sleep(5)

    # Print summary
    if args.epochs > 1:
        print_run_summary(results)


if __name__ == "__main__":
    main()
