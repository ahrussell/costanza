"""Behavioral tests for `validate_and_clamp_action`.

Pinned threat model: the encoder runs inside the dm-verity enclave on a
JSON state dict supplied by the (untrusted) prover. Every field the
encoder reads must either (a) be bound into the input hash, or (b) be
position-derived from a hashed structure.

`inv["id"]` is *not* in the hash — `_hash_investments` keys on positional
`i = idx + 1` and never hashes the `id` field. So a runner can permute
`id` labels in the JSON without breaking hash verification. Any encoder
read keyed on `inv["id"]` is therefore runner-controlled and unsafe.

These tests pin the encoder's clamping output to the position-derived
view of the investment list, so future regressions on this axis fail
loudly.
"""

from .action_encoder import validate_and_clamp_action


# ─── Fixture ──────────────────────────────────────────────────────────────

# Treasury sized so the per-protocol cap is well below the per-epoch
# investment capacity — the resulting `hard_cap` is therefore set by the
# per-protocol math, which is exactly the path under attack.
_TREASURY_WEI = 10 * 10**18              # 10 ETH liquid
_POSITION_WEI = 2_500_000_000_000_000_000  # 2.5 ETH already in protocol 1


def _state(investments):
    """Minimal epoch-state dict that satisfies _compute_action_bounds.

    Only the fields the bounds helper and encoder actually read need real
    values; the rest are stubs.
    """
    return {
        "treasury_balance": _TREASURY_WEI,
        "effective_max_bid": 10**16,        # 0.01 ETH — small, doesn't dominate
        "commission_rate_bps": 500,
        "investments": investments,
        "nonprofits": [],
        "messages": [],
        "history": [],
        "memory": [],
        "eth_usd_price": 0,
    }


def _investment(*, current_value, name, id_label, active=True):
    """Build a single investment entry. `id_label` is the field under attack —
    the runner can set it to any value without breaking the input hash."""
    return {
        "id": id_label,
        "name": name,
        "current_value": current_value,
        "shares": current_value,            # 1:1 mock; not hashed-relevant here
        "deposited": current_value,
        "active": active,
        "risk_tier": 1,
        "expected_apy_bps": 400,
    }


def _honest_state():
    """Position N has id=N (the on-chain registry's own ordering)."""
    return _state([
        _investment(current_value=_POSITION_WEI, name="Aave V3 USDC", id_label=1),
        _investment(current_value=0,             name="Lido wstETH",  id_label=2),
    ])


def _adversarial_state():
    """Identical hashed fields, only the `id` labels are permuted.

    Position 0 still represents on-chain protocol 1 (Aave, full); position
    1 still represents protocol 2 (Lido, empty). Their `name`,
    `current_value`, etc. are unchanged. Only the `id` field is swapped —
    the one field the input hash never reads.
    """
    return _state([
        _investment(current_value=_POSITION_WEI, name="Aave V3 USDC", id_label=2),
        _investment(current_value=0,             name="Lido wstETH",  id_label=1),
    ])


# ─── Invest tests ─────────────────────────────────────────────────────────


def test_invest_clamp_resists_id_swap():
    """Encoder's invest-clamp output must not depend on `inv["id"]`.

    Model picks invest(2, 1.0 ETH) — protocol 2 (Lido) is empty in both
    states, so the action should pass through unchanged. The adversarial
    state misdirects an `id`-keyed lookup to the full position, causing
    the encoder to over-clamp the deposit.
    """
    action = lambda: {
        "action": "invest",
        "params": {"protocol_id": 2, "amount_eth": 1.0},
    }

    honest_out, _ = validate_and_clamp_action(action(), _honest_state())
    advers_out, _ = validate_and_clamp_action(action(), _adversarial_state())

    assert honest_out == advers_out, (
        "encoder produced different invest output for two states with "
        "identical input hashes — the only difference is the un-hashed "
        "`id` field, which a runner can freely permute. Outputs:\n"
        f"  honest:      {honest_out}\n"
        f"  adversarial: {advers_out}"
    )


def test_invest_clamp_uses_position_for_existing_amount():
    """Even with `id` fields entirely absent, the clamp must work.

    Confirms the encoder reads `current_value` from
    `state["investments"][protocol_id - 1]`, not from any entry whose `id`
    field happens to match. Layout chosen so pre-fix and post-fix diverge:
    the targeted positional slot is the FULL one, so a position-blind
    encoder over-clamps headroom and lets the requested amount pass
    unchanged, while the position-aware encoder clamps it down.
    """
    investments = [
        _investment(current_value=0,             name="Aave V3 USDC", id_label=1),
        _investment(current_value=_POSITION_WEI, name="Lido wstETH",  id_label=2),
    ]
    # Strip the `id` field from every entry — what the encoder *should* be
    # using is the array index, not this label.
    for inv in investments:
        del inv["id"]
    state = _state(investments)

    out, _ = validate_and_clamp_action(
        {"action": "invest", "params": {"protocol_id": 2, "amount_eth": 1.0}},
        state,
    )

    # Position 2 already holds 2.5 ETH; the per-protocol cap (~25% of
    # total assets, with a 5% safety margin) leaves <1 ETH of room, so
    # the encoder must clamp the 1.0 ETH request down or downgrade.
    assert out["action"] in ("invest", "do_nothing")
    if out["action"] == "invest":
        assert out["params"]["amount_eth"] < 1.0, (
            f"expected invest amount clamped below 1.0 ETH "
            f"(positional slot 2 already holds 2.5 ETH), "
            f"got {out['params']['amount_eth']}"
        )


# ─── Withdraw tests ───────────────────────────────────────────────────────


def test_withdraw_clamp_resists_id_swap():
    """Encoder's withdraw-clamp output must not depend on `inv["id"]`.

    Model picks withdraw(1, 5.0 ETH) — protocol 1 (Aave) holds 2.5 ETH.
    Honest state clamps to 2.5 ETH (the full position). Adversarial state
    misdirects the `id`-keyed lookup to the empty position, causing the
    encoder to incorrectly downgrade to do_nothing.
    """
    action = lambda: {
        "action": "withdraw",
        "params": {"protocol_id": 1, "amount_eth": 5.0},
    }

    honest_out, _ = validate_and_clamp_action(action(), _honest_state())
    advers_out, _ = validate_and_clamp_action(action(), _adversarial_state())

    assert honest_out == advers_out, (
        "encoder produced different withdraw output for two states with "
        "identical input hashes — the only difference is the un-hashed "
        "`id` field. Outputs:\n"
        f"  honest:      {honest_out}\n"
        f"  adversarial: {advers_out}"
    )


def test_withdraw_clamp_uses_position_for_existing_amount():
    """Even with `id` fields entirely absent, the withdraw clamp must work.

    Layout chosen so pre-fix and post-fix diverge: the targeted positional
    slot is FULL. A position-blind encoder fails the existing-position
    lookup, sees `position_wei == 0`, and downgrades to do_nothing. A
    position-aware encoder finds the real position and clamps the
    requested withdraw to it.
    """
    investments = [
        _investment(current_value=0,             name="Aave V3 USDC", id_label=1),
        _investment(current_value=_POSITION_WEI, name="Lido wstETH",  id_label=2),
    ]
    for inv in investments:
        del inv["id"]
    state = _state(investments)

    out, _ = validate_and_clamp_action(
        {"action": "withdraw", "params": {"protocol_id": 2, "amount_eth": 5.0}},
        state,
    )

    # Position 2 holds 2.5 ETH; a 5.0 ETH withdraw should clamp down to
    # the full-position amount. The encoder must NOT downgrade to
    # do_nothing — that would be the position-blind result.
    assert out["action"] == "withdraw", (
        f"expected withdraw to pass through (clamped) for full positional "
        f"slot 2, got {out['action']}"
    )
    assert abs(out["params"]["amount_eth"] - 2.5) < 1e-9, (
        f"expected withdraw clamped to 2.5 ETH (full position), "
        f"got {out['params']['amount_eth']}"
    )
