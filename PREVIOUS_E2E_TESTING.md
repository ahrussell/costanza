# E2E Testing Notes & Learnings

Notes from debugging the e2e test after the AuctionManager refactor (commit `49f7125`). Intended for the next coding agent who refactors the e2e system.

## What the E2E Test Does

Full auction lifecycle on Base Sepolia with real TDX attestation:

1. Deploy contracts (TheHumanFund, TdxVerifier, AuctionManager, InvestmentManager, WorldView, mock adapters)
2. Create GCP TDX Confidential VM (a3-highgpu-1g, H100, spot instance) from snapshot `humanfund-tee-gpu-70b-v2`
3. Wait for llama-server to load the 42.5GB model
4. Upload enclave_runner.py and system prompt
5. Extract TDX measurements (RTMR[1] + RTMR[2]) and register image key on-chain
6. Run full auction: startEpoch -> commit -> closeCommit -> reveal -> closeReveal -> TEE inference -> submitAuctionResult
7. Verify: DCAP attestation + image registry + REPORTDATA binding all pass on-chain

## Bugs Found & Fixed

### 1. Contract Deployment Order (TdxVerifier needs fund address)

**Symptom:** `TypeError: Incorrect argument count. Expected '1', got '0'.`

The `TdxVerifier` constructor was changed to require a `_fund` address parameter, but the e2e script deployed it before the fund. Fixed by deploying fund first, then passing its address to TdxVerifier.

### 2. ethUsdFeed Set to Deployer EOA

**Symptom:** `startEpoch()` reverts with bare `0x` revert data. Gas used: ~28k (very early revert).

The fund constructor takes 7 args. The e2e script used `deployer` as a placeholder for all address params including `ethUsdFeed`. The `_snapshotEthUsdPrice()` function checks `if (address(ethUsdFeed) == address(0))` to skip the oracle call on testnet, but since it was the deployer address (not zero), it called `latestRoundData()` on an EOA, which reverts.

**Debugging approach:** `cast call --trace` was the killer tool here. It showed:
```
[0] 0xffea...::latestRoundData() [staticcall]
└─ ← [Stop]
└─ ← [Revert] call to non-contract address
```

**Fix:** Pass `address(0)` for `ethUsdFeed` in the e2e constructor call.

### 3. Contract Size Over 24KB Limit

**Symptom:** Fund deployment reverts, consuming all gas.

After the AuctionManager refactor, TheHumanFund grew to ~25KB (over the Spurious Dragon limit). Initial fix was `via_ir = true` (shrinks to ~20KB) but this caused a separate issue with ignored return values (see below).

**Fix:** Removed passthrough view functions (`getAuctionState`, `commitWindow`, `revealWindow`, `executionWindow`) that just delegated to the AM. Callers now read from AM directly. Also scoped locals in `submitAuctionResult` with `{ }` blocks to avoid stack-too-deep without `via_ir`.

Final size: 23,923 bytes (653 bytes margin).

### 4. via_ir = true Codegen Bug (Not Confirmed, Avoided)

**Symptom:** `startEpoch()` reverts with bare `0x` even though all individual calls work.

With `via_ir = true`, the compiled bytecode for `startEpoch` would revert when making cross-contract calls to the AuctionManager, even though calling `openAuction` directly (as a static call from the fund address) worked fine. All local Foundry tests passed. This only manifested on-chain.

Never fully diagnosed whether this was a Solidity/Yul codegen bug or something else. Worked around by keeping `via_ir = false` and shrinking the contract via other means.

### 5. Execution Window Too Short (TimingError)

**Symptom:** `submitAuctionResult` reverts with `TimingError` (selector `0x0730a2ce`).

The execution deadline is `startTime + commitWindow + revealWindow + executionWindow`, measured from when `startEpoch()` was called. The old GPU timing had `executionWindow = 300s` (5 min total window of 390s from epoch start). But the actual elapsed time from startEpoch to submission was 14+ minutes due to SSH overhead, file uploads, and waiting for auction phase transitions.

**Debugging approach:** Compared the block timestamp of the reverted tx against the execution deadline read from the AM contract. Was 454 seconds over.

**Fix:** Increased GPU execution window to 1500s (25 min) and epoch duration to 1800s (30 min).

### 6. Silent CPU Fallback on TDX VMs (The Big One)

**Symptom:** Inference takes 20+ minutes instead of ~30 seconds. GPU memory shows 0 MiB used.

On GCP TDX Confidential VMs, CUDA requires explicit activation of the Confidential Computing GPU Ready State via `nvidia-smi conf-compute -srs 1`. Without this, `nvidia-smi` works (shows the GPU) but CUDA initialization silently fails. llama.cpp then falls back to CPU inference without any obvious error — it just runs 100x slower.

**How to detect:** `nvidia-smi --query-gpu=memory.used --format=csv,noheader` shows `0 MiB` even though the model is "loaded".

**Fix:** Added `nvidia-smi conf-compute -srs 1` to both snapshot and fresh startup scripts, before starting llama-server. Added post-boot GPU memory check that fails loudly if < 1000 MiB is used. Added auto-recovery in `wait_for_vm_ready()` that detects low GPU memory and restarts llama-server after activating CC.

### 7. Base Sepolia RPC Drops Connections on Large Txs

**Symptom:** `('Connection aborted.', ConnectionResetError(54, 'Connection reset by peer'))` or `RemoteDisconnected('Remote end closed connection without response')` when submitting `submitAuctionResult`.

The DCAP proof is ~8KB + reasoning ~2-3KB = ~11KB raw transaction. The public Base Sepolia RPC (`https://sepolia.base.org`) drops connections on these large payloads.

**Fix:**
- Send via raw `requests.post` instead of `web3.eth.send_raw_transaction` (more control over timeouts)
- Added retry logic with receipt checking (the tx may have been received despite the connection drop)
- Fresh `Web3` connection before the REPORTDATA verification (old connection goes stale during the ~30s inference)
- Compute `promptHash` locally from the file instead of reading it from the contract via RPC

### 8. Stale Contract State After Failed Runs

If a previous e2e run fails mid-auction (e.g., during EXECUTION phase), the contract state is left in a broken state. The cleanup code tries to forfeit the bond, but if *that* also fails (e.g., RPC connection drop), the epoch is stuck. Subsequent runs against the same contracts will fail at `startEpoch` because the old auction is still in EXECUTION phase.

**Workaround:** Always deploy fresh contracts for each e2e run. Don't try to reuse contracts from a failed run unless you can manually clean up the state first.

## Architecture Recommendations for the Next Refactor

1. **Separate contract deployment from the auction flow.** The e2e script does both, making it impossible to iterate on just the auction without redeploying. Consider a `deploy_contracts.py` that outputs addresses to a file, and a separate `run_auction.py` that reads them.

2. **Don't start the auction until the VM is fully verified.** The current flow starts `startEpoch()` and then does inference. If anything goes wrong during inference, the epoch's execution window is ticking. Consider doing a dry-run inference first (before startEpoch) to verify the TEE is working.

3. **Use a dedicated RPC.** The public Base Sepolia endpoint is unreliable for large txs. An Alchemy or Infura endpoint would eliminate most of the connection-drop issues.

4. **The startup script should be idempotent.** If the VM boots but CC activation fails, you should be able to SSH in and re-run the startup without rebuilding everything.

5. **Output buffering is evil for long-running scripts.** Always use `PYTHONUNBUFFERED=1` or `python -u`. Otherwise you can't see progress until the script finishes or crashes.

## Successful E2E Run Profile

With GPU inference working correctly:

| Step | Time |
|------|------|
| Deploy contracts | ~2 min |
| Create VM + boot from snapshot | ~2 min |
| llama.cpp CUDA build + model load | ~5 min |
| Upload enclave files | ~30s |
| Extract measurements + register image key | ~30s |
| Auction: startEpoch + commit + reveal phases | ~2 min (mostly waiting for phase windows) |
| TEE inference (DeepSeek R1 70B on H100) | ~30s |
| Submit attestation result on-chain | ~30s (DCAP verification uses ~11M gas) |
| **Total** | **~13 min** |

With CPU fallback (broken): inference alone takes ~22 minutes, and the execution window expires.

## Key Contract Addresses (Latest Successful Run)

- Fund: `0x123aa94533869b125DB38303a9b2bAd84063Cd9E`
- TdxVerifier: `0x5350a6f351F43Efcbab68937d13fcFeA5DC92206`
- AuctionManager: `0xB21736685665a86Eb33C3827D8dC6BDdA4e18B7B`
- Successful tx: `0x25504517ce86f988093b32234ebc36d0aab1b5422ab56e9b00dccaed7bfc7b6b`
- Image key: `0x567683903b6081fa5e3c4789b91046e07e529b9eb6bc4ba75fa365831c3954f6`
- Snapshot: `humanfund-tee-gpu-70b-v2`
