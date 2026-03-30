# Security Audit Report: The Human Fund

**Date**: 2026-03-30
**Scope**: Full codebase adversarial review — smart contracts, TEE enclave, prover client, DeFi adapters, build/deployment scripts, auction system
**Method**: Line-by-line code review from a motivated penetration tester's perspective, with focus on cross-system interaction vulnerabilities
**Prior audit**: 2026-03-29 — this report reflects the current codebase after significant remediation work

---

## Executive Summary

The previous audit identified 3 critical, 7 high, 12 medium, and 10 low severity findings. Substantial remediation has been completed: the critical display data verification gap (C-1, C-2) has been closed with comprehensive hash-binding in the TEE, DeFi adapter slippage and oracle issues have been fixed, and build-time supply chain risks have been addressed. The auction system has been redesigned with commit-reveal, pull-based bond refunds, and salt-mixed randomness.

The remaining attack surface is significantly reduced. The most notable residual issues are: swap deadlines that use `block.timestamp` (ineffective as a timing constraint, though low-impact on Base L2), shell injection in infrastructure scripts, the unbounded auto-escalation loop, and the inherent last-revealer influence on randomness in the commit-reveal scheme.

**Finding Count**: 0 Critical, 1 High, 6 Medium, 7 Low

---

## Remediation Status (Prior Audit)

### Fixed

| Prior ID | Finding | Status |
|----------|---------|--------|
| **C-1** | Display data not hash-bound in TEE | **FIXED** — `verify_display_data()` in `input_hash.py` recomputes investment, worldview, message, and history hashes from expanded data and verifies they match opaque on-chain hashes |
| **C-2** | Datamarking bypass via prover-controlled messages | **FIXED** — Display data verification (C-1 fix) prevents provers from substituting fake message text |
| **H-2** | Wrong slippage units in WstETH/CbETH | **FIXED** — `WstETHAdapter` now uses `getStETHByWstETH()` to convert to ETH terms; `CbETHAdapter` uses `exchangeRate()` for proper conversion |
| **H-3** | Oracle staleness not checked in SwapHelper | **FIXED** — `STALENESS_THRESHOLD = 3600` enforced, `updatedAt` checked, reverts on stale data (`SwapHelper.sol:116,132`) |
| **H-4** | Unsigned llama.cpp clone | **FIXED** — Commit hash pinned and verified at build time (`build_base_image.sh:148-156`); mismatch aborts build |
| **H-5** | Wrong image key formula in scripts | **FIXED** — Both `register_image.py` and `verify_measurements.py` now use `sha256(MRTD \|\| RTMR[1] \|\| RTMR[2])`, matching `TdxVerifier.sol` |
| **H-6** | No reentrancy guard on InvestmentManager | **FIXED** — `ReentrancyGuard` inherited; `nonReentrant` on `deposit()`, `withdraw()`, `withdrawAll()` (`InvestmentManager.sol:19,188,226,269`) |
| **H-7** | SSH key baked into production images | **FIXED** — Key copy gated behind `ENABLE_SSH` flag (`build_full_dmverity_image.sh:112`); debug builds produce different dm-verity hash and won't pass production attestation |
| **M-5** | Zero default auction timing windows | **FIXED** — `setTiming()` requires all windows > 0 (`AuctionManager.sol:225`) |
| **M-6** | Commit salt stored world-readable | **FIXED** — `os.fchmod(fd, 0o600)` before writing (`state.py:59`) |
| **M-7** | No hash pinning for Python deps | **FIXED** — `pip install --require-hashes --no-cache-dir` (`build_base_image.sh:188`) |
| **M-8** | Private key / error leakage to ntfy | **FIXED** — `_sanitize()` redacts private keys, API keys, and Bearer tokens before external transmission (`notifier.py:15-24`) |
| **L-10** | Non-revealer bonds permanently locked | **FIXED** — Unrevealed bonds now sent to fund treasury (`AuctionManager.sol:182-195`); revealed non-winners use pull-based `claimBond()` |

### Partially Fixed

| Prior ID | Finding | Status |
|----------|---------|--------|
| **H-1** | No swap deadline | **PARTIALLY FIXED** — Deadline field added to all swap params, but value is `block.timestamp` which is always satisfied. See M-1 below. |
| **C-3** | Reasoning injection via Pass 2 | **IMPROVED** — Now three-pass inference (thinking → diary → action). Pass 1 analytical thinking is never transmitted on-chain or hashed. However, Pass 1 reasoning still propagates into Pass 2 and Pass 3 context. See M-3 below. |
| **M-9** | `prevrandao` proposer-influenceable | **IMPROVED** — Randomness seed now `keccak256(prevrandao, saltAccumulator)` where `saltAccumulator` is XOR of all revealed salts. See M-4 below. |
| **M-12** | Shell injection in Python scripts | **PARTIALLY FIXED** — `gcp.py` uses `shlex.split()`. But `e2e_test.py`, `register_image.py`, and `verify_measurements.py` still use `shell=True`. See M-6 below. |

### Accepted by Design (Moved to SECURITY_MODEL.md)

| Prior ID | Finding | Status |
|----------|---------|--------|
| **M-2** | Commit-reveal not truly sealed-bid | Inherent to on-chain commit-reveal. Now mitigated by bond forfeiture. See A-1 in SECURITY_MODEL.md. |
| **M-3** | `startEpoch` auto-forfeit race condition | Accepted. See A-5 in SECURITY_MODEL.md. |
| **M-4** | `receive()` inflates `totalInflows` | Informational only. See A-6 in SECURITY_MODEL.md. |
| **M-10** | Morpho ERC-4626 share price inflation | Accepted with mitigations. See A-8 in SECURITY_MODEL.md. |
| **M-11** | `withdrawAll` silently swallows failures | Accepted — partial withdrawal better than total failure. See A-10 in SECURITY_MODEL.md. |
| **L-1** | Serial console output injection | Mitigated by attestation REPORTDATA verification. |
| **L-2** | `_snapshotEthUsdPrice` sets price to 0 | Defensive behavior — blocks donations when oracle unavailable. |
| **L-3** | Unlimited token approvals to swap router | Mitigated by immutable router address. |
| **L-4** | UTF-8 truncation in WorldView/Messages | Cosmetic; no security impact. |
| **L-6** | Inference retry with same seed | **FIXED** — Seed now increments per retry attempt (`enclave_runner.py:375-378`). |
| **L-8** | Spot VM preemption during auction | Accepted — bond forfeiture is the designed penalty. |

---

## Current Findings

## HIGH

### H-1: `effectiveMaxBid` / `currentBond` Unbounded Loop (Carried from M-1)

**Severity**: HIGH
**Component**: `src/TheHumanFund.sol:1054-1068, 536-546`

```solidity
function effectiveMaxBid() public view returns (uint256) {
    if (consecutiveMissedEpochs == 0) return maxBid;
    uint256 hardCap = (address(this).balance * MAX_BID_BPS) / 10000;
    uint256 escalated = maxBid;
    for (uint256 i = 0; i < consecutiveMissedEpochs; i++) {
        escalated = escalated + (escalated * AUTO_ESCALATION_BPS) / 10000;
        if (escalated >= hardCap) return hardCap;
    }
    return escalated;
}
```

Both `effectiveMaxBid()` and `currentBond()` loop `consecutiveMissedEpochs` times. This counter increments on every missed epoch via permissionless `startEpoch()` → `closeCommit()` (when no committers) → `_advanceEpochMissed()`. An attacker could repeatedly trigger missed epochs to inflate the counter.

The early-exit when `escalated >= hardCap` limits practical iterations to ~25 for reasonable `maxBid` values (10% compound reaches 2% treasury cap quickly). However, if `maxBid` is set very low relative to the treasury, the loop could run hundreds of iterations before hitting the cap. `currentBond()` compounds on top of `effectiveMaxBid()`, adding a nested call.

If `consecutiveMissedEpochs` reaches ~600+, gas cost exceeds block limits, bricking `startEpoch()`, `reveal()`, and any function calling `effectiveMaxBid()` or `currentBond()`. The auction system becomes permanently stuck.

**Impact**: Permanent denial of service on the auction system after sustained missed epochs.

**Fix**: Use closed-form exponentiation with a fixed iteration cap, or cap `consecutiveMissedEpochs` at a safe maximum (e.g., 50).

---

## MEDIUM

### M-1: `block.timestamp` Swap Deadline Is Ineffective

**Severity**: MEDIUM (LOW on Base L2 specifically)
**Components**: `src/adapters/SwapHelper.sol:77,98`, `WstETHAdapter.sol:72,106`, `CbETHAdapter.sol:62,93`, `TheHumanFund.sol:901`

All Uniswap swaps use `deadline: block.timestamp`. Since `block.timestamp` is set by the block producer at inclusion time, the deadline check (`block.timestamp <= deadline`) is always satisfied regardless of when the transaction is included. This is effectively no deadline.

On Ethereum L1, this would allow transactions to be held in the mempool indefinitely for sandwich attacks. On Base L2, the centralized sequencer (Coinbase) processes transactions quickly with no public mempool, significantly reducing this risk.

**Impact**: On Base, minimal — the sequencer would need to actively delay transactions. If the contract is ever deployed on L1 or a decentralized L2, this becomes HIGH severity.

**Fix**: Use a caller-provided deadline or `block.timestamp + DEADLINE_BUFFER` (e.g., 30 minutes). Even on L2, this provides defense-in-depth against future sequencer decentralization.

---

### M-2: `_clearCurrentAuction` Loop Over Committers Array

**Severity**: MEDIUM
**Component**: `src/AuctionManager.sol:286-305`

```solidity
function _clearCurrentAuction() internal {
    for (uint256 i = 0; i < committers.length; i++) {
        address runner = committers[i];
        delete bidCommits[runner];
        delete hasCommitted[runner];
        delete hasRevealed[runner];
        delete revealedBids[runner];
    }
    delete committers;
    // ...
}
```

Called at the start of each `openAuction()`, this loops over the previous auction's committers to clean up mapping state. `MAX_COMMITTERS = 50` bounds this, but each iteration performs 4 `SSTORE` operations. At 50 committers, this is 200 storage writes (~1M gas) added to the `startEpoch()` transaction cost, which could make the first epoch after a heavily-contested auction expensive.

**Impact**: Elevated gas cost for `startEpoch()` after popular auctions. Not a DoS since MAX_COMMITTERS is capped.

---

### M-3: Three-Pass Reasoning Propagation

**Severity**: MEDIUM
**Component**: `prover/enclave/inference.py:62-119`

The three-pass inference system (thinking → diary → action) propagates all prior pass outputs into subsequent pass contexts:
- Pass 2 prompt includes Pass 1 thinking
- Pass 3 prompt includes Pass 1 thinking + Pass 2 diary

If a datamarked donor message partially influences Pass 1's analytical reasoning, that influenced content becomes unmarked trusted context in Passes 2 and 3. This is a "reasoning laundering" vector.

**Mitigations already in place**: (1) Datamarking makes injection harder in Pass 1; (2) display data verification prevents prover-fabricated messages; (3) messages are limited to 280 chars; (4) minimum 0.01 ETH economic barrier; (5) contract bounds cap any resulting action.

**Residual risk**: A well-crafted 280-char message that costs 0.01 ETH could subtly bias the model's reasoning within contract bounds. The three-pass architecture makes this marginally easier than a single-pass system since influenced reasoning compounds.

---

### M-4: Last-Revealer Influence on Randomness Seed

**Severity**: MEDIUM
**Component**: `src/AuctionManager.sol:175`

```solidity
currentRandomnessSeed = uint256(keccak256(abi.encodePacked(block.prevrandao, saltAccumulator)));
```

The randomness seed mixes `block.prevrandao` with the XOR of all revealed salts. This is an improvement over pure `prevrandao`, but the last revealer has a binary choice:
1. **Reveal**: seed = `keccak256(prevrandao, accumulator XOR mySalt)`
2. **Don't reveal**: seed = `keccak256(prevrandao, accumulator)` (forfeit bond)

The last revealer can compute both seeds before deciding, gaining a 1-bit influence over the randomness at the cost of their bond. A last-revealer who is also a block proposer on Base (requires Coinbase sequencer compromise) could additionally manipulate `prevrandao`.

**Impact**: Limited — attacker selects between two model outputs, not arbitrary ones. Bond forfeiture makes this costly. On Base, proposer collusion requires compromising Coinbase.

---

### M-5: `_storeHistory` Loop Over Committers

**Severity**: MEDIUM
**Component**: `src/AuctionManager.sol:260-283`

`_storeHistory()` loops over all committers to store per-runner `BidRecord` structs. Combined with `_clearCurrentAuction()` (M-2), this means each auction transition involves two full loops over the committers array, each doing multiple storage writes. At MAX_COMMITTERS=50, the combined gas cost could make `closeRevealPhase()` expensive when it also distributes bonds.

**Impact**: Elevated gas costs for auction state transitions. Bounded by MAX_COMMITTERS=50.

---

### M-6: Shell Injection in Infrastructure Scripts

**Severity**: MEDIUM
**Components**: `prover/scripts/e2e_test.py:105`, `register_image.py:21`, `verify_measurements.py:30`

```python
# e2e_test.py
subprocess.run(cmd, shell=True, capture_output=capture, text=True, timeout=timeout)

# register_image.py / verify_measurements.py
subprocess.run(f"gcloud {args}", shell=True, capture_output=True, text=True, timeout=timeout)
```

CLI arguments (VM names, zones, image names) are interpolated into shell commands without sanitization. A malicious `--vm-name` like `foo; rm -rf /` would execute arbitrary commands.

**Impact**: Local privilege escalation if an attacker can influence script arguments. These are operator-run scripts, not production code, limiting the attack surface to the prover's own machine.

**Fix**: Use `subprocess.run(["gcloud", ...args], shell=False)` with argument lists.

---

## LOW

### L-1: Temp File Cleanup Race in GCP TEE Client

**Component**: `prover/client/tee_clients/gcp.py:65-85`

Epoch state JSON is written to a temp file for GCP metadata upload. If the process crashes between file creation (line 65) and cleanup (line 85), the epoch state (including seeds, treasury data) persists in `/tmp`. The epoch state is not secret (it's all on-chain), but the temp file may include assembled display data.

### L-2: No Fuzz Testing (Carried from L-9)

**Component**: Test suite

165 tests pass, but all use hardcoded values. No property-based/fuzz tests for bounds checking, action encoding, hash computation, or adapter interactions. No fork tests against live DeFi protocols.

### L-3: `_snapshotEthUsdPrice` Sets Price to 0 on Oracle Failure

**Component**: `TheHumanFund.sol:708-724`

When the Chainlink oracle is stale or reverts, `epochEthUsdPrice` is set to 0. This blocks donations (defensive) but the model sees a $0 ETH/USD price in its context, which could confuse its reasoning about investment strategy.

### L-4: ETH/USD Price Fallback of $2000 in Prover Client

**Component**: `prover/client/chain.py:84-86`

If `epochEthUsdPrice()` call fails, the prover silently falls back to $2000 in 8-decimal format. This affects bid calculation (gas cost estimation in USD terms) but not on-chain behavior.

### L-5: TOCTOU in dm-verity Build Process (Carried from L-7)

**Component**: `prover/scripts/vm_build_all.sh`

The build runs on a live VM. Between code installation and squashfs creation, GCP guest agents or other system services could modify files on the rootfs. The dm-verity hash captures whatever state exists at squashfs creation time, so any modification would be consistently captured — the risk is that unintended content makes it into the verified image.

### L-6: No Retry Logic on Spot VM Preemption

**Component**: `prover/client/tee_clients/gcp.py`

If GCP preempts a SPOT VM during inference, the prover loses the epoch and forfeits their bond. The prover client has no retry logic to detect preemption and attempt a new VM within the execution window. The `--instance-termination-action=DELETE` flag means the VM vanishes without trace, and the polling loop eventually times out.

### L-7: Hardcoded Username in Debug Image Build

**Component**: `prover/scripts/build_full_dmverity_image.sh:116`

SSH key is baked with hardcoded username `andrewrussell`. This only applies to debug builds (`ENABLE_SSH=true`) and debug images produce a different dm-verity hash that won't pass production attestation. However, if multiple operators build debug images, the hardcoded username is wrong for all but one.

---

## Architectural Assessment: Auction Redesign

The auction system has been significantly redesigned since the prior audit. Key improvements:

1. **Commit-reveal scheme**: Bids are sealed via `keccak256(bidAmount, salt)` during the commit phase, then revealed. This prevents bid-sniping (the old first-price mechanism allowed last-second undercutting).

2. **Pull-based bond refunds**: Non-winners claim bonds via `claimBond()` instead of receiving inline refunds. This prevents griefing via gas-heavy receive hooks. Non-revealers' bonds are transferred to the fund treasury.

3. **Salt-mixed randomness**: The inference seed incorporates `saltAccumulator` (XOR of revealed salts) alongside `prevrandao`, reducing single-party influence on randomness.

4. **MAX_COMMITTERS cap**: Limits the committers array to 50, bounding loop gas costs in `_clearCurrentAuction()` and `_storeHistory()`.

5. **Three-phase timing**: Commit → Reveal → Execution with configurable, non-zero windows.

**Residual concerns**: The loop-based gas costs in state transitions (M-2, M-5) and the last-revealer randomness influence (M-4) are inherent to this design. Neither is exploitable for profit — they're cost/fairness issues.

---

## Attack Chain Analysis (Updated)

The prior audit's primary attack chain — fabricated display data → biased model decisions → sandwich swaps — has been substantially closed:

1. **Display data fabrication**: Blocked by TEE `verify_display_data()`. The prover cannot substitute fake investment positions, messages, policies, or history without failing hash verification.

2. **Swap exploitation**: Oracle staleness is checked (3600s threshold). Slippage units are correct for all adapters. Swap deadlines use `block.timestamp` (ineffective in theory, low-impact on Base L2).

3. **Remaining attack surface**: A well-funded attacker could influence model decisions via donor messages (0.01 ETH per message, 280 chars, datamarked) within contract bounds (max 10% donation, investment caps). Combined with last-revealer randomness influence (forfeit bond for a different seed), this gives limited steering capability. Single-epoch damage is capped at ~10% of treasury.

**Estimated sustained drain potential**: Under the current mitigations, sustained manipulation would require: winning multiple auctions (competitive bidding), crafting effective 280-char injections through datamarking, and accepting bond forfeitures for randomness influence. The economic cost to the attacker likely exceeds the extractable value for any reasonably-sized treasury.

---

## Priority Remediation Order

| Priority | Finding | Fix |
|----------|---------|-----|
| 1 | H-1: Unbounded escalation loop | Cap `consecutiveMissedEpochs` or use closed-form exponentiation |
| 2 | M-1: `block.timestamp` deadline | Use `block.timestamp + buffer` for all swaps |
| 3 | M-6: Shell injection in scripts | Use `shell=False` with argument lists |
| 4 | M-2, M-5: Auction loop gas costs | Consider lazy cleanup or gas-bounded iteration |
| 5 | M-3: Reasoning propagation | Consider stripping datamarked content from Pass 1 output before Pass 2 |
| 6 | M-4: Last-revealer randomness | Document as accepted risk; consider VDF or threshold signature schemes if randomness quality becomes critical |
