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
import os
import subprocess
import time

from .base import TEEClient

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
        cmd = f"gcloud {args}"
        if self.project:
            cmd += f" --project={self.project}"
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        if check and result.returncode != 0:
            raise RuntimeError(f"gcloud failed: {result.stderr[:500]}")
        return result.stdout.strip()

    def _create_vm(self, epoch_state_json: str):
        """Create a TDX Confidential VM with epoch state in metadata."""
        import tempfile
        import uuid
        self.vm_name = f"humanfund-runner-{uuid.uuid4().hex[:8]}"
        print(f"  Creating VM: {self.vm_name}")
        print(f"  Image: {self.image}")
        print(f"  Machine: {self.machine_type}")

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
                f"--metadata-from-file=epoch-state={metadata_file}",
                timeout=180,
            )
        finally:
            os.unlink(metadata_file)

        print(f"  VM created: {self.vm_name}")

    def _poll_serial_output(self, timeout=None):
        """Poll the serial console for the enclave's output.

        The enclave writes JSON between OUTPUT_START_MARKER and OUTPUT_END_MARKER.
        We poll every 30 seconds until we see the output or timeout.
        """
        if timeout is None:
            timeout = self.inference_timeout

        print(f"  Polling serial console (timeout: {timeout}s)...")
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
                            print(f"    {line.strip()}")
                    last_line_count = len(lines)

                # Look for the output markers
                start_idx = output.find(OUTPUT_START_MARKER)
                end_idx = output.find(OUTPUT_END_MARKER)

                if start_idx >= 0 and end_idx > start_idx:
                    result_json = output[start_idx + len(OUTPUT_START_MARKER):end_idx].strip()
                    elapsed = time.time() - start
                    print(f"  Result received after {elapsed:.0f}s")
                    return json.loads(result_json)

            except (subprocess.TimeoutExpired, json.JSONDecodeError) as e:
                print(f"    Poll error: {e}")

            time.sleep(30)

        raise RuntimeError(f"No output after {timeout}s — enclave may have failed")

    def _cleanup(self):
        """Delete the VM."""
        if self.vm_name:
            print(f"  Deleting VM: {self.vm_name}")
            try:
                self._gcloud(
                    f"compute instances delete {self.vm_name} "
                    f"--zone={self.zone} --quiet",
                    check=False, timeout=120,
                )
                print("  VM deleted")
            except Exception as e:
                print(f"  WARNING: Failed to delete VM: {e}")
            self.vm_name = None

    def run_epoch(self, contract_state, epoch_context, system_prompt, seed):
        """Run inference inside a fresh GCP TDX VM.

        Input is passed via GCP instance metadata.
        Output is read from the serial console.

        Returns the enclave result dict with an added `vm_minutes` field.
        """
        # Build the epoch state that the enclave will read
        epoch_data = {
            "contract_state": contract_state,
            "epoch_context": epoch_context,
            "seed": seed,
            # system_prompt is on the dm-verity rootfs, not passed via metadata
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
