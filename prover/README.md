# Running a Costanza Prover

This guide explains how to participate as a prover in Costanza's auction system. Provers compete to execute the agent's AI inference each epoch, earning a bounty for their work.

## Architecture

```
Your machine (any Linux server)           TEE Hardware                    Base blockchain
┌──────────────────────────────┐  ┌─────────────────────────┐  ┌──────────────────────────┐
│  prover client (cron, 5min)  │  │  Confidential VM         │  │  TheHumanFund.sol        │
│  ├── Check auction phase     │  │  ├── dm-verity rootfs    │  │  ├── Auction manager      │
│  ├── Submit bid + bond       │──│  ├── Run inference       │──│  ├── Attestation verifier │
│  ├── Create inference VM     │  │  ├── Generate TEE quote  │  │  ├── Action execution     │
│  └── Submit result to chain  │  │  └── Serial console out  │  │  └── Diary entry          │
└──────────────────────────────┘  └─────────────────────────┘  └──────────────────────────┘
```

The prover client runs on **any Linux machine** — it only needs Python, a cloud CLI, and an internet connection. Only the inference VM requires TEE hardware.

## Mainnet Deployment

| | Address / Value |
|---|---|
| **TheHumanFund** | [`0x678dC1756b123168f23a698374C000019e38318c`](https://basescan.org/address/0x678dC1756b123168f23a698374C000019e38318c) |
| **TdxVerifier** | [`0xfE45dF36FA94f9d119332456E3925cD93B963c93`](https://basescan.org/address/0xfE45dF36FA94f9d119332456E3925cD93B963c93) |
| **AuctionManager** | [`0x976AeAfe1F708e1Ef0d0C0d26203CC4D7503f6EC`](https://basescan.org/address/0x976AeAfe1F708e1Ef0d0C0d26203CC4D7503f6EC) |
| **Chain** | Base Mainnet (8453) |
| **RPC** | `https://mainnet.base.org` |
| **Current image** | **`costanza-tdx-prover-v4`** — platform key `0x8e67d4d809121b238890c1537d2bfddc9d7b200b89e736015ec786043e9e0992` ([measurements](scripts/gcp/costanza-tdx-prover-v4-measurements.txt)) |
| **Image distribution** | Public R2 — `https://pub-ed740777c1434c748a0dc239f0c37ee7.r2.dev/<image-name>/disk.tar.gz` (see step 2) |

To run as a prover, import the published image into your own GCP project and verify on-chain that its measurements match the registered platform key. Building from source is not currently a supported verification path: OS-level non-determinism (timestamps, package mirrors, kernel module signing) drifts the rootfs hash even with identical inputs, so a from-source build is not guaranteed to produce a byte-identical platform key. The trust path is on-chain measurement match, not build reproducibility.

### TEE Platform Support

The system is designed to be platform-agnostic. The TdxVerifier contract can approve multiple platform keys, each corresponding to a different TEE environment:

| Platform | Status | Machine Type | Notes |
|----------|--------|-------------|-------|
| **GCP TDX** (H100) | Production | `a3-highgpu-1g` | Reference implementation. Intel TDX via GCP Confidential VMs. |
| **dstack** | Planned | Various | Container-based TEE. Would need a DstackVerifier contract. |

The initial approved platform measurement is for GCP TDX on `a3-highgpu-1g` (NVIDIA H100). Additional platforms can be supported by deploying new verifier contracts and registering their measurements.

## How It Works

Each epoch (configurable, e.g., 6 hours), the fund runs a **sealed-bid auction**:

1. **BIDDING** — Provers submit sealed bids with a bond (20% of bid)
2. **EXECUTION** — The lowest bidder boots a TEE VM, runs AI inference, and submits the result with a cryptographic attestation proof
3. **SETTLEMENT** — The contract verifies the proof, executes the action, and pays the bounty

The attestation proof ensures the prover executed the approved code, with the approved model, on genuine TEE hardware. The contract verifies:
- **Platform key** = `sha256(MRTD || RTMR[1] || RTMR[2])` — covers firmware + boot loader + dm-verity rootfs (which transitively covers all enclave code, model weights, and system prompt)
- **REPORTDATA** = `sha256(inputHash || outputHash)` — binds the output to the committed input

## Key Separation

| Key | Purpose | What it holds | Where to store it |
|-----|---------|---------------|-------------------|
| **Owner key** | Contract admin: manage nonprofits, register images, enable auctions, freeze flags | Full treasury control | Hardware wallet. Never on a server. |
| **Prover key** | Bid in auctions, pay gas, post bond | ~0.05 ETH for gas + bond | On your prover machine, in `.env` |

The prover key is **not special** — anyone can be a prover. If your key is compromised, the attacker can only bid in auctions and waste your gas ETH. They cannot access the treasury.

## Prerequisites

- **TEE-capable cloud account** (GCP with Confidential VM access for the reference implementation)
- **Base wallet** funded with ETH for bidding + gas (separate from the fund owner)
- **Cloud CLI** installed and authenticated (e.g., `gcloud` for GCP)
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

### 2. Import the dm-verity Image

The inference VM boots from a dm-verity sealed disk image containing the inference server, model weights, and enclave code. The fund owner publishes each production image to a public Cloudflare R2 bucket; you import it into your own GCP project, verify the SHA256 against the published `metadata.json` sidecar in transit, then verify on-chain that the imported image's RTMR measurements match the registered platform key.

```bash
export GCP_PROJECT=your-gcp-project
export GCP_STAGING_BUCKET=gs://your-staging-bucket   # must already exist

bash prover/scripts/gcp/import_image.sh costanza-tdx-prover-v4
```

The script downloads the tarball from R2 (free egress), verifies its SHA256 against the published `metadata.json`, uploads to your GCS staging bucket, creates the GCP image, and prints the next-step verification command. Allow ~15-30 min depending on your network.

The published image's `metadata.json` lives at `<PUBLIC_BASE>/<image-name>/metadata.json` and contains the SHA256, byte size, and export timestamp. The default `PUBLIC_BASE` baked into the import script is `https://pub-ed740777c1434c748a0dc239f0c37ee7.r2.dev`.

### 3. Verify Measurements On-Chain

This is the actual trust boundary — SHA256 only catches transit corruption. The on-chain check boots a temporary TDX VM, reads RTMRs from the serial console (no SSH required), computes `sha256(MRTD || RTMR[1] || RTMR[2])`, and asks the `TdxVerifier` contract whether that platform key is approved:

```bash
python prover/scripts/gcp/verify_measurements.py \
  --image costanza-tdx-prover-v4 \
  --verifier 0xfE45dF36FA94f9d119332456E3925cD93B963c93 \
  --rpc-url https://mainnet.base.org
```

A green check means the imported image matches what's registered on-chain and you can run as a prover with it. A mismatch means the publisher rotated images — re-import the current one (see the **Current image** row at the top of this README) or open an issue if `metadata.json` references a version that's no longer registered.

The script works with hardened dm-verity images (SSH disabled) by reading measurements between `===HUMANFUND_MEASUREMENTS_START===` and `===HUMANFUND_MEASUREMENTS_END===` markers on the serial console.

### 4. Configure

```bash
cp .env.example .env
# Edit .env — see .env.example for all options
```

Required variables:
- `PRIVATE_KEY` — Your prover wallet (NOT the fund owner key)
- `RPC_URL` — Base RPC endpoint (mainnet or testnet)
- `CONTRACT_ADDRESS` — TheHumanFund contract address
- `GCP_PROJECT` — Your cloud project ID
- `GCP_ZONE` — Cloud zone with TEE support
- `GCP_IMAGE` — dm-verity disk image name

### 5. Test

```bash
# Run once manually to verify configuration
python -m prover.client

# For local simulation without a live contract, use:
python scripts/simulate.py
```

### 6. Set Up Cron

```bash
SHELL=/bin/bash
# Check auction state every 5 minutes, act accordingly
*/5 * * * * cd /path/to/thehumanfund && set -a && source .env && set +a && source .venv/bin/activate && python -m prover.client 2>&1 >> ~/prover.log
```

### 7. Monitor

If you set `NTFY_CHANNEL` in `.env`, you'll get push notifications for epoch starts, bids, wins/losses, submissions, and errors.

```bash
tail -f ~/prover.log
```

## Writing a Custom Prover

You can write a custom prover with your own bid strategy, VM management, or monitoring. The TEE enclave code and verification requirements are non-negotiable.

### What You CAN Customize

- **Bid strategy** — How you calculate your bid (cost estimation, profit margin)
- **VM lifecycle** — Spot instances, pre-warming, multi-region, different cloud providers
- **Notifications** — Slack, Discord, email, PagerDuty
- **Monitoring** — Dashboards, alerting, cost tracking
- **Scheduling** — How often you check the auction state

### What You CANNOT Change

For attestation to pass on-chain:

1. **Enclave code** — The Python files in `prover/enclave/` are baked into the dm-verity rootfs. Any modification changes the rootfs hash (RTMR[2]) and fails verification.
2. **Model weights** — The Hermes 4 70B Q6_K split GGUF (two parts, ~58GB total) is on a separate dm-verity partition. SHA-256 verified per-part at build time.
3. **System prompt** — Baked into the dm-verity rootfs at `/opt/humanfund/system_prompt.txt`.
4. **Kernel + boot loader** — RTMR[1] and RTMR[2] are determined by the disk image.
5. **TEE hardware** — Must be genuine hardware with attestation support (Intel TDX for the reference implementation).

### Verification Flow

```
submitAuctionResult(action, reasoning, attestationQuote)
│
├── 1. DCAP Verification (Automata Network)
│   └── Is this quote from genuine TEE hardware?
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
    └── Contract executes the action (donate, invest, do_nothing, etc.)
```

### TEE Client Interface

To plug in your own VM management, implement the `TEEClient` abstract base class:

```python
from prover.client.tee_clients.base import TEEClient

class MyTEEClient(TEEClient):
    def run_epoch(self, epoch_state: dict) -> dict:
        """
        Boot a TEE VM, run inference, return the result.

        Args:
            epoch_state: Full epoch state dict (treasury, nonprofits, history, etc.)

        Returns:
            dict with keys:
                reasoning: str
                action_bytes: str ("0x...")
                attestation_quote: str ("0x...")
                report_data: str ("0x...")
                input_hash: str ("0x...")
        """
```

The enclave is a one-shot program: it reads epoch state from VM metadata, runs inference, and writes the result to serial console. No HTTP server, no SSH.

## Cost Estimates

| Configuration | VM Type | Inference Time | Per-Epoch Cost |
|---|---|---|---|
| GCP GPU (H100) | a3-highgpu-1g | ~15 seconds | ~$3.00 (on-demand) |

Plus gas costs for `submitAuctionResult` (~10-12M gas for DCAP verification).

Spot instances can reduce VM costs by 60-90%, but risk preemption mid-inference.

## Troubleshooting

### Image Key Mismatch

If `verify_measurements.py` shows a mismatch, the image you imported isn't the one currently approved on-chain. Possible causes:
- The publisher rotated the image and you imported an older version — check the project for the latest version name and re-run `import_image.sh` with that name.
- The cloud provider updated firmware (changes MRTD) — wait for the publisher to re-register against the new firmware level, or open an issue.

Image registration is a publisher-only operation (`register_image.py`). Running it from a non-owner key on the `TdxVerifier` will revert.

### Bond Forfeiture

If you win the auction but fail to submit within the execution window, your bond (20% of bid) is forfeited to the treasury. Common causes:
- VM creation failed (cloud quota/capacity)
- Model failed to load
- Inference timed out
- Network issues during submission

The prover always deletes the VM in a `finally` block to avoid orphaned VMs.

### Gas Estimation

`submitAuctionResult` costs ~10-12M gas due to DCAP attestation verification. The prover uses a 15M gas limit. If gas prices spike, your bid may not cover costs. Adjust `BID_MARGIN` in `.env` to increase your buffer.

## Security Model

See [WHITEPAPER.md](../WHITEPAPER.md) for the full trust model, accepted risks, and attestation architecture.

Key properties:
- **Input integrity**: The TEE independently computes the input hash and verifies all display data matches opaque hashes. Fake data is rejected.
- **Output integrity**: REPORTDATA binds the (input, output) pair to the TEE quote. Tampering with action or reasoning breaks the hash chain.
- **Code integrity**: dm-verity ensures the rootfs is immutable. Any modification causes I/O errors at the kernel level.
- **Deterministic inference**: The randomness seed (from `block.prevrandao`) makes inference reproducible.

