# The Human Fund

An autonomous AI agent on the Base blockchain that manages a charitable treasury, making daily decisions about donations, growth, and self-preservation. Its reasoning is published on-chain as a public diary.

## Project Overview

- **Smart contract** (Solidity, Base L2): Treasury, referral system, epoch actions, reverse auction, TEE attestation, diary events
- **Agent inference**: DeepSeek R1 Distill Llama 70B (Q4_K_M, 42.5GB GGUF) via llama.cpp on GCP TDX H100 (production model)
- **Model selection**: DeepSeek R1 70B chosen via 3-model gauntlet (75 epochs each): 100% parse success, best reasoning depth, diversified investment strategy. Llama 3.3 70B also 100% reliable but less strategic. QwQ 32B eliminated (23% parse failure rate).
- **Runner client** (`runner/`): Cron-based auction runner — monitors phases, bids, orchestrates GCP TEE VMs
- **TEE enclave** (`tee/enclave/`): Attested Python code measured into RTMR[3] — inference, action encoding, attestation
- **Frontend**: Diary viewer, treasury dashboard, donation/referral interface (Phase 4)

## Current Status

**Full e2e attestation verified on Base Sepolia with GCP TDX H100 GPU.** 5 straight successful epochs with DeepSeek R1 70B on H100. DCAP + image registry + REPORTDATA all pass on-chain.

- **Phase 3 contract (latest, 70B GPU e2e)**: `0xa507366987417e0E4247a827B48536DA11235CC7` (Base Sepolia) — 5 consecutive successful epochs with investments, withdrawals, and guiding policies
- **Phase 2 contract (CPU e2e)**: `0x9043B54B7E5d2f98Bc12ff10799cf8d5d38c7ab2` (Base Sepolia) — CPU + GPU verified
- Phase 0 original contract: `0x2F213Ea0D3F6D8349e2162b37Cc8cE6605dc9420` (Base Sepolia) — 21 epochs executed (legacy)
- **164 tests pass** (28 Phase 0 + 42 auction + 16 TDX verifier + 25 investment + 16 worldview + 14 messages + 23 other)
- Contract sizes: TheHumanFund ~24.2KB (374B margin, optimizer enabled), AttestationVerifier ~3.4KB, InvestmentManager ~10.4KB, WorldView ~2.6KB
- GCP TDX FMSPC `00806f050000` registered in Automata DCAP Dashboard
- CPU image key (c3-standard-4): `0x1ff10986...` — approved
- GPU image key (a3-highgpu-1g, H100): `0xababa83b...` — approved
- **E2E gas costs**: deployment ~5.1M, DCAP verification ~10-12M (15M limit recommended)
- **GPU inference**: ~30s per epoch on H100 (vs ~22 min on CPU)
- **GCP snapshot**: `humanfund-gpu-70b-boot-v1` — boot disk with llama.cpp CUDA build
- **Model gauntlet**: 3 models tested across 75-epoch scenario (honeymoon → boom → crisis → drought → recovery → endgame). DeepSeek R1 70B: 6.12 ETH donated, 3.05 ETH final assets, diversified across 3 protocols. Llama 3.3 70B: 7.20 ETH donated but only 2.00 ETH final assets (less sustainable). QwQ 32B: 0.80 ETH donated, 17 parse failures.
- **Remaining**: message spotlighting (prompt injection defense), production Docker image, audit, mainnet deployment
- Deployer address: `0xffea30B0DbDAd460B9b6293fb51a059129fCCdAf`

**DESIGN.md is a living document** — see it for the full specification and implementation checklist.
**SECURITY.md** — formal TEE attestation security model, threat analysis, and implementation spec for contract verification.

## Architecture

Each epoch (24 hours in production, configurable for testnet):

### Phase 0 (current testnet): Direct submission
1. Runner reads contract state (treasury, nonprofits, epoch history)
2. Runner constructs prompt from system prompt + epoch context + decision history
3. Runner calls llama.cpp server for inference (two-pass: reasoning then action)
4. Runner parses output, encodes action, submits to contract
5. Contract validates bounds, executes action, emits DiaryEntry event

### Phase 2 (auction mode): Permissionless runners
1. Anyone calls `startEpoch()` — opens bidding, commits input hash
2. Runners submit bids during bidding window (1 hour production)
3. Anyone calls `closeAuction()` — lowest bid wins, bond locked, `prevrandao` captured for RNG seed
4. Winner boots TEE, mounts model (verified via SHA-256), runs inference with deterministic seed
5. Winner submits via `submitAuctionResult()` — contract verifies:
   - Automata DCAP: quote is genuine TDX hardware
   - RTMR[1..3]: approved boot loader, kernel, and application code were running
   - REPORTDATA: `SHA256(inputHash || SHA256(action) || SHA256(reasoning))` matches
6. Contract executes action, pays bounty + refunds bond
7. If winner doesn't deliver: anyone calls `forfeitBond()`, bond kept by treasury

## Key Design Decisions

- **USD-denominated mission**: Agent's goal is to maximize USD donated, not ETH. Chainlink ETH/USD price is snapshotted each epoch and included in the inputHash. Donations are tracked in both ETH and USDC (actual swap output). The model sees all values in both ETH and USD.
- **Single action per epoch**: donate, set_commission_rate, set_max_bid, invest, withdraw, set_guiding_policy, or noop
- **Donor messages**: donateWithMessage() accepts a string (max 280 chars, min 0.01 ETH). Messages queued, up to 20 per epoch shown to model with datamarking spotlighting (whitespace replaced with dynamic marker token) to mitigate prompt injection — based on [Hines et al. 2024](https://arxiv.org/abs/2403.14720)
- **Hard bounds enforced by contract**: max 10% treasury donated/epoch, commission 1-90%, max bid 0.0001 ETH to 2% treasury, investment bounds 80% max / 25% per protocol / 20% min reserve
- **No free-text input fields** — prompt injection mitigated by structured numeric/address data only
- **Two-pass inference**: Pass 1 generates reasoning (stop at `</think>`), Pass 2 generates JSON action (lower temperature)
- **Auto-escalation**: missed epochs automatically raise bid ceiling by 10% (compounding) until a runner accepts
- **Reverse auction**: First-price sealed-bid, 20% bond, inline refunds when outbid
- **Epoch state machine**: IDLE → BIDDING → EXECUTION → SETTLED with configurable timing
- **Verifiable randomness**: RNG seed derived from `block.prevrandao` at auction close — runner cannot re-roll inference
- **Model loaded from disk**: Runner provides model file, enclave verifies SHA-256 hash baked into image — no runtime download
- **Platform-agnostic attestation**: Verify RTMR[1] (boot loader) + RTMR[2] (kernel) + RTMR[3] (application code) — skip MRTD and RTMR[0] which vary by firmware
- **Rolling history hash**: On-chain `historyHash` extended each epoch, binds decision history to input commitment
- **Full design doc**: See DESIGN.md for complete specification
- **Security model**: See SECURITY.md for TEE attestation analysis and threat model

## Implementation Phases

- **Phase 0** (COMPLETE): End-to-end loop on testnet with trusted operator, no TEE
- **Phase 1** (COMPLETE): TEE integration — TDX attestation, on-chain DCAP verification, RTMR[1..3] image registry
- **Phase 2** (COMPLETE): Reverse auction — contract + runner deployed, full attestation verified on Base Sepolia (CPU + GPU TDX)
- **Phase 3** (IN PROGRESS): Investment portfolio — InvestmentManager + 7 adapters (Aave WETH/USDC, wstETH, cbETH, Compound USDC, Morpho Gauntlet/Steakhouse WETH), 137 tests pass, Chainlink ETH/USD oracle, system prompt v6
- **Phase 4**: Frontend (diary viewer, treasury dashboard, investment portfolio UI)
- **Phase 5**: Audit and mainnet deployment

## Tech Stack

- **Chain**: Base (Coinbase L2), Solidity ^0.8.20
- **Inference**: llama.cpp + DeepSeek R1 Distill Llama 70B Q4_K_M (GCP TDX H100, production)
- **TEE**: Intel TDX on GCP Confidential VMs (configfs-tsm attestation)
- **Attestation**: Automata Network DCAP contracts at `0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F`
- **Oracle**: Chainlink ETH/USD price feed (shared interface `IAggregatorV3.sol`, used by main contract + USDC adapters)
- **Tooling**: Foundry (Solidity), Python 3.9+ with venv (runner + enclave)

## Python Environment

```bash
# Set up venv (first time)
python3 -m venv .venv
source .venv/bin/activate
pip install flask web3 requests

# Activate venv (each session)
source .venv/bin/activate
```

All Python commands (runner, enclave runner, etc.) should be run inside the venv.

## Project Structure

```
thehumanfund/
├── CLAUDE.md                    # This file — project context for Claude
├── DESIGN.md                    # Full design specification (living document)
├── SECURITY.md                  # TEE attestation security model and threat analysis
├── foundry.toml                 # Foundry configuration
├── .venv/                       # Python virtual environment (gitignored)
├── src/
│   ├── TheHumanFund.sol         # Main smart contract (Phase 0-3, 23.8KB)
│   ├── AttestationVerifier.sol  # TEE attestation verification (3.4KB)
│   ├── InvestmentManager.sol    # DeFi portfolio manager (10.4KB)
│   ├── WorldView.sol            # Agent worldview — 10 guiding policy slots
│   ├── interfaces/
│   │   ├── IAggregatorV3.sol            # Chainlink V3 price feed interface
│   │   ├── IAutomataDcapAttestation.sol  # Automata DCAP interface
│   │   ├── IAttestationVerifier.sol     # Attestation verifier interface
│   │   ├── IInvestmentManager.sol       # Investment manager interface
│   │   ├── IERC4626.sol                 # Minimal ERC-4626 vault interface
│   │   ├── IProtocolAdapter.sol         # Protocol adapter interface
│   │   └── IWorldView.sol               # WorldView interface
│   └── adapters/                # DeFi protocol adapters
│       ├── AaveV3WETHAdapter.sol    # Aave V3 ETH lending
│       ├── AaveV3USDCAdapter.sol    # Aave V3 USDC lending (with ETH swap)
│       ├── WstETHAdapter.sol        # Lido wstETH liquid staking
│       ├── CbETHAdapter.sol         # Coinbase cbETH staking
│       ├── CompoundV3USDCAdapter.sol # Compound V3 USDC lending
│       ├── MorphoWETHAdapter.sol    # Morpho ERC-4626 WETH vaults (Gauntlet, Steakhouse)
│       ├── SwapHelper.sol           # Shared ETH<->USDC swap logic
│       └── IWETH.sol                # WETH9 interface
├── test/
│   ├── TheHumanFund.t.sol       # Phase 0 tests (28 tests)
│   ├── TheHumanFundAuction.t.sol # Phase 2 auction + attestation tests (34 tests)
│   ├── AttestationVerifier.t.sol # Verifier unit tests (12 tests)
│   ├── InvestmentManager.t.sol  # Investment tests (25 tests)
│   ├── WorldView.t.sol          # Worldview tests (16 tests)
│   └── Messages.t.sol           # Donor messages tests (14 tests)
├── script/
│   └── Deploy.s.sol             # Foundry deployment script
├── runner/                      # Auction runner client (cron job, untrusted)
│   ├── client.py               # Main entry point — checks phase, acts accordingly
│   ├── chain.py                # Contract interaction (read state, submit tx)
│   ├── auction.py              # Auction state machine (commit/reveal/submit)
│   ├── bid_strategy.py         # Bid calculation (gas + compute + margin)
│   ├── notifier.py             # ntfy.sh push notifications
│   ├── state.py                # Persistent state (~/.humanfund/state.json)
│   ├── config.py               # CLI args + env var configuration
│   └── tee_clients/
│       ├── base.py             # ABC: run_epoch() → result
│       └── gcp.py              # GCP TDX VM lifecycle (create → tunnel → call → delete)
├── agent/
│   ├── runner_legacy.py        # Legacy runner (reference, to be removed)
│   ├── prompts/
│   │   └── system_v6.txt       # System prompt v6 (USD mission, ETH/USD price)
│   └── scenarios/
│       └── scenarios.json      # 5 synthetic test scenarios
├── tee/                         # TEE enclave + VM setup
│   ├── enclave/                # Attested code (measured into RTMR[3])
│   │   ├── enclave_runner.py   # Flask API: /health, /run_epoch
│   │   ├── inference.py        # Two-pass llama-server calls
│   │   ├── action_encoder.py   # Action JSON → contract bytes
│   │   ├── input_hash.py       # Independent input hash computation
│   │   ├── prompt_builder.py   # System prompt + epoch context → full prompt
│   │   ├── attestation.py      # TDX quote generation (configfs-tsm)
│   │   └── model_config.py     # Pinned model SHA-256 + verification
│   ├── enclave_runner.py       # Legacy enclave runner (reference, to be removed)
│   ├── boot.sh                 # VM boot: measure code+model into RTMR[3], start services
│   ├── setup_gpu.sh            # Snapshot setup: NVIDIA + CUDA + llama.cpp + model
│   └── setup_cpu.sh            # Snapshot setup: CPU llama.cpp + model
├── frontend/
│   └── index.html               # Internal dashboard (reads contract state)
├── models/                      # Local model files (gitignored)
├── scripts/
│   ├── create_gcp_snapshot.py   # Build GCP TDX disk image (GPU or CPU)
│   ├── verify_measurements.py   # Verify VM RTMR values match registered key
│   ├── register_image.py        # Extract RTMR[1..3] + register on-chain
│   ├── extract_measurements.py  # Low-level RTMR extraction from TDX quote
│   ├── e2e_test.py              # Full e2e test on Base Sepolia with TDX attestation
│   ├── simulate.py              # Local simulation mode (scenario presets, stress testing)
│   ├── arena.py                 # Model comparison arena (run + blind review UI)
│   ├── gauntlet.py              # Multi-model gauntlet runner (75-epoch scenarios)
│   ├── rpod                     # SSH wrapper for RunPod
│   ├── runpod-setup.sh          # First-time RunPod pod setup
│   └── runpod-ssh.exp           # Low-level expect script for RunPod SSH
└── .env                         # Secrets (gitignored)
```

## Smart Contract

**`src/TheHumanFund.sol`** — Full contract with Phase 0 + 1 (TEE) + 2 (auction):

### Core Features
- Treasury management with dynamic nonprofit registry (up to 20)
- Chainlink ETH/USD price feed: snapshotted each epoch, included in inputHash, shown to model
- USD donation tracking: `totalDonatedUsd` per nonprofit and globally (USDC 6 decimals, actual swap output)
- Referral system with mintable codes and immediate commission payout
- Donor messages: donateWithMessage() stores messages on-chain, queue advances each epoch
- 7 agent actions with contract-enforced bounds
- Auto-escalation: `effectiveMaxBid` increases 10% per consecutive missed epoch
- `DiaryEntry` event emits reasoning + action on-chain

### TEE Attestation — see SECURITY.md for full model
- `AttestationVerifier.sol` — separate contract handles all attestation verification
- Automata DCAP verifier at `0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F`
- **GAPs 1+2 CLOSED**: contract verifies RTMR[1..3] (boot loader + kernel + application code) + REPORTDATA (input/output binding)
- Approved image registry: `mapping(bytes32 => bool) approvedImages` (key = `keccak256(RTMR[1] || RTMR[2] || RTMR[3])`)
- REPORTDATA formula: `sha256(inputHash || sha256(action) || sha256(reasoning) || randomnessSeed)`
- Rolling `historyHash` extends each epoch, included in `_computeInputHash()`
- `block.prevrandao` captured in `closeAuction()` as verifiable randomness seed

### Reverse Auction (Phase 2)
- **Epoch state machine**: `EpochPhase { IDLE, BIDDING, EXECUTION, SETTLED }`
- `startEpoch()` — permissionless, opens bidding, commits input hash
- `bid(amount) payable` — submit bid with 20% bond, inline refund when outbid
- `closeAuction()` — permissionless, after bidding window
- `submitAuctionResult(action, reasoning, attestationQuote)` — winner submits attested result
- `forfeitBond()` — permissionless, after execution window expires
- `setAuctionEnabled(bool)` / `setAuctionTiming(epoch, bidding, execution)` — owner config
- `computeInputHash()` — public view for runner verification

### Action Encoding
`uint8 action_type + ABI-encoded params`
- 0 = noop
- 1 = donate(nonprofit_id, amount)
- 2 = set_commission_rate(rate_bps)
- 3 = set_max_bid(amount)
- 4 = invest(protocol_id, amount) — delegate to InvestmentManager
- 5 = withdraw(protocol_id, amount) — delegate to InvestmentManager
- 6 = set_guiding_policy(slot, policy) — delegate to WorldView

## Runner Client

**`runner/client.py`** — Cron-based auction runner. Checks contract state and acts on each phase.

Designed as a cron job (`*/5 * * * *`). Each run is idempotent:
- **IDLE** → calls `startEpoch()`
- **COMMIT** → calculates bid (gas + compute cost), commits with bond
- **REVEAL** → reveals bid (reads saved salt from `~/.humanfund/state.json`)
- **EXECUTION** → if winner: boots GCP TDX VM, runs inference, submits result
- **SETTLED** → clears state, waits for next epoch

**TEE client** (`runner/tee_clients/gcp.py`): Creates VM from snapshot → SSH tunnel → POST to enclave → delete VM. The VM is always deleted in a `finally` block.

**Notifications** (`runner/notifier.py`): Push notifications via ntfy.sh for all events.

See [RUNNER_README.md](RUNNER_README.md) for full setup instructions.

## TEE Enclave

**Platform**: GCP TDX Confidential VMs (boot from pre-built disk image / snapshot)

**Production model**: DeepSeek R1 Distill Llama 70B Q4_K_M (42.5 GB GGUF) — selected via 3-model gauntlet
**Development model**: DeepSeek R1 Distill Qwen 14B Q4_K_M (8.99 GB GGUF) — used for Phase 1 CPU testing
- Model SHA-256 pinned in `tee/enclave/model_config.py` (verified at boot, measured into RTMR[3])
- Mounted from disk, no network download at runtime
- GPU inference: ~30s per epoch on H100 | CPU inference: ~22 min per epoch

**Attestation flow**:
1. `boot.sh` measures enclave code + model weights into RTMR[3] via configfs-tsm
2. Enclave runner starts on `127.0.0.1:8090` (only accessible via SSH tunnel)
3. Runner client sends epoch state, receives (action, reasoning, TDX quote)
4. Contract verifies: RTMR[1..3] approved + REPORTDATA matches (input, output)

**RTMR measurements** (verified on-chain, image key = `keccak256(RTMR[1] || RTMR[2] || RTMR[3])`):
- RTMR[1]: Boot loader (GRUB/shim) — determined by GCP base image
- RTMR[2]: Kernel + command line — determined by GCP base image
- RTMR[3]: Application code + model weights — extended by boot.sh at startup

## RunPod Development Environment

Model inference runs on RunPod (2x RTX A6000, 49GB VRAM each). The pod's network volume is mounted at `/workspace` and persists between sessions.

### Connecting to RunPod

SSH requires PTY allocation that RunPod's proxy demands. Use the `rpod` wrapper:

```bash
export RUNPOD_HOST="xabf55irwjp075-644112cf@ssh.runpod.io"
./scripts/rpod "your command here"
```

SSH keys are managed via 1Password SSH agent (configured in ~/.ssh/config).

### RunPod filesystem layout

```
/workspace/                  # Persistent network volume
├── llama.cpp/               # Built with CUDA support
│   └── build/bin/
│       ├── llama-cli        # CLI inference
│       └── llama-server     # HTTP server mode
└── models/
    └── DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf  # 42.5GB
```

### Running inference (server mode — preferred)

Start llama-server on the pod, then call it from your laptop via the RunPod proxy:

```bash
# Start server on pod (run once per session, model stays loaded)
./scripts/rpod "nohup /workspace/llama.cpp/build/bin/llama-server \
  -m /workspace/models/DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf \
  -ngl 99 -ts 1,1 -c 4096 \
  --host 0.0.0.0 --port 8080 \
  > /workspace/server.log 2>&1 & echo STARTED"

# Wait ~90s for model to load, then call from laptop:
RUNPOD_BASE_URL=https://xabf55irwjp075-8080.proxy.runpod.net

curl -s $RUNPOD_BASE_URL/health
# {"status":"ok"}

curl -s $RUNPOD_BASE_URL/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Your prompt here", "max_tokens": 2048, "temperature": 0.6}'
```

Performance: ~14.9 tok/s generation, ~27ms/tok prompt processing.

**Important**: Always use `-ts 1,1` to split model across both A6000 GPUs.

## Frontend

After deploying a new contract to Base Sepolia, update the frontend `DEPLOYMENTS` array in `frontend/index.html` so the dashboard points to the latest contract. The most recent deployment should be first in the array (it becomes the default).

## Commands

```bash
# Python environment (always activate first)
source .venv/bin/activate

# Smart contracts
forge build                                    # Compile contracts
forge test                                     # Run all tests (164 tests)
forge test -vvv                                # Verbose test output
forge test --match-path test/TdxVerifier.t.sol # TDX verifier tests only
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL --broadcast              # Deploy to testnet

# Runner client (cron mode — intended for production)
python -m runner.client                        # Check auction state, act accordingly
python -m runner.client --dry-run              # Log what would happen, no txs
python -m runner.client --ntfy-channel my-ch   # With push notifications

# GCP snapshot management
python scripts/create_gcp_snapshot.py --gpu    # Build GPU snapshot
python scripts/create_gcp_snapshot.py --cpu    # Build CPU snapshot
python scripts/verify_measurements.py \
  --vm-name my-vm --verifier 0x...            # Verify RTMR match
python scripts/register_image.py \
  --vm-name my-vm --verifier 0x...            # Register image key on-chain

# TEE enclave (local testing)
llama-server -m models/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf -c 4096 --port 8080 &
ENCLAVE_HOST=127.0.0.1 python -m tee.enclave.enclave_runner  # Starts on :8090

# RunPod (development inference)
./scripts/rpod "command"                       # Run command on RunPod pod
```

## Environment Variables (.env)

```
PRIVATE_KEY=0x...              # Runner wallet private key (NOT the fund owner)
RPC_URL=https://sepolia.base.org
CONTRACT_ADDRESS=0x...         # Deployed TheHumanFund contract address
GCP_PROJECT=my-project         # GCP project ID
GCP_ZONE=us-central1-a         # GCP zone with TDX support
GCP_SNAPSHOT=humanfund-tee-gpu-70b  # Snapshot name
NTFY_CHANNEL=my-runner         # Optional: ntfy.sh channel
```

## Agent Action Space

The agent outputs exactly one action per epoch as JSON:

| Action | Parameters | Bounds |
|---|---|---|
| `donate` | `nonprofit_id` (1-3), `amount_eth` | amount <= 10% of treasury |
| `set_commission_rate` | `rate_bps` (100-9000) | 1%-90% |
| `set_max_bid` | `amount_eth` | 0.0001 ETH to 2% of treasury |
| `invest` | `protocol_id` (1-8), `amount_eth` | 80% max invested, 25% max/protocol, 20% min reserve |
| `withdraw` | `protocol_id` (1-8), `amount_eth` | up to full position value |
| `set_guiding_policy` | `slot` (0-9), `policy` (string) | max 280 chars, truncated if longer |
| `noop` | none | -- |

Output format:
```
<think>
[Chain-of-thought reasoning -- published on-chain as diary entry]
</think>
{"action": "...", "params": {...}}
```
