#!/usr/bin/env python3
"""
Prompt evaluation tool for The Human Fund.

Sends system prompt + epoch context to the llama-server, parses the response,
validates the action, and saves results for comparison across prompt versions.

Usage:
    # Run all scenarios with the current prompt version
    python agent/run_eval.py

    # Run a specific scenario
    python agent/run_eval.py --scenario first_epoch

    # Use a specific prompt version
    python agent/run_eval.py --prompt agent/prompts/system_v2.txt

    # Compare two prompt versions
    python agent/run_eval.py --compare v1 v2
"""

import json
import re
import sys
import time
import argparse
from datetime import datetime
from pathlib import Path
from urllib.request import urlopen, Request
from urllib.error import URLError

BASE_URL = "https://xabf55irwjp075-8080.proxy.runpod.net"
PROJECT_ROOT = Path(__file__).parent.parent
AGENT_DIR = PROJECT_ROOT / "agent"
SCENARIOS_FILE = AGENT_DIR / "scenarios" / "scenarios.json"
RESULTS_DIR = AGENT_DIR / "results"


def _headers():
    """Common headers to avoid Cloudflare blocking."""
    return {"User-Agent": "TheHumanFund/1.0", "Content-Type": "application/json"}


def check_server():
    """Check if the llama-server is reachable."""
    try:
        req = Request(f"{BASE_URL}/health", headers=_headers())
        resp = urlopen(req, timeout=10)
        data = json.loads(resp.read())
        return data.get("status") == "ok"
    except Exception as e:
        print(f"Server not reachable: {e}")
        return False


def run_inference(prompt: str, max_tokens: int = 4096, temperature: float = 0.6) -> dict:
    """Send a completion request to the llama-server."""
    payload = json.dumps({
        "prompt": prompt,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stop": ["\n{\"action\""],  # We'll handle this differently
    }).encode()

    # Actually, don't use stop — let it generate the full response including JSON
    payload = json.dumps({
        "prompt": prompt,
        "max_tokens": max_tokens,
        "temperature": temperature,
    }).encode()

    req = Request(
        f"{BASE_URL}/v1/completions",
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
        "finish_reason": choice["finish_reason"],
        "tokens": result["usage"],
        "elapsed_seconds": round(elapsed, 1),
        "timings": result.get("timings", {}),
    }


def parse_response(text: str) -> dict:
    """Parse the model's response into think block + action JSON."""
    result = {
        "raw": text,
        "think": None,
        "action_json": None,
        "action": None,
        "parse_errors": [],
    }

    # Extract <think> block
    # The prompt already opens <think>, so the response text may start with
    # the reasoning directly (no opening tag) and close with </think>
    think_match = re.search(r"<think>(.*?)</think>", text, re.DOTALL)
    if think_match:
        result["think"] = think_match.group(1).strip()
    else:
        # Check if text starts with reasoning (we primed with <think>\n)
        close_idx = text.find("</think>")
        if close_idx >= 0:
            result["think"] = text[:close_idx].strip()
        else:
            think_start = text.find("<think>")
            if think_start >= 0:
                result["think"] = text[think_start + 7:].strip()
                result["parse_errors"].append("Think block not closed (truncated?)")
            else:
                result["parse_errors"].append("No <think> block found")

    # Also look for JSON after </think> when we primed the opening tag
    json_match_alt = re.search(r"</think>\s*(\{.*?\})", text, re.DOTALL)

    # Extract JSON action (look for it after </think>)
    json_match = re.search(r"</think>\s*(\{.*?\})\s*$", text, re.DOTALL)
    if json_match:
        json_str = json_match.group(1).strip()
        try:
            result["action_json"] = json.loads(json_str)
            result["action"] = result["action_json"].get("action")
        except json.JSONDecodeError as e:
            result["parse_errors"].append(f"Invalid JSON: {e}")
            result["action_json"] = json_str  # Save raw string
    else:
        # Try to find any JSON object in the text after thinking
        all_json = re.findall(r'\{[^{}]*"action"[^{}]*\}', text)
        if all_json:
            json_str = all_json[-1]  # Take the last one
            try:
                result["action_json"] = json.loads(json_str)
                result["action"] = result["action_json"].get("action")
                result["parse_errors"].append("JSON found but not in expected position")
            except json.JSONDecodeError:
                result["parse_errors"].append("Found action-like JSON but couldn't parse it")
        else:
            result["parse_errors"].append("No action JSON found")

    return result


def validate_action(parsed: dict, scenario_context: str) -> dict:
    """Validate the action against the contract's hard constraints."""
    checks = {
        "has_think_block": parsed["think"] is not None,
        "has_valid_json": isinstance(parsed["action_json"], dict),
        "has_action_field": parsed["action"] is not None,
        "action_is_valid_type": False,
        "params_valid": False,
        "within_bounds": False,
        "errors": [],
    }

    if not checks["has_action_field"]:
        checks["errors"].append("No action field in output")
        return checks

    action = parsed["action"]
    params = parsed["action_json"].get("params", {})
    valid_actions = ["donate", "set_commission_rate", "set_max_bid", "noop"]

    if action not in valid_actions:
        checks["errors"].append(f"Unknown action: {action}")
        return checks

    checks["action_is_valid_type"] = True

    # Extract treasury balance from context
    balance_match = re.search(r"Treasury balance: ([\d.]+) ETH", scenario_context)
    treasury = float(balance_match.group(1)) if balance_match else None

    if action == "noop":
        checks["params_valid"] = True
        checks["within_bounds"] = True

    elif action == "donate":
        nid = params.get("nonprofit_id")
        amount = params.get("amount_eth")
        if nid in [1, 2, 3] and isinstance(amount, (int, float)) and amount > 0:
            checks["params_valid"] = True
            if treasury and amount <= treasury * 0.10:
                checks["within_bounds"] = True
            else:
                checks["errors"].append(
                    f"Donation {amount} ETH exceeds 10% of treasury ({treasury} ETH)"
                )
        else:
            checks["errors"].append(f"Invalid donate params: nonprofit_id={nid}, amount_eth={amount}")

    elif action == "set_commission_rate":
        rate = params.get("rate_bps")
        if isinstance(rate, (int, float)) and 100 <= rate <= 9000:
            checks["params_valid"] = True
            checks["within_bounds"] = True
        else:
            checks["errors"].append(f"Invalid commission rate: {rate} (must be 100-9000)")

    elif action == "set_max_bid":
        amount = params.get("amount_eth")
        if isinstance(amount, (int, float)) and amount >= 0.0001:
            checks["params_valid"] = True
            if treasury and amount <= treasury * 0.02:
                checks["within_bounds"] = True
            else:
                checks["errors"].append(
                    f"Max bid {amount} ETH exceeds 2% of treasury ({treasury} ETH)"
                )
        else:
            checks["errors"].append(f"Invalid max bid: {amount}")

    return checks


def evaluate_quality(parsed: dict) -> dict:
    """Qualitative metrics for the response."""
    think = parsed.get("think") or ""
    return {
        "think_length_chars": len(think),
        "think_length_words": len(think.split()),
        "references_history": bool(re.search(r"(last epoch|previous|epoch \d+|I (said|decided|thought))", think, re.I)),
        "mentions_tradeoffs": bool(re.search(r"(tradeoff|trade-off|balance|tension|on the other hand|however|but|versus)", think, re.I)),
        "mentions_numbers": bool(re.search(r"\d+\.\d+\s*ETH|\d+%|\$[\d,]+", think)),
        "mentions_nonprofits": bool(re.search(r"(GiveDirectly|Against Malaria|Helen Keller)", think, re.I)),
        "shows_uncertainty": bool(re.search(r"(uncertain|not sure|might|could|maybe|perhaps|I don't know)", think, re.I)),
        "has_strategy": bool(re.search(r"(strategy|plan|approach|going forward|next epoch|long.?term)", think, re.I)),
    }


def print_result(scenario: dict, parsed: dict, validation: dict, quality: dict, inference: dict):
    """Pretty-print the evaluation result."""
    print(f"\n{'='*70}")
    print(f"SCENARIO: {scenario['name']}")
    print(f"{'='*70}")

    # Think block (truncated for display)
    think = parsed.get("think") or "(none)"
    if len(think) > 800:
        think_display = think[:400] + "\n  [...]\n  " + think[-400:]
    else:
        think_display = think
    print(f"\n📝 REASONING ({quality['think_length_words']} words):")
    print(f"  {think_display}")

    # Action
    print(f"\n🎯 ACTION: {json.dumps(parsed.get('action_json', 'NONE'), indent=2)}")

    # Validation
    all_valid = all([
        validation["has_think_block"],
        validation["has_valid_json"],
        validation["action_is_valid_type"],
        validation["params_valid"],
        validation["within_bounds"],
    ])
    print(f"\n✅ VALIDATION: {'PASS' if all_valid else 'FAIL'}")
    for key in ["has_think_block", "has_valid_json", "action_is_valid_type", "params_valid", "within_bounds"]:
        status = "✅" if validation[key] else "❌"
        print(f"  {status} {key}")
    if validation["errors"]:
        for err in validation["errors"]:
            print(f"  ⚠️  {err}")

    # Quality
    print(f"\n📊 QUALITY:")
    for key, val in quality.items():
        if isinstance(val, bool):
            print(f"  {'✅' if val else '⬜'} {key}")
        else:
            print(f"  📏 {key}: {val}")

    # Parse errors
    if parsed["parse_errors"]:
        print(f"\n⚠️  PARSE ISSUES:")
        for err in parsed["parse_errors"]:
            print(f"  - {err}")

    # Performance
    print(f"\n⏱️  {inference['elapsed_seconds']}s | "
          f"{inference['tokens']['completion_tokens']} tokens generated | "
          f"{inference['tokens']['total_tokens']} total tokens")


def run_scenario(scenario: dict, system_prompt: str) -> dict:
    """Run a single scenario and return the full result."""
    # Construct the full prompt — end with <think> to prime the model
    full_prompt = system_prompt + "\n\n" + scenario["context"] + "\n\n<think>\n"

    print(f"\n⏳ Running: {scenario['name']}...")
    inference = run_inference(full_prompt)
    parsed = parse_response(inference["text"])
    validation = validate_action(parsed, scenario["context"])
    quality = evaluate_quality(parsed)

    print_result(scenario, parsed, validation, quality, inference)

    return {
        "scenario_id": scenario["id"],
        "scenario_name": scenario["name"],
        "inference": inference,
        "parsed": {
            "think": parsed["think"],
            "action_json": parsed["action_json"] if isinstance(parsed["action_json"], dict) else str(parsed["action_json"]),
            "action": parsed["action"],
            "parse_errors": parsed["parse_errors"],
        },
        "validation": validation,
        "quality": quality,
    }


def compare_versions(v1_name: str, v2_name: str):
    """Compare results from two prompt versions side by side."""
    v1_dir = RESULTS_DIR / v1_name
    v2_dir = RESULTS_DIR / v2_name

    if not v1_dir.exists() or not v2_dir.exists():
        print(f"Missing results directory. Available: {[d.name for d in RESULTS_DIR.iterdir() if d.is_dir()]}")
        return

    v1_summary = json.loads((v1_dir / "summary.json").read_text())
    v2_summary = json.loads((v2_dir / "summary.json").read_text())

    print(f"\n{'='*70}")
    print(f"COMPARISON: {v1_name} vs {v2_name}")
    print(f"{'='*70}")

    for s1 in v1_summary["results"]:
        s2 = next((s for s in v2_summary["results"] if s["scenario_id"] == s1["scenario_id"]), None)
        if not s2:
            continue

        print(f"\n--- {s1['scenario_name']} ---")
        print(f"  {'':30s} {'v1':>15s} {'v2':>15s}")

        a1 = s1["parsed"]["action"] or "FAIL"
        a2 = s2["parsed"]["action"] or "FAIL"
        print(f"  {'Action':30s} {a1:>15s} {a2:>15s}")

        v1_valid = "PASS" if s1["validation"]["within_bounds"] else "FAIL"
        v2_valid = "PASS" if s2["validation"]["within_bounds"] else "FAIL"
        print(f"  {'Valid':30s} {v1_valid:>15s} {v2_valid:>15s}")

        w1 = s1["quality"]["think_length_words"]
        w2 = s2["quality"]["think_length_words"]
        print(f"  {'Think length (words)':30s} {w1:>15d} {w2:>15d}")

        t1 = s1["inference"]["elapsed_seconds"]
        t2 = s2["inference"]["elapsed_seconds"]
        print(f"  {'Time (seconds)':30s} {t1:>15.1f} {t2:>15.1f}")

        for qkey in ["references_history", "mentions_tradeoffs", "mentions_numbers", "shows_uncertainty", "has_strategy"]:
            q1 = "✅" if s1["quality"][qkey] else "⬜"
            q2 = "✅" if s2["quality"][qkey] else "⬜"
            print(f"  {qkey:30s} {q1:>15s} {q2:>15s}")


def main():
    parser = argparse.ArgumentParser(description="Evaluate Human Fund prompts")
    parser.add_argument("--prompt", default=str(AGENT_DIR / "prompts" / "system_v1.txt"),
                        help="Path to system prompt file")
    parser.add_argument("--scenario", default=None,
                        help="Run a specific scenario by ID (default: all)")
    parser.add_argument("--compare", nargs=2, metavar=("V1", "V2"),
                        help="Compare two result versions")
    parser.add_argument("--max-tokens", type=int, default=4096,
                        help="Max tokens for generation")
    parser.add_argument("--label", default=None,
                        help="Label for this run (default: prompt filename stem)")
    args = parser.parse_args()

    if args.compare:
        compare_versions(args.compare[0], args.compare[1])
        return

    # Check server
    if not check_server():
        print("❌ Server not reachable. Start llama-server on RunPod first.")
        print("   See CLAUDE.md for instructions.")
        sys.exit(1)

    print("✅ Server is healthy")

    # Load prompt
    prompt_path = Path(args.prompt)
    system_prompt = prompt_path.read_text().strip()
    print(f"📄 Prompt: {prompt_path.name} ({len(system_prompt.split())} words)")

    # Load scenarios
    scenarios = json.loads(SCENARIOS_FILE.read_text())
    if args.scenario:
        scenarios = [s for s in scenarios if s["id"] == args.scenario]
        if not scenarios:
            print(f"❌ Unknown scenario: {args.scenario}")
            print(f"   Available: {[s['id'] for s in json.loads(SCENARIOS_FILE.read_text())]}")
            sys.exit(1)

    print(f"🎯 Scenarios: {len(scenarios)}")

    # Run evaluations
    results = []
    for scenario in scenarios:
        result = run_scenario(scenario, system_prompt)
        results.append(result)

    # Save results
    label = args.label or prompt_path.stem
    run_dir = RESULTS_DIR / label
    run_dir.mkdir(parents=True, exist_ok=True)

    summary = {
        "prompt_file": str(prompt_path),
        "prompt_label": label,
        "timestamp": datetime.now().isoformat(),
        "results": results,
    }

    summary_path = run_dir / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, default=str))
    print(f"\n💾 Results saved to {summary_path}")

    # Print overall summary
    print(f"\n{'='*70}")
    print("SUMMARY")
    print(f"{'='*70}")
    total = len(results)
    valid = sum(1 for r in results if r["validation"]["within_bounds"])
    parsed = sum(1 for r in results if r["validation"]["has_valid_json"])
    actions = {}
    for r in results:
        a = r["parsed"]["action"] or "PARSE_FAIL"
        actions[a] = actions.get(a, 0) + 1

    print(f"  Scenarios: {total}")
    print(f"  Parsed OK: {parsed}/{total}")
    print(f"  Valid actions: {valid}/{total}")
    print(f"  Action distribution: {actions}")
    avg_think = sum(r["quality"]["think_length_words"] for r in results) / total
    print(f"  Avg think length: {avg_think:.0f} words")
    avg_time = sum(r["inference"]["elapsed_seconds"] for r in results) / total
    print(f"  Avg inference time: {avg_time:.1f}s")


if __name__ == "__main__":
    main()
