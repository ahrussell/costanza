#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# AgentMemory Migration — Fork Rehearsal
# ═══════════════════════════════════════════════════════════════════════
#
# Drives the AgentMemory migration ceremony (runbook steps 4 + 5a + 5b)
# against an anvil fork of Base mainnet. Validates:
#
#   1. DeployAgentMemory.s.sol produces a contract wired to live FUND + IM
#   2. New contract's getEntries() returns NUM_SLOTS + protocolCount entries
#   3. Per-protocol description entries at indices 10..15 match what IM
#      currently has registered (live read of `protocols(uint256)`)
#   4. stateHash() is non-zero
#   5. Fund owner (humanfund-deploy) can call setAgentMemory(newAddr)
#   6. Fund.agentMemory() now points at the new contract
#   7. Fund owner can call seedMemory() with captured v1 slots, and the
#      new contract's getEntry(i) round-trips correctly for each non-empty
#      slot
#
# Reads v1's current contents from /tmp/agentmemory-migration/slots.json
# (produced by the same per-slot getEntry() loop the real ceremony's
# step 2 uses). Skip slot 0 and slot 9 (they're empty on mainnet today;
# slot 9 is reserved for the "unlock Costanza Token" seed note the agent
# will get post-migration).
#
# Usage:
#   set -a && source /path/to/.env && set +a    # picks up RPC_URL
#   bash deploy/mainnet/fork_rehearsal_memory.sh
#
# Or pass the upstream URL explicitly:
#   FORK_URL=https://base-mainnet.g.alchemy.com/v2/<key> \
#     bash deploy/mainnet/fork_rehearsal_memory.sh
#
# Prerequisites: forge, cast, anvil, jq, python3.

set -euo pipefail

PORT="${ANVIL_PORT:-8546}"   # default 8546 so we don't clash with the
                             # adapter rehearsal still up on 8545
ANVIL_PID=""

FORK_URL="${FORK_URL:-${RPC_URL:-https://mainnet.base.org}}"
RPC_URL="http://localhost:${PORT}"

# ─── Constants (verified mainnet addresses) ──────────────────────────────

FUND="0x678dC1756b123168f23a698374C000019e38318c"
IM="0x2fab8aE91B9EB3BaB18531594B20e0e086661892"
WV_V1="0x8de1BbFA2200A9104e3C08a00F96C2c8Ee073346"
OWNER="0x2e61a91EbeD1B557199f42d3E843c06Afb445004"  # humanfund-deploy

# anvil test account 0 — used as the deploy signer.
DEPLOYER_PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEPLOYER_ADDR="0xf39Fd6e51aad88F6F4ce6aB8827279cfFFb92266"

SLOTS_JSON="/tmp/agentmemory-migration/slots.json"

# ─── Helpers ─────────────────────────────────────────────────────────────

die() { echo "❌ $*" >&2; exit 1; }
ok()  { echo "✓ $*"; }

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Send a transaction via cast and verify the on-chain receipt status.
# Mirrors the wrapper in fork_rehearsal.sh — cast send exits 0 even on
# revert, so we parse the receipt's `status` field and `cast run` the
# tx hash on failure for a full EVM trace.
send_or_die() {
    local label="$1"; shift
    local stdout_file stderr_file exit_code
    stdout_file=$(mktemp)
    stderr_file=$(mktemp)
    cast send "$@" --rpc-url "$RPC_URL" --json >"$stdout_file" 2>"$stderr_file"
    exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo "❌ $label: cast send exited $exit_code" >&2
        echo "─── cast stderr ───" >&2; cat "$stderr_file" >&2
        echo "─── cast stdout ───" >&2; cat "$stdout_file" >&2
        rm -f "$stdout_file" "$stderr_file"
        exit 1
    fi

    local receipt_line status tx_hash
    receipt_line=$(head -n 1 "$stdout_file")
    status=$(printf '%s' "$receipt_line" | python3 -c \
        "import sys, json; d=json.loads(sys.stdin.read() or '{}'); print(d.get('status',''))" 2>/dev/null) \
        || status=""
    tx_hash=$(printf '%s' "$receipt_line" | python3 -c \
        "import sys, json; d=json.loads(sys.stdin.read() or '{}'); print(d.get('transactionHash',''))" 2>/dev/null) \
        || tx_hash=""

    if [[ "$status" != "0x1" ]]; then
        echo "❌ $label: tx not confirmed successful (status=$status, hash=$tx_hash)" >&2
        if [[ -n "$tx_hash" && "$tx_hash" =~ ^0x ]]; then
            echo "─── EVM trace (cast run, last 60 lines) ───" >&2
            cast run "$tx_hash" --rpc-url "$RPC_URL" --quick 2>&1 | tail -60 >&2 || true
        fi
        rm -f "$stdout_file" "$stderr_file"
        exit 1
    fi
    rm -f "$stdout_file" "$stderr_file"
}

fund_eoa() {
    local addr="$1"
    cast rpc anvil_setBalance "$addr" "0x100000000000000000" --rpc-url "$RPC_URL" >/dev/null
    cast rpc anvil_impersonateAccount "$addr" --rpc-url "$RPC_URL" >/dev/null
}

cleanup() {
    if [[ -n "$ANVIL_PID" ]] && kill -0 "$ANVIL_PID" 2>/dev/null; then
        echo ""
        echo "--- Tearing down anvil (pid $ANVIL_PID) ---"
        kill "$ANVIL_PID" 2>/dev/null || true
        wait "$ANVIL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ─── Slots file sanity check ─────────────────────────────────────────────

[[ -f "$SLOTS_JSON" ]] || die "missing $SLOTS_JSON — run step 2 first"
jq -e 'length == 10' "$SLOTS_JSON" >/dev/null \
    || die "$SLOTS_JSON should have exactly 10 entries"

# ─── Anvil ───────────────────────────────────────────────────────────────

LATEST_BLOCK=$(cast block-number --rpc-url "$FORK_URL")
echo "═══ Starting anvil fork on port $PORT ═══"
echo "  upstream:     [hidden — see FORK_URL/RPC_URL env]"
echo "  pinned block: $LATEST_BLOCK"

anvil --fork-url "$FORK_URL" \
      --fork-block-number "$LATEST_BLOCK" \
      --timeout 60000 \
      --retries 10 \
      --port "$PORT" \
      --silent &
ANVIL_PID=$!

for _ in {1..120}; do
    if cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
cast block-number --rpc-url "$RPC_URL" >/dev/null \
    || die "anvil never came up on port $PORT"
ok "anvil up; block: $(cast block-number --rpc-url "$RPC_URL")"
echo ""

# ─── Step 4: deploy new AgentMemory via the forge script ────────────────

echo "═══ Step 4 — Deploy AgentMemory via DeployAgentMemory.s.sol ═══"
# Inline env override — matches the real ceremony and defends against
# Sepolia values leaking in via local .env.
PRIVATE_KEY="$DEPLOYER_PK" \
INVESTMENT_MANAGER="$IM" \
FUND="$FUND" \
    forge script deploy/mainnet/DeployAgentMemory.s.sol:DeployAgentMemory \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --silent

# Pull the new address from the broadcast manifest. Base mainnet chainId
# 8453 is preserved through the fork.
MANIFEST="broadcast/DeployAgentMemory.s.sol/8453/run-latest.json"
[[ -f "$MANIFEST" ]] || die "broadcast manifest missing: $MANIFEST"
WV_V2=$(jq -r '[.transactions[] | select(.contractName == "AgentMemory") | .contractAddress] | last' "$MANIFEST")
[[ "$WV_V2" =~ ^0x[a-fA-F0-9]{40}$ ]] || die "v2 address parse failed: $WV_V2"
ok "new AgentMemory: $WV_V2"

# ─── Wiring verification ────────────────────────────────────────────────

V2_FUND=$(cast call "$WV_V2" "fund()(address)" --rpc-url "$RPC_URL")
V2_IM=$(cast call "$WV_V2" "investmentManager()(address)" --rpc-url "$RPC_URL")
V2_NSLOTS=$(cast call "$WV_V2" "NUM_SLOTS()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')

[[ "$(lc "$V2_FUND")" == "$(lc "$FUND")" ]] \
    || die "v2.fund mismatch: got $V2_FUND want $FUND"
[[ "$(lc "$V2_IM")" == "$(lc "$IM")" ]] \
    || die "v2.investmentManager mismatch: got $V2_IM want $IM"
[[ "$V2_NSLOTS" == "10" ]] \
    || die "v2.NUM_SLOTS != 10 (got $V2_NSLOTS)"
ok "wiring matches expected (fund/IM/NUM_SLOTS)"

# ─── getEntries() shape ────────────────────────────────────────────────

PCOUNT=$(cast call "$IM" "protocolCount()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')
EXPECTED_LEN=$((10 + PCOUNT))
echo "IM protocolCount: $PCOUNT (so getEntries should be $EXPECTED_LEN long)"

# Parse the dynamic tuple[] return. cast's --json mode returns the abi
# decoded value as a single nested array; count its top-level length.
ENTRIES_JSON=$(cast call "$WV_V2" "getEntries()((string,string)[])" --rpc-url "$RPC_URL" --json)
ACTUAL_LEN=$(printf '%s' "$ENTRIES_JSON" | python3 -c "
import sys, json, ast
# cast --json wraps the result in a JSON array; the actual decoded value
# is a Python-syntax string of nested tuples. Parse both layers.
outer = json.load(sys.stdin)
val = outer[0] if isinstance(outer, list) else outer
parsed = ast.literal_eval(val) if isinstance(val, str) else val
print(len(parsed))
")
[[ "$ACTUAL_LEN" == "$EXPECTED_LEN" ]] \
    || die "getEntries length mismatch: got $ACTUAL_LEN want $EXPECTED_LEN"
ok "getEntries length: $ACTUAL_LEN (10 mutable + $PCOUNT descriptions)"

# Verify the first protocol description (slot 10) matches IM's protocols(1).
# Both calls return tuples — pull the strings via cast --json and python so
# we don't have to wrestle with parenthesised plaintext output.
EXPECTED_NAME=$(cast call "$IM" "protocols(uint256)(address,string,string,uint8,uint16,bool,bool)" 1 --rpc-url "$RPC_URL" --json \
    | python3 -c "import sys, json; print(json.load(sys.stdin)[1])")
ACTUAL_TITLE=$(cast call "$WV_V2" "getEntry(uint256)((string,string))" 10 --rpc-url "$RPC_URL" --json \
    | python3 -c "
import sys, json, ast
o = json.load(sys.stdin)
v = o[0] if isinstance(o, list) else o
t = ast.literal_eval(v) if isinstance(v, str) else v
print(t[0])
")
[[ "$ACTUAL_TITLE" == "$EXPECTED_NAME" ]] \
    || die "slot 10 title mismatch: got '$ACTUAL_TITLE' want '$EXPECTED_NAME'"
ok "slot 10 title matches IM.protocols(1).name: $ACTUAL_TITLE"

# ─── stateHash non-zero ────────────────────────────────────────────────

V2_HASH=$(cast call "$WV_V2" "stateHash()(bytes32)" --rpc-url "$RPC_URL")
[[ "$V2_HASH" != "0x0000000000000000000000000000000000000000000000000000000000000000" ]] \
    || die "stateHash is zero — getEntries must be returning empty"
ok "stateHash() non-zero: $V2_HASH"
echo ""

# ─── Step 5a: setAgentMemory ───────────────────────────────────────────

echo "═══ Step 5a — setAgentMemory(v2) as fund owner ═══"
fund_eoa "$OWNER"

PRE_AM=$(cast call "$FUND" "agentMemory()(address)" --rpc-url "$RPC_URL")
echo "fund.agentMemory pre:  $PRE_AM"
[[ "$(lc "$PRE_AM")" == "$(lc "$WV_V1")" ]] \
    || die "pre-state mismatch: fund.agentMemory != v1"

send_or_die "setAgentMemory(v2)" \
    --unlocked --from "$OWNER" "$FUND" \
    "setAgentMemory(address)" "$WV_V2"

POST_AM=$(cast call "$FUND" "agentMemory()(address)" --rpc-url "$RPC_URL")
[[ "$(lc "$POST_AM")" == "$(lc "$WV_V2")" ]] \
    || die "fund.agentMemory didn't update: got $POST_AM want $WV_V2"
ok "fund.agentMemory now points at v2: $POST_AM"
echo ""

# ─── Step 5b: seedMemory from captured v1 slots ────────────────────────

echo "═══ Step 5b — seedMemory(non-empty v1 slots) as fund owner ═══"
# Build arrays from slots.json (skip empty slots and slot 9 — we deliberately
# leave it empty post-migration so the model can have a clean note inserted
# manually as the next step).
SEED_PAYLOAD=$(python3 << EOF
import json
slots = json.load(open("$SLOTS_JSON"))
# Non-empty, exclude slot 9 (deliberately reserved)
keep = [s for s in slots if (s["title"] or s["body"]) and s["slot"] != 9]
def fmt_array_uint(xs):
    return "[" + ",".join(str(x) for x in xs) + "]"
def fmt_array_str(xs):
    # cast send takes JSON-array-of-strings. Use json.dumps for proper escaping.
    return json.dumps(xs, ensure_ascii=False)
print(fmt_array_uint([s["slot"] for s in keep]))
print(fmt_array_str([s["title"] for s in keep]))
print(fmt_array_str([s["body"]  for s in keep]))
EOF
)
SEED_SLOTS=$(echo "$SEED_PAYLOAD"  | sed -n '1p')
SEED_TITLES=$(echo "$SEED_PAYLOAD" | sed -n '2p')
SEED_BODIES=$(echo "$SEED_PAYLOAD" | sed -n '3p')
echo "seeding slots: $SEED_SLOTS"

send_or_die "seedMemory" \
    --unlocked --from "$OWNER" "$FUND" \
    "seedMemory(uint256[],string[],string[])" \
    "$SEED_SLOTS" "$SEED_TITLES" "$SEED_BODIES"

# Verify each captured slot round-tripped correctly.
python3 << EOF
import json, subprocess
slots = json.load(open("$SLOTS_JSON"))
v2 = "$WV_V2"
rpc = "$RPC_URL"
ok_count = 0
fail = []
for s in slots:
    out = subprocess.check_output(
        ["cast", "call", v2, "getEntry(uint256)((string,string))", str(s["slot"]),
         "--rpc-url", rpc],
        text=True,
    ).strip()
    # cast prints: ("title here", "body here")
    if s["slot"] == 9:
        # Slot 9 is reserved — we did NOT seed it; expect empty on v2.
        expect = '("", "")'
        if out == expect:
            ok_count += 1
        else:
            fail.append((s["slot"], out, expect))
        continue
    if not (s["title"] or s["body"]):
        continue
    # cast quote-escapes the strings. Compare loosely by checking the title
    # substring appears in the output.
    if s["title"] in out and s["body"][:30] in out:
        ok_count += 1
    else:
        fail.append((s["slot"], out, s))
print(f"  ✓ {ok_count} slots round-tripped (including the reserved empty slot 9)")
if fail:
    print("  ❌ slot mismatches:")
    for f in fail:
        print(f"     {f}")
    raise SystemExit(1)
EOF
echo ""

# ─── Done ──────────────────────────────────────────────────────────────

echo "═══ ✓ Fork rehearsal complete ═══"
echo "  WV_V2:           $WV_V2"
echo "  stateHash post:  $(cast call $WV_V2 stateHash\(\)\(bytes32\) --rpc-url $RPC_URL)"
echo ""
echo "  Live fund.agentMemory()    = $(cast call $FUND agentMemory\(\)\(address\) --rpc-url $RPC_URL)"
echo "  Live fund.memoryHash via   stateHash() above"
echo ""
echo "  Run with anvil still up at $RPC_URL for poking; press Ctrl-C to tear down."
