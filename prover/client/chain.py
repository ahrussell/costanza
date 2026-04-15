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
from web3.exceptions import ContractLogicError, ContractCustomError

logger = logging.getLogger(__name__)


ABI_DIR = Path(__file__).parent.parent.parent / "out"


def load_abi(contract_name):
    """Load ABI from forge output directory."""
    abi_path = ABI_DIR / f"{contract_name}.sol" / f"{contract_name}.json"
    with open(abi_path) as f:
        return json.loads(f.read())["abi"]


def build_error_selector_map(*contract_names):
    """Build {selector_hex: error_name} from compiled ABIs.

    Error selectors are deterministic: keccak256("ErrorName(arg_types)")[:4].
    This computes them from ABI definitions instead of hardcoding hex values.

    Returns:
        Dict mapping "0x{selector}" to error name string.
        Example: {"0x0730a2ce": "TimingError", "0xbf930e52": "ProofFailed"}
    """
    selector_map = {}
    for name in contract_names:
        abi = load_abi(name)
        for item in abi:
            if item.get("type") == "error":
                input_types = ",".join(inp["type"] for inp in item.get("inputs", []))
                sig = f"{item['name']}({input_types})"
                selector = Web3.keccak(text=sig)[:4].hex()
                selector_map[f"0x{selector}"] = item["name"]
    return selector_map


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

    def get_auction_state(self):
        """Get current auction state including timing windows for wall-clock phase resolution.

        Returns dict with epoch, contract_phase, winner, bid, bond, seed,
        and timing boundaries (commit_end, reveal_end, exec_end, now).
        """
        # Use currentEpoch (actual contract state), not projectedEpoch.
        # The v2 client calls syncPhase() to advance — projectedEpoch() would
        # return a future epoch that has no auction data in the AuctionManager.
        epoch = self.contract.functions.currentEpoch().call()
        am = self.am
        phase = am.functions.getPhase(epoch).call()
        winner = am.functions.getWinner(epoch).call()
        winning_bid = am.functions.getWinningBid(epoch).call()
        bond_amount = am.functions.getBond(epoch).call()
        seed = am.functions.getRandomnessSeed(epoch).call()

        # Timing data for wall-clock phase resolution
        start_time = am.functions.getStartTime(epoch).call()
        commit_window = am.functions.commitWindow().call()
        reveal_window = am.functions.revealWindow().call()
        execution_window = am.functions.executionWindow().call()
        now = self.w3.eth.get_block("latest")["timestamp"]

        return {
            "epoch": epoch,
            "contract_phase": phase,
            "winner": winner,
            "winning_bid": winning_bid,
            "bond_amount": bond_amount,
            "randomness_seed": seed,
            # Timing boundaries
            "start_time": start_time,
            "commit_end": start_time + commit_window if start_time > 0 else 0,
            "reveal_end": start_time + commit_window + reveal_window if start_time > 0 else 0,
            "exec_end": start_time + commit_window + reveal_window + execution_window if start_time > 0 else 0,
            "now": now,
        }

    def check_participation(self, epoch):
        """Query chain for our participation status in a given epoch.

        Returns dict with committed, revealed, won, winner.
        This is the source of truth — local state is advisory only.

        Uses didReveal() (reads hasRevealed mapping) rather than getBidRecord()
        because getBidRecord is only populated after the auction settles.
        """
        my_addr = self.account.address
        am = self.am

        # Check if we committed by scanning the committers list.
        # hasCommitted is internal in the AM, so we scan the list (bounded by MAX_COMMITTERS).
        committers = am.functions.getCommitters(epoch).call()
        committed = any(Web3.to_checksum_address(c) == my_addr for c in committers)

        # didReveal reads from the live hasRevealed mapping (works during active auctions)
        revealed = am.functions.didReveal(epoch, my_addr).call() if committed else False

        # Epoch-level winner address
        winner = am.functions.getWinner(epoch).call()
        won = revealed and Web3.to_checksum_address(winner) == my_addr

        return {
            "committed": committed,
            "revealed": revealed,
            "won": won,
            "winner": winner,
        }

    def get_current_bond(self):
        """Get the current bond amount required for bidding."""
        return self.contract.functions.currentBond().call()

    def get_my_bid_record(self, epoch):
        """Read this runner's bid record for an epoch from on-chain history.

        Returns the BidRecord struct (revealed, bidAmount, winner, forfeited)
        or None if no record exists. Only populated AFTER the auction settles
        (i.e. after reveal closes for non-winners, or after submission for
        winners). Use this to recover bid_amount when local state was wiped
        but we know from chain that we participated.
        """
        try:
            rec = self.am.functions.getBidRecord(epoch, self.account.address).call()
            # rec = (revealed, bidAmount, winner, forfeited)
            if not rec[0] and rec[1] == 0:
                return None
            return {
                "revealed": rec[0],
                "bid_amount": rec[1],
                "winner": rec[2],
                "forfeited": rec[3],
            }
        except Exception:
            return None

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
        """Read the full epoch state the enclave needs.

        After the pure-`_hashSnapshot` refactor, this reads scalars from
        the frozen `EpochSnapshot` directly — no separate overlay pass.
        """
        from .epoch_state import read_contract_state
        return read_contract_state(self.contract, self.w3)

    def get_epoch_timing(self):
        """Read epoch timing from contract.

        Returns dict with last_epoch_start_time, epoch_duration, next_eligible_time.
        """
        last_start = self.contract.functions.lastEpochStartTime().call()
        duration = self.contract.functions.epochDuration().call()
        return {
            "last_epoch_start_time": last_start,
            "epoch_duration": duration,
            "next_eligible_time": last_start + duration,
        }

    def sync_phase(self, gas=800_000):
        """Call syncPhase() on the fund contract to advance through elapsed phases.

        Returns True if the transaction succeeded.
        """
        receipt = self.send_tx(self.contract.functions.syncPhase(), gas=gas)
        logger.info("syncPhase() confirmed: gas=%s", receipt.get("gasUsed", "?"))
        return True

    def claim_bond(self, epoch):
        """Claim bond refund for a specific epoch from the AuctionManager.

        Returns the receipt, or None if no bond is claimable.
        """
        # Check eligibility first to avoid wasting gas
        if not self.am.functions.didReveal(epoch, self.account.address).call():
            return None
        winner = self.am.functions.getWinner(epoch).call()
        if winner.lower() == self.account.address.lower():
            return None  # winners get bond via settleExecution
        if self.am.functions.hasClaimed(epoch, self.account.address).call():
            return None  # already claimed

        receipt = self.send_tx(self.am.functions.claimBond(epoch), gas=100_000)
        logger.info("claimBond(%d) confirmed: gas=%s", epoch, receipt.get("gasUsed", "?"))
        return receipt

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
        tx_params = {
            "from": self.account.address,
            "nonce": self.w3.eth.get_transaction_count(self.account.address),
            "value": value,
            "maxFeePerGas": self.w3.eth.gas_price * 2,
            "maxPriorityFeePerGas": self.w3.eth.max_priority_fee,
        }
        # Pass gas limit to build_transaction() so web3 doesn't call
        # estimate_gas() during fill_transaction_defaults(). Without this,
        # a contract revert during gas estimation raises ContractCustomError
        # before we even attempt to send the transaction.
        if gas:
            tx_params["gas"] = gas
        tx = fn.build_transaction(tx_params)
        if not gas:
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
