#!/usr/bin/env python3
"""Contract interaction — read state and submit transactions.

Wraps web3.py calls to TheHumanFund contract for:
- Reading auction state (phase, bonds, timing)
- Reading epoch state (treasury, nonprofits, investments, etc.)
- Submitting transactions (startEpoch, commit, reveal, closeCommit, etc.)
"""

import json
from pathlib import Path
from web3 import Web3


ABI_DIR = Path(__file__).parent.parent / "out"


def load_abi(contract_name):
    """Load ABI from forge output directory."""
    abi_path = ABI_DIR / f"{contract_name}.sol" / f"{contract_name}.json"
    with open(abi_path) as f:
        return json.loads(f.read())["abi"]


class ChainClient:
    def __init__(self, rpc_url, private_key, contract_address):
        self.w3 = Web3(Web3.HTTPProvider(rpc_url))
        self.account = self.w3.eth.account.from_key(private_key)
        self.contract = self.w3.eth.contract(
            address=Web3.to_checksum_address(contract_address),
            abi=load_abi("TheHumanFund"),
        )

    def get_auction_phase(self):
        """Get current auction phase (0=IDLE, 1=COMMIT, 2=REVEAL, 3=EXECUTION, 4=SETTLED)."""
        epoch = self.contract.functions.currentEpoch().call()
        state = self.contract.functions.getAuctionState(epoch).call()
        return {
            "epoch": epoch,
            "start_time": state[0],
            "phase": state[1],  # 0=IDLE, 1=COMMIT, 2=REVEAL, 3=EXECUTION, 4=SETTLED
            "winner": state[2],
            "winning_bid": state[3],
            "bond_amount": state[4],
            "randomness_seed": state[5],
        }

    def get_current_bond(self):
        """Get the current bond amount required for bidding."""
        return self.contract.functions.currentBond().call()

    def get_effective_max_bid(self):
        """Get the current effective max bid ceiling."""
        return self.contract.functions.effectiveMaxBid().call()

    def get_gas_price(self):
        """Get current gas price in wei."""
        return self.w3.eth.gas_price

    def get_eth_usd_price(self):
        """Get the ETH/USD price snapshotted for the current epoch."""
        epoch = self.contract.functions.currentEpoch().call()
        try:
            return self.contract.functions.epochEthUsdPrice(epoch).call()
        except Exception:
            return 2000 * 10**8  # fallback: $2000 in 8-decimal format

    def read_contract_state(self):
        """Read full contract state for epoch context building.

        Returns a structured dict suitable for input hash computation
        and epoch context building.

        TODO: Extract full implementation from agent/runner.py
        """
        raise NotImplementedError("Full state reading not yet extracted from runner.py")

    def send_tx(self, fn, value=0, gas=None):
        """Build, sign, and send a transaction.

        Args:
            fn: Contract function call (e.g., self.contract.functions.startEpoch())
            value: ETH value to send in wei.
            gas: Gas limit (estimated if not provided).

        Returns:
            Transaction receipt.
        """
        tx = fn.build_transaction({
            "from": self.account.address,
            "nonce": self.w3.eth.get_transaction_count(self.account.address),
            "value": value,
            "maxFeePerGas": self.w3.eth.gas_price * 2,
            "maxPriorityFeePerGas": self.w3.eth.max_priority_fee,
        })
        if gas:
            tx["gas"] = gas
        else:
            tx["gas"] = self.w3.eth.estimate_gas(tx)

        signed = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        return self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
