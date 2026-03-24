#!/usr/bin/env python3
"""GCP TEE client — manages TDX Confidential VM lifecycle.

Flow:
1. Create VM from snapshot (no public ports)
2. Wait for SSH ready
3. Open SSH tunnel (port 8090 → localhost:8090)
4. Wait for enclave health check
5. POST epoch state to enclave
6. Parse response
7. Kill tunnel, delete VM

The VM is ALWAYS deleted in the finally block, even on error.
"""

import json
import os
import signal
import subprocess
import time
from urllib.request import urlopen, Request

from .base import TEEClient


class GCPTEEClient(TEEClient):
    def __init__(self, project=None, zone="us-central1-a", snapshot="humanfund-tee-gpu-70b",
                 machine_type="a3-highgpu-1g"):
        self.project = project
        self.zone = zone
        self.snapshot = snapshot
        self.machine_type = machine_type
        self.vm_name = None
        self.tunnel_proc = None

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

    def _create_vm(self):
        """Create a TDX Confidential VM from snapshot."""
        import uuid
        self.vm_name = f"humanfund-runner-{uuid.uuid4().hex[:8]}"
        print(f"  Creating VM: {self.vm_name}")

        self._gcloud(
            f"compute instances create {self.vm_name} "
            f"--zone={self.zone} "
            f"--machine-type={self.machine_type} "
            f"--image={self.snapshot} "
            f"--confidential-compute-type=TDX "
            f"--boot-disk-size=200GB "
            f"--no-address "  # No public IP
            f"--maintenance-policy=TERMINATE",
            timeout=180,
        )
        print(f"  VM created: {self.vm_name}")

    def _wait_ssh_ready(self, max_wait=300):
        """Wait for SSH to be available on the VM."""
        print("  Waiting for SSH...")
        start = time.time()
        while time.time() - start < max_wait:
            try:
                result = subprocess.run(
                    f"gcloud compute ssh {self.vm_name} --zone={self.zone} "
                    f"--command='echo ready' --ssh-flag='-o ConnectTimeout=5'",
                    shell=True, capture_output=True, text=True, timeout=15,
                )
                if "ready" in result.stdout:
                    print(f"  SSH ready after {int(time.time() - start)}s")
                    return
            except (subprocess.TimeoutExpired, Exception):
                pass
            time.sleep(10)
        raise RuntimeError(f"SSH not ready after {max_wait}s")

    def _open_tunnel(self, local_port=8090, remote_port=8090):
        """Open SSH tunnel to the VM."""
        print(f"  Opening SSH tunnel (localhost:{local_port} → VM:{remote_port})")
        self.tunnel_proc = subprocess.Popen(
            f"gcloud compute ssh {self.vm_name} --zone={self.zone} "
            f"-- -L {local_port}:localhost:{remote_port} -N -o ServerAliveInterval=30",
            shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        # Give tunnel a moment to establish
        time.sleep(3)
        if self.tunnel_proc.poll() is not None:
            raise RuntimeError("SSH tunnel failed to start")
        print("  Tunnel established")

    def _wait_enclave_ready(self, port=8090, max_wait=600):
        """Wait for the enclave runner to be healthy."""
        print("  Waiting for enclave runner...")
        start = time.time()
        while time.time() - start < max_wait:
            try:
                resp = urlopen(f"http://localhost:{port}/health", timeout=5)
                status = json.loads(resp.read())
                if status.get("status") == "ok":
                    print(f"  Enclave ready after {int(time.time() - start)}s")
                    return
            except Exception:
                pass
            time.sleep(10)
        raise RuntimeError(f"Enclave not ready after {max_wait}s")

    def _call_enclave(self, contract_state, epoch_context, system_prompt, seed, port=8090):
        """Send epoch state to enclave and get result."""
        payload = json.dumps({
            "contract_state": contract_state,
            "epoch_context": epoch_context,
            "system_prompt": system_prompt,
            "seed": seed,
        }).encode()

        req = Request(
            f"http://localhost:{port}/run_epoch",
            data=payload,
            headers={"Content-Type": "application/json"},
        )

        print("  Calling enclave for inference...")
        resp = urlopen(req, timeout=1800)  # 30 min timeout for CPU inference
        return json.loads(resp.read())

    def _cleanup(self):
        """Kill tunnel and delete VM."""
        if self.tunnel_proc:
            try:
                os.kill(self.tunnel_proc.pid, signal.SIGTERM)
                self.tunnel_proc.wait(timeout=5)
            except Exception:
                try:
                    os.kill(self.tunnel_proc.pid, signal.SIGKILL)
                except Exception:
                    pass
            self.tunnel_proc = None

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

        Returns the enclave result dict, with an added `vm_minutes` field
        indicating actual billable VM uptime.
        """
        vm_start = time.time()
        try:
            self._create_vm()
            self._wait_ssh_ready()
            self._open_tunnel()
            self._wait_enclave_ready()
            result = self._call_enclave(contract_state, epoch_context, system_prompt, seed)
            result["vm_minutes"] = (time.time() - vm_start) / 60
            return result
        finally:
            self._cleanup()
