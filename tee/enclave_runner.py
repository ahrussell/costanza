#!/usr/bin/env python3
"""
The Human Fund — TEE Enclave Runner (Phase 1)

Runs inside a TDX Confidential VM (Phala Cloud / dstack).
Provides an HTTP API that:
  1. Accepts epoch context (contract state) as input
  2. Constructs the full prompt (system prompt + epoch context)
  3. Runs two-pass inference via the local llama-server
  4. Returns the action, reasoning, and TDX attestation quote

The attestation quote binds the (input_hash, action, reasoning_hash) to
the TEE's identity (RTMR values), proving this exact code + model produced
the output on genuine TDX hardware.

Usage:
    # Inside the TEE container (started by Dockerfile CMD)
    python3 enclave_runner.py

    # External caller (the runner on the operator's machine):
    curl -X POST http://<tee-host>:8090/run_epoch \
      -H "Content-Type: application/json" \
      -d '{"epoch_context": "=== EPOCH 42 STATE ===\n..."}'
"""

import hashlib
import json
import os
import socket
import struct
import sys
import time
from pathlib import Path
from urllib.request import urlopen, Request

from flask import Flask, jsonify, request

app = Flask(__name__)

# ─── Config ──────────────────────────────────────────────────────────────

SYSTEM_PROMPT_PATH = Path(os.environ.get("SYSTEM_PROMPT_PATH", "/app/system_prompt.txt"))
LLAMA_SERVER_URL = f"http://127.0.0.1:{os.environ.get('LLAMA_SERVER_PORT', '8080')}"
DSTACK_SOCK = "/var/run/dstack.sock"          # v0.5.x+
DSTACK_SOCK_LEGACY = "/var/run/tappd.sock"    # v0.3.x fallback


# ─── Inference ───────────────────────────────────────────────────────────

def _call_llama(prompt, max_tokens=4096, temperature=0.6, stop=None):
    """Call the local llama-server."""
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
        headers={"Content-Type": "application/json"},
    )

    start = time.time()
    resp = urlopen(req, timeout=1800)  # CPU inference on 14B can take 20+ min per pass
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
    """Two-pass inference: reasoning (stop at </think>), then JSON action."""
    # Pass 1: Generate reasoning
    result1 = _call_llama(prompt, max_tokens=max_tokens, temperature=temperature, stop=["</think>"])
    reasoning = result1["text"].strip()

    # Pass 2: Generate JSON action
    prompt2 = prompt + reasoning + "\n</think>\n"
    result2 = _call_llama(prompt2, max_tokens=256, temperature=0.3, stop=["\n\n"])

    combined_text = reasoning + "\n</think>\n" + result2["text"]
    return {
        "text": combined_text,
        "reasoning": reasoning,
        "action_text": result2["text"].strip(),
        "elapsed_seconds": result1["elapsed_seconds"] + result2["elapsed_seconds"],
        "tokens": {
            "prompt_tokens": result1["tokens"]["prompt_tokens"] + result2["tokens"]["prompt_tokens"],
            "completion_tokens": result1["tokens"]["completion_tokens"] + result2["tokens"]["completion_tokens"],
        },
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


def parse_action(text):
    """Parse the model's output to extract the action JSON."""
    # Look for JSON after </think>
    close_idx = text.find("</think>")
    if close_idx >= 0:
        after = text[close_idx + len("</think>"):].strip()
        obj = _extract_json_object(after)
        if obj and "action" in obj:
            obj["action"] = obj["action"].split("(")[0].strip().lower()
            return obj

    # Fallback: search entire text
    for i, c in enumerate(text):
        if c == '{':
            obj = _extract_json_object(text[i:])
            if obj and "action" in obj:
                # Normalize action name
                obj["action"] = obj["action"].split("(")[0].strip().lower()
                return obj

    return None


# ─── TDX Attestation ────────────────────────────────────────────────────

def get_tdx_quote(report_data: bytes) -> bytes:
    """Request a TDX attestation quote from dstack via Unix socket.

    Args:
        report_data: 64 bytes of custom data to bind into the quote.
                     We use: SHA256(input_hash || action_bytes || reasoning_hash)

    Returns:
        Raw DCAP quote bytes, suitable for on-chain verification.
    """
    # Find the dstack socket (v0.5.x or legacy v0.3.x)
    sock_path = DSTACK_SOCK
    if not os.path.exists(sock_path):
        sock_path = DSTACK_SOCK_LEGACY
    if not os.path.exists(sock_path):
        print(f"WARNING: dstack socket not found at {DSTACK_SOCK} or {DSTACK_SOCK_LEGACY}")
        print("  Running outside TEE — returning mock attestation")
        return b"MOCK_ATTESTATION_NOT_IN_TEE"

    # dstack v0.5.x+ API: POST /GetQuote on Unix socket
    # Legacy (v0.3.x) used /var/run/tappd.sock and /prpc/Tappd.TdxQuote
    try:
        # Prepare the request — report_data as hex string, max 64 bytes
        request_body = json.dumps({
            "report_data": report_data.hex(),
        }).encode()

        # Connect via Unix socket
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(30)
        sock.connect(sock_path)

        # Send HTTP request over Unix socket
        http_request = (
            f"POST /GetQuote HTTP/1.1\r\n"
            f"Host: localhost\r\n"
            f"Content-Type: application/json\r\n"
            f"Content-Length: {len(request_body)}\r\n"
            f"Connection: close\r\n"
            f"\r\n"
        ).encode() + request_body

        sock.sendall(http_request)

        # Read response
        response = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response += chunk

        sock.close()

        # Parse HTTP response body
        # Response format: {"quote": "<hex>", "event_log": "<json string>"}
        body_start = response.find(b"\r\n\r\n")
        if body_start >= 0:
            body = response[body_start + 4:]
            # Handle chunked transfer encoding
            try:
                result = json.loads(body)
            except json.JSONDecodeError:
                # Try stripping chunked encoding markers
                lines = body.split(b"\r\n")
                body_parts = [lines[i] for i in range(1, len(lines), 2) if lines[i]]
                result = json.loads(b"".join(body_parts))

            quote_hex = result.get("quote", "")
            print(f"  TDX quote obtained: {len(quote_hex) // 2} bytes")
            return bytes.fromhex(quote_hex)
        else:
            print(f"WARNING: Could not parse dstack response")
            return b"ATTESTATION_PARSE_ERROR"

    except Exception as e:
        print(f"WARNING: Failed to get TDX quote: {e}")
        return b"ATTESTATION_ERROR"


def compute_report_data(input_hash: bytes, action_bytes: bytes, reasoning: str) -> bytes:
    """Compute the 64-byte report data that gets bound into the TDX quote.

    This creates a cryptographic binding between:
    - The input (epoch context hash)
    - The output (action + reasoning)
    - The TEE identity (via RTMR values in the quote)

    The smart contract can verify: "this exact input produced this exact output
    inside a genuine TEE running the approved image."
    """
    reasoning_hash = hashlib.sha256(reasoning.encode("utf-8")).digest()
    action_hash = hashlib.sha256(action_bytes).digest()

    # Combine: SHA256(input_hash || action_hash || reasoning_hash)
    combined = hashlib.sha256(
        input_hash + action_hash + reasoning_hash
    ).digest()

    # Pad to 64 bytes (TDX report data is exactly 64 bytes)
    return combined.ljust(64, b'\x00')


# ─── HTTP API ────────────────────────────────────────────────────────────

@app.route("/health", methods=["GET"])
def health():
    """Health check."""
    # Also check if llama-server is ready
    try:
        resp = urlopen(f"{LLAMA_SERVER_URL}/health", timeout=5)
        llama_status = json.loads(resp.read())
    except Exception as e:
        return jsonify({"status": "unhealthy", "llama": str(e)}), 503

    has_tee = os.path.exists(DSTACK_SOCK) or os.path.exists(DSTACK_SOCK_LEGACY)
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
            "epoch_context": "=== EPOCH N STATE ===\n...",
            "input_hash": "0x..."  (optional, for attestation binding)
        }

    Response:
        {
            "reasoning": "...",
            "action": {"action": "...", "params": {...}},
            "action_bytes": "0x...",
            "attestation_quote": "0x...",
            "report_data": "0x...",
            "inference_seconds": 42.1,
            "tokens": {...}
        }
    """
    data = request.get_json()
    if not data or "epoch_context" not in data:
        return jsonify({"error": "Missing epoch_context"}), 400

    epoch_context = data["epoch_context"]
    input_hash_hex = data.get("input_hash", "0x" + "00" * 32)
    input_hash = bytes.fromhex(input_hash_hex.replace("0x", ""))

    # Load system prompt
    system_prompt = SYSTEM_PROMPT_PATH.read_text().strip()

    # Construct full prompt
    full_prompt = system_prompt + "\n\n" + epoch_context + "\n\n<think>\n"

    # Run inference (with retry)
    max_retries = 3
    action_json = None
    inference = None

    for attempt in range(1, max_retries + 1):
        print(f"Inference attempt {attempt}/{max_retries}...")
        try:
            inference = run_inference(full_prompt)
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

    reasoning = inference["reasoning"]

    # Encode action to bytes (same format as the smart contract expects)
    action_bytes = encode_action_bytes(action_json)

    # Get TDX attestation quote
    report_data = compute_report_data(input_hash, action_bytes, reasoning)
    quote = get_tdx_quote(report_data)

    return jsonify({
        "reasoning": reasoning,
        "action": action_json,
        "action_bytes": "0x" + action_bytes.hex(),
        "attestation_quote": "0x" + quote.hex(),
        "report_data": "0x" + report_data.hex(),
        "input_hash": input_hash_hex,
        "inference_seconds": inference["elapsed_seconds"],
        "tokens": inference["tokens"],
    })


def encode_action_bytes(action_json):
    """Encode action JSON to the contract's byte format."""
    action = action_json["action"]
    params = action_json.get("params", {})

    # Normalize action name — smaller models sometimes include parameter signatures
    action = action.split("(")[0].strip().lower()

    if action == "noop":
        return bytes([0])
    elif action == "donate":
        # Handle various param key names the model might use
        np_id = int(params.get("nonprofit_id") or params.get("id") or params.get("nonprofit") or 1)
        amount_str = str(params.get("amount_eth") or params.get("amount") or params.get("eth") or "0.1")
        amount_wei = int(float(amount_str) * 1e18)
        return (
            bytes([1])
            + np_id.to_bytes(32, "big")
            + amount_wei.to_bytes(32, "big")
        )
    elif action == "set_commission_rate":
        rate = int(params.get("rate_bps") or params.get("rate") or params.get("bps") or 1000)
        return bytes([2]) + rate.to_bytes(32, "big")
    elif action == "set_max_bid":
        amount_str = str(params.get("amount_eth") or params.get("amount") or params.get("eth") or "0.001")
        amount_wei = int(float(amount_str) * 1e18)
        return bytes([3]) + amount_wei.to_bytes(32, "big")
    else:
        # Unknown action — fall back to noop
        print(f"WARNING: Unknown action '{action}', falling back to noop")
        return bytes([0])


# ─── Main ────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    port = int(os.environ.get("ENCLAVE_PORT", "8090"))
    print(f"Starting enclave runner on port {port}...")
    print(f"  System prompt: {SYSTEM_PROMPT_PATH}")
    print(f"  Llama server: {LLAMA_SERVER_URL}")
    tee_sock = DSTACK_SOCK if os.path.exists(DSTACK_SOCK) else DSTACK_SOCK_LEGACY
    print(f"  dstack socket: {tee_sock} ({'found' if os.path.exists(tee_sock) else 'NOT FOUND'})")

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

    # threaded=True prevents a stuck/dropped request from blocking all others.
    # Flask dev server is fine for the TEE enclave (single client, not public).
    app.run(host="0.0.0.0", port=port, threaded=True)
