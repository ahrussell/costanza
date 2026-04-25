#!/usr/bin/env python3
"""End-to-end test for the prover's input-hash pipeline.

The CrossStackHash forge tests verify Solidity ↔ Python parity by building
the state JSON inside Solidity and feeding it to compute_input_hash. That's
load-bearing for hash logic, but it bypasses prover/client/epoch_state.py —
the actual web3 plumbing the runner uses to read the contract state.

A renamed function (the real getPolicies → getEntries case) or a drifted
ABI tuple won't show up in CrossStackHash because that path never runs.
This test plugs the gap: it spawns anvil, deploys the full stack via a
dedicated forge script (DeployForPipelineTest), then calls the *real*
read_contract_state function and asserts its hash matches the contract's
stored input hash for the snapshot.

Run: python -m pytest prover/client/test_pipeline.py -v

Skips cleanly if anvil/forge aren't installed or `forge build` hasn't run.
"""

import json
import os
import shutil
import socket
import subprocess
import time
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
ANVIL_PORT = 18546

# Anvil's deterministic dev account 0 — pre-funded with 10000 ETH.
DEV_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"


def _wait_port(host, port, timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.5):
                return
        except OSError:
            time.sleep(0.1)
    raise TimeoutError(f"port {port} never opened")


@pytest.fixture(scope="module")
def anvil_url():
    if not shutil.which("anvil"):
        pytest.skip("anvil not in PATH")
    proc = subprocess.Popen(
        ["anvil", "--host", "127.0.0.1", "--port", str(ANVIL_PORT)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        _wait_port("127.0.0.1", ANVIL_PORT)
        yield f"http://127.0.0.1:{ANVIL_PORT}"
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


@pytest.fixture(scope="module")
def fund_address(anvil_url):
    if not shutil.which("forge"):
        pytest.skip("forge not in PATH")
    artifact = REPO_ROOT / "out/TheHumanFund.sol/TheHumanFund.json"
    if not artifact.exists():
        pytest.skip(f"{artifact} missing — run `forge build` first")

    script = "test/helpers/DeployForPipelineTest.s.sol:DeployForPipelineTest"
    env = {**os.environ, "PRIVATE_KEY": DEV_KEY}
    res = subprocess.run(
        ["forge", "script", script,
         "--rpc-url", anvil_url, "--broadcast", "--legacy",
         "--private-key", DEV_KEY],
        cwd=REPO_ROOT, env=env, capture_output=True, text=True,
    )
    if res.returncode != 0:
        pytest.fail(
            f"forge script failed (exit {res.returncode}):\n"
            f"--- stdout ---\n{res.stdout}\n--- stderr ---\n{res.stderr}"
        )

    addr = None
    for line in res.stdout.splitlines():
        if "TheHumanFund:" in line:
            for tok in line.split():
                if tok.startswith("0x") and len(tok) == 42:
                    addr = tok
                    break
            if addr:
                break
    if not addr:
        pytest.fail(f"couldn't extract TheHumanFund address from:\n{res.stdout}")
    return addr


def test_read_contract_state_pipeline_matches_onchain_hash(anvil_url, fund_address):
    """Drive the live web3 path: read state via prover code → hash → assert.

    DeployForPipelineTest seeds two memory slots, two nonprofits, an
    InvestmentManager (no positions), and AgentMemory. setAuctionManager
    eagerly opens epoch 1 and freezes its EpochSnapshot. The on-chain hash
    is the ground truth; the Python pipeline must reproduce it byte-for-byte.
    """
    from web3 import Web3

    from prover.client.epoch_state import read_contract_state
    from prover.enclave.input_hash import compute_input_hash

    abi = json.loads(
        (REPO_ROOT / "out/TheHumanFund.sol/TheHumanFund.json").read_text()
    )["abi"]
    w3 = Web3(Web3.HTTPProvider(anvil_url))
    contract = w3.eth.contract(
        address=Web3.to_checksum_address(fund_address), abi=abi
    )

    epoch = contract.functions.currentEpoch().call()
    assert epoch == 1, f"expected epoch 1 after deploy, got {epoch}"

    state = read_contract_state(contract, w3, epoch=epoch)
    py_hash = compute_input_hash(state)

    sol_hash_bytes = contract.functions.computeInputHashForEpoch(epoch).call()

    assert py_hash == bytes(sol_hash_bytes), (
        "prover pipeline hash mismatch:\n"
        f"  python:   0x{py_hash.hex()}\n"
        f"  solidity: 0x{bytes(sol_hash_bytes).hex()}\n"
        "  → check epoch_state.py ABIs vs current contracts, and any new "
        "scalar bound into _hashState."
    )

    # Sanity: the test only matters if the seeded memory actually shows up.
    seeded = [m for m in state["memories"] if m["title"]]
    assert len(seeded) == 2, (
        f"expected 2 seeded memory slots but pipeline returned {len(seeded)}; "
        "AgentMemory ABI may be silently failing to decode entries."
    )
