"""Regression vectors from independently fetched on-chain epoch commitments.

Run with .venv/bin/python so the existing web3/eth_abi dependencies are present.
"""
import copy
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
try:
    from experiments.operator_control.export_history import verify_state, RPC
except ImportError:
    verify_state = None


@unittest.skipIf(verify_state is None, "Use .venv/bin/python for historical commitment tests")
class HistoricalStateTests(unittest.TestCase):
    def fixture(self, epoch):
        case = json.loads((Path(__file__).parent / "testdata" / f"epoch_{epoch:04d}.json").read_text())
        verification = case["provenance"]["state_verification"]
        snap = {k: bytes.fromhex(v.removeprefix("0x")) for k, v in verification["component_hashes"].items()}
        expected = bytes.fromhex(verification["seeded_input_hash"].removeprefix("0x"))
        return case, snap, expected

    def test_known_legacy_and_current_commitments(self):
        for epoch, scheme in ((1, "legacy_fixed_ten"), (66, "rolling_variable_length")):
            with self.subTest(epoch=epoch):
                case, snap, expected = self.fixture(epoch)
                result = verify_state(case["epoch_state"], snap, expected, case["seed"])
                self.assertEqual(result["memory_hash_scheme"], scheme)

    def test_future_memory_cannot_replace_historical_memory(self):
        case, snap, expected = self.fixture(66)
        state = copy.deepcopy(case["epoch_state"])
        state["memories"][0]["body"] += " future knowledge"
        with self.assertRaises(ValueError):
            verify_state(state, snap, expected, case["seed"])

    def test_changed_scalar_and_seed_rejected(self):
        case, snap, expected = self.fixture(1)
        state = copy.deepcopy(case["epoch_state"])
        state["treasury_balance"] += 1
        with self.assertRaisesRegex(ValueError, "seeded input hash"):
            verify_state(state, snap, expected, case["seed"])
        with self.assertRaisesRegex(ValueError, "seeded input hash"):
            verify_state(case["epoch_state"], snap, expected, case["seed"] ^ 1)

    def test_cache_proxy_rejected_without_network(self):
        with self.assertRaisesRegex(ValueError, "unsafe for historical"):
            RPC("https://humanfund-rpc-cache.thehumanfund.workers.dev", Path("/unused"))


if __name__ == "__main__":
    unittest.main()
