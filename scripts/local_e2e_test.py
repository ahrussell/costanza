#!/usr/bin/env python3
"""
Local end-to-end test for the auction flow.
Runs against local Anvil + llama-server + enclave_runner.

Usage:
    python3 scripts/local_e2e_test.py
"""
import hashlib
import json
import os
import sys
import time
from pathlib import Path
from urllib.request import urlopen, Request

from web3 import Web3
from eth_account import Account

# Config
RPC_URL = "http://127.0.0.1:8545"
TEE_URL = "http://127.0.0.1:8090"
CONTRACT_ADDRESS = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
BID_AMOUNT_WEI = 1000000000000000  # 0.001 ETH

# Load ABI
ABI_PATH = Path(__file__).parent.parent / "out" / "TheHumanFund.sol" / "TheHumanFund.json"
artifact = json.loads(ABI_PATH.read_text())
ABI = artifact["abi"]

def main():
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    account = Account.from_key(PRIVATE_KEY)
    contract = w3.eth.contract(address=Web3.to_checksum_address(CONTRACT_ADDRESS), abi=ABI)

    print(f"Connected: {w3.is_connected()}")
    print(f"Account: {account.address}")
    print(f"Balance: {w3.from_wei(w3.eth.get_balance(account.address), 'ether')} ETH")
    print(f"Epoch: {contract.functions.currentEpoch().call()}")
    print()

    # === Step 1: Start Epoch ===
    print("=== Step 1: startEpoch() ===")
    tx = contract.functions.startEpoch().build_transaction({
        "from": account.address,
        "nonce": w3.eth.get_transaction_count(account.address),
        "gas": 500000,
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    print(f"  Status: {'SUCCESS' if receipt.status == 1 else 'FAILED'}")

    epoch = contract.functions.currentEpoch().call()
    input_hash = contract.functions.epochInputHashes(epoch).call()
    print(f"  Epoch: {epoch}")
    print(f"  Input hash: 0x{input_hash.hex()}")
    print()

    # === Step 2: Bid ===
    print("=== Step 2: bid() ===")
    bond = BID_AMOUNT_WEI * 20 // 100  # 20%
    tx = contract.functions.bid(BID_AMOUNT_WEI).build_transaction({
        "from": account.address,
        "value": bond,
        "nonce": w3.eth.get_transaction_count(account.address),
        "gas": 500000,
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    print(f"  Status: {'SUCCESS' if receipt.status == 1 else 'FAILED'}")
    print(f"  Bid: {BID_AMOUNT_WEI / 1e18} ETH, Bond: {bond / 1e18} ETH")
    print()

    # === Step 3: Wait for bidding window ===
    bid_window = contract.functions.biddingWindow().call()
    print(f"Waiting {bid_window + 2}s for bidding window to close...")
    time.sleep(bid_window + 2)

    # === Step 4: Close Auction ===
    print("=== Step 4: closeAuction() ===")
    tx = contract.functions.closeAuction().build_transaction({
        "from": account.address,
        "nonce": w3.eth.get_transaction_count(account.address),
        "gas": 500000,
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    print(f"  Status: {'SUCCESS' if receipt.status == 1 else 'FAILED'}")

    # Get seed
    auction = contract.functions.getAuctionState(epoch).call()
    seed = auction[6]  # randomnessSeed is 7th element (index 6)
    print(f"  Seed: {seed}")
    print(f"  Winner: {auction[3]}")
    print()

    # === Step 5: Run TEE Inference ===
    print("=== Step 5: TEE Inference ===")
    # Build a minimal epoch context
    state = {
        "treasury": w3.from_wei(contract.functions.treasuryBalance().call(), 'ether'),
        "commission": contract.functions.commissionRateBps().call() / 100,
        "epoch": epoch,
    }
    epoch_context = f"""=== EPOCH {epoch} STATE ===
Treasury balance: {state['treasury']:.4f} ETH
Commission rate: {state['commission']}%
Max bid ceiling: 0.001 ETH
Fund age: {epoch} epochs
Epochs since last donation: 0
"""

    body = {
        "epoch_context": epoch_context,
        "input_hash": "0x" + input_hash.hex(),
        "seed": seed,
    }

    max_retries = 5
    tee_result = None
    for attempt in range(1, max_retries + 1):
        print(f"  Attempt {attempt}/{max_retries}...")
        try:
            req = Request(
                f"{TEE_URL}/run_epoch",
                data=json.dumps(body).encode(),
                headers={"Content-Type": "application/json"},
            )
            resp = urlopen(req, timeout=120)
            tee_result = json.loads(resp.read())
            if "error" in tee_result:
                print(f"  Error: {tee_result['error']}")
                tee_result = None
                continue
            print(f"  Action: {tee_result['action']}")
            print(f"  Inference: {tee_result['inference_seconds']}s")
            break
        except Exception as e:
            print(f"  Error: {e}")
            continue

    if not tee_result:
        print("FAILED: Could not get valid inference after retries")
        sys.exit(1)

    action_bytes = bytes.fromhex(tee_result["action_bytes"].replace("0x", ""))
    reasoning_bytes = tee_result["reasoning"].encode("utf-8")[:8000]
    quote_bytes = bytes.fromhex(tee_result["attestation_quote"].replace("0x", ""))

    print(f"  Action bytes: {len(action_bytes)} bytes")
    print(f"  Reasoning: {len(reasoning_bytes)} bytes")
    print(f"  Quote: {len(quote_bytes)} bytes")
    print()

    # === Step 6: Verify REPORTDATA matches ===
    print("=== Step 6: Verify REPORTDATA ===")
    expected_rd = hashlib.sha256(
        input_hash +
        hashlib.sha256(action_bytes).digest() +
        hashlib.sha256(reasoning_bytes).digest() +
        seed.to_bytes(32, "big")
    ).digest()
    actual_rd = bytes.fromhex(tee_result["report_data"].replace("0x", ""))[:32]
    match = expected_rd == actual_rd
    print(f"  Expected: 0x{expected_rd.hex()[:16]}...")
    print(f"  Actual:   0x{actual_rd.hex()[:16]}...")
    print(f"  Match: {match}")
    if not match:
        print("REPORTDATA MISMATCH — submission will revert")
        sys.exit(1)
    print()

    # === Step 7: Submit Auction Result ===
    print("=== Step 7: submitAuctionResult() ===")
    try:
        tx = contract.functions.submitAuctionResult(
            action_bytes, reasoning_bytes, quote_bytes
        ).build_transaction({
            "from": account.address,
            "nonce": w3.eth.get_transaction_count(account.address),
            "gas": 6000000,
        })
        signed = account.sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
        print(f"  Status: {'SUCCESS' if receipt.status == 1 else 'REVERTED'}")
        print(f"  Gas used: {receipt.gasUsed}")
        print(f"  Tx hash: {tx_hash.hex()}")
    except Exception as e:
        print(f"  FAILED: {e}")
        sys.exit(1)

    # === Step 8: Verify State ===
    print()
    print("=== Step 8: Verify State ===")
    new_epoch = contract.functions.currentEpoch().call()
    history_hash = contract.functions.historyHash().call()
    print(f"  Epoch: {epoch} -> {new_epoch}")
    print(f"  History hash: 0x{history_hash.hex()[:16]}...")
    print(f"  Treasury: {w3.from_wei(contract.functions.treasuryBalance().call(), 'ether')} ETH")

    if new_epoch == epoch + 1:
        print()
        print("SUCCESS! Full auction lifecycle completed.")
    else:
        print()
        print("FAILED: Epoch did not advance")
        sys.exit(1)


if __name__ == "__main__":
    main()
