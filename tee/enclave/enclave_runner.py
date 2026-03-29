#!/usr/bin/env python3
"""The Human Fund — TEE Enclave (one-shot)

Runs inside a TDX Confidential VM on a dm-verity protected rootfs.
This is a ONE-SHOT program, not a server. It:
  1. Reads epoch state from the platform-specific input channel
  2. Reads the system prompt from the dm-verity rootfs
  3. Starts llama-server and runs two-pass inference
  4. Generates a TDX attestation quote
  5. Writes the result to the platform-specific output channel
  6. Exits

There is no Flask, no HTTP server, no Docker. The only runner-controlled
input is the epoch state JSON. Everything else (code, model, system prompt)
is on the dm-verity rootfs and immutable.

Input channels (tried in order):
  1. /input/epoch_state.json  (file — most portable)
  2. GCP instance metadata    (cloud-specific fallback)
  3. stdin                    (development/testing)

Output channels (all written):
  1. /output/result.json      (file — most portable)
  2. Serial console           (GCP-readable without SSH)
  3. stdout                   (development/testing)
"""

import hashlib
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

from .inference import run_two_pass_inference, truncate_reasoning
from .action_encoder import parse_action, encode_action_bytes
from .input_hash import compute_input_hash, derive_contract_state, _keccak256
from .attestation import get_tdx_quote, compute_report_data
from .prompt_builder import build_epoch_context, build_full_prompt

# ─── Configuration ──────────────────────────────────────────────────────

MODEL_PATH = os.environ.get("MODEL_PATH", "/models/model.gguf")
SYSTEM_PROMPT_PATH = os.environ.get("SYSTEM_PROMPT_PATH", "/opt/humanfund/system_prompt.txt")
LLAMA_SERVER_PORT = int(os.environ.get("LLAMA_SERVER_PORT", "8080"))
LLAMA_SERVER_URL = f"http://127.0.0.1:{LLAMA_SERVER_PORT}"
LLAMA_SERVER_BIN = os.environ.get("LLAMA_SERVER_BIN", "/opt/humanfund/bin/llama-server")

INPUT_FILE = "/input/epoch_state.json"
OUTPUT_DIR = "/output"
SERIAL_DEVICE = "/dev/ttyS0"

# Delimiters for serial console output (runner parses between these)
OUTPUT_START_MARKER = "===HUMANFUND_OUTPUT_START==="
OUTPUT_END_MARKER = "===HUMANFUND_OUTPUT_END==="


def log(msg):
    print(f"[enclave] {msg}", flush=True)


# ─── Input reading ──────────────────────────────────────────────────────

def read_input() -> dict:
    """Read epoch state from the platform-specific input channel.

    Tries in order:
      1. File at /input/epoch_state.json (most portable)
      2. GCP instance metadata (cloud-specific)
      3. stdin (development/testing)
    """
    # 1. File input (portable)
    if os.path.exists(INPUT_FILE):
        log(f"Reading input from {INPUT_FILE}")
        with open(INPUT_FILE) as f:
            return json.load(f)

    # 2. GCP metadata
    try:
        from urllib.request import urlopen, Request
        req = Request(
            "http://169.254.169.254/computeMetadata/v1/instance/attributes/epoch-state",
            headers={"Metadata-Flavor": "Google"}
        )
        resp = urlopen(req, timeout=2)
        data = json.loads(resp.read())
        log("Reading input from GCP instance metadata")
        return data
    except Exception:
        pass

    # 3. stdin (development)
    if not sys.stdin.isatty():
        log("Reading input from stdin")
        return json.load(sys.stdin)

    raise RuntimeError(
        "No input found. Provide epoch state via:\n"
        f"  - File: {INPUT_FILE}\n"
        "  - GCP metadata: epoch-state attribute\n"
        "  - stdin: echo '{{...}}' | python3 -m tee.enclave.enclave_runner"
    )


# ─── Output writing ────────────────────────────────────────────────────

def write_output(result: dict):
    """Write result to all available output channels."""
    output_json = json.dumps(result, indent=2)

    # 1. File output (portable)
    try:
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        output_path = os.path.join(OUTPUT_DIR, "result.json")
        with open(output_path, "w") as f:
            f.write(output_json)
        log(f"Result written to {output_path}")
    except OSError as e:
        log(f"Could not write to {OUTPUT_DIR}: {e}")

    # 2. Serial console (GCP-readable without SSH)
    try:
        with open(SERIAL_DEVICE, "w") as serial:
            serial.write(f"\n{OUTPUT_START_MARKER}\n")
            serial.write(output_json)
            serial.write(f"\n{OUTPUT_END_MARKER}\n")
            serial.flush()
        log("Result written to serial console")
    except OSError:
        pass  # No serial device (not on GCP, or development mode)

    # 3. stdout (always)
    print(f"\n{OUTPUT_START_MARKER}")
    print(output_json)
    print(OUTPUT_END_MARKER)
    sys.stdout.flush()


def write_error(error: str):
    """Write an error result."""
    write_output({"status": "error", "error": error})


# ─── llama-server management ───────────────────────────────────────────

def start_llama_server() -> subprocess.Popen:
    """Start the local llama-server process."""
    if not os.path.exists(LLAMA_SERVER_BIN):
        raise RuntimeError(f"llama-server not found at {LLAMA_SERVER_BIN}")
    if not os.path.exists(MODEL_PATH):
        raise RuntimeError(f"Model not found at {MODEL_PATH}")

    log(f"Starting llama-server (model: {MODEL_PATH})...")

    # Detect GPU
    gpu_layers = ""
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0 and result.stdout.strip():
            gpu_layers = "-ngl 99"
            log(f"  GPU detected: {result.stdout.strip()}")
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    if not gpu_layers:
        log("  No GPU detected, using CPU inference")

    cmd = [
        LLAMA_SERVER_BIN,
        "-m", MODEL_PATH,
        "-c", "16384",
        "--host", "127.0.0.1",
        "--port", str(LLAMA_SERVER_PORT),
    ]
    if gpu_layers:
        cmd.extend(gpu_layers.split())

    proc = subprocess.Popen(
        cmd,
        stdout=open("/tmp/llama-server.log", "w"),
        stderr=subprocess.STDOUT,
    )
    log(f"  llama-server PID={proc.pid}")
    return proc


def wait_for_llama_server(timeout=600):
    """Wait for llama-server to be ready (model loaded)."""
    from urllib.request import urlopen

    log("Waiting for llama-server to load model...")
    start = time.time()
    for i in range(timeout // 5):
        try:
            resp = urlopen(f"{LLAMA_SERVER_URL}/health", timeout=5)
            status = json.loads(resp.read())
            if status.get("status") == "ok":
                elapsed = time.time() - start
                log(f"  Model loaded in {elapsed:.0f}s")
                return
        except Exception:
            pass
        time.sleep(5)

    raise RuntimeError(f"llama-server not ready after {timeout}s")


# ─── Main ──────────────────────────────────────────────────────────────

def emit_measurements():
    """Extract and emit TDX measurements to serial console (no SSH needed).

    This runs early in boot so the e2e test script can read measurements
    from serial output even though SSH is disabled on hardened images.
    """
    MEASUREMENTS_START = "===HUMANFUND_MEASUREMENTS_START==="
    MEASUREMENTS_END = "===HUMANFUND_MEASUREMENTS_END==="

    try:
        base = "/sys/kernel/config/tsm/report"
        if not os.path.isdir(base):
            log("  No configfs-tsm — skipping measurement extraction")
            return

        entry = os.path.join(base, "measure-boot")
        os.makedirs(entry, exist_ok=True)
        try:
            with open(os.path.join(entry, "inblob"), "wb") as f:
                f.write(b"\x00" * 64)
            with open(os.path.join(entry, "outblob"), "rb") as f:
                quote = f.read()
        finally:
            try:
                os.rmdir(entry)
            except OSError:
                pass

        # Parse MRTD and RTMRs from the TDX quote (standard layout)
        body = 48
        mrtd = quote[body + 136 : body + 184]
        rtmr0 = quote[body + 328 : body + 376]
        rtmr1 = quote[body + 376 : body + 424]
        rtmr2 = quote[body + 424 : body + 472]
        rtmr3 = quote[body + 472 : body + 520]

        measurements = (
            f"MRTD:{mrtd.hex()}\n"
            f"RTMR0:{rtmr0.hex()}\n"
            f"RTMR1:{rtmr1.hex()}\n"
            f"RTMR2:{rtmr2.hex()}\n"
            f"RTMR3:{rtmr3.hex()}"
        )
        log(f"  TDX measurements extracted ({len(quote)} byte quote)")

        # Write to serial console
        try:
            with open(SERIAL_DEVICE, "w") as serial:
                serial.write(f"\n{MEASUREMENTS_START}\n")
                serial.write(measurements)
                serial.write(f"\n{MEASUREMENTS_END}\n")
                serial.flush()
        except OSError:
            pass

        # Also to stdout
        print(f"\n{MEASUREMENTS_START}")
        print(measurements)
        print(MEASUREMENTS_END)
        sys.stdout.flush()

    except Exception as e:
        log(f"  Measurement extraction failed: {e}")


def main():
    log("The Human Fund — TEE Enclave (one-shot)")
    log(f"  Model: {MODEL_PATH}")
    log(f"  System prompt: {SYSTEM_PROMPT_PATH}")
    log(f"  dm-verity rootfs: all code is immutable")

    # Emit measurements early — no SSH needed for e2e measurement extraction
    log("")
    log("Step 0: Extracting TDX measurements...")
    emit_measurements()

    llama_proc = None

    try:
        # Step 1: Read input
        log("")
        log("Step 1: Reading epoch state...")
        epoch_data = read_input()

        seed = int(epoch_data.get("seed", 0))
        llama_seed = seed & 0xFFFFFFFF if seed > 0 else -1
        log(f"  Seed: {seed} (llama: {llama_seed})")

        # Step 2: Read system prompt from dm-verity rootfs
        log("")
        log("Step 2: Reading system prompt...")
        prompt_path = Path(SYSTEM_PROMPT_PATH)
        if not prompt_path.exists():
            raise RuntimeError(f"System prompt not found at {SYSTEM_PROMPT_PATH}")
        system_prompt = prompt_path.read_text().strip()
        log(f"  Prompt: {len(system_prompt)} chars, sha256={hashlib.sha256(system_prompt.encode()).hexdigest()[:16]}...")

        # Step 3: Compute input hash
        # The runner sends the full flat epoch state. The TEE derives the
        # structured contract_state from it for hash verification, ensuring
        # ALL data shown to the model is transitively verified via inputHash.
        log("")
        log("Step 3: Computing input hash...")
        epoch_state = epoch_data.get("epoch_state")
        if not epoch_state:
            raise RuntimeError(
                "epoch_state is required. The TEE must derive all data "
                "deterministically from the hash-verified epoch state."
            )
        # Derive contract_state from flat epoch_state
        contract_state = derive_contract_state(epoch_state)
        # base_input_hash = _computeInputHash() in Solidity (no seed)
        base_input_hash = compute_input_hash(contract_state)
        # final input_hash = keccak256(base || seed), matching epochInputHashes[epoch]
        # set in TheHumanFund.closeReveal():
        #   epochInputHashes[epoch] = keccak256(epochBaseInputHashes[epoch] || seed)
        seed_bytes = seed.to_bytes(32, "big") if seed > 0 else b"\x00" * 32
        input_hash = _keccak256(base_input_hash + seed_bytes)
        log(f"  Base input hash: 0x{base_input_hash.hex()[:16]}...")
        log(f"  Input hash (derived from epoch_state): 0x{input_hash.hex()[:16]}...")

        # Step 4: Build prompt (deterministically from hash-verified state)
        # epoch_context is built INSIDE the TEE from the same data that was
        # hash-verified in step 3. No runner-supplied free-text prompt.
        log("")
        log("Step 4: Building prompt...")
        epoch_context = build_epoch_context(epoch_state, seed=seed)
        log(f"  Epoch context built from verified state ({len(epoch_context)} chars)")
        full_prompt = build_full_prompt(system_prompt, epoch_context)
        log(f"  Full prompt: {len(full_prompt)} chars")

        # Step 5: Start llama-server and run inference
        log("")
        log("Step 5: Running inference...")
        llama_proc = start_llama_server()
        wait_for_llama_server()

        max_retries = 3
        action_json = None
        inference = None

        for attempt in range(1, max_retries + 1):
            log(f"  Attempt {attempt}/{max_retries}...")
            try:
                inference = run_two_pass_inference(
                    full_prompt, seed=llama_seed, llama_url=LLAMA_SERVER_URL
                )
            except Exception as e:
                log(f"  Inference error: {e}")
                if attempt == max_retries:
                    raise RuntimeError(f"Inference failed after {max_retries} attempts: {e}")
                continue

            action_json = parse_action(inference["text"])
            if action_json:
                log(f"  Action: {action_json['action']}")
                break
            log(f"  Could not parse action from output")

        if not action_json:
            raise RuntimeError("Could not parse action after retries")

        # Step 6: Encode action and compute hashes
        log("")
        log("Step 6: Encoding action...")
        reasoning = truncate_reasoning(inference["reasoning"])
        action_bytes = encode_action_bytes(action_json)
        log(f"  Action bytes: {len(action_bytes)} bytes")
        log(f"  Reasoning: {len(reasoning)} chars")

        # Step 7: Get TDX attestation quote
        log("")
        log("Step 7: Generating TDX attestation quote...")
        report_data = compute_report_data(input_hash, action_bytes, reasoning, system_prompt)
        quote = get_tdx_quote(report_data)
        log(f"  Quote: {len(quote)} bytes")
        log(f"  Report data: 0x{report_data.hex()[:32]}...")

        # Step 8: Write output
        log("")
        log("Step 8: Writing output...")
        result = {
            "status": "success",
            "reasoning": reasoning,
            "action": action_json,
            "action_bytes": "0x" + action_bytes.hex(),
            "attestation_quote": "0x" + quote.hex(),
            "report_data": "0x" + report_data.hex(),
            "input_hash": "0x" + input_hash.hex(),
            "seed": seed,
            "inference_seconds": inference["elapsed_seconds"],
            "tokens": inference["tokens"],
        }
        write_output(result)

        log("")
        log("Epoch complete.")

    except Exception as e:
        log(f"FATAL: {e}")
        write_error(str(e))
        sys.exit(1)

    finally:
        # Kill llama-server
        if llama_proc and llama_proc.poll() is None:
            log("Stopping llama-server...")
            llama_proc.terminate()
            try:
                llama_proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                llama_proc.kill()


if __name__ == "__main__":
    main()
