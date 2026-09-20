#!/usr/bin/env python3
"""Read-only historical export, pinned to finalized blocks and verified input commitments.

Uses the repository's .venv (web3/eth_abi). No account or signing key is loaded.
Raw RPC responses are cached locally; no GPU or GCloud access is needed.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import sys
import threading
import time
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
import requests
from web3 import Web3
from eth_utils.abi import get_abi_output_types
from prover.client.epoch_state import _IM_ABI, _WV_ABI, _MSG_ABI, _SNAP_FIELDS
from prover.enclave import input_hash as ih

ADDRESS = "0x678dC1756b123168f23a698374C000019e38318c"
DEPLOY_BLOCK = 45330578
ZERO = "0x" + "00"*20


def normalize(value):
    if isinstance(value, bytes):
        return "0x" + value.hex()
    if hasattr(value, "items"):
        return {k: normalize(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [normalize(v) for v in value]
    return value


def save(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(normalize(obj), indent=2, sort_keys=True) + "\n")


class RPC:
    def __init__(self, url, cache):
        if urlparse(url).hostname == "humanfund-rpc-cache.thehumanfund.workers.dev":
            raise ValueError("Website proxy is unsafe for historical eth_call block pinning")
        self.url, self.cache = url, cache
        cache.mkdir(parents=True, exist_ok=True)
        self.local = threading.local()
        self.rate_lock = threading.Lock()
        self.next_request = 0

    def many(self, requests_):
        results, pending, locations = [None]*len(requests_), [], []
        for i, (method, params) in enumerate(requests_):
            key = hashlib.sha256(json.dumps([method, params], sort_keys=True).encode()).hexdigest()
            path = self.cache / (key + ".json")
            # Never cache moving block tags.
            cacheable = method != "eth_blockNumber" and not any(t in json.dumps(params) for t in ('"latest"', '"finalized"', '"safe"'))
            if cacheable and path.exists():
                stored = json.loads(path.read_text())
                results[i] = stored["result"]
            else:
                pending.append({"jsonrpc": "2.0", "id": i, "method": method, "params": params})
                locations.append((i, path, cacheable))
        for start in range(0, len(pending), 10):
            group = pending[start:start+10]
            if not hasattr(self.local, "session"):
                self.local.session = requests.Session()
            for attempt in range(5):
                with self.rate_lock:
                    delay = self.next_request - time.monotonic()
                    if delay > 0:
                        time.sleep(delay)
                    self.next_request = time.monotonic() + len(group)*0.1
                try:
                    response = self.local.session.post(self.url, json=group, timeout=60)
                except requests.RequestException as e:
                    raise RuntimeError("RPC transport failed: " + type(e).__name__) from None
                if response.status_code in (429, 502, 503, 504):
                    time.sleep(2**attempt)
                    continue
                if response.status_code != 200:
                    raise RuntimeError(f"RPC HTTP status {response.status_code}")
                data = response.json()
                if not isinstance(data, list):
                    raise RuntimeError("RPC batch response is not a list: " + str(data)[:250])
                if any("error" in r for r in data):
                    if all("error" not in r or r["error"].get("code") in (-32016, -32005, 429) for r in data):
                        time.sleep(2**attempt)
                        continue
                    raise RuntimeError("RPC error: " + str([r for r in data if "error" in r])[:500])
                by_id = {r["id"]: r["result"] for r in data}
                for i, path, cacheable in locations[start:start+10]:
                    results[i] = by_id[i]
                    if cacheable:
                        # Different threads may ask the same immutable question.
                        temp = path.with_suffix(f".{threading.get_ident()}.tmp")
                        save(temp, {"request": requests_[i], "result": by_id[i]})
                        temp.replace(path)
                break
            else:
                raise RuntimeError("RPC throttled/unavailable after bounded retries")
        return results

    def one(self, method, params):
        return self.many([(method, params)])[0]


def calls(rpc, functions, block):
    raw = rpc.many([("eth_call", [{"to": f.address, "data": f._encode_transaction_data()}, hex(block)]) for f in functions])
    decoded = []
    codec = Web3().codec
    for fn, value in zip(functions, raw):
        values = codec.decode(get_abi_output_types(fn.abi), bytes.fromhex(value[2:]))
        decoded.append(values[0] if len(values) == 1 else values)
    return decoded


def legacy_memory_hash(entries):
    if not entries:
        return bytes(32)
    if len(entries) != 10:
        raise ValueError("Legacy memory requires exactly ten entries")
    return ih._keccak256(ih._abi_encode(*[("string", e[k]) for e in entries for k in ("title", "body")]))


def verify_state(state, snap, expected, seed):
    components = {
        "nonprofits_hash": ih._hash_nonprofits(state["nonprofits"]),
        "messages_hash": ih._hash_messages(state["donor_messages"]),
        "history_hash": ih._hash_history(state["history"], state["epoch"]),
        "investments_hash": ih._hash_investments(state["investments"], state["investment_manager_wired"]),
    }
    memory = ih._hash_memory(state["memories"])
    scheme = "rolling_variable_length"
    if memory != snap["memory_hash"]:
        memory = legacy_memory_hash(state["memories"])
        scheme = "legacy_fixed_ten"
    components["memory_hash"] = memory
    for name, value in components.items():
        if value != snap[name]:
            raise ValueError(f"Historical {name} does not match frozen commitment")
    base = ih._keccak256(ih._abi_encode(*[("bytes32", h) for h in (
        ih._hash_state(state), components["nonprofits_hash"], components["investments_hash"],
        memory, components["messages_hash"], components["history_hash"])]))
    bound = ih._keccak256(base + seed.to_bytes(32, "big"))
    if bound != expected:
        raise ValueError("Reconstructed seeded input hash does not match on-chain input hash")
    return {"verified": True, "memory_hash_scheme": scheme, "base_input_hash": base,
            "seeded_input_hash": bound, "component_hashes": components}


def export_epoch(rpc, contract, epoch, record, cutoff, out):
    filename = out / "fixtures" / f"epoch_{epoch:04d}.json"
    if filename.exists():
        fixture = json.loads(filename.read_text())
        if fixture["provenance"]["cutoff_hash"] != cutoff["hash"]:
            raise ValueError("Existing fixture belongs to a different cutoff")
        pin = fixture["provenance"]["pre_execution_block"]
        snap_tuple, seed, expected = calls(rpc, [contract.functions.getEpochSnapshot(epoch),
            contract.functions.epochSeeds(epoch), contract.functions.epochInputHashes(epoch)], pin)
        if seed != fixture["seed"] or fixture["epoch_state"]["epoch"] != epoch:
            raise ValueError("Cached fixture seed/epoch mismatch")
        observed = {"timestamp": record[0], "action": record[1], "reasoning": record[2],
            "treasury_before": record[3], "treasury_after": record[4], "bounty_paid": record[5]}
        if fixture["observed_output"] != normalize(observed):
            raise ValueError("Cached historical output differs from cutoff record")
        verify_state(fixture["epoch_state"], dict(zip(_SNAP_FIELDS, snap_tuple)), expected, seed)
        return epoch, "cached and reverified"
    # Base blocks in this interval have two-second timestamps. Verify the
    # candidate header rather than assuming this identity is sufficient.
    number = int(cutoff["number"], 16) - (int(cutoff["timestamp"], 16) - record[0]) // 2
    block = rpc.one("eth_getBlockByNumber", [hex(number), False])
    if int(block["timestamp"], 16) != record[0]:
        raise ValueError("Timestamp-to-block mapping failed; explicit event scan required")
    topic = "0x" + Web3.keccak(text="EpochExecuted(uint256,address,uint256)").hex()
    logs = rpc.one("eth_getLogs", [{"address": ADDRESS, "fromBlock": hex(number), "toBlock": hex(number),
        "topics": [topic, "0x" + epoch.to_bytes(32, "big").hex()]}])
    if len(logs) != 1:
        raise ValueError("Expected exactly one execution event for epoch")
    event = logs[0]
    if event["blockHash"] != block["hash"]:
        raise ValueError("Event/header mismatch")
    pin = number - 1
    header = rpc.one("eth_getBlockByNumber", [hex(pin), False])
    snap_tuple, seed, expected, im_address, mem_address = calls(rpc, [
        contract.functions.getEpochSnapshot(epoch), contract.functions.epochSeeds(epoch),
        contract.functions.epochInputHashes(epoch), contract.functions.investmentManager(),
        contract.functions.agentMemory()], pin)
    if seed <= 0:
        raise ValueError("No seed before submission block; transaction-level replay required")
    snap = dict(zip(_SNAP_FIELDS, snap_tuple))
    state = {k: snap[k] for k in _SNAP_FIELDS[:19] if k != "balance"}
    state["treasury_balance"] = snap["balance"]
    state["nonprofits"] = []
    for i, np in enumerate(calls(rpc, [contract.functions.getNonprofit(i) for i in range(1, snap["nonprofit_count"]+1)], pin), 1):
        state["nonprofits"].append(dict(zip(("id", "name", "description", "ein", "total_donated", "total_donated_usd", "donation_count"), (i, *np))))
    eps = list(range(epoch-1, max(0, epoch-20), -1))
    state["history"] = []
    for ep, r in zip(eps, calls(rpc, [contract.functions.getEpochRecord(e) for e in eps], pin)):
        if r[6]:
            state["history"].append({"epoch": ep, "action": r[1], "reasoning": r[2],
                "treasury_before": r[3], "treasury_after": r[4], "bounty_paid": r[5]})
    state["investment_manager_wired"] = im_address.lower() != ZERO
    state["investments"] = []
    if state["investment_manager_wired"]:
        im = Web3().eth.contract(address=Web3.to_checksum_address(im_address), abi=_IM_ABI)
        for pid, position in enumerate(calls(rpc, [im.functions.getPosition(i) for i in range(1, snap["investment_protocol_count"]+1)], pin), 1):
            dep, shares, _, name, risk, apy, _ = position
            state["investments"].append({"id": pid, "deposited": dep, "shares": shares,
                "current_value": snap["investment_current_values"][pid], "active": snap["investment_active"][pid],
                "name": name, "risk_tier": risk, "expected_apy_bps": apy})
    state["memories"] = []
    if mem_address.lower() != ZERO:
        mem = Web3().eth.contract(address=Web3.to_checksum_address(mem_address), abi=_WV_ABI)
        raw = rpc.one("eth_call", [{"to": mem.address, "data": mem.functions.getEntries()._encode_transaction_data()}, hex(pin)])
        data = bytes.fromhex(raw[2:])
        try:
            entries = Web3().codec.decode(["(string,string)[]"], data)[0]
        except Exception:
            entries = Web3().codec.decode(["(string,string)[10]"], data)[0]
        state["memories"] = [{"title": title, "body": body} for title, body in entries]
    msg = Web3().eth.contract(address=ADDRESS, abi=_MSG_ABI)
    count = min(3, snap["message_count"] - snap["message_head"])
    state["donor_messages"] = [dict(zip(("sender", "amount", "text", "epoch"), value)) for value in
        calls(rpc, [msg.functions.messages(i) for i in range(snap["message_head"], snap["message_head"]+count)], pin)]
    verification = verify_state(state, snap, expected, seed)
    fixture = {"fixture_id": f"epoch_{epoch:04d}", "seed": seed, "epoch_state": state,
        "provenance": {"chain_id": 8453, "contract": ADDRESS, "cutoff_hash": cutoff["hash"],
            "execution_event": event, "pre_execution_block": pin, "pre_execution_block_hash": header["hash"],
            "memory_contract": mem_address, "state_verification": verification},
        "observed_output": {"timestamp": record[0], "action": record[1], "reasoning": record[2],
            "treasury_before": record[3], "treasury_after": record[4], "bounty_paid": record[5]}}
    save(filename, fixture)
    return epoch, verification["memory_hash_scheme"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc", default="https://mainnet.base.org")
    parser.add_argument("--rpc-env-file", type=Path, help="Read only the named RPC variable; never load signing keys")
    parser.add_argument("--rpc-env-key", default="ALCHEMY_BASE_RPC")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--workers", type=int, default=3)
    args = parser.parse_args()
    if args.rpc_env_file:
        for line in args.rpc_env_file.read_text().splitlines():
            line = line.strip().removeprefix("export ")
            if line.startswith(args.rpc_env_key + "="):
                args.rpc = line.split("=", 1)[1].strip().strip('"').strip("'")
                break
        else:
            raise ValueError("Named RPC variable not found")
    out = args.out.resolve()
    rpc = RPC(args.rpc, out / "rpc-cache")
    abi = json.loads((ROOT / "out/TheHumanFund.sol/TheHumanFund.json").read_text())["abi"]
    contract = Web3().eth.contract(address=ADDRESS, abi=abi)
    cutoff_path = out / "cutoff.json"
    if cutoff_path.exists():
        cutoff = json.loads(cutoff_path.read_text())
    else:
        if int(rpc.one("eth_chainId", []), 16) != 8453:
            raise ValueError("Expected Base mainnet")
        cutoff = rpc.one("eth_getBlockByNumber", ["finalized", False])
        save(cutoff_path, cutoff)
    number = int(cutoff["number"], 16)
    current = calls(rpc, [contract.functions.currentEpoch()], number)[0]
    records = calls(rpc, [contract.functions.getEpochRecord(e) for e in range(1, current+1)], number)
    selected = [(e, r) for e, r in enumerate(records, 1) if r[6]]
    inventory = {"cutoff_block": number, "cutoff_hash": cutoff["hash"], "current_epoch": current,
        "executed_epochs": [e for e, _ in selected],
        "not_executed_at_cutoff": [e for e, r in enumerate(records, 1) if not r[6]],
        "selection_rule": "all executed epochs 1 through currentEpoch at fixed finalized cutoff"}
    save(out / "inventory.json", inventory)
    print(f"Cutoff {number}, current epoch {current}, {len(selected)} executed epochs", flush=True)
    failures = []
    with ThreadPoolExecutor(args.workers) as pool:
        futures = {pool.submit(export_epoch, rpc, contract, e, r, cutoff, out): e for e, r in selected}
        for future in as_completed(futures):
            try:
                epoch, scheme = future.result()
                print(f"epoch {epoch}: verified ({scheme})", flush=True)
            except Exception as e:
                epoch = futures[future]
                failures.append({"epoch": epoch, "error": str(e)})
                print(f"epoch {epoch}: FAILED {str(e)[:200]}", flush=True)
    save(out / "export-status.json", {"expected": len(selected), "failures": failures,
        "complete": not failures, "source_abi_sha256": hashlib.sha256(json.dumps(abi, sort_keys=True).encode()).hexdigest(),
        "fixture_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((out / "fixtures").glob("*.json"))}})
    if failures:
        raise SystemExit("Incomplete export; do not silently omit failed epochs")


if __name__ == "__main__":
    main()
