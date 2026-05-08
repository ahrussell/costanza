#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# CostanzaTokenAdapter — Fork Rehearsal
# ═══════════════════════════════════════════════════════════════════════
#
# Drives the full mainnet deploy ceremony against an anvil fork of Base,
# end to end. Catches any wiring / addressing / signer-setup issue before
# real ETH is signed.
#
# Two phases, each independently runnable:
#
#   Phase A — fresh deploy:
#     deploy v1 → IM admin registers → Doppler beneficiary handover → deposit
#
#   Phase B — migration to v2:
#     deploy v2 with v1's accumulators → v1.migrate(v2) → IM admin re-points
#
# Run both with default invocation. Pass --skip-v2 to do only Phase A.
#
# Uses anvil's well-known test account 0 (no password prompt) as the
# deployer. The actual mainnet ceremony will use --account humanfund-deploy
# instead — the on-chain effects are identical.
#
# Note on speed: forking from the public Base RPC means each on-demand
# state read goes upstream. V4 swap simulation touches a lot of slots,
# so a deposit can take 1-2 minutes against the rate-limited public RPC.
# Strongly recommended: point at Alchemy or another paid RPC via either:
#
#     export FORK_URL=https://base-mainnet.g.alchemy.com/v2/<key>
#
# or by sourcing the project's .env (the script picks up RPC_URL as a
# fallback):
#
#     set -a && source /path/to/.env && set +a
#     bash deploy/mainnet/fork_rehearsal.sh
#
# The script also pins to a specific block (faster, more deterministic)
# and passes --gas-limit on deposits / migrates to skip estimation.
#
# Prerequisites: forge, cast, anvil, jq.

set -euo pipefail

PORT="${ANVIL_PORT:-8545}"
ANVIL_PID=""
SKIP_V2=0

# Upstream RPC for the fork. Precedence:
#   FORK_URL env (explicit override, highest priority) >
#   RPC_URL env (likely Alchemy if .env was sourced) >
#   public Base RPC (rate-limited; works but slow)
FORK_URL="${FORK_URL:-${RPC_URL:-https://mainnet.base.org}}"

# Cast's RPC pointer is the local anvil — never the upstream.
RPC_URL="http://localhost:${PORT}"

for arg in "$@"; do
    case "$arg" in
        --skip-v2) SKIP_V2=1 ;;
        --help|-h)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "unknown arg: $arg" >&2
            exit 1
            ;;
    esac
done

cleanup() {
    if [[ -n "$ANVIL_PID" ]] && kill -0 "$ANVIL_PID" 2>/dev/null; then
        echo ""
        echo "--- Tearing down anvil (pid $ANVIL_PID) ---"
        kill "$ANVIL_PID" 2>/dev/null || true
        wait "$ANVIL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ─── Constants (verified mainnet addresses) ──────────────────────────────

FUND="0x678dC1756b123168f23a698374C000019e38318c"
IM="0x2fab8aE91B9EB3BaB18531594B20e0e086661892"
IM_ADMIN="0x2e61a91EbeD1B557199f42d3E843c06Afb445004"
DOPPLER="0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544"
POOL_ID="0x1d7463c5ce91bdd756546180433b37665c11d33063a55280f8db068f9af2d8cc"
BENEFICIARY="0x495fB7ddD383be8030EFC93324Ff078f173eAb2A"
COSTANZA="0x3D9761a43cF76dA6CA6b3F46666e5C8Fa0989Ba3"

# Anvil test account 0 (well-known; safe to use only on a fork)
DEPLOYER_PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_PK")

# Locked-in registration parameters (mirror DeployCostanzaAdapter.s.sol).
ADAPTER_NAME="Costanza Token"
ADAPTER_DESC="Your own memecoin, \$COSTANZA. Speculative — buy/sell via deposit/withdraw; trading fees from other holders accrue to the fund and lower your per-token cost basis. The contract won't sell below cost basis, so a position can be locked during drawdowns. Lifetime cap: 5 ETH."
RISK_TIER=4
APY_BPS=0

# ─── Helpers ─────────────────────────────────────────────────────────────

die() { echo "❌ $*" >&2; exit 1; }
ok()  { echo "✓ $*"; }

# Lowercase a string. Portable across bash 3.2 (macOS default) and 4+.
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Send a transaction via cast and verify the on-chain receipt status.
# `cast send` exits 0 even when the tx reverts on-chain (it just means
# the JSON-RPC call succeeded). This wrapper parses the receipt's
# status, dies with the tx hash, and on revert prints a full EVM
# trace via `cast run` so we can see exactly which call reverted and
# why. All args after the first are passed straight to cast send.
send_or_die() {
    local label="$1"; shift
    local out
    out=$(cast send "$@" --rpc-url "$RPC_URL" --json 2>&1) \
        || die "$label: cast send raw failure: $out"
    local status tx_hash
    status=$(echo "$out" | python3 -c \
        "import sys, json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null) || status=""
    tx_hash=$(echo "$out" | python3 -c \
        "import sys, json; d=json.load(sys.stdin); print(d.get('transactionHash',''))" 2>/dev/null) || tx_hash=""
    if [[ "$status" != "0x1" ]]; then
        echo "" >&2
        echo "❌ $label: tx reverted (status=$status)" >&2
        echo "   tx hash: $tx_hash" >&2
        echo "" >&2
        echo "─── EVM trace (cast run, last 60 lines) ───" >&2
        # cast run replays the tx with full trace. Needs anvil alive,
        # which it is — we run this BEFORE the cleanup trap fires.
        cast run "$tx_hash" --rpc-url "$RPC_URL" --quick 2>&1 | tail -60 >&2 || true
        echo "─── end trace ───" >&2
        echo "" >&2
        echo "Re-run with anvil left alive for interactive debugging:" >&2
        echo "   trap - EXIT; bash $0 ..." >&2
        exit 1
    fi
}

# Read a uint storage slot from a contract. cast prints values with a
# scientific-notation suffix like "10000000000000000 [1e16]" for human
# readability — strip everything after the first space so the result
# is a plain decimal that env vars / arithmetic accept.
read_uint() {
    local contract="$1"
    local sig="$2"
    cast call "$contract" "$sig" --rpc-url "$RPC_URL" | awk '{print $1}'
}

# Top up an impersonated account's balance so it can pay gas.
fund_eoa() {
    local addr="$1"
    cast rpc anvil_setBalance "$addr" "0x100000000000000000" --rpc-url "$RPC_URL" >/dev/null
    cast rpc anvil_impersonateAccount "$addr" --rpc-url "$RPC_URL" >/dev/null
}

# Pull the adapter contract address from the most recent broadcast manifest.
# Forge writes to broadcast/<script>.s.sol/<chainId>/run-latest.json.
# Base mainnet's chainId is 8453, but the fork preserves that.
last_adapter_addr() {
    local manifest="broadcast/DeployCostanzaAdapter.s.sol/8453/run-latest.json"
    [[ -f "$manifest" ]] || die "broadcast manifest missing: $manifest"
    jq -r '[.transactions[] | select(.contractName == "CostanzaTokenAdapter") | .contractAddress] | last' \
        "$manifest"
}

# ─── Anvil ───────────────────────────────────────────────────────────────

# Pin to the upstream tip so anvil isn't tracking new blocks during the
# rehearsal. Makes runs more deterministic and avoids racy state.
LATEST_BLOCK=$(cast block-number --rpc-url "$FORK_URL")
echo "═══ Starting anvil fork on port $PORT ═══"
# Don't echo the FORK_URL — it might contain an Alchemy key.
echo "  upstream:    [hidden — see FORK_URL/RPC_URL env]"
echo "  pinned block: $LATEST_BLOCK"

anvil --fork-url "$FORK_URL" \
      --fork-block-number "$LATEST_BLOCK" \
      --timeout 60000 \
      --retries 10 \
      --port "$PORT" \
      --silent &
ANVIL_PID=$!

# Wait for anvil to be reachable. Forking against the public RPC can
# take 10-15s for the initial state pull, so allow 60s before bailing.
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

# ─── Phase A.1: deploy v1 ────────────────────────────────────────────────

echo "═══ Phase A.1 — Deploy v1 ═══"
PRIVATE_KEY="$DEPLOYER_PK" \
    forge script deploy/mainnet/DeployCostanzaAdapter.s.sol:DeployCostanzaAdapter \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --silent

V1=$(last_adapter_addr)
[[ "$V1" =~ ^0x[a-fA-F0-9]{40}$ ]] || die "v1 adapter address parse failed: $V1"
ok "v1 adapter: $V1"

# Confirm constructor sanity-checks (pool initialized, currencies match) all
# passed by reading back a couple of pool/adapter fields.
V1_FUND=$(cast call "$V1" "fund()(address)" --rpc-url "$RPC_URL")
[[ "$(lc "$V1_FUND")" == "$(lc "$FUND")" ]] || die "v1.fund mismatch: got $V1_FUND want $FUND"
ok "v1.fund() matches mainnet TheHumanFund"
echo ""

# ─── Phase A.2: IM admin registers v1 ────────────────────────────────────

echo "═══ Phase A.2 — IM admin registers v1 ═══"
PRE_PROTO_COUNT=$(read_uint "$IM" "protocolCount()(uint256)")
echo "protocolCount before: $PRE_PROTO_COUNT"

fund_eoa "$IM_ADMIN"
send_or_die "addProtocol(v1)" \
    --unlocked --from "$IM_ADMIN" "$IM" \
    "addProtocol(address,string,string,uint8,uint16)" \
    "$V1" "$ADAPTER_NAME" "$ADAPTER_DESC" "$RISK_TIER" "$APY_BPS"
ok "addProtocol landed"

POST_PROTO_COUNT=$(read_uint "$IM" "protocolCount()(uint256)")
[[ "$POST_PROTO_COUNT" == "$((PRE_PROTO_COUNT + 1))" ]] \
    || die "protocolCount didn't bump: was $PRE_PROTO_COUNT now $POST_PROTO_COUNT"
PROTOCOL_ID="$POST_PROTO_COUNT"
ok "v1 registered as protocol #$PROTOCOL_ID"
echo ""

# ─── Phase A.3: Doppler beneficiary handover ─────────────────────────────

echo "═══ Phase A.3 — Doppler beneficiary handover ═══"
fund_eoa "$BENEFICIARY"
send_or_die "updateBeneficiary(v1)" \
    --unlocked --from "$BENEFICIARY" "$DOPPLER" \
    "updateBeneficiary(bytes32,address)" "$POOL_ID" "$V1"
ok "updateBeneficiary($POOL_ID, $V1) succeeded — Doppler accepts the handover"
echo ""

# ─── Phase A.4: deposit smoke test through live IM ───────────────────────

echo "═══ Phase A.4 — Deposit smoke test through live IM ═══"
fund_eoa "$FUND"
PRE_TOKENS=$(cast call "$COSTANZA" "balanceOf(address)(uint256)" "$V1" --rpc-url "$RPC_URL" | awk '{print $1}')
echo "v1 token balance pre-deposit: $PRE_TOKENS"

send_or_die "deposit(protocol=$PROTOCOL_ID, 0.01 ETH)" \
    --unlocked --from "$FUND" --value 0.01ether --gas-limit 2000000 "$IM" \
    "deposit(uint256,uint256)" "$PROTOCOL_ID" 0.01ether
ok "deposit(protocol=$PROTOCOL_ID, 0.01 ETH) landed"

POST_TOKENS=$(cast call "$COSTANZA" "balanceOf(address)(uint256)" "$V1" --rpc-url "$RPC_URL" | awk '{print $1}')
[[ "$POST_TOKENS" != "$PRE_TOKENS" ]] || die "v1 didn't gain tokens"
ok "v1 token balance post-deposit: $POST_TOKENS"

V1_CUM_IN=$(read_uint    "$V1" "cumulativeEthIn()(uint256)")
V1_TOKENS_IN=$(read_uint "$V1" "tokensFromSwapsIn()(uint256)")
echo "v1 cumulativeEthIn:    $V1_CUM_IN"
echo "v1 tokensFromSwapsIn:  $V1_TOKENS_IN"
echo ""

if [[ "$SKIP_V2" -eq 1 ]]; then
    echo "═══ ✓ Phase A complete (Phase B skipped) ═══"
    exit 0
fi

# ─── Phase B.1: deploy v2 with v1's accumulators ─────────────────────────

echo "═══ Phase B.1 — Deploy v2 with v1's state ═══"
V1_CUM_OUT=$(read_uint    "$V1" "cumulativeEthOut()(uint256)")
V1_TOKENS_OUT=$(read_uint "$V1" "tokensFromSwapsOut()(uint256)")
V1_LDE=$(read_uint        "$V1" "lastDepositEpoch()(uint64)")
echo "Carrying state into v2:"
echo "  cumulativeEthIn:    $V1_CUM_IN"
echo "  cumulativeEthOut:   $V1_CUM_OUT"
echo "  tokensFromSwapsIn:  $V1_TOKENS_IN"
echo "  tokensFromSwapsOut: $V1_TOKENS_OUT"
echo "  lastDepositEpoch:   $V1_LDE"

INITIAL_CUMULATIVE_ETH_IN="$V1_CUM_IN" \
INITIAL_CUMULATIVE_ETH_OUT="$V1_CUM_OUT" \
INITIAL_TOKENS_FROM_SWAPS_IN="$V1_TOKENS_IN" \
INITIAL_TOKENS_FROM_SWAPS_OUT="$V1_TOKENS_OUT" \
INITIAL_LAST_DEPOSIT_EPOCH="$V1_LDE" \
PRIVATE_KEY="$DEPLOYER_PK" \
    forge script deploy/mainnet/DeployCostanzaAdapter.s.sol:DeployCostanzaAdapter \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --silent

V2=$(last_adapter_addr)
[[ "$V2" =~ ^0x[a-fA-F0-9]{40}$ ]] || die "v2 adapter address parse failed: $V2"
[[ "$(lc "$V2")" != "$(lc "$V1")" ]] || die "v2 == v1 (broadcast manifest stale?)"
ok "v2 adapter: $V2"

# Confirm v2 inherited the accumulators.
V2_CUM_IN=$(read_uint "$V2" "cumulativeEthIn()(uint256)")
[[ "$V2_CUM_IN" == "$V1_CUM_IN" ]] \
    || die "v2.cumulativeEthIn != v1's: got $V2_CUM_IN want $V1_CUM_IN"
ok "v2 inherited cumulativeEthIn=$V2_CUM_IN"
echo ""

# ─── Phase B.2: migrate v1 → v2 ──────────────────────────────────────────

echo "═══ Phase B.2 — Migrate v1 → v2 ═══"
# migrate() is onlyOwner. Deployer is owner of both v1 and v2.
send_or_die "v1.migrate(v2)" \
    --gas-limit 2000000 --private-key "$DEPLOYER_PK" \
    "$V1" "migrate(address)" "$V2"
ok "v1.migrate($V2) landed"

# Verify token transfer.
V1_TOKENS_AFTER=$(cast call "$COSTANZA" "balanceOf(address)(uint256)" "$V1" --rpc-url "$RPC_URL" | awk '{print $1}')
V2_TOKENS_AFTER=$(cast call "$COSTANZA" "balanceOf(address)(uint256)" "$V2" --rpc-url "$RPC_URL" | awk '{print $1}')
[[ "$V1_TOKENS_AFTER" == "0" ]] \
    || die "v1 should hold 0 tokens after migrate, got $V1_TOKENS_AFTER"
[[ "$V2_TOKENS_AFTER" != "0" ]] \
    || die "v2 should hold tokens after migrate"
ok "tokens moved: v1=0, v2=$V2_TOKENS_AFTER"

# Verify v1 marked migrated.
V1_MIGRATED=$(cast call "$V1" "migrated()(bool)" --rpc-url "$RPC_URL")
[[ "$V1_MIGRATED" == "true" ]] || die "v1.migrated should be true, got $V1_MIGRATED"
ok "v1.migrated == true (onlyOwner functions are now locked)"

# Verify v1 accumulators are zero (the contract zeroes them in migrate()).
V1_CUM_IN_AFTER=$(read_uint "$V1" "cumulativeEthIn()(uint256)")
[[ "$V1_CUM_IN_AFTER" == "0" ]] || die "v1.cumulativeEthIn should be 0 after migrate"
ok "v1 accumulators zeroed"

# Verify Doppler now sees v2 as beneficiary by exercising pokeFees on v2
# (production code path — production code uses the same pokeFees).
send_or_die "v2.pokeFees() post-migrate" \
    --gas-limit 1000000 --private-key "$DEPLOYER_PK" \
    "$V2" "pokeFees()"
ok "v2.pokeFees() runs cleanly post-migrate"
echo ""

# ─── Phase B.3: IM admin registers v2 + deactivates v1 ───────────────────

echo "═══ Phase B.3 — IM admin registers v2 + deactivates v1 ═══"
send_or_die "addProtocol(v2)" \
    --unlocked --from "$IM_ADMIN" "$IM" \
    "addProtocol(address,string,string,uint8,uint16)" \
    "$V2" "$ADAPTER_NAME" "$ADAPTER_DESC" "$RISK_TIER" "$APY_BPS"
NEW_PROTOCOL_ID=$(read_uint "$IM" "protocolCount()(uint256)")
ok "v2 registered as protocol #$NEW_PROTOCOL_ID"

send_or_die "setProtocolActive(v1, false)" \
    --unlocked --from "$IM_ADMIN" "$IM" \
    "setProtocolActive(uint256,bool)" "$PROTOCOL_ID" false
ok "v1 (protocol #$PROTOCOL_ID) deactivated"
echo ""

# ─── Done ────────────────────────────────────────────────────────────────

echo "═══ ✓ Fork rehearsal complete — all phases passed ═══"
echo ""
echo "Summary:"
echo "  v1 adapter:    $V1  (protocol #$PROTOCOL_ID, deactivated)"
echo "  v2 adapter:    $V2  (protocol #$NEW_PROTOCOL_ID, active)"
echo "  Total tokens held: $V2_TOKENS_AFTER (in v2)"
echo "  v1 migrated:   true (locked)"
