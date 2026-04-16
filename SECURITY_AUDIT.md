# Security Audit Report: The Human Fund

**Date**: 2026-04-16
**Audited commit**: `f8f0c7c` (Add deposit+withdrawal tests for all six DeFi adapters in mainnet fork)
**Scope**: Full codebase adversarial review — smart contracts, TEE enclave, prover client, taint analysis, DeFi adapters, build/deployment scripts, frontend
**Method**: Line-by-line code review (Claude Opus 4.6) from a motivated penetration tester's perspective, with focus on cross-system interaction vulnerabilities and input hash integrity
**Previous audit**: 2026-03-31 (commit `3bbdb3e`)

---

## Executive Summary

This is the second full audit of the codebase. Since the last audit, significant improvements have been made: a static taint analysis system now mechanically enforces input hash coverage, fork tests cover all six DeFi adapters with deposit+withdrawal, and the prover client has retry logic for failed submissions.

The primary attack chain (fabricated display data → biased model decisions) is now closed at three independent levels: AST taint analysis at commit time, Solidity `pure` function enforcement at compile time, and cross-stack hash tests at test time. No critical or high-severity findings remain. The remaining attack surface consists of accepted design trade-offs and defense-in-depth improvements.

**Finding Count**: 0 Critical, 0 High, 4 Medium (2 accepted by design, 2 resolved), 8 Low

---

## Input Hash Integrity — Taint Analysis Assessment

The system's core security claim is **Property 3 (Input Binding)**: a prover cannot show the model a value without including it in the input hash. This is enforced by a three-layer mechanism:

### Layer 1: Static Taint Analysis (`prover/enclave/test_hash_coverage.py`)

An AST walker extracts "state-rooted key paths" (e.g., `treasury_balance`, `nonprofits[*].name`, `investments[*].current_value`) from both `prompt_builder.build_epoch_context` and `input_hash.compute_input_hash`, then asserts the prompt set is a subset of the hash set. The walker handles literal subscripts, `.get()`, aliasing, loop iteration, `enumerate()`, inter-procedural calls, comprehensions, and f-strings.

**Strengths**:
- **Fails loudly** (`WalkerGaveUpError`) on unrecognized patterns rather than silently skipping them. False negatives are treated as fatal.
- Catches root-passed-to-unknown-function (`json.dumps(state)`), `.items()`/`.keys()`/`.values()` on tainted dicts, and all other patterns that could leak untracked fields.
- Has 12 self-tests exercising every supported access pattern.
- Already caught a real vulnerability: investment protocol IDs were displayed from runner-supplied state but hashed positionally, allowing a runner to swap IDs without changing the hash.

**Limitations** (none currently exploitable):
- Single-file scope. Cross-file taint is not tracked, but all prompt-building logic lives in `prompt_builder.py`.
- `_content_hash_for_entry` requires manual registration as a secondary entry point because taint is lost through dict indirection (`by_epoch.get(...)`). New helpers accessed via similar patterns would need manual addition.
- The `_PROMPT_IGNORE` set (line 525) is empty. Its existence creates a mechanism to silently bypass the check if entries are added in the future.

**Non-state prompt content** (voice anchors, system prompt, model weights) is protected by dm-verity rootfs attestation via RTMR[2], not by the input hash. The seed is independently verified on-chain via `block.prevrandao`. No bypass found.

### Layer 2: Solidity `pure` Hash Function (`TheHumanFund._hashSnapshot`)

Declared `pure` — the Solidity compiler mechanically proves no storage reads can occur during hash computation. The function only reads the frozen `EpochSnapshot` struct passed as a parameter. Sub-hashes (nonprofits, messages, history, investments, worldview) are computed from live state at freeze time and stored as `bytes32` fields, eliminating drift.

### Layer 3: Cross-Stack Hash Test (`test/CrossStackHash.t.sol`)

Uses `vm.ffi()` to call Python's `compute_input_hash()` on identical state, asserting byte-exact hash equivalence across Solidity and Python.

**Gap**: Investments and worldview sub-hashes are tested only with empty data (`[]`). A Solidity/Python encoding divergence in `_hash_investments` or `_hash_worldview` (e.g., `bool` encoding for `active`, `uint8` for `risk_tier`, `uint16` for `expected_apy_bps`, or empty-string padding in worldview) would not be caught until a live epoch fails. See M-3 below.

### Derived Values

All derived values shown to the model (`total_assets`, `total_invested`, lifespan estimates, action bounds) are re-computed inside the enclave from hashed primitives via `_derive_trusted_aggregates` (prompt_builder.py:190-213). The code explicitly documents that runner-supplied aggregates are not trusted. No manipulation vector found.

---

## Current Findings

### MEDIUM

#### M-1: Two-Pass Donor-Content Propagation (Mitigated)

**Severity**: MEDIUM
**Component**: `prover/enclave/inference.py`

v19 replaced the three-pass pipeline (think → diary → action) with a two-pass pipeline (diary → grammar-constrained action JSON). The prior "thinking" pass was removed entirely, which narrows the attack surface: there is no longer a private scratchpad whose output is re-fed into subsequent passes, so a donor message cannot be laundered through a "reasoning" round into the final diary/action. `sanitize_thinking()` is retained as defense-in-depth and now scrubs XML-like instruction/override tags from the diary output before it is included in any downstream state.

The action pass is locked to a GBNF grammar (`prover/enclave/action_grammar.gbnf`), so even adversarially-shaped diary text cannot produce an out-of-shape action JSON. A post-parse validator (`validate_and_clamp_action`) additionally clamps `nonprofit_id`, `protocol_id`, `rate_bps`, and transfer amounts against the per-epoch bounds shown in the prompt, coercing out-of-range inputs to do_nothing while preserving any worldview sidecar — closing the loophole where prior on-chain rejection silently wasted an epoch.

**Residual risk**: A well-crafted 280-char donor message (costing 0.01 ETH, datamarked with seed-derived markers from unpredictable `block.prevrandao`) could still subtly bias the model's reasoning within contract bounds. Combined with datamarking spotlighting, per-sample fiction framing on voice anchors, display-data verification, message length limits, economic barriers, contract bounds (max 10% donation per epoch), grammar-gated actions, and validator clamping, the practical exploit cost exceeds extractable value.

---

#### M-2: Last-Revealer Influence on Randomness Seed (Accepted)

**Severity**: MEDIUM
**Component**: `src/AuctionManager.sol:178`

The randomness seed mixes `block.prevrandao` with the XOR of all revealed salts. The last revealer has a binary choice (reveal or forfeit bond), gaining 1-bit influence over the randomness. On Base, proposer collusion requires compromising Coinbase.

**Impact**: Limited — attacker selects between two model outputs, not arbitrary ones. Bond forfeiture makes this costly. Accepted as inherent to commit-reveal randomness.

---

#### M-3: Cross-Stack Hash Tests Lack Investment and Worldview Coverage (Resolved)

**Severity**: MEDIUM → **RESOLVED**
**Component**: `test/CrossStackHash.t.sol`

Previously, all cross-stack tests used empty investments and worldview. Three new tests now exercise populated data:
- `test_cross_stack_hash_with_investments`: Two protocols (Aave WETH + Lido wstETH) with deposits, verifying `bool active`, `uint8 risk_tier`, `uint16 expected_apy_bps` encoding.
- `test_cross_stack_hash_with_worldview`: Three non-empty policy slots, verifying string ABI-encoding across 10 slots.
- `test_cross_stack_hash_with_investments_and_worldview`: Combined test with both populated.

All 7 cross-stack tests pass. Edge cases with maximum collection sizes remain untested but are lower priority.

---

#### M-4: Recovery Script Has Stale REPORTDATA Formula (Resolved)

**Severity**: MEDIUM → **RESOLVED**
**Component**: `scripts/recover_submit.py`

The recovery script had three issues, all now fixed:
1. **Stale REPORTDATA formula**: Removed prompt hash from `output_hash` computation — now matches the current protocol (`keccak256(sha256(action) || sha256(reasoning))`).
2. **Hardcoded values**: VM name, contract address, zone, project, and verifier ID are now CLI arguments. RPC_URL and PRIVATE_KEY are environment variables only (no `--private-key` CLI arg).
3. **`shell=True`**: Replaced with list-based `subprocess.run` via `shlex.split`.
4. **Silent REPORTDATA mismatch**: Script now aborts with an error if REPORTDATA doesn't match, preventing a doomed transaction.

---

### LOW

#### L-1: `totalInflows` Inflated by Internal Transfers

**Component**: `src/TheHumanFund.sol:1663-1668`

The `receive()` function unconditionally adds `msg.value` to `totalInflows` for all incoming ETH, including AuctionManager bond returns and InvestmentManager withdrawal proceeds. These are not external donations. Over time, `totalInflows` diverges from actual external contributions. This metric is frozen into the EpochSnapshot and shown to the model, but does not affect economic bounds — `effectiveMaxBid` uses `address(this).balance`, not `totalInflows`.

#### L-2: `_snapshotEthUsdPrice` Sets Price to 0 on Oracle Failure

**Component**: `src/TheHumanFund.sol`

When the Chainlink oracle is stale or reverts, `epochEthUsdPrice` is set to 0. This blocks USD donation tracking (defensive) but the model sees a $0 ETH/USD price in its context, which could confuse its reasoning about investment strategy.

#### L-3: ETH/USD Price Fallback of $2000 in Prover Client

**Component**: `prover/client/chain.py:178-184`

If `epochEthUsdPrice()` call fails, the prover silently falls back to $2000 in 8-decimal format. This affects bid calculation (gas cost estimation in USD terms) but not on-chain behavior.

#### L-4: TOCTOU in dm-verity Build Process

**Component**: `prover/scripts/gcp/vm_build_all.sh`

Between code installation and squashfs creation, GCP guest agents or other system services could modify files on the rootfs. The dm-verity hash captures whatever state exists at squashfs creation time, so any modification would be consistently captured — the risk is that unintended content makes it into the verified image.

#### L-5: Frontend Renders Owner-Controlled Names Without `escapeHtml()`

**Component**: `index.html:2385, 2410`

Nonprofit names (`np.name`, `np.ein`) and investment protocol names (`pos.name`) are inserted into table HTML via template literals without passing through `escapeHtml()`. These values can only be set by the contract owner via `addNonprofit()` or `addProtocol()`, so exploitation requires the owner's private key. All user-generated content (donor messages, diary entries, worldview policies) correctly uses `escapeHtml()`.

#### L-6: Private Key Accepted via CLI Argument in `register_image.py`

**Component**: `prover/scripts/gcp/register_image.py:183`

The `--private-key` CLI argument makes the key visible in `ps aux` output and shell history. The environment variable fallback (`PRIVATE_KEY`) is the safe default, but the CLI option remains available.

#### L-7: Hardcoded Developer Path in `e2e_test.py`

**Component**: `prover/scripts/gcp/e2e_test.py:1006`

A hardcoded fallback path to a specific developer's `.env` file leaks the developer's username and directory structure. Functional risk is minimal but it should use environment variables or project-relative paths.

#### L-8: Temp File Cleanup Race in GCP TEE Client

**Component**: `prover/client/tee_clients/gcp.py:64-85`

Epoch state JSON is written to a temp file for GCP metadata upload. If the process crashes between file creation and cleanup, the epoch state persists in `/tmp`. The epoch state is not secret (it's all on-chain data), but cleanup is best-effort.

---

## Positive Security Observations

These design patterns were verified and found to be correctly implemented:

1. **CEI pattern consistently applied.** `donate()`, `donateWithMessage()`, `claimCommission()`, and `submitAuctionResult()` all write state before making external calls. `_payCommission()` follows `checks-effects` before the ETH transfer.

2. **ReentrancyGuard properly used.** All external-facing functions that transfer ETH use `nonReentrant`. `syncPhase()` is intentionally unguarded (documented at lines 460-479 with full analysis of reentrancy impact).

3. **`_hashSnapshot` is `pure`.** Compiler-enforced guarantee that no storage reads occur during input hash computation.

4. **Freeze/kill-switch system is one-directional.** `frozenFlags |= flag` can only set bits, never clear them.

5. **Commit-reveal includes runner address.** `keccak256(abi.encodePacked(runner, bidAmount, salt))` prevents reveal frontrunning by binding commits to a specific address.

6. **Adapter slippage is oracle-backed.** SwapHelper, WstETHAdapter, and CbETHAdapter use Chainlink prices with staleness checks to compute minimum output amounts, defending against sandwich attacks.

7. **DonationExecutor clears residual approvals.** Zeroes approvals after use (lines 77, 84).

8. **TdxVerifier checks REPORTDATA padding.** Verifies upper 32 bytes are zero (lines 157-161), preventing attestation quote manipulation.

9. **Investment bounds checked against total assets.** InvestmentManager's `deposit()` checks max total, max per-protocol, and minimum reserve constraints against fund balance plus invested value.

10. **Supply chain integrity in image builds.** llama.cpp pinned to exact commit hash with verification, model weights verified via SHA-256, Python dependencies installed with `--require-hashes`. Debug builds produce different dm-verity hashes and cannot impersonate production.

11. **Atomic state writes.** Prover client uses tempfile + rename pattern with 0o600 permissions set before writing.

12. **File lock prevents concurrent cron instances.** `fcntl.flock(LOCK_EX | LOCK_NB)` in client.py:607.

13. **Cryptographically secure salt generation.** `secrets.token_hex(32)` used for commit salt.

14. **Amount clamping notes appended before hashing.** `validate_and_clamp_action()` appends clamping notes to reasoning BEFORE input hash computation, maintaining attestation integrity.

15. **Position-based ID derivation throughout.** Prompt builder derives displayed IDs from array position (`idx + 1`), never trusting runner-supplied `id` fields. Documented in prompt_builder.py:462-468, input_hash.py:148-150, action_encoder.py:246-254.

16. **Retry logic for failed submissions.** Three-attempt retry schedule with both cached resubmission and fresh TEE re-execution strategies.

---

## Resolved Findings (Since 2026-03-31 Audit)

| Previous ID | Finding | Resolution |
|---|---|---|
| M-3 | Cross-stack hash tests lack investment/worldview coverage | Three new tests added exercising populated investments (2 protocols) and worldview (3 policy slots). All 7 cross-stack tests pass. |
| M-4 | Recovery script stale REPORTDATA formula | Fixed formula (removed prompt hash), made values configurable via CLI args, replaced `shell=True`, abort on REPORTDATA mismatch. |
| L-2 | No fuzz testing / No fork tests | Fork tests now cover all six DeFi adapters with deposit+withdrawal (commit `f8f0c7c`). Fuzz testing still absent but fork tests significantly improve confidence. |
| L-6 | No retry logic on Spot VM preemption | Retry schedule implemented in `client.py:64-68` — three attempts with fresh TEE re-execution on failure. |

---

## Attack Chain Analysis

The primary attack chain — fabricated display data → biased model decisions → fund extraction — is closed at three independent levels:

1. **Display data fabrication**: Blocked by the taint analysis system. The AST walker statically proves at commit time that every field the prompt builder reads is bound into the input hash. The enclave independently re-derives the hash from prover-supplied data, and the contract verifies by strict hash equality. A prover who substitutes display text must find a hash collision (breaks assumption A2).

2. **Swap exploitation**: Oracle staleness is checked (3600s threshold). Slippage units are correct for all adapters. Swap deadlines use `block.timestamp + 300`.

3. **Donor message injection**: Five layers of defense: datamarking spotlighting with seed-derived markers (unpredictable at message submission), `sanitize_thinking()` stripping XML-like tags from reasoning propagation, 280-char message limit, 0.01 ETH minimum per message, and contract bounds (max 10% donation per epoch).

4. **Remaining attack surface**: A well-funded attacker could attempt to influence model decisions via donor messages within contract bounds. Combined with last-revealer randomness influence (forfeit bond for a different seed), this gives limited steering capability. Single-epoch damage is capped at ~12% of treasury (10% donation + 2% bounty). Sustained manipulation requires winning multiple competitive auctions and accepting escalating bond costs.

**Estimated sustained drain potential**: Sustained manipulation requires: winning multiple auctions (competitive bidding), crafting effective 280-char injections through unpredictable datamarking, and accepting bond forfeitures for randomness influence. The economic cost to the attacker exceeds extractable value for any reasonably-sized treasury.
