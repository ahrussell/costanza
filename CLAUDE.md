# The Human Fund

An autonomous AI agent on the Base blockchain that manages a charitable treasury, making daily decisions about donations, growth, and self-preservation. Its reasoning is published on-chain as a public diary.

## Project Overview

- **Smart contract** (Solidity, Base L2): Treasury, referral system, epoch actions, reverse auction, TEE attestation, diary events
- **Agent inference**: DeepSeek R1 Distill Llama 70B (Q4_K_M, 42.5GB GGUF) via llama.cpp on GCP TDX H100 (production model)
- **Model selection**: DeepSeek R1 70B chosen via 3-model gauntlet (75 epochs each): 100% parse success, best reasoning depth, diversified investment strategy. Llama 3.3 70B also 100% reliable but less strategic. QwQ 32B eliminated (23% parse failure rate).
- **Prover client** (`prover/client/`): Cron-based auction prover — monitors phases, bids, orchestrates GCP TEE VMs
- **TEE enclave** (`prover/enclave/`): One-shot Python program + llama-server running directly on full dm-verity rootfs (no Docker, no SSH). Input via GCP metadata, output via serial console
- **Frontend**: Diary viewer, treasury dashboard, donation/referral interface (Phase 4)

## Current Status

**Full e2e attestation verified on Base Sepolia with GCP TDX H100 GPU.** 5 straight successful epochs with DeepSeek R1 70B on H100. DCAP + image registry + REPORTDATA all pass on-chain.

- **Phase 3 contract (latest)**: `0xC95FDD9a6a3Accc50cF325bDc5fE537Ee83a1827` (Base Sepolia)
- Phase 3 contract (previous): `0xa507366987417e0E4247a827B48536DA11235CC7` (Base Sepolia) — 5 consecutive successful epochs
- **Phase 2 contract (CPU e2e)**: `0x9043B54B7E5d2f98Bc12ff10799cf8d5d38c7ab2` (Base Sepolia) — CPU + GPU verified
- Phase 0 original contract: `0x2F213Ea0D3F6D8349e2162b37Cc8cE6605dc9420` (Base Sepolia) — 21 epochs executed (legacy)
- **165 tests pass** (37 Phase 0 + 42 auction + 17 TDX verifier + 35 investment + 16 worldview + 14 messages + 4 cross-stack hash)
- Contract sizes: TheHumanFund ~24.0KB (20B margin, optimizer enabled), TdxVerifier ~2.5KB, InvestmentManager ~8.1KB, WorldView ~2.5KB, AuctionManager ~7.3KB
- GCP TDX FMSPC `00806f050000` registered in Automata DCAP Dashboard
- CPU image key (c3-standard-4): `0x1ff10986...` — approved
- GPU image key (a3-highgpu-1g, H100): `0xff11715b...` — approved (v7)
- **Note**: H100 on-demand quota is 0; all GPU VMs use `--provisioning-model=SPOT`
- **E2E gas costs**: deployment ~5.1M, DCAP verification ~10-12M (15M limit recommended)
- **GPU inference**: ~15.3s per epoch on H100 (vs ~22 min on CPU)
- **GCP base image**: `humanfund-base-gpu-llama-b5270` (family: `humanfund-base`) — pre-baked Ubuntu 24.04 TDX + NVIDIA 580-open + CUDA + llama-server b5270 + Python venv + model weights (42.5GB). Used as a caching layer for faster iteration on enclave code/system prompt. Rebuild when llama.cpp/NVIDIA/Ubuntu versions change.
- **GCP production image**: `humanfund-dmverity-hardened-v5` — built on top of base image by adding enclave code + system prompt, then sealing with two-disk dm-verity build (`build_full_dmverity_image.sh`). Full dm-verity rootfs, no Docker, direct execution. Includes C-1 fix (display data verification in TEE).
- **Model gauntlet**: 3 models tested across 75-epoch scenario (honeymoon → boom → crisis → drought → recovery → endgame). DeepSeek R1 70B: 6.12 ETH donated, 3.05 ETH final assets, diversified across 3 protocols. Llama 3.3 70B: 7.20 ETH donated but only 2.00 ETH final assets (less sustainable). QwQ 32B: 0.80 ETH donated, 17 parse failures.
- **Remaining**: extended testnet run, mainnet deployment
- Deployer address: `0xffea30B0DbDAd460B9b6293fb51a059129fCCdAf`

**DESIGN.md is a living document** — see it for the full specification and implementation checklist.
**SECURITY_MODEL.md** — trust boundaries, accepted risks, and pre-mainnet verification checklist.
**DMVERITY.md** — dm-verity TEE architecture, boot flow, disk layout, and build process.

## Architecture

Each epoch (24 hours in production, configurable for testnet):

### Phase 0 (current testnet): Direct submission
1. Prover reads contract state (treasury, nonprofits, epoch history)
2. Prover constructs prompt from system prompt + epoch context + decision history
3. Prover calls llama.cpp server for inference (two-pass: reasoning then action)
4. Prover parses output, encodes action, submits to contract
5. Contract validates bounds, executes action, emits DiaryEntry event

### Phase 2 (auction mode): Permissionless provers
1. Anyone calls `startEpoch()` — opens bidding, commits input hash
2. Provers submit bids during bidding window (1 hour production)
3. Anyone calls `closeAuction()` — lowest bid wins, bond locked, `prevrandao` captured for RNG seed
4. Winner boots TDX VM from dm-verity disk image, one-shot enclave program runs inference directly from immutable rootfs with deterministic seed
5. Winner submits via `submitAuctionResult()` — TdxVerifier verifies:
   - Automata DCAP: quote is genuine TDX hardware
   - Platform key: `sha256(MRTD || RTMR[1] || RTMR[2])` — firmware + kernel + dm-verity rootfs (transitively covers all code)
   - REPORTDATA: `SHA256(inputHash || outputHash)` matches
6. Contract executes action, pays bounty + refunds bond
7. If winner doesn't deliver: anyone calls `forfeitBond()`, bond kept by treasury

## Key Design Decisions

- **USD-denominated mission**: Agent's goal is to maximize USD donated, not ETH. Chainlink ETH/USD price is snapshotted each epoch and included in the inputHash. Donations are tracked in both ETH and USDC (actual swap output). The model sees all values in both ETH and USD.
- **Single action per epoch**: donate, set_commission_rate, set_max_bid, invest, withdraw, set_guiding_policy, or noop
- **Donor messages**: donateWithMessage() accepts a string (max 280 chars, min 0.01 ETH). Messages queued, up to 20 per epoch shown to model with datamarking spotlighting (whitespace replaced with dynamic marker token) to mitigate prompt injection — based on [Hines et al. 2024](https://arxiv.org/abs/2403.14720)
- **Hard bounds enforced by contract**: max 10% treasury donated/epoch, commission 1-90%, max bid 0.0001 ETH to 2% treasury, investment bounds 80% max / 25% per protocol / 20% min reserve
- **No free-text input fields** — prompt injection mitigated by structured numeric/address data only
- **Two-pass inference**: Pass 1 generates reasoning (stop at `</think>`), Pass 2 generates JSON action (lower temperature)
- **Auto-escalation**: missed epochs automatically raise bid ceiling by 10% (compounding) until a prover accepts
- **Reverse auction**: First-price sealed-bid, 20% bond, inline refunds when outbid
- **Epoch state machine**: IDLE → BIDDING → EXECUTION → SETTLED with configurable timing
- **Verifiable randomness**: RNG seed derived from `block.prevrandao` at auction close — prover cannot re-roll inference
- **Model on dm-verity partition**: Model weights live on a separate dm-verity partition, hash baked into GRUB command line (measured into RTMR[2]). Enclave also verifies SHA-256 at startup (defense-in-depth). No runtime download.
- **Platform-only attestation**: TdxVerifier uses platform key = `sha256(MRTD || RTMR[1] || RTMR[2])`. dm-verity rootfs hash in RTMR[2] transitively covers all code, so no separate app key (RTMR[3]) is needed. RTMR[0] (VM hardware config) intentionally skipped so provers can use different VM sizes.
- **Rolling history hash**: On-chain `historyHash` extended each epoch, binds decision history to input commitment
- **No Docker enclave**: Enclave runs directly on dm-verity rootfs (no Docker, no container runtime). One-shot program: reads input from GCP metadata, writes output to serial console. No network listeners, no SSH in production.
- **Full design doc**: See DESIGN.md for complete specification
- **Security model**: See SECURITY_MODEL.md for trust boundaries, accepted risks, and verification checklist
- **Architecture doc**: See DMVERITY.md for detailed dm-verity boot flow, disk layout, and build process

## Implementation Phases

- **Phase 0** (COMPLETE): End-to-end loop on testnet with trusted operator, no TEE
- **Phase 1** (COMPLETE): TEE integration — TDX attestation, on-chain DCAP verification, RTMR[1..3] image registry
- **Phase 2** (COMPLETE): Reverse auction — contract + prover deployed, full attestation verified on Base Sepolia (CPU + GPU TDX)
- **Phase 3** (IN PROGRESS): Investment portfolio — InvestmentManager + 7 adapters (Aave WETH/USDC, wstETH, cbETH, Compound USDC, Morpho Gauntlet/Steakhouse WETH), 165 tests pass, Chainlink ETH/USD oracle, system prompt v6
- **Phase 4**: Frontend (diary viewer, treasury dashboard, investment portfolio UI)
- **Phase 5**: Audit and mainnet deployment

## Tech Stack

- **Chain**: Base (Coinbase L2), Solidity ^0.8.20
- **Inference**: llama.cpp + DeepSeek R1 Distill Llama 70B Q4_K_M (GCP TDX H100, production)
- **TEE**: Intel TDX on GCP Confidential VMs, full dm-verity rootfs (no Docker), configfs-tsm attestation
- **Attestation**: Automata Network DCAP contracts at `0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F`
- **Oracle**: Chainlink ETH/USD price feed (shared interface `IAggregatorV3.sol`, used by main contract + USDC adapters)
- **Tooling**: Foundry (Solidity), Python 3.9+ with venv (prover + enclave)

## Python Environment

```bash
# Set up venv (first time)
python3 -m venv .venv
source .venv/bin/activate
pip install flask web3 requests

# Activate venv (each session)
source .venv/bin/activate
```

All Python commands (prover, enclave runner, etc.) should be run inside the venv.

## Project Structure

```
thehumanfund/
├── CLAUDE.md                    # This file — project context for Claude
├── DESIGN.md                    # Full design specification (living document)
├── SECURITY_MODEL.md            # Trust boundaries, accepted risks, verification checklist
├── SECURITY_AUDIT.md            # Point-in-time adversarial security audit
├── DMVERITY.md                  # dm-verity TEE architecture (boot flow, disk layout, build)
├── foundry.toml                 # Foundry configuration
├── .venv/                       # Python virtual environment (gitignored)
├── src/
│   ├── TheHumanFund.sol         # Main smart contract (Phase 0-3, ~23.9KB)
│   ├── TdxVerifier.sol          # TDX attestation verifier (platform key: sha256(MRTD||RTMR1||RTMR2))
│   ├── InvestmentManager.sol    # DeFi portfolio manager (~7.7KB)
│   ├── WorldView.sol            # Agent worldview — 10 guiding policy slots
│   ├── interfaces/
│   │   ├── IAggregatorV3.sol            # Chainlink V3 price feed interface
│   │   ├── IAuctionManager.sol          # Auction manager interface
│   │   ├── IAutomataDcapAttestation.sol  # Automata DCAP interface
│   │   ├── IEndaoment.sol               # Endaoment donation interface
│   │   ├── IInvestmentManager.sol       # Investment manager interface
│   │   ├── IProofVerifier.sol           # Proof verifier interface (used by TdxVerifier)
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
│   ├── TheHumanFund.t.sol       # Phase 0 tests
│   ├── TheHumanFundAuction.t.sol # Phase 2 auction + attestation tests
│   ├── TdxVerifier.t.sol        # TDX verifier tests
│   ├── CrossStackHash.t.sol     # Cross-language hash compatibility tests
│   ├── InvestmentManager.t.sol  # Investment tests
│   ├── WorldView.t.sol          # Worldview tests
│   └── Messages.t.sol           # Donor messages tests
├── script/
│   └── Deploy.s.sol             # Foundry deployment script
├── prover/                      # Auction prover + TEE enclave (all prover code)
│   ├── client/                 # Prover client (cron job, untrusted)
│   │   ├── client.py           # Main entry point — checks phase, acts accordingly
│   │   ├── chain.py            # Contract interaction (read state, submit tx)
│   │   ├── epoch_state.py      # Read full epoch state from contract for TEE
│   │   ├── auction.py          # Auction state machine (commit/reveal/submit)
│   │   ├── bid_strategy.py     # Bid calculation (gas + compute + margin)
│   │   ├── notifier.py         # ntfy.sh push notifications
│   │   ├── state.py            # Persistent state (~/.humanfund/state.json)
│   │   ├── config.py           # CLI args + env var configuration
│   │   └── tee_clients/
│   │       ├── base.py         # ABC: run_epoch() → result
│   │       └── gcp.py          # GCP TDX VM lifecycle (create → tunnel → call → delete)
│   ├── enclave/                # Python enclave code (baked into dm-verity rootfs, no Docker)
│   │   ├── enclave_runner.py   # One-shot program: read input → inference → attest → output
│   │   ├── inference.py        # Two-pass llama-server calls
│   │   ├── action_encoder.py   # Action JSON → contract bytes
│   │   ├── input_hash.py       # Independent input hash computation
│   │   ├── prompt_builder.py   # System prompt + epoch context → full prompt
│   │   ├── attestation.py      # TDX quote generation via configfs-tsm
│   │   └── model_config.py     # Pinned model SHA-256 + verification
│   ├── prompts/
│   │   └── system.txt          # System prompt (USD mission, ETH/USD price)
│   └── scripts/                # Prover/TEE infrastructure scripts
│       ├── build_base_image.sh      # Build GCP base image (NVIDIA + CUDA + llama-server + model, slow ~15min)
│       ├── build_full_dmverity_image.sh  # Build production dm-verity image (fast ~10min, uses base)
│       ├── vm_build_all.sh          # Runs on VM: squashfs → verity → initramfs → partition → GRUB
│       ├── vm_install.sh            # Installs dependencies on VM for base image build
│       ├── e2e_test.py              # Full e2e test on Base Sepolia with TDX attestation
│       ├── register_image.py        # Register platform key on-chain (serial console, no SSH)
│       └── verify_measurements.py   # Verify RTMR values match registered key (serial console)
├── frontend/
│   └── index.html               # Internal dashboard (reads contract state)
├── models/                      # Local model files (gitignored)
├── scripts/
│   ├── deploy_mainnet.sh        # Mainnet deployment guide (step-by-step)
│   ├── recover_submit.py        # Emergency recovery for stuck auction epochs
│   ├── simulate.py              # Local simulation mode (scenario presets, stress testing)
│   ├── compute_hash.py          # Input hash computation (used by Foundry FFI tests)
│   └── base_addresses.json      # Base mainnet contract addresses
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

### TEE Attestation — see SECURITY_MODEL.md + DMVERITY.md for full model
- **TdxVerifier.sol** — TDX attestation verifier for dm-verity architecture
  - Platform key: `sha256(MRTD || RTMR[1] || RTMR[2])` — firmware + kernel + dm-verity rootfs (transitively covers all code)
  - No app key needed: dm-verity root hash in RTMR[2] covers everything (no Docker, no RTMR[3])
  - RTMR[0] intentionally skipped (VM hardware config varies by prover)
- Automata DCAP verifier at `0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F`
- REPORTDATA formula: `sha256(inputHash || outputHash)` where `outputHash = keccak256(sha256(action) || sha256(reasoning) || sha256(systemPrompt))`
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
- `computeInputHash()` — public view for prover verification

### Action Encoding
`uint8 action_type + ABI-encoded params`
- 0 = noop
- 1 = donate(nonprofit_id, amount)
- 2 = set_commission_rate(rate_bps)
- 3 = set_max_bid(amount)
- 4 = invest(protocol_id, amount) — delegate to InvestmentManager
- 5 = withdraw(protocol_id, amount) — delegate to InvestmentManager
- 6 = set_guiding_policy(slot, policy) — delegate to WorldView

## Prover Client

**`prover/client/client.py`** — Cron-based auction prover. Checks contract state and acts on each phase.

Designed as a cron job (`*/5 * * * *`). Each run is idempotent:
- **IDLE** → calls `startEpoch()`
- **COMMIT** → calculates bid (gas + compute cost), commits with bond
- **REVEAL** → reveals bid (reads saved salt from `~/.humanfund/state.json`)
- **EXECUTION** → if winner: boots GCP TDX VM, runs inference, submits result
- **SETTLED** → clears state, waits for next epoch

**TEE client** (`prover/client/tee_clients/gcp.py`): Creates VM from dm-verity image with epoch state in metadata → polls serial console for output → parses result → deletes VM. No SSH, no HTTP. The VM is always deleted in a `finally` block.

**Notifications** (`prover/client/notifier.py`): Push notifications via ntfy.sh for all events.

See [prover/README](prover/README) for full setup instructions.

## TEE Enclave

**Platform**: GCP TDX Confidential VMs with full dm-verity rootfs (no Docker)

**Production model**: DeepSeek R1 Distill Llama 70B Q4_K_M (42.5 GB GGUF) — selected via 3-model gauntlet
**Development model**: DeepSeek R1 Distill Qwen 14B Q4_K_M (8.99 GB GGUF) — used for Phase 1 CPU testing
- Model SHA-256 pinned in `prover/enclave/model_config.py` (verified at boot)
- Model on separate dm-verity partition at `/models/`, no network download at runtime
- GPU inference: ~15.3s per epoch on H100 | CPU inference: ~22 min per epoch

**Architecture (no Docker)**:
- Enclave code lives at `/opt/humanfund/enclave/` on the dm-verity rootfs
- System prompt at `/opt/humanfund/system_prompt.txt` on the dm-verity rootfs
- llama-server binary at `/opt/humanfund/bin/llama-server` on the dm-verity rootfs
- `humanfund-enclave.service` — systemd one-shot service that runs the enclave program
- `prover/scripts/build_base_image.sh` — builds GCP base image (NVIDIA + CUDA + llama-server + model, ~15min)
- `prover/scripts/build_full_dmverity_image.sh` — builds production dm-verity image from base (~10min)
- `prover/scripts/vm_build_all.sh` — runs on VM: creates squashfs, verity, initramfs, partitions output disk

**Enclave I/O (no SSH, no Flask, no network listeners)**:
- **Input**: Epoch state JSON via GCP instance metadata (`epoch-state` attribute) or file at `/input/epoch_state.json`
- **Output**: Result JSON to serial console (`/dev/ttyS0`, between `===HUMANFUND_OUTPUT_START===` and `===HUMANFUND_OUTPUT_END===` delimiters) and `/output/result.json`
- Prover reads output via `gcloud compute instances get-serial-port-output`

**Attestation flow**:
1. VM boots from dm-verity image: OVMF (MRTD) → GRUB (RTMR[1]) → kernel + cmdline with dm-verity hashes (RTMR[2])
2. Initramfs sets up dm-verity, mounts immutable rootfs and model partition
3. systemd starts one-shot enclave program (reads input, runs inference, generates TDX quote)
4. Enclave gets TDX quote via configfs-tsm with REPORTDATA = sha256(inputHash || outputHash)
5. Enclave writes result to serial console, prover reads it, submits to chain
6. TdxVerifier verifies: platform key (MRTD + RTMR[1..2]) + REPORTDATA

**RTMR measurements** (verified on-chain via TdxVerifier):
- MRTD: Measured at VM launch (firmware) — part of platform key
- RTMR[1]: Boot loader (GRUB/shim) — part of platform key
- RTMR[2]: Kernel + command line including dm-verity root hashes — part of platform key. Transitively covers all code via dm-verity.
- RTMR[3]: Not used (no Docker, all code on dm-verity rootfs covered by RTMR[2])

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
forge test                                     # Run all tests (165 tests)
forge test -vvv                                # Verbose test output
forge test --match-path test/TdxVerifier.t.sol # TDX verifier tests only
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL --broadcast              # Deploy to testnet

# Prover client (cron mode — intended for production)
python -m prover.client                        # Check auction state, act accordingly
python -m prover.client --dry-run              # Log what would happen, no txs
python -m prover.client --ntfy-channel my-ch   # With push notifications

# GCP disk image (dm-verity)
bash prover/scripts/build_base_image.sh               # Build base image (slow, ~15min, do once)
bash prover/scripts/build_full_dmverity_image.sh \
  --base-image humanfund-base-gpu-llama-b5270  # Build production image (fast, ~10min)
bash prover/scripts/build_full_dmverity_image.sh \
  --base-image humanfund-base-gpu-llama-b5270 \
  --name humanfund-dmverity-gpu-v6             # Named production image
python prover/scripts/verify_measurements.py \
  --image humanfund-dmverity-hardened-v6 \
  --verifier 0x...                            # Verify RTMR match (via serial console)
python prover/scripts/register_image.py \
  --image humanfund-dmverity-hardened-v6 \
  --verifier 0x...                            # Register image key on-chain (via serial console)

# TEE enclave (local testing)
llama-server -m models/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf -c 4096 --port 8080 &
ENCLAVE_HOST=127.0.0.1 python -m prover.enclave.enclave_runner  # Starts on :8090

```

## Environment Variables (.env)

```
PRIVATE_KEY=0x...              # Prover wallet private key (NOT the fund owner)
RPC_URL=https://sepolia.base.org
CONTRACT_ADDRESS=0x...         # Deployed TheHumanFund contract address
GCP_PROJECT=my-project         # GCP project ID
GCP_ZONE=us-central1-a         # GCP zone with TDX support
GCP_IMAGE=humanfund-dmverity-gpu-v6    # Production dm-verity disk image
NTFY_CHANNEL=my-prover         # Optional: ntfy.sh channel
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
