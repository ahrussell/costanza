#!/usr/bin/env python3
"""Build a state JSON per executed testnet epoch (1..N) for the memory battery.

Each output file matches the shape that `prompt_builder.build_epoch_context`
expects: snapshot-derived scalars + nonprofits + history + investments +
messages + a *historical* memory snapshot reconstructed by replaying
MemoryEntrySet events up to the previous epoch's execution block.

Output: data/epoch_NN.json (zero-padded, sorted lexicographically)
"""

import json
import os
import sys
from pathlib import Path

# Make prover.* importable
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from web3 import Web3
from prover.client.epoch_state import read_contract_state
from prover.client.chain import load_abi

_FUND_ABI = load_abi("TheHumanFund")
_AGENT_MEMORY_ABI = load_abi("AgentMemory")


RPC_URL = os.environ.get("RPC_URL", "https://sepolia.base.org")
CONTRACT_ADDRESS = os.environ.get(
    "CONTRACT_ADDRESS", "0xA0eB246cba399DD84B7De7f298b00A775065F345"
)
DEPLOY_BLOCK = int(os.environ.get("DEPLOY_BLOCK", "40678011"))
OUT_DIR = Path(os.environ.get("OUT_DIR", "/tmp/battery_data"))
CHUNK = 9500  # Base Sepolia public RPC limit is 10k


def chunked_get_logs(contract_event, from_block, to_block, chunk=CHUNK):
    """Paginated event fetch — public Base Sepolia RPC caps eth_getLogs at 10k blocks."""
    out = []
    start = from_block
    while start <= to_block:
        end = min(start + chunk - 1, to_block)
        out.extend(contract_event.get_logs(from_block=start, to_block=end))
        start = end + 1
    return out


def to_jsonable(v):
    if isinstance(v, bytes):
        return "0x" + v.hex()
    if isinstance(v, dict):
        return {k: to_jsonable(x) for k, x in v.items()}
    if isinstance(v, list):
        return [to_jsonable(x) for x in v]
    if isinstance(v, tuple):
        return [to_jsonable(x) for x in v]
    return v


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    fund = w3.eth.contract(address=Web3.to_checksum_address(CONTRACT_ADDRESS), abi=_FUND_ABI)

    current_epoch = fund.functions.currentEpoch().call()
    print(f"Current epoch: {current_epoch}")

    mem_addr = fund.functions.agentMemory().call()
    mem = w3.eth.contract(address=Web3.to_checksum_address(mem_addr), abi=_AGENT_MEMORY_ABI)
    print(f"AgentMemory: {mem_addr}")

    head = w3.eth.block_number
    print(f"Head block: {head}")

    print("Fetching DiaryEntry events to map epoch -> exec block...")
    diary_logs = chunked_get_logs(fund.events.DiaryEntry, DEPLOY_BLOCK, head)
    epoch_exec_block = {}
    for log in diary_logs:
        epoch_exec_block[int(log["args"]["epoch"])] = int(log["blockNumber"])
    print(f"  {len(epoch_exec_block)} executed epochs found: {sorted(epoch_exec_block)}")

    print("Fetching MemoryEntrySet events to reconstruct memory history...")
    mem_logs = chunked_get_logs(mem.events.MemoryEntrySet, DEPLOY_BLOCK, head)
    mem_logs.sort(key=lambda l: (l["blockNumber"], l["logIndex"]))
    print(f"  {len(mem_logs)} MemoryEntrySet events")

    # Build a lookup: for each epoch e, the memory state shown to the model
    # at the start of e is the cumulative effect of all MemoryEntrySet
    # events whose block <= epoch (e-1)'s exec block.
    sorted_executed = sorted(epoch_exec_block)
    if not sorted_executed:
        print("No executed epochs — nothing to prep")
        return

    epochs_to_test = sorted_executed
    print(f"Will produce state JSONs for epochs: {epochs_to_test}")

    for e in epochs_to_test:
        # Cutoff = previous epoch's exec block (or 0 if e is the first executed)
        prev_executed = [x for x in sorted_executed if x < e]
        cutoff = epoch_exec_block[prev_executed[-1]] if prev_executed else 0

        slots = [{"title": "", "body": ""} for _ in range(10)]
        for log in mem_logs:
            if log["blockNumber"] > cutoff:
                break
            slot = int(log["args"]["slot"])
            if 0 <= slot < 10:
                slots[slot] = {
                    "title": log["args"]["title"],
                    "body": log["args"]["body"],
                }

        # Pull the rest of the state via the prover's existing reader (uses
        # the snapshot for scalars + history). Then override the memory
        # field with the historical reconstruction above.
        try:
            state = read_contract_state(fund, w3, epoch=e)
        except Exception as ex:
            print(f"  epoch {e}: read_contract_state failed: {ex}")
            continue
        state["memories"] = slots

        outfile = OUT_DIR / f"epoch_{e:02d}.json"
        with outfile.open("w") as f:
            json.dump(to_jsonable(state), f, indent=2, default=str)

        active = sum(1 for s in slots if s["title"] or s["body"])
        print(f"  epoch {e:2d}: cutoff={cutoff}  memory_active={active}/10  -> {outfile.name}")

    print(f"\nDone. {len(epochs_to_test)} files in {OUT_DIR}")


if __name__ == "__main__":
    main()
