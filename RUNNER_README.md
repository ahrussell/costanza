# Running a Human Fund Auction Runner

This guide explains how to participate as a runner in The Human Fund's auction system. Runners compete to execute the fund's AI inference each epoch, earning a bounty for their work.

## How It Works

Each epoch (24 hours in production), the fund runs a **commit-reveal sealed-bid auction**:

1. **COMMIT** — Runners submit sealed bid commitments with a bond
2. **REVEAL** — Runners reveal their actual bids
3. **EXECUTION** — The lowest bidder boots a TDX Confidential VM, runs AI inference, and submits the result with a cryptographic attestation proof
4. **SETTLEMENT** — The contract verifies the proof and pays the bounty

The attestation proof ensures the runner executed the approved code, with the approved model, on genuine Intel TDX hardware. The contract verifies:
- **RTMR[1]+[2]** — The VM booted the approved kernel (pinned GCP image version)
- **RTMR[3]** — The VM ran the approved enclave code + model weights
- **REPORTDATA** — The output (action + reasoning) was produced from the committed input, using the approved system prompt

## Prerequisites

- **GCP account** with Confidential VM (TDX) access
- **Base wallet** funded with ETH for bidding + gas (separate from the fund owner)
- **gcloud CLI** installed and authenticated
- **Python 3.9+** with pip
- **Foundry** (for contract ABIs)

## Option A: Use the Canonical Runner (Recommended)

### 1. Clone the Repository

```bash
git clone https://github.com/ahrussell/thehumanfund.git
cd thehumanfund
```

### 2. Install Dependencies

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install web3 flask pycryptodome eth_abi requests
```

### 3. Create a GCP Snapshot

Build a disk image with llama-server, model weights, and enclave code pre-installed:

```bash
# GPU (recommended — ~30s inference, ~$3/epoch)
python scripts/create_gcp_snapshot.py --gpu

# CPU (cheaper — ~22 min inference, ~$0.10/epoch)
python scripts/create_gcp_snapshot.py --cpu
```

This creates a GCP TDX Confidential VM, installs everything, and saves a disk image.

### 4. Verify Measurements

Confirm your snapshot produces the correct RTMR values that match what's registered on-chain:

```bash
python scripts/verify_measurements.py --contract 0x... --verifier 0x...
```

If the image key matches, your VM will pass attestation verification. If it doesn't match (e.g., GCP updated the base image), contact the fund owner to register the new measurements.

### 5. Configure

```bash
cp .env.example .env
# Edit .env with:
#   PRIVATE_KEY=0x...          # Your runner wallet (NOT the fund owner)
#   RPC_URL=https://...        # Base RPC endpoint
#   CONTRACT_ADDRESS=0x...     # TheHumanFund contract address
#   GCP_PROJECT=your-project   # Your GCP project ID
#   GCP_ZONE=us-central1-a     # GCP zone with TDX support
#   GCP_SNAPSHOT=humanfund-tee-gpu-70b  # Snapshot name from step 3
#   NTFY_CHANNEL=my-runner     # Optional: ntfy.sh notifications
```

### 6. Set Up Cron

The runner checks the auction state every 5 minutes and acts accordingly:

```bash
# Add to crontab:
*/5 * * * * cd /path/to/thehumanfund && source .venv/bin/activate && python -m runner.client 2>&1 | tee -a ~/.humanfund/runner.log
```

### 7. Monitor

If you configured `NTFY_CHANNEL`, you'll get push notifications for:
- Epoch started
- Bid committed/revealed
- Auction won/lost
- Result submitted
- Any errors

You can also check the log:
```bash
tail -f ~/.humanfund/runner.log
```

## Option B: Write Your Own Runner

You can write a custom runner with your own bid strategy, VM management, or monitoring. However, **the TEE enclave code and verification requirements are non-negotiable**.

### What You CAN Customize

- **Bid strategy** — How you calculate your bid (cost estimation, profit margin)
- **VM lifecycle** — How you create/manage GCP VMs (spot instances, pre-warming, etc.)
- **Notification system** — Slack, Discord, email, PagerDuty instead of ntfy.sh
- **Monitoring** — Dashboards, alerting, cost tracking
- **Scheduling** — How often you check the auction state

### What You CANNOT Change

For the attestation proof to pass on-chain verification, you MUST:

1. **Use the approved system prompt** — The system prompt's SHA-256 must match `approvedPromptHash` stored on-chain. Read it with:
   ```bash
   cast call $CONTRACT --rpc-url $RPC_URL "approvedPromptHash()(bytes32)"
   ```

2. **Run the pinned enclave code** — The Python files in `tee/enclave/` are measured into RTMR[3] at boot time. Any modification changes the measurement and fails verification. You must use the exact code from the approved git commit.

3. **Use the pinned model weights** — The model SHA-256 is hardcoded in `tee/enclave/model_config.py`. The enclave rejects any model that doesn't match. The model hash is also measured into RTMR[3].

4. **Boot the approved kernel** — Use the pinned GCP base image version. RTMR[1] (boot loader) and RTMR[2] (kernel) are determined by the GCP image and verified on-chain.

5. **Run on genuine Intel TDX hardware** — The DCAP attestation quote must come from real TDX hardware. GCP Confidential VMs with TDX are the supported platform.

### Verification Flow (What the Contract Checks)

```
submitAuctionResult(action, reasoning, proof, verifierId, ...)
│
├── 1. DCAP Verification (Automata)
│   └── Is this quote from genuine Intel TDX hardware?
│
├── 2. Image Registry (RTMR[1] + RTMR[2] + RTMR[3])
│   ├── RTMR[1]: Boot loader matches approved GCP image?
│   ├── RTMR[2]: Kernel matches approved GCP image?
│   └── RTMR[3]: Enclave code + model match approved hash?
│
├── 3. REPORTDATA Binding
│   ├── inputHash: Matches on-chain epochInputHashes[epoch]?
│   └── outputHash: keccak256(sha256(action) || sha256(reasoning) || approvedPromptHash)
│       └── sha256(inputHash || outputHash) == quote's REPORTDATA?
│
└── 4. Action Execution
    └── Contract executes the action (donate, invest, noop, etc.)
```

### TEE Client Interface

If you write your own runner, implement this interface to plug in your TEE management:

```python
class TEEClient:
    def run_epoch(self, contract_state, epoch_context, system_prompt, seed):
        """
        Args:
            contract_state: dict — Structured state for input hash verification
            epoch_context: str — Pre-built epoch context string
            system_prompt: str — System prompt (hash must match on-chain)
            seed: int — Randomness seed from block.prevrandao

        Returns:
            dict with keys:
                reasoning: str
                action: dict
                action_bytes: str ("0x...")
                attestation_quote: str ("0x...")
                report_data: str ("0x...")
                input_hash: str ("0x...")
        """
```

The enclave runner at `http://localhost:8090/run_epoch` accepts these as a JSON POST body and returns the result.

## Cost Estimates

| Configuration | VM Type | Inference Time | Boot Time | Per-Epoch Cost (On-Demand) |
|---|---|---|---|---|
| GPU (H100) | a3-highgpu-1g | ~30 seconds | ~5 minutes | ~$3.00 |
| CPU | c3-standard-4 | ~22 minutes | ~5 minutes | ~$0.10 |

Plus gas costs for `submitAuctionResult` (~12.5M gas for DCAP verification).

Spot/preemptible instances can reduce VM costs by 60-90%, but risk being preempted mid-inference.

## Troubleshooting

### RTMR Mismatch

If `verify_measurements.py` shows a mismatch, the GCP base image may have been updated. The fund owner needs to register the new RTMR values:

```bash
python scripts/register_image.py --vm-name your-vm --verifier 0x...
```

### Bond Forfeiture

If you win the auction but fail to submit a result within the execution window, your bond is forfeited to the fund treasury. Common causes:
- VM creation failed (GCP quota/capacity)
- Model failed to load (disk space, corruption)
- Inference timed out
- Network issues during submission

The runner client always deletes the VM in a `finally` block to avoid orphaned VMs accumulating costs.

### Gas Estimation

`submitAuctionResult` is expensive (~12.5M gas) due to DCAP attestation verification. The runner uses a 15M gas limit. If gas prices spike, your bid may not cover costs. Adjust `--bid-margin` to increase your buffer.

## Security Model

See [SECURITY.md](SECURITY.md) for the full TEE attestation security model and threat analysis.

Key properties:
- **Input integrity**: The TEE independently computes the input hash from structured state. Fake data produces a wrong hash, rejected by the contract.
- **Output integrity**: REPORTDATA binds the (input, output) pair to the TDX quote. Tampering with action or reasoning breaks the hash chain.
- **Code integrity**: RTMR[3] measures the enclave code and model weights. Modified code produces different measurements, rejected by the contract.
- **Deterministic inference**: The randomness seed (from `block.prevrandao`) makes inference reproducible. Anyone can verify results by re-running with the same seed.
