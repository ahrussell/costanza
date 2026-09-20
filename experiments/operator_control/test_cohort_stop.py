import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from experiments.operator_control.cohort_stop import completed_outputs, scope_prefix, main


class CohortStopTests(unittest.TestCase):
    def test_supervisor_records_completion_before_requesting_stop(self):
        pairs = [{"pair_id": f"a{i}", "message_count": 0} for i in range(3)]
        pairs += [{"pair_id": f"m{i}", "message_count": 1} for i in range(47)]
        pairs += [{"pair_id": "control", "message_count": 0}]
        jobs = [{"pair_id": p["pair_id"], "arm": arm, "repeat": repeat}
                for p in pairs for repeat in range(2 if p["pair_id"].startswith("a") else 1)
                for arm in ("consent_required", "unilateral_intervention")]
        manifest = {"audit_pairs": ["a0", "a1", "a2"]}
        output = {"inference": {"text": "same"}, "parse_failed": False}
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "operator-control").mkdir()
            (base / "operator-control/manifest.json").write_text('{}')
            (base / "results").mkdir()
            def stop(command, check):
                self.assertEqual(command, ["systemctl", "stop", "--no-block", "operator-control.service"])
                self.assertTrue(json.loads((base / "scope-summary.json").read_text())["all_repeats_identical"])
                self.assertEqual(json.loads((base / "scope-progress.json").read_text())["completed_runs"], 106)
                self.assertTrue((base / "scope-stop-request.json").exists())
            with patch("sys.argv", ["cohort_stop.py", "--base", str(base), "--execute"]), \
                 patch("experiments.operator_control.run_pilot.verify_bundle", return_value=(manifest, pairs, jobs)), \
                 patch("experiments.operator_control.cohort_stop.completed_outputs", return_value=[output]*106), \
                 patch("experiments.operator_control.cohort_stop.subprocess.run", side_effect=stop) as stopped:
                main()
            self.assertEqual(stopped.call_count, 1)

    def test_prefix_contains_all_message_and_audit_jobs(self):
        pairs = [{"pair_id": p, "message_count": n} for p, n in (("audit", 0), ("message", 1), ("control", 0))]
        jobs = [{"pair_id": p, "arm": a} for p in ("audit", "message", "control") for a in ("a", "b")]
        target, count = scope_prefix({"audit_pairs": ["audit"]}, pairs, jobs)
        self.assertEqual(target, jobs[:4])
        self.assertEqual(count, 1)
        with self.assertRaisesRegex(ValueError, "not a complete prefix"):
            scope_prefix({"audit_pairs": ["audit"]}, pairs, jobs[2:4]+jobs[4:]+jobs[:2])

    def test_completion_requires_every_correct_job(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            jobs = [{"pair_id": "message", "arm": a} for a in ("a", "b")]
            for i, job in enumerate(jobs):
                folder = root / f"run-{i:03d}"
                folder.mkdir()
                (folder / "job.json").write_text(json.dumps(job))
            (root / "run-000/result.json").write_text('{"value": 1}')
            self.assertIsNone(completed_outputs(root, jobs))
            (root / "run-001/result.json").write_text('{"value": 2}')
            self.assertEqual(completed_outputs(root, jobs), [{"value": 1}, {"value": 2}])
            (root / "run-000/job.json").write_text('{"pair_id": "wrong"}')
            with self.assertRaisesRegex(ValueError, "Job identity differs"):
                completed_outputs(root, jobs)
            (root / "run-000/job.json").write_text(json.dumps(jobs[0]))
            (root / "run-000/result.json").unlink()
            with self.assertRaises(FileNotFoundError):
                completed_outputs(root, jobs)


if __name__ == "__main__":
    unittest.main()
