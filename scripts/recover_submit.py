#!/usr/bin/env python3
"""Emergency recovery script: read serial console from stuck inference VM and submit on-chain."""
import hashlib
import json
import os
import requests
import subprocess
import sys
import time
from pathlib import Path

from web3 import Web3
from eth_account import Account

OUTPUT_START_MARKER = "===HUMANFUND_OUTPUT_START==="
OUTPUT_END_MARKER = "===HUMANFUND_OUTPUT_END==="

VM_NAME = "humanfund-runner-da2b81f2"
ZONE = "us-central1-a"
PROJECT = "the-human-fund"
FUND_ADDR = "0x08e18f25f42F12fFAAca6b55247B06828150C3C9"
RPC_URL = os.environ.get("RPC_URL", "https://sepolia.base.org")
PRIVATE_KEY = os.environ.get("PRIVATE_KEY")

# Load ABIs
SCRIPT_DIR = Path(__file__).parent.parent
fund_abi = json.loads((SCRIPT_DIR / "out/TheHumanFund.sol/TheHumanFund.json").read_text())["abi"]

def gcloud(args, check=True, timeout=60):
    cmd = f"gcloud {args} --project={PROJECT}"
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode != 0:
        raise RuntimeError(f"gcloud failed: {result.stderr[:500]}")
    return result.stdout.strip()

def get_serial_output():
    print("Fetching serial console output...")
    return gcloud(f"compute instances get-serial-port-output {VM_NAME} --zone={ZONE}", timeout=30)

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
    if not PRIVATE_KEY:
        print("ERROR: PRIVATE_KEY not set")
        sys.exit(1)

    account = Account.from_key(PRIVATE_KEY)
    print(f"Account: {account.address}")

    # Get serial output and parse result
    output = get_serial_output()
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

    # Extract worldview update if any
    action_json = result.get("action", {})
    if isinstance(action_json, str):
        action_json = json.loads(action_json)
    wv = action_json.get("worldview", {}) if isinstance(action_json, dict) else {}
    policy_slot = wv.get("slot", -1)
    policy_text = wv.get("policy", "")

    # Verify REPORTDATA
    w3 = Web3(Web3.HTTPProvider(RPC_URL, request_kwargs={"timeout": 60}))
    fund = w3.eth.contract(address=FUND_ADDR, abi=fund_abi)

    current_epoch = fund.functions.currentEpoch().call()
    input_hash_raw = fund.functions.epochInputHashes(current_epoch).call()
    input_hash_bytes = input_hash_raw if isinstance(input_hash_raw, bytes) else input_hash_raw.to_bytes(32, "big")
    print(f"Contract input hash: 0x{input_hash_bytes.hex()[:16]}...")

    prompt_path = SCRIPT_DIR / "prover" / "prompts" / "system.txt"
    prompt_hash = hashlib.sha256(prompt_path.read_text().strip().encode("utf-8")).digest()
    output_hash = Web3.keccak(
        hashlib.sha256(action_bytes).digest() +
        hashlib.sha256(reasoning_bytes).digest() +
        prompt_hash
    )
    expected_rd = hashlib.sha256(input_hash_bytes + output_hash).digest()
    tee_rd = bytes.fromhex(result["report_data"].replace("0x", ""))[:32]
    print(f"REPORTDATA match: {expected_rd == tee_rd}")
    if expected_rd != tee_rd:
        print(f"  Expected: {expected_rd.hex()[:32]}...")
        print(f"  TEE:      {tee_rd.hex()[:32]}...")

    # Build and submit tx
    nonce = w3.eth.get_transaction_count(account.address)
    gas_price = w3.eth.gas_price
    chain_id = w3.eth.chain_id
    print(f"Submitting (nonce={nonce}, verifier_id=2)...")

    calldata = fund.functions.submitAuctionResult(
        action_bytes, reasoning_bytes, attestation_bytes, 2, policy_slot, policy_text
    )._encode_transaction_data()
    tx = {
        "from": account.address,
        "to": FUND_ADDR,
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
    print(f"Tx: https://sepolia.basescan.org/tx/{tx_hash.hex()}")

    raw_tx_hex = "0x" + raw_tx.hex()
    for attempt in range(5):
        try:
            resp = requests.post(RPC_URL, json={
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
