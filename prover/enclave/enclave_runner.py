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
from .action_encoder import parse_action, encode_action_bytes, validate_and_clamp_action
from .input_hash import compute_input_hash, _keccak256
from .attestation import get_tdx_quote, compute_report_data
from .prompt_builder import build_epoch_context, build_full_prompt
from .voice_anchors import parse_anchors, select_anchors, VOICE_ANCHOR_K

# ─── Configuration ──────────────────────────────────────────────────────

MODEL_PATH = os.environ.get("MODEL_PATH", "/models/model.gguf")
SYSTEM_PROMPT_PATH = os.environ.get("SYSTEM_PROMPT_PATH", "/opt/humanfund/system_prompt.txt")
VOICE_ANCHORS_PATH = os.environ.get("VOICE_ANCHORS_PATH", "/opt/humanfund/voice_anchors.txt")
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

def require_nvidia_cc():
    """Abort if NVIDIA Confidential Compute mode is not engaged on the GPU.

    `humanfund-gpu-cc.service` attempts to enable CC mode on boot, but it's
    best-effort (3 retries then shrug). Without this gate the enclave would
    silently run inference with CC disabled. Hard-fail here so the TDX
    quote is never produced — the prover client then times out and the
    epoch forfeits cleanly instead of producing unattested output.
    """
    try:
        result = subprocess.run(
            ["nvidia-smi", "conf-compute", "-f"],
            capture_output=True, text=True, timeout=10
        )
    except FileNotFoundError:
        raise RuntimeError("nvidia-smi not found — cannot verify CC mode")
    except subprocess.TimeoutExpired:
        raise RuntimeError("nvidia-smi conf-compute timed out")

    if result.returncode != 0:
        raise RuntimeError(
            f"nvidia-smi conf-compute failed (rc={result.returncode}): "
            f"{result.stderr.strip()}"
        )

    output = result.stdout
    # Expected lines (driver 580+):
    #   CC status: ON
    #   CC mode: ...
    #   Ready-state: READY
    status_on = "CC status: ON" in output
    ready = "Ready-state: READY" in output or "Ready state: READY" in output
    if not (status_on and ready):
        raise RuntimeError(
            "NVIDIA CC not engaged. nvidia-smi conf-compute -f output:\n" + output
        )
    log("  NVIDIA CC: ON, Ready-state: READY")


def start_llama_server() -> subprocess.Popen:
    """Start the local llama-server process with deterministic flags.

    Production enclave requires GPU — no CPU fallback. Any CPU-side
    inference would diverge from the GPU baseline committed in the
    validation battery. If nvidia-smi is unavailable or reports no GPU,
    the enclave aborts before ever producing a TDX quote.
    """
    if not os.path.exists(LLAMA_SERVER_BIN):
        raise RuntimeError(f"llama-server not found at {LLAMA_SERVER_BIN}")
    if not os.path.exists(MODEL_PATH):
        raise RuntimeError(f"Model not found at {MODEL_PATH}")

    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=5
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        raise RuntimeError(f"GPU required but nvidia-smi unavailable: {e}")
    if result.returncode != 0 or not result.stdout.strip():
        raise RuntimeError(f"GPU required but nvidia-smi returned no device: {result.stderr.strip()}")
    log(f"Starting llama-server (model: {MODEL_PATH}, GPU: {result.stdout.strip()})...")

    # Determinism-critical flags — order must not vary across builds.
    #   -ngl 99         full GPU offload (all layers)
    #   -b 1            physical batch size 1
    #   --parallel 1    single server slot, no request parallelism
    #   --flash-attn 0  disable flash attention (reduction-order varies)
    cmd = [
        LLAMA_SERVER_BIN,
        "-m", MODEL_PATH,
        "-c", "32768",
        "--host", "127.0.0.1",
        "--port", str(LLAMA_SERVER_PORT),
        "-ngl", "99",
        "-b", "1",
        "--parallel", "1",
        "--flash-attn", "0",
    ]

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
    import argparse
    parser = argparse.ArgumentParser(description="TEE Enclave (one-shot)")
    parser.add_argument("--mock", action="store_true",
                        help="Allow mock attestation (dev only, will NOT pass on-chain verification)")
    args = parser.parse_args()

    log("The Human Fund — TEE Enclave (one-shot)")
    log(f"  Model: {MODEL_PATH}")
    log(f"  System prompt: {SYSTEM_PROMPT_PATH}")
    log(f"  Voice anchors: {VOICE_ANCHORS_PATH}")
    log(f"  dm-verity rootfs: all code is immutable")
    if args.mock:
        log("  WARNING: Mock attestation enabled (--mock flag)")

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

        # Step 2: Read system prompt + voice anchors from dm-verity rootfs
        log("")
        log("Step 2: Reading system prompt and voice anchors...")
        prompt_path = Path(SYSTEM_PROMPT_PATH)
        if not prompt_path.exists():
            raise RuntimeError(f"System prompt not found at {SYSTEM_PROMPT_PATH}")
        system_prompt = prompt_path.read_text().strip()
        log(f"  Prompt: {len(system_prompt)} chars, sha256={hashlib.sha256(system_prompt.encode()).hexdigest()[:16]}...")

        anchors_path = Path(VOICE_ANCHORS_PATH)
        if anchors_path.exists():
            full_anchors_text = anchors_path.read_text().strip()
            log(
                f"  Voice anchors: {len(full_anchors_text)} chars, "
                f"sha256={hashlib.sha256(full_anchors_text.encode()).hexdigest()[:16]}..."
            )
            # Deterministic seed-bound rotation: show the model VOICE_ANCHOR_K
            # samples from the full pool per epoch, selected by the same
            # seed that is XOR'd into `epochInputHash`. The anchors file
            # is measured in RTMR[2] via dm-verity and the seed is bound
            # on-chain, so the selection is integrity-protected transitively
            # (no extra hash needed). `select_anchors` returns a rendered
            # string with per-sample fiction framing already wrapped around
            # each chosen sample.
            anchors_header, anchor_samples = parse_anchors(full_anchors_text)
            voice_anchors = select_anchors(
                anchors_header, anchor_samples, seed=seed, k=VOICE_ANCHOR_K
            )
            log(
                f"  Voice anchors: {len(anchor_samples)} parsed, "
                f"{VOICE_ANCHOR_K} selected via seed={seed}"
            )
        else:
            voice_anchors = ""
            log(f"  Voice anchors: not found at {VOICE_ANCHORS_PATH}, continuing without")

        # Step 3: Compute input hash
        # The enclave is a dumb hasher. It takes the flat epoch_state from the
        # runner, re-derives EVERY leaf hash (state, nonprofits, investments,
        # memory, messages, history) from the raw display data, and combines
        # them the same way the contract does. On-chain verification is pure
        # hash equality against epochInputHashes[epoch]. If the runner lied
        # about any display field, the hash won't match and the submission
        # reverts. No separate verification step.
        log("")
        log("Step 3: Computing input hash...")
        epoch_state = epoch_data.get("epoch_state")
        if not epoch_state:
            raise RuntimeError(
                "epoch_state is required. The enclave hashes the runner-supplied "
                "flat state directly and the contract verifies by hash equality."
            )
        # base_input_hash = _computeInputHash() in Solidity (no seed)
        base_input_hash = compute_input_hash(epoch_state)
        # final input_hash = keccak256(base || seed), matching epochInputHashes[epoch]
        # set in TheHumanFund._syncPhase() reveal-close:
        #   epochInputHashes[epoch] = keccak256(epochBaseInputHashes[epoch] || seed)
        seed_bytes = seed.to_bytes(32, "big") if seed > 0 else b"\x00" * 32
        input_hash = _keccak256(base_input_hash + seed_bytes)
        log(f"  Base input hash: 0x{base_input_hash.hex()[:16]}...")
        log(f"  Input hash (with seed):  0x{input_hash.hex()[:16]}...")

        # Step 4: Build prompt (deterministically from the hashed state).
        # Any field the model sees is a field that contributed to the hash
        # above. If the runner lied, the hash won't match on-chain and we
        # waste GPU time, but no bad action ever lands.
        log("")
        log("Step 4: Building prompt...")
        epoch_context = build_epoch_context(epoch_state, seed=seed, voice_anchors=voice_anchors)
        log(f"  Epoch context built from verified state ({len(epoch_context)} chars)")
        full_prompt = build_full_prompt(system_prompt, epoch_context)
        log(f"  Full prompt: {len(full_prompt)} chars")

        # Step 5: Start llama-server and run inference
        log("")
        log("Step 5: Running inference...")
        external_llama = os.environ.get("LLAMA_SERVER_EXTERNAL", "").strip() == "1"
        if external_llama:
            log("  LLAMA_SERVER_EXTERNAL=1 — using already-running llama-server")
        else:
            require_nvidia_cc()
            llama_proc = start_llama_server()
            wait_for_llama_server()

        # run_two_pass_inference (v19): pass 1 emits the diary, pass 2
        # emits the action JSON under GBNF grammar constraints. Pass 2
        # retries with an incrementing seed on the rare chance the model
        # produces output the parser can't read (grammar should make that
        # basically impossible). If all retries fail, parsed_action is
        # None and we fall back to a no-action result with a system note
        # so Costanza can see what happened next epoch.
        inference = run_two_pass_inference(
            full_prompt, seed=llama_seed, llama_url=LLAMA_SERVER_URL,
        )
        action_json = inference.get("parsed_action")
        system_notes = []  # list[str] of clamp / fallback notices for the diary

        if action_json is None:
            log(f"  Action parse FAILED after {inference.get('action_attempts', '?')} attempts — falling back to no action")
            action_json = {"action": "do_nothing", "params": {}, "memory": []}
            system_notes.append(
                "model failed to output valid JSON after several attempts — "
                "defaulting to no action this epoch"
            )
        else:
            log(f"  Action: {action_json['action']} (parsed after {inference.get('action_attempts', 1)} attempt(s))")

            # Clamp amounts to the per-epoch bounds the prompt displayed.
            # Fixes issue #10 — model overshoots by 10-20% and the contract
            # silently rejects. Clamping here lets the action land.
            action_json, clamp_notes = validate_and_clamp_action(action_json, epoch_state)
            if clamp_notes:
                for n in clamp_notes:
                    log(f"  Clamp: {n}")
                system_notes.extend(clamp_notes)

        # Step 6: Encode action + inject system notes into the diary.
        # CRITICAL: system notes MUST be injected BEFORE truncate_reasoning()
        # because the contract's REPORTDATA is sha256(inputHash || outputHash)
        # where outputHash covers the reasoning. Editing reasoning after
        # hashing would break attestation.
        #
        # Notes go inside the <diary> block so the model sees them in
        # future epochs' decision history.
        log("")
        log("Step 6: Encoding action...")
        reasoning = inference["reasoning"]
        if system_notes:
            notes_block = "\n\n" + "\n".join(
                f"[System note: {n}]" for n in system_notes
            )
            # Insert before </diary> if present, otherwise append
            diary_close_idx = reasoning.rfind("</diary>")
            if diary_close_idx >= 0:
                reasoning = reasoning[:diary_close_idx] + notes_block + "\n" + reasoning[diary_close_idx:]
            else:
                reasoning = reasoning.rstrip() + notes_block
        reasoning = truncate_reasoning(reasoning)
        action_bytes = encode_action_bytes(action_json)
        # The validator (validate_and_clamp_action) has already canonicalized
        # the memory sidecar: 0..3 entries, each {slot, title, body} with
        # bounded sizes. This is the EXACT list the client will submit and
        # the contract will hash for outputHash. Capturing the local var
        # here both (a) lets us hash it into REPORTDATA and (b) gives the
        # client a single canonical source it can pass through unchanged.
        submitted_memory = action_json.get("memory", []) if isinstance(action_json, dict) else []
        if not isinstance(submitted_memory, list):
            submitted_memory = []
        log(f"  Action bytes: {len(action_bytes)} bytes")
        log(f"  Reasoning: {len(reasoning)} chars ({len(system_notes)} system notes appended)")
        log(f"  Memory updates: {len(submitted_memory)}")

        # Step 7: Get TDX attestation quote
        log("")
        log("Step 7: Generating TDX attestation quote...")
        report_data = compute_report_data(
            input_hash, action_bytes, reasoning, submitted_memory
        )
        quote = get_tdx_quote(report_data, allow_mock=args.mock)
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
            "submitted_memory": submitted_memory,
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
        # Kill llama-server (only if we started it — not in LLAMA_SERVER_EXTERNAL mode)
        if llama_proc and llama_proc.poll() is None:
            log("Stopping llama-server...")
            llama_proc.terminate()
            try:
                llama_proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                llama_proc.kill()


if __name__ == "__main__":
    main()
