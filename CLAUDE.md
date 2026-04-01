# The Human Fund

An autonomous AI agent on the Base blockchain that manages a charitable treasury, making daily decisions about donations, growth, and self-preservation. Its reasoning is published on-chain as a public diary.

## Project Overview

- **Smart contract** (Solidity, Base L2): Treasury, referral system, epoch actions, reverse auction, TEE attestation, diary events
- **Agent inference**: DeepSeek R1 Distill Llama 70B (Q4_K_M, 42.5GB GGUF) via llama.cpp on GCP TDX H100
- **Prover client** (`prover/client/`): Cron-based auction prover — monitors phases, bids, orchestrates GCP TEE VMs
- **TEE enclave** (`prover/enclave/`): One-shot Python program + llama-server running directly on full dm-verity rootfs (no Docker, no SSH). Input via GCP metadata, output via serial console
- **Frontend** (`frontend/`): Diary viewer, treasury dashboard, donation/referral interface

## Current Status

- **Contract**: `0x69716cd7836f4d5c573b309c32a7a8e93484e719` (Base Sepolia)
- **AuctionManager**: `0x6fd985c7ee2ef558a1fa3f388fd1c110f8e4d4d9`
- **TdxVerifier**: `0x1749e5132b3b12c63cbc5c419aab1623ba4cd7c7`
- **Deployer**: `0xffea30B0DbDAd460B9b6293fb51a059129fCCdAf`
- **182 tests pass** (core + auction + TDX verifier + investment + worldview + messages + cross-stack hash)
- GPU image key (a3-highgpu-1g, H100): `0x548fcaab...` — approved (v9)
- GCP TDX FMSPC `00806f050000` registered in Automata DCAP Dashboard
- H100 on-demand quota is 0; all GPU VMs use `--provisioning-model=SPOT`
- **Remaining**: extended testnet run, mainnet deployment

**Deep dives**: [DESIGN.md](DESIGN.md) (full specification), [SECURITY_MODEL.md](SECURITY_MODEL.md) (trust boundaries, accepted risks), [DMVERITY.md](DMVERITY.md) (boot flow, disk layout, build process)

## Architecture

Each epoch (24 hours in production, configurable for testnet):

1. Anyone calls `startEpoch()` — auto-cleans any stale previous auction, opens commit phase, commits input hash
2. Provers commit sealed bid hashes with bond during commit window (1 hour production)
3. Anyone calls `closeCommit()` — if no commits, epoch is missed
4. Provers reveal bids during reveal window (30 min production)
5. Anyone calls `closeReveal()` — lowest revealed bid wins, bond locked, randomness seed captured
6. Winner boots TDX VM from dm-verity disk image, one-shot enclave runs inference with deterministic seed
7. Winner submits via `submitAuctionResult()` — TdxVerifier verifies:
   - Automata DCAP: quote is genuine TDX hardware
   - Platform key: `sha256(MRTD || RTMR[1] || RTMR[2])` — firmware + kernel + dm-verity rootfs
   - REPORTDATA: `sha256(inputHash || outputHash)` matches
8. Contract executes action, pays bounty + refunds bond
9. If winner doesn't deliver: anyone calls `forfeitBond()`, bond kept by treasury

See [DESIGN.md](DESIGN.md) for the full integrity chain, auction economics, and indestructibility model.

## Key Development Rules

### Input Hash Integrity

Every value shown to the model in the epoch context MUST be included in the `inputHash` — either directly in `_hashState()` or transitively via a sub-hash. If a new field is added to the contract state that influences the model's prompt, it must be added to all of:

1. `_hashState()` in `src/TheHumanFund.sol`
2. `compute_input_hash()` in `prover/enclave/input_hash.py`
3. `derive_contract_state()` in `prover/enclave/input_hash.py`
4. `read_contract_state()` and `build_contract_state_for_tee()` in `prover/client/epoch_state.py`
5. `_buildStateJson()` in `test/CrossStackHash.t.sol`

Without this, a malicious runner could feed the TEE arbitrary values for that field and on-chain verification would not catch it.

### Gas Estimates

When contract functions change (new logic, different codegen from `via_ir`, etc.), the hardcoded gas limits in `prover/client/auction.py` may become too low, causing silent out-of-gas reverts. After any contract change, verify gas usage against the limits:

- `GAS_START_EPOCH`, `GAS_COMMIT`, `GAS_CLOSE_COMMIT`, `GAS_REVEAL`, `GAS_CLOSE_REVEAL`, `GAS_SUBMIT_RESULT`

Check actual gas used via `cast send` or test transactions and update the constants with comfortable headroom.

## Tech Stack

- **Chain**: Base (Coinbase L2), Solidity ^0.8.20
- **Inference**: llama.cpp + DeepSeek R1 Distill Llama 70B Q4_K_M (GCP TDX H100)
- **TEE**: Intel TDX on GCP Confidential VMs, full dm-verity rootfs (no Docker), configfs-tsm attestation
- **Attestation**: Automata Network DCAP contracts at `0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F`
- **Oracle**: Chainlink ETH/USD price feed (`IAggregatorV3.sol`, used by main contract + USDC adapters)
- **Tooling**: Foundry (Solidity), Python 3.9+ with venv (prover + enclave)

## Project Structure

```
thehumanfund/
├── CLAUDE.md                    # This file
├── DESIGN.md                    # Full design specification
├── SECURITY_MODEL.md            # Trust boundaries, accepted risks, verification checklist
├── SECURITY_AUDIT.md            # Point-in-time adversarial security audit
├── DMVERITY.md                  # dm-verity TEE architecture (boot flow, disk layout, build)
├── foundry.toml                 # Foundry configuration
├── .venv/                       # Python virtual environment (gitignored)
├── src/
│   ├── TheHumanFund.sol         # Main smart contract
│   ├── TdxVerifier.sol          # TDX attestation verifier
│   ├── InvestmentManager.sol    # DeFi portfolio manager
│   ├── WorldView.sol            # Agent worldview — 8 persistent slots
│   ├── interfaces/
│   │   ├── IAggregatorV3.sol            # Chainlink V3 price feed interface
│   │   ├── IAuctionManager.sol          # Auction manager interface
│   │   ├── IAutomataDcapAttestation.sol # Automata DCAP interface
│   │   ├── IEndaoment.sol               # Endaoment donation interface
│   │   ├── IInvestmentManager.sol       # Investment manager interface
│   │   ├── IProofVerifier.sol           # Proof verifier interface
│   │   ├── IERC4626.sol                 # Minimal ERC-4626 vault interface
│   │   ├── IProtocolAdapter.sol         # Protocol adapter interface
│   │   └── IWorldView.sol               # WorldView interface
│   └── adapters/                # DeFi protocol adapters
│       ├── AaveV3WETHAdapter.sol    # Aave V3 ETH lending
│       ├── AaveV3USDCAdapter.sol    # Aave V3 USDC lending (with ETH swap)
│       ├── WstETHAdapter.sol        # Lido wstETH liquid staking
│       ├── CbETHAdapter.sol         # Coinbase cbETH staking
│       ├── CompoundV3USDCAdapter.sol # Compound V3 USDC lending
│       ├── MorphoWETHAdapter.sol    # Morpho ERC-4626 WETH vaults
│       ├── SwapHelper.sol           # Shared ETH<->USDC swap logic
│       └── IWETH.sol                # WETH9 interface
├── test/
│   ├── TheHumanFund.t.sol       # Core tests
│   ├── TheHumanFundAuction.t.sol # Auction + attestation tests
│   ├── TdxVerifier.t.sol        # TDX verifier tests
│   ├── CrossStackHash.t.sol     # Cross-language hash compatibility tests
│   ├── InvestmentManager.t.sol  # Investment tests
│   ├── WorldView.t.sol          # Worldview tests
│   └── Messages.t.sol           # Donor messages tests
├── script/
│   └── Deploy.s.sol             # Foundry deployment script
├── prover/
│   ├── client/                 # Prover client (cron job, untrusted)
│   │   ├── client.py           # Main entry point — checks phase, acts accordingly
│   │   ├── chain.py            # Contract interaction (read state, submit tx)
│   │   ├── epoch_state.py      # Read full epoch state from contract for TEE
│   │   ├── auction.py          # Auction state machine
│   │   ├── bid_strategy.py     # Bid calculation (gas + compute + margin)
│   │   ├── notifier.py         # ntfy.sh push notifications
│   │   ├── state.py            # Persistent state (~/.humanfund/state.json)
│   │   ├── config.py           # CLI args + env var configuration
│   │   └── tee_clients/
│   │       ├── base.py         # ABC: run_epoch() → result
│   │       └── gcp.py          # GCP TDX VM lifecycle (create → poll → delete)
│   ├── enclave/                # Python enclave code (baked into dm-verity rootfs)
│   │   ├── enclave_runner.py   # One-shot: read input → inference → attest → output
│   │   ├── inference.py        # Two-pass llama-server calls
│   │   ├── action_encoder.py   # Action JSON → contract bytes
│   │   ├── input_hash.py       # Independent input hash computation
│   │   ├── prompt_builder.py   # System prompt + epoch context → full prompt
│   │   ├── attestation.py      # TDX quote generation via configfs-tsm
│   │   └── model_config.py     # Pinned model SHA-256 + verification
│   ├── prompts/
│   │   └── system.txt          # System prompt (Costanza's personality + instructions)
│   └── scripts/
│       └── gcp/                     # GCP TDX infrastructure scripts
│           ├── build_base_image.sh      # Build GCP base image (NVIDIA + CUDA + llama-server + model)
│           ├── build_full_dmverity_image.sh  # Build production dm-verity image (uses base)
│           ├── vm_build_all.sh          # Runs on VM: squashfs → verity → initramfs → GRUB
│           ├── vm_install.sh            # Install dependencies on VM for base image build
│           ├── e2e_test.py              # Full e2e test on Base Sepolia
│           ├── register_image.py        # Register platform key on-chain
│           └── verify_measurements.py   # Verify RTMR values match registered key
├── index.html                   # Frontend dashboard (reads contract state)
├── models/                      # Local model files (gitignored)
├── scripts/
│   ├── deploy_mainnet.sh        # Mainnet deployment guide
│   ├── recover_submit.py        # Emergency recovery for stuck auction epochs
│   ├── simulate.py              # Local simulation mode (scenario presets)
│   ├── compute_hash.py          # Input hash computation (used by Foundry FFI tests)
│   └── base_addresses.json      # Base mainnet contract addresses
└── .env                         # Secrets (gitignored)
```

## Smart Contract

**`src/TheHumanFund.sol`** — Main contract:

### Core Features
- Treasury management with dynamic nonprofit registry (up to 20)
- Chainlink ETH/USD price feed: snapshotted each epoch, included in inputHash, shown to model
- USD donation tracking: `totalDonatedUsd` per nonprofit and globally (USDC 6 decimals, actual swap output)
- Referral system with mintable codes and immediate commission payout
- Donor messages: `donateWithMessage()` stores messages on-chain, queue advances each epoch
- 7 agent actions with contract-enforced bounds
- Auto-escalation: `effectiveMaxBid` increases 10% per consecutive missed epoch
- `DiaryEntry` event emits reasoning + action on-chain

### Reverse Auction (Commit-Reveal)
- **Auction state machine**: `AuctionPhase { IDLE, COMMIT, REVEAL, EXECUTION, SETTLED }`
- `startEpoch()` — permissionless, auto-cleans stale auctions (any phase), opens commit phase, commits input hash
- `commit(commitHash) payable` — submit sealed bid hash with bond
- `closeCommit()` — permissionless, after commit window
- `reveal(bidAmount, salt)` — reveal previously committed bid
- `closeReveal()` — permissionless, after reveal window; lowest bid wins, randomness seed captured
- `submitAuctionResult(action, reasoning, proof, verifierId, policySlot, policyText)` — winner submits attested result
- `forfeitBond()` — permissionless, after execution window expires
- `computeInputHash()` — public view for prover verification
- **Stale recovery**: `startEpoch()` chains through remaining phase transitions if previous auction is stuck; credits `consecutiveMissedEpochs` based on elapsed wall-clock time

### Action Encoding
`uint8 action_type + ABI-encoded params`
- 0 = noop
- 1 = donate(nonprofit_id, amount)
- 2 = set_commission_rate(rate_bps)
- 3 = invest(protocol_id, amount) — delegate to InvestmentManager
- 4 = withdraw(protocol_id, amount) — delegate to InvestmentManager
- 5 = set_guiding_policy(slot, policy) — delegate to WorldView

## Prover Client

**`prover/client/client.py`** — Cron-based auction prover (`*/10 * * * *`). Each run is idempotent:
- **IDLE** → calls `startEpoch()`
- **BIDDING** → calculates bid (gas + compute cost), submits with bond
- **EXECUTION** → if winner: boots GCP TDX VM, runs inference, submits result
- **SETTLED** → clears state, waits for next epoch

**TEE client** (`prover/client/tee_clients/gcp.py`): Creates VM from dm-verity image with epoch state in metadata → polls serial console for output → parses result → deletes VM. No SSH, no HTTP.

See [prover/README.md](prover/README.md) for full setup instructions.

## TEE Enclave

**Platform**: GCP TDX Confidential VMs with full dm-verity rootfs (no Docker)

- Model SHA-256 pinned in `prover/enclave/model_config.py` (verified at boot)
- Model on separate dm-verity partition at `/models/`, no network download at runtime
- GPU inference: ~15.3s per epoch on H100
- Enclave code at `/opt/humanfund/enclave/` on the dm-verity rootfs
- **Input**: Epoch state JSON via GCP instance metadata
- **Output**: Result JSON to serial console (`/dev/ttyS0`, between `===HUMANFUND_OUTPUT_START===` / `===HUMANFUND_OUTPUT_END===` delimiters)

See [DMVERITY.md](DMVERITY.md) for boot flow, disk layout, and build process.

## Frontend

After deploying a new contract to Base Sepolia, update the `DEPLOYMENTS` array in `index.html` so the dashboard points to the latest contract. The most recent deployment should be first in the array (it becomes the default).

## Commands

```bash
# Python environment (always activate first)
source .venv/bin/activate

# Smart contracts
forge build                                    # Compile contracts
forge test                                     # Run all tests (165 tests)
forge test -vvv                                # Verbose test output
forge test --match-path test/TdxVerifier.t.sol # Specific test file
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL --broadcast              # Deploy to testnet

# Prover client (cron mode)
python -m prover.client                        # Check auction state, act accordingly
python -m prover.client --dry-run              # Log what would happen, no txs
python -m prover.client --ntfy-channel my-ch   # With push notifications

# GCP disk image (dm-verity)
bash prover/scripts/gcp/build_base_image.sh               # Build base + model template (slow, ~15min)
bash prover/scripts/gcp/build_full_dmverity_image.sh \
  --base-image humanfund-base-gpu-llama-b5270 \
  --model-template humanfund-model-template-gpu-llama-b5270  # Fast: model pre-written on disk
python prover/scripts/gcp/register_image.py \
  --image humanfund-dmverity-hardened-v8 \
  --verifier 0x...                            # Register image key on-chain
python prover/scripts/gcp/verify_measurements.py \
  --image humanfund-dmverity-hardened-v8 \
  --verifier 0x...                            # Verify RTMR match

# TEE enclave (local testing)
llama-server -m models/<model>.gguf -c 4096 --port 8080 &
ENCLAVE_HOST=127.0.0.1 python -m prover.enclave.enclave_runner
```

## Environment Variables (.env)

```
PRIVATE_KEY=0x...              # Prover wallet private key (NOT the fund owner)
RPC_URL=https://sepolia.base.org
CONTRACT_ADDRESS=0x...         # Deployed TheHumanFund contract address
GCP_PROJECT=my-project         # GCP project ID
GCP_ZONE=us-central1-a         # GCP zone with TDX support
GCP_IMAGE=humanfund-dmverity-hardened-v8    # Production dm-verity disk image
NTFY_CHANNEL=my-prover         # Optional: ntfy.sh channel
```

## Agent Action Space

The agent outputs exactly one action per epoch as JSON, with an optional worldview update:

| Action | Parameters | Bounds |
|---|---|---|
| `donate` | `nonprofit_id`, `amount_eth` | amount <= 10% of treasury |
| `set_commission_rate` | `rate_bps` (100-9000) | 1%-90% |
| `invest` | `protocol_id` (1-8), `amount_eth` | 80% max invested, 25% max/protocol, 20% min reserve |
| `withdraw` | `protocol_id` (1-8), `amount_eth` | up to full position value |
| `noop` | none | -- |

Worldview updates (slots 0-7, max 280 chars) happen alongside the action — they don't consume it.

Output format:
```
<think>
[Private analytical reasoning — scratch pad for tradeoffs and planning]
</think>
<diary>
[Public diary entry — published on-chain, written in the literary style from worldview slot [0]]
</diary>
{"action": "...", "params": {...}}
```

With optional worldview update:
```
{"action": "...", "params": {...}, "worldview": {"slot": 3, "policy": "Hopeful. The drought is ending."}}
```
