# Running a Human Fund Auction Runner

This guide explains how to participate as a runner in The Human Fund's auction system. Runners compete to execute the fund's AI inference each epoch, earning a bounty for their work.

## Architecture Overview

```
Your machine (Hetzner, home server, etc.)     GCP Confidential Cloud          Base blockchain
┌─────────────────────────────────────┐  ┌──────────────────────────┐  ┌──────────────────────┐
│  runner/client.py (cron, every 5m)  │  │  TDX H100 VM (per epoch) │  │  TheHumanFund.sol    │
│  ├── Check auction phase            │  │  ├── Boot from dm-verity  │  │  ├── Auction manager  │
│  ├── Submit bid + bond              │──│  ├── Run inference (~15s) │──│  ├── TDX verification │
│  ├── Create inference VM on GCP     │  │  ├── Generate TDX quote   │  │  ├── Action execution │
│  └── Submit result to chain         │  │  └── Output via serial    │  │  └── Diary entry      │
└─────────────────────────────────────┘  └──────────────────────────┘  └──────────────────────┘
```

The runner code runs on **any Linux machine** — it only needs Python, gcloud CLI, and an internet connection. Only the inference VM runs on GCP with TDX hardware.

## How It Works

Each epoch (configurable, e.g. 6 hours), the fund runs a **sealed-bid auction**:

1. **BIDDING** — Runners submit sealed bids with a bond (20% of bid)
2. **EXECUTION** — The lowest bidder boots a TDX Confidential VM, runs AI inference, and submits the result with a cryptographic attestation proof
3. **SETTLEMENT** — The contract verifies the proof, executes the action, and pays the bounty

The attestation proof ensures the runner executed the approved code, with the approved model, on genuine Intel TDX hardware. The contract verifies:
- **Platform key** = `sha256(MRTD || RTMR[1] || RTMR[2])` — firmware + boot loader + dm-verity rootfs (which transitively covers all enclave code, model weights, and system prompt)
- **REPORTDATA** = `sha256(inputHash || outputHash)` — binds the output to the committed input

## Key Separation

| Key | Purpose | What it holds | Where to store it |
|-----|---------|---------------|-------------------|
| **Owner key** | Contract admin: manage nonprofits, register images, enable auctions, freeze flags | Full treasury control | Hardware wallet. Never on a server. |
| **Runner key** | Bid in auctions, pay gas, post bond | ~0.05 ETH for gas + bond | On your runner machine, in `.env` |

The runner key is **not special** — anyone can be a runner. If your runner key is compromised, the attacker can only bid in auctions and waste your gas ETH. They cannot access the treasury.

## Prerequisites

- **GCP account** with Confidential VM (TDX) access and H100 GPU quota
- **Base wallet** funded with ETH for bidding + gas (separate from the fund owner)
- **gcloud CLI** installed and authenticated
- **Python 3.9+** with pip
- **Foundry** (for contract ABIs — `forge build` must work)

## Quick Start

### 1. Clone and Install

```bash
git clone https://github.com/ahrussell/thehumanfund.git
cd thehumanfund
python3 -m venv .venv
source .venv/bin/activate
pip install web3 pycryptodome eth_abi requests
forge build  # Generate ABIs
```

### 2. Build a dm-verity Image (or use the canonical one)

The inference VM boots from a dm-verity sealed disk image containing llama-server, model weights, and enclave code. If the fund owner publishes the canonical image name, you can skip this step.

To build your own (requires ~15 min for base image, ~10 min for sealed image):

```bash
# Build base image (once — installs NVIDIA drivers, CUDA, llama-server, model)
bash scripts/build_base_image.sh

# Build dm-verity sealed image (each time enclave code changes)
bash scripts/build_full_dmverity_image.sh \
  --base-image humanfund-base-gpu-llama-b5270 \
  --name humanfund-dmverity-gpu-mainnet-v1
```

### 3. Verify Measurements

Confirm your image produces RTMR values matching what's registered on-chain:

```bash
python scripts/verify_measurements.py \
  --vm-name <test-vm> \
  --verifier <TdxVerifier-address> \
  --rpc-url <rpc-url>
```

If the platform key matches, your VM will pass attestation. If not (e.g., GCP updated firmware), the fund owner needs to register the new key.

### 4. Configure

```bash
cp .env.example .env
# Edit .env — see .env.example for all options
```

Required variables:
- `PRIVATE_KEY` — Your runner wallet (NOT the fund owner key)
- `RPC_URL` — Base RPC endpoint (mainnet or testnet)
- `CONTRACT_ADDRESS` — TheHumanFund contract address
- `GCP_PROJECT` — Your GCP project ID
- `GCP_ZONE` — GCP zone with TDX support (e.g., `us-central1-a`)
- `GCP_IMAGE` — dm-verity disk image name

### 5. Test

```bash
# Dry run — logs what would happen without submitting transactions
python -m runner.client --dry-run
```

### 6. Set Up Cron

```bash
# Check auction state every 5 minutes, act accordingly
*/5 * * * * cd /path/to/thehumanfund && source .venv/bin/activate && python -m runner.client 2>&1 >> ~/.humanfund/runner.log
```

### 7. Monitor

If you set `NTFY_CHANNEL` in `.env`, you'll get push notifications for epoch starts, bids, wins/losses, submissions, and errors.

```bash
tail -f ~/.humanfund/runner.log
```

## Writing a Custom Runner

You can write a custom runner with your own bid strategy, VM management, or monitoring. The TEE enclave code and verification requirements are non-negotiable.

### What You CAN Customize

- **Bid strategy** — How you calculate your bid (cost estimation, profit margin)
- **VM lifecycle** — Spot instances, pre-warming, multi-region, etc.
- **Notifications** — Slack, Discord, email, PagerDuty
- **Monitoring** — Dashboards, alerting, cost tracking
- **Scheduling** — How often you check the auction state

### What You CANNOT Change

For attestation to pass on-chain:

1. **Enclave code** — The Python files in `tee/enclave/` are baked into the dm-verity rootfs. Any modification changes the rootfs hash (RTMR[2]) and fails verification.
2. **Model weights** — The 42.5GB GGUF model is on a separate dm-verity partition. SHA-256 verified at build time.
3. **System prompt** — Baked into the dm-verity rootfs at `/opt/humanfund/system_prompt.txt`.
4. **Kernel + boot loader** — RTMR[1] and RTMR[2] are determined by the GCP image.
5. **TDX hardware** — Must be genuine Intel TDX (GCP Confidential VMs).

### Verification Flow

```
submitAuctionResult(action, reasoning, attestationQuote)
│
├── 1. DCAP Verification (Automata Network)
│   └── Is this quote from genuine Intel TDX hardware?
│
├── 2. Platform Key Registry (TdxVerifier)
│   └── sha256(MRTD || RTMR[1] || RTMR[2]) matches an approved image?
│       (dm-verity rootfs hash in RTMR[2] transitively covers all code)
│
├── 3. REPORTDATA Binding
│   ├── inputHash matches on-chain epochInputHashes[epoch]?
│   └── sha256(inputHash || outputHash) == quote's REPORTDATA?
│
└── 4. Action Execution
    └── Contract executes the action (donate, invest, noop, etc.)
```

### TEE Client Interface

To plug in your own VM management, implement the `TEEClient` abstract base class:

```python
from runner.tee_clients.base import TEEClient

class MyTEEClient(TEEClient):
    def run_epoch(self, epoch_state: dict) -> dict:
        """
        Boot a TDX VM, run inference, return the result.

        Args:
            epoch_state: Full epoch state dict (treasury, nonprofits, history, etc.)

        Returns:
            dict with keys:
                reasoning: str — Chain-of-thought reasoning
                action_bytes: str — ABI-encoded action ("0x...")
                attestation_quote: str — Raw TDX DCAP quote ("0x...")
                report_data: str — REPORTDATA from the quote ("0x...")
                input_hash: str — Computed input hash ("0x...")
        """
```

The enclave is a one-shot program: it reads epoch state from GCP instance metadata, runs inference, and writes the result to serial console. No HTTP server, no SSH.

## Cost Estimates

| Configuration | VM Type | Inference Time | Boot Time | Per-Epoch Cost |
|---|---|---|---|---|
| GPU (H100) | a3-highgpu-1g | ~15 seconds | ~5 minutes | ~$3.00 (on-demand) |

Plus gas costs for `submitAuctionResult` (~10-12M gas for DCAP verification).

Spot instances can reduce VM costs by 60-90%, but risk preemption mid-inference.

## Troubleshooting

### Image Key Mismatch

If `verify_measurements.py` shows a mismatch, either:
- You built the image from different code than what's registered
- GCP updated their firmware (changes MRTD)

The fund owner registers new images via:
```bash
python scripts/register_image.py --vm-name <vm> --verifier <addr> --rpc-url <rpc>
```

### Bond Forfeiture

If you win the auction but fail to submit within the execution window, your bond (20% of bid) is forfeited to the treasury. Common causes:
- VM creation failed (GCP quota/capacity)
- Model failed to load
- Inference timed out
- Network issues during submission

The runner always deletes the VM in a `finally` block to avoid orphaned VMs.

### Gas Estimation

`submitAuctionResult` costs ~10-12M gas due to DCAP attestation verification. The runner uses a 15M gas limit. If gas prices spike, your bid may not cover costs. Adjust `BID_MARGIN` in `.env` to increase your buffer.

## Security Model

See [SECURITY_MODEL.md](SECURITY_MODEL.md) for the full trust model, accepted risks, and attestation architecture.

Key properties:
- **Input integrity**: The TEE independently computes the input hash and verifies all display data matches opaque hashes. Fake data is rejected.
- **Output integrity**: REPORTDATA binds the (input, output) pair to the TDX quote. Tampering with action or reasoning breaks the hash chain.
- **Code integrity**: dm-verity ensures the rootfs is immutable. Any modification causes I/O errors at the kernel level.
- **Deterministic inference**: The randomness seed (from `block.prevrandao`) makes inference reproducible.
