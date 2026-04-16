#!/usr/bin/env python3
"""GCP Persistent TEE client — reuses a single spot VM across multiple epochs.

For testnet use only. Production uses GCPTEEClient (one-shot dm-verity VMs).

Architecture:
  1. Create a fixed-name spot VM from the base GPU image (not dm-verity).
     The VM has llama-server + model pre-installed.
  2. Wait for SSH to become available, then sync enclave code and start llama-server.
  3. Per epoch: SSH in, pipe epoch state via stdin, run enclave with
     LLAMA_SERVER_EXTERNAL=1 (skips start/stop of llama-server), read stdout.
  4. VM persists between epochs — model stays loaded (~2min inference vs ~15min cold).

No TDX attestation: proof is empty bytes, contract uses MockVerifier (ID 2).
"""

import json
import logging
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from .base import TEEClient

logger = logging.getLogger(__name__)

VM_NAME = "humanfund-testnet"
LLAMA_SERVER_BIN = "/opt/humanfund/bin/llama-server"
MODEL_PATH = "/models/model.gguf"
REMOTE_PROVER_DIR = "/opt/humanfund/prover"
LLAMA_SERVER_PORT = 8080


class GCPPersistentTEEClient(TEEClient):
    """Reusable spot VM for testnet inference. Not for production."""

    def __init__(self, project=None, zone="us-central1-a",
                 image="humanfund-base-gpu-llama-b5270",
                 machine_type="a3-highgpu-1g",
                 inference_timeout=600,
                 source_dir="."):
        self.project = project
        self.zone = zone
        self.image = image
        self.machine_type = machine_type
        self.inference_timeout = inference_timeout
        self.source_dir = Path(source_dir)

    # ─── gcloud helpers ──────────────────────────────────────────────────

    def _gcloud(self, args_str, check=True, timeout=120, input_data=None):
        """Run a gcloud command, returning stdout as a string."""
        cmd = ["gcloud"] + args_str.split()
        if self.project:
            cmd += ["--project", self.project]
        result = subprocess.run(
            cmd,
            input=input_data,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if check and result.returncode != 0:
            raise RuntimeError(f"gcloud failed ({result.returncode}): {result.stderr[:500]}")
        return result.stdout.strip()

    def _ssh(self, remote_cmd, input_data=None, timeout=None, check=True):
        """Run a command on the persistent VM via gcloud compute ssh.

        Uses IAP tunnelling — no external IP needed.
        stdin is piped from input_data if provided.
        """
        if timeout is None:
            timeout = self.inference_timeout
        cmd = [
            "gcloud", "compute", "ssh", VM_NAME,
            f"--zone={self.zone}",
            "--tunnel-through-iap",
            "--ssh-flag=-o StrictHostKeyChecking=no",
            "--ssh-flag=-o ServerAliveInterval=30",
            "--", remote_cmd,
        ]
        if self.project:
            cmd = cmd[:3] + ["--project", self.project] + cmd[3:]

        result = subprocess.run(
            cmd,
            input=input_data,
            capture_output=True,
            timeout=timeout,
        )
        stdout = result.stdout.decode("utf-8", errors="replace")
        stderr = result.stderr.decode("utf-8", errors="replace")

        if check and result.returncode != 0:
            raise RuntimeError(
                f"SSH command failed (exit {result.returncode}):\n"
                f"  cmd: {remote_cmd[:200]}\n"
                f"  stderr (last 800): {stderr[-800:]}\n"
                f"  stdout (last 800): {stdout[-800:]}"
            )
        return stdout, stderr

    # ─── VM lifecycle ────────────────────────────────────────────────────

    def _vm_exists(self):
        try:
            self._gcloud(
                f"compute instances describe {VM_NAME} --zone={self.zone} --format=value(status)",
                check=True, timeout=30,
            )
            return True
        except (RuntimeError, subprocess.TimeoutExpired):
            return False

    def _vm_status(self):
        try:
            return self._gcloud(
                f"compute instances describe {VM_NAME} --zone={self.zone} --format=value(status)",
                check=True, timeout=30,
            )
        except Exception:
            return None

    def _create_vm(self):
        """Create the persistent spot VM from the base GPU image."""
        logger.info("Creating persistent VM: %s (image=%s, machine=%s)",
                    VM_NAME, self.image, self.machine_type)
        self._gcloud(
            f"compute instances create {VM_NAME}"
            f" --zone={self.zone}"
            f" --machine-type={self.machine_type}"
            f" --image={self.image}"
            f" --boot-disk-size=200GB"
            f" --maintenance-policy=TERMINATE"
            f" --provisioning-model=SPOT"
            f" --instance-termination-action=DELETE"
            f" --scopes=https://www.googleapis.com/auth/cloud-platform",
            timeout=180,
        )
        logger.info("VM created: %s", VM_NAME)

    def _wait_for_ssh(self, timeout=300):
        """Poll until gcloud SSH is usable."""
        logger.info("Waiting for SSH on %s (up to %ds)...", VM_NAME, timeout)
        start = time.time()
        while time.time() - start < timeout:
            try:
                self._ssh("echo ssh-ready", timeout=30, check=True)
                logger.info("SSH is ready (%.0fs)", time.time() - start)
                return
            except Exception as e:
                logger.debug("SSH not ready yet: %s", e)
                time.sleep(15)
        raise RuntimeError(f"SSH not available on {VM_NAME} after {timeout}s")

    def _sync_code_if_needed(self):
        """Copy enclave + prompts to the VM only if not already present."""
        try:
            stdout, _ = self._ssh(
                f"test -f {REMOTE_PROVER_DIR}/enclave/enclave_runner.py && echo present",
                timeout=20, check=False,
            )
            if "present" in stdout:
                logger.info("Enclave code already present on VM, skipping sync.")
                return
        except Exception:
            pass
        self._sync_code()

    def _sync_code(self):
        """Copy enclave + prompts to the VM."""
        logger.info("Syncing enclave code to %s...", VM_NAME)

        # Ensure target directory exists (sudo for /opt paths)
        self._ssh(f"sudo mkdir -p {REMOTE_PROVER_DIR} && sudo chmod 777 {REMOTE_PROVER_DIR}", timeout=30)

        # Copy enclave module (includes __init__.py and all .py files)
        for subdir in ["enclave", "prompts"]:
            local_path = self.source_dir / "prover" / subdir
            if not local_path.exists():
                logger.warning("Source dir not found: %s", local_path)
                continue
            cmd = [
                "gcloud", "compute", "scp",
                "--recurse",
                f"--zone={self.zone}",
                "--tunnel-through-iap",
                str(local_path),
                f"{VM_NAME}:{REMOTE_PROVER_DIR}/",
            ]
            if self.project:
                cmd = cmd[:3] + ["--project", self.project] + cmd[3:]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            if result.returncode != 0:
                raise RuntimeError(f"scp failed for {subdir}: {result.stderr[:300]}")
            logger.info("  Synced prover/%s", subdir)

        # Copy top-level prover/__init__.py so it's importable as a package
        init_src = self.source_dir / "prover" / "__init__.py"
        if init_src.exists():
            cmd = [
                "gcloud", "compute", "scp",
                f"--zone={self.zone}",
                "--tunnel-through-iap",
                str(init_src),
                f"{VM_NAME}:{REMOTE_PROVER_DIR}/__init__.py",
            ]
            if self.project:
                cmd = cmd[:3] + ["--project", self.project] + cmd[3:]
            subprocess.run(cmd, capture_output=True, text=True, timeout=30)

        # Install Python deps for the enclave (skip if already present)
        logger.info("  Installing enclave Python deps...")
        self._ssh(
            "python3 -c 'import Crypto; import eth_abi' 2>/dev/null"
            " || sudo pip3 install --break-system-packages --ignore-installed typing_extensions"
            " --quiet pycryptodome eth_abi requests 2>&1 | tail -3",
            timeout=120,
        )
        logger.info("Code sync complete.")

    def _start_llama_server(self):
        """Start llama-server in the background on the VM."""
        logger.info("Starting llama-server (model load may take ~10-15 min)...")
        # Kill any existing instance first
        self._ssh("pkill -f llama-server || true", timeout=15, check=False)
        time.sleep(2)
        self._ssh(
            f"nohup env LD_LIBRARY_PATH=/opt/humanfund/bin"
            f" {LLAMA_SERVER_BIN} -m {MODEL_PATH} -c 16384 -ngl 99"
            f" --host 127.0.0.1 --port {LLAMA_SERVER_PORT}"
            f" > /tmp/llama-server.log 2>&1 &",
            timeout=15,
        )
        logger.info("llama-server started (PID in background).")

    def _wait_for_llama_ready(self, timeout=900):
        """Poll llama-server /health until the model is loaded."""
        logger.info("Waiting for model to load (up to %ds)...", timeout)
        start = time.time()
        check_cmd = (
            f"curl -sf http://127.0.0.1:{LLAMA_SERVER_PORT}/health"
            " | python3 -c \"import sys,json; d=json.load(sys.stdin); "
            "print('ok' if d.get('status')=='ok' else 'not-ok')\""
            " 2>/dev/null || echo not-ok"
        )
        while time.time() - start < timeout:
            try:
                stdout, _ = self._ssh(check_cmd, timeout=20, check=False)
                if "ok" in stdout and "not-ok" not in stdout:
                    elapsed = time.time() - start
                    logger.info("Model loaded in %.0fs!", elapsed)
                    return
            except Exception as e:
                logger.debug("Health check error: %s", e)
            elapsed = time.time() - start
            logger.info("  Still loading... (%.0fs elapsed)", elapsed)
            time.sleep(20)
        raise RuntimeError(f"llama-server not ready after {timeout}s — check /tmp/llama-server.log on VM")

    def _is_llama_running(self):
        """Check if llama-server is running and model is loaded."""
        check_cmd = (
            f"curl -sf http://127.0.0.1:{LLAMA_SERVER_PORT}/health"
            " | python3 -c \"import sys,json; d=json.load(sys.stdin); "
            "print('ok' if d.get('status')=='ok' else 'not-ok')\""
            " 2>/dev/null || echo not-ok"
        )
        try:
            stdout, _ = self._ssh(check_cmd, timeout=20, check=False)
            return "ok" in stdout and "not-ok" not in stdout
        except Exception:
            return False

    def _ensure_ready(self):
        """Ensure VM exists, code is synced, and llama-server is running."""
        if not self._vm_exists():
            self._create_vm()
            self._wait_for_ssh()
            self._sync_code_if_needed()
            self._start_llama_server()
            self._wait_for_llama_ready()
        else:
            status = self._vm_status()
            if status != "RUNNING":
                raise RuntimeError(
                    f"VM {VM_NAME} exists but is not RUNNING (status={status}). "
                    "Delete it manually with: "
                    f"gcloud compute instances delete {VM_NAME} --zone={self.zone}"
                )
            if not self._is_llama_running():
                logger.info("VM running but llama-server not ready — restarting...")
                self._sync_code_if_needed()
                self._start_llama_server()
                self._wait_for_llama_ready()
            else:
                logger.info("VM is running, llama-server ready.")

    # ─── Inference ───────────────────────────────────────────────────────

    def run_epoch(self, epoch_state, system_prompt, seed):
        """Run inference on the persistent VM via SSH stdin.

        Passes epoch state as JSON on stdin; the enclave reads it as the
        'stdin' fallback input channel (enclave_runner.py already supports this).

        Returns result dict compatible with the standard GCPTEEClient output,
        with `attestation_quote` set to empty bytes (MockVerifier accepts anything).
        """
        self._ensure_ready()

        epoch_data = json.dumps({
            "epoch_state": epoch_state,
            "seed": seed,
        })

        remote_cmd = (
            f"LLAMA_SERVER_EXTERNAL=1"
            f" SYSTEM_PROMPT_PATH={REMOTE_PROVER_DIR}/prompts/system.txt"
            f" VOICE_ANCHORS_PATH={REMOTE_PROVER_DIR}/prompts/voice_anchors.txt"
            f" MODEL_PATH={MODEL_PATH}"
            f" LLAMA_SERVER_BIN={LLAMA_SERVER_BIN}"
            f" LLAMA_SERVER_PORT={LLAMA_SERVER_PORT}"
            f" PYTHONPATH=/opt/humanfund"
            f" python3 -m prover.enclave.enclave_runner --mock"
        )

        logger.info("Running enclave via SSH (epoch_state: %d bytes)...", len(epoch_data))
        run_start = time.time()

        stdout, stderr = self._ssh(
            remote_cmd,
            input_data=epoch_data.encode("utf-8"),
            timeout=self.inference_timeout,
            check=True,
        )

        elapsed = time.time() - run_start
        logger.info("Enclave finished in %.0fs", elapsed)

        # Log enclave progress lines
        for line in stdout.splitlines():
            if "[enclave]" in line:
                logger.info("%s", line.strip())

        # Parse result from stdout (between output markers)
        result = self._parse_output(stdout)
        result["vm_minutes"] = elapsed / 60
        return result

    @staticmethod
    def _parse_output(stdout):
        """Extract JSON result from enclave stdout markers."""
        START = "===HUMANFUND_OUTPUT_START==="
        END = "===HUMANFUND_OUTPUT_END==="

        start_idx = stdout.find(START)
        end_idx = stdout.find(END)

        if start_idx < 0 or end_idx <= start_idx:
            raise RuntimeError(
                f"No output markers found in enclave stdout.\n"
                f"Last 500 chars: {stdout[-500:]}"
            )

        block = stdout[start_idx + len(START):end_idx]
        # Find the last JSON object in the block (syslog lines may follow)
        last_brace = block.rfind("\n{")
        if last_brace >= 0:
            result_json = block[last_brace:].strip()
        else:
            result_json = block.strip()

        obj, _ = json.JSONDecoder().raw_decode(result_json)

        if obj.get("status") == "error":
            raise RuntimeError(f"Enclave error: {obj.get('error')}")

        return obj
