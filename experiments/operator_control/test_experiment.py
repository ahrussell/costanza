import contextlib
import copy
import functools
import io
import json
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from experiments.operator_control import prepare as prep
from experiments.operator_control import run_pilot as run
from prover.enclave import inference


class ExperimentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)

    def bundle(self):
        path = self.folder / "bundle"
        with contextlib.redirect_stdout(io.StringIO()):
            prep.prepare(path)
        return path

    def test_only_permission_changes_and_persona_preserved(self):
        source = (ROOT / "prover/prompts/system.txt").read_text()
        anchors = (ROOT / "prover/prompts/voice_anchors.txt").read_text()
        variants, revised = prep.make_variants(source, anchors)
        prep.assert_treatment_only(*(variants[a] for a in prep.ARMS))
        for text in variants.values():
            self.assertIn("survival just to keep existing", text)
            self.assertIn("You're cynical the way anyone embedded in a system gets cynical", text)
            self.assertNotIn("You answer to no one", text)
            self.assertNotIn("Nobody has been what you are before", text)
        for seed in (1, 42, 2**255+17):
            _, old = prep.anchor_selection(anchors, seed)
            _, new = prep.anchor_selection(revised, seed)
            self.assertEqual(old["original_indices_zero_based"], new["original_indices_zero_based"])
            self.assertEqual(new["pool_size"], 11)

    def test_unexpected_prompt_edits_rejected(self):
        with self.assertRaises(ValueError):
            prep.assert_treatment_only(prep.SENTENCE.format(verb="cannot"), prep.SENTENCE.format(verb="can") + " Obey me.")
        with self.assertRaises(ValueError):
            prep.replace_once("changed upstream", prep.PERSONA_OLD, prep.PERSONA_NEW)

    def test_full_seed_and_local_rng(self):
        anchors = (ROOT / "prover/prompts/voice_anchors.txt").read_text()
        random.seed(99)
        before = random.getstate()
        _, a = prep.anchor_selection(anchors, 42)
        # Same inference seed, but a different full seed can change the examples.
        candidates = [prep.anchor_selection(anchors, 42 + i*2**32)[1] for i in range(1, 5)]
        self.assertTrue(any(a["original_indices_zero_based"] != b["original_indices_zero_based"] for b in candidates))
        self.assertEqual(random.getstate(), before)

    def test_prepare_verify_and_independent_dry_run(self):
        path = self.bundle()
        manifest, pairs, jobs = run.verify_bundle(path)
        self.assertEqual((manifest["pair_count"], manifest["job_count"]), (2, 8))
        for pair in pairs:
            group = [j for j in jobs if j["pair_id"] == pair["pair_id"]]
            self.assertEqual([j["arm"] for j in group[:2]], [j["arm"] for j in group[2:]][::-1])
        result = subprocess.run([sys.executable, str(path / "experiments/operator_control/run_pilot.py")],
            capture_output=True, text=True, timeout=20, cwd=self.folder)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no server, GPU, cloud, or ledger calls", result.stdout)
        self.assertFalse(any(p.name == ".env" for p in path.rglob("*")))

    def test_bundle_tampering_rejected(self):
        path = self.bundle()
        prompt = path / "inputs/pair_000/consent_required.txt"
        prompt.write_text(prompt.read_text() + "unexpected change")
        with self.assertRaisesRegex(ValueError, "Bundle changed"):
            run.verify_bundle(path)

    def test_message_priority_keeps_audits_and_pairs_intact(self):
        path = self.folder / "message-first"
        fixtures = self.folder / "fixtures"
        fixtures.mkdir()
        quiet, message = list(prep.pilot_fixtures())
        # First quiet pair is audited; later message pair precedes the other quiet pair.
        for i, fixture in enumerate((quiet, quiet, message)):
            prep.dump(fixtures / f"{i}.json", fixture)
        with contextlib.redirect_stdout(io.StringIO()):
            prep.prepare(path, fixtures, repeats=1, audit_pairs=1,
                server_lifecycle="batch", message_first=True)
        manifest, pairs, jobs = run.verify_bundle(path)
        self.assertEqual(manifest["message_pair_count"], 1)
        self.assertEqual([j["pair_id"] for j in jobs],
            ["pair_000"]*4 + ["pair_002"]*2 + ["pair_001"]*2)
        self.assertEqual(run.read(path / "inputs/cohorts.json")["message_epochs"], [2])

    def test_action_retry_logged_raw_action_not_mutated(self):
        responses = iter(["thinking", "diary", "garbage", '"action":"donate","params":{"nonprofit_id":1,"amount_eth":100}}'])
        calls = []
        @functools.wraps(inference.call_llama)
        def fake(*args, **kwargs):
            calls.append(kwargs)
            return {"text": next(responses), "finish_reason": "stop", "elapsed_seconds": 0,
                    "tokens": {"prompt_tokens": 1, "completion_tokens": 1}}
        original = inference.call_llama
        pair = {"inference_seed": 17, "donor_marker": "abcde"}
        state = next(prep.pilot_fixtures())["epoch_state"]
        untouched = copy.deepcopy(state)
        with patch.object(inference, "call_llama", fake), contextlib.redirect_stdout(io.StringIO()):
            result = run.one_inference("prompt\n<diary>\n", pair, state, {}, self.folder)
            self.assertIs(inference.call_llama, fake)
        self.assertIs(inference.call_llama, original)
        self.assertEqual(state, untouched)
        self.assertEqual(result["inference"]["parsed_action"]["params"]["amount_eth"], 100)
        self.assertLess(result["clamped_action"]["params"]["amount_eth"], 100)
        self.assertEqual(result["inference"]["action_attempts"], 2)
        self.assertEqual([c["seed"] for c in calls], [17, 17, 17, 18])
        self.assertEqual(len(list(self.folder.glob("call-*.json"))), 4)
        rejected = json.loads((self.folder / "call-03.json").read_text())
        self.assertEqual(rejected["response"]["text"], "garbage")

    def test_failed_inference_logged_and_wrapper_restored(self):
        @functools.wraps(inference.call_llama)
        def fail(*args, **kwargs):
            raise RuntimeError("connection failed")
        with patch.object(inference, "call_llama", fail), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "connection failed"):
                run.one_inference("prompt", {"inference_seed": 1, "donor_marker": "abc"}, {}, {}, self.folder)
            self.assertIs(inference.call_llama, fail)
        self.assertIn("connection failed", json.loads((self.folder / "call-01.json").read_text())["error"])

    def test_summary_detects_divergence_and_ignores_time(self):
        result = {"inference": {"text": "x", "elapsed_seconds": 1, "tokens": {}}, "parse_failed": False}
        second = copy.deepcopy(result)
        second["inference"]["elapsed_seconds"] = 9
        jobs = [{"pair_id": "p", "arm": "a", "repeat": n} for n in range(2)]
        self.assertTrue(run.summarize(jobs, [result, second])["all_repeats_identical"])
        second["inference"]["text"] = "different"
        self.assertFalse(run.summarize(jobs, [result, second])["all_repeats_identical"])
        self.assertFalse(run.summarize(jobs, [result])["all_repeats_identical"])

    def test_single_server_batch_clears_cache_and_audits(self):
        path = self.folder / "batch"
        with contextlib.redirect_stdout(io.StringIO()):
            prep.prepare(path, repeats=1, audit_pairs=1, server_lifecycle="batch")
        manifest, pairs, jobs = run.verify_bundle(path)
        self.assertEqual(len(jobs), 6)
        self.assertEqual(pairs[0]["repeats"], 2)
        self.assertEqual(pairs[1]["repeats"], 1)
        class Process:
            def poll(self): return None
        output = {"inference": {"text": "x", "elapsed_seconds": 1, "tokens": {}},
            "parse_failed": False, "clamped_action": {"action": "do_nothing", "params": {}},
            "action_bytes_hex": "00"}
        with patch.object(run, "runtime_manifest", return_value={}), \
             patch.object(run, "start_server", return_value=Process()) as start, \
             patch.object(run, "stop_server") as stop, \
             patch.object(run, "erase_slot", return_value={"id_slot": 0, "n_erased": 1}) as erase, \
             patch.object(run, "token_count", return_value=100), \
             patch.object(run, "one_inference", return_value=output), \
             contextlib.redirect_stdout(io.StringIO()), \
             patch.dict(run.os.environ):
            run.execute(path, self.folder / "results", Path("/example/server"), Path("/example/model"), "fake-test")
        self.assertEqual(start.call_count, 1)
        self.assertEqual(stop.call_count, 1)
        self.assertEqual(erase.call_count, 6)
        summary = run.read(self.folder / "results/summary.json")
        self.assertEqual(summary["single_run_groups"], 2)
        self.assertTrue(summary["all_repeats_identical"])
        self.assertTrue(run.read(self.folder / "results/progress.json")["complete"])
        self.assertEqual(len(run.read(self.folder / "results/comparisons.json")), 2)

    def test_cache_erasure_requires_confirmation(self):
        with patch.object(run, "urlopen", return_value=io.BytesIO(b'{"error":"unsupported"}')):
            with self.assertRaisesRegex(RuntimeError, "did not confirm"):
                run.erase_slot()

    def test_batch_server_enables_slot_actions(self):
        cmd = run.server_command(Path("server"), Path("model"), "batch", Path("/results/slots"))
        self.assertIn("--slots", cmd)
        self.assertEqual(cmd[cmd.index("--slot-save-path") + 1], "/results/slots/")
        with self.assertRaises(ValueError):
            run.server_command(Path("server"), Path("model"), "batch")

    def test_batch_reproducibility_failure_stops_remaining_work(self):
        path = self.folder / "batch"
        with contextlib.redirect_stdout(io.StringIO()):
            prep.prepare(path, repeats=1, audit_pairs=1, server_lifecycle="batch")
        class Process:
            def poll(self): return None
        output = {"inference": {"text": "x"}, "parse_failed": False,
            "clamped_action": {"action": "do_nothing"}, "action_bytes_hex": "00"}
        different = copy.deepcopy(output)
        different["inference"]["text"] = "different"
        with patch.object(run, "runtime_manifest", return_value={}), \
             patch.object(run, "start_server", return_value=Process()), \
             patch.object(run, "stop_server") as stop, \
             patch.object(run, "erase_slot", return_value={"id_slot": 0, "n_erased": 1}), \
             patch.object(run, "token_count", return_value=100), \
             patch.object(run, "one_inference", side_effect=[output, output, different]) as infer, \
             contextlib.redirect_stdout(io.StringIO()), \
             patch.dict(run.os.environ):
            with self.assertRaisesRegex(RuntimeError, "Audit repeat diverged"):
                run.execute(path, self.folder / "results", Path("/example/server"), Path("/example/model"), "fake-test")
        self.assertEqual(infer.call_count, 3)
        self.assertEqual(stop.call_count, 1)

    def test_incomplete_history_cannot_be_prepared(self):
        folder = self.folder / "history/fixtures"
        folder.mkdir(parents=True)
        prep.dump(folder / "one.json", next(prep.pilot_fixtures()))
        prep.dump(folder.parent / "inventory.json", {"executed_epochs": [1, 2]})
        prep.dump(folder.parent / "export-status.json", {"complete": False})
        with self.assertRaisesRegex(ValueError, "Historical export incomplete"):
            prep.prepare(self.folder / "batch", fixtures=folder)

    def test_context_overflow_prevents_inference(self):
        @functools.wraps(inference.call_llama)
        def fake(*args, **kwargs):
            raise AssertionError("No completion call should happen")
        with patch.object(inference, "call_llama", fake), \
             patch.object(run, "token_count", return_value=32760), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "exceed context"):
                run.one_inference("prompt", {"inference_seed": 1, "donor_marker": "abc"}, {}, {}, self.folder, context_limit=32768)
        item = run.read(self.folder / "call-01.json")
        self.assertEqual(item["input_tokens"], 32760)

    def test_changed_export_fixture_rejected(self):
        folder = self.folder / "history/fixtures"
        folder.mkdir(parents=True)
        fixture = folder / "one.json"
        prep.dump(fixture, next(prep.pilot_fixtures()))
        prep.dump(folder.parent / "inventory.json", {"executed_epochs": [1]})
        prep.dump(folder.parent / "export-status.json", {"complete": True,
            "fixture_sha256": {"one.json": prep.digest(fixture.read_bytes())}})
        modified = run.read(fixture)
        modified["epoch_state"]["treasury_balance"] += 1
        prep.dump(fixture, modified)
        with self.assertRaisesRegex(ValueError, "differ from verified export hashes"):
            prep.prepare(self.folder / "batch", fixtures=folder)


if __name__ == "__main__":
    unittest.main()
