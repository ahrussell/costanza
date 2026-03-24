#!/usr/bin/env python3
"""Action encoding — parse model output and encode to contract byte format.

The model outputs JSON actions like {"action": "donate", "params": {"nonprofit_id": 1, "amount_eth": 0.05}}.
This module parses various output formats (JSON, function-call syntax) and encodes
them to the contract's byte format: uint8 type + ABI-encoded parameters.

No bounds clamping — the enclave faithfully encodes whatever the model outputs.
If the action is out of bounds, the contract will noop and record the attempted
action in the epoch history. The prover still gets paid.
"""

import json
import re


# Protocol name -> ID mapping for when the model outputs names instead of IDs
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
    cleaned = re.sub(r'[^\d.\-]', '', s)
    return cleaned if cleaned else "0"


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
