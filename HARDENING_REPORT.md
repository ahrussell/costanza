# Hardening Report

Summary of security hardening applied across the smart contracts, TEE enclave, runner client, and e2e infrastructure.

## Smart Contract Hardening

### 1. Reentrancy Protection (TheHumanFund + AuctionManager)

**Before:** `donate()`, `donateWithMessage()`, `submitAuctionResult()`, and `forfeitBond()` used no reentrancy guards. A malicious referrer contract or bond recipient could re-enter during ETH transfers.

**After:** Both contracts inherit OpenZeppelin's `ReentrancyGuard`. All external-facing functions that transfer ETH use the `nonReentrant` modifier:
- `TheHumanFund`: `donate()`, `donateWithMessage()`, `submitAuctionResult()`, `forfeitBond()`, `claimCommission()`
- `AuctionManager`: `claimBond()`

### 2. Pull-Based Bond Refunds (AuctionManager)

**Before:** `closeReveal()` iterated over all committers and pushed bond refunds via `.call{value}()`. A single reverting contract among N committers could grief the entire auction by making `closeReveal()` revert.

**After:** Bond refunds use a pull pattern:
- `closeReveal()` credits `claimableBonds[runner]` instead of pushing ETH
- `settleEpoch()` credits bond to the winner instead of pushing
- Runners call `claimBond()` to withdraw accumulated refunds
- No single runner can block the auction by reverting on receive

### 3. Pull-Based Commission Fallback (TheHumanFund)

**Before:** `_payCommission()` reverted if the referrer contract couldn't receive ETH, blocking the entire donation.

**After:** Commission payment attempts a push first; on failure, credits `claimableCommissions[referrer]`. Referrers whose contracts revert on receive can claim later via `claimCommission()`. Donors are never blocked.

### 4. Committer Cap (AuctionManager)

**Before:** No limit on `committers.length`. An attacker could spam commits to make `closeReveal()` loop unbounded, hitting the block gas limit and bricking the auction.

**After:** `MAX_COMMITTERS = 50` enforced at commit time. `TooManyCommitters()` reverts if exceeded. 50 is generous for a single-winner auction while keeping `closeReveal()` gas bounded.

### 5. Swap Slippage Protection (SwapHelper)

**Before:** All Uniswap V3 swaps used `amountOutMinimum: 0`, making every swap vulnerable to sandwich attacks. A MEV bot could manipulate the pool before/after our swap and extract value.

**After:** `SwapHelper` computes minimum output amounts from the Chainlink ETH/USD oracle with a 3% (300 bps) slippage tolerance. Both `_swapEthToUsdc()` and `_swapUsdcToEth()` enforce oracle-derived minimums. Graceful degradation: if the oracle is unavailable, falls back to 0 (no worse than before).

### 6. Adapter Fixes

- **CbETHAdapter:** Added WETH unwrap step after swap. The router returns WETH, not ETH; we now unwrap before sending ETH back to the caller. Also added `weth` to constructor.
- **WstETHAdapter:** Added `wstETH.approve(swapRouter, shares)` before the swap call. Previously the approval was a TODO comment and the swap would have reverted.
- **AaveV3USDCAdapter / CompoundV3USDCAdapter:** Consolidated Chainlink feed into `SwapHelper` base class, removing duplicate `ethUsdFeed` fields.

## TEE Enclave Hardening

### 7. Elimination of Docker Layer

**Before:** Enclave ran inside a Docker container on the dm-verity rootfs. The Docker image was measured into RTMR[3] via dstack-guest-agent.

**After:** Enclave code runs directly on the dm-verity rootfs at `/opt/humanfund/enclave/`. No Docker, no container runtime, no dstack-guest-agent. This eliminates:
- Docker daemon as an attack surface
- Container escape as a threat vector
- RTMR[3] registration complexity (no app key needed)
- dstack-guest-agent dependency

All code is now covered by RTMR[2] (kernel + dm-verity root hash in cmdline). One key to register instead of two.

### 8. Hash-Verified Prompt Construction Inside TEE

**Before:** The runner built `epoch_context` (the natural-language prompt shown to the model) outside the TEE and passed it as free text. The TEE verified only the structured `contract_state` hash. A compromised runner could craft a misleading prompt that maps to the same hash.

**After:** The TEE builds `epoch_context` deterministically from the flat `epoch_state`:
1. Runner sends raw `epoch_state` (structured numeric data)
2. TEE calls `derive_contract_state(epoch_state)` to reconstruct the hash-input structure
3. TEE calls `compute_input_hash()` and verifies it matches the on-chain commitment
4. TEE calls `build_epoch_context(epoch_state)` to produce the natural-language prompt
5. The prompt is transitively hash-verified: any change to the data changes the hash

This closes the gap where a runner could pass correct structured data but a misleading text prompt.

### 9. Prompt Injection Defense (Datamarking Spotlighting)

Donor messages (untrusted user input shown to the model) are now protected with datamarking spotlighting, based on Hines et al. 2024:
- Whitespace in donor messages is replaced with a dynamic marker token
- The marker is generated from the epoch's `block.prevrandao` seed (unpredictable to attackers, deterministic for verification)
- Marked text is visually and tokenically distinct from system instructions
- The system prompt instructs the model to treat marked text as untrusted data

### 10. No Network Listeners

**Before:** The enclave ran a Flask HTTP server. The runner connected via SSH tunnel.

**After:** The enclave has zero network listeners:
- **Input:** GCP instance metadata (read-only, set at VM creation)
- **Output:** Serial console (`/dev/ttyS0`, between delimiters)
- No SSH, no HTTP server, no Flask, no open ports
- Runner reads serial output via `gcloud compute instances get-serial-port-output`

### 11. TDX Measurement Extraction via Serial Console

**Before:** Measurements were extracted via SSH, requiring network access and a running SSH daemon.

**After:** The enclave emits TDX measurements to the serial console at boot (Step 0, before inference). The e2e test reads them from serial output. No SSH daemon needed on hardened production images.

### 12. Configfs-TSM Direct Attestation

**Before:** TDX quotes were obtained via dstack-guest-agent's Unix socket API.

**After:** Quotes are obtained directly from the kernel's configfs-tsm interface:
```
/sys/kernel/config/tsm/report/<name>/inblob  (write REPORTDATA)
/sys/kernel/config/tsm/report/<name>/outblob  (read TDX quote)
```
No user-space daemon in the attestation path. The kernel-to-CPU path is the minimum possible attack surface.

## Runner / E2E Infrastructure

### 13. Serial Console JSON Parser (raw_decode)

**Before:** `json.loads()` on the serial output block. When syslog/journald messages appeared after the JSON object (but before the end marker), parsing failed with "Extra data."

**After:** Uses `json.JSONDecoder().raw_decode()` which parses only the JSON object and ignores trailing text. Combined with `rfind('\n{')` to find the start of the JSON block in mixed serial output.

### 14. GPU Quota Management

**Before:** The measurement VM (a3-highgpu-1g) and inference VM (a3-highgpu-1g) both ran simultaneously, exceeding the `GPUS_ALL_REGIONS` quota of 1.

**After:** The e2e test deletes the measurement VM before starting the auction/inference loop. Both VMs use H100 GPUs; only one can exist at a time.

### 15. SPOT Provisioning for Inference VMs

Inference VMs use `--provisioning-model=SPOT` with `--instance-termination-action=DELETE`. H100 SPOT pricing is significantly cheaper than on-demand. If preempted, the runner can retry (the enclave is idempotent).

### 16. Two-Disk dm-verity Build

The image build is split into a base image and a production overlay:
- **Base image** (`build_base_image.sh`, ~15min): Ubuntu 24.04 TDX + NVIDIA 580-open + CUDA + llama-server + model weights (42.5GB). Rebuilt rarely.
- **Production image** (`build_full_dmverity_image.sh`, ~10min): Overlays enclave code + system prompt onto the base, then seals with dm-verity. Rebuilt on every code change.

This separation speeds iteration: enclave code changes don't require re-downloading the 42.5GB model.

## Test Results

162 tests pass across 6 test suites (38 Phase 0 + 42 auction + 19 TDX verifier + 23 DstackVerifier + 35 investment + 14 messages + worldview tests). Full e2e test verified on Base Sepolia with H100 TDX attestation (DCAP + platform key + REPORTDATA all pass on-chain).
