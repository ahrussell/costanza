#!/usr/bin/env python3
"""Tests for voice-anchor parsing and seed-deterministic rotation."""

import unittest
from pathlib import Path

from .voice_anchors import parse_anchors, select_anchors, VOICE_ANCHOR_K


PROMPTS_DIR = Path(__file__).parent.parent / "prompts"
ANCHORS_FILE = PROMPTS_DIR / "voice_anchors.txt"


class TestParseAnchors(unittest.TestCase):
    def test_parses_production_file(self):
        """The real prompts/voice_anchors.txt should parse into 10 entries
        plus a header."""
        text = ANCHORS_FILE.read_text()
        header, entries = parse_anchors(text)
        self.assertEqual(len(entries), 10, f"expected 10 anchors, got {len(entries)}")
        self.assertTrue(header, "header should be non-empty")
        self.assertIn("diary", header.lower())

    def test_entries_start_with_opener(self):
        text = ANCHORS_FILE.read_text()
        _, entries = parse_anchors(text)
        for idx, entry in enumerate(entries, 1):
            self.assertTrue(
                entry.startswith(f"─── Entry {idx} ─"),
                f"entry {idx} starts with: {entry[:30]!r}",
            )

    def test_entries_end_with_divider(self):
        text = ANCHORS_FILE.read_text()
        _, entries = parse_anchors(text)
        for idx, entry in enumerate(entries, 1):
            last_line = entry.rstrip().split("\n")[-1]
            self.assertTrue(
                set(last_line) == {"─"} and len(last_line) >= 3,
                f"entry {idx} closes with: {last_line!r}",
            )

    def test_empty_input(self):
        header, entries = parse_anchors("")
        self.assertEqual(entries, [])

    def test_header_only_no_entries(self):
        header, entries = parse_anchors("just a note\nwith no entries\n")
        self.assertIn("just a note", header)
        self.assertEqual(entries, [])

    def test_synthetic_fixture(self):
        text = (
            "Header text\n"
            "second header line\n"
            "\n"
            "─── Entry 1 ─────\n"
            "[context: test]\n"
            "\n"
            "body one\n"
            "──────────\n"
            "\n"
            "─── Entry 2 ─────\n"
            "body two\n"
            "──────────\n"
        )
        header, entries = parse_anchors(text)
        self.assertIn("Header text", header)
        self.assertIn("second header line", header)
        self.assertEqual(len(entries), 2)
        self.assertIn("body one", entries[0])
        self.assertIn("body two", entries[1])


class TestSelectAnchors(unittest.TestCase):
    def setUp(self):
        text = ANCHORS_FILE.read_text()
        self.header, self.entries = parse_anchors(text)

    def test_selects_k_entries(self):
        out = select_anchors(self.header, self.entries, seed=42, k=VOICE_ANCHOR_K)
        # Count entry-open dividers in the output
        open_count = out.count("─── Entry ")
        self.assertEqual(open_count, VOICE_ANCHOR_K)

    def test_deterministic_same_seed(self):
        a = select_anchors(self.header, self.entries, seed=12345, k=5)
        b = select_anchors(self.header, self.entries, seed=12345, k=5)
        self.assertEqual(a, b)

    def test_different_seeds_produce_different_selections(self):
        """At least one pair of distinct seeds in a sample should yield
        different selections. (Statistically near-certain given 10 choose 5 = 252.)"""
        outs = {
            select_anchors(self.header, self.entries, seed=s, k=5)
            for s in range(50)
        }
        self.assertGreater(len(outs), 1, "all 50 seeds collided — suspicious")

    def test_selection_order_preserved(self):
        """Selected entries should appear in their original order."""
        out = select_anchors(self.header, self.entries, seed=7, k=5)
        # Find the entry numbers that appear, and check they're ascending
        import re
        nums = [int(m.group(1)) for m in re.finditer(r"─── Entry (\d+) ─", out)]
        self.assertEqual(nums, sorted(nums), f"order not preserved: {nums}")

    def test_header_always_included(self):
        out = select_anchors(self.header, self.entries, seed=1, k=5)
        self.assertIn(self.header.split("\n")[0], out)

    def test_k_equals_n_returns_all(self):
        out = select_anchors(self.header, self.entries, seed=1, k=len(self.entries))
        for idx in range(1, len(self.entries) + 1):
            self.assertIn(f"─── Entry {idx} ─", out)

    def test_k_larger_than_n_returns_all(self):
        out = select_anchors(self.header, self.entries, seed=1, k=len(self.entries) + 5)
        for idx in range(1, len(self.entries) + 1):
            self.assertIn(f"─── Entry {idx} ─", out)

    def test_seed_zero_fallback(self):
        """Seed=0 should produce a deterministic fallback selection."""
        a = select_anchors(self.header, self.entries, seed=0, k=5)
        b = select_anchors(self.header, self.entries, seed=0, k=5)
        self.assertEqual(a, b)

    def test_negative_seed_fallback(self):
        a = select_anchors(self.header, self.entries, seed=-1, k=5)
        b = select_anchors(self.header, self.entries, seed=0, k=5)
        self.assertEqual(a, b, "negative seed should fall back to seed=0 selection")

    def test_empty_entries(self):
        out = select_anchors("a header", [], seed=1, k=5)
        self.assertIn("a header", out)
        self.assertNotIn("─── Entry", out)


if __name__ == "__main__":
    unittest.main()
