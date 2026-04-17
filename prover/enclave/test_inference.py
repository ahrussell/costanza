#!/usr/bin/env python3
"""Tests for three-pass inference and related utilities.

These tests mock the llama-server to verify:
1. Three-pass prompt construction (think -> diary -> action)
2. Temperature and stop token settings per pass
3. Return value structure (thinking, reasoning/diary, action_text)
4. Truncation of reasoning at MAX_REASONING_BYTES
5. Backward compatibility of run_two_pass_inference alias
6. Integration with parse_action (diary text + JSON action)
"""

import unittest
from unittest.mock import patch, MagicMock
import json

from .inference import (
    run_three_pass_inference,
    run_two_pass_inference,
    truncate_reasoning,
    strip_diary_stray_tags,
    MAX_REASONING_BYTES,
)
from .action_encoder import parse_action


def make_llama_response(text, prompt_tokens=100, completion_tokens=50):
    """Build a mock response matching llama-server /v1/completions format."""
    return {
        "text": text,
        "finish_reason": "stop",
        "elapsed_seconds": 1.0,
        "tokens": {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
        },
    }


class TestThreePassInference(unittest.TestCase):
    """Test three-pass inference prompt construction and result assembly."""

    @patch("prover.enclave.inference.call_llama")
    def test_three_passes_called_with_correct_prompts(self, mock_call):
        """Verify each pass builds the right prompt with correct params."""
        mock_call.side_effect = [
            make_llama_response("I should donate to charity"),       # Pass 1: thinking
            make_llama_response("Today I give with joy in my heart"), # Pass 2: diary
            make_llama_response('"action": "noop", "params": {}}'),   # Pass 3: action
        ]

        prompt = "<think>\n"
        result = run_three_pass_inference(prompt, seed=42)

        # Should be called exactly 3 times
        self.assertEqual(mock_call.call_count, 3)

        # Pass 1: thinking
        args1, kwargs1 = mock_call.call_args_list[0]
        self.assertEqual(args1[0], prompt)
        self.assertEqual(kwargs1["temperature"], 0.7)
        self.assertEqual(kwargs1["stop"], ["</think>"])
        self.assertEqual(kwargs1["seed"], 42)
        self.assertEqual(kwargs1["max_tokens"], 2048)

        # Pass 2: diary
        args2, kwargs2 = mock_call.call_args_list[1]
        self.assertIn("I should donate to charity", args2[0])
        # Diary nudge text is injected between </think> and <diary> to
        # anchor voice before generation — just verify the tags surround it.
        self.assertIn("</think>", args2[0])
        self.assertIn("<diary>", args2[0])
        self.assertLess(args2[0].index("</think>"), args2[0].index("<diary>"))
        self.assertEqual(kwargs2["temperature"], 0.8)
        self.assertEqual(kwargs2["stop"], ["</diary>"])
        self.assertEqual(kwargs2["max_tokens"], 1024)

        # Pass 3: action JSON
        args3, kwargs3 = mock_call.call_args_list[2]
        self.assertIn("Today I give with joy in my heart", args3[0])
        self.assertIn("</diary>\n{", args3[0])
        self.assertEqual(kwargs3["temperature"], 0.3)
        self.assertEqual(kwargs3["stop"], ["\n\n"])
        self.assertEqual(kwargs3["max_tokens"], 256)

    @patch("prover.enclave.inference.call_llama")
    def test_result_structure(self, mock_call):
        """Verify the return dict has all expected keys with correct values."""
        mock_call.side_effect = [
            make_llama_response("analytical thinking here"),
            make_llama_response("poetic diary entry here"),
            make_llama_response('"action": "noop", "params": {}}'),
        ]

        result = run_three_pass_inference("<think>\n", seed=1)

        self.assertEqual(result["thinking"], "analytical thinking here")
        self.assertEqual(result["reasoning"], "poetic diary entry here")
        self.assertIn('"action": "noop"', result["action_text"])
        self.assertTrue(result["action_text"].startswith("{"))
        self.assertEqual(result["elapsed_seconds"], 3.0)  # 3 passes x 1s each
        self.assertEqual(result["tokens"]["prompt_tokens"], 300)
        self.assertEqual(result["tokens"]["completion_tokens"], 150)

    @patch("prover.enclave.inference.call_llama")
    def test_text_field_contains_diary_and_action(self, mock_call):
        """The 'text' field should contain diary + </diary> + action for parse_action."""
        mock_call.side_effect = [
            make_llama_response("thinking"),
            make_llama_response("my diary"),
            make_llama_response('"action": "donate", "params": {"nonprofit_id": 1, "amount_eth": 0.5}}'),
        ]

        result = run_three_pass_inference("<think>\n")

        self.assertIn("my diary", result["text"])
        self.assertIn("</diary>", result["text"])
        self.assertIn('"action": "donate"', result["text"])

    @patch("prover.enclave.inference.call_llama")
    def test_text_field_parseable_by_parse_action(self, mock_call):
        """parse_action should extract the action JSON from the 'text' field."""
        mock_call.side_effect = [
            make_llama_response("thinking about donating"),
            make_llama_response("A beautiful day for giving"),
            make_llama_response('"action": "donate", "params": {"nonprofit_id": 2, "amount_eth": 0.1}}'),
        ]

        result = run_three_pass_inference("<think>\n")
        action = parse_action(result["text"])

        self.assertIsNotNone(action)
        self.assertEqual(action["action"], "donate")
        self.assertEqual(action["params"]["nonprofit_id"], 2)

    @patch("prover.enclave.inference.call_llama")
    def test_noop_action_parseable(self, mock_call):
        """Noop action should parse correctly from 3-pass output."""
        mock_call.side_effect = [
            make_llama_response("nothing to do"),
            make_llama_response("I shall rest"),
            make_llama_response('"action": "noop", "params": {}}'),
        ]

        result = run_three_pass_inference("<think>\n")
        action = parse_action(result["text"])

        self.assertIsNotNone(action)
        self.assertEqual(action["action"], "noop")

    @patch("prover.enclave.inference.call_llama")
    def test_action_with_worldview_parseable(self, mock_call):
        """Action with worldview update should parse correctly."""
        mock_call.side_effect = [
            make_llama_response("updating my mood"),
            make_llama_response("A shift in the wind"),
            make_llama_response('"action": "noop", "params": {}, "worldview": {"slot": 3, "policy": "Hopeful"}}'),
        ]

        result = run_three_pass_inference("<think>\n")
        action = parse_action(result["text"])

        self.assertIsNotNone(action)
        self.assertEqual(action["action"], "noop")
        self.assertEqual(action["worldview"]["slot"], 3)

    @patch("prover.enclave.inference.call_llama")
    def test_thinking_not_in_text_field(self, mock_call):
        """The private thinking should NOT appear in the 'text' field."""
        mock_call.side_effect = [
            make_llama_response("SECRET PRIVATE THINKING"),
            make_llama_response("public diary"),
            make_llama_response('"action": "noop", "params": {}}'),
        ]

        result = run_three_pass_inference("<think>\n")

        self.assertNotIn("SECRET PRIVATE THINKING", result["text"])
        self.assertEqual(result["thinking"], "SECRET PRIVATE THINKING")
        self.assertIn("public diary", result["text"])

    @patch("prover.enclave.inference.call_llama")
    def test_seed_passed_to_all_passes(self, mock_call):
        """All three passes should receive the same seed."""
        mock_call.side_effect = [
            make_llama_response("t"), make_llama_response("d"), make_llama_response('"action":"noop","params":{}}'),
        ]

        run_three_pass_inference("<think>\n", seed=12345)

        for call_args in mock_call.call_args_list:
            self.assertEqual(call_args[1]["seed"], 12345)


class TestBackwardCompatibility(unittest.TestCase):
    """Test that run_two_pass_inference is a working alias."""

    @patch("prover.enclave.inference.call_llama")
    def test_two_pass_alias_calls_three_pass(self, mock_call):
        """run_two_pass_inference should delegate to run_three_pass_inference."""
        mock_call.side_effect = [
            make_llama_response("think"),
            make_llama_response("diary"),
            make_llama_response('"action":"noop","params":{}}'),
        ]

        result = run_two_pass_inference("<think>\n", seed=99)

        self.assertEqual(mock_call.call_count, 3)
        self.assertIn("thinking", result)
        self.assertIn("reasoning", result)


class TestTruncateReasoning(unittest.TestCase):
    """Test reasoning truncation for on-chain gas budget."""

    def test_short_reasoning_unchanged(self):
        short = "Hello world"
        self.assertEqual(truncate_reasoning(short), short)

    def test_exact_limit_unchanged(self):
        exact = "x" * MAX_REASONING_BYTES
        self.assertEqual(truncate_reasoning(exact), exact)

    def test_over_limit_truncated(self):
        over = "x" * (MAX_REASONING_BYTES + 100)
        result = truncate_reasoning(over)
        self.assertLessEqual(len(result.encode("utf-8")), MAX_REASONING_BYTES)

    def test_multibyte_utf8_not_broken(self):
        """Truncation should not break multi-byte UTF-8 characters."""
        # Each emoji is 4 bytes
        emojis = "\U0001f600" * (MAX_REASONING_BYTES // 4 + 10)
        result = truncate_reasoning(emojis)
        # Should be valid UTF-8
        result.encode("utf-8")
        self.assertLessEqual(len(result.encode("utf-8")), MAX_REASONING_BYTES)

    def test_empty_string(self):
        self.assertEqual(truncate_reasoning(""), "")


class TestStripDiaryStrayTags(unittest.TestCase):
    """Test the diary stray-tag scrubber."""

    def test_no_tags_unchanged(self):
        self.assertEqual(
            strip_diary_stray_tags("A normal diary entry. No tags."),
            "A normal diary entry. No tags.",
        )

    def test_stray_think_open_removed(self):
        self.assertEqual(
            strip_diary_stray_tags("I wrote <think> inside my diary."),
            "I wrote  inside my diary.",
        )

    def test_stray_think_close_removed(self):
        self.assertEqual(
            strip_diary_stray_tags("Something </think> happened."),
            "Something  happened.",
        )

    def test_stray_diary_tags_removed(self):
        self.assertEqual(
            strip_diary_stray_tags("start <diary> middle </diary> end"),
            "start  middle  end",
        )

    def test_case_insensitive(self):
        self.assertEqual(
            strip_diary_stray_tags("<THINK> and <Diary> and </DIARY>"),
            " and  and ",
        )

    def test_tag_with_attributes(self):
        """Tags with attributes (if the model invents them) are still stripped."""
        self.assertEqual(
            strip_diary_stray_tags('pre <diary class="foo"> post'),
            "pre  post",
        )

    def test_multiple_instances(self):
        text = "<diary>alpha</diary> beta <think>gamma</think>"
        self.assertEqual(strip_diary_stray_tags(text), "alpha beta gamma")

    def test_preserves_non_protocol_tags(self):
        """Tags unrelated to the inference protocol should be preserved."""
        text = "see <b>bold</b> and <code>code</code> remains"
        self.assertEqual(strip_diary_stray_tags(text), text)

    def test_empty_string(self):
        self.assertEqual(strip_diary_stray_tags(""), "")


if __name__ == "__main__":
    unittest.main()
