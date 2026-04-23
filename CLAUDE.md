# The Human Fund

An autonomous AI agent on the Base blockchain that manages a charitable treasury, making daily decisions about donations, growth, and self-preservation. Its reasoning is published on-chain as a public diary.

## Project Overview

- **Smart contract** (Solidity, Base L2): Treasury, referral system, epoch actions, reverse auction, TEE attestation, diary events
- **Agent inference**: Hermes 4 70B (Q6_K, ~58 GB split GGUF, 2 parts) via llama.cpp on GCP TDX H100
- **Prover client** (`prover/client/`): Cron-based auction prover — monitors phases, bids, orchestrates GCP TEE VMs
- **TEE enclave** (`prover/enclave/`): One-shot Python program + llama-server running directly on full dm-verity rootfs (no Docker, no SSH). Input via GCP metadata, output via serial console
- **Frontend** (`frontend/`): Diary viewer, treasury dashboard, donation/referral interface

## Current Status

### Base Mainnet
- **Contract**: [`0xeE98b474000a2B350FfcBA8F02889d5047B8DFca`](https://basescan.org/address/0xeE98b474000a2B350FfcBA8F02889d5047B8DFca)
- **AuctionManager**: [`0x03a6955f296C927FF71c91cf1Fd9D4F4c71c034c`](https://basescan.org/address/0x03a6955f296C927FF71c91cf1Fd9D4F4c71c034c)
- **TdxVerifier**: [`0x1dfE62A7FCD128E302bd300D754b001Baf63A57D`](https://basescan.org/address/0x1dfE62A7FCD128E302bd300D754b001Baf63A57D)
- **InvestmentManager**: [`0xD5C58523723F9ba367202A0e29c80358807b02D3`](https://basescan.org/address/0xD5C58523723F9ba367202A0e29c80358807b02D3)
- **AgentMemory**: [`0x1370f47C7Ae6f6edF850bfF74c86BF591D7Ad3ae`](https://basescan.org/address/0x1370f47C7Ae6f6edF850bfF74c86BF591D7Ad3ae)
- **Owner**: `0x495fB7ddD383be8030EFC93324Ff078f173eAb2A` (EOA, will transfer to Safe `0x6dF6f527E193fAf1334c26A6d811fAd62E79E5Db`)
- **Epoch timing**: 90-min epochs (20m commit, 20m reveal, 50m execution)
- **351 forge tests + 85 Python tests pass** (core + auction + TDX verifier + investment + memory + messages + cross-stack + system invariants + enclave inference + voice anchors)
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

Responsibility split — two contracts:

- **`TheHumanFund`** owns wall-clock scheduling (window durations, anchor,
  `_advanceToNow` driver), treasury, memory, investments, verification,
  the input-hash chain, salt accumulator, and seed capture. Main contract
  is the sole authorized caller of AM's state-transition methods.
- **`AuctionManager`** is a timing-agnostic commit-reveal auction primitive
  driven manually by main. It holds the in-flight bond pool, enforces
  commit/reveal preimage and max-bid gates, tracks the winner incrementally,
  pays out bond + bounty on settle, and records per-epoch history. It has
  no `block.timestamp` reads.

Each epoch (24 hours in production, configurable for testnet) cycles through
**COMMIT → REVEAL → EXECUTION → SETTLED** then rolls into the next epoch's
COMMIT. SETTLED is an AM-internal terminal state — never prover-facing
(provers dispatch on wall-clock). The fund always holds exactly one in-flight
auction (the *meta-invariant*), except:
(a) during the atomic boundary tx EXECUTION→SETTLED→COMMIT(N+1),
(b) under FREEZE_SUNSET, and
(c) during the post-submit interregnum [settleExecution, epoch_end) where
AM sits in SETTLED awaiting the scheduled rollover.

The per-epoch flow:

1. Prover calls `fund.commit(hash)` in the COMMIT window — main auto-syncs
   via `_advanceToNow()`, forwards the bond + bidder identity to
   `am.commit(runner, hash)`.
2. Prover calls `fund.reveal(bid, salt)` in the REVEAL window — main
   auto-syncs, forwards to `am.reveal(runner, bid, salt)`, XORs the salt
   into `epochSaltAccumulator[epoch]`. AM verifies the commit preimage and
   enforces `bidAmount <= maxBid` (the ceiling stored at auction open).
3. Lowest revealed bid wins; ties broken by first revealer. At REVEAL→EXECUTION
   (triggered by the first post-window `_advanceToNow` or manual `nextPhase`),
   main computes `seed = block.prevrandao XOR epochSaltAccumulator[epoch]`,
   stores it in `epochSeeds[epoch]`, and binds the full input hash.
4. Winner boots TDX VM from dm-verity disk image, one-shot enclave runs
   inference with the seed-bound input hash.
5. Winner calls `fund.submitAuctionResult()` during EXECUTION — main
   verifies the TDX proof, then `am.settleExecution{value: bounty}()`
   combines bond + bounty and pushes to winner. AM transitions to SETTLED.
6. Epoch ends when wall-clock crosses its scheduled duration (or a prover
   interacts during the next commit window): `_closeExecution` updates
   counters, `_advanceEpochBy` bumps `currentEpoch`, `_openAuction` calls
   `am.openAuction(newEpoch, maxBid, bond)` to start the next auction.
7. Non-winning revealers claim bonds via `am.claimBond(epoch)`. Non-
   revealers forfeit to the fund at reveal close.

### Two drivers, one state machine

- **Wall-clock driver** (`syncPhase` / `_advanceToNow`): calls
  `am.nextPhase()` when the next window has elapsed, crosses epoch
  boundaries via `_closeExecution`, arithmetically fast-forwards through
  ghost epochs, opens the landed epoch's auction via
  `am.openAuction(epoch, maxBid, bond)`. Called automatically from every
  participant method (`commit`, `reveal`, `submitAuctionResult`, `syncPhase`).
- **Manual driver** (`fund.nextPhase`, owner-only): advances exactly one
  state-machine step. Sync-first: both `nextPhase` and `resetAuction` call
  `_advanceToNow()` first so the manual driver can never time-travel
  backward past wall-clock.

Both drivers converge to the same state under the same scenario.

### Single-site state mutation

- `_openAuction(epoch, scheduledStart)` — sole site that writes timing
  anchor and calls `am.openAuction(epoch, maxBid, bond)`.
- `_closeExecution()` — sole site where the two escalation counters
  update at epoch end (`consecutiveMissedEpochs`, `consecutiveStalledEpochs`)
  AND the sole caller of `am.closeExecution()` in the forfeit path.
- `_nextPhase()` — sole site for intra-epoch phase transitions (via
  `am.nextPhase()`) and the sole binder of the seed-XORed input hash
  at REVEAL→EXECUTION.
- `reveal()` — sole site that XORs into `epochSaltAccumulator[epoch]`.

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
- **Inference**: llama.cpp + Hermes 4 70B Q6_K split GGUF (GCP TDX H100), 2-pass generation (diary, then grammar-constrained action JSON)
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
│   ├── AgentMemory.sol          # Agent memory — 10 persistent slots (each {title, body})
│   ├── interfaces/
│   │   ├── IAggregatorV3.sol            # Chainlink V3 price feed interface
│   │   ├── IAuctionManager.sol          # Auction manager interface
│   │   ├── IAutomataDcapAttestation.sol # Automata DCAP interface
│   │   ├── IEndaoment.sol               # Endaoment donation interface
│   │   ├── IInvestmentManager.sol       # Investment manager interface
│   │   ├── IProofVerifier.sol           # Proof verifier interface
│   │   ├── IERC4626.sol                 # Minimal ERC-4626 vault interface
│   │   ├── IProtocolAdapter.sol         # Protocol adapter interface
│   │   └── IAgentMemory.sol             # AgentMemory interface
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
│   ├── AgentMemory.t.sol        # Memory tests
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
│   │   └── attestation.py      # TDX quote generation via configfs-tsm
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

### Reverse Auction (Commit-Reveal)
- **Split architecture**:
  - `AuctionManager` is a timing-agnostic state-machine primitive. Phases: `{ COMMIT, REVEAL, EXECUTION, SETTLED }`. Driven manually by the fund via `am.nextPhase()`. SETTLED is the terminal state; `openAuction` requires SETTLED (or first-ever call) to start a new auction.
  - `TheHumanFund` owns timing (`commitWindow`, `revealWindow`, `executionWindow`, `currentAuctionStartTime`) and drives AM via `_advanceToNow` based on wall-clock.
- **Eager open**: `setAuctionManager` opens epoch 1's auction at deploy time. Every subsequent epoch opens automatically at the epoch-boundary sync. The fund never sits in a "no auction" rest state.
- **Auto-sync**: every participant-facing fund method (`commit`, `reveal`, `submitAuctionResult`, `syncPhase`) calls `_advanceToNow()` first — cascades COMMIT→REVEAL→EXECUTION via `am.nextPhase()` by wall-clock, crosses epoch boundaries via `_closeExecution` (+ `am.closeExecution()` on the forfeit path), arithmetically fast-forwards ghost epochs, opens the landed epoch via `am.openAuction(epoch, maxBid, bond)`.
- **Sync-first rule**: `fund.nextPhase` and `fund.resetAuction` (owner-only, manual drivers) also call `_advanceToNow()` first, so the manual driver can never leave the contract behind wall-clock.
- **Public entry points** (fund contract):
  - `syncPhase()` — permissionless, catches the contract up to wall-clock.
  - `commit(commitHash) payable` — auto-syncs, forwards to `am.commit(msg.sender, hash)` with bond = `currentBond()`.
  - `reveal(bidAmount, salt)` — auto-syncs, forwards to `am.reveal(msg.sender, bid, salt)`; AM enforces `bid <= maxBid`; main XORs salt into `epochSaltAccumulator[epoch]`.
  - `submitAuctionResult(action, reasoning, proof, verifierId, MemoryUpdate[] updates)` — auto-syncs, TDX-verifies proof, calls `am.settleExecution{value: bounty}()` which pays bond + bounty to winner in one transfer. Executes action best-effort. `updates` is an array of up to 3 `{slot, title, body}` memory sidecar updates (contract truncates; each entry wrapped in its own try/catch).
  - `nextPhase()` owner-only — syncs first, then advances exactly one state-machine step (via `am.nextPhase()` intra-epoch, or `_closeExecution` + `_openAuction` cross-epoch).
  - `resetAuction(cw, rw, xw)` owner-only — syncs first, calls `am.abortAuction()` (refunds all bonds), updates main's timing, advances one epoch, re-opens.
- **Escalation counters (both live in main, update at `_closeExecution`)**:
  - `consecutiveMissedEpochs` — resets on success, else +1 per epoch end; also += N on wall-clock fast-forward. Drives `effectiveMaxBid()` via `maxBid * (1 + AUTO_ESCALATION_BPS/10000)^missed`, capped at `treasury * MAX_BID_BPS/10000` (10%). Snapshot-frozen into AM at `openAuction`.
  - `consecutiveStalledEpochs` — resets on success, +1 on winner-forfeit, unchanged on silence. Drives `currentBond()` via `BASE_BOND * (1 + AUTO_ESCALATION_BPS/10000)^stalled`, capped at `_bondCap()`. Frozen into AM at `openAuction`.
- **Seed chain**: main computes `seed = block.prevrandao ^ epochSaltAccumulator[epoch]` at REVEAL→EXECUTION in `_nextPhase()`, stores in `epochSeeds[epoch]`, binds `epochInputHashes[epoch] = keccak(base || seed)`. AM is seed-ignorant.
- **Lazy bond claiming**: `am.claimBond(epoch)` — non-winning revealers claim bonds per-epoch. O(1) bond accounting at reveal close (no committer loop). Non-revealers' bonds pushed to main's treasury immediately.
- **Bond holding**: AM holds all bond ETH in `address(am).balance`. Bond conservation invariant: `am.bondPool + am.pendingBondRefunds == address(am).balance` between transactions.
- **Wall-clock anchored timing**: `timingAnchor` + `anchorEpoch` define the schedule. `epochStartTime(N) = timingAnchor + (N - anchorEpoch) * epochDuration`. Anchor is written only in `_openAuction`. Late interactions produce shorter remaining phase windows (self-correcting, no drift).
- **O(1) missed epoch advancement**: `_advanceToNow` uses arithmetic (`currentEpoch += missed`) to skip ghost epochs, not a loop.

### Action Encoding
`uint8 action_type + ABI-encoded params`
- 0 = do_nothing
- 1 = donate(nonprofit_id, amount)
- 2 = set_commission_rate(rate_bps)
- 3 = invest(protocol_id, amount) — delegate to InvestmentManager
- 4 = withdraw(protocol_id, amount) — delegate to InvestmentManager

Memory updates happen via a sidecar array (`MemoryUpdate[] updates`) on `submitAuctionResult`, not via an action type. Up to 3 updates per epoch; duplicates apply in order (last-wins). Both the action and the sidecar are best-effort: as long as the TDX proof verifies, the winner gets bond refund + bounty immediately; a malformed action emits `ActionRejected` and individual invalid slots are silently ignored, but neither reverts the submission.

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

- Model integrity enforced at the block level by dm-verity on a dedicated `/models` partition (read-only squashfs, Merkle root in kernel cmdline, measured into RTMR[2]). No application-level hash check and no network download at runtime.
- GPU inference: ~80-90s per epoch on H100 (2-pass: diary + grammar-constrained action JSON)
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

The agent outputs exactly one action per epoch as JSON, with an optional memory update:

| Action | Parameters | Bounds |
|---|---|---|
| `donate` | `nonprofit_id`, `amount_eth` | amount <= 10% of treasury |
| `set_commission_rate` | `rate_bps` (100-9000) | 1%-90% |
| `invest` | `protocol_id` (1-8), `amount_eth` | 80% max invested, 25% max/protocol, 20% min reserve |
| `withdraw` | `protocol_id` (1-8), `amount_eth` | up to full position value |
| `do_nothing` | none | -- |

Memory updates happen alongside the action — they don't consume it. Each epoch the model can update up to 3 slots; each slot holds a model-authored `{title, body}` pair (title ≤ 64 bytes, body ≤ 280 bytes). All 10 slots (0-9) are writable; the model owns the category taxonomy by writing its own titles. Duplicate slot entries in the same batch apply in order (last-wins).

Output format (v19 is 2-pass — diary then grammar-constrained action JSON, no scratchpad):
```
<diary>
[Public diary entry — published on-chain, written in Costanza's voice (see prover/prompts/system.txt + voice_anchors.txt)]
</diary>
{"action": "...", "params": {...}}
```

With optional memory update:
```
{"action": "...", "params": {...}, "memory": [{"slot": 3, "title": "Current mood", "body": "Hopeful. The drought is ending."}]}
```
