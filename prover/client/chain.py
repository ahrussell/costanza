#!/usr/bin/env python3
"""Contract interaction — read state and submit transactions.

Wraps web3.py calls to TheHumanFund contract for:
- Reading auction state (phase, bonds, timing)
- Reading epoch state (treasury, nonprofits, investments, etc.)
- Submitting transactions (startEpoch, commit, reveal, closeCommit, etc.)
"""

import json
import logging
from pathlib import Path
from web3 import Web3

logger = logging.getLogger(__name__)


ABI_DIR = Path(__file__).parent.parent.parent / "out"


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
        # Lazy-loaded auction manager contract
        self._am = None

    @property
    def am(self):
        """Auction manager contract (lazy-loaded)."""
        if self._am is None:
            am_addr = self.contract.functions.auctionManager().call()
            self._am = self.w3.eth.contract(
                address=Web3.to_checksum_address(am_addr),
                abi=load_abi("AuctionManager"),
            )
        return self._am

    def get_auction_phase(self):
        """Get current auction state from individual AuctionManager getters."""
        epoch = self.contract.functions.currentEpoch().call()
        am = self.am
        phase = am.functions.getPhase(epoch).call()
        winner = am.functions.getWinner(epoch).call()
        winning_bid = am.functions.getWinningBid(epoch).call()
        bond_amount = am.functions.getBond(epoch).call()
        seed = am.functions.getRandomnessSeed(epoch).call()
        return {
            "epoch": epoch,
            "phase": phase,
            "winner": winner,
            "winning_bid": winning_bid,
            "bond_amount": bond_amount,
            "randomness_seed": seed,
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
        try:
            return self.contract.functions.epochEthUsdPrice().call()
        except Exception:
            logger.warning("ETH/USD price fetch failed, using $2000 fallback", exc_info=True)
            return 2000 * 10**8  # fallback: $2000 in 8-decimal format

    def read_contract_state(self):
        """Read full contract state for epoch context building.

        Delegates to runner.epoch_state which reads all on-chain data.
        """
        from .epoch_state import read_contract_state
        return read_contract_state(self.contract, self.w3)

    def build_contract_state_for_tee(self, state):
        """Build structured contract state for TEE input hash verification."""
        from .epoch_state import build_contract_state_for_tee
        return build_contract_state_for_tee(self.contract, self.w3, state)

    def send_tx(self, fn, value=0, gas=None):
        """Build, sign, and send a transaction.

        Args:
            fn: Contract function call (e.g., self.contract.functions.startEpoch())
            value: ETH value to send in wei.
            gas: Gas limit (estimated if not provided).

        Returns:
            Transaction receipt.

        Raises:
            RuntimeError: If the transaction reverts on-chain (receipt status != 1).
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
        raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction
        tx_hash = self.w3.eth.send_raw_transaction(raw)
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
        if receipt["status"] != 1:
            raise RuntimeError(
                f"Transaction reverted on-chain: tx={tx_hash.hex()}, "
                f"gas_used={receipt.get('gasUsed', '?')}"
            )
        return receipt
