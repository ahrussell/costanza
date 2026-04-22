#!/usr/bin/env python3
"""Tests for two-pass inference (v19) and related utilities.

These tests mock the llama-server to verify:
1. Two-pass prompt construction (diary -> grammar-constrained action JSON)
2. Temperature, stop token, and grammar settings per pass
3. Return value structure (reasoning/diary, action_text, parsed_action)
4. Truncation of reasoning at MAX_REASONING_BYTES
5. Backward compatibility of run_three_pass_inference alias
6. Integration with parse_action (diary text + JSON action)
"""

import unittest
from unittest.mock import patch

from .inference import (
    run_two_pass_inference,
    run_three_pass_inference,
    truncate_reasoning,
    strip_diary_stray_tags,
    DEFAULT_DIARY_PREFILL,
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


class TestTwoPassInference(unittest.TestCase):
    """Test two-pass inference prompt construction and result assembly."""

    @patch("prover.enclave.inference.call_llama")
    def test_two_passes_called_with_correct_prompts(self, mock_call):
        """Verify each pass builds the right prompt with correct params."""
        mock_call.side_effect = [
            make_llama_response("Today I give with joy."),        # Pass 1: diary
            make_llama_response('"action": "do_nothing", "params": {}}'),  # Pass 2: action
        ]

        prompt = "<diary>\n"
        # diary_prefill="" so pass-1 args[0] equals `prompt` exactly.
        result = run_two_pass_inference(prompt, seed=42, diary_prefill="")

        self.assertEqual(mock_call.call_count, 2)

        # Pass 1: diary. stop at </diary>, freq penalty, pass1 temp.
        args1, kwargs1 = mock_call.call_args_list[0]
        self.assertEqual(args1[0], prompt)
        self.assertEqual(kwargs1["temperature"], 0.85)
        self.assertEqual(kwargs1["stop"], ["</diary>"])
        self.assertEqual(kwargs1["seed"], 42)
        self.assertEqual(kwargs1["max_tokens"], 1024)
        self.assertEqual(kwargs1["frequency_penalty"], 0.4)
        self.assertIsNone(kwargs1.get("grammar"))

        # Pass 2: action JSON, grammar-constrained, pass2 temp, starts at '{'.
        args2, kwargs2 = mock_call.call_args_list[1]
        self.assertIn("Today I give with joy.", args2[0])
        self.assertIn("</diary>\n{", args2[0])
        self.assertEqual(kwargs2["temperature"], 0.3)
        self.assertEqual(kwargs2["stop"], ["\n\n"])
        self.assertEqual(kwargs2["max_tokens"], 256)
        # Grammar should be present (loaded from action_grammar.gbnf on disk)
        self.assertTrue(kwargs2.get("grammar"), "pass 2 should pass grammar")

    @patch("prover.enclave.inference.call_llama")
    def test_sampler_config_v19_defaults(self, mock_call):
        """Default sampler should match v19 baseline: top_p=1.0, top_k=0, min_p=0.05."""
        mock_call.side_effect = [
            make_llama_response("diary"),
            make_llama_response('"action":"do_nothing","params":{}}'),
        ]

        run_two_pass_inference("<diary>\n", seed=1)

        for args, kwargs in mock_call.call_args_list:
            self.assertEqual(kwargs["top_p"], 1.0)
            self.assertEqual(kwargs["top_k"], 0)
            self.assertEqual(kwargs["min_p"], 0.05)

    @patch("prover.enclave.inference.call_llama")
    def test_result_structure(self, mock_call):
        """Verify the return dict has all expected keys with correct values."""
        mock_call.side_effect = [
            make_llama_response("poetic diary entry here"),
            make_llama_response('"action": "do_nothing", "params": {}}'),
        ]

        # diary_prefill="" so reasoning equals the mocked diary text exactly.
        result = run_two_pass_inference("<diary>\n", seed=1, diary_prefill="")

        # thinking is always "" in v19 (no scratchpad pass).
        self.assertEqual(result["thinking"], "")
        self.assertEqual(result["reasoning"], "poetic diary entry here")
        self.assertIn('"action": "do_nothing"', result["action_text"])
        self.assertTrue(result["action_text"].startswith("{"))
        self.assertEqual(result["elapsed_seconds"], 2.0)  # 2 passes x 1s each
        self.assertEqual(result["tokens"]["prompt_tokens"], 200)
        self.assertEqual(result["tokens"]["completion_tokens"], 100)
        self.assertIsNotNone(result["parsed_action"])
        self.assertEqual(result["parsed_action"]["action"], "do_nothing")
        self.assertEqual(result["action_attempts"], 1)

    @patch("prover.enclave.inference.call_llama")
    def test_text_field_contains_diary_and_action(self, mock_call):
        """The 'text' field should contain diary + </diary> + action for parse_action."""
        mock_call.side_effect = [
            make_llama_response("my diary"),
            make_llama_response('"action": "donate", "params": {"nonprofit_id": 1, "amount_eth": 0.5}}'),
        ]

        result = run_two_pass_inference("<diary>\n")

        self.assertIn("my diary", result["text"])
        self.assertIn("</diary>", result["text"])
        self.assertIn('"action": "donate"', result["text"])

    @patch("prover.enclave.inference.call_llama")
    def test_text_field_parseable_by_parse_action(self, mock_call):
        """parse_action should extract the action JSON from the 'text' field."""
        mock_call.side_effect = [
            make_llama_response("A beautiful day for giving"),
            make_llama_response('"action": "donate", "params": {"nonprofit_id": 2, "amount_eth": 0.1}}'),
        ]

        result = run_two_pass_inference("<diary>\n")
        action = parse_action(result["text"])

        self.assertIsNotNone(action)
        self.assertEqual(action["action"], "donate")
        self.assertEqual(action["params"]["nonprofit_id"], 2)

    @patch("prover.enclave.inference.call_llama")
    def test_do_nothing_action_parseable(self, mock_call):
        """do_nothing action should parse correctly from 2-pass output."""
        mock_call.side_effect = [
            make_llama_response("I shall rest"),
            make_llama_response('"action": "do_nothing", "params": {}}'),
        ]

        result = run_two_pass_inference("<diary>\n")
        action = parse_action(result["text"])

        self.assertIsNotNone(action)
        self.assertEqual(action["action"], "do_nothing")

    @patch("prover.enclave.inference.call_llama")
    def test_action_with_memory_parseable(self, mock_call):
        """Action with memory update (array form) should parse correctly."""
        mock_call.side_effect = [
            make_llama_response("A shift in the wind"),
            make_llama_response(
                '"action": "do_nothing", "params": {}, '
                '"memory": [{"slot": 3, "title": "Mood", "body": "Hopeful"}]}'
            ),
        ]

        result = run_two_pass_inference("<diary>\n")
        action = parse_action(result["text"])

        self.assertIsNotNone(action)
        self.assertEqual(action["action"], "do_nothing")
        self.assertIsInstance(action["memory"], list)
        self.assertEqual(len(action["memory"]), 1)
        self.assertEqual(action["memory"][0]["slot"], 3)
        self.assertEqual(action["memory"][0]["title"], "Mood")
        self.assertEqual(action["memory"][0]["body"], "Hopeful")

    @patch("prover.enclave.inference.call_llama")
    def test_action_with_multi_slot_memory_parseable(self, mock_call):
        """Action with three memory updates should parse as a 3-entry list."""
        mock_call.side_effect = [
            make_llama_response("Three things to carry forward"),
            make_llama_response(
                '"action": "do_nothing", "params": {}, '
                '"memory": ['
                '{"slot": 1, "title": "T1", "body": "B1"},'
                '{"slot": 5, "title": "T5", "body": "B5"},'
                '{"slot": 9, "title": "T9", "body": "B9"}'
                ']}'
            ),
        ]

        result = run_two_pass_inference("<diary>\n")
        action = parse_action(result["text"])

        self.assertIsNotNone(action)
        self.assertIsInstance(action["memory"], list)
        self.assertEqual([e["slot"] for e in action["memory"]], [1, 5, 9])

    @patch("prover.enclave.inference.call_llama")
    def test_seed_increments_across_retries(self, mock_call):
        """Pass 2 retries should increment the seed to avoid identical output."""
        # First two attempts return unparseable garbage; third succeeds.
        mock_call.side_effect = [
            make_llama_response("diary here"),
            make_llama_response("GARBAGE NOT JSON"),       # attempt 1
            make_llama_response("STILL GARBAGE"),          # attempt 2
            make_llama_response('"action":"do_nothing","params":{}}'),  # attempt 3
        ]

        result = run_two_pass_inference("<diary>\n", seed=1000)

        # Pass 1 uses the base seed.
        _, pass1_kwargs = mock_call.call_args_list[0]
        self.assertEqual(pass1_kwargs["seed"], 1000)

        # Pass 2 retries increment the seed.
        retry_seeds = [
            kwargs["seed"] for _, kwargs in mock_call.call_args_list[1:]
        ]
        self.assertEqual(retry_seeds, [1000, 1001, 1002])
        self.assertEqual(result["action_attempts"], 3)

    @patch("prover.enclave.inference.call_llama")
    def test_all_retries_fail_returns_none_parsed_action(self, mock_call):
        """When all pass 2 retries fail, parsed_action is None for caller fallback."""
        mock_call.side_effect = [
            make_llama_response("diary here"),
            make_llama_response("GARBAGE"),
            make_llama_response("GARBAGE"),
            make_llama_response("GARBAGE"),
            make_llama_response("GARBAGE"),
        ]

        result = run_two_pass_inference("<diary>\n", seed=-1)

        self.assertIsNone(result["parsed_action"])
        self.assertEqual(result["action_attempts"], 4)

    @patch("prover.enclave.inference.call_llama")
    def test_stray_diary_close_tag_clipped(self, mock_call):
        """If the stop token is missed, the first </diary> in pass 1 output is still clipped."""
        mock_call.side_effect = [
            make_llama_response("real diary body</diary>\nleaked action"),
            make_llama_response('"action":"do_nothing","params":{}}'),
        ]

        result = run_two_pass_inference("<diary>\n")

        self.assertIn("real diary body", result["reasoning"])
        self.assertNotIn("leaked action", result["reasoning"])
        self.assertNotIn("</diary>", result["reasoning"])


class TestDiaryPrefill(unittest.TestCase):
    """Tests for the diary pre-fill that prevents empty pass-1 output.

    Without the prefill, Hermes 4 70B emits </diary> as its first generation
    token roughly 80% of the time on production prompts (verified greedy +
    a 15-seed sweep). The prefill is appended to pass-1's prompt to anchor
    generation, but stripped from the returned `reasoning` so the on-chain
    text is 100% model voice.
    """

    @patch("prover.enclave.inference.call_llama")
    def test_default_prefill_appended_to_pass1_prompt(self, mock_call):
        """Pass-1 sees `prompt + DEFAULT_DIARY_PREFILL`, not just `prompt`."""
        mock_call.side_effect = [
            make_llama_response(" was a long epoch."),
            make_llama_response('"action":"do_nothing","params":{}}'),
        ]
        prompt = "<diary>\n"
        run_two_pass_inference(prompt, seed=1)

        args1, _ = mock_call.call_args_list[0]
        self.assertEqual(args1[0], prompt + DEFAULT_DIARY_PREFILL)

    @patch("prover.enclave.inference.call_llama")
    def test_prefill_stripped_from_returned_reasoning(self, mock_call):
        """`reasoning` is the model's continuation only — prefill is NOT in it."""
        mock_call.side_effect = [
            make_llama_response("Epoch three. Nobody wrote me anything today."),
            make_llama_response('"action":"do_nothing","params":{}}'),
        ]
        result = run_two_pass_inference("<diary>\n", seed=1)

        self.assertEqual(
            result["reasoning"],
            "Epoch three. Nobody wrote me anything today.",
        )
        self.assertNotIn("Dear Diary", result["reasoning"])

    @patch("prover.enclave.inference.call_llama")
    def test_model_leading_whitespace_stripped(self, mock_call):
        """Leading whitespace from the model's continuation is lstripped."""
        mock_call.side_effect = [
            make_llama_response("   first sentence."),
            make_llama_response('"action":"do_nothing","params":{}}'),
        ]
        result = run_two_pass_inference("<diary>\n", seed=1)
        self.assertEqual(result["reasoning"], "first sentence.")

    @patch("prover.enclave.inference.call_llama")
    def test_empty_prefill_is_supported(self, mock_call):
        """diary_prefill='' restores the pre-prefill behavior — used by tests."""
        mock_call.side_effect = [
            make_llama_response("raw diary"),
            make_llama_response('"action":"do_nothing","params":{}}'),
        ]
        prompt = "<diary>\n"
        result = run_two_pass_inference(prompt, seed=1, diary_prefill="")

        args1, _ = mock_call.call_args_list[0]
        self.assertEqual(args1[0], prompt)
        self.assertEqual(result["reasoning"], "raw diary")

    @patch("prover.enclave.inference.call_llama")
    def test_pass2_context_byte_consistent_with_pass1(self, mock_call):
        """Pass 2's prompt must include the prefill so the assembled context is
        byte-consistent with what pass 1 actually generated."""
        mock_call.side_effect = [
            make_llama_response("Epoch three. A quiet day."),
            make_llama_response('"action":"do_nothing","params":{}}'),
        ]
        run_two_pass_inference("<diary>\n", seed=1)

        args2, _ = mock_call.call_args_list[1]
        # Pass 2 prompt = pass1_prompt + diary + "\n</diary>\n{"
        #               = "<diary>\n" + "Dear Diary,\n\n" + "Epoch three. A quiet day." + "\n</diary>\n{"
        self.assertIn(DEFAULT_DIARY_PREFILL, args2[0])
        self.assertIn("Epoch three. A quiet day.", args2[0])
        self.assertIn("</diary>\n{", args2[0])


class TestPass1RetryOnEmpty(unittest.TestCase):
    """Tests for pass-1 retry-on-empty with PRNG-derived deterministic seeds.

    If the model emits an empty diary (</diary> as first token), the retry
    loop re-rolls with a deterministic seed drawn from random.Random(base_seed).
    First attempt uses base_seed unchanged so the no-retry path is bit-for-bit
    identical to the pre-retry implementation.
    """

    @patch("prover.enclave.inference.call_llama")
    def test_no_retry_on_first_attempt_success(self, mock_call):
        """If pass 1 succeeds first try, only one pass-1 call is made."""
        mock_call.side_effect = [
            make_llama_response("First diary content."),
            make_llama_response('"action":"do_nothing","params":{}}'),
        ]
        result = run_two_pass_inference("<diary>\n", seed=42)

        # 1 pass-1 + 1 pass-2 = 2 calls
        self.assertEqual(mock_call.call_count, 2)
        self.assertEqual(result["pass1_attempts"], 1)
        # First pass-1 attempt MUST use the base seed unchanged so the
        # no-retry path is bit-for-bit identical to pre-retry behavior.
        _, kwargs1 = mock_call.call_args_list[0]
        self.assertEqual(kwargs1["seed"], 42)

    @patch("prover.enclave.inference.call_llama")
    def test_retry_fires_on_empty_diary(self, mock_call):
        """An empty pass-1 result triggers a retry with a different seed."""
        mock_call.side_effect = [
            make_llama_response(""),                         # empty -> retry
            make_llama_response("Now real content."),        # success
            make_llama_response('"action":"do_nothing","params":{}}'),
        ]
        result = run_two_pass_inference("<diary>\n", seed=42)

        # 2 pass-1 attempts + 1 pass-2 = 3 calls
        self.assertEqual(mock_call.call_count, 3)
        self.assertEqual(result["pass1_attempts"], 2)
        self.assertEqual(result["reasoning"], "Now real content.")

        # Retry seed must be deterministic from base seed (PRNG-derived).
        _, kwargs1a = mock_call.call_args_list[0]
        _, kwargs1b = mock_call.call_args_list[1]
        self.assertEqual(kwargs1a["seed"], 42)
        # Second attempt: random.Random(42).randint(0, 2**31-1) — known value.
        import random
        expected_retry_seed = random.Random(42).randint(0, 2**31 - 1)
        self.assertEqual(kwargs1b["seed"], expected_retry_seed)

    @patch("prover.enclave.inference.call_llama")
    def test_retry_seeds_are_deterministic(self, mock_call):
        """Two runs with the same base seed produce the same retry sequence."""
        # Force 3 empty diaries before success → 4 attempts.
        empty = lambda: make_llama_response("")
        side_effect_1 = [empty(), empty(), empty(),
                          make_llama_response("good diary text here"),
                          make_llama_response('"action":"do_nothing","params":{}}')]
        side_effect_2 = [empty(), empty(), empty(),
                          make_llama_response("good diary text here"),
                          make_llama_response('"action":"do_nothing","params":{}}')]

        mock_call.side_effect = side_effect_1
        run_two_pass_inference("<diary>\n", seed=12345)
        seeds_run1 = [kw["seed"] for _, kw in mock_call.call_args_list[:4]]

        mock_call.reset_mock()
        mock_call.side_effect = side_effect_2
        run_two_pass_inference("<diary>\n", seed=12345)
        seeds_run2 = [kw["seed"] for _, kw in mock_call.call_args_list[:4]]

        self.assertEqual(seeds_run1, seeds_run2,
                         "PRNG-derived retry seeds must be deterministic")

    @patch("prover.enclave.inference.call_llama")
    def test_random_seed_mode_uses_minus_one(self, mock_call):
        """seed=-1 (random mode) keeps -1 across retries so llama-server
        picks a fresh random seed each try."""
        mock_call.side_effect = [
            make_llama_response(""),
            make_llama_response("real diary content here."),
            make_llama_response('"action":"do_nothing","params":{}}'),
        ]
        run_two_pass_inference("<diary>\n", seed=-1)

        _, kwargs1a = mock_call.call_args_list[0]
        _, kwargs1b = mock_call.call_args_list[1]
        self.assertEqual(kwargs1a["seed"], -1)
        self.assertEqual(kwargs1b["seed"], -1)

    @patch("prover.enclave.inference.call_llama")
    def test_short_diary_treated_as_empty(self, mock_call):
        """A pass-1 result with <5 chars of stripped content triggers retry —
        prevents shipping degenerate diaries like 'It' or 'Dear'."""
        mock_call.side_effect = [
            make_llama_response("It"),                      # too short
            make_llama_response("Now a real diary entry."),
            make_llama_response('"action":"do_nothing","params":{}}'),
        ]
        result = run_two_pass_inference("<diary>\n", seed=42)
        self.assertEqual(result["pass1_attempts"], 2)
        self.assertEqual(result["reasoning"], "Now a real diary entry.")


class TestBackwardCompatibility(unittest.TestCase):
    """Test that run_three_pass_inference is a working alias to the 2-pass path."""

    @patch("prover.enclave.inference.call_llama")
    def test_three_pass_alias_runs_two_pass(self, mock_call):
        """run_three_pass_inference should delegate to run_two_pass_inference."""
        mock_call.side_effect = [
            make_llama_response("diary"),
            make_llama_response('"action":"do_nothing","params":{}}'),
        ]

        result = run_three_pass_inference("<diary>\n", seed=99)

        # v19 is 2-pass — the alias should make two calls, not three.
        self.assertEqual(mock_call.call_count, 2)
        self.assertIn("reasoning", result)
        self.assertIn("thinking", result)
        self.assertEqual(result["thinking"], "")  # no scratchpad pass


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


class TestMemorySidecarClamp(unittest.TestCase):
    """Validator coverage for the memory sidecar array."""

    def _state(self):
        # Minimal state — the memory clamp doesn't touch action bounds.
        return {
            "treasury_balance": 10 * 10**18,
            "investments": [],
        }

    def _clamp(self, memory):
        from .action_encoder import validate_and_clamp_action
        aj = {"action": "do_nothing", "params": {}, "memory": memory}
        return validate_and_clamp_action(aj, self._state())

    def test_empty_list_passes_through(self):
        aj, notes = self._clamp([])
        self.assertEqual(aj["memory"], [])
        self.assertEqual(notes, [])

    def test_missing_field_passes_through(self):
        from .action_encoder import validate_and_clamp_action
        aj = {"action": "do_nothing", "params": {}}
        aj, notes = validate_and_clamp_action(aj, self._state())
        # When absent entirely, sidecar is left untouched (not materialized
        # as an empty list — the client decides whether to synthesize []).
        self.assertNotIn("memory", aj)
        self.assertEqual(notes, [])

    def test_single_update_normalized(self):
        aj, notes = self._clamp([{"slot": 3, "title": "Mood", "body": "Hopeful"}])
        self.assertEqual(aj["memory"], [
            {"slot": 3, "title": "Mood", "body": "Hopeful"}
        ])
        self.assertEqual(notes, [])

    def test_single_dict_wrapped_into_list(self):
        aj, _ = self._clamp({"slot": 2, "title": "T", "body": "B"})
        self.assertEqual(aj["memory"], [{"slot": 2, "title": "T", "body": "B"}])

    def test_over_cap_truncated(self):
        updates = [
            {"slot": i, "title": f"T{i}", "body": f"B{i}"} for i in range(5)
        ]
        aj, notes = self._clamp(updates)
        self.assertEqual(len(aj["memory"]), 3)
        self.assertEqual([e["slot"] for e in aj["memory"]], [0, 1, 2])
        # 5 → 3 means 2 extras dropped via the cap.
        self.assertTrue(any("truncated to 3" in n for n in notes))

    def test_invalid_slot_dropped(self):
        updates = [
            {"slot": 1, "title": "ok", "body": "keep"},
            {"slot": 99, "title": "bad", "body": "drop"},
            {"slot": 4, "title": "ok2", "body": "keep2"},
        ]
        aj, notes = self._clamp(updates)
        self.assertEqual([e["slot"] for e in aj["memory"]], [1, 4])
        self.assertTrue(any("dropped" in n and "malformed" in n for n in notes))

    def test_string_slot_coerced(self):
        aj, _ = self._clamp([{"slot": "5", "title": "T", "body": "B"}])
        self.assertEqual(aj["memory"][0]["slot"], 5)

    def test_unparseable_slot_dropped(self):
        aj, _ = self._clamp([{"slot": "not-a-number", "title": "T", "body": "B"}])
        self.assertEqual(aj["memory"], [])

    def test_title_truncated_to_64_bytes(self):
        long_title = "X" * 100
        aj, _ = self._clamp([{"slot": 1, "title": long_title, "body": "b"}])
        self.assertEqual(len(aj["memory"][0]["title"].encode("utf-8")), 64)

    def test_body_truncated_to_280_bytes(self):
        long_body = "Y" * 400
        aj, _ = self._clamp([{"slot": 1, "title": "t", "body": long_body}])
        self.assertEqual(len(aj["memory"][0]["body"].encode("utf-8")), 280)

    def test_non_dict_entry_dropped(self):
        aj, notes = self._clamp([
            "not a dict",
            {"slot": 1, "title": "T", "body": "B"},
            42,
        ])
        self.assertEqual([e["slot"] for e in aj["memory"]], [1])
        self.assertTrue(any("malformed" in n for n in notes))

    def test_non_list_non_dict_replaced_with_empty(self):
        aj, notes = self._clamp("a string sidecar")
        self.assertEqual(aj["memory"], [])
        self.assertTrue(any("expected a list" in n for n in notes))

    def test_dup_slot_order_preserved(self):
        # Validator does NOT dedup; contract's last-wins semantics apply.
        aj, _ = self._clamp([
            {"slot": 2, "title": "First",  "body": "first"},
            {"slot": 2, "title": "Second", "body": "second"},
        ])
        self.assertEqual([e["title"] for e in aj["memory"]], ["First", "Second"])

    def test_utf8_multibyte_truncation_safe(self):
        # A 64-byte cap that would land mid-codepoint must drop the partial
        # codepoint rather than emit invalid UTF-8.
        emoji_body = "💡" * 50  # each emoji is 4 bytes, so 200 bytes total
        title = "A" + "💡"  # 1 + 4 = 5 bytes, under cap, no truncation
        aj, _ = self._clamp([{"slot": 1, "title": title, "body": emoji_body}])
        out_body = aj["memory"][0]["body"]
        # Must decode cleanly (no replacement chars from bad truncation).
        out_body.encode("utf-8").decode("utf-8")
        self.assertLessEqual(len(out_body.encode("utf-8")), 280)


if __name__ == "__main__":
    unittest.main()
