# Rename: worldview → memory

**Branch:** `rename-worldview-to-memory` (off `main` @ 181986d)
**Worktree:** `.claude/worktrees/rename-to-memory`
**Scope:** mechanical rename only — no semantic / functional changes.

## Why

- "Memory" is legible to a public audience without crypto/AI jargon. "Worldview" reads as ideology.
- The model writes more naturally about "checking my memory" than "checking my worldview slot 3".
- Now-or-never: nothing is deployed to mainnet that depends on the current names.

## Name map

### Concepts

| Old | New | Notes |
|---|---|---|
| `worldview` (collection) | `memory` | the 10-slot store as a whole |
| `WorldView` (Solidity contract) | `AgentMemory` | more specific than just `Memory` |
| `IWorldView` (Solidity interface) | `IAgentMemory` | |
| `WorldViewEntry` / `Entry` (struct) | `MemoryEntry` (struct) | per-slot `{title, body}` |
| `PolicyUpdate` (struct, sidecar) | `MemoryUpdate` (struct) | per-update `{slot, title, body}` |
| `policy` / `policies` | (drop) | legacy v0 term — replace with "memory" or "entry" depending on context |
| `guiding_polic*` | `memor*` | e.g. `guidingPolicies` → `memorySlots` if it appears |

### Names that do NOT change

| Field | Why keep |
|---|---|
| `slot` (the 0–9 index) | already the right word |
| `title` | clear |
| `body` | clear |
| All other contract methods | only worldview-related ones change |

### JSON sidecar field

In the action JSON the model emits, the top-level sidecar key flips:

```diff
- {"action": "donate", "params": {...}, "worldview": [{"slot": 3, ...}, ...]}
+ {"action": "donate", "params": {...}, "memory":    [{"slot": 3, ...}, ...]}
```

- GBNF grammar: rename `worldview-kv` / `worldview-body` / `worldview-update`
  productions to `memory-kv` / `memory-body` / `memory-update`, and the
  literal `"\"worldview\":"` → `"\"memory\":"`.
- All Python `action_json.get("worldview")` → `.get("memory")`.
- All Solidity-side comments referring to the sidecar.

### Method / event names (Solidity)

| Old | New |
|---|---|
| `WorldView.setEntry` (or whatever `setSlot` is called) | `AgentMemory.setEntry` (no change if signature is generic) |
| Whatever `setWorldView*` / `getWorldView*` exists | `setMemory*` / `getMemory*` |
| `WorldViewSet` event | `MemoryEntrySet` |
| `IWorldView.PolicyUpdate` | `IAgentMemory.MemoryUpdate` |

(I'll grep-confirm the actual method names live and update this map before
fanning out.)

### Prompt section headers

| Old | New |
|---|---|
| `# F. YOUR WORLDVIEW (10 slots)` | `# F. YOUR MEMORY (10 slots)` |
| `=== YOUR WORLDVIEW ===` | `=== YOUR MEMORY ===` |
| "worldview update" / "worldview sidecar" | "memory update" / "memory sidecar" |
| "guiding policy" / "guiding policies" | "memory" |

## Hash invariance

The output-hash preimage is the **values** packed via `abi.encode(uint8 slot, string title, string body)`. JSON key names are NOT in the hash preimage — they're just dict accessors in Python and struct field accessors in Solidity. Renaming `worldview` → `memory` (or any field name) does NOT change the on-chain hash, AS LONG AS:

- Both sides keep the same `(uint8, string, string)` packing
- Both sides extract the same values from the JSON

We're free to rename `slot`/`title`/`body` too, but keeping them avoids unnecessary churn and they're already good names. **Recommendation: leave them alone.**

The user has confirmed (2026-04-22) that we have license to change hash-relevant code as long as it changes consistently across stacks, so this constraint is a guideline rather than a hard ceiling.

## File inventory (~50 files)

### Hash-relevant (touch with extra care)

```
src/TheHumanFund.sol                          — hashSubmittedUpdates etc
src/WorldView.sol                             — contract being renamed
src/interfaces/IWorldView.sol                 — interface being renamed
prover/enclave/attestation.py                 — _hash_submitted_updates, compute_report_data
prover/enclave/input_hash.py                  — _abi_encode helper, _hash_worldview etc
prover/enclave/action_encoder.py              — sidecar key extraction
prover/client/epoch_state.py                  — chain reads
test/CrossStackHash.t.sol                     — cross-stack parity
test/WorldView.t.sol                          — contract behavior
prover/enclave/test_hash_coverage.py          — coverage analyzer
scripts/compute_output_hash.py                — Python hash mirror (FFI'd from Foundry)
```

### Solidity (no hash change, just renames)

```
src/TheHumanFund.sol                          — submitAuctionResult sidecar param
src/WorldView.sol                             — file rename → src/AgentMemory.sol
src/interfaces/IWorldView.sol                 — file rename → src/interfaces/IAgentMemory.sol
test/TheHumanFund.t.sol
test/TheHumanFundAuction.t.sol
test/SystemInvariants.t.sol
test/WorldView.t.sol                          — file rename → test/AgentMemory.t.sol
test/MainnetFork.t.sol
test/helpers/EpochTest.sol
deploy/mainnet/Deploy.s.sol
deploy/testnet/DeployTestnet.s.sol
deploy/mainnet/preflight.sh
deploy/mainnet/deploy_guide.sh
deploy/testnet/e2e.py
deploy/testnet/gcp_persistent.py
```

### Python prover/enclave (no hash change)

```
prover/enclave/enclave_runner.py
prover/enclave/inference.py                   — docstring + comments only
prover/enclave/prompt_builder.py              — section headers + render_worldview() function name
prover/enclave/action_grammar.gbnf            — JSON key change
prover/enclave/test_inference.py
prover/enclave/test_input_hash.py
prover/enclave/test_output_coverage.py
prover/enclave/attestation.py
prover/scripts/gcp/e2e_test.py
prover/scripts/gcp/test_v12.py
prover/scripts/gcp/build_base_image.sh
prover/scripts/gcp/build_full_dmverity_image.sh
prover/scripts/gcp/register_image.py
prover/client/client.py
prover/client/auction.py
prover/client/epoch_state.py
prover/client/tee_clients/gcp.py
scripts/simulate.py
scripts/recover_submit.py
```

### Frontend

```
index.html                                    — UI labels + JS variable names
docs/call_graph.html
```

### Prompts (I'll do these myself)

```
prover/prompts/system.txt                     — section §C output format example, voice nudges
prover/prompts/character_draft.md
prover/prompts/voice_anchors.txt              — likely zero hits, but verify
```

### Docs (I'll do WHITEPAPER, subagents do the rest mechanically)

```
README.md
CLAUDE.md                                     — project overview, examples
WHITEPAPER.md                                 — formal spec
SECURITY_AUDIT.md
```

## Verification gates

After each subagent reports done, run from the rename worktree:

```bash
forge build                                                              # compile
forge test                                                               # full Solidity suite
forge test --match-path test/CrossStackHash.t.sol                        # hash parity
/path/to/.venv/bin/python -m pytest prover/enclave/                      # 109+ Python tests
/path/to/.venv/bin/python -m pytest prover/enclave/test_hash_coverage.py # static coverage
```

All gates must be green before we proceed to behavior-test. **Do NOT skip any.**

After verification: copy the rename-worktree files into the `behavior-test` worktree and re-run `scripts/test_worldview_behavior.py` against H100 to confirm model behavior is unchanged (or improved by the more legible name in prompts).

## Delegation plan

| Agent | Scope | Verification |
|---|---|---|
| **Sonnet #1** | Solidity rename: all `*.sol`, `deploy/`, `test/`. Move `WorldView.sol` → `AgentMemory.sol`, `IWorldView.sol` → `IAgentMemory.sol`, `WorldView.t.sol` → `AgentMemory.t.sol`. Update all imports + struct refs. | `forge build && forge test` |
| **Sonnet #2** | Python rename: `prover/enclave/*.py`, `prover/client/*.py`, `prover/scripts/gcp/*.py`, `scripts/*.py`, `deploy/testnet/*.py`. JSON sidecar key + GBNF grammar. | `pytest prover/enclave/` |
| **Haiku** | `index.html`, `docs/call_graph.html`, mechanical README/CLAUDE/SECURITY_AUDIT string substitution. | manual review of HTML diff |
| **Me (Opus)** | `prover/prompts/system.txt`, `prover/prompts/character_draft.md`, `prover/prompts/voice_anchors.txt` (if affected), prompt section headers in `prompt_builder.py`, `WHITEPAPER.md`, full integration verification. | All gates above |

After all subagent PRs land in this worktree, I do the cross-stack hash test + behavior test as the final integration check.
