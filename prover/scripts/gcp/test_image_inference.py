#!/usr/bin/env python3
"""Boot a TDX VM from a dm-verity image, run a one-shot inference on a
synthetic epoch state, capture both the boot RTMR measurements AND the
inference output during the same VM lifetime, and save everything to disk.

No on-chain contract is touched — synthetic state is generated locally
via scripts/simulate.py's scenario presets. Fast, cheap, fully offline
validation that a freshly built dm-verity image:

  - boots and dm-verity holds
  - GPU CC initializes
  - the enclave runner reads metadata, runs inference, attests, and
    emits the expected output markers
  - measurements are reproducible and stable

Reuses production primitives: GCPTEEClient handles VM lifecycle (create,
poll serial, delete) and register_image's measurement parser handles
RTMR extraction. Both run off the SAME serial output captured during
the inference lifecycle, so we get measurements without booting a
second VM.

Usage:
    python prover/scripts/gcp/test_image_inference.py \\
        --image costanza-tdx-prover-v2 \\
        --output-dir ./test-results/v2
"""

import argparse
import json
import logging
import os
import re
import secrets
import sys
import time
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from prover.client.tee_clients.gcp import (
    GCPTEEClient,
    OUTPUT_END_MARKER,
    OUTPUT_START_MARKER,
)
from prover.scripts.gcp.register_image import compute_image_key
from scripts.simulate import SCENARIO_NAMES, generate_scenario_state

logger = logging.getLogger(__name__)


def _normalize_state_for_json(obj):
    """Walk the state dict, converting raw bytes to '0x'-hex strings.

    simulate.py emits some fields (notably history[*].action,
    history[*].reasoning) as raw bytes for in-process simulation.
    Production's epoch_state.py converts these to hex strings before they
    cross the enclave boundary, and the enclave runner accepts both
    shapes. Mirror the production normalization here so json.dumps in
    GCPTEEClient.run_epoch doesn't bail.
    """
    if isinstance(obj, bytes):
        return "0x" + obj.hex()
    if isinstance(obj, dict):
        return {k: _normalize_state_for_json(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_normalize_state_for_json(v) for v in obj]
    return obj


class MeasureAndInferClient(GCPTEEClient):
    """GCPTEEClient that ALSO captures RTMR measurements from the boot
    serial output. Measurements are emitted by the enclave at boot, well
    before inference output, so both markers appear in the same serial
    log over the VM's single lifetime — no second VM needed.
    """

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.captured_serial = ""

    def _poll_serial_output(self, timeout=None):
        # Mirrors the parent's polling loop but stashes every serial
        # snapshot so we can grep RTMRs out of it after success.
        if timeout is None:
            timeout = self.inference_timeout

        logger.info("Polling serial console (timeout: %ds)...", timeout)
        start = time.time()
        last_line_count = 0

        while time.time() - start < timeout:
            try:
                output = self._gcloud(
                    f"compute instances get-serial-port-output {self.vm_name} "
                    f"--zone={self.zone}",
                    check=False,
                    timeout=30,
                )
                self.captured_serial = output

                lines = output.split("\n")
                if len(lines) > last_line_count:
                    for line in lines[last_line_count:]:
                        if "[enclave]" in line:
                            logger.info("[enclave] %s", line.strip())
                    last_line_count = len(lines)

                start_idx = output.find(OUTPUT_START_MARKER)
                end_idx = output.find(OUTPUT_END_MARKER)
                if start_idx >= 0 and end_idx > start_idx:
                    block = output[start_idx + len(OUTPUT_START_MARKER):end_idx]
                    last_brace = block.rfind("\n{")
                    if last_brace >= 0:
                        result_json = block[last_brace:].strip()
                        elapsed = time.time() - start
                        logger.info("Inference result received after %.0fs", elapsed)
                        obj, _ = json.JSONDecoder().raw_decode(result_json)
                        return obj
            except Exception as e:
                logger.warning("Poll iteration error: %s", e)

            time.sleep(30)

        raise RuntimeError(f"No output after {timeout}s — enclave may have failed")

    def extract_measurements(self):
        """Parse RTMRs out of whatever serial we already captured.

        Must be called after a successful run_epoch (so the buffer has
        boot output in it). Mirrors register_image's parser exactly.
        """
        if not self.captured_serial:
            raise RuntimeError("No serial output captured — call run_epoch first")

        measurements = {}
        for label, key in [
            ("MRTD", "mrtd"),
            ("RTMR0", "rtmr0"),
            ("RTMR1", "rtmr1"),
            ("RTMR2", "rtmr2"),
            ("RTMR3", "rtmr3"),
        ]:
            m = re.search(rf"{label}:([0-9a-f]{{96}})", self.captured_serial)
            if m:
                measurements[key] = bytes.fromhex(m.group(1))
        for required in ("mrtd", "rtmr1", "rtmr2"):
            if required not in measurements:
                raise RuntimeError(f"Missing {required} in serial output")
        return measurements


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--image", required=True, help="GCP image name to test")
    parser.add_argument(
        "--scenario",
        default="default",
        choices=SCENARIO_NAMES,
        help="Synthetic state preset (default: default)",
    )
    parser.add_argument("--zone", default="us-central1-a")
    parser.add_argument(
        "--project",
        default=os.environ.get("GCP_PROJECT", "the-human-fund"),
    )
    parser.add_argument(
        "--inference-timeout",
        type=int,
        default=1200,
        help="Seconds to wait for inference output (default: 1200)",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Directory to save results (default: ./test-results/<image>)",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    output_dir = Path(args.output_dir or f"./test-results/{args.image}")
    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"=== Image inference test: {args.image} ===")
    print(f"  Scenario:  {args.scenario}")
    print(f"  Output:    {output_dir}/")

    state, scenario_desc = generate_scenario_state(args.scenario)
    state = _normalize_state_for_json(state)
    print(f"  Preset:    {scenario_desc}")

    # The seed is a 32-byte randomness source used inside the enclave for
    # datamarking + voice-anchor selection. The contract derives it from
    # block.prevrandao XOR salt accumulator; for an offline test, any
    # 256-bit value works. Captured to disk for reproducibility.
    seed_int = int.from_bytes(secrets.token_bytes(32), "big")
    print(f"  Seed:      {hex(seed_int)}")

    (output_dir / "input_state.json").write_text(
        json.dumps(state, indent=2, default=str)
    )
    (output_dir / "input_seed.txt").write_text(hex(seed_int))

    client = MeasureAndInferClient(
        project=args.project,
        zone=args.zone,
        image=args.image,
        machine_type="a3-highgpu-1g",
        inference_timeout=args.inference_timeout,
    )

    start = time.time()
    failure = None
    result = None
    try:
        result = client.run_epoch(
            epoch_state=state,
            system_prompt="",
            seed=seed_int,
        )
    except Exception as e:
        failure = e
        logger.error("Inference failed: %s", e)

    # Always dump the serial log — it's the postmortem source of truth
    # whether we succeeded or not.
    (output_dir / "serial_log.txt").write_text(client.captured_serial)

    # Try to extract measurements regardless of inference outcome —
    # measurements are emitted at boot, so they're independent of
    # whether inference itself succeeded.
    measurements = None
    image_key = None
    try:
        measurements = client.extract_measurements()
        image_key = compute_image_key(measurements)
        measurements_doc = {
            "image": args.image,
            "image_key": "0x" + image_key.hex(),
            "mrtd": measurements["mrtd"].hex(),
            "rtmr0": measurements.get("rtmr0", b"").hex(),
            "rtmr1": measurements["rtmr1"].hex(),
            "rtmr2": measurements["rtmr2"].hex(),
            "rtmr3": measurements.get("rtmr3", b"").hex(),
        }
        (output_dir / "measurements.json").write_text(
            json.dumps(measurements_doc, indent=2)
        )
        print(f"\n=== Measurements captured ===")
        print(f"  Image key: 0x{image_key.hex()}")
    except Exception as me:
        logger.warning("Could not extract measurements: %s", me)

    if failure is not None:
        print(f"\n!! Inference failed: {failure}")
        print(f"   Serial log saved to {output_dir / 'serial_log.txt'}")
        sys.exit(1)

    elapsed = time.time() - start

    (output_dir / "inference_result.json").write_text(
        json.dumps(result, indent=2, default=str)
    )

    print(f"\n=== Done in {elapsed/60:.1f} minutes ===")
    if measurements is not None:
        print(f"  MRTD:      {measurements['mrtd'].hex()}")
        print(f"  RTMR[1]:   {measurements['rtmr1'].hex()}")
        print(f"  RTMR[2]:   {measurements['rtmr2'].hex()}")
        print(f"  Image key: 0x{image_key.hex()}")
    if result:
        print(
            f"  Inference: action_type={result.get('action_type')}, "
            f"vm_minutes={result.get('vm_minutes', 0):.1f}"
        )
    print(f"  Saved to:  {output_dir}/")
    print()
    print("    measurements.json     — image key + RTMRs (for register_image.py later)")
    print("    inference_result.json — enclave output (action + reasoning + attestation)")
    print("    serial_log.txt        — full VM serial log (postmortem)")
    print("    input_state.json      — synthetic epoch state used as input")
    print("    input_seed.txt        — random seed used")


if __name__ == "__main__":
    main()
