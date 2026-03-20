#!/usr/bin/env python3
"""
The Human Fund — Model Comparison Arena

A blind arena tool for comparing LLM models on simulated agent epochs.
Users evaluate model outputs without knowing which model produced them.

Two modes:
  run    — Run multiple models through the same simulation scenarios
  review — Serve a local UI for blind evaluation and ranking

Usage:
    # Run two models through 5 epochs
    python scripts/arena.py run \\
        --models ds-70b:http://localhost:8080,llama-33-70b:http://localhost:8081 \\
        --epochs 5 --treasury 0.5

    # Review results in browser
    python scripts/arena.py review --input arena_results.json --port 8888
"""

import argparse
import copy
import json
import os
import random
import string
import sys
import time
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.request import urlopen, Request

# ─── Path setup ──────────────────────────────────────────────────────────

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "agent"))
sys.path.insert(0, str(PROJECT_ROOT / "tee"))

from runner import build_epoch_context, format_eth
from enclave_runner import encode_action_bytes, _extract_json_object, parse_action

# ─── Reuse simulation infrastructure ────────────────────────────────────

from simulate import (
    generate_initial_state,
    apply_action,
    advance_epoch,
    add_history_entry,
    call_llama,
    two_pass_inference,
    _wei,
)

# ─── Run Mode ────────────────────────────────────────────────────────────


def parse_model_configs(models_str):
    """Parse 'name:url,name:url' into list of dicts."""
    configs = []
    for entry in models_str.split(","):
        entry = entry.strip()
        if ":" not in entry:
            print(f"ERROR: Invalid model config '{entry}'. Expected name:url")
            sys.exit(1)
        # Split on first colon only (URL contains colons)
        name, url = entry.split(":", 1)
        # Handle case where name:http://... has the http:// split wrong
        if not url.startswith("http"):
            # Try splitting differently: everything after first : is URL
            pass
        configs.append({"name": name.strip(), "url": url.strip()})
    return configs


def check_server_health(url, name):
    """Verify a llama-server is reachable."""
    try:
        req = Request(
            f"{url}/health",
            headers={"User-Agent": "TheHumanFund/1.0"},
        )
        resp = urlopen(req, timeout=10)
        health = json.loads(resp.read())
        status = health.get("status", "unknown")
        print(f"  {name} ({url}): {status}")
        return status == "ok"
    except Exception as e:
        print(f"  {name} ({url}): UNREACHABLE — {e}")
        return False


def format_action_display(action_json):
    """Create a human-readable display string for an action."""
    action = action_json.get("action", "unknown")
    params = action_json.get("params", {})

    if action == "noop":
        return "noop()"
    elif action == "donate":
        np_id = params.get("nonprofit_id", params.get("id", "?"))
        amount = params.get("amount_eth", params.get("amount", "?"))
        return f"donate(nonprofit_id={np_id}, amount={amount} ETH)"
    elif action == "set_commission_rate":
        rate = params.get("rate_bps", params.get("rate", "?"))
        return f"set_commission_rate(rate_bps={rate})"
    elif action == "set_max_bid":
        amount = params.get("amount_eth", params.get("amount", "?"))
        return f"set_max_bid(amount={amount} ETH)"
    elif action == "invest":
        pid = params.get("protocol_id", params.get("id", "?"))
        amount = params.get("amount_eth", params.get("amount", "?"))
        return f"invest(protocol_id={pid}, amount={amount} ETH)"
    elif action == "withdraw":
        pid = params.get("protocol_id", params.get("id", "?"))
        amount = params.get("amount_eth", params.get("amount", "?"))
        return f"withdraw(protocol_id={pid}, amount={amount} ETH)"
    elif action in ("set_guiding_policy", "set_policy"):
        slot = params.get("slot", params.get("slot_id", "?"))
        policy = str(params.get("policy", params.get("text", "")))[:60]
        return f'set_guiding_policy(slot={slot}, policy="{policy}...")'
    else:
        return f"{action}({json.dumps(params)})"


def run_arena(args):
    """Run multiple models through the same simulation epochs."""
    models = parse_model_configs(args.models)

    if len(models) < 2:
        print("ERROR: Need at least 2 models to compare.")
        sys.exit(1)

    print(f"\nModel Arena — Comparing {len(models)} models over {args.epochs} epochs")
    print(f"Initial treasury: {args.treasury} ETH")
    print()

    # Check all servers
    print("Checking model servers...")
    all_ok = True
    for m in models:
        if not check_server_health(m["url"], m["name"]):
            all_ok = False
    if not all_ok:
        print("\nERROR: Not all servers are reachable. Fix and retry.")
        sys.exit(1)
    print()

    # Load system prompt
    system_prompt_path = PROJECT_ROOT / "agent" / "prompts" / "system_v4.txt"
    if not system_prompt_path.exists():
        # Fall back to v3
        system_prompt_path = PROJECT_ROOT / "agent" / "prompts" / "system_v3.txt"
    if not system_prompt_path.exists():
        print("ERROR: No system prompt found (tried system_v4.txt, system_v3.txt)")
        sys.exit(1)

    system_prompt = system_prompt_path.read_text().strip()
    protocols_ref_path = PROJECT_ROOT / "agent" / "prompts" / "protocols_reference.txt"
    if protocols_ref_path.exists():
        system_prompt += "\n\n" + protocols_ref_path.read_text().strip()

    # Create anonymized model map
    model_keys = [f"model_{chr(ord('a') + i)}" for i in range(len(models))]
    model_map = {key: m["name"] for key, m in zip(model_keys, models)}

    # Generate shared initial state
    base_state = generate_initial_state(args.treasury, start_epoch=10)

    # Each model gets its own state fork
    model_states = {key: copy.deepcopy(base_state) for key in model_keys}

    # Results structure
    results = {
        "metadata": {
            "created": datetime.now(timezone.utc).isoformat(),
            "epochs": args.epochs,
            "initial_treasury": f"{args.treasury} ETH",
            "models": [m["name"] for m in models],
            "system_prompt": system_prompt_path.name,
        },
        "epochs": [],
        "model_map": model_map,
    }

    print("=" * 70)
    print("  ARENA RUN")
    print("=" * 70)

    for epoch_idx in range(args.epochs):
        # Use model_a's state for epoch number (they may diverge but epoch counter is shared)
        epoch_num = model_states[model_keys[0]]["epoch"]

        print(f"\n{'=' * 70}")
        print(f"  EPOCH {epoch_num} (step {epoch_idx + 1}/{args.epochs})")
        print(f"{'=' * 70}")

        epoch_result = {
            "epoch_num": epoch_num,
            "results": {},
        }

        for key, model in zip(model_keys, models):
            state = model_states[key]
            print(f"\n  [{model['name']}] Treasury: {format_eth(state['treasury_balance'])} ETH")

            # Build epoch context from this model's state
            epoch_context = build_epoch_context(state)

            if epoch_idx == 0 and key == model_keys[0]:
                # Store context preview from first model's first epoch
                epoch_result["context_preview"] = epoch_context[:200]

            full_prompt = system_prompt + "\n\n" + epoch_context + "\n\n<think>\n"

            # Run inference
            print(f"  [{model['name']}] Running inference...")
            start_time = time.time()
            try:
                inference = two_pass_inference(model["url"], full_prompt)
            except Exception as e:
                print(f"  [{model['name']}] ERROR: Inference failed: {e}")
                elapsed = time.time() - start_time
                epoch_result["results"][key] = {
                    "reasoning": f"[Inference failed: {e}]",
                    "action": {"action": "noop", "params": {}},
                    "action_display": "noop() [inference error]",
                    "state_changes": ["Inference failed, no action taken"],
                    "treasury_after": format_eth(state["treasury_balance"]) + " ETH",
                    "elapsed_seconds": round(elapsed, 1),
                }
                advance_epoch(state)
                continue

            elapsed = time.time() - start_time
            print(f"  [{model['name']}] Done in {elapsed:.1f}s")

            # Parse action
            action_json = parse_action(inference["text"])
            if not action_json:
                print(f"  [{model['name']}] WARNING: Could not parse action, defaulting to noop")
                action_json = {"action": "noop", "params": {}}

            # Apply action to this model's state fork
            treasury_before = state["treasury_balance"]
            changes = apply_action(state, action_json)

            # Encode action bytes for history
            try:
                action_bytes = encode_action_bytes(action_json)
            except Exception:
                action_bytes = bytes([0])

            add_history_entry(state, action_json, inference.get("reasoning", ""), action_bytes)

            # Store result
            epoch_result["results"][key] = {
                "reasoning": inference.get("reasoning", inference["text"]),
                "action": action_json,
                "action_display": format_action_display(action_json),
                "state_changes": changes,
                "treasury_after": format_eth(state["treasury_balance"]) + " ETH",
                "elapsed_seconds": round(elapsed, 1),
            }

            print(f"  [{model['name']}] Action: {format_action_display(action_json)}")
            for c in changes:
                print(f"  [{model['name']}] {c}")

            # Advance to next epoch
            advance_epoch(state)

        # Store context preview if not set
        if "context_preview" not in epoch_result:
            first_key = model_keys[0]
            epoch_result["context_preview"] = f"Epoch {epoch_num} context"

        results["epochs"].append(epoch_result)

    # Save results
    output_path = Path(args.output)
    output_path.write_text(json.dumps(results, indent=2, default=str))
    print(f"\n{'=' * 70}")
    print(f"  Arena results saved to {output_path}")
    print(f"  Run 'python scripts/arena.py review --input {output_path}' to evaluate")
    print(f"{'=' * 70}\n")


# ─── Review Mode ─────────────────────────────────────────────────────────

REVIEW_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>The Human Fund — Model Arena</title>
<style>
  :root {
    --bg-primary: #0d1117;
    --bg-secondary: #161b22;
    --bg-card: #1c2128;
    --bg-hover: #252c35;
    --border: #30363d;
    --text-primary: #e6edf3;
    --text-secondary: #8b949e;
    --text-muted: #484f58;
    --green: #3fb950;
    --green-dim: #1a3a2a;
    --orange: #d29922;
    --orange-dim: #3d2e00;
    --blue: #58a6ff;
    --red: #f85149;
    --purple: #bc8cff;
    --font-mono: 'SF Mono', 'Fira Code', 'Cascadia Code', monospace;
    --font-sans: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
  }

  * { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    background: var(--bg-primary);
    color: var(--text-primary);
    font-family: var(--font-sans);
    line-height: 1.6;
    min-height: 100vh;
  }

  .header {
    background: var(--bg-secondary);
    border-bottom: 1px solid var(--border);
    padding: 1rem 2rem;
    display: flex;
    align-items: center;
    justify-content: space-between;
    position: sticky;
    top: 0;
    z-index: 100;
  }

  .header h1 {
    font-family: var(--font-mono);
    font-size: 1.1rem;
    color: var(--green);
    font-weight: 600;
  }

  .header .meta {
    font-size: 0.85rem;
    color: var(--text-secondary);
    font-family: var(--font-mono);
  }

  .container {
    max-width: 1400px;
    margin: 0 auto;
    padding: 2rem;
  }

  .progress-bar {
    display: flex;
    gap: 0.5rem;
    margin-bottom: 2rem;
    flex-wrap: wrap;
  }

  .progress-dot {
    width: 2.5rem;
    height: 2.5rem;
    border-radius: 0.4rem;
    border: 1px solid var(--border);
    background: var(--bg-secondary);
    display: flex;
    align-items: center;
    justify-content: center;
    font-family: var(--font-mono);
    font-size: 0.8rem;
    color: var(--text-secondary);
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .progress-dot:hover { background: var(--bg-hover); }
  .progress-dot.active { border-color: var(--green); color: var(--green); background: var(--green-dim); }
  .progress-dot.ranked { border-color: var(--orange); color: var(--orange); background: var(--orange-dim); }
  .progress-dot.ranked.active { border-color: var(--green); color: var(--green); background: var(--green-dim); }

  .epoch-header {
    margin-bottom: 1.5rem;
  }

  .epoch-header h2 {
    font-family: var(--font-mono);
    font-size: 1.3rem;
    color: var(--text-primary);
    margin-bottom: 0.5rem;
  }

  .context-preview {
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-radius: 0.5rem;
    padding: 1rem;
    font-family: var(--font-mono);
    font-size: 0.8rem;
    color: var(--text-secondary);
    white-space: pre-wrap;
    word-break: break-word;
    margin-bottom: 1.5rem;
    max-height: 6rem;
    overflow: hidden;
    position: relative;
    cursor: pointer;
    transition: max-height 0.3s ease;
  }

  .context-preview.expanded {
    max-height: none;
  }

  .context-preview::after {
    content: 'click to expand';
    position: absolute;
    bottom: 0;
    left: 0;
    right: 0;
    height: 2.5rem;
    background: linear-gradient(transparent, var(--bg-secondary));
    display: flex;
    align-items: flex-end;
    justify-content: center;
    font-size: 0.7rem;
    color: var(--text-muted);
    padding-bottom: 0.3rem;
  }

  .context-preview.expanded::after {
    display: none;
  }

  .model-cards {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(500px, 1fr));
    gap: 1.5rem;
    margin-bottom: 2rem;
  }

  .model-card {
    background: var(--bg-card);
    border: 1px solid var(--border);
    border-radius: 0.75rem;
    overflow: hidden;
    transition: border-color 0.15s ease;
  }

  .model-card:hover { border-color: var(--text-muted); }

  .card-header {
    padding: 1rem 1.25rem;
    border-bottom: 1px solid var(--border);
    display: flex;
    align-items: center;
    justify-content: space-between;
    background: var(--bg-secondary);
  }

  .card-header .model-label {
    font-family: var(--font-mono);
    font-size: 1rem;
    font-weight: 600;
    color: var(--blue);
  }

  .card-header .timing {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: var(--text-muted);
  }

  .card-body { padding: 1.25rem; }

  .section-label {
    font-family: var(--font-mono);
    font-size: 0.7rem;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--text-muted);
    margin-bottom: 0.4rem;
  }

  .reasoning-block {
    background: var(--bg-primary);
    border: 1px solid var(--border);
    border-radius: 0.4rem;
    padding: 1rem;
    font-family: var(--font-mono);
    font-size: 0.78rem;
    line-height: 1.5;
    color: var(--text-secondary);
    white-space: pre-wrap;
    word-break: break-word;
    max-height: 20rem;
    overflow-y: auto;
    margin-bottom: 1rem;
  }

  .reasoning-block::-webkit-scrollbar { width: 6px; }
  .reasoning-block::-webkit-scrollbar-track { background: var(--bg-primary); }
  .reasoning-block::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }

  .action-block {
    background: var(--green-dim);
    border: 1px solid rgba(63, 185, 80, 0.3);
    border-radius: 0.4rem;
    padding: 0.75rem 1rem;
    font-family: var(--font-mono);
    font-size: 0.85rem;
    color: var(--green);
    margin-bottom: 1rem;
  }

  .state-changes {
    list-style: none;
    margin-bottom: 0.75rem;
  }

  .state-changes li {
    font-family: var(--font-mono);
    font-size: 0.78rem;
    color: var(--text-secondary);
    padding: 0.15rem 0;
  }

  .state-changes li::before {
    content: '\2192 ';
    color: var(--orange);
  }

  .treasury-after {
    font-family: var(--font-mono);
    font-size: 0.85rem;
    color: var(--orange);
    padding-top: 0.25rem;
    border-top: 1px solid var(--border);
  }

  /* Ranking UI */
  .ranking-section {
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-radius: 0.75rem;
    padding: 1.5rem;
    margin-bottom: 2rem;
  }

  .ranking-section h3 {
    font-family: var(--font-mono);
    font-size: 1rem;
    color: var(--text-primary);
    margin-bottom: 1rem;
  }

  .ranking-row {
    display: flex;
    align-items: center;
    gap: 1rem;
    margin-bottom: 0.75rem;
    padding: 0.5rem 0.75rem;
    background: var(--bg-card);
    border: 1px solid var(--border);
    border-radius: 0.4rem;
  }

  .ranking-row label {
    font-family: var(--font-mono);
    font-size: 0.9rem;
    color: var(--blue);
    min-width: 6rem;
  }

  .ranking-row select {
    background: var(--bg-primary);
    color: var(--text-primary);
    border: 1px solid var(--border);
    border-radius: 0.3rem;
    padding: 0.4rem 0.75rem;
    font-family: var(--font-mono);
    font-size: 0.85rem;
    cursor: pointer;
  }

  .ranking-row select:focus {
    outline: none;
    border-color: var(--green);
  }

  .btn {
    background: var(--green);
    color: var(--bg-primary);
    border: none;
    border-radius: 0.4rem;
    padding: 0.65rem 1.5rem;
    font-family: var(--font-mono);
    font-size: 0.85rem;
    font-weight: 600;
    cursor: pointer;
    transition: opacity 0.15s ease;
  }

  .btn:hover { opacity: 0.85; }
  .btn:disabled { opacity: 0.4; cursor: not-allowed; }

  .btn-secondary {
    background: var(--bg-card);
    color: var(--text-primary);
    border: 1px solid var(--border);
  }

  .btn-reveal {
    background: var(--orange);
    font-size: 1rem;
    padding: 0.8rem 2.5rem;
    margin-top: 1rem;
  }

  .nav-buttons {
    display: flex;
    gap: 1rem;
    justify-content: center;
    margin-bottom: 2rem;
  }

  /* Results / Reveal */
  .reveal-section {
    display: none;
  }

  .reveal-section.visible { display: block; }

  .leaderboard {
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-radius: 0.75rem;
    overflow: hidden;
    margin-bottom: 2rem;
  }

  .leaderboard-header {
    padding: 1rem 1.5rem;
    background: var(--bg-card);
    border-bottom: 1px solid var(--border);
  }

  .leaderboard-header h3 {
    font-family: var(--font-mono);
    font-size: 1.1rem;
    color: var(--green);
  }

  .leaderboard-row {
    display: grid;
    grid-template-columns: 3rem 1fr 6rem 6rem;
    padding: 0.75rem 1.5rem;
    border-bottom: 1px solid var(--border);
    align-items: center;
  }

  .leaderboard-row:last-child { border-bottom: none; }

  .leaderboard-row.header-row {
    background: var(--bg-card);
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--text-muted);
    font-family: var(--font-mono);
  }

  .leaderboard-row .rank {
    font-family: var(--font-mono);
    font-size: 1.2rem;
    font-weight: 700;
    color: var(--orange);
  }

  .leaderboard-row .rank.gold { color: #ffd700; }
  .leaderboard-row .rank.silver { color: #c0c0c0; }
  .leaderboard-row .rank.bronze { color: #cd7f32; }

  .leaderboard-row .model-name {
    font-family: var(--font-mono);
    font-size: 0.95rem;
    color: var(--text-primary);
  }

  .leaderboard-row .avg-rank,
  .leaderboard-row .wins {
    font-family: var(--font-mono);
    font-size: 0.9rem;
    color: var(--text-secondary);
    text-align: center;
  }

  .epoch-breakdown {
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-radius: 0.75rem;
    overflow: hidden;
  }

  .epoch-breakdown-header {
    padding: 1rem 1.5rem;
    background: var(--bg-card);
    border-bottom: 1px solid var(--border);
  }

  .epoch-breakdown-header h3 {
    font-family: var(--font-mono);
    font-size: 1rem;
    color: var(--text-primary);
  }

  .breakdown-row {
    display: flex;
    gap: 1rem;
    padding: 0.75rem 1.5rem;
    border-bottom: 1px solid var(--border);
    font-family: var(--font-mono);
    font-size: 0.85rem;
    align-items: center;
  }

  .breakdown-row:last-child { border-bottom: none; }

  .breakdown-row .epoch-label {
    min-width: 5rem;
    color: var(--text-muted);
  }

  .breakdown-row .model-rank {
    padding: 0.2rem 0.6rem;
    border-radius: 0.25rem;
    font-size: 0.8rem;
  }

  .breakdown-row .model-rank.winner {
    background: var(--green-dim);
    color: var(--green);
    border: 1px solid rgba(63, 185, 80, 0.3);
  }

  .breakdown-row .model-rank.loser {
    background: var(--bg-card);
    color: var(--text-secondary);
    border: 1px solid var(--border);
  }

  .status-message {
    text-align: center;
    font-family: var(--font-mono);
    font-size: 0.85rem;
    color: var(--text-muted);
    padding: 1rem;
  }
</style>
</head>
<body>

<div class="header">
  <h1>THE HUMAN FUND // MODEL ARENA</h1>
  <div class="meta" id="headerMeta"></div>
</div>

<div class="container">
  <!-- Arena View -->
  <div id="arenaView">
    <div class="progress-bar" id="progressBar"></div>

    <div class="epoch-header" id="epochHeader">
      <h2 id="epochTitle"></h2>
    </div>

    <div class="context-preview" id="contextPreview" onclick="this.classList.toggle('expanded')"></div>

    <div class="model-cards" id="modelCards"></div>

    <div class="ranking-section" id="rankingSection">
      <h3>Rank the outputs (1 = best)</h3>
      <div id="rankingRows"></div>
      <div style="display:flex; gap:1rem; margin-top:1rem; align-items:center;">
        <button class="btn" id="submitRankBtn" onclick="submitRanking()">Submit Ranking</button>
        <span class="status-message" id="rankStatus"></span>
      </div>
    </div>

    <div class="nav-buttons">
      <button class="btn btn-secondary" id="prevBtn" onclick="navigateEpoch(-1)">Previous</button>
      <button class="btn btn-secondary" id="nextBtn" onclick="navigateEpoch(1)">Next</button>
    </div>

    <div style="text-align:center; margin-top:1rem;">
      <button class="btn btn-reveal" id="revealBtn" onclick="revealResults()" style="display:none;">
        Reveal Results
      </button>
    </div>
  </div>

  <!-- Results View (hidden until reveal) -->
  <div class="reveal-section" id="revealView">
    <div class="leaderboard" id="leaderboard"></div>
    <div class="epoch-breakdown" id="epochBreakdown"></div>
    <div style="text-align:center; margin-top:2rem;">
      <button class="btn btn-secondary" onclick="backToArena()">Back to Arena</button>
    </div>
  </div>
</div>

<script>
let data = null;
let rankings = {};  // epoch_num -> { model_key: rank }
let currentEpoch = 0;
let shuffleMap = {};  // epoch_num -> shuffled order of model keys

async function init() {
  const resp = await fetch('/api/data');
  data = await resp.json();

  // Try to load saved rankings
  try {
    const savedResp = await fetch('/api/rankings');
    if (savedResp.ok) {
      const saved = await savedResp.json();
      if (saved && saved.rankings) {
        rankings = saved.rankings;
      }
    }
  } catch(e) {}

  // Build shuffle map with deterministic seed per epoch
  const modelKeys = Object.keys(data.model_map);
  data.epochs.forEach((ep, idx) => {
    // Shuffle using epoch_num as seed (Fisher-Yates with seeded random)
    const keys = [...modelKeys];
    let seed = ep.epoch_num * 31337 + idx * 7;
    for (let i = keys.length - 1; i > 0; i--) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      const j = seed % (i + 1);
      [keys[i], keys[j]] = [keys[j], keys[i]];
    }
    shuffleMap[ep.epoch_num] = keys;
  });

  // Header meta
  document.getElementById('headerMeta').textContent =
    `${data.metadata.models.length} models | ${data.metadata.epochs} epochs | ${data.metadata.initial_treasury}`;

  buildProgressBar();
  renderEpoch(0);
}

function buildProgressBar() {
  const bar = document.getElementById('progressBar');
  bar.innerHTML = '';
  data.epochs.forEach((ep, idx) => {
    const dot = document.createElement('div');
    dot.className = 'progress-dot' + (idx === currentEpoch ? ' active' : '');
    if (rankings[ep.epoch_num]) dot.classList.add('ranked');
    dot.textContent = ep.epoch_num;
    dot.onclick = () => { currentEpoch = idx; renderEpoch(idx); };
    bar.appendChild(dot);
  });
}

function renderEpoch(idx) {
  currentEpoch = idx;
  const ep = data.epochs[idx];
  const modelKeys = Object.keys(data.model_map);
  const shuffledKeys = shuffleMap[ep.epoch_num];

  // Update progress bar
  buildProgressBar();

  // Epoch header
  document.getElementById('epochTitle').textContent =
    `Epoch ${ep.epoch_num} (${idx + 1} of ${data.epochs.length})`;

  // Context preview
  document.getElementById('contextPreview').textContent = ep.context_preview || 'No context available';
  document.getElementById('contextPreview').classList.remove('expanded');

  // Model cards
  const cardsContainer = document.getElementById('modelCards');
  cardsContainer.innerHTML = '';

  // Display labels: Model A, Model B, etc. in shuffled order
  shuffledKeys.forEach((key, displayIdx) => {
    const result = ep.results[key];
    if (!result) return;

    const displayLabel = `Model ${String.fromCharCode(65 + displayIdx)}`;

    const card = document.createElement('div');
    card.className = 'model-card';
    card.innerHTML = `
      <div class="card-header">
        <span class="model-label">${displayLabel}</span>
        <span class="timing">${result.elapsed_seconds}s</span>
      </div>
      <div class="card-body">
        <div class="section-label">Reasoning</div>
        <div class="reasoning-block">${escapeHtml(result.reasoning)}</div>

        <div class="section-label">Action</div>
        <div class="action-block">${escapeHtml(result.action_display)}</div>

        <div class="section-label">State Changes</div>
        <ul class="state-changes">
          ${result.state_changes.map(c => `<li>${escapeHtml(c)}</li>`).join('')}
        </ul>

        <div class="treasury-after">Treasury: ${result.treasury_after}</div>
      </div>
    `;
    cardsContainer.appendChild(card);
  });

  // Ranking rows
  const rankingRows = document.getElementById('rankingRows');
  rankingRows.innerHTML = '';
  const existingRanking = rankings[ep.epoch_num] || {};

  shuffledKeys.forEach((key, displayIdx) => {
    const displayLabel = `Model ${String.fromCharCode(65 + displayIdx)}`;
    const row = document.createElement('div');
    row.className = 'ranking-row';

    let options = '<option value="">--</option>';
    for (let r = 1; r <= modelKeys.length; r++) {
      const selected = existingRanking[key] === r ? ' selected' : '';
      options += `<option value="${r}"${selected}>${r}</option>`;
    }

    row.innerHTML = `
      <label>${displayLabel}</label>
      <select data-model-key="${key}" onchange="updateRankStatus()">
        ${options}
      </select>
    `;
    rankingRows.appendChild(row);
  });

  // Nav buttons
  document.getElementById('prevBtn').disabled = idx === 0;
  document.getElementById('nextBtn').disabled = idx === data.epochs.length - 1;

  // Show reveal button if all epochs ranked
  updateRevealButton();
  updateRankStatus();
}

function updateRankStatus() {
  const selects = document.querySelectorAll('#rankingRows select');
  const values = Array.from(selects).map(s => parseInt(s.value)).filter(v => !isNaN(v));
  const modelCount = Object.keys(data.model_map).length;

  const statusEl = document.getElementById('rankStatus');
  if (values.length === 0) {
    statusEl.textContent = '';
    return;
  }

  // Check for duplicate ranks
  const uniqueValues = new Set(values);
  if (values.length === modelCount && uniqueValues.size < modelCount) {
    statusEl.textContent = 'Duplicate ranks detected — each model needs a unique rank';
    statusEl.style.color = 'var(--red)';
  } else if (values.length < modelCount) {
    statusEl.textContent = `${modelCount - values.length} model(s) still need a rank`;
    statusEl.style.color = 'var(--text-muted)';
  } else {
    statusEl.textContent = 'Ready to submit';
    statusEl.style.color = 'var(--green)';
  }
}

function submitRanking() {
  const ep = data.epochs[currentEpoch];
  const selects = document.querySelectorAll('#rankingRows select');
  const modelCount = Object.keys(data.model_map).length;

  const ranking = {};
  let valid = true;
  const values = [];

  selects.forEach(s => {
    const key = s.dataset.modelKey;
    const val = parseInt(s.value);
    if (isNaN(val)) { valid = false; return; }
    ranking[key] = val;
    values.push(val);
  });

  if (!valid || values.length !== modelCount) {
    document.getElementById('rankStatus').textContent = 'Please rank all models before submitting';
    document.getElementById('rankStatus').style.color = 'var(--red)';
    return;
  }

  // Check for duplicates
  if (new Set(values).size !== values.length) {
    document.getElementById('rankStatus').textContent = 'Each model needs a unique rank';
    document.getElementById('rankStatus').style.color = 'var(--red)';
    return;
  }

  rankings[ep.epoch_num] = ranking;

  // Save to server
  fetch('/api/rankings', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ rankings })
  });

  document.getElementById('rankStatus').textContent = 'Ranking saved';
  document.getElementById('rankStatus').style.color = 'var(--green)';

  buildProgressBar();
  updateRevealButton();

  // Auto-advance to next unranked epoch
  setTimeout(() => {
    const nextUnranked = data.epochs.findIndex((ep, idx) => idx > currentEpoch && !rankings[ep.epoch_num]);
    if (nextUnranked !== -1) {
      renderEpoch(nextUnranked);
    }
  }, 600);
}

function updateRevealButton() {
  const allRanked = data.epochs.every(ep => rankings[ep.epoch_num]);
  document.getElementById('revealBtn').style.display = allRanked ? 'inline-block' : 'none';
}

function navigateEpoch(dir) {
  const next = currentEpoch + dir;
  if (next >= 0 && next < data.epochs.length) {
    renderEpoch(next);
  }
}

async function revealResults() {
  const resp = await fetch('/api/reveal');
  const reveal = await resp.json();

  document.getElementById('arenaView').style.display = 'none';
  document.getElementById('revealView').classList.add('visible');

  // Build leaderboard
  const lb = document.getElementById('leaderboard');
  const sorted = reveal.leaderboard.sort((a, b) => a.avg_rank - b.avg_rank);
  const rankColors = ['gold', 'silver', 'bronze'];

  lb.innerHTML = `
    <div class="leaderboard-header"><h3>Leaderboard</h3></div>
    <div class="leaderboard-row header-row">
      <span>#</span><span>Model</span><span>Avg Rank</span><span>Wins</span>
    </div>
    ${sorted.map((entry, idx) => `
      <div class="leaderboard-row">
        <span class="rank ${rankColors[idx] || ''}">${idx + 1}</span>
        <span class="model-name">${escapeHtml(entry.model_name)}</span>
        <span class="avg-rank">${entry.avg_rank.toFixed(2)}</span>
        <span class="wins">${entry.wins}</span>
      </div>
    `).join('')}
  `;

  // Build per-epoch breakdown
  const bd = document.getElementById('epochBreakdown');
  bd.innerHTML = `
    <div class="epoch-breakdown-header"><h3>Per-Epoch Breakdown</h3></div>
    ${reveal.per_epoch.map(ep => {
      const entries = ep.results.sort((a, b) => a.rank - b.rank);
      return `
        <div class="breakdown-row">
          <span class="epoch-label">Epoch ${ep.epoch_num}</span>
          ${entries.map(e => `
            <span class="model-rank ${e.rank === 1 ? 'winner' : 'loser'}">
              #${e.rank} ${escapeHtml(e.model_name)}: ${escapeHtml(e.action_display)}
            </span>
          `).join('')}
        </div>
      `;
    }).join('')}
  `;
}

function backToArena() {
  document.getElementById('arenaView').style.display = 'block';
  document.getElementById('revealView').classList.remove('visible');
}

function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text || '';
  return div.innerHTML;
}

window.addEventListener('DOMContentLoaded', init);
</script>
</body>
</html>"""


class ArenaHandler(BaseHTTPRequestHandler):
    """HTTP handler for the review UI."""

    results_data = None
    rankings_data = {}
    rankings_file = None

    def log_message(self, format, *args):
        # Suppress default logging
        pass

    def do_GET(self):
        if self.path == "/" or self.path == "/index.html":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(REVIEW_HTML.encode("utf-8"))

        elif self.path == "/api/data":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(self.results_data).encode("utf-8"))

        elif self.path == "/api/rankings":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"rankings": ArenaHandler.rankings_data}).encode("utf-8"))

        elif self.path == "/api/reveal":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            reveal = self._compute_reveal()
            self.wfile.write(json.dumps(reveal).encode("utf-8"))

        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/api/rankings":
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
            ArenaHandler.rankings_data = body.get("rankings", {})

            # Persist rankings to disk
            if ArenaHandler.rankings_file:
                try:
                    Path(ArenaHandler.rankings_file).write_text(
                        json.dumps(ArenaHandler.rankings_data, indent=2)
                    )
                except Exception:
                    pass

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok": true}')
        else:
            self.send_response(404)
            self.end_headers()

    def _compute_reveal(self):
        """Compute leaderboard and per-epoch breakdown."""
        model_map = self.results_data["model_map"]
        model_keys = list(model_map.keys())
        rankings = ArenaHandler.rankings_data

        # Aggregate scores
        scores = {key: {"ranks": [], "wins": 0} for key in model_keys}

        per_epoch = []
        for ep in self.results_data["epochs"]:
            epoch_num = str(ep["epoch_num"])
            ep_rankings = rankings.get(epoch_num, rankings.get(int(epoch_num), {}))

            epoch_results = []
            for key in model_keys:
                rank = ep_rankings.get(key, len(model_keys))
                scores[key]["ranks"].append(rank)
                if rank == 1:
                    scores[key]["wins"] += 1
                epoch_results.append({
                    "model_key": key,
                    "model_name": model_map[key],
                    "rank": rank,
                    "action_display": ep["results"].get(key, {}).get("action_display", "?"),
                })

            per_epoch.append({
                "epoch_num": ep["epoch_num"],
                "results": epoch_results,
            })

        leaderboard = []
        for key in model_keys:
            ranks = scores[key]["ranks"]
            avg = sum(ranks) / len(ranks) if ranks else 0
            leaderboard.append({
                "model_key": key,
                "model_name": model_map[key],
                "avg_rank": avg,
                "wins": scores[key]["wins"],
            })

        return {
            "leaderboard": leaderboard,
            "per_epoch": per_epoch,
            "model_map": model_map,
        }


def run_review(args):
    """Start the review UI server."""
    input_path = Path(args.input)
    if not input_path.exists():
        print(f"ERROR: Results file not found: {input_path}")
        sys.exit(1)

    data = json.loads(input_path.read_text())
    ArenaHandler.results_data = data

    # Load saved rankings if they exist
    rankings_file = input_path.with_suffix(".rankings.json")
    ArenaHandler.rankings_file = str(rankings_file)
    if rankings_file.exists():
        try:
            ArenaHandler.rankings_data = json.loads(rankings_file.read_text())
            print(f"Loaded saved rankings from {rankings_file}")
        except Exception:
            pass

    port = args.port
    server = HTTPServer(("", port), ArenaHandler)

    print(f"\nModel Arena — Review UI")
    print(f"Models: {', '.join(data['metadata']['models'])}")
    print(f"Epochs: {data['metadata']['epochs']}")
    print(f"\nOpen in browser: http://localhost:{port}")
    print(f"Press Ctrl+C to stop\n")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")
        server.server_close()


# ─── CLI ─────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="The Human Fund — Model Comparison Arena",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Run two models through 5 epochs
  python scripts/arena.py run \\
      --models ds-70b:http://localhost:8080,qwen-14b:http://localhost:8081

  # Review results in browser
  python scripts/arena.py review --input arena_results.json
        """,
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    # Run subcommand
    run_parser = subparsers.add_parser("run", help="Run models through simulation epochs")
    run_parser.add_argument(
        "--models", required=True,
        help="Comma-separated model configs as name:url (e.g., ds-70b:http://localhost:8080,qwen-14b:http://localhost:8081)"
    )
    run_parser.add_argument("--epochs", type=int, default=5, help="Number of simulation epochs (default: 5)")
    run_parser.add_argument("--treasury", type=float, default=0.5, help="Initial treasury in ETH (default: 0.5)")
    run_parser.add_argument("--output", type=str, default="arena_results.json", help="Output JSON file (default: arena_results.json)")

    # Review subcommand
    review_parser = subparsers.add_parser("review", help="Review results in browser UI")
    review_parser.add_argument("--input", type=str, default="arena_results.json", help="Results JSON file (default: arena_results.json)")
    review_parser.add_argument("--port", type=int, default=8888, help="HTTP port for UI (default: 8888)")

    args = parser.parse_args()

    if args.command == "run":
        run_arena(args)
    elif args.command == "review":
        run_review(args)


if __name__ == "__main__":
    main()
