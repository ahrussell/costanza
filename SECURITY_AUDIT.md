# Security Audit Report: The Human Fund

**Date**: 2026-03-31
**Audited commit**: `3bbdb3e` (Fix diary newlines, add Endaoment link, and copy edits)
**Scope**: Full codebase adversarial review — smart contracts, TEE enclave, prover client, DeFi adapters, build/deployment scripts, auction system
**Method**: Line-by-line code review from a motivated penetration tester's perspective, with focus on cross-system interaction vulnerabilities

---

## Executive Summary

Multiple rounds of auditing and remediation have closed all critical, high, and most medium severity findings. The remaining attack surface consists of two accepted medium-severity design trade-offs and seven low-severity issues. No finding currently enables theft of funds or denial of service.

**Finding Count**: 0 Critical, 0 High, 2 Medium (accepted by design), 7 Low

---

## Current Findings

### MEDIUM

#### M-1: Three-Pass Reasoning Propagation (Mitigated)

**Severity**: MEDIUM
**Component**: `prover/enclave/inference.py`

The three-pass inference system (thinking → diary → action) propagates Pass 1 thinking into Pass 2/3 contexts. `sanitize_thinking()` strips XML-like instruction/override tags from Pass 1 output before propagation, preventing reasoning laundering of injected directives.

**Residual risk**: A well-crafted 280-char donor message (costing 0.01 ETH, datamarked) could still subtly bias the model's reasoning within contract bounds — but injected tags cannot survive sanitization into Passes 2/3. Combined with datamarking, display data verification, message length limits, economic barriers, and contract bounds, the practical exploit cost exceeds extractable value.

---

#### M-2: Last-Revealer Influence on Randomness Seed (Accepted)

**Severity**: MEDIUM
**Component**: `src/AuctionManager.sol:178`

The randomness seed mixes `block.prevrandao` with the XOR of all revealed salts. The last revealer has a binary choice (reveal or forfeit bond), gaining 1-bit influence over the randomness. On Base, proposer collusion requires compromising Coinbase.

**Impact**: Limited — attacker selects between two model outputs, not arbitrary ones. Bond forfeiture makes this costly. Accepted as inherent to commit-reveal randomness.

---

### LOW

#### L-1: Temp File Cleanup Race in GCP TEE Client

**Component**: `prover/client/tee_clients/gcp.py:65-85`

Epoch state JSON is written to a temp file for GCP metadata upload. If the process crashes between file creation and cleanup, the epoch state persists in `/tmp`. The epoch state is not secret (it's all on-chain), but the temp file may include assembled display data.

#### L-2: No Fuzz Testing

**Component**: Test suite

175 tests pass, but all use hardcoded values. No property-based/fuzz tests for bounds checking, action encoding, hash computation, or adapter interactions. No fork tests against live DeFi protocols.

#### L-3: `_snapshotEthUsdPrice` Sets Price to 0 on Oracle Failure

**Component**: `TheHumanFund.sol`

When the Chainlink oracle is stale or reverts, `epochEthUsdPrice` is set to 0. This blocks donations (defensive) but the model sees a $0 ETH/USD price in its context, which could confuse its reasoning about investment strategy.

#### L-4: ETH/USD Price Fallback of $2000 in Prover Client

**Component**: `prover/client/chain.py`

If `epochEthUsdPrice()` call fails, the prover silently falls back to $2000 in 8-decimal format. This affects bid calculation (gas cost estimation in USD terms) but not on-chain behavior.

#### L-5: TOCTOU in dm-verity Build Process

**Component**: `prover/scripts/gcp/vm_build_all.sh`

The build runs on a live VM. Between code installation and squashfs creation, GCP guest agents or other system services could modify files on the rootfs. The dm-verity hash captures whatever state exists at squashfs creation time, so any modification would be consistently captured — the risk is that unintended content makes it into the verified image.

#### L-6: No Retry Logic on Spot VM Preemption

**Component**: `prover/client/tee_clients/gcp.py`

If GCP preempts a SPOT VM during inference, the prover loses the epoch and forfeits their bond. The prover client has no retry logic to detect preemption and attempt a new VM within the execution window.

#### L-7: Hardcoded Username in Debug Image Build

**Component**: `prover/scripts/gcp/build_full_dmverity_image.sh:116`

SSH key is baked with hardcoded username `andrewrussell`. This only applies to debug builds (`ENABLE_SSH=true`) and debug images produce a different dm-verity hash that won't pass production attestation. However, if multiple operators build debug images, the hardcoded username is wrong for all but one.

---

## Attack Chain Analysis

The primary attack chain — fabricated display data → biased model decisions → sandwich swaps — has been closed:

1. **Display data fabrication**: Blocked by TEE `verify_display_data()`. The prover cannot substitute fake investment positions, messages, policies, or history without failing hash verification.

2. **Swap exploitation**: Oracle staleness is checked (3600s threshold). Slippage units are correct for all adapters. Swap deadlines use `block.timestamp + 300` (5-minute buffer for defense-in-depth against future sequencer decentralization).

3. **Remaining attack surface**: A well-funded attacker could influence model decisions via donor messages (0.01 ETH per message, 280 chars, datamarked) within contract bounds (max 10% donation, investment caps). XML-like injection tags are stripped from reasoning before propagation across inference passes. Combined with last-revealer randomness influence (forfeit bond for a different seed), this gives limited steering capability. Single-epoch damage is capped at ~10% of treasury.

**Estimated sustained drain potential**: Sustained manipulation would require: winning multiple auctions (competitive bidding), crafting effective 280-char injections through datamarking, and accepting bond forfeitures for randomness influence. The economic cost to the attacker likely exceeds the extractable value for any reasonably-sized treasury.
