#!/usr/bin/env python3
"""The Human Fund — TEE Enclave Runner

Runs inside a TDX Confidential VM. Provides an HTTP API that:
  1. Accepts epoch state (contract state + system prompt) as input
  2. Verifies input hash independently
  3. Builds the full prompt
  4. Runs two-pass inference via the local llama-server
  5. Returns the action, reasoning, and TDX attestation quote

The attestation quote binds the (input_hash, action, reasoning) to
the TEE's identity (RTMR values), proving this exact code + model produced
the output on genuine TDX hardware.

Usage:
    python3 -m tee.enclave.enclave_runner

    # External caller (via SSH tunnel):
    curl -X POST http://localhost:8090/run_epoch \
      -H "Content-Type: application/json" \
      -d '{"contract_state": {...}, "system_prompt": "...", "seed": 12345}'
"""

import hashlib
import json
import os
import sys
import time
from pathlib import Path
from urllib.request import urlopen

from flask import Flask, jsonify, request

from .inference import run_two_pass_inference, truncate_reasoning
from .action_encoder import parse_action, encode_action_bytes
from .input_hash import compute_input_hash
from .attestation import get_tdx_quote, compute_report_data, CONFIGFS_TSM_BASE
from .prompt_builder import build_full_prompt

app = Flask(__name__)

LLAMA_SERVER_URL = f"http://127.0.0.1:{os.environ.get('LLAMA_SERVER_PORT', '8080')}"


@app.route("/health", methods=["GET"])
def health():
    """Health check — verifies llama-server is ready and TDX is available."""
    try:
        resp = urlopen(f"{LLAMA_SERVER_URL}/health", timeout=5)
        llama_status = json.loads(resp.read())
    except Exception as e:
        return jsonify({"status": "unhealthy", "llama": str(e)}), 503

    has_tee = os.path.isdir(CONFIGFS_TSM_BASE) or os.path.exists("/dev/tdx_guest")
    return jsonify({
        "status": "ok",
        "llama": llama_status,
        "tee": "available" if has_tee else "not_available",
    })


@app.route("/run_epoch", methods=["POST"])
def run_epoch():
    """Execute inference for one epoch.

    Request body:
        {
            "contract_state": { ... structured state for input hash + prompt building ... },
            "epoch_context": "=== EPOCH N STATE ===\\n..."  (pre-built, if not building in TEE),
            "system_prompt": "You are The Human Fund...",
            "seed": 12345,
            "input_hash": "0x..."  (fallback if no contract_state)
        }

    Response:
        {
            "reasoning": "...",
            "action": {"action": "...", "params": {...}},
            "action_bytes": "0x...",
            "attestation_quote": "0x...",
            "report_data": "0x...",
            "input_hash": "0x...",
            "seed": 12345,
            "inference_seconds": 42.1,
            "tokens": {...}
        }
    """
    data = request.get_json()
    if not data:
        return jsonify({"error": "Missing request body"}), 400

    seed = int(data.get("seed", 0))
    llama_seed = seed & 0xFFFFFFFF if seed > 0 else -1

    # Get system prompt (verified via approvedPromptHash on-chain)
    system_prompt = data.get("system_prompt", "").strip()
    if not system_prompt:
        # Fallback to local file
        prompt_path = Path(os.environ.get("SYSTEM_PROMPT_PATH", "/opt/humanfund/system_prompt.txt"))
        if prompt_path.exists():
            system_prompt = prompt_path.read_text().strip()
        else:
            return jsonify({"error": "No system prompt provided and no local file found"}), 400

    # Compute input hash from structured contract state
    contract_state = data.get("contract_state")
    if contract_state:
        input_hash = compute_input_hash(contract_state)
        print(f"  Input hash (computed): 0x{input_hash.hex()[:16]}...")
    else:
        input_hash_hex = data.get("input_hash", "0x" + "00" * 32)
        input_hash = bytes.fromhex(input_hash_hex.replace("0x", ""))
        print(f"  Input hash (provided, unverified): 0x{input_hash.hex()[:16]}...")

    # Get epoch context (pre-built by runner or built from state)
    epoch_context = data.get("epoch_context", "").strip()
    if not epoch_context:
        return jsonify({"error": "Missing epoch_context"}), 400

    # Build full prompt
    full_prompt = build_full_prompt(system_prompt, epoch_context)

    # Run inference with retry
    max_retries = 3
    action_json = None
    inference = None

    for attempt in range(1, max_retries + 1):
        print(f"Inference attempt {attempt}/{max_retries} (seed={llama_seed})...")
        try:
            inference = run_two_pass_inference(full_prompt, seed=llama_seed, llama_url=LLAMA_SERVER_URL)
        except Exception as e:
            print(f"Inference error: {e}")
            if attempt == max_retries:
                return jsonify({"error": f"Inference failed: {e}"}), 500
            continue

        action_json = parse_action(inference["text"])
        if action_json:
            break
        print(f"Attempt {attempt}: could not parse action")

    if not action_json:
        return jsonify({
            "error": "Could not parse action after retries",
            "raw_output": inference["text"][:2000] if inference else None,
        }), 500

    # Truncate reasoning BEFORE hashing
    reasoning = truncate_reasoning(inference["reasoning"])

    # Encode action
    try:
        action_bytes = encode_action_bytes(action_json)
    except Exception as e:
        return jsonify({
            "error": f"Failed to encode action: {e}",
            "action": action_json,
        }), 500

    # Debug: log exact bytes going into hash computation
    print(f"  HASH DEBUG: action_bytes={action_bytes.hex()[:32]}... ({len(action_bytes)} bytes)", flush=True)
    print(f"  HASH DEBUG: reasoning={len(reasoning.encode('utf-8'))} bytes, sha256={hashlib.sha256(reasoning.encode('utf-8')).hexdigest()[:16]}", flush=True)
    print(f"  HASH DEBUG: prompt sha256={hashlib.sha256(system_prompt.encode('utf-8')).hexdigest()[:16]}", flush=True)
    print(f"  HASH DEBUG: input_hash={input_hash.hex()[:16]}", flush=True)
    sys.stdout.flush()

    # Get TDX attestation quote
    report_data = compute_report_data(input_hash, action_bytes, reasoning, system_prompt)
    quote = get_tdx_quote(report_data)

    return jsonify({
        "reasoning": reasoning,
        "action": action_json,
        "action_bytes": "0x" + action_bytes.hex(),
        "attestation_quote": "0x" + quote.hex(),
        "report_data": "0x" + report_data.hex(),
        "input_hash": "0x" + input_hash.hex(),
        "seed": seed,
        "inference_seconds": inference["elapsed_seconds"],
        "tokens": inference["tokens"],
    })


def main():
    port = int(os.environ.get("ENCLAVE_PORT", "8090"))
    host = os.environ.get("ENCLAVE_HOST", "127.0.0.1")
    print(f"Starting enclave runner on {host}:{port}...")
    print(f"  Llama server: {LLAMA_SERVER_URL}")
    has_tee = os.path.isdir(CONFIGFS_TSM_BASE) or os.path.exists("/dev/tdx_guest")
    print(f"  TDX attestation: {'available' if has_tee else 'not available (mock mode)'}")

    # Wait for llama-server to be ready
    print("Waiting for llama-server...")
    for i in range(60):
        try:
            resp = urlopen(f"{LLAMA_SERVER_URL}/health", timeout=5)
            status = json.loads(resp.read())
            if status.get("status") == "ok":
                print(f"  llama-server ready after {i * 5}s")
                break
        except Exception:
            pass
        time.sleep(5)
    else:
        print("WARNING: llama-server not ready after 5 minutes, starting anyway")

    app.run(host=host, port=port, threaded=True)


if __name__ == "__main__":
    main()
