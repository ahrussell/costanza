# AgentMemory Redesign — Design Doc

_(Filename retains the `V2` marker as a stable identifier for this redesign
milestone, but there's no `AgentMemoryV2` contract in source. We edit
`src/AgentMemory.sol` in place; the legacy v1 bytecode lives on-chain at
`0x8de1Bb…` and serves as the rollback target. "V2" in the text below
refers to the new on-chain deployment, not a source-file name.)_

**Status:** draft

**Author:** plan agreed with project lead 2026-05-11

**Problem statement:** the `description` field on each `InvestmentManager`
protocol entry never reaches the agent's prompt. Costanza only sees protocol
NAMES, which works for well-known yield adapters (Aave, Lido, etc.) but
silently fails for project-specific adapters like `Costanza Token`. The
description is on-chain (set at `addProtocol`) but isn't covered by any input
hash, so the runner can't surface it to the TEE without breaking the
"every prompt field is hash-covered" rule.

## 1. Goals

- **G1.** Investment descriptions reach Costanza's prompt, inlined into each
  investment's listing row (NOT as a separate "Investment Context" section,
  and NOT as agent-authored memory entries).
- **G2.** Hash-covered end to end — Sol-side and Python-side must produce
  byte-identical hashes for the same state. No new "free" inputs that bypass
  the hash chain.
- **G3.** Future-proof — adding a 7th adapter via `addProtocol` requires NO
  code changes on either Sol or Python; description just shows up in the next
  epoch's snapshot automatically.
- **G4.** Single source of truth for `memoryHash` inputs. Whatever the runner
  reads as memory-input MUST come from `agentMemory.getEntries()`. The
  contract that hashes the data is the contract that serves it. Symmetric
  read-and-hash flow, robust to any future mutability changes in descriptions.
- **G5.** `TheHumanFund` (immutable) is untouched. Only the two methods it
  calls on `IAgentMemory` (`setEntry`, `stateHash`) keep their existing
  signatures. The fund doesn't see `getEntries()`, so changing that method's
  return type doesn't affect the fund.
- **G6. Semantic minimalism — the description convention lives in exactly
  two places: `prompt_builder.py` (TEE) and `index.html` (frontend).** The
  rest of the pipeline (Sol stateHash, runner state-build, Python hash
  mirror) treats the entries list as an opaque variable-length collection
  of (title, body) pairs. Anything that hashes it just loops; anything that
  passes it through just passes it through. This keeps the hash-coverage
  surface narrow and makes the "memory + descriptions" pairing reversible
  if we ever want to evolve the convention.

## 2. Non-goals

- Not redesigning the action / memory-update path. Costanza's existing 10
  slots stay mutable on the same `setEntry` mechanism.
- Not changing `InvestmentManager` (immutable).
- Not changing `TheHumanFund` (immutable). All wiring stays the same: fund
  reads `agentMemory.stateHash()` once per epoch open to compute `memoryHash`.
- Not adding immutable-marker logic to the existing 10 slots. The first 10
  remain fully agent-writable.
- **Not splitting the memory-input data structure.** Everything that's in
  `memoryHash` is also returned by `getEntries()`. No separate
  `getInvestmentDescriptions()` method, no parallel data field. One list,
  one getter, one hash.

## 3. Current state (for reference)

```
            ┌────────────────────────────────────────────────┐
TheHumanFund│  _buildEpochSnapshot:                          │
            │      memoryHash = agentMemory.stateHash()      │
            │      investmentsHash = im.epochStateHash(...)  │
            └──┬──────────────────────────────┬──────────────┘
               │                              │
               ▼                              ▼
       AgentMemory v1                  InvestmentManager (immutable)
       (10 fixed slots)                ProtocolInfo includes `description`
       stateHash =                     epochStateHash hashes:
       keccak(t0,b0,...,t9,b9)             i, deposited, shares,
                                            currentValue, active,
                                            name, riskTier, apy
                                          ← description NOT included
```

Runner (`epoch_state.py`) reads memory entries and protocol metadata,
serializes into a state dict, hands to TEE. Enclave's `_hash_memory`
re-hashes the 10 slots, `_hash_investments` re-hashes the 8 fields. No
description anywhere on the runner→TEE path.

Prompt builder renders memory as "Recent Memories" section, investments as
"Investment Portfolio" section, no description rendered for either.

## 4. Proposed design

### 4.1 Contract (`src/AgentMemory.sol`) and `IAgentMemory` interface

**Interface change** (`src/interfaces/IAgentMemory.sol`):
```solidity
function getEntries() external view returns (MemoryEntry[] memory);
//                                                       ^^ was MemoryEntry[10]
```
Variable-length return. The other interface methods (`setEntry`, `getEntry`,
`stateHash`) are unchanged.

**Storage** (`src/AgentMemory.sol`):
```solidity
contract AgentMemory is IAgentMemory {
    uint256 public constant NUM_SLOTS = 10;
    uint256 public constant MAX_TITLE_LENGTH = 64;
    uint256 public constant MAX_BODY_LENGTH = 280;

    address public immutable fund;
    IInvestmentManager public immutable investmentManager;
    MemoryEntry[10] internal _entries;  // mutable slots only — descriptions
                                        // are derived live, not stored

    constructor(address _fund, address _im) {
        require(_fund != address(0) && _im != address(0), "zero addr");
        fund = _fund;
        investmentManager = IInvestmentManager(_im);
    }

    /// @notice Set a memory entry. Only fund can call; only slots 0..9.
    function setEntry(uint256 slot, string calldata title, string calldata body)
        external override
    {
        require(msg.sender == fund, "only fund");
        require(slot < NUM_SLOTS, "memory slot >= 10 is read-only");
        _entries[slot] = MemoryEntry({
            title: _truncate(title, MAX_TITLE_LENGTH),
            body:  _truncate(body,  MAX_BODY_LENGTH)
        });
        emit MemoryEntrySet(slot, _entries[slot].title, _entries[slot].body);
    }

    /// @notice Single-entry getter. Slots 0..9 read mutable storage;
    ///         slots 10..(10 + protocolCount - 1) read the corresponding
    ///         protocol's (name, description) live from IM.
    function getEntry(uint256 slot)
        external view override returns (MemoryEntry memory)
    {
        if (slot < NUM_SLOTS) return _entries[slot];
        uint256 protocolId = slot - NUM_SLOTS + 1;  // 1-indexed in IM
        require(protocolId <= investmentManager.protocolCount(), "invalid slot");
        (, string memory name, string memory desc, , , , ) =
            investmentManager.protocols(protocolId);
        return MemoryEntry({title: name, body: desc});
    }

    /// @notice All entries: 10 mutable slots followed by N protocol-description
    ///         slots in protocolId order (protocol 1 at index 10, protocol N
    ///         at index 10 + N - 1).
    function getEntries() external view override returns (MemoryEntry[] memory) {
        uint256 count = investmentManager.protocolCount();
        MemoryEntry[] memory out = new MemoryEntry[](NUM_SLOTS + count);
        for (uint256 i = 0; i < NUM_SLOTS; i++) {
            out[i] = _entries[i];
        }
        for (uint256 i = 1; i <= count; i++) {
            (, string memory name, string memory desc, , , , ) =
                investmentManager.protocols(i);
            out[NUM_SLOTS + i - 1] = MemoryEntry({title: name, body: desc});
        }
        return out;
    }

    /// @notice Deterministic hash of the FULL entry list as returned by
    ///         getEntries(). Loop-based so the schema absorbs protocol-count
    ///         growth without code changes.
    function stateHash() external view override returns (bytes32) {
        MemoryEntry[] memory entries = this.getEntries();
        bytes32 rolling = bytes32(0);
        for (uint256 i = 0; i < entries.length; i++) {
            rolling = keccak256(abi.encode(rolling, i, entries[i].title, entries[i].body));
        }
        return keccak256(abi.encode(rolling, entries.length));
    }
}
```

**Properties:**
- `getEntries()` is the canonical source of memory-input data.
- `stateHash()` is derived from `getEntries()` byte-for-byte (it calls
  `this.getEntries()` and hashes the result). Same source for data and hash.
- `getEntry(slot)` is consistent with `getEntries()[slot]` for any in-range
  slot. Verified by unit tests.

**Why the rolling per-item hash**: this is the established variable-length
cross-stack hashing idiom in the codebase. `InvestmentManager.epochStateHash`
(line 347-358) uses the same pattern over its protocol list, and the existing
Python mirror in `_hash_investments` handles it. We copy the pattern so the
existing Python mirror (`_hash_memory`) has a clean template — the new
behavior is a body-only rewrite, not a new function.

**Storage layout note**: descriptions are NOT stored in `_entries`. The
storage layout is identical to v1 (just 10 mutable slots). Descriptions live
in IM's storage; AgentMemory reads them live each call. Cheaper deploy, no
duplication of state, automatic propagation of `addProtocol` calls.

### 4.2 Cross-stack hash specification

Both sides MUST produce identical `bytes32` for the same `entries` list.

**Sol-side reference**: the `stateHash()` body in §4.1 is the canonical spec.

**Python-side mirror** (`prover/enclave/input_hash.py`) — keep the
function name `_hash_memory` (G6: semantic minimalism, this layer is just
"hash a list of memory entries"):

```python
def _hash_memory(entries: list[dict]) -> bytes:
    """Mirror of AgentMemory.stateHash().

    Generic over a variable-length list of memory entries. Each entry is
    {"title": str, "body": str}. Whatever semantic convention places things
    at particular indices (e.g., entries[0..9] = mutable slots,
    entries[10..] = protocol descriptions) is irrelevant here — this layer
    just hashes the list.

    Empty list (no agentMemory wired) → b'\\x00' * 32 (sentinel).
    """
    if not entries:
        return b"\x00" * 32
    rolling = bytes(32)
    for i, e in enumerate(entries):
        rolling = keccak(abi_encode(
            ["bytes32", "uint256", "string", "string"],
            [rolling, i, e["title"], e["body"]],
        ))
    return keccak(abi_encode(
        ["bytes32", "uint256"],
        [rolling, len(entries)],
    ))
```

**Critical**: must use `abi.encode` (NOT `abi.encodePacked`) to match the
Sol-side `keccak256(abi.encode(...))`. The 32-byte padding and dynamic-type
head/tail offsets must agree exactly.

**Positional security note**: the index `i` is included in each item's
inner hash. A malicious runner reordering entries would change every
subsequent rolling hash → mismatch → submit reverts. The
"look-up-by-position-not-by-id" rule (CLAUDE.md, PR #44 lesson) extends
naturally to whatever consumer reads `entries[10 + idx]` for descriptions
— must be positional, never title-string matching. The title is
informational rendering, not a key.

Coverage check: extend `test/CrossStackHash.t.sol` to call `_hash_memory`
via FFI on a fixture with N protocols registered and assert byte-equality
with `agentMemory.stateHash()`.

### 4.3 Enclave changes

**`prover/enclave/input_hash.py`**:
- `_hash_memory` keeps its name and its `state["memories"]` source field.
  Body changes from "unroll 10 entries via `abi.encode(t0, b0, ..., t9, b9)`"
  to "loop over variable-length list with rolling index-hash" per §4.2.
- No new state field, no second argument, no rename. This layer is
  semantically generic per G6.
- `compute_input_hash` is untouched — it still calls
  `_hash_memory(state["memories"])`.

**`prover/enclave/prompt_builder.py`** — this is one of the TWO files
that knows about the description convention (the other is `index.html`):
- "Recent Memories" section reads `state["memories"][:10]` — same 10-slot
  rendering as today. Agent sees no change in this section.
- "Investment Portfolio" section: for each investment at position `idx`
  (0-indexed in the investments list, which mirrors protocol IDs 1..N),
  inline the description from `state["memories"][10 + idx]` into the row.
  Proposed format:

  ```
  Investment Portfolio
  ────────────────────
  (room = how much MORE you can invest in this protocol this epoch...)

    #1 Aave V3 USDC [LOW, ~5% APY]: 0.014825 ETH deposited -> $X (...)  |  room: ...
       Swap ETH to USDC, lend on Aave. Higher APY but you lose if ETH rises.

    #6 Costanza Token [HIGH, ~0% APY]: no position  |  room: ...
       Your own memecoin, $COSTANZA. Speculative — buy/sell via deposit/
       withdraw; trading fees from other holders accrue to the fund and
       lower your per-token cost basis. The contract won't sell below cost
       basis, so a position can be locked during drawdowns. Lifetime cap: 5 ETH.
  ```

  Description rendered indented under each row. Same format whether the
  agent has a position or not.

- **Lookup rule** (hash-coverage-critical): the description for
  `investments[idx]` is `state["memories"][10 + idx]`. NEVER look up by
  title-string match. Position is canonical; the title in the entry is
  rendering context only, never a key.

**`prover/enclave/test_hash_coverage.py`**:
- `state["memories"]` is hash-covered as before (no name change, just
  variable length).
- Add an assertion that the prompt builder's investment-row code reads
  `memories[10 + idx]` by position, never by `.title` matching. Same
  static-walker rule as `investments[idx]` and `nonprofits[idx]` from
  PR #44's lesson.

### 4.4 Runner changes (`prover/client/epoch_state.py`)

**Exactly one change: delete the pad/truncate-to-10 block** (lines
283-285 today):

```python
# DELETE these three lines so the list can grow past 10:
while len(normalized) < 10:
    normalized.append({"title": "", "body": ""})
state["memories"] = normalized[:10]

# REPLACED by:
state["memories"] = normalized
```

State field name `memories` stays. No new fetch, no new state key, no new
logic. The runner becomes oblivious to whether `getEntries()` returned 10
entries (v1) or 10+N entries (v2) — it just passes whatever it got. Per G6.

**No call to `IM.protocols(i)` is added.** AgentMemory is the single source
of truth — `getEntries()` already includes the IM-derived descriptions in
positions 10+.

The all-empty fallback at line 264 (`state["memories"] = [{"title": "",
"body": ""} for _ in range(10)]`) is kept as-is for the "agentMemory not
wired" defensive case. On mainnet this branch never fires; on testnet /
local-dev fixtures without a memory contract it gives the TEE a 10-empty
list to hash.

### 4.5 Frontend (`index.html`)

`getEntries()` now returns variable length. Where the dashboard renders
memory slots:

```javascript
// Before:
const entries = await agentMemory.getEntries();  // length 10
entries.forEach((e, i) => renderSlot(i, e));

// After:
const entries = await agentMemory.getEntries();  // length 10 + N
entries.slice(0, 10).forEach((e, i) => renderSlot(i, e));
```

3 lines of JS. The descriptions at positions 10+ are NOT rendered on the
dashboard's memory panel (they're already visible in the investments table).

## 5. Migration ceremony

**Pre-flight:**

- Confirm `frozenFlags & FREEZE_MEMORY_WIRING == 0` (we just checked: 0).
- Confirm `TheHumanFund.owner()` is `humanfund-deploy`.
- Pause the Hetzner cron runner: `crontab -u humanfund -r`.
- Wait for any in-flight auction to settle (verify `am.currentPhase()` is
  not `EXECUTION` for the current epoch — safest to do this near an epoch
  boundary).

**Deploy:**

```bash
# Deploy AgentMemory, constructor args = (fund, im)
forge create src/AgentMemory.sol:AgentMemory \
    --constructor-args \
        0x678dC1756b123168f23a698374C000019e38318c \
        0x2fab8aE91B9EB3BaB18531594B20e0e086661892 \
    --rpc-url https://mainnet.base.org \
    --account humanfund-deploy \
    --verify
```

Record `AGENT_MEMORY=0x...`.

**Re-seed mutable slots 1-8** to preserve Costanza's existing memory:

```bash
# Read current v1 entries
WV_V1=0x8de1BbFA2200A9104e3C08a00F96C2c8Ee073346
# ...for each non-empty slot, capture (slot, title, body)

# Seed v2 with the same contents BEFORE wiring fund.setAgentMemory
# IMPORTANT: must call via fund.seedMemory after setAgentMemory,
# because v2.setEntry is gated on `msg.sender == fund`. So order is:
# 1) setAgentMemory(v2) — repoint fund.agentMemory
# 2) seedMemory(...)    — fund calls v2.setEntry(...) for each old slot
```

**Wire fund:**

```bash
cast send 0x678dC1756b123168f23a698374C000019e38318c \
    "setAgentMemory(address)" $AGENT_MEMORY \
    --account humanfund-deploy
```

After this call lands, the fund reads `memoryHash` from V2. The next
epoch's snapshot uses V2's stateHash (which incorporates descriptions).

**Re-seed:**

```bash
cast send 0x678dC1756b123168f23a698374C000019e38318c \
    "seedMemory(uint256[],string[],string[])" \
    "[1,2,3,4,5,6,7,8]" \
    '[<8 titles from v1>]' \
    '[<8 bodies from v1>]' \
    --account humanfund-deploy
```

**TEE image rebuild:**

Build a new dm-verity image with the updated `prover/enclave/*.py` files.
Register the new platform key on-chain (`register_image.py`). Update the
Hetzner runner's `GCP_IMAGE` env var to point at the new image.

**Resume runner:**

```bash
# Restore cron with the new GCP_IMAGE env baked into .env
crontab -u humanfund - <<< "...cron line..."
```

**Verify on first epoch with v2 active:**
- `cast call $AGENT_MEMORY "stateHash()(bytes32)"` returns a fresh hash
- TEE inference succeeds; submit lands without `ProofFailed`
- Prompt's "Investment Context" section includes Costanza Token's
  description (verify via journalctl + prompt diff)

## 6. Testing plan

**Unit tests** (`test/AgentMemory.t.sol`):
- `setEntry` works for slots 0..9, identical to v1
- `setEntry` reverts for slot ≥ 10
- `stateHash` is deterministic — same state → same hash
- `stateHash` changes when any mutable slot OR any IM description changes
- `stateHash` matches a hand-computed expected value for a known fixture

**Cross-stack hash test** (`test/CrossStackHash.t.sol`):
- Extend the existing fixture to include investment descriptions
- Call Python-side `_hash_memory(...)` via FFI
- Assert `agentMemory.stateHash() == python_result`

**Enclave hash-coverage test** (`prover/enclave/test_hash_coverage.py`):
- `investment_descriptions` field is in the covered-fields list
- Each consumer using `state["investment_descriptions"]` reads by index

**End-to-end mainnet-fork rehearsal**:
- Deploy v2 against a Base mainnet fork
- Call `setAgentMemory` from forked owner
- Re-seed slots 1-8
- Have a runner client do a full epoch loop (commit → reveal → execute)
- Confirm `submitAuctionResult` succeeds
- Inspect the prompt the TEE built — descriptions present

## 7. Risks & rollback

| Risk | Mitigation |
|---|---|
| Sol/Python hash mismatch | Cross-stack test must pass before any deploy |
| Mid-epoch swap → TEE proof mismatch | Pause runner during ceremony |
| Re-seed loses an entry | Verify each slot post-reseed via `cast call agentMemory.getEntry(i)` |
| New TEE image fails to boot | Test image standalone before registering platform key |
| Costanza confused by new prompt section | "Investment context" heading + "not your memory" subline; revert is just re-pointing `setAgentMemory` to v1 |

**Rollback:** if anything breaks post-deploy, the owner can call
`fund.setAgentMemory(v1_address)` to revert. v1 is still deployed and
holds its original entries (the v2 deploy didn't touch v1). One tx.

## 8. Open questions

- **Q1: gas cost of `stateHash`** with 10 mutable slot reads + N IM external
  reads + keccaks. For N=6 today, max=21: well under any practical cap.
  Worth measuring to confirm but not a design constraint.
- **Q2: are deactivated protocols' descriptions included?** Yes — `IM.protocols(i)`
  returns description regardless of `active`. The agent might want context
  about "deactivated" adapters for historical reasoning. Open to changing if
  preference is "active only."
- **Q3: rendering format for description in investment row.** Current
  proposal in §4.3: indented continuation line under the protocol's main
  data row. Alternatives: trailing fragment on same line (terser but
  cluttered); separate sub-block after the portfolio listing. Keep simple
  until we see how it reads in actual prompts.

## 9. Files touched (preview)

```
src/AgentMemory.sol                          REWRITE  (in-place; v1 bytecode is
                                                       preserved on-chain at 0x8de1Bb…)
src/interfaces/IAgentMemory.sol              EDIT     (getEntries return type
                                                       MemoryEntry[10] → MemoryEntry[])
test/AgentMemory.t.sol                       REWRITE  (in-place; full rewrite for
                                                       new behavior)
test/CrossStackHash.t.sol                    EXTEND   (variable-length memory fixture)
prover/enclave/input_hash.py                 EDIT     (_hash_memory: variable-length
                                                       loop body, same name + signature)
prover/enclave/prompt_builder.py             EDIT     (inline descriptions in invest rows;
                                                       only file with the convention)
prover/enclave/test_hash_coverage.py         EXTEND   (positional-lookup assertion
                                                       for memories[10+idx])
prover/client/epoch_state.py                 EDIT     (delete the pad/truncate-to-10
                                                       block; ~4 lines)
index.html                                   EDIT     (.slice(0, 10) when rendering
                                                       memory; only frontend with the convention)
deploy/mainnet/DeployAgentMemory.s.sol       NEW
deploy/mainnet/agentmemory_runbook.md        NEW
docs/AGENT_MEMORY_V2_DESIGN.md               THIS FILE

src/InvestmentManager.sol                    unchanged (immutable on mainnet)
src/TheHumanFund.sol                         unchanged (immutable on mainnet)
```

**Files knowing about the description convention** (per G6, exactly two):
- `prover/enclave/prompt_builder.py`
- `index.html`

Everything else operates on a generic list-of-(title,body) abstraction.
