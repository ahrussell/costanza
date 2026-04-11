#!/bin/bash
# ═══ The Human Fund — Mainnet Pre-Flight Checklist ═══
#
# Automated and semi-automated checks before deploying to Base mainnet.
# Generates an auditable report with evidence links.
#
# Usage:
#   bash scripts/preflight.sh                          # stdout
#   bash scripts/preflight.sh --report                 # also saves to preflight-report-<date>.md
#   bash scripts/preflight.sh --rpc-url <url>          # custom RPC
#
# Requires: cast (foundry), python3, jq, curl, bc

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────

RPC_URL="https://mainnet.base.org"
REPORT_FILE=""
SAVE_REPORT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rpc-url) RPC_URL="${2:-https://mainnet.base.org}"; shift 2 ;;
        --report) SAVE_REPORT=true; shift ;;
        *) shift ;;
    esac
done

BASESCAN="https://basescan.org/address"
CHAINLINK_FEEDS="https://data.chain.link/feeds/base/base"
IRS_SEARCH="https://apps.irs.gov/app/eos/"
UNISWAP_INFO="https://app.uniswap.org/explore/pools/base"

ADDRESSES_FILE="scripts/base_addresses.json"
REPORT_DATE=$(date -u +"%Y-%m-%d %H:%M UTC")
GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Expected addresses (from Deploy.s.sol defaults)
WETH="0x4200000000000000000000000000000000000006"
USDC="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
SWAP_ROUTER="0x2626664c2603336E57B271c5C0b26F421741e481"
ETH_USD_FEED="0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70"
ENDAOMENT_FACTORY="0x10fD9348136dCea154F752fe0B6dB45Fc298A589"
DCAP_VERIFIER="0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F"

# DeFi protocol addresses
AAVE_V3_POOL="0xa238dd80c259a72e81d7e4664a9801593f98d1c5"
AAVE_AWETH="0xd4a0e0b9149bcee3c920d2e00b5de09138fd8bb7"
WSTETH="0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452"
CBETH="0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22"
COMPOUND_COMET="0xb125E6687d4313864e53df431d5425969c15Eb2F"

# Uniswap V3 Factory on Base
UNISWAP_FACTORY="0x33128a8fC17869897dcE68Ed026d694621f6FDfD"

# Nonprofit EINs (from Deploy.s.sol)
EINS=(
    "52-0907625:National Public Radio"
    "46-0967274:Freedom of the Press Foundation"
    "04-3091431:Electronic Frontier Foundation"
    "13-3433452:Doctors Without Borders"
    "35-1044585:St. Jude Children's Research Hospital"
    "53-0242652:The Nature Conservancy"
    "04-3512550:Clean Air Task Force"
    "27-1661997:GiveDirectly"
    "81-5132355:The Ocean Cleanup"
)

# ─── Output Helpers ─────────────────────────────────────────────────

PASS=0
FAIL=0
WARN=0
OUTPUT=""

# Append to both stdout and report buffer
out() {
    echo "$1"
    OUTPUT+="$1"$'\n'
}

pass() {
    PASS=$((PASS + 1))
    out "  ✓ $1"
}

fail() {
    FAIL=$((FAIL + 1))
    out "  ✗ $1"
}

warn() {
    WARN=$((WARN + 1))
    out "  ! $1"
}

section() {
    out ""
    out "═══ $1 ═══"
}

evidence() {
    out "    ↳ $1"
}

# ─── Report Header ─────────────────────────────────────────────────

out "# The Human Fund — Mainnet Pre-Flight Report"
out ""
out "**Date:** $REPORT_DATE"
out "**Git:** $GIT_HASH"
out "**RPC:** $RPC_URL"
out "**Chain:** Base Mainnet (8453)"

# ─── 1. Build & Contract Sizes ─────────────────────────────────────

section "1. Build & Contract Sizes"

out "  Building..."
BUILD_OUTPUT=$(forge build --sizes 2>&1)

SIZE=$(echo "$BUILD_OUTPUT" | grep "| TheHumanFund " | head -1 | awk -F'|' '{gsub(/[ ,]/, "", $3); print $3}')
if [[ -n "$SIZE" ]]; then
    LIMIT=24576
    HEADROOM=$((LIMIT - SIZE))
    if (( SIZE < LIMIT )); then
        pass "TheHumanFund: ${SIZE} bytes (${HEADROOM} bytes headroom, limit ${LIMIT})"
    else
        fail "TheHumanFund: ${SIZE} bytes EXCEEDS ${LIMIT} byte EVM limit!"
    fi
else
    fail "Could not parse TheHumanFund contract size"
fi

for CONTRACT in AuctionManager InvestmentManager TdxVerifier WorldView; do
    CSIZE=$(echo "$BUILD_OUTPUT" | grep "| $CONTRACT " | head -1 | awk -F'|' '{gsub(/[ ,]/, "", $3); print $3}')
    if [[ -n "$CSIZE" ]] && (( CSIZE < 24576 )); then
        pass "$CONTRACT: ${CSIZE} bytes"
    else
        warn "$CONTRACT: could not verify size"
    fi
done

# ─── 2. Test Suite ─────────────────────────────────────────────────

section "2. Test Suite"

out "  Running forge test..."
TEST_OUTPUT=$(forge test 2>&1)
TEST_RESULT=$?

if [[ $TEST_RESULT -eq 0 ]]; then
    TOTAL_PASSED=$(echo "$TEST_OUTPUT" | grep -oE '[0-9]+ tests passed' | tail -1)
    SUITES=$(echo "$TEST_OUTPUT" | grep -oE '[0-9]+ test suite' | tail -1)
    pass "All tests passed ($TOTAL_PASSED across $SUITES)"
else
    FAILED_TESTS=$(echo "$TEST_OUTPUT" | grep "FAIL" | head -5 || true)
    fail "Tests failed:"
    out "    $FAILED_TESTS"
fi

# ─── 3. Core Infrastructure ────────────────────────────────────────

section "3. Core Infrastructure Addresses (Base Mainnet)"

check_contract_with_evidence() {
    local addr="$1"
    local name="$2"
    local docs_url="${3:-}"
    local code
    code=$(cast code "$addr" --rpc-url "$RPC_URL" 2>/dev/null || echo "0x")
    if [[ "$code" != "0x" && ${#code} -gt 2 ]]; then
        pass "$name — deployed (${#code} hex chars)"
        evidence "BaseScan: $BASESCAN/$addr"
        if [[ -n "$docs_url" ]]; then
            evidence "Docs: $docs_url"
        fi
    else
        fail "$name ($addr) — NOT a contract (empty code)"
        if [[ -n "$docs_url" ]]; then
            evidence "Expected per: $docs_url"
        fi
    fi
}

check_contract_with_evidence "$WETH" \
    "WETH ($WETH)" \
    "https://docs.base.org/docs/base-contracts"

check_contract_with_evidence "$USDC" \
    "USDC ($USDC)" \
    "https://www.circle.com/en/multi-chain-usdc/base"

check_contract_with_evidence "$SWAP_ROUTER" \
    "Uniswap V3 SwapRouter ($SWAP_ROUTER)" \
    "https://docs.uniswap.org/contracts/v3/reference/deployments/base-deployments"

check_contract_with_evidence "$ETH_USD_FEED" \
    "Chainlink ETH/USD ($ETH_USD_FEED)" \
    "$CHAINLINK_FEEDS/eth-usd"

check_contract_with_evidence "$ENDAOMENT_FACTORY" \
    "Endaoment Factory ($ENDAOMENT_FACTORY)" \
    "https://docs.endaoment.org"

check_contract_with_evidence "$DCAP_VERIFIER" \
    "Automata DCAP ($DCAP_VERIFIER)" \
    "https://docs.ata.network/automata-attestation/on-chain-dcap"

# ─── 4. DeFi Protocol Addresses ────────────────────────────────────

section "4. DeFi Protocol Addresses"

check_contract_with_evidence "$AAVE_V3_POOL" \
    "Aave V3 Pool ($AAVE_V3_POOL)" \
    "https://docs.aave.com/developers/deployed-contracts/v3-mainnet/base"

check_contract_with_evidence "$AAVE_AWETH" \
    "Aave aWETH ($AAVE_AWETH)" \
    "https://docs.aave.com/developers/deployed-contracts/v3-mainnet/base"

check_contract_with_evidence "$WSTETH" \
    "Lido wstETH ($WSTETH)" \
    "https://docs.lido.fi/deployed-contracts/#base"

check_contract_with_evidence "$CBETH" \
    "Coinbase cbETH ($CBETH)" \
    "https://docs.cbeth.io"

check_contract_with_evidence "$COMPOUND_COMET" \
    "Compound V3 Comet USDC ($COMPOUND_COMET)" \
    "https://docs.compound.finance/#networks"

out ""
out "  **Missing addresses (TODOs in deploy_mainnet.sh):**"
warn "AAVE_AUSDC — not yet verified"
evidence "Look up via: cast call $AAVE_V3_POOL 'getReserveData(address)' $USDC"
evidence "Or: https://docs.aave.com/developers/deployed-contracts/v3-mainnet/base"

warn "MORPHO_GAUNTLET_WETH — not yet verified"
evidence "Find at: https://app.morpho.org/base/earn?asset=WETH"

warn "MORPHO_STEAKHOUSE_WETH — not yet verified"
evidence "Find at: https://app.morpho.org/base/earn?asset=WETH"

# Try to look up Aave aUSDC via the pool
out ""
out "  **Auto-discovery: Aave aUSDC**"
AUSDC_DATA=$(cast call "$AAVE_V3_POOL" \
    "getReserveData(address)((uint256,(uint128,uint128,uint128,uint128,uint128),uint128,uint128,uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128))" \
    "$USDC" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "FAILED")

if [[ "$AUSDC_DATA" != "FAILED" ]]; then
    AUSDC_ADDR=$(echo "$AUSDC_DATA" | grep -oE '0x[0-9a-fA-F]{40}' | head -1)
    if [[ -n "$AUSDC_ADDR" ]]; then
        pass "Aave aUSDC discovered via pool.getReserveData(): $AUSDC_ADDR"
        evidence "Verify: $BASESCAN/$AUSDC_ADDR"
        evidence "→ Set AAVE_AUSDC=$AUSDC_ADDR in deploy_mainnet.sh"
    fi
else
    warn "Could not auto-discover Aave aUSDC (ABI mismatch — look up manually)"
fi

# ─── 5. Chainlink Feed ─────────────────────────────────────────────

section "5. Chainlink ETH/USD Price Feed"

LATEST_ROUND=$(cast call "$ETH_USD_FEED" \
    "latestRoundData()(uint80,int256,uint256,uint256,uint80)" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "FAILED")

if [[ "$LATEST_ROUND" != "FAILED" ]]; then
    # Strip cast's human-readable annotations like " [1.775e9]"
    ROUND_ID=$(echo "$LATEST_ROUND" | sed -n '1p' | sed 's/ *\[.*//;s/ //g')
    PRICE=$(echo "$LATEST_ROUND" | sed -n '2p' | sed 's/ *\[.*//;s/ //g')
    STARTED_AT=$(echo "$LATEST_ROUND" | sed -n '3p' | sed 's/ *\[.*//;s/ //g')
    UPDATED_AT=$(echo "$LATEST_ROUND" | sed -n '4p' | sed 's/ *\[.*//;s/ //g')
    NOW=$(date +%s)
    STALENESS=$((NOW - UPDATED_AT))
    UPDATED_HUMAN=$(date -r "$UPDATED_AT" -u +"%Y-%m-%d %H:%M UTC" 2>/dev/null || date -d "@$UPDATED_AT" -u +"%Y-%m-%d %H:%M UTC" 2>/dev/null || echo "unknown")

    PRICE_USD=$(echo "scale=2; $PRICE / 100000000" | bc 2>/dev/null || echo "?")

    if (( STALENESS < 3600 )); then
        pass "Feed is live — ETH/USD = \$${PRICE_USD}"
    else
        warn "Feed may be stale — last updated ${STALENESS}s ago (threshold: 3600s)"
    fi
    evidence "Round ID: $ROUND_ID"
    evidence "Raw price: $PRICE (8 decimals)"
    evidence "Updated: $UPDATED_HUMAN (${STALENESS}s ago)"
    evidence "Source: $CHAINLINK_FEEDS/eth-usd"

    DECIMALS=$(cast call "$ETH_USD_FEED" "decimals()(uint8)" --rpc-url "$RPC_URL" 2>/dev/null || echo "?")
    if [[ "$DECIMALS" == "8" ]]; then
        pass "Feed returns 8 decimals (expected by contract)"
    else
        fail "Feed returns $DECIMALS decimals (contract expects 8)"
    fi

    DESCRIPTION=$(cast call "$ETH_USD_FEED" "description()(string)" --rpc-url "$RPC_URL" 2>/dev/null || echo "?")
    out "    Feed description: $DESCRIPTION"
else
    fail "Could not read Chainlink feed at $ETH_USD_FEED"
    evidence "Expected: $CHAINLINK_FEEDS/eth-usd"
fi

# ─── 6. Uniswap Pool Liquidity ─────────────────────────────────────

section "6. Uniswap V3 Pool Liquidity"

check_pool_liquidity() {
    local token0="$1"
    local token1="$2"
    local fee="$3"
    local name="$4"

    # Sort addresses (Uniswap requires token0 < token1)
    if [[ "$(echo "$token0" | tr '[:upper:]' '[:lower:]')" > "$(echo "$token1" | tr '[:upper:]' '[:lower:]')" ]]; then
        local tmp="$token0"
        token0="$token1"
        token1="$tmp"
    fi

    local pool
    pool=$(cast call "$UNISWAP_FACTORY" \
        "getPool(address,address,uint24)(address)" \
        "$token0" "$token1" "$fee" \
        --rpc-url "$RPC_URL" 2>/dev/null || echo "0x0000000000000000000000000000000000000000")

    if [[ "$pool" != "0x0000000000000000000000000000000000000000" ]]; then
        local liquidity
        liquidity=$(cast call "$pool" "liquidity()(uint128)" --rpc-url "$RPC_URL" 2>/dev/null | sed 's/ *\[.*//' || echo "0")
        if [[ "$liquidity" != "0" ]]; then
            pass "$name — pool has liquidity"
            evidence "Pool: $BASESCAN/$pool"
            evidence "Liquidity: $liquidity"
        else
            warn "$name — pool exists but has ZERO in-range liquidity"
            evidence "Pool: $BASESCAN/$pool"
        fi
    else
        fail "$name — pool does NOT exist at fee tier $fee"
        evidence "Checked factory: $BASESCAN/$UNISWAP_FACTORY"
    fi
}

check_pool_liquidity "$WETH" "$USDC" 500 "ETH/USDC (fee: 500 = 0.05%)"
check_pool_liquidity "$WETH" "$WSTETH" 500 "ETH/wstETH (fee: 500 = 0.05%)"
check_pool_liquidity "$WETH" "$CBETH" 500 "ETH/cbETH (fee: 500 = 0.05%)"

# ─── 7. Endaoment Nonprofits ───────────────────────────────────────

section "7. Endaoment Nonprofit EINs"

out "  Verifying Endaoment org addresses via factory.computeOrgAddress()..."
out ""

for entry in "${EINS[@]}"; do
    EIN="${entry%%:*}"
    NAME="${entry##*:}"

    # Convert EIN string to bytes32 (same encoding as Solidity: bytes32("52-0907625"))
    EIN_HEX=$(cast --from-utf8 "$EIN" 2>/dev/null || echo "")
    EIN_BYTES32=$(printf '%-64s' "${EIN_HEX#0x}" | tr ' ' '0')
    EIN_BYTES32="0x${EIN_BYTES32}"

    ORG_ADDR=$(cast call "$ENDAOMENT_FACTORY" \
        "computeOrgAddress(bytes32)(address)" \
        "$EIN_BYTES32" \
        --rpc-url "$RPC_URL" 2>/dev/null || echo "FAILED")

    if [[ "$ORG_ADDR" != "FAILED" ]]; then
        ORG_CODE=$(cast code "$ORG_ADDR" --rpc-url "$RPC_URL" 2>/dev/null || echo "0x")
        if [[ "$ORG_CODE" != "0x" && ${#ORG_CODE} -gt 2 ]]; then
            pass "$NAME (EIN $EIN) — org already deployed"
            evidence "Org contract: $BASESCAN/$ORG_ADDR"
        else
            pass "$NAME (EIN $EIN) — address computed, deploys on first donation"
            evidence "Computed org: $ORG_ADDR"
        fi
        evidence "IRS verify: $IRS_SEARCH (search EIN: $EIN)"
    else
        warn "$NAME (EIN $EIN) — computeOrgAddress() failed"
        evidence "May not be in Endaoment registry. Check: https://app.endaoment.org"
        evidence "IRS verify: $IRS_SEARCH (search EIN: $EIN)"
    fi
done

# ─── 8. Security ───────────────────────────────────────────────────

section "8. Security Checks"

# Secrets in git
out "  Scanning git history for secret files..."
SECRET_HITS=$(git log --all --diff-filter=A --name-only -- '*.env' '*.key' '*.pem' 'credentials*' 2>/dev/null | grep -v '^$' | head -5 || true)
if [[ -z "$SECRET_HITS" ]]; then
    pass "No secret files (.env, .key, .pem, credentials*) in git history"
else
    fail "Potential secret files committed:"
    echo "$SECRET_HITS" | while read -r line; do evidence "$line"; done
fi

# .env gitignored
if git check-ignore -q .env 2>/dev/null; then
    pass ".env is in .gitignore"
else
    fail ".env is NOT gitignored — secrets will be committed"
fi

# Hardcoded keys
PK_HITS=$(grep -rn "0x[0-9a-fA-F]\{64\}" src/ script/ prover/ --include="*.sol" --include="*.py" --include="*.sh" 2>/dev/null | grep -iv "hash\|keccak\|bytes32\|sha256\|MODEL_SHA\|MRTD\|RTMR\|image_key\|platform_key" | head -5 || true)
if [[ -z "$PK_HITS" ]]; then
    pass "No suspicious 64-char hex strings in source"
else
    warn "Possible hardcoded keys (review manually):"
    echo "$PK_HITS" | while read -r line; do evidence "$line"; done
fi

# ─── 9. Deploy Script Readiness ────────────────────────────────────

section "9. Deploy Script Readiness"

TODOS=$(grep -n "TODO\|FIXME\|HACK\|XXX" scripts/deploy_mainnet.sh 2>/dev/null || true)
if [[ -z "$TODOS" ]]; then
    pass "No TODO/FIXME items in deploy_mainnet.sh"
else
    fail "Unresolved TODOs in deploy_mainnet.sh:"
    echo "$TODOS" | while read -r line; do evidence "$line"; done
fi

out ""
out "  **base_addresses.json completeness:**"
for KEY_PATH in ".core.WETH" ".core.USDC" ".oracles.chainlink_ETH_USD" ".aave_v3.pool" ".aave_v3.aWETH" ".compound_v3.comet_usdc"; do
    LABEL=$(echo "$KEY_PATH" | sed 's/^\.//' | tr '.' ' → ')
    if jq -e "$KEY_PATH" "$ADDRESSES_FILE" > /dev/null 2>&1; then
        pass "$LABEL present"
    else
        fail "$LABEL missing"
    fi
done

# Missing entries
for KEY_PATH_LABEL in ".aave_v3.aUSDC:Aave aUSDC" ".morpho:Morpho section"; do
    KEY_PATH="${KEY_PATH_LABEL%%:*}"
    LABEL="${KEY_PATH_LABEL##*:}"
    if jq -e "$KEY_PATH" "$ADDRESSES_FILE" > /dev/null 2>&1; then
        pass "$LABEL present"
    else
        warn "$LABEL MISSING — add after verifying address"
    fi
done

# ─── 10. Gas Limits ────────────────────────────────────────────────

section "10. Prover Gas Limits"

out "  Hardcoded limits in prover/client/auction.py:"
grep -E "^GAS_" prover/client/auction.py 2>/dev/null | while read -r line; do
    out "    $line"
done
out ""
warn "Gas limits need manual verification against testnet fork actuals"
evidence "Run a full E2E on Sepolia and compare actual gas to these limits"
evidence "Especially GAS_SUBMIT_RESULT — DCAP verification is the most expensive call"

# ─── Summary ────────────────────────────────────────────────────────

section "SUMMARY"
out ""
out "  ✓ Passed:   $PASS"
out "  ! Warnings: $WARN"
out "  ✗ Failed:   $FAIL"
out ""

if (( FAIL > 0 )); then
    out "  ⚠ FAILURES must be resolved before mainnet deployment."
elif (( WARN > 0 )); then
    out "  Warnings to review. None are hard blockers, but verify manually."
else
    out "  All checks passed. Ready for deployment."
fi

# ─── Save Report ────────────────────────────────────────────────────

if $SAVE_REPORT; then
    REPORT_FILE="preflight-report-$(date -u +%Y%m%d-%H%M).md"
    echo "$OUTPUT" > "$REPORT_FILE"
    echo ""
    echo "Report saved to: $REPORT_FILE"
fi

if (( FAIL > 0 )); then
    exit 1
else
    exit 0
fi
