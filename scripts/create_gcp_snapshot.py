#!/usr/bin/env python3
"""Create a GCP TDX Confidential VM disk image (snapshot) for TEE inference.

Boots a fresh VM, installs dependencies (NVIDIA/CUDA for GPU, llama.cpp, model,
enclave code), then creates a disk image from the boot disk. Runners boot from
this image for fast startup (~2 min vs ~15 min fresh install).

Usage:
    python scripts/create_gcp_snapshot.py               # GPU (default)
    python scripts/create_gcp_snapshot.py --cpu          # CPU only
    python scripts/create_gcp_snapshot.py --force        # Overwrite existing
    python scripts/create_gcp_snapshot.py --keep-vm      # Don't delete VM after
"""

import argparse
import subprocess
import sys
import time
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent

# Pinned GCP base image for reproducible RTMR[1]+[2] values
GCP_BASE_IMAGE_FAMILY = "ubuntu-2404-lts-amd64"
GCP_BASE_IMAGE_PROJECT = "ubuntu-os-cloud"

DEFAULT_ZONE = "us-central1-a"
GPU_MACHINE_TYPE = "a3-highgpu-1g"
CPU_MACHINE_TYPE = "c3-standard-4"


def gcloud(args, check=True, timeout=300):
    """Run a gcloud command and return stdout."""
    result = subprocess.run(
        f"gcloud {args}", shell=True, capture_output=True, text=True, timeout=timeout
    )
    if check and result.returncode != 0:
        print(f"gcloud error: {result.stderr[:500]}", file=sys.stderr)
        raise RuntimeError(f"gcloud failed: {result.stderr[:200]}")
    return result.stdout.strip()


def image_exists(image_name):
    """Check if a GCP disk image already exists."""
    try:
        result = gcloud(f"compute images describe {image_name} --format='value(status)'", check=False)
        return "READY" in result
    except Exception:
        return False


def create_vm(vm_name, zone, machine_type, use_gpu):
    """Create a fresh GCP TDX Confidential VM."""
    print(f"\n  Creating VM: {vm_name}")
    print(f"    Zone: {zone}")
    print(f"    Machine type: {machine_type}")
    print(f"    Base image: {GCP_BASE_IMAGE_FAMILY}")

    gcloud(
        f"compute instances create {vm_name} "
        f"--zone={zone} "
        f"--machine-type={machine_type} "
        f"--image-family={GCP_BASE_IMAGE_FAMILY} "
        f"--image-project={GCP_BASE_IMAGE_PROJECT} "
        f"--confidential-compute-type=TDX "
        f"--boot-disk-size=200GB "
        f"--maintenance-policy=TERMINATE",
        timeout=180,
    )
    print("  VM created, waiting for SSH...")

    # Wait for SSH
    for i in range(30):
        try:
            result = gcloud(
                f"compute ssh {vm_name} --zone={zone} "
                f"--command='echo ready' --ssh-flag='-o ConnectTimeout=5'",
                check=False, timeout=15,
            )
            if "ready" in result:
                print(f"  SSH ready after {i * 10}s")
                return
        except Exception:
            pass
        time.sleep(10)
    raise RuntimeError("SSH not ready after 5 minutes")


def upload_and_run_setup(vm_name, zone, use_gpu):
    """Upload enclave code and setup script, then run setup."""
    # Upload enclave code
    enclave_dir = PROJECT_ROOT / "tee" / "enclave"
    boot_script = PROJECT_ROOT / "tee" / "boot.sh"
    setup_script = PROJECT_ROOT / "tee" / ("setup_gpu.sh" if use_gpu else "setup_cpu.sh")

    print("\n  Uploading enclave code...")
    gcloud(f"compute scp --recurse {enclave_dir} {vm_name}:/tmp/enclave --zone={zone}", timeout=60)
    gcloud(f"compute scp {boot_script} {vm_name}:/tmp/boot.sh --zone={zone}", timeout=30)
    gcloud(f"compute scp {setup_script} {vm_name}:/tmp/setup.sh --zone={zone}", timeout=30)

    print("  Running setup script (this takes 10-30 minutes)...")
    gcloud(
        f"compute ssh {vm_name} --zone={zone} "
        f"--command='sudo bash /tmp/setup.sh'",
        timeout=3600,  # 1 hour max
    )
    print("  Setup complete!")


def create_disk_image(vm_name, image_name, zone):
    """Stop VM and create a disk image from its boot disk."""
    print(f"\n  Stopping VM for snapshot...")
    gcloud(f"compute instances stop {vm_name} --zone={zone}", timeout=120)

    print(f"  Creating disk image: {image_name}")
    gcloud(
        f"compute images create {image_name} "
        f"--source-disk={vm_name} "
        f"--source-disk-zone={zone} "
        f"--force",
        timeout=600,
    )
    print(f"  Image created: {image_name}")

    # Restart VM (so it can be used for measurement extraction)
    gcloud(f"compute instances start {vm_name} --zone={zone}", timeout=120)
    print("  VM restarted")


def delete_vm(vm_name, zone):
    """Delete the VM."""
    print(f"\n  Deleting VM: {vm_name}")
    gcloud(f"compute instances delete {vm_name} --zone={zone} --quiet", check=False, timeout=120)
    print("  VM deleted")


def main():
    parser = argparse.ArgumentParser(description="Create GCP TDX disk image for TEE inference")
    parser.add_argument("--cpu", action="store_true", help="CPU-only setup (no GPU)")
    parser.add_argument("--name", help="Custom image name (default: humanfund-tee-{gpu|cpu}-70b)")
    parser.add_argument("--zone", default=DEFAULT_ZONE, help=f"GCP zone (default: {DEFAULT_ZONE})")
    parser.add_argument("--force", action="store_true", help="Overwrite existing image")
    parser.add_argument("--keep-vm", action="store_true", help="Don't delete VM after creating image")
    args = parser.parse_args()

    use_gpu = not args.cpu
    machine_type = CPU_MACHINE_TYPE if args.cpu else GPU_MACHINE_TYPE
    image_name = args.name or f"humanfund-tee-{'cpu' if args.cpu else 'gpu'}-70b"
    vm_name = f"humanfund-snapshot-builder-{int(time.time()) % 10000}"

    print(f"═══ Creating GCP TDX Snapshot ═══")
    print(f"  Mode: {'CPU' if args.cpu else 'GPU'}")
    print(f"  Image name: {image_name}")
    print(f"  Machine type: {machine_type}")

    if image_exists(image_name) and not args.force:
        print(f"\n  Image '{image_name}' already exists. Use --force to overwrite.")
        sys.exit(1)

    if image_exists(image_name) and args.force:
        print(f"\n  Deleting existing image '{image_name}'...")
        gcloud(f"compute images delete {image_name} --quiet", check=False, timeout=60)

    try:
        create_vm(vm_name, args.zone, machine_type, use_gpu)
        upload_and_run_setup(vm_name, args.zone, use_gpu)
        create_disk_image(vm_name, image_name, args.zone)
        print(f"\n═══ Snapshot created: {image_name} ═══")
        print(f"\nNext steps:")
        print(f"  1. Extract measurements: python scripts/register_image.py --vm-name {vm_name} --zone {args.zone}")
        print(f"  2. Register image key on-chain")
        print(f"  3. Delete VM: gcloud compute instances delete {vm_name} --zone={args.zone}")
    except Exception as e:
        print(f"\nERROR: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        if not args.keep_vm:
            delete_vm(vm_name, args.zone)


if __name__ == "__main__":
    main()
