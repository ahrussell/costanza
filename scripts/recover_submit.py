#!/usr/bin/env python3
"""Emergency recovery script: read serial console from stuck inference VM and submit on-chain.

Usage:
    python scripts/recover_submit.py --vm-name <vm> --contract <addr> [--zone <zone>] [--project <proj>]

Reads a TEE result from a stuck VM's serial console and submits it on-chain.
Requires PRIVATE_KEY and RPC_URL environment variables.
"""
import argparse
import hashlib
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

from web3 import Web3
from eth_account import Account

OUTPUT_START_MARKER = "===HUMANFUND_OUTPUT_START==="
OUTPUT_END_MARKER = "===HUMANFUND_OUTPUT_END==="

# Load ABIs
SCRIPT_DIR = Path(__file__).parent.parent
fund_abi = json.loads((SCRIPT_DIR / "out/TheHumanFund.sol/TheHumanFund.json").read_text())["abi"]

def gcloud(args, project, check=True, timeout=60):
    import shlex
    cmd = ["gcloud"] + shlex.split(args) + ["--project", project]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode != 0:
        raise RuntimeError(f"gcloud failed: {result.stderr[:500]}")
    return result.stdout.strip()

def get_serial_output(vm_name, zone, project):
    print("Fetching serial console output...")
    return gcloud(f"compute instances get-serial-port-output {vm_name} --zone={zone}",
                  project=project, timeout=30)

def parse_result(output):
    start_idx = output.find(OUTPUT_START_MARKER)
    end_idx = output.find(OUTPUT_END_MARKER)
    if start_idx < 0 or end_idx <= start_idx:
        return None
    block = output[start_idx + len(OUTPUT_START_MARKER):end_idx]
    last_brace = block.rfind("\n{")
    if last_brace < 0:
        return None
    result_json = block[last_brace:].strip()
    obj, _ = json.JSONDecoder().raw_decode(result_json)
    return obj

def main():
    parser = argparse.ArgumentParser(description="Emergency recovery: submit TEE result from stuck VM")
    parser.add_argument("--vm-name", required=True, help="GCP VM instance name")
    parser.add_argument("--contract", required=True, help="TheHumanFund contract address")
    parser.add_argument("--zone", default="us-central1-a", help="GCP zone (default: us-central1-a)")
    parser.add_argument("--project", default="the-human-fund", help="GCP project (default: the-human-fund)")
    parser.add_argument("--verifier-id", type=int, default=2, help="Verifier ID (default: 2)")
    args = parser.parse_args()

    rpc_url = os.environ.get("RPC_URL")
    private_key = os.environ.get("PRIVATE_KEY")
    if not private_key:
        print("ERROR: PRIVATE_KEY env var not set")
        sys.exit(1)
    if not rpc_url:
        print("ERROR: RPC_URL env var not set")
        sys.exit(1)

    account = Account.from_key(private_key)
    print(f"Account: {account.address}")

    # Get serial output and parse result
    output = get_serial_output(args.vm_name, args.zone, args.project)
    result = parse_result(output)
    if not result:
        print("ERROR: Could not find result in serial output")
        print(f"Serial output tail: {output[-500:]}")
        sys.exit(1)

    print(f"Parsed result: action={result.get('action')}, quote={len(bytes.fromhex(result['attestation_quote'].replace('0x','')))} bytes")

    # Decode fields
    action_bytes = bytes.fromhex(result["action_bytes"].replace("0x", ""))
    reasoning_bytes = result["reasoning"].encode("utf-8")
    attestation_bytes = bytes.fromhex(result["attestation_quote"].replace("0x", ""))

    # Extract memory updates if any — now an array of up to 3
    # {slot, title, body} entries. Defensive: single-dict legacy shape is
    # wrapped; missing/malformed entries are dropped rather than aborting.
    # Note: prefer result["submitted_memory"] if present (attested path).
    raw_mem = result.get("submitted_memory")
    if raw_mem is None:
        # Fallback: extract from action JSON (older result format)
        action_json = result.get("action", {})
        if isinstance(action_json, str):
            action_json = json.loads(action_json)
        raw_mem = action_json.get("memory") if isinstance(action_json, dict) else None
    memory_updates = []
    if isinstance(raw_mem, dict):
        raw_mem = [raw_mem]
    if isinstance(raw_mem, list):
        for entry in raw_mem:
            if not isinstance(entry, dict):
                continue
            try:
                slot = int(entry.get("slot"))
            except (TypeError, ValueError):
                continue
            if slot < 0 or slot > 9:
                continue
            title = str(entry.get("title", ""))[:64]
            body = str(entry.get("body", ""))[:280]
            memory_updates.append((slot, title, body))
        memory_updates = memory_updates[:3]
    print(f"Memory updates to apply: {len(memory_updates)}")

    # Verify REPORTDATA
    # outputHash = keccak256(sha256(action) || sha256(reasoning))
    # Prompt is verified via dm-verity image key, no longer in outputHash.
    w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs={"timeout": 60}))
    fund = w3.eth.contract(address=args.contract, abi=fund_abi)

    current_epoch = fund.functions.currentEpoch().call()
    input_hash_raw = fund.functions.epochInputHashes(current_epoch).call()
    input_hash_bytes = input_hash_raw if isinstance(input_hash_raw, bytes) else input_hash_raw.to_bytes(32, "big")
    print(f"Contract input hash: 0x{input_hash_bytes.hex()[:16]}...")

    output_hash = Web3.keccak(
        hashlib.sha256(action_bytes).digest() +
        hashlib.sha256(reasoning_bytes).digest()
    )
    expected_rd = hashlib.sha256(input_hash_bytes + output_hash).digest()
    tee_rd = bytes.fromhex(result["report_data"].replace("0x", ""))[:32]
    print(f"REPORTDATA match: {expected_rd == tee_rd}")
    if expected_rd != tee_rd:
        print(f"  Expected: {expected_rd.hex()[:32]}...")
        print(f"  TEE:      {tee_rd.hex()[:32]}...")
        print("ERROR: REPORTDATA mismatch — submission will revert on-chain. Aborting.")
        sys.exit(1)

    # Build and submit tx
    nonce = w3.eth.get_transaction_count(account.address)
    gas_price = w3.eth.gas_price
    chain_id = w3.eth.chain_id
    print(f"Submitting (nonce={nonce}, verifier_id={args.verifier_id})...")

    calldata = fund.functions.submitAuctionResult(
        action_bytes, reasoning_bytes, attestation_bytes, args.verifier_id, memory_updates
    )._encode_transaction_data()
    tx = {
        "from": account.address,
        "to": args.contract,
        "data": calldata,
        "nonce": nonce,
        "gas": 15_000_000,
        "maxFeePerGas": gas_price * 3,
        "maxPriorityFeePerGas": w3.to_wei(0.01, "gwei"),
        "chainId": chain_id,
        "type": 2,
    }
    signed = account.sign_transaction(tx)
    raw_tx = signed.raw_transaction
    tx_hash = Web3.keccak(raw_tx)

    explorer = "basescan.org" if chain_id == 8453 else "sepolia.basescan.org"
    print(f"Tx: https://{explorer}/tx/{tx_hash.hex()}")

    import requests
    raw_tx_hex = "0x" + raw_tx.hex()
    for attempt in range(5):
        try:
            resp = requests.post(rpc_url, json={
                "jsonrpc": "2.0", "method": "eth_sendRawTransaction",
                "params": [raw_tx_hex], "id": 1,
            }, timeout=300)
            resp_json = resp.json()
            if "error" in resp_json:
                err = str(resp_json["error"])
                if "already known" in err or "nonce too low" in err:
                    print(f"Tx already in mempool")
                    break
                print(f"RPC error (attempt {attempt+1}): {err[:200]}")
                time.sleep(3)
            else:
                print(f"Tx sent: {resp_json.get('result', 'ok')}")
                break
        except Exception as e:
            print(f"Send error (attempt {attempt+1}): {e}")
            time.sleep(3)

    # Wait for receipt
    print("Waiting for receipt...")
    for i in range(60):
        try:
            receipt = w3.eth.get_transaction_receipt(tx_hash)
            if receipt:
                if receipt.status == 1:
                    print(f"SUCCESS! Gas used: {receipt.gasUsed}")
                else:
                    print(f"REVERTED! Gas used: {receipt.gasUsed}")
                return
        except Exception:
            pass
        time.sleep(5)
    print("Timed out waiting for receipt")

if __name__ == "__main__":
    main()
