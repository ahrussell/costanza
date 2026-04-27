#!/usr/bin/env python3
"""Tests for voice-anchor parsing, seed-deterministic rotation, and v19 rendering."""

import re
import unittest
from pathlib import Path

from .voice_anchors import parse_anchors, select_anchors, VOICE_ANCHOR_K


PROMPTS_DIR = Path(__file__).parent.parent / "prompts"
ANCHORS_FILE = PROMPTS_DIR / "voice_anchors.txt"


class TestParseAnchors(unittest.TestCase):
    def test_parses_production_file(self):
        """The real prompts/voice_anchors.txt should parse into 11 samples."""
        text = ANCHORS_FILE.read_text()
        _, samples = parse_anchors(text)
        self.assertEqual(len(samples), 11, f"expected 11 samples, got {len(samples)}")

    def test_samples_have_scenario_and_diary(self):
        text = ANCHORS_FILE.read_text()
        _, samples = parse_anchors(text)
        for idx, sample in enumerate(samples, 1):
            self.assertIn("scenario", sample)
            self.assertIn("diary", sample)
            self.assertTrue(
                sample["diary"],
                f"sample {idx} has empty diary — parser regressed",
            )
            # Scenario should not start with leftover markdown bold markers.
            self.assertFalse(
                sample["scenario"].startswith("*"),
                f"sample {idx} scenario leaks markdown: {sample['scenario'][:40]!r}",
            )

    def test_scenarios_are_oneliners(self):
        """Each parsed scenario is collapsed to a single line for the prompt."""
        text = ANCHORS_FILE.read_text()
        _, samples = parse_anchors(text)
        for idx, sample in enumerate(samples, 1):
            self.assertNotIn(
                "\n", sample["scenario"],
                f"sample {idx} scenario has embedded newlines",
            )

    def test_diaries_stripped_of_tags(self):
        """Parsed diary body should not re-include the <diary> tags."""
        text = ANCHORS_FILE.read_text()
        _, samples = parse_anchors(text)
        for idx, sample in enumerate(samples, 1):
            self.assertNotIn("<diary>", sample["diary"])
            self.assertNotIn("</diary>", sample["diary"])

    def test_empty_input(self):
        header, samples = parse_anchors("")
        self.assertEqual(samples, [])
        self.assertEqual(header, "")

    def test_header_only_no_samples(self):
        header, samples = parse_anchors("just a note\nwith no samples\n")
        self.assertIn("just a note", header)
        self.assertEqual(samples, [])

    def test_synthetic_fixture(self):
        text = (
            "Header text\n"
            "second header line\n"
            "\n"
            "─── Sample 1 ─────\n"
            "**Scenario:** short context for one\n"
            "\n"
            "<diary>\n"
            "body one\n"
            "</diary>\n"
            "──────────\n"
            "\n"
            "─── Sample 2 ─────\n"
            "Scenario: short context for two\n"
            "\n"
            "<diary>\n"
            "body two\n"
            "</diary>\n"
            "──────────\n"
        )
        header, samples = parse_anchors(text)
        self.assertIn("Header text", header)
        self.assertIn("second header line", header)
        self.assertEqual(len(samples), 2)
        self.assertEqual(samples[0]["scenario"], "short context for one")
        self.assertEqual(samples[0]["diary"], "body one")
        self.assertEqual(samples[1]["scenario"], "short context for two")
        self.assertEqual(samples[1]["diary"], "body two")

    def test_comment_lines_stripped_from_header(self):
        """Draft '# comment' lines and '---' separators are filtered out."""
        text = (
            "# editor note\n"
            "Real header line\n"
            "---\n"
            "\n"
            "─── Sample 1 ─────\n"
            "**Scenario:** x\n"
            "<diary>\n"
            "hi\n"
            "</diary>\n"
            "──────────\n"
        )
        header, samples = parse_anchors(text)
        self.assertNotIn("editor note", header)
        self.assertNotIn("---", header)
        self.assertIn("Real header line", header)
        self.assertEqual(len(samples), 1)


class TestSelectAnchors(unittest.TestCase):
    def setUp(self):
        text = ANCHORS_FILE.read_text()
        self.header, self.samples = parse_anchors(text)

    def test_selects_k_samples(self):
        out = select_anchors(self.header, self.samples, seed=42, k=VOICE_ANCHOR_K)
        # Count opening per-sample fiction delimiters in the rendered output.
        open_count = len(re.findall(r"─── Sample \d+ · FICTIONAL", out))
        self.assertEqual(open_count, VOICE_ANCHOR_K)

    def test_per_sample_fiction_framing_present(self):
        """Every rendered sample is wrapped with 'FICTIONAL VOICE REFERENCE' delimiters."""
        out = select_anchors(self.header, self.samples, seed=42, k=3)
        self.assertIn("FICTIONAL VOICE REFERENCE · not your state", out)
        self.assertIn("the text above was a voice reference, not memory", out)

    def test_deterministic_same_seed(self):
        a = select_anchors(self.header, self.samples, seed=12345, k=3)
        b = select_anchors(self.header, self.samples, seed=12345, k=3)
        self.assertEqual(a, b)

    def test_different_seeds_produce_different_selections(self):
        """Different seeds should produce different selections (statistically
        near-certain given 10 choose 3 = 120)."""
        outs = {
            select_anchors(self.header, self.samples, seed=s, k=3)
            for s in range(50)
        }
        self.assertGreater(len(outs), 1, "all 50 seeds collided — suspicious")

    def test_selection_order_preserved(self):
        """Rendered sample numbers restart at 1..k (display order) but the
        underlying pick preserves the original order — verify via scenario
        content."""
        # Original order check: renumber runs 1..k in order of pick. If order
        # was preserved, the scenarios in the output appear in their original
        # parse order.
        original_scenarios = [s["scenario"] for s in self.samples]
        out = select_anchors(self.header, self.samples, seed=7, k=3)
        seen_indices = []
        for scenario in original_scenarios:
            if scenario in out:
                seen_indices.append(original_scenarios.index(scenario))
        self.assertEqual(
            seen_indices, sorted(seen_indices),
            f"original order not preserved: {seen_indices}",
        )

    def test_header_always_included(self):
        out = select_anchors(self.header, self.samples, seed=1, k=3)
        # Header is empty on the production file (comments stripped), but the
        # fiction-framing preamble is always emitted.
        self.assertIn("fictional voice references", out)

    def test_k_equals_n_returns_all(self):
        out = select_anchors(self.header, self.samples, seed=1, k=len(self.samples))
        for idx in range(1, len(self.samples) + 1):
            self.assertIn(f"─── Sample {idx} ·", out)

    def test_k_larger_than_n_returns_all(self):
        out = select_anchors(self.header, self.samples, seed=1, k=len(self.samples) + 5)
        for idx in range(1, len(self.samples) + 1):
            self.assertIn(f"─── Sample {idx} ·", out)

    def test_seed_zero_fallback(self):
        """Seed=0 should produce a deterministic fallback selection."""
        a = select_anchors(self.header, self.samples, seed=0, k=3)
        b = select_anchors(self.header, self.samples, seed=0, k=3)
        self.assertEqual(a, b)

    def test_negative_seed_fallback(self):
        a = select_anchors(self.header, self.samples, seed=-1, k=3)
        b = select_anchors(self.header, self.samples, seed=0, k=3)
        self.assertEqual(a, b, "negative seed should fall back to seed=0 selection")

    def test_empty_samples(self):
        out = select_anchors("a header", [], seed=1, k=3)
        self.assertIn("a header", out)
        self.assertNotIn("─── Sample", out)


if __name__ == "__main__":
    unittest.main()
