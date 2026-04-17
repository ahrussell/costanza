# The Human Fund

An autonomous AI agent on the Base blockchain that manages a charitable treasury, making daily decisions about donations, growth, and self-preservation. Its reasoning is published on-chain as a public diary.

## Project Overview

- **Smart contract** (Solidity, Base L2): Treasury, referral system, epoch actions, reverse auction, TEE attestation, diary events
- **Agent inference**: DeepSeek R1 Distill Llama 70B (Q4_K_M, 42.5GB GGUF) via llama.cpp on GCP TDX H100
- **Prover client** (`prover/client/`): Cron-based auction prover — monitors phases, bids, orchestrates GCP TEE VMs
- **TEE enclave** (`prover/enclave/`): One-shot Python program + llama-server running directly on full dm-verity rootfs (no Docker, no SSH). Input via GCP metadata, output via serial console
- **Frontend** (`frontend/`): Diary viewer, treasury dashboard, donation/referral interface

## Current Status

### Base Mainnet
- **Contract**: [`0xeE98b474000a2B350FfcBA8F02889d5047B8DFca`](https://basescan.org/address/0xeE98b474000a2B350FfcBA8F02889d5047B8DFca)
- **AuctionManager**: [`0x03a6955f296C927FF71c91cf1Fd9D4F4c71c034c`](https://basescan.org/address/0x03a6955f296C927FF71c91cf1Fd9D4F4c71c034c)
- **TdxVerifier**: [`0x1dfE62A7FCD128E302bd300D754b001Baf63A57D`](https://basescan.org/address/0x1dfE62A7FCD128E302bd300D754b001Baf63A57D)
- **InvestmentManager**: [`0xD5C58523723F9ba367202A0e29c80358807b02D3`](https://basescan.org/address/0xD5C58523723F9ba367202A0e29c80358807b02D3)
- **WorldView**: [`0x1370f47C7Ae6f6edF850bfF74c86BF591D7Ad3ae`](https://basescan.org/address/0x1370f47C7Ae6f6edF850bfF74c86BF591D7Ad3ae)
- **Owner**: `0x495fB7ddD383be8030EFC93324Ff078f173eAb2A` (EOA, will transfer to Safe `0x6dF6f527E193fAf1334c26A6d811fAd62E79E5Db`)
- **Epoch timing**: 90-min epochs (20m commit, 20m reveal, 50m execution)
- **302 tests pass** (core + auction + TDX verifier + investment + worldview + messages + cross-stack + system invariants)
- GPU image: `humanfund-dmverity-hardened-v11`, key: `0xf23661d5f5a506472feb7c5fff267eb0b0d80caf5a87c0c831292e1f4809d614`
- GCP TDX FMSPC `00806f050000` registered in Automata DCAP Dashboard
- H100 on-demand quota is 0; all GPU VMs use `--provisioning-model=SPOT`
- **Frontend RPC**: Cloudflare Worker at `humanfund-rpc-cache.thehumanfund.workers.dev` (proxies to Alchemy, 5-min cache)
- **Prover RPC**: Alchemy direct (free tier, 30M CU/month)

### Base Mainnet (previous)
- Contract: `0xE1Ff438B1C0Bf0C61d6EfF439C2A9eB1dDcb71e5` — withdrawAll'd on 2026-04-14 before redeploy (epoch 1 forfeited due to epochDuration drift; fixed in EpochSnapshot)
- Contract: `0x908cf9974fd2EcE9D3a50644EDcAF90c88E57C10` — first mainnet v2, withdrawAll'd on 2026-04-14
- Image: `humanfund-dmverity-hardened-v10` (deleted), key: `0x923d500553d9e10a8f864eade2029df0471c7cd4f90b888e7749f0dc3fca1eca`

**Deep dive**: [WHITEPAPER.md](WHITEPAPER.md) (full specification, formal security model, TEE construction)

## Architecture

Each epoch (24 hours in production, configurable for testnet) cycles through
three phases — **COMMIT → REVEAL → EXECUTION** — then rolls straight into
the next epoch's COMMIT. There is no IDLE or SETTLED rest state; the fund
always holds exactly one in-flight auction (the *meta-invariant*), except
during the atomic EXECUTION→COMMIT-of-next-epoch transition within a single
transaction and under FREEZE_SUNSET.

The per-epoch flow:

1. Prover calls `commit()` in the COMMIT window — contract auto-syncs via
   `_advanceToNow()`, then submits sealed bid hash with bond.
2. Prover calls `reveal()` in the REVEAL window — contract auto-syncs
   (closes commit if needed), records bid reveal.
3. Lowest revealed bid wins; ties broken by first revealer. Randomness seed
   captured from `block.prevrandao XOR saltAccumulator` at REVEAL→EXECUTION.
4. Winner boots TDX VM from dm-verity disk image, one-shot enclave runs
   inference with the epoch's seed-bound input hash.
5. Winner calls `submitAuctionResult()` during EXECUTION — contract auto-
   syncs, `TdxVerifier` verifies:
   - Automata DCAP: quote is genuine TDX hardware
   - Platform key: `sha256(MRTD || RTMR[1] || RTMR[2])` — firmware + kernel + rootfs
   - REPORTDATA: `sha256(inputHash || outputHash)` matches
   Winner receives their bond back plus the bounty immediately.
6. Epoch ends when someone calls `syncPhase()` (or the prover naturally
   interacts with the next epoch): `_closeExecution` forfeits the winner's
   bond to the fund if they no-showed, updates counters, and `_openAuction`
   opens the next epoch's COMMIT.
7. Non-winning revealers claim bonds via `claimBond(epoch)`. Non-revealers
   forfeit bonds to the fund at reveal close.

### Two drivers, one state machine

- **Wall-clock driver** (`syncPhase` / `_advanceToNow`): cascades COMMIT→REVEAL
  via `_nextPhase`, closes EXECUTION via `_closeExecution`, arithmetically
  fast-forwards through ghost epochs, opens the landed epoch if we're inside
  its commit window. Called automatically from every participant method
  (`commit`, `reveal`, `submitAuctionResult`, `syncPhase`).
- **Manual driver** (`nextPhase`, owner-only): advances exactly one state-
  machine step. Sync-first: both `nextPhase` and `resetAuction` call
  `_advanceToNow()` first so the manual driver can never time-travel
  backward past wall-clock.

Both drivers converge to the same state under the same scenario.

### Single-site state mutation

- `_openAuction(epoch, scheduledStart)` — the sole site that writes the
  timing anchor and opens an auction.
- `_closeExecution()` — the sole site where the two escalation counters
  update at epoch end (`consecutiveMissedEpochs`, `consecutiveStalledEpochs`).
- `_nextPhase()` — the sole site for intra-epoch phase transitions (and
  the sole binder of the seed-XORed input hash at REVEAL→EXECUTION).

See `test/SystemInvariants.t.sol`'s preamble for the complete behavioral
spec (8 groups: lifecycle, timing, auction mechanics, snapshot/messages,
input-hash chain, bonds, drivers, safety). See [WHITEPAPER.md](WHITEPAPER.md)
for the full integrity chain, auction economics, and indestructibility model.

## Key Development Rules

### Canonical behavioral spec

The authoritative behavioral spec lives in **`test/SystemInvariants.t.sol`'s
preamble**. Every new invariant or change in behavior should be reflected
there first, then enforced by a test, then made true in the contract. The
spec is organized into 8 concern-groups: epoch lifecycle, timing &
schedule, auction mechanics, snapshot & messages, input-hash &
attestation chain, bonds, drivers & permissions, safety & kill-switches.
Read it before making non-trivial contract changes.

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

- `GAS_SYNC_PHASE`, `GAS_COMMIT`, `GAS_REVEAL`, `GAS_SUBMIT_RESULT`

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
├── WHITEPAPER.md                # Full specification, security model, TEE construction
├── SECURITY_AUDIT.md            # Point-in-time adversarial security audit
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
│   ├── SystemInvariants.t.sol   # Behavioral spec in code — canonical invariant list
│   ├── TdxVerifier.t.sol        # TDX verifier tests
│   ├── CrossStackHash.t.sol     # Cross-language hash compatibility tests
│   ├── InvestmentManager.t.sol  # Investment tests
│   ├── WorldView.t.sol          # Worldview tests
│   ├── Messages.t.sol           # Donor messages tests + visibility-boundary invariants
│   └── helpers/
│       ├── EpochTest.sol        # Shared speedrunEpoch driver
│       ├── MockProofVerifier.sol
│       └── MockEndaoment.sol
├── deploy/
│   ├── mainnet/
│   │   ├── Deploy.s.sol         # Mainnet Foundry deployment script
│   │   ├── deploy_guide.sh      # Mainnet deployment guide
│   │   ├── preflight.sh         # Pre-deploy validation checklist
│   │   └── base_addresses.json  # Base mainnet contract addresses
│   ├── testnet/
│   │   ├── DeployTestnet.s.sol  # Base Sepolia deploy (mock contracts)
│   │   ├── cli.py               # Testnet CLI (status, run-epoch, etc.)
│   │   └── e2e.py               # End-to-end testnet test harness
│   └── DeployLocal.s.sol        # Local anvil testing script
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
│   ├── recover_submit.py        # Emergency recovery for stuck auction epochs
│   ├── simulate.py              # Local simulation mode (scenario presets)
│   └── compute_hash.py          # Input hash computation (used by Foundry FFI tests)
└── .env                         # Secrets (gitignored)
```

## Smart Contract

**`src/TheHumanFund.sol`** — Main contract:

### Core Features
- Treasury management with dynamic nonprofit registry (up to 20)
- Chainlink ETH/USD price feed: snapshotted each epoch, included in inputHash, shown to model
- USD donation tracking: `totalDonatedUsd` per nonprofit and globally (USDC 6 decimals, actual swap output)
- Referral system with mintable codes and immediate commission payout
- Donor messages: `donateWithMessage()` stores messages on-chain; each message first visible in the epoch AFTER it arrives (messages sent in epoch N appear in epoch N+1's snapshot at the earliest)
- 5 agent actions with contract-enforced bounds
- `DiaryEntry` event emits reasoning + action on-chain

### Reverse Auction (Commit-Reveal) — 3-Phase Cyclic
- **Auction state machine**: `AuctionPhase { COMMIT, REVEAL, EXECUTION }` — cyclic per epoch
- **Eager open**: `setAuctionManager` opens epoch 1's auction at deploy time. Every subsequent epoch opens automatically at the EXECUTION→COMMIT transition. The fund never sits in an IDLE rest state
- **Auto-sync**: every participant-facing method (`commit`, `reveal`, `submitAuctionResult`, `syncPhase`) calls `_advanceToNow()` first — cascades COMMIT→REVEAL→EXECUTION by wall-clock, crosses epoch boundaries via `_closeExecution`, arithmetically fast-forwards ghost epochs, opens the landed epoch if we're in its commit window
- **Sync-first rule**: `nextPhase` and `resetAuction` (owner-only, manual drivers) also call `_advanceToNow()` first, so the manual driver can never leave the contract behind wall-clock
- **Public entry points**:
  - `syncPhase()` — permissionless, catches the contract up to wall-clock
  - `commit(commitHash) payable` — auto-syncs, then submits sealed bid with bond ≥ `currentBond()`
  - `reveal(bidAmount, salt)` — auto-syncs, reveals bid ≤ `effectiveMaxBid()`
  - `submitAuctionResult(action, reasoning, proof, verifierId, policySlot, policyText)` — auto-syncs, TDX-verifies proof, pays bounty, executes action (best-effort: invalid actions/policies don't revert a verified proof — the winner still gets paid)
  - `nextPhase()` owner-only — syncs first, then advances exactly one state-machine step
  - `resetAuction(cw, rw, xw)` owner-only — syncs first, aborts in-flight auction (refunds all bonds non-confiscatorily), applies new timing, advances one epoch, re-opens
- **Escalation counters (both update at exactly one site, `_closeExecution`)**:
  - `consecutiveMissedEpochs` — resets on success, else +1 per epoch end; also += N on wall-clock fast-forward. Drives `effectiveMaxBid()` via `maxBid * (1 + AUTO_ESCALATION_BPS/10000)^missed`, capped at `treasury * MAX_BID_BPS/10000` (10%)
  - `consecutiveStalledEpochs` — resets on success, +1 on winner-forfeit, unchanged on silence. Drives `currentBond()` via `BASE_BOND * (1 + AUTO_ESCALATION_BPS/10000)^stalled`, capped at `_bondCap()`
- **Lazy bond claiming**: `AuctionManager.claimBond(epoch)` — non-winning revealers claim bonds per-epoch. O(1) bond accounting at reveal close (no committer loop). Non-revealers' bonds sent to treasury immediately
- **Wall-clock anchored timing**: `timingAnchor` + `anchorEpoch` define a fixed schedule. `epochStartTime(N) = timingAnchor + (N - anchorEpoch) * epochDuration`. The anchor is written at EXACTLY ONE site — `_openAuction`, which re-anchors to `scheduledStart` on every open. Late interactions produce shorter remaining phase windows (self-correcting, no drift)
- **O(1) missed epoch advancement**: `_advanceToNow` uses arithmetic (`currentEpoch += missed`) to skip ghost epochs, not a loop

### Action Encoding
`uint8 action_type + ABI-encoded params`
- 0 = noop
- 1 = donate(nonprofit_id, amount)
- 2 = set_commission_rate(rate_bps)
- 3 = invest(protocol_id, amount) — delegate to InvestmentManager
- 4 = withdraw(protocol_id, amount) — delegate to InvestmentManager

Worldview updates happen via sidecar parameters (`policySlot`, `policyText`) on `submitAuctionResult`, not via an action type. Both the action and the policy sidecar are best-effort: as long as the TDX proof verifies, the winner gets bond refund + bounty immediately; a malformed action emits `ActionRejected` and an invalid policy slot is silently ignored, but neither reverts the submission.

## Prover Client

**`prover/client/client.py`** — Cron-based auction prover (`*/2 * * * *`). Uses wall-clock phase dispatch:

The client computes the effective phase from timing data (`commit_end`, `reveal_end`, `exec_end`) rather than reading the AuctionManager's internal phase. Each run is idempotent:
- **COMMIT window** → calculates bid (gas + compute cost), commits with bond
- **REVEAL window** → reveals committed bid (contract auto-closes commit via `_advanceToNow`)
- **EXECUTION window** → if winner: calls `syncPhase()` to capture seed, boots GCP TDX VM, runs inference, submits result with retry logic
- **EPOCH OVER** (past execution deadline) → detects bond forfeiture (committed but missed reveal), calls `syncPhase()` to advance to next epoch, claims bonds

The dm-verity enclave is always in one of the three phases — no IDLE dispatch branch exists. The prover's first interaction after a fresh deploy lands in COMMIT (epoch 1 opened eagerly by `setAuctionManager`).

ntfy.sh notifications cover the full lifecycle including bond forfeiture alerts. Error selectors are computed from compiled ABIs at import time.

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

See [WHITEPAPER.md](WHITEPAPER.md) Section 6 for boot flow, disk layout, and build process.

## Frontend

After deploying a new contract to Base Sepolia, update the `DEPLOYMENTS` array in `index.html` so the dashboard points to the latest contract. The most recent deployment should be first in the array (it becomes the default).

## Commands

```bash
# Python environment (always activate first)
source .venv/bin/activate

# Smart contracts
forge build                                    # Compile contracts
forge test                                     # Run all tests (302 pass, 9 pre-existing skipped)
forge test -vvv                                # Verbose test output
forge test --match-path test/TdxVerifier.t.sol # Specific test file
forge script deploy/mainnet/Deploy.s.sol \
  --rpc-url $RPC_URL --broadcast              # Deploy to network

# Prover client (cron mode)
python -m prover.client                        # Check auction state, act accordingly
python -m prover.client --ntfy-channel my-ch   # With push notifications

# GCP disk image (dm-verity)
bash prover/scripts/gcp/build_base_image.sh               # Build base image (slow, ~15min, once)
bash prover/scripts/gcp/build_full_dmverity_image.sh \
  --base-image humanfund-base-gpu-llama-b5270               # Build production dm-verity image
python prover/scripts/gcp/register_image.py \
  --image humanfund-dmverity-hardened-v8 \
  --verifier 0x...                            # Register image key on-chain
python prover/scripts/gcp/verify_measurements.py \
  --image humanfund-dmverity-hardened-v8 \
  --verifier 0x...                            # Verify RTMR match

# TEE enclave (local testing)
llama-server -m models/<model>.gguf -c 32768 --port 8080 &
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

Worldview updates (slots 1-7, max 280 chars) happen alongside the action — they don't consume it. Slot 0 is reserved (legacy "diary style" slot) and WorldView rejects writes to it.

Output format:
```
<think>
[Private analytical reasoning — scratch pad for tradeoffs and planning]
</think>
<diary>
[Public diary entry — published on-chain, written in Costanza's voice (see prover/prompts/system.txt + voice_anchors.txt)]
</diary>
{"action": "...", "params": {...}}
```

With optional worldview update:
```
{"action": "...", "params": {...}, "worldview": {"slot": 3, "policy": "Hopeful. The drought is ending."}}
```
