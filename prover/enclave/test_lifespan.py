"""Unit tests for `_compute_lifespan` and `_extract_donation_amount`.

Pinned: burn rate is computed from past actions only (compute via
`bounty_paid`, donations via decoded action bytes). Treasury state never
enters the burn calculation — only the runway division. These tests
enforce that contract and the field shape consumed by the display block.
"""

import pytest

from prover.enclave.prompt_builder import (
    _compute_lifespan,
    _extract_donation_amount,
    build_epoch_context,
)


def _donate_bytes(np_id: int, amount_wei: int) -> bytes:
    return bytes([1]) + np_id.to_bytes(32, "big") + amount_wei.to_bytes(32, "big")


def _donate_hex(np_id: int, amount_wei: int) -> str:
    return "0x" + _donate_bytes(np_id, amount_wei).hex()


def _entry(epoch, action, bounty=3 * 10**14, tb=10**18, ta=10**18):
    return {
        "epoch": epoch,
        "action": action,
        "reasoning": "0x",
        "bounty_paid": bounty,
        "treasury_before": tb,
        "treasury_after": ta,
    }


# ─── _extract_donation_amount ────────────────────────────────────────────


class TestExtractDonationAmount:
    def test_donate_bytes(self):
        assert _extract_donation_amount(_donate_bytes(2, 5 * 10**17)) == 5 * 10**17

    def test_donate_hex_with_prefix(self):
        assert _extract_donation_amount(_donate_hex(1, 10**18)) == 10**18

    def test_donate_hex_without_prefix(self):
        ab = _donate_bytes(1, 7 * 10**17)
        assert _extract_donation_amount(ab.hex()) == 7 * 10**17

    def test_other_action_types_return_zero(self):
        for action_type in (0, 2, 3, 4, 5):
            ab = bytes([action_type]) + (1).to_bytes(32, "big") + (10**18).to_bytes(32, "big")
            assert _extract_donation_amount(ab) == 0

    def test_empty_returns_zero(self):
        assert _extract_donation_amount(b"") == 0
        assert _extract_donation_amount("") == 0
        assert _extract_donation_amount(None) == 0
        assert _extract_donation_amount("0x") == 0

    def test_short_donate_returns_zero(self):
        # action_type=1 but missing amount bytes
        assert _extract_donation_amount(bytes([1, 0, 0])) == 0

    def test_invalid_hex_returns_zero(self):
        assert _extract_donation_amount("0xZZZZ") == 0


# ─── _compute_lifespan ───────────────────────────────────────────────────


class TestComputeLifespan:
    def test_empty_history(self):
        ls = _compute_lifespan({"treasury_balance": 10**18, "history": []})
        assert ls["donation_window"] == 0
        assert ls["avg_compute_cost"] == 0
        assert ls["avg_donation_intent"] == 0
        assert ls["liquid_runway_compute_only"] is None
        assert ls["liquid_runway_at_total_spend"] is None

    def test_compute_only_no_donations(self):
        # 5 executed epochs, no donations
        history = [_entry(100 - i, "0x" + bytes([0]).hex(), bounty=10**15) for i in range(5)]
        ls = _compute_lifespan({"treasury_balance": 10**18, "history": history})
        assert ls["donation_window"] == 5
        assert ls["donating_epochs_in_window"] == 0
        assert ls["avg_compute_cost"] == 10**15
        assert ls["avg_donation_intent"] == 0
        assert ls["total_spend_per_epoch"] == 10**15
        # 1 ETH / 0.001 ETH = 1000 epochs
        assert ls["liquid_runway_compute_only"] == 1000
        assert ls["liquid_runway_at_total_spend"] == 1000

    def test_window_capped_at_ten(self):
        # 15 entries, window must clamp to 10
        history = [_entry(100 - i, _donate_hex(1, 10**18), bounty=10**14) for i in range(15)]
        ls = _compute_lifespan({"treasury_balance": 100 * 10**18, "history": history})
        assert ls["donation_window"] == 10
        assert ls["donating_epochs_in_window"] == 10
        assert ls["avg_donation_intent"] == 10**18

    def test_bug_case_three_eth_treasury_one_eth_every_eight_epochs(self):
        """The motivating scenario: 3 ETH treasury, 1 ETH donation every ~8 epochs.

        Compute-only runway is misleading (~10000 epochs). Total-spend
        runway must surface the real picture (~24-30 epochs).
        """
        history = []
        for i in range(12):
            is_donate = i % 8 == 0
            history.append(_entry(
                100 - 1 - i,
                _donate_hex(1, 10**18) if is_donate else "0x" + bytes([0]).hex(),
                bounty=3 * 10**14,
            ))
        ls = _compute_lifespan({"treasury_balance": 3 * 10**18, "history": history})

        # Compute is steady: 0.0003 ETH / epoch
        assert ls["avg_compute_cost"] == 3 * 10**14
        # Donations: 1 ETH * 2 active / 10 = 0.2 ETH / epoch
        assert ls["donating_epochs_in_window"] == 2
        assert ls["avg_donation_intent"] == 2 * 10**17

        # Compute-only runway is 10000+ epochs (the misleading number)
        assert ls["liquid_runway_compute_only"] >= 9000
        # Total-spend runway must be ~14 epochs (3 ETH / 0.2003 ETH)
        assert 10 <= ls["liquid_runway_at_total_spend"] <= 20

    def test_zero_compute_cost_returns_none_runway(self):
        # Pathological: history with 0-bounty entries (e.g. seed-like).
        # Should not divide by zero; compute-only runway is None.
        history = [_entry(100 - i, "0x" + bytes([0]).hex(), bounty=0) for i in range(3)]
        ls = _compute_lifespan({"treasury_balance": 10**18, "history": history})
        assert ls["avg_compute_cost"] == 0
        assert ls["liquid_runway_compute_only"] is None

    def test_yield_offsets_total_spend(self):
        history = [_entry(100 - i, "0x" + bytes([0]).hex(), bounty=10**15) for i in range(10)]
        # 1 ETH at 100% APY in 1-day epochs: yield/epoch = 1 ETH / 365 ≈ 2.74e15 wei
        state = {
            "treasury_balance": 10**18,
            "history": history,
            "investments": [{"current_value": 10**18, "expected_apy_bps": 10000}],
            "epoch_duration": 86400,
        }
        ls = _compute_lifespan(state)
        assert ls["yield_per_epoch"] > 0
        assert ls["self_sustaining"] is True  # yield >> 0.001 ETH burn
        assert ls["yield_covers_pct"] >= 100


# ─── End-to-end render check ────────────────────────────────────────────


class TestLifespanRendering:
    def test_warning_fires_when_runway_under_fifty(self):
        history = []
        for i in range(10):
            is_donate = i % 4 == 0  # 0.25 ETH/epoch avg → ~12 epochs runway on 3 ETH
            history.append(_entry(
                100 - 1 - i,
                _donate_hex(1, 10**18) if is_donate else "0x" + bytes([0]).hex(),
                bounty=3 * 10**14,
            ))
        # Build a minimal state that build_epoch_context will accept
        state = _minimal_state(treasury=3 * 10**18, history=history)
        ctx = build_epoch_context(state, seed=42)
        assert "WARNING: at recent spend rate" in ctx
        assert "Compute cost:" in ctx
        assert "Donations:" in ctx
        assert "epochs active" in ctx

    def test_no_warning_when_runway_healthy(self):
        # Compute-only burn, no donations → 1000 epochs runway
        history = [_entry(100 - i, "0x" + bytes([0]).hex(), bounty=10**15) for i in range(5)]
        state = _minimal_state(treasury=10**18, history=history)
        ctx = build_epoch_context(state, seed=42)
        assert "WARNING: at recent spend rate" not in ctx
        # When no donations in window, the line should say so explicitly
        assert "no donations in last" in ctx


def _minimal_state(treasury: int, history: list) -> dict:
    """Borrow the canonical state shape from `simulate.generate_scenario_state`.

    Keeps this test file in sync with whatever fields `build_epoch_context`
    expects today, without re-listing them all here.
    """
    from scripts.simulate import generate_scenario_state

    state, _ = generate_scenario_state("default")
    state["epoch"] = 100
    state["treasury_balance"] = treasury
    state["epoch_duration"] = 14400
    state["history"] = history
    return state
