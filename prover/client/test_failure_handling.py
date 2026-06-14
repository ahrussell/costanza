#!/usr/bin/env python3
"""Tests for submission failure classification + the verification halt breaker.

Regression coverage for the 2026-06 incident: GCP rolled out new TD firmware,
the MRTD (and thus the dm-verity image key) drifted, and every
submitAuctionResult reverted on-chain with ProofFailed. The mined revert tx
carries no reason, so the client mislabeled it as a transient "dcap_revert",
retried 3x (re-booting the H100 twice), then forfeited a bond — every epoch.

The fix: (1) send_tx replays the calldata via eth_call to recover the revert
selector, so ProofFailed is recognized and classified non-retryable; (2) a
persistent circuit breaker stops committing after a deterministic verification
failure instead of bleeding a fresh bond each epoch.

Run: python -m pytest prover/client/test_failure_handling.py -v
"""

from pathlib import Path

import pytest

pytest.importorskip("web3")

# auction.py builds its error-selector map from forge artifacts at import time.
_ART = Path(__file__).resolve().parents[2] / "out" / "TheHumanFund.sol" / "TheHumanFund.json"
if not _ART.exists():
    pytest.skip("forge artifacts missing — run `forge build`", allow_module_level=True)

from web3.exceptions import ContractCustomError, ContractLogicError  # noqa: E402

from prover.client.auction import (  # noqa: E402
    classify_submit_error, HALTING_CATEGORIES, ERROR_SELECTORS,
)
from prover.client.chain import ChainClient  # noqa: E402
from prover.client import state as state_mod  # noqa: E402

# keccak256("ProofFailed()")[:4] — the selector seen in the live failed txns.
PROOF_FAILED_SELECTOR = "0x8dce8175"


# ─── classify_submit_error ───────────────────────────────────────────────

def test_proof_failed_selector_is_in_map():
    """Sanity: the ProofFailed selector resolves to the right error name."""
    assert ERROR_SELECTORS.get(PROOF_FAILED_SELECTOR) == "ProofFailed"


def test_decoded_proof_failed_is_non_retryable():
    """The whole point: once send_tx appends the decoded selector, a mined
    ProofFailed revert classifies as proof_failed and is NOT retried."""
    err = RuntimeError(
        "Transaction reverted on-chain: tx=0xabc, gas_used=5221685, "
        f"revert={PROOF_FAILED_SELECTOR}"
    )
    category, should_retry, _ = classify_submit_error(err)
    assert category == "proof_failed"
    assert should_retry is False
    assert category in HALTING_CATEGORIES


def test_undecoded_revert_falls_back_to_retryable():
    """When the selector can't be recovered, keep the conservative
    'assume transient, retry' fallback — but it must NOT halt."""
    err = RuntimeError("Transaction reverted on-chain: tx=0xabc, gas_used=5221685")
    category, should_retry, _ = classify_submit_error(err)
    assert category == "dcap_revert"
    assert should_retry is True
    assert category not in HALTING_CATEGORIES


def test_timing_error_is_expected_non_retryable():
    """A decoded TimingError (window expired) is a benign non-retry, not a halt."""
    timing_selector = next(s for s, n in ERROR_SELECTORS.items() if n == "TimingError")
    err = RuntimeError(f"Transaction reverted on-chain: tx=0xabc, revert={timing_selector}")
    category, should_retry, _ = classify_submit_error(err)
    assert category == "timing_expired"
    assert should_retry is False
    assert category not in HALTING_CATEGORIES


# ─── ChainClient._decode_revert_reason ───────────────────────────────────

class _FakeEth:
    def __init__(self, exc=None):
        self._exc = exc

    def call(self, call, block_identifier=None):
        if self._exc is not None:
            raise self._exc
        return b""  # replay didn't revert


class _FakeW3:
    def __init__(self, exc=None):
        self.eth = _FakeEth(exc)


def _bare_client(exc):
    """A ChainClient with its w3 stubbed — bypasses __init__ (no RPC/keys)."""
    c = object.__new__(ChainClient)
    c.w3 = _FakeW3(exc)
    return c


_TX = {"from": "0x1", "to": "0x2", "data": "0xdeadbeef", "value": 0, "gas": 100}


def test_decode_revert_reason_custom_error_via_data_attr():
    e = ContractCustomError("execution reverted")
    e.data = PROOF_FAILED_SELECTOR
    suffix = _bare_client(e)._decode_revert_reason(_TX, 123)
    assert PROOF_FAILED_SELECTOR in suffix
    assert suffix.startswith(", revert=")


def test_decode_revert_reason_logic_error_via_str():
    suffix = _bare_client(ContractLogicError(PROOF_FAILED_SELECTOR))._decode_revert_reason(_TX, 123)
    assert PROOF_FAILED_SELECTOR in suffix


def test_decode_revert_reason_empty_when_replay_succeeds():
    # No exception → replay didn't revert → nothing to report.
    assert _bare_client(None)._decode_revert_reason(_TX, 123) == ""


def test_decode_revert_reason_swallows_rpc_errors():
    # An unexpected RPC failure must not mask the original revert.
    assert _bare_client(Exception("RPC down"))._decode_revert_reason(_TX, 123) == ""


# ─── halt state helpers ──────────────────────────────────────────────────

def test_halt_roundtrip_and_clear(tmp_path):
    assert state_mod.load_halt(tmp_path) is None
    rec = {"epoch": 198, "category": "proof_failed", "message": "x", "notified": False}
    state_mod.save_halt(rec, tmp_path)
    loaded = state_mod.load_halt(tmp_path)
    assert loaded["epoch"] == 198 and loaded["category"] == "proof_failed"
    state_mod.clear_halt(tmp_path)
    assert state_mod.load_halt(tmp_path) is None


def test_halt_survives_epoch_state_clear(tmp_path):
    """The halt must outlive per-epoch state.json clears (epoch rollover)."""
    state_mod.save({"epoch": 1, "committed": True}, tmp_path)
    state_mod.save_halt({"epoch": 1, "category": "proof_failed"}, tmp_path)
    state_mod.clear(tmp_path)  # epoch rollover wipes state.json + tee results
    assert state_mod.load(tmp_path) == {}
    assert state_mod.load_halt(tmp_path) is not None  # ...but NOT the halt


def test_clear_halt_idempotent(tmp_path):
    state_mod.clear_halt(tmp_path)  # no file — must not raise
    state_mod.clear_halt(tmp_path)
