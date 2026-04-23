#!/usr/bin/env python3
"""Tests for chatml_prompt_builder + chatml_inference (mocked llama-server)."""

import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_REPO_ROOT))

from experiments.chatml.chatml_prompt_builder import (
    build_messages,
    render_system_message,
    render_voice_anchor_pairs,
    render_epoch_user_turn,
    render_history_pairs,
    ACTION_USER_PROMPT,
)
from experiments.chatml.chatml_inference import run_chat_two_pass


# --- Sample fixtures ---

SYSTEM_PROMPT_FIXTURE = """# A. WHO YOU ARE
You are Costanza.

Some operating rules.

Sample diaries follow — these are reference examples of the voice, not your real history.
"""

ANCHORS_FIXTURE = """Some header text.

─── Sample 1 ──────
**Scenario:** A quiet day, no donor messages.

<diary>
First sample. Quiet day.
</diary>
──────

─── Sample 2 ──────
**Scenario:** A donor sent 0.05 ETH with a question about AMF.

<diary>
Second sample. Engaged with AMF question.
</diary>
──────

─── Sample 3 ──────
**Scenario:** Investment yield came in.

<diary>
Third sample. Yield commentary.
</diary>
──────
"""


def _minimal_state(epoch=1):
    """Minimal flat state dict that build_epoch_context can consume."""
    return {
        "epoch": epoch,
        "treasury_balance": int(1e18),  # 1 ETH
        "commission_rate_bps": 1000,
        "max_bid": int(1e15),
        "effective_max_bid": int(1e15),
        "deploy_timestamp": 0,
        "total_inflows": int(1e18),
        "total_donated": 0,
        "total_commissions": 0,
        "total_bounties": 0,
        "last_donation_epoch": 0,
        "last_commission_change_epoch": 0,
        "consecutive_missed": 0,
        "epoch_inflow": 0,
        "epoch_donation_count": 0,
        "nonprofits": [
            {"id": 1, "name": "GiveDirectly", "address": "0x1", "total_donated": 0,
             "donation_count": 0, "total_donated_usd": 0},
        ],
        "history": [],
        "snapshots": [],
        "investments": [],
        "total_invested": 0,
        "total_assets": int(1e18),
        "memories": [{"title": "", "body": ""} for _ in range(10)],
        "donor_messages": [],
        "message_count": 0,
        "message_head": 0,
        "epoch_eth_usd_price": int(1660 * 1e8),
        "epoch_duration": 86400,
    }


# --- Tests ---

class TestSystemMessage(unittest.TestCase):
    def test_drops_sample_diaries_trailer(self):
        out = render_system_message(SYSTEM_PROMPT_FIXTURE)
        self.assertNotIn("Sample diaries follow", out)
        self.assertIn("You are Costanza.", out)

    def test_preserves_rest_of_content(self):
        out = render_system_message(SYSTEM_PROMPT_FIXTURE)
        self.assertIn("Some operating rules.", out)


class TestAnchorPairs(unittest.TestCase):
    def setUp(self):
        from prover.enclave.voice_anchors import parse_anchors
        self.header, self.samples = parse_anchors(ANCHORS_FIXTURE)

    def test_emits_pairs(self):
        pairs = render_voice_anchor_pairs(
            self.header, self.samples, seed=42, k=3,
        )
        # 3 samples × 2 messages each = 6 messages
        self.assertEqual(len(pairs), 6)
        # Alternates user/assistant
        for i, m in enumerate(pairs):
            expected = "user" if i % 2 == 0 else "assistant"
            self.assertEqual(m["role"], expected)

    def test_no_diary_tags_in_assistant(self):
        pairs = render_voice_anchor_pairs(
            self.header, self.samples, seed=42, k=3,
        )
        for m in pairs:
            if m["role"] == "assistant":
                self.assertNotIn("<diary>", m["content"])
                self.assertNotIn("</diary>", m["content"])

    def test_seed_deterministic(self):
        a = render_voice_anchor_pairs(self.header, self.samples, seed=7, k=2)
        b = render_voice_anchor_pairs(self.header, self.samples, seed=7, k=2)
        self.assertEqual(a, b)


class TestEpochUserTurn(unittest.TestCase):
    def test_no_voice_anchors_inline(self):
        state = _minimal_state(epoch=5)
        out = render_epoch_user_turn(state, seed=1)
        self.assertNotIn("SAMPLE DIARIES", out)
        self.assertNotIn("FICTIONAL VOICE REFERENCE", out)

    def test_no_your_turn_section(self):
        state = _minimal_state(epoch=5)
        out = render_epoch_user_turn(state, seed=1)
        self.assertNotIn("=== YOUR TURN ===", out)

    def test_includes_diary_request(self):
        state = _minimal_state(epoch=5)
        out = render_epoch_user_turn(state, seed=1)
        self.assertIn("Write your diary entry", out)

    def test_includes_state_data(self):
        state = _minimal_state(epoch=5)
        out = render_epoch_user_turn(state, seed=1)
        self.assertIn("EPOCH 5", out)


class TestBuildMessages(unittest.TestCase):
    def test_full_assembly_no_history(self):
        state = _minimal_state(epoch=10)
        msgs = build_messages(
            state=state, seed=42,
            system_prompt_text=SYSTEM_PROMPT_FIXTURE,
            voice_anchors_text=ANCHORS_FIXTURE,
            history_mode="none",
        )
        # 1 system + 6 anchor messages (3 pairs) + 1 epoch user = 8
        self.assertEqual(len(msgs), 8)
        self.assertEqual(msgs[0]["role"], "system")
        self.assertEqual(msgs[-1]["role"], "user")

    def test_history_mode_with_no_history_data_is_empty(self):
        state = _minimal_state(epoch=10)
        msgs = build_messages(
            state=state, seed=42,
            system_prompt_text=SYSTEM_PROMPT_FIXTURE,
            voice_anchors_text=ANCHORS_FIXTURE,
            history_mode="past_pairs",
        )
        # state.history is empty, so no past pairs added
        self.assertEqual(len(msgs), 8)

    def test_history_pairs_when_data_present(self):
        state = _minimal_state(epoch=10)
        # Seed 2 prior epochs into history. prompt_builder's history
        # renderer requires action + treasury_before/after fields.
        state["history"] = [
            {
                "epoch": 8, "diary": "Epoch 8 diary content here.",
                "action": b"\x00",  # do_nothing
                "treasury_before": int(1e18), "treasury_after": int(1e18),
            },
            {
                "epoch": 9, "diary": "Epoch 9 diary content.",
                "action": b"\x00",
                "treasury_before": int(1e18), "treasury_after": int(1e18),
            },
        ]

        snapshots = {
            8: dict(_minimal_state(epoch=8), history=state["history"][:1]),
            9: dict(_minimal_state(epoch=9), history=state["history"][:2]),
        }

        msgs = build_messages(
            state=state, seed=42,
            system_prompt_text=SYSTEM_PROMPT_FIXTURE,
            voice_anchors_text=ANCHORS_FIXTURE,
            history_mode="past_pairs",
            history_limit=5,
            state_at_epoch_fn=lambda e: snapshots.get(e),
        )
        # 1 system + 6 anchor + 4 history (2 pairs) + 1 epoch = 12
        self.assertEqual(len(msgs), 12)


# --- Mock llama-server ---

def _mock_chat_response(content, prompt_tokens=100, completion_tokens=50):
    return {
        "choices": [{
            "message": {"role": "assistant", "content": content},
            "finish_reason": "stop",
        }],
        "usage": {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
        },
    }


class TestChatTwoPass(unittest.TestCase):
    @patch("experiments.chatml.chatml_inference.urlopen")
    def test_two_passes_called_with_correct_endpoint_and_messages(self, mock_urlopen):
        from io import BytesIO
        responses = [
            BytesIO(json.dumps(_mock_chat_response("A real diary entry here.")).encode()),
            BytesIO(json.dumps(_mock_chat_response('{"action": "do_nothing", "params": {}}')).encode()),
        ]
        mock_urlopen.side_effect = responses

        msgs = [
            {"role": "system", "content": "you are X"},
            {"role": "user", "content": "epoch context"},
        ]
        result = run_chat_two_pass(msgs, seed=42)

        # Two HTTP calls
        self.assertEqual(mock_urlopen.call_count, 2)
        # Both hit /v1/chat/completions
        for call in mock_urlopen.call_args_list:
            req = call[0][0]
            self.assertIn("/v1/chat/completions", req.full_url)

        # Pass 1 sent the original 2 messages
        pass1_body = json.loads(mock_urlopen.call_args_list[0][0][0].data)
        self.assertEqual(len(pass1_body["messages"]), 2)
        self.assertEqual(pass1_body["temperature"], 0.85)

        # Pass 2 sent original + assistant + action prompt user
        pass2_body = json.loads(mock_urlopen.call_args_list[1][0][0].data)
        self.assertEqual(len(pass2_body["messages"]), 4)
        self.assertEqual(pass2_body["messages"][2]["role"], "assistant")
        self.assertEqual(pass2_body["messages"][2]["content"], "A real diary entry here.")
        self.assertEqual(pass2_body["messages"][3]["role"], "user")
        self.assertIn("action JSON", pass2_body["messages"][3]["content"])
        self.assertEqual(pass2_body["temperature"], 0.3)
        # Grammar SHOULD be set on pass 2 (loaded from action_grammar_chatml.gbnf)
        self.assertIn("grammar", pass2_body)

        self.assertEqual(result["diary"], "A real diary entry here.")
        self.assertEqual(result["parsed_action"]["action"], "do_nothing")
        self.assertEqual(result["pass1_attempts"], 1)

    @patch("experiments.chatml.chatml_inference.urlopen")
    def test_retry_fires_on_empty_diary(self, mock_urlopen):
        from io import BytesIO
        responses = [
            BytesIO(json.dumps(_mock_chat_response("")).encode()),
            BytesIO(json.dumps(_mock_chat_response("Now real diary content.")).encode()),
            BytesIO(json.dumps(_mock_chat_response('{"action": "do_nothing", "params": {}}')).encode()),
        ]
        mock_urlopen.side_effect = responses

        msgs = [{"role": "user", "content": "go"}]
        result = run_chat_two_pass(msgs, seed=42)

        self.assertEqual(result["pass1_attempts"], 2)
        self.assertEqual(result["diary"], "Now real diary content.")

    @patch("experiments.chatml.chatml_inference.urlopen")
    def test_strips_diary_tags_if_model_echoes_them(self, mock_urlopen):
        from io import BytesIO
        responses = [
            BytesIO(json.dumps(_mock_chat_response("<diary>Real content here.</diary>")).encode()),
            BytesIO(json.dumps(_mock_chat_response('{"action": "do_nothing", "params": {}}')).encode()),
        ]
        mock_urlopen.side_effect = responses

        msgs = [{"role": "user", "content": "go"}]
        result = run_chat_two_pass(msgs, seed=42)

        self.assertEqual(result["diary"], "Real content here.")
        self.assertNotIn("<diary>", result["diary"])


if __name__ == "__main__":
    unittest.main()
