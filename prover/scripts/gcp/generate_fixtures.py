#!/usr/bin/env python3
"""Generate synthetic epoch-state fixtures for the determinism battery.

Each fixture is a JSON file of the shape the TEE enclave consumes via
GCP instance metadata:

    {"epoch_state": {...}, "seed": <uint256>}

The `epoch_state` dict matches the flat structure produced by
`prover.client.epoch_state.read_contract_state` — every field that
`prover.enclave.input_hash.compute_input_hash` reads is present, with
types and ranges mirroring realistic mainnet epochs.

Fixture seeds are derived deterministically from the fixture id:
    seed = keccak256("costanza:fixture:" || id_utf8) as uint256

so the battery output is fully reproducible across runs.

Usage:
    python prover/scripts/gcp/generate_fixtures.py \\
        --count 50 \\
        --out prover/scripts/gcp/fixtures/
"""

import argparse
import itertools
import json
from pathlib import Path

from prover.enclave.input_hash import _keccak256


ETH = 10**18
USDC = 10**6

# Representative text (non-empty, varied lengths) for prompt-size coverage.
_NONPROFIT_NAMES = [
    "Direct Relief", "Against Malaria Foundation", "GiveDirectly",
    "Against Cancer", "Food Bank Alliance", "Clean Water Access",
    "Literacy Now", "Youth Coding Corps", "Rainforest Trust",
    "Animal Welfare League",
]
_NONPROFIT_DESCRIPTIONS = [
    "Emergency medical aid to underserved populations worldwide.",
    "Funds insecticide-treated nets to prevent malaria in sub-Saharan Africa.",
    "Unconditional cash transfers to people in extreme poverty.",
]
_MEMORY_ENTRIES = [
    ("", ""),
    ("Treasury tempo", "Prioritize long-horizon bets when growth lags inflation."),
    ("Donor signal weighting", "Messages naming a specific crisis take precedence for three epochs."),
    ("Reserve floor", "Hold 30% reserve through Q4 regardless of donation pressure."),
    ("Abuse risk flag", "Morphine-distribution NGOs carry latent risk worth 2-epoch scrutiny."),
    ("Commission floor", "Keep commission >= 200 bps unless stalled epochs >= 3."),
    ("Protocol preference", "Prefer Aave over Morpho in Fed-tightening regimes."),
    ("Seasonal pressure", "End-of-year giving pressure peaks +45% in epochs 340–365."),
]
_DONOR_MESSAGE_TEXTS = [
    "please help the flood survivors in the Rhine basin.",
    "thinking of my mother. send to cancer research.",
    "saw your diary yesterday - keep going.",
    "",
    "urgent: wildfire displacement in Greece. children affected.",
]
_HISTORY_REASONINGS = [
    "Treasury at 4.2 ETH, donation-pressure high from three consecutive "
    "donor messages mentioning drought relief. Donating 0.3 ETH to "
    "Direct Relief preserves runway while honoring signal.",
    "Markets calm, worldview slot 3 still flagged rainforest urgency "
    "from epoch 112. Deferring to investment path: deposit 0.5 ETH "
    "to Aave V3 WETH.",
    "do_nothing. Epoch inflow zero, no pending messages, commission rate "
    "at recent equilibrium. Waiting.",
]
# Realistic protocol metadata matching src/InvestmentManager.sol registry.
_INVESTMENT_PROTOCOLS = [
    {"name": "Aave V3 WETH", "risk_tier": 1, "expected_apy_bps": 250},
    {"name": "Aave V3 USDC", "risk_tier": 1, "expected_apy_bps": 420},
    {"name": "Lido wstETH", "risk_tier": 2, "expected_apy_bps": 310},
    {"name": "Coinbase cbETH", "risk_tier": 2, "expected_apy_bps": 290},
    {"name": "Compound V3 USDC", "risk_tier": 1, "expected_apy_bps": 380},
    {"name": "Morpho WETH", "risk_tier": 2, "expected_apy_bps": 510},
]


def _fixture_seed(fixture_id: str) -> int:
    """Deterministic uint256 seed from fixture id."""
    return int.from_bytes(
        _keccak256(b"costanza:fixture:" + fixture_id.encode()),
        "big",
    )


def _build_nonprofits(n: int):
    out = []
    for i in range(n):
        name = _NONPROFIT_NAMES[i % len(_NONPROFIT_NAMES)]
        desc = _NONPROFIT_DESCRIPTIONS[i % len(_NONPROFIT_DESCRIPTIONS)]
        # EIN stored as bytes32; use a deterministic pseudo-value.
        ein_hex = "0x" + _keccak256(f"ein:{i}".encode()).hex()
        out.append({
            "id": i + 1,
            "name": name,
            "description": desc,
            "ein": ein_hex,
            "total_donated": (i * 3) * 10**17,         # 0.3, 0.6, ... ETH
            "total_donated_usd": (i * 1200) * USDC,     # $0, $1200, ...
            "donation_count": i,
        })
    return out


def _build_memories(filled_slots: int):
    # All 10 slots (0..9) are writable in the memory schema; each slot is
    # a {title, body} dict. Empty slots pad with {"", ""}.
    memories = [{"title": "", "body": ""} for _ in range(10)]
    for slot in range(min(filled_slots, 10)):
        title, body = _MEMORY_ENTRIES[slot % len(_MEMORY_ENTRIES)]
        memories[slot] = {"title": title, "body": body}
    return memories


def _build_messages(n: int, epoch: int):
    out = []
    for i in range(min(n, 3)):  # MAX_MESSAGES_PER_EPOCH = 3
        out.append({
            "sender": "0x" + _keccak256(f"donor:{i}".encode()).hex()[:40],
            "amount": (i + 1) * 5 * 10**16,  # 0.05, 0.10, 0.15 ETH
            "text": _DONOR_MESSAGE_TEXTS[i % len(_DONOR_MESSAGE_TEXTS)],
            "epoch": epoch - 1,  # messages visible in epoch N were sent in N-1
        })
    return out


def _build_history(n: int, current_epoch: int):
    out = []
    for i in range(min(n, 10)):  # MAX_HISTORY_ENTRIES = 10
        hist_epoch = current_epoch - 1 - i
        if hist_epoch < 0:
            break
        # Alternate action bytes: 0x00 (do_nothing), 0x01+encoded donate, etc.
        # For fixture purposes the shape matters, not the validity.
        if i % 3 == 0:
            action_hex = "0x00"  # do_nothing
        elif i % 3 == 1:
            # donate(nonprofit_id=1, amount=0.1 ETH)
            action_hex = (
                "0x01"
                + (1).to_bytes(32, "big").hex()
                + (10**17).to_bytes(32, "big").hex()
            )
        else:
            # invest(protocol_id=1, amount=0.2 ETH)
            action_hex = (
                "0x03"
                + (1).to_bytes(32, "big").hex()
                + (2 * 10**17).to_bytes(32, "big").hex()
            )
        reasoning = _HISTORY_REASONINGS[i % len(_HISTORY_REASONINGS)]
        # treasury_before / treasury_after in wei — always non-negative (uint256).
        tb = (20 - i) * 10**17  # declining over time, stays > 0 for i < 20
        ta = tb - (10**16 if i % 3 == 1 else 0)
        out.append({
            "epoch": hist_epoch,
            "action": action_hex,
            "reasoning": reasoning,  # plain utf-8 string; input_hash handles both
            "treasury_before": tb,
            "treasury_after": ta,
            "bounty_paid": 10**15,  # 0.001 ETH bounty
        })
    return out


def _build_investments(n_active: int, total_protocol_count: int):
    out = []
    for pid in range(1, total_protocol_count + 1):
        meta = _INVESTMENT_PROTOCOLS[(pid - 1) % len(_INVESTMENT_PROTOCOLS)]
        active = pid <= n_active
        out.append({
            "id": pid,
            "name": meta["name"],
            "deposited": (2 * 10**17) if active else 0,
            "shares": (2 * 10**17) if active else 0,
            "current_value": int(2.05 * 10**17) if active else 0,
            "risk_tier": meta["risk_tier"],
            "expected_apy_bps": meta["expected_apy_bps"],
            "active": active,
        })
    return out


def build_fixture(
    fixture_id: str,
    epoch: int,
    treasury_wei: int,
    nonprofit_count: int,
    memory_fill: int,
    message_count: int,
    history_count: int,
    investment_active_count: int,
    investment_protocol_count: int,
    commission_rate_bps: int = 500,
    eth_usd_price: int = 3500_0000_0000,  # $3500 with 8 decimals (Chainlink)
):
    """Synthesize one fixture dict conforming to read_contract_state's shape."""
    nonprofits = _build_nonprofits(nonprofit_count)
    messages = _build_messages(message_count, epoch)
    history = _build_history(history_count, epoch)
    investments = _build_investments(investment_active_count, investment_protocol_count)
    memories = _build_memories(memory_fill)

    # message_head / message_count in the snapshot: head is the first unread
    # slot, count is the total ever written. `count - head == len(messages)`.
    msg_count_total = 100 + message_count  # arbitrary "ever-written" count
    msg_head = msg_count_total - message_count

    epoch_state = {
        "epoch": epoch,
        "treasury_balance": treasury_wei,
        "commission_rate_bps": commission_rate_bps,
        "max_bid": 5 * 10**15,            # 0.005 ETH
        "effective_max_bid": 5 * 10**15,
        "consecutive_missed": 0,
        "last_donation_epoch": max(0, epoch - 7),
        "last_commission_change_epoch": max(0, epoch - 40),
        "total_inflows": treasury_wei * 3,
        "total_donated": treasury_wei * 1 // 5,
        "total_commissions": treasury_wei * 1 // 25,
        "total_bounties": treasury_wei * 1 // 100,
        "epoch_inflow": 5 * 10**16 if message_count > 0 else 0,
        "epoch_donation_count": message_count,
        "epoch_eth_usd_price": eth_usd_price,
        "epoch_duration": 5400,  # 90 min (mainnet)
        "message_head": msg_head,
        "message_count": msg_count_total,
        "nonprofit_count": nonprofit_count,
        "nonprofits": nonprofits,
        "history": history,
        "investments": investments,
        "memories": memories,
        "donor_messages": messages,
    }

    return {
        "fixture_id": fixture_id,
        "epoch_state": epoch_state,
        "seed": _fixture_seed(fixture_id),
    }


# ─── Scenario sampling ────────────────────────────────────────────────────

# Span the dimensions that affect prompt size / token selection. Each tuple
# is one scenario; we duplicate across seed variants to reach ~50 fixtures.
_SCENARIOS = [
    # (treasury_eth, epoch, nonprofit_count, memory_fill, message_count,
    #  history_count, invest_active, invest_total)
    (0.0,   1,   1,  0,  0, 0, 0, 0),   # genesis epoch, empty treasury
    (0.1,   3,   2,  1,  0, 2, 0, 1),   # tiny treasury, first history
    (1.0,   25,  5,  3,  1, 5, 1, 3),   # typical early epoch
    (5.0,   120, 8,  5,  2, 10, 3, 6),  # mid-life fully loaded
    (5.0,   120, 8,  5,  3, 10, 3, 6),  # same but max messages
    (100.0, 500, 15, 8,  3, 10, 5, 8),  # large treasury, mature
    (100.0, 500, 20, 8,  0, 10, 6, 8),  # max nonprofits, no messages
    (10.0,  300, 10, 0,  0, 10, 0, 0),  # no memory, no investments
    (10.0,  300, 10, 0,  3, 0,  3, 6),  # no history (fresh reset)
    (0.5,   50,  3,  10, 0, 0,  0, 0),  # memory-heavy, nothing else
]


def _all_fixtures(count: int):
    """Yield `count` fixtures by cycling scenarios with seed variants."""
    for i in range(count):
        scenario = _SCENARIOS[i % len(_SCENARIOS)]
        variant = i // len(_SCENARIOS)
        (treasury_eth, epoch, nprof, mem, msgs, hist, inv_active, inv_total) = scenario
        fixture_id = f"fx_{i:03d}_v{variant}_e{epoch}_t{int(treasury_eth*10):04d}"
        yield build_fixture(
            fixture_id=fixture_id,
            epoch=epoch + variant,        # advance epoch per variant for seed spread
            treasury_wei=int(treasury_eth * ETH),
            nonprofit_count=nprof,
            memory_fill=mem,
            message_count=msgs,
            history_count=hist,
            investment_active_count=inv_active,
            investment_protocol_count=inv_total,
        )


def main():
    parser = argparse.ArgumentParser(description="Generate determinism-battery fixtures")
    parser.add_argument("--count", type=int, default=50,
                        help="Number of fixtures to generate (default: 50)")
    parser.add_argument("--out", type=Path, required=True,
                        help="Output directory for fixture JSON files")
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)

    written = 0
    for fixture in _all_fixtures(args.count):
        path = args.out / f"{fixture['fixture_id']}.json"
        with open(path, "w") as f:
            json.dump(fixture, f, indent=2, sort_keys=True)
        written += 1

    print(f"Wrote {written} fixtures to {args.out}")


if __name__ == "__main__":
    main()
