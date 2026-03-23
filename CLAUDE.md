# The Human Fund

An autonomous AI agent on the Base blockchain that manages a charitable treasury, making daily decisions about donations, growth, and self-preservation. Its reasoning is published on-chain as a public diary.

## Project Overview

- **Smart contract** (Solidity, Base L2): Treasury, referral system, epoch actions, reverse auction, TEE attestation, diary events
- **Agent inference**: DeepSeek R1 Distill Llama 70B (Q4_K_M, 42.5GB GGUF) via llama.cpp on GCP TDX H100 (production model)
- **Model selection**: DeepSeek R1 70B chosen via 3-model gauntlet (75 epochs each): 100% parse success, best reasoning depth, diversified investment strategy. Llama 3.3 70B also 100% reliable but less strategic. QwQ 32B eliminated (23% parse failure rate).
- **Runner software**: Python script that reads contract state, runs inference (direct or via TEE), parses output, submits on-chain
- **TEE enclave**: Docker image with llama.cpp + model + Flask API, runs in TDX Confidential VM on Phala Cloud
- **Frontend**: Diary viewer, treasury dashboard, donation/referral interface (Phase 4)

## Current Status

**Full e2e attestation verified on Base Sepolia with GCP TDX H100 GPU.** 5 straight successful epochs with DeepSeek R1 70B on H100. DCAP + image registry + REPORTDATA all pass on-chain.

- **Phase 3 contract (latest, 70B GPU e2e)**: `0xa507366987417e0E4247a827B48536DA11235CC7` (Base Sepolia) — 5 consecutive successful epochs with investments, withdrawals, and guiding policies
- **Phase 2 contract (CPU e2e)**: `0x9043B54B7E5d2f98Bc12ff10799cf8d5d38c7ab2` (Base Sepolia) — CPU + GPU verified
- Phase 0 original contract: `0x2F213Ea0D3F6D8349e2162b37Cc8cE6605dc9420` (Base Sepolia) — 21 epochs executed (legacy)
- **126 tests pass** (28 Phase 0 + 34 auction + 12 attestation verifier + 25 investment + 13 worldview + 14 messages)
- Contract sizes: TheHumanFund ~18.0KB (6.5KB margin, optimizer enabled), AttestationVerifier ~3.4KB, InvestmentManager ~10.4KB, WorldView ~2.6KB
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
   - MRTD + RTMR[0..2]: approved image was running
   - REPORTDATA: `SHA256(inputHash || SHA256(action) || SHA256(reasoning))` matches
6. Contract executes action, pays bounty + refunds bond
7. If winner doesn't deliver: anyone calls `forfeitBond()`, bond kept by treasury

## Key Design Decisions

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
- **Platform-agnostic attestation**: Verify MRTD + RTMR[0..2] (skip RTMR[3] — platform/instance-specific)
- **Rolling history hash**: On-chain `historyHash` extended each epoch, binds decision history to input commitment
- **Full design doc**: See DESIGN.md for complete specification
- **Security model**: See SECURITY.md for TEE attestation analysis and threat model

## Implementation Phases

- **Phase 0** (COMPLETE): End-to-end loop on testnet with trusted operator, no TEE
- **Phase 1** (COMPLETE): TEE integration — enclave on Phala Cloud, real TDX attestation, on-chain DCAP verification code
- **Phase 2** (COMPLETE): Reverse auction — contract + runner deployed, full attestation verified on Base Sepolia (CPU + GPU TDX)
- **Phase 3** (IN PROGRESS): Investment portfolio — InvestmentManager + 5 adapters (Aave, wstETH, cbETH, Compound, Aerodrome), 99 tests pass, Chainlink ETH/USD oracle, system prompt v2
- **Phase 4**: Frontend (diary viewer, treasury dashboard, investment portfolio UI)
- **Phase 5**: Audit and mainnet deployment

## Tech Stack

- **Chain**: Base (Coinbase L2), Solidity ^0.8.20
- **Inference**: llama.cpp + DeepSeek R1 Distill Llama 70B Q4_K_M (GCP TDX H100, production)
- **TEE**: Intel TDX via Phala Cloud / dstack (v0.5.x)
- **Attestation**: Automata Network DCAP contracts at `0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F`
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
│   │   ├── IAutomataDcapAttestation.sol  # Automata DCAP interface
│   │   ├── IAttestationVerifier.sol     # Attestation verifier interface
│   │   ├── IInvestmentManager.sol       # Investment manager interface
│   │   ├── IProtocolAdapter.sol         # Protocol adapter interface
│   │   └── IWorldView.sol               # WorldView interface
│   └── adapters/                # DeFi protocol adapters
│       ├── AaveV3WETHAdapter.sol    # Aave V3 ETH lending
│       ├── AaveV3USDCAdapter.sol    # Aave V3 USDC lending (with ETH swap)
│       ├── WstETHAdapter.sol        # Lido wstETH liquid staking
│       ├── CbETHAdapter.sol         # Coinbase cbETH staking
│       ├── CompoundV3USDCAdapter.sol # Compound V3 USDC lending
│       ├── SwapHelper.sol           # Shared ETH<->USDC swap logic
│       └── IWETH.sol                # WETH9 interface
├── test/
│   ├── TheHumanFund.t.sol       # Phase 0 tests (28 tests)
│   ├── TheHumanFundAuction.t.sol # Phase 2 auction + attestation tests (34 tests)
│   ├── AttestationVerifier.t.sol # Verifier unit tests (12 tests)
│   ├── InvestmentManager.t.sol  # Investment tests (25 tests)
│   ├── WorldView.t.sol          # Worldview tests (13 tests)
│   └── Messages.t.sol           # Donor messages tests (14 tests)
├── script/
│   └── Deploy.s.sol             # Foundry deployment script
├── agent/
│   ├── runner.py                # Runner: state → prompt → inference → submit (Phase 0 + 1)
│   ├── run_eval.py              # Prompt evaluation framework
│   ├── prompts/
│   │   ├── system_v1.txt        # System prompt v1 (Phase 0-2, no investments)
│   │   ├── system_v2.txt        # System prompt v2 (Phase 3, with investments)
│   │   └── system_v3.txt        # System prompt v3 (Phase 3+, with worldview)
│   └── scenarios/
│       └── scenarios.json       # 5 synthetic test scenarios
├── tee/                         # Phase 1: TEE enclave image
│   ├── Dockerfile               # Multi-stage: llama.cpp + enclave runner (model downloaded at runtime)
│   ├── docker-compose.yaml      # Phala Cloud / dstack deployment config
│   ├── enclave_runner.py        # Flask API: /health, /run_epoch (inference + attestation)
│   ├── start.sh                 # Container entrypoint (model download + SHA-256 verify)
│   └── system_prompt.txt        # Copy of agent/prompts/system_v1.txt
├── frontend/
│   └── index.html               # Internal dashboard (reads contract state)
├── models/                      # Local model files (gitignored)
├── scripts/
│   ├── simulate.py              # Local simulation mode (scenario presets, stress testing)
│   ├── arena.py                 # Model comparison arena (run + blind review UI)
│   ├── gauntlet.py              # Multi-model gauntlet runner (75-epoch scenarios)
│   ├── e2e_test.py              # Full e2e test on Base Sepolia with TDX attestation
│   ├── rpod                     # SSH wrapper for RunPod
│   ├── runpod-setup.sh          # First-time RunPod pod setup
│   └── runpod-ssh.exp           # Low-level expect script for RunPod SSH
└── .env                         # Secrets (gitignored)
```

## Smart Contract

**`src/TheHumanFund.sol`** — Full contract with Phase 0 + 1 (TEE) + 2 (auction):

### Core Features
- Treasury management with 3 hardcoded nonprofits
- Referral system with mintable codes and immediate commission payout
- Donor messages: donateWithMessage() stores messages on-chain, queue advances each epoch
- 4 agent actions with contract-enforced bounds
- Auto-escalation: `effectiveMaxBid` increases 10% per consecutive missed epoch
- `DiaryEntry` event emits reasoning + action on-chain

### TEE Attestation — see SECURITY.md for full model
- `AttestationVerifier.sol` — separate contract handles all attestation verification
- Automata DCAP verifier at `0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F`
- **GAPs 1+2 CLOSED**: contract now verifies MRTD + RTMR[0..2] (image identity) + REPORTDATA (input/output binding)
- Approved image registry: `mapping(bytes32 => bool) approvedImages` (key = `keccak256(MRTD || RTMR[0..2])`)
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

## Runner Script

**`agent/runner.py`** — Reads contract state, builds prompt, runs inference, submits action.

Supports two modes:
- **Direct mode** (Phase 0): `python agent/runner.py` — calls llama-server directly
- **TEE mode** (Phase 1): `python agent/runner.py --tee-url http://host:8090` — sends epoch context to TEE enclave

Key implementation details:
- **Two-pass inference**: Pass 1 generates reasoning with `stop=["</think>"]`, Pass 2 generates JSON action with `temperature=0.3`
- **JSON parsing**: Custom `_extract_json_object()` with brace depth tracking (regex fails on nested JSON)
- **Gas limit**: 5,000,000 (reasoning calldata can be 3KB+, ~16 gas per non-zero byte)
- **Reasoning cap**: 8KB on-chain to stay within gas budget
- **Pre-submission bounds check**: Clamps donate to 9.9%, commission 100-9000 bps, max_bid to valid range
- **Retry logic**: Up to 3 attempts on parse failure
- **Custom User-Agent**: `TheHumanFund/1.0` to bypass Cloudflare blocking on RunPod proxy

**Auction mode** (Phase 2): `python agent/runner.py --auction --tee-url http://host:8090 --bid 0.0001`
- Monitors auction state, calls `startEpoch()`, bids, `closeAuction()`
- On win: reads state, runs TEE inference, submits via `submitAuctionResult()`

**Known issue**: The Phala gateway has HTTP timeouts (~60s), so long CPU inference (~22 min) fails through the gateway. Use an SSH tunnel or run inference directly on the CVM:
```bash
# SSH tunnel (bypasses gateway timeout)
phala ssh humanfund-tee -- -L 18090:localhost:8091 -N &
python agent/runner.py --auction --tee-url http://localhost:18090 --bid 0.0001

# Or launch inference directly on CVM (survives wifi drops)
phala cp payload.json humanfund-tee:/tmp/payload.json
phala ssh humanfund-tee -- 'docker exec -d dstack-agent-1 python3 /tmp/run_inference.py'
```

## TEE Enclave

**Image**: `ghcr.io/ahrussell/humanfund-tee:v3` (amd64, Ubuntu 22.04)

**Production model**: DeepSeek R1 Distill Llama 70B Q4_K_M (42.5 GB GGUF) — selected via 3-model gauntlet
**Development model**: DeepSeek R1 Distill Qwen 14B Q4_K_M (8.99 GB GGUF) — used for Phase 1 CPU testing
- SHA-256: `0b319bd0572f2730bfe11cc751defe82045fad5085b4e60591ac2cd2d9633181`
- Mounted from disk by runner, SHA-256 verified at boot (no network download)
- CPU-only inference: ~0.33 tok/s on 16 vCPU, ~22 min/epoch
- Production will use 70B model (or larger) — just change `MODEL_SHA256` in Dockerfile and register new RTMR measurements

**Phala Cloud CVM**: `humanfund-tee` (tdx.2xlarge, 16 vCPU, 32 GB RAM)
- App ID: `5dcad829680b2ea7a0ac01021da00fa913eea815`
- Endpoint: `https://5dcad829680b2ea7a0ac01021da00fa913eea815-8091.dstack-pha-prod5.phala.network`
- dstack socket: `/var/run/dstack.sock` (v0.5.x API)

**dstack attestation API**: `POST /GetQuote` on Unix socket
- Request: `{"report_data": "<hex>"}`
- Response: `{"quote": "<hex>", "event_log": "<json>"}`
- dstack v0.5.x passes report_data **verbatim** to TDX driver (zero-padded to 64 bytes, no hashing)
- The old v0.3.x `tappd` API applied SHA-256 — that behavior is deprecated

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
forge test                                     # Run all tests (55 tests)
forge test -vvv                                # Verbose test output
forge test --match-path test/TheHumanFundAuction.t.sol  # Auction tests only
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL --broadcast              # Deploy to testnet

# Runner (direct mode — Phase 0)
python agent/runner.py                         # Run one epoch (reads .env)
python agent/runner.py --epochs 5              # Run 5 epochs in sequence
python agent/runner.py --dry-run               # Inference only, no submission

# Runner (TEE mode -- Phase 1)
python agent/runner.py --tee-url http://host:8090

# Runner (auction mode -- Phase 2)
python agent/runner.py --auction --tee-url http://host:8090 --bid 0.0001
python agent/runner.py --auction --tee-url http://localhost:18090 --bid 0.0001  # via SSH tunnel

# TEE enclave (local testing with 1.5B model)
llama-server -m models/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf -c 4096 --port 8080 &
cd tee && python enclave_runner.py             # Starts on :8090

# TEE enclave (Phala Cloud)
# Requires: nvm use 20 && phala login
phala deploy -c tee/docker-compose.yaml -n humanfund-tee --instance-type tdx.2xlarge
phala ps --cvm-id humanfund-tee                # Check container status
phala logs dstack-agent-1 --cvm-id humanfund-tee --stderr  # Container logs

# RunPod
./scripts/rpod "command"                       # Run command on RunPod pod
bash scripts/runpod-setup.sh                   # First-time setup (run ON the pod)
```

## Environment Variables (.env)

```
PRIVATE_KEY=0x...              # Deployer/runner wallet private key
DEPLOYER_ADDRESS=0x...         # Wallet address
RPC_URL=https://sepolia.base.org
CONTRACT_ADDRESS=0x...         # Deployed contract address
LLAMA_SERVER_URL=https://...   # RunPod proxy URL for llama-server
TEE_URL=https://...            # Phala Cloud enclave URL (Phase 1)
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
