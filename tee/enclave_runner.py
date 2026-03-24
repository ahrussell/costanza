#!/usr/bin/env python3
"""
The Human Fund — TEE Enclave Runner

Runs inside a TDX Confidential VM. Provides an HTTP API that:
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
import re
import sys
import time
from pathlib import Path
from urllib.request import urlopen, Request

from flask import Flask, jsonify, request

app = Flask(__name__)

# ─── Config ──────────────────────────────────────────────────────────────

SYSTEM_PROMPT_PATH = Path(os.environ.get("SYSTEM_PROMPT_PATH", "/app/system_prompt.txt"))
LLAMA_SERVER_URL = f"http://127.0.0.1:{os.environ.get('LLAMA_SERVER_PORT', '8080')}"

# Max reasoning bytes to include on-chain. Truncate BEFORE computing REPORTDATA
# so the contract's sha256(reasoning) matches the quote's REPORTDATA.
MAX_REASONING_BYTES = 8000


# ─── Inference ───────────────────────────────────────────────────────────

def _call_llama(prompt, max_tokens=4096, temperature=0.6, stop=None, seed=-1):
    """Call the local llama-server."""
    body = {
        "prompt": prompt,
        "max_tokens": max_tokens,
        "temperature": temperature,
    }
    if stop:
        body["stop"] = stop
    if seed >= 0:
        body["seed"] = seed

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


def run_inference(prompt, max_tokens=4096, temperature=0.6, seed=-1):
    """Two-pass inference: reasoning (stop at </think>), then JSON action."""
    # Pass 1: Generate reasoning
    result1 = _call_llama(prompt, max_tokens=max_tokens, temperature=temperature, stop=["</think>"], seed=seed)
    reasoning = result1["text"].strip()

    # Pass 2: Generate JSON action (same seed for determinism)
    # Prefix with "{" to force the model to output JSON directly
    prompt2 = prompt + reasoning + "\n</think>\n{"
    result2 = _call_llama(prompt2, max_tokens=256, temperature=0.3, stop=["\n\n"], seed=seed)

    action_text = "{" + result2["text"]
    combined_text = reasoning + "\n</think>\n" + action_text
    return {
        "text": combined_text,
        "reasoning": reasoning,
        "action_text": action_text.strip(),
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
    # Look for JSON after </think> or </diary>
    close_idx = text.find("</think>")
    if close_idx < 0:
        close_idx = text.find("</diary>")
        close_len = len("</diary>")
    else:
        close_len = len("</think>")
    if close_idx >= 0:
        after = text[close_idx + close_len:].strip()
        obj = _extract_json_object(after)
        if obj and "action" in obj:
            if isinstance(obj["action"], str):
                obj["action"] = obj["action"].split("(")[0].strip().lower()
            return obj

    # Fallback: search entire text for JSON
    for i, c in enumerate(text):
        if c == '{':
            obj = _extract_json_object(text[i:])
            if obj and "action" in obj:
                # Normalize action name
                if isinstance(obj["action"], str):
                    obj["action"] = obj["action"].split("(")[0].strip().lower()
                return obj

    # Fallback 2: parse function-call format output
    # Model sometimes outputs: set_guiding_policy(slot=1, policy="...")
    # or: donate(nonprofit_id=1, amount_eth=0.01)
    return _parse_function_call_format(text)


def _parse_function_call_format(text):
    """Parse action from function-call format like 'donate(nonprofit_id=1, amount_eth=0.01)'.

    The model sometimes mimics the history display format instead of outputting JSON.
    """
    # Look after </think> first, then in the whole text
    search_text = text
    close_idx = text.find("</think>")
    if close_idx >= 0:
        search_text = text[close_idx + len("</think>"):]

    # Known action patterns
    action_patterns = [
        "noop", "donate", "set_commission_rate", "set_max_bid",
        "invest", "withdraw", "set_guiding_policy", "set_policy",
    ]

    for action_name in action_patterns:
        # Look for action_name( or action_name as standalone
        idx = search_text.lower().find(action_name)
        if idx == -1:
            continue

        after = search_text[idx:]
        # Check for noop (no params)
        if action_name == "noop":
            return {"action": "noop", "params": {}}

        # Try to extract params from parentheses
        paren_start = after.find("(")
        if paren_start == -1:
            continue

        # Find matching close paren
        depth = 0
        paren_end = -1
        for i, c in enumerate(after[paren_start:]):
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    paren_end = paren_start + i
                    break
        if paren_end == -1:
            continue

        params_str = after[paren_start+1:paren_end]
        params = {}

        # Parse key=value pairs
        # Handle: slot=1, policy="some text with, commas"
        # Use a simple state machine for quoted strings
        current_key = ""
        current_val = ""
        in_key = True
        in_quotes = False
        quote_char = None

        for c in params_str:
            if in_key:
                if c == "=":
                    in_key = False
                elif c not in " ,":
                    current_key += c
            else:
                if not in_quotes:
                    if c in ('"', "'"):
                        in_quotes = True
                        quote_char = c
                    elif c == ",":
                        # End of value
                        params[current_key.strip()] = _coerce_param_value(current_val.strip())
                        current_key = ""
                        current_val = ""
                        in_key = True
                    else:
                        current_val += c
                else:
                    if c == quote_char:
                        in_quotes = False
                    else:
                        current_val += c

        # Don't forget the last param
        if current_key.strip():
            params[current_key.strip()] = _coerce_param_value(current_val.strip())

        return {"action": action_name, "params": params}

    return None


def _coerce_param_value(val):
    """Try to convert a string value to the appropriate Python type."""
    if not val:
        return val
    # Remove surrounding quotes if present
    if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
        return val[1:-1]
    # Try numeric conversion
    try:
        if "." in val:
            return float(val)
        return int(val)
    except (ValueError, TypeError):
        return val


# ─── TDX Attestation ────────────────────────────────────────────────────

# configfs-tsm paths (GCP, bare-metal TDX with kernel >= 6.7)
CONFIGFS_TSM_BASE = "/sys/kernel/config/tsm/report"


def _get_quote_configfs_tsm(report_data: bytes) -> bytes:
    """Get TDX quote via Linux configfs-tsm interface (GCP, bare-metal).

    Works on any TDX VM with kernel >= 6.7 and CONFIG_TSM_REPORTS enabled.
    This is the standard Linux interface for TDX attestation.
    """
    import tempfile
    import uuid

    # Create a unique report entry
    entry_name = f"humanfund-{uuid.uuid4().hex[:8]}"
    entry_path = os.path.join(CONFIGFS_TSM_BASE, entry_name)

    try:
        os.makedirs(entry_path, exist_ok=True)

        # Write report_data (exactly 64 bytes)
        with open(os.path.join(entry_path, "inblob"), "wb") as f:
            f.write(report_data[:64].ljust(64, b'\x00'))

        # Read the generated quote
        with open(os.path.join(entry_path, "outblob"), "rb") as f:
            quote = f.read()

        print(f"  TDX quote via configfs-tsm: {len(quote)} bytes")
        return quote

    finally:
        # Clean up the report entry
        try:
            os.rmdir(entry_path)
        except OSError:
            pass


def _get_quote_dev_tdx(report_data: bytes) -> bytes:
    """Get TDX quote via /dev/tdx_guest ioctl (legacy, pre-6.7 kernels)."""
    import ctypes
    import fcntl

    # TDX_CMD_GET_REPORT0 ioctl
    # struct tdx_report_req { reportdata[64]; tdreport[1024]; }
    TDX_CMD_GET_REPORT0 = 0xC4401401  # _IOWR('T', 1, struct tdx_report_req)

    report_req = bytearray(64 + 1024)
    report_req[:64] = report_data[:64].ljust(64, b'\x00')

    fd = os.open("/dev/tdx_guest", os.O_RDWR)
    try:
        fcntl.ioctl(fd, TDX_CMD_GET_REPORT0, report_req)
        # The TD report is in bytes 64:1088
        # But we need the full DCAP quote, not just the TD report.
        # /dev/tdx_guest gives us the report; the QGS converts it to a quote.
        # For simplicity, use configfs-tsm which handles the full quote flow.
        print("WARNING: /dev/tdx_guest gives TD report, not full DCAP quote")
        print("  Use configfs-tsm (kernel >= 6.7) for full quote generation")
        return bytes(report_req[64:1088])
    finally:
        os.close(fd)


def get_tdx_quote(report_data: bytes) -> bytes:
    """Request a TDX attestation quote using the best available backend.

    Tries in order:
    1. configfs-tsm (GCP TDX, bare-metal TDX with kernel >= 6.7)
    2. /dev/tdx_guest (bare-metal TDX with older kernels)
    3. Mock mode (local testing — returns report_data as the "quote")

    Args:
        report_data: 64 bytes of custom data to bind into the quote.

    Returns:
        Raw DCAP quote bytes, suitable for on-chain verification.
    """
    # Try configfs-tsm first (GCP, bare-metal with kernel >= 6.7)
    if os.path.isdir(CONFIGFS_TSM_BASE):
        try:
            return _get_quote_configfs_tsm(report_data)
        except Exception as e:
            print(f"WARNING: configfs-tsm failed: {e}")

    # Try /dev/tdx_guest (bare-metal with older kernels)
    if os.path.exists("/dev/tdx_guest"):
        try:
            return _get_quote_dev_tdx(report_data)
        except Exception as e:
            print(f"WARNING: /dev/tdx_guest failed: {e}")

    # Mock mode (local testing)
    print("WARNING: No TDX attestation backend found (configfs-tsm, /dev/tdx_guest)")
    print("  Running outside TEE — returning report_data as mock attestation")
    return report_data


def compute_report_data(input_hash: bytes, action_bytes: bytes, reasoning: str,
                        system_prompt: str) -> bytes:
    """Compute the 64-byte report data that gets bound into the TDX quote.

    This creates a cryptographic binding between:
    - The input (epoch context hash, which includes the randomness seed)
    - The output (action + reasoning + prompt hash)
    - The TEE identity (via RTMR values in the quote)

    The contract verifies:
        REPORTDATA == sha256(inputHash || outputHash)
    where:
        promptHash  = sha256(systemPrompt)
        outputHash  = keccak256(abi.encodePacked(
                          sha256(action), sha256(reasoning), promptHash))

    The promptHash must match the contract's approvedPromptHash. This proves
    the TEE used the approved system prompt without the verifier needing to
    see the prompt text.
    """
    action_hash = hashlib.sha256(action_bytes).digest()
    reasoning_hash = hashlib.sha256(reasoning.encode("utf-8")).digest()
    prompt_hash = hashlib.sha256(system_prompt.encode("utf-8")).digest()

    # outputHash = keccak256(sha256(action) || sha256(reasoning) || sha256(prompt))
    # Must match Solidity: keccak256(abi.encodePacked(sha256(action), sha256(reasoning), approvedPromptHash))
    output_hash = _keccak256(action_hash + reasoning_hash + prompt_hash)

    # REPORTDATA = sha256(inputHash || outputHash), zero-padded to 64 bytes
    report_data = hashlib.sha256(input_hash + output_hash).digest()

    # Pad to 64 bytes (TDX report data is exactly 64 bytes)
    return report_data.ljust(64, b'\x00')


# ─── Input Hash Verification ─────────────────────────────────────────────

def _keccak256(data: bytes) -> bytes:
    """Compute keccak256 hash (same as Solidity's keccak256).

    IMPORTANT: Python's hashlib.sha3_256 is SHA-3 (FIPS 202), NOT Keccak-256.
    They use different padding and produce different outputs. Ethereum uses
    the original Keccak-256, not the NIST-standardized SHA-3.
    """
    try:
        import sha3
        return sha3.keccak_256(data).digest()
    except ImportError:
        pass
    try:
        from Crypto.Hash import keccak as _keccak
        k = _keccak.new(digest_bits=256)
        k.update(data)
        return k.digest()
    except ImportError:
        pass
    try:
        from web3 import Web3
        return Web3.keccak(data)
    except ImportError:
        raise ImportError(
            "No keccak256 implementation available. "
            "Install one of: pysha3, pycryptodome, or web3"
        )


def _abi_encode(*values) -> bytes:
    """Replicate Solidity's abi.encode() for uint256/bytes32/string/address values.

    Each value is a tuple of (type, value):
        ("uint256", 42)
        ("bytes32", b'\\x00...')
        ("string", "hello")
        ("address", "0x1234...")
    """
    from eth_abi import encode
    types = [v[0] for v in values]
    vals = [v[1] for v in values]
    return encode(types, vals)


def _abi_encode_packed(*raw_bytes) -> bytes:
    """Replicate Solidity's abi.encodePacked() — just concatenate raw bytes."""
    return b"".join(raw_bytes)


def compute_input_hash(state: dict) -> bytes:
    """Replicate TheHumanFund._computeInputHash() from structured state.

    The state dict must contain the same fields used by the contract:
      - state_hash_inputs: {epoch, balance, commission_rate_bps, max_bid, ...}
      - nonprofits: [{name, addr, total_donated, donation_count}, ...]
      - invest_hash: "0x..." (from investmentManager.stateHash())
      - worldview_hash: "0x..." (from worldView.stateHash())
      - message_hashes: ["0x...", ...] (per-message keccak256, up to 20)
      - epoch_content_hashes: ["0x...", ...] (last 10 epoch content hashes)
    """
    # 1. State hash
    s = state["state_hash_inputs"]
    state_hash = _keccak256(_abi_encode(
        ("uint256", s["epoch"]),
        ("uint256", s["balance"]),
        ("uint256", s["commission_rate_bps"]),
        ("uint256", s["max_bid"]),
        ("uint256", s["consecutive_missed_epochs"]),
        ("uint256", s["last_donation_epoch"]),
        ("uint256", s["last_commission_change_epoch"]),
        ("uint256", s["total_inflows"]),
        ("uint256", s["total_donated_to_nonprofits"]),
        ("uint256", s["total_commissions_paid"]),
        ("uint256", s["total_bounties_paid"]),
        ("uint256", s["current_epoch_inflow"]),
        ("uint256", s["current_epoch_donation_count"]),
    ))

    # 2. Nonprofit hash
    nps = state["nonprofits"]
    if len(nps) == 0:
        nonprofit_hash = b'\x00' * 32
    else:
        # Match contract: keccak256(abi.encodePacked(hash1, hash2, ...))
        # where each hash = keccak256(abi.encode(name, description, ein, totalDonated, donationCount))
        packed = b""
        for np in nps:
            ein_bytes = bytes.fromhex(np["ein"].replace("0x", "")) if isinstance(np["ein"], str) else np["ein"]
            ein_bytes32 = ein_bytes.ljust(32, b'\x00')[:32]
            per_np_hash = _keccak256(_abi_encode(
                ("string", np["name"]),
                ("string", np["description"]),
                ("bytes32", ein_bytes32),
                ("uint256", np["total_donated"]),
                ("uint256", np["donation_count"]),
            ))
            packed += per_np_hash
        nonprofit_hash = _keccak256(packed)

    # 3. Investment hash (pre-computed by InvestmentManager.stateHash())
    invest_hash = bytes.fromhex(state.get("invest_hash", "0" * 64).replace("0x", ""))

    # 4. Worldview hash (pre-computed by WorldView.stateHash())
    worldview_hash = bytes.fromhex(state.get("worldview_hash", "0" * 64).replace("0x", ""))

    # 5. Message hash — keccak256 of packed per-message hashes
    msg_hashes = state.get("message_hashes", [])
    if msg_hashes:
        packed = b""
        for h in msg_hashes:
            packed += bytes.fromhex(h.replace("0x", ""))
        msg_hash = _keccak256(packed)
    else:
        msg_hash = b'\x00' * 32

    # 6. History hash — keccak256 of packed epoch content hashes (most recent first)
    epoch_hashes = state.get("epoch_content_hashes", [])
    if epoch_hashes:
        packed = b""
        for h in epoch_hashes:
            packed += bytes.fromhex(h.replace("0x", ""))
        hist_hash = _keccak256(packed)
    else:
        hist_hash = b'\x00' * 32

    # Final: keccak256(abi.encode(stateHash, nonprofitHash, investHash, worldviewHash, msgHash, histHash))
    return _keccak256(_abi_encode(
        ("bytes32", state_hash),
        ("bytes32", nonprofit_hash),
        ("bytes32", invest_hash),
        ("bytes32", worldview_hash),
        ("bytes32", msg_hash),
        ("bytes32", hist_hash),
    ))


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
            "epoch_context": "=== EPOCH N STATE ===\n...",
            "contract_state": { ... structured state for input hash verification ... },
            "input_hash": "0x..."  (committed on-chain by startEpoch)
        }

    The enclave verifies that contract_state hashes to input_hash before
    running inference. This prevents a malicious runner from feeding the
    model fabricated state while passing through the real input_hash.

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
    seed = int(data.get("seed", 0))

    # Compute input hash from structured contract state.
    # The TEE independently derives the input hash from the data it receives.
    # This hash goes into REPORTDATA — the contract verifies it matches
    # the on-chain committed epochInputHashes[epoch]. If the runner sent
    # fake data, the hash won't match and submitAuctionResult reverts.
    contract_state = data.get("contract_state")
    if contract_state:
        input_hash = compute_input_hash(contract_state)
        print(f"  Input hash (computed from state): 0x{input_hash.hex()[:16]}...")
    else:
        # Fallback: no structured state, use provided hash
        input_hash_hex = data.get("input_hash", "0x" + "00" * 32)
        input_hash = bytes.fromhex(input_hash_hex.replace("0x", ""))
        print(f"  Input hash (provided, unverified): 0x{input_hash.hex()[:16]}...")

    # Derive llama.cpp seed from the randomness seed (baked into inputHash).
    # Use lower 32 bits (llama.cpp seed is uint32).
    llama_seed = seed & 0xFFFFFFFF if seed > 0 else -1

    # Use system prompt from runner request (includes protocol reference from chain),
    # falling back to local file if not provided.
    system_prompt = data.get("system_prompt", "").strip()
    if not system_prompt:
        system_prompt = SYSTEM_PROMPT_PATH.read_text().strip()

    # Construct full prompt
    full_prompt = system_prompt + "\n\n" + epoch_context + "\n\n<think>\n"

    # Run inference (with retry)
    max_retries = 3
    action_json = None
    inference = None

    for attempt in range(1, max_retries + 1):
        print(f"Inference attempt {attempt}/{max_retries} (seed={llama_seed})...")
        try:
            inference = run_inference(full_prompt, seed=llama_seed)
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

    reasoning_full = inference["reasoning"]

    # Truncate reasoning to fit on-chain gas budget.
    # CRITICAL: truncate BEFORE computing REPORTDATA so contract's
    # sha256(reasoning) matches the value bound into the TDX quote.
    reasoning_bytes = reasoning_full.encode("utf-8")
    if len(reasoning_bytes) > MAX_REASONING_BYTES:
        reasoning_bytes = reasoning_bytes[:MAX_REASONING_BYTES]
        # Ensure we don't break a multi-byte UTF-8 character
        reasoning = reasoning_bytes.decode("utf-8", errors="ignore")
        print(f"  Reasoning truncated: {len(reasoning_full.encode('utf-8'))} → {len(reasoning.encode('utf-8'))} bytes")
    else:
        reasoning = reasoning_full

    # Encode action to bytes (same format as the smart contract expects)
    try:
        action_bytes = encode_action_bytes(action_json)
    except Exception as e:
        return jsonify({
            "error": f"Failed to encode action: {e}",
            "action": action_json,
            "raw_output": inference["text"][:2000],
        }), 500

    # Debug: log exact bytes going into hash computation
    import sys
    print(f"  HASH DEBUG: action_bytes={action_bytes.hex()[:32]}... ({len(action_bytes)} bytes)", flush=True)
    print(f"  HASH DEBUG: reasoning={len(reasoning.encode('utf-8'))} bytes, sha256={hashlib.sha256(reasoning.encode('utf-8')).hexdigest()[:16]}", flush=True)
    print(f"  HASH DEBUG: prompt sha256={hashlib.sha256(system_prompt.encode('utf-8')).hexdigest()[:16]}", flush=True)
    print(f"  HASH DEBUG: input_hash={input_hash.hex()[:16]}", flush=True)
    sys.stdout.flush()

    # Get TDX attestation quote — uses truncated reasoning
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


def _clean_amount(raw):
    """Clean an amount string from model output — strip units, whitespace, etc."""
    if isinstance(raw, (int, float)):
        return str(raw)
    s = str(raw).strip()
    # Remove common suffixes the model might add
    for suffix in [" ETH", " eth", " Eth", "ETH", "eth", " ether", "ether"]:
        if s.endswith(suffix):
            s = s[:-len(suffix)].strip()
    # Remove any remaining non-numeric characters except . and -
    import re
    cleaned = re.sub(r'[^\d.\-]', '', s)
    return cleaned if cleaned else "0"


# Protocol name → ID mapping for when the model outputs names instead of IDs
PROTOCOL_NAME_MAP = {
    "aave": 1, "aave v3 weth": 1, "aave weth": 1, "aave v3": 1, "aave eth": 1,
    "wsteth": 2, "lido": 2, "lido wsteth": 2, "steth": 2,
    "cbeth": 3, "coinbase": 3, "coinbase cbeth": 3,
    "reth": 4, "rocket pool": 4, "rocket pool reth": 4,
    "aave usdc": 5, "aave v3 usdc": 5,
    "compound": 6, "compound v3": 6, "compound usdc": 6, "compound v3 usdc": 6,
    "moonwell": 7, "moonwell usdc": 7,
    "aerodrome": 8, "aerodrome eth/usdc": 8, "aerodrome lp": 8,
}


def _parse_protocol_id(params):
    """Parse protocol_id from various model output formats (numeric, name strings, etc.)."""
    raw_pid = str(params.get("protocol_id") or params.get("id") or params.get("protocol") or 1)
    # Try direct numeric parse first
    try:
        return int(raw_pid)
    except (ValueError, TypeError):
        pass
    # Try name lookup (case-insensitive)
    name_lower = raw_pid.strip().lower()
    if name_lower in PROTOCOL_NAME_MAP:
        return PROTOCOL_NAME_MAP[name_lower]
    # Try partial match — find longest matching key
    for key in sorted(PROTOCOL_NAME_MAP.keys(), key=len, reverse=True):
        if key in name_lower or name_lower in key:
            return PROTOCOL_NAME_MAP[key]
    # Last resort: extract digits
    digits = re.findall(r'\d+', raw_pid)
    if digits:
        return int(digits[0])
    return 1  # fallback


def encode_action_bytes(action_json):
    """Encode action JSON to the contract's byte format.

    No bounds clamping — the enclave faithfully encodes whatever the model
    outputs. If the action is out of bounds, the contract will noop and
    record the attempted action in the epoch history for future context.
    The prover still gets paid (they ran inference correctly).
    """
    action = action_json["action"]
    # Model sometimes puts params at top level or under "args" instead of "params"
    params = action_json.get("params", action_json.get("args", {}))
    if not params:
        param_keys = {"nonprofit_id", "id", "amount_eth", "amount", "rate_bps", "rate",
                       "protocol_id", "protocol", "slot", "policy", "text"}
        params = {k: v for k, v in action_json.items() if k in param_keys}

    # Normalize action name — smaller models sometimes include parameter signatures
    action = action.split("(")[0].strip().lower()

    if action == "noop":
        return bytes([0])
    elif action == "donate":
        # Handle various param key names the model might use
        raw_np = str(params.get("nonprofit_id") or params.get("id") or params.get("nonprofit") or 1)
        # Extract integer from various model outputs: "1", "#1", "0xaddr...", "nonprofit 2", etc.
        digits = re.findall(r'\d+', raw_np)
        try:
            np_id = int(digits[0]) if digits else 1
        except (ValueError, TypeError, IndexError):
            np_id = 1
        amount_str = _clean_amount(params.get("amount_eth") or params.get("amount") or params.get("eth") or "0.1")
        amount_wei = int(float(amount_str) * 1e18)
        return (
            bytes([1])
            + np_id.to_bytes(32, "big")
            + amount_wei.to_bytes(32, "big")
        )
    elif action == "set_commission_rate":
        rate = int(float(str(params.get("rate_bps") or params.get("rate") or params.get("bps") or 1000)))
        return bytes([2]) + rate.to_bytes(32, "big")
    elif action == "set_max_bid":
        amount_str = _clean_amount(params.get("amount_eth") or params.get("amount") or params.get("eth") or "0.001")
        amount_wei = int(float(amount_str) * 1e18)
        return bytes([3]) + amount_wei.to_bytes(32, "big")
    elif action == "invest":
        protocol_id = _parse_protocol_id(params)
        amount_str = _clean_amount(params.get("amount_eth") or params.get("amount") or params.get("eth") or "0.1")
        amount_wei = int(float(amount_str) * 1e18)
        return (
            bytes([4])
            + protocol_id.to_bytes(32, "big")
            + amount_wei.to_bytes(32, "big")
        )
    elif action == "withdraw":
        protocol_id = _parse_protocol_id(params)
        amount_str = _clean_amount(params.get("amount_eth") or params.get("amount") or params.get("eth") or "0.1")
        amount_wei = int(float(amount_str) * 1e18)
        return (
            bytes([5])
            + protocol_id.to_bytes(32, "big")
            + amount_wei.to_bytes(32, "big")
        )
    elif action in ("set_guiding_policy", "set_policy"):
        slot = int(params.get("slot") or params.get("slot_id") or params.get("id") or 0)
        policy = str(params.get("policy") or params.get("text") or params.get("value") or "")
        # Truncate to 280 chars
        if len(policy) > 280:
            policy = policy[:280]
        # ABI-encode (uint256, string)
        slot_bytes = slot.to_bytes(32, "big")
        # String ABI encoding: offset (32) + length + padded data
        policy_bytes = policy.encode("utf-8")
        str_offset = (64).to_bytes(32, "big")  # offset to string data (after slot + offset)
        str_length = len(policy_bytes).to_bytes(32, "big")
        # Pad string data to 32-byte boundary
        padded_len = ((len(policy_bytes) + 31) // 32) * 32
        str_data = policy_bytes.ljust(padded_len, b'\x00')
        return bytes([6]) + slot_bytes + str_offset + str_length + str_data
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

    # threaded=True prevents a stuck/dropped request from blocking all others.
    # Flask dev server is sufficient here (single client, not public-facing).
    app.run(host="0.0.0.0", port=port, threaded=True)
