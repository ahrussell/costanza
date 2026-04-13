#!/usr/bin/env python3
"""GCP TEE client — manages TDX Confidential VM lifecycle.

New architecture (no SSH, no Docker, no HTTP server):
1. Create VM from dm-verity image with epoch state in metadata
2. VM boots, runs one-shot inference, writes result to serial console
3. Runner polls serial console for output
4. Parse result
5. Delete VM

The VM runs a one-shot enclave program on a dm-verity rootfs.
No SSH, no Docker, no network listeners. The only I/O channels are:
  - Input: GCP instance metadata (epoch state JSON)
  - Output: Serial console (result JSON between delimiters)
"""

import json
import logging
import os
import subprocess
import time

from .base import TEEClient

logger = logging.getLogger(__name__)

# Delimiters matching enclave_runner.py
OUTPUT_START_MARKER = "===HUMANFUND_OUTPUT_START==="
OUTPUT_END_MARKER = "===HUMANFUND_OUTPUT_END==="


class GCPTEEClient(TEEClient):
    def __init__(self, project=None, zone="us-central1-a",
                 image="humanfund-dmverity-gpu-v5",
                 machine_type="a3-highgpu-1g",
                 inference_timeout=900):
        self.project = project
        self.zone = zone
        self.image = image
        self.machine_type = machine_type
        self.inference_timeout = inference_timeout  # seconds to wait for result
        self.vm_name = None

    def _gcloud(self, args, check=True, timeout=120):
        """Run a gcloud command."""
        import shlex
        cmd = ["gcloud"] + shlex.split(args)
        if self.project:
            cmd.extend(["--project", self.project])
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        )
        if check and result.returncode != 0:
            raise RuntimeError(f"gcloud failed: {result.stderr[:500]}")
        return result.stdout.strip()

    def _create_vm(self, epoch_state_json: str):
        """Create a TDX Confidential VM with epoch state in metadata."""
        import tempfile
        import uuid
        self.vm_name = f"humanfund-runner-{uuid.uuid4().hex[:8]}"
        logger.info("Creating VM: %s (image=%s, machine=%s)", self.vm_name, self.image, self.machine_type)

        # Write epoch state to a temp file to avoid gcloud's special char parsing
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            f.write(epoch_state_json)
            metadata_file = f.name

        try:
            self._gcloud(
                f"compute instances create {self.vm_name} "
                f"--zone={self.zone} "
                f"--machine-type={self.machine_type} "
                f"--image={self.image} "
                f"--confidential-compute-type=TDX "
                f"--boot-disk-size=300GB "
                f"--maintenance-policy=TERMINATE "
                f"--provisioning-model=SPOT "
                f"--instance-termination-action=DELETE "
                f"--metadata-from-file=epoch-state={metadata_file} "
                f"--scopes=https://www.googleapis.com/auth/compute.readonly",
                timeout=180,
            )
        finally:
            os.unlink(metadata_file)

        logger.info("VM created: %s", self.vm_name)

    def _poll_serial_output(self, timeout=None):
        """Poll the serial console for the enclave's output.

        The enclave writes JSON between OUTPUT_START_MARKER and OUTPUT_END_MARKER.
        We poll every 30 seconds until we see the output or timeout.
        """
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
                    check=False, timeout=30,
                )

                # Show progress (new lines since last check)
                lines = output.split('\n')
                if len(lines) > last_line_count:
                    for line in lines[last_line_count:]:
                        if '[enclave]' in line:
                            logger.info("[enclave] %s", line.strip())
                    last_line_count = len(lines)

                # Look for the output markers.
                # The enclave writes to /dev/ttyS0 (no timestamp) AND to stdout
                # (which journald timestamped). Both appear in the serial output.
                # The ttyS0 write comes first: START marker, then delayed syslog
                # messages, then the JSON, then END marker. The JSON is the last
                # `{...}` block before the END marker in the first marker pair.
                start_idx = output.find(OUTPUT_START_MARKER)
                end_idx = output.find(OUTPUT_END_MARKER)

                if start_idx >= 0 and end_idx > start_idx:
                    block = output[start_idx + len(OUTPUT_START_MARKER):end_idx]
                    # The raw JSON from the direct ttyS0 write is the last { in the block.
                    # Syslog messages (with timestamps) appear after the JSON, so use
                    # raw_decode to parse just the JSON object and ignore trailing text.
                    last_brace = block.rfind("\n{")
                    if last_brace >= 0:
                        result_json = block[last_brace:].strip()
                        elapsed = time.time() - start
                        logger.info("Result received after %.0fs", elapsed)
                        obj, _ = json.JSONDecoder().raw_decode(result_json)
                        return obj

            except subprocess.TimeoutExpired:
                logger.warning("Serial console poll timed out, retrying...")
            except json.JSONDecodeError as e:
                logger.warning("JSON parse error in serial output: %s", e)

            time.sleep(30)

        raise RuntimeError(f"No output after {timeout}s — enclave may have failed")

    def _cleanup(self):
        """Delete the VM."""
        if self.vm_name:
            logger.info("Deleting VM: %s", self.vm_name)
            try:
                self._gcloud(
                    f"compute instances delete {self.vm_name} "
                    f"--zone={self.zone} --quiet",
                    check=False, timeout=120,
                )
                logger.info("VM deleted")
            except Exception as e:
                logger.warning("Failed to delete VM: %s", e)
            self.vm_name = None

    def run_epoch(self, epoch_state, contract_state, system_prompt, seed):
        """Run inference inside a fresh GCP TDX VM.

        Input is passed via GCP instance metadata.
        Output is read from the serial console.

        The enclave builds epoch_context deterministically from epoch_state
        inside the TEE. It derives contract_state from epoch_state for hash
        verification, ensuring all data shown to the model is transitively
        verified via inputHash.

        Returns the enclave result dict with an added `vm_minutes` field.
        """
        # Build the epoch data that the enclave will read.
        # epoch_state: full flat state — TEE derives hash inputs + builds prompt.
        # Merge epoch_content_hashes and message_hashes from contract_state into the
        # flat epoch_state so derive_contract_state() can include them in the input hash.
        epoch_state_with_hashes = {
            **epoch_state,
            "invest_hash": contract_state.get("invest_hash", "0x" + "00" * 32),
            "worldview_hash": contract_state.get("worldview_hash", "0x" + "00" * 32),
            "epoch_content_hashes": contract_state.get("epoch_content_hashes", []),
            "message_hashes": contract_state.get("message_hashes", []),
        }
        epoch_data = {
            "epoch_state": epoch_state_with_hashes,
            "contract_state": contract_state,
            "seed": seed,
        }
        epoch_state_json = json.dumps(epoch_data)

        vm_start = time.time()
        try:
            self._create_vm(epoch_state_json)
            result = self._poll_serial_output()

            if result.get("status") == "error":
                raise RuntimeError(f"Enclave error: {result.get('error')}")

            result["vm_minutes"] = (time.time() - vm_start) / 60
            return result

        finally:
            self._cleanup()
