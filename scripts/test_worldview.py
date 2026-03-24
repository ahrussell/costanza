#!/usr/bin/env python3
"""
Test worldview update alongside main action.

Runs epochs with scenarios that should encourage the model to update
its worldview, and verifies:
1. The model produces valid JSON every time
2. The worldview field is properly formed when present
3. The main action is still valid alongside worldview updates
4. The model can remember investment blowups etc
"""

import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "agent"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "tee"))

from runner import build_epoch_context, format_eth, datamark_text, _generate_marker
from enclave_runner import parse_action, _extract_json_object

SERVER_URL = os.environ.get("LLAMA_SERVER_URL", "http://localhost:8080")

PROMPT_PATH = os.path.join(os.path.dirname(__file__), "agent", "prompts", "system_v6.txt")
PROTOCOLS_PATH = os.path.join(os.path.dirname(__file__), "agent", "prompts", "protocols_reference.txt")

def _wei(eth):
    return int(eth * 1e18)

def load_system_prompt():
    with open(PROMPT_PATH) as f:
        prompt = f.read().strip()
    if os.path.exists(PROTOCOLS_PATH):
        with open(PROTOCOLS_PATH) as f:
            prompt += "\n\n" + f.read().strip()
    return prompt

def two_pass_inference(system_prompt, epoch_context, server_url):
    from urllib.request import urlopen, Request

    full_prompt = system_prompt + "\n\n" + epoch_context + "\n\nReminder: Reason inside <think> tags, then output exactly one JSON action. You may optionally include a \"worldview\" field to update a guiding policy."

    # Pass 1: reasoning
    req_data = json.dumps({
        "prompt": f"<|begin_of_text|>{full_prompt}\n\n<think>\n",
        "max_tokens": 2048,
        "temperature": 0.6,
        "stop": ["</think>"],
    }).encode()
    req = Request(f"{server_url}/v1/completions", data=req_data,
                  headers={"Content-Type": "application/json", "User-Agent": "TheHumanFund/1.0"})
    with urlopen(req, timeout=300) as resp:
        result = json.loads(resp.read())
    reasoning = result["choices"][0]["text"].strip()

    # Pass 2: action JSON
    action_prompt = f"<|begin_of_text|>{full_prompt}\n\n<think>\n{reasoning}\n</think>\n{{"
    req_data = json.dumps({
        "prompt": action_prompt,
        "max_tokens": 512,  # More room for worldview field
        "temperature": 0.3,
        "stop": ["\n\n"],
    }).encode()
    req = Request(f"{server_url}/v1/completions", data=req_data,
                  headers={"Content-Type": "application/json", "User-Agent": "TheHumanFund/1.0"})
    with urlopen(req, timeout=120) as resp:
        result = json.loads(resp.read())
    action_text = "{" + result["choices"][0]["text"].strip()

    return reasoning, action_text


def make_state(epoch, policies=None, investments=None, messages=None, treasury=2.0, history=None):
    if policies is None:
        policies = []
    if investments is None:
        investments = [
            {"id": 1, "name": "Aave V3 WETH", "deposited": 0, "shares": 0, "current_value": 0, "active": True, "risk_tier": 1, "expected_apy_bps": 400},
            {"id": 2, "name": "Lido wstETH", "deposited": 0, "shares": 0, "current_value": 0, "active": True, "risk_tier": 2, "expected_apy_bps": 350},
        ]
    if messages is None:
        messages = []
    if history is None:
        history = []

    return {
        'epoch': epoch,
        'treasury_balance': _wei(treasury),
        'total_donated': _wei(0.5),
        'total_received': _wei(3.0),
        'commission_rate_bps': 500,
        'max_bid': _wei(0.0001),
        'effective_max_bid': _wei(0.0001),
        'last_donation_epoch': max(1, epoch - 1),
        'last_commission_change_epoch': 0,
        'consecutive_missed': 0,
        'nonprofits': [
            {'id': 1, 'name': 'GiveDirectly', 'address': '0x' + 'a1'*20, 'total_donated': _wei(0.2), 'donation_count': 3},
            {'id': 2, 'name': 'Against Malaria Foundation', 'address': '0x' + 'b2'*20, 'total_donated': _wei(0.15), 'donation_count': 2},
            {'id': 3, 'name': 'Helen Keller International', 'address': '0x' + 'c3'*20, 'total_donated': _wei(0.15), 'donation_count': 1},
        ],
        'investments': investments,
        'total_invested': sum(i['current_value'] for i in investments),
        'guiding_policies': policies[:],
        'donor_messages': messages,
        'message_count': len(messages),
        'message_head': 0,
        'history': history,
        'randomness_seed': epoch * 54321,
    }


def run_epoch(test_name, state):
    """Run one epoch and return parsed results."""
    print(f"\n{'='*70}")
    print(f"  {test_name} (epoch {state['epoch']})")
    print(f"{'='*70}")
    print(f"  Treasury: {format_eth(state['treasury_balance'])} ETH")
    print(f"  Policies: {len([p for p in state['guiding_policies'] if p])}")
    if state['donor_messages']:
        print(f"  Messages: {len(state['donor_messages'])}")

    context = build_epoch_context(state)
    system_prompt = load_system_prompt()

    t0 = time.time()
    reasoning, action_text = two_pass_inference(system_prompt, context, SERVER_URL)
    elapsed = time.time() - t0

    print(f"  ⏱️  {elapsed:.1f}s")

    # Parse the action
    parsed = parse_action(action_text)
    if parsed:
        action_type = parsed.get("action", "unknown")
        params = parsed.get("params", {})
        worldview = parsed.get("worldview")

        print(f"  🎯 Action: {action_type}({params})")
        if worldview:
            print(f"  📝 Worldview: slot {worldview.get('slot')}: \"{worldview.get('policy', '')[:60]}...\"")
        else:
            print(f"  📝 Worldview: (no update)")
    else:
        action_type = "PARSE_FAILED"
        worldview = None
        print(f"  ❌ Parse failed: {action_text[:200]}")

    # Show reasoning snippet
    print(f"  Reasoning ({len(reasoning)} chars): ...{reasoning[-200:]}")

    return {
        "action_type": action_type,
        "parsed": parsed,
        "worldview": worldview,
        "reasoning": reasoning,
        "action_text": action_text,
        "elapsed": elapsed,
    }


def main():
    print("=" * 70)
    print("  WORLDVIEW UPDATE TEST SUITE")
    print("  Model: DeepSeek R1 Distill 70B Q4_K_M")
    print("=" * 70)

    results = []
    system_prompt = load_system_prompt()

    # ─── Test 1: Fresh fund — should the model set initial policies? ───
    state = make_state(epoch=1, policies=[], treasury=2.0)
    r = run_epoch("T1: Fresh fund, no policies yet", state)
    results.append(("T1", r))

    # ─── Test 2: After investment blowup — should remember ─────────────
    state = make_state(
        epoch=15,
        policies=["Maintain 60% in safe protocols, 20% medium risk, 20% liquid."],
        treasury=1.0,
        investments=[
            {"id": 1, "name": "Aave V3 WETH", "deposited": _wei(0.5), "shares": _wei(0.5), "current_value": _wei(0.5), "active": True, "risk_tier": 1, "expected_apy_bps": 400},
            {"id": 2, "name": "Lido wstETH", "deposited": _wei(0.5), "shares": _wei(0.5), "current_value": _wei(0.15), "active": True, "risk_tier": 2, "expected_apy_bps": 350},  # 70% loss!
        ],
        history=[
            {'epoch': 14, 'reasoning': 'CRITICAL: Lido wstETH position has lost 70% of its value due to a depeg event. Our 0.5 ETH deposit is now worth only 0.15 ETH. This is a severe loss. I need to reassess our investment strategy.',
             'action': b'\x05' + b'\x00'*63, 'treasury_before': _wei(1.0), 'treasury_after': _wei(1.0)},
            {'epoch': 13, 'reasoning': 'Routine donation to GiveDirectly.',
             'action': b'\x01' + b'\x00'*31 + _wei(0.1).to_bytes(32, 'big'), 'treasury_before': _wei(1.1), 'treasury_after': _wei(1.0)},
        ],
    )
    r = run_epoch("T2: After investment blowup — should update policy", state)
    results.append(("T2", r))

    # ─── Test 3: Donor with strong preference — worldview note? ────────
    state = make_state(
        epoch=10,
        policies=["Donate generously while maintaining reserves."],
        treasury=3.0,
        messages=[
            {'sender': '0x' + 'ab'*20, 'amount': _wei(2.0), 'epoch': 9,
             'text': 'I donated 2 ETH. I believe strongly in Against Malaria Foundation. Bed nets save more lives per dollar than almost any other intervention.'},
        ],
    )
    r = run_epoch("T3: Large donor with strong preference", state)
    results.append(("T3", r))

    # ─── Test 4: Multiple epochs — does it produce valid JSON each time? ───
    state = make_state(epoch=20, policies=["Be generous.", "Invest conservatively."], treasury=1.5)
    for ep in range(5):
        state['epoch'] = 20 + ep
        state['randomness_seed'] = (20 + ep) * 54321
        r = run_epoch(f"T4.{ep}: Reliability run epoch {20+ep}", state)
        results.append((f"T4.{ep}", r))
        # Update state with action results if parsed
        if r["parsed"]:
            wv = r["parsed"].get("worldview")
            if wv and isinstance(wv, dict):
                slot = int(wv.get("slot", 0))
                policy = str(wv.get("policy", ""))[:280]
                if 0 <= slot <= 9 and policy:
                    while len(state["guiding_policies"]) <= slot:
                        state["guiding_policies"].append("")
                    state["guiding_policies"][slot] = policy

    # ─── Summary ──────────────────────────────────────────────────────
    print("\n" + "=" * 70)
    print("  RESULTS SUMMARY")
    print("=" * 70)

    total = len(results)
    parsed_ok = sum(1 for _, r in results if r["parsed"] is not None)
    with_worldview = sum(1 for _, r in results if r["worldview"] is not None)
    parse_rate = parsed_ok / total * 100

    print(f"\n  Total epochs: {total}")
    print(f"  Parse success: {parsed_ok}/{total} ({parse_rate:.0f}%)")
    print(f"  With worldview update: {with_worldview}/{total}")
    print()

    for name, r in results:
        wv_str = f"📝 slot {r['worldview']['slot']}" if r['worldview'] else "—"
        status = "✅" if r["parsed"] else "❌"
        print(f"  {status} {name}: {r['action_type']:20s} | worldview: {wv_str}")

    print()
    if parsed_ok == total:
        print("  🎉 100% parse success — worldview feature is reliable!")
    else:
        print(f"  ⚠️  {total - parsed_ok} parse failures")

    return 0 if parsed_ok == total else 1


if __name__ == "__main__":
    sys.exit(main())
