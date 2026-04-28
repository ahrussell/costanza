#!/usr/bin/env python3
"""Contract interaction — read state and submit transactions.

Wraps web3.py calls to TheHumanFund contract for:
- Reading auction state (phase, bonds, timing)
- Reading epoch state (treasury, nonprofits, investments, etc.)
- Submitting transactions (syncPhase, commit, reveal, submitAuctionResult, etc.)
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
        # Use currentEpoch (actual contract state). The client calls
        # syncPhase() to advance — the contract always reflects the
        # up-to-date epoch + auction data for any action path.
        epoch = self.contract.functions.currentEpoch().call()
        am = self.am
        # Current-auction AM views take no args (the AM is timing-agnostic
        # and holds exactly one live auction at a time).
        phase = am.functions.phase().call()
        winner = am.functions.winner().call()
        winning_bid = am.functions.winningBid().call()
        bond_amount = am.functions.bond().call()
        # Seed is main-owned now — captured at reveal-close into epochSeeds.
        seed = self.contract.functions.epochSeeds(epoch).call()

        # Timing data for wall-clock phase resolution. Timing is main-owned
        # now; AM has no notion of time.
        start_time = self.contract.functions.currentAuctionStartTime().call()
        commit_window = self.contract.functions.commitWindow().call()
        reveal_window = self.contract.functions.revealWindow().call()
        execution_window = self.contract.functions.executionWindow().call()
        now = self.w3.eth.get_block("latest")["timestamp"]

        # Authoritative "epoch resolved" signal is epochs[e].executed. Pulled
        # alongside the phase so the dispatcher can short-circuit once a
        # winner has already submitted successfully.
        record = self.contract.functions.getEpochRecord(epoch).call()
        executed = bool(record[6])  # 7th field per EpochRecord layout

        return {
            "epoch": epoch,
            "contract_phase": phase,
            "executed": executed,
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

        For the current (live) auction, uses the AM's current-auction
        views. For past epochs, uses historical views.
        """
        my_addr = self.account.address
        am = self.am
        current_epoch = am.functions.currentEpoch().call()
        is_current = epoch == current_epoch

        if is_current:
            committers = am.functions.getCommitters().call()
            committed = any(Web3.to_checksum_address(c) == my_addr for c in committers)
            revealed = am.functions.didReveal(my_addr).call() if committed else False
            winner = am.functions.winner().call()
        else:
            committers = am.functions.getCommittersOfEpoch(epoch).call()
            committed = any(Web3.to_checksum_address(c) == my_addr for c in committers)
            revealed = am.functions.didRevealInEpoch(epoch, my_addr).call() if committed else False
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
        """Get the current effective max bid ceiling (live, recomputed against
        current treasury). Use this only for *informational* logging — the
        AuctionManager enforces the snapshotted value frozen at openAuction,
        which is what `get_auction_max_bid` returns.
        """
        return self.contract.functions.effectiveMaxBid().call()

    def get_auction_max_bid(self):
        """Get the AuctionManager's snapshotted maxBid for the in-flight auction.

        This is the binding ceiling for both commit and reveal: the AM stores
        the effectiveMaxBid value computed at openAuction, and reveal() reverts
        with InvalidParams if `bidAmount > am.maxBid`. After-the-fact donations
        that would lift `fund.effectiveMaxBid()` do NOT lift this value.
        """
        am_address = self._auction_manager_address()
        if am_address is None or am_address == "0x" + "0" * 40:
            # Pre-setAuctionManager state (shouldn't happen post-deploy).
            return self.contract.functions.maxBid().call()
        am = self.w3.eth.contract(
            address=am_address,
            abi=[{
                "inputs": [],
                "name": "maxBid",
                "outputs": [{"type": "uint256"}],
                "stateMutability": "view",
                "type": "function",
            }],
        )
        return am.functions.maxBid().call()

    def _auction_manager_address(self):
        """Cached lookup of the AM address bound to the fund."""
        if not hasattr(self, "_am_addr_cached"):
            try:
                self._am_addr_cached = self.contract.functions.auctionManager().call()
            except Exception:
                self._am_addr_cached = None
        return self._am_addr_cached

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

    def read_contract_state(self, epoch=None):
        """Read the full epoch state the enclave needs.

        Reads scalars from the frozen `EpochSnapshot` directly. If epoch
        is specified, reads that epoch's snapshot instead of currentEpoch().
        """
        from .epoch_state import read_contract_state
        return read_contract_state(self.contract, self.w3, epoch=epoch)

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
        """Claim bond refund for a past epoch from the AuctionManager.

        Returns the receipt, or None if no bond is claimable. Past-epoch
        participation is tracked via `didRevealInEpoch` (historical) rather
        than the current-auction `didReveal(runner)` view.
        """
        # Check eligibility first to avoid wasting gas
        if not self.am.functions.didRevealInEpoch(epoch, self.account.address).call():
            return None
        winner = self.am.functions.getWinner(epoch).call()
        if winner.lower() == self.account.address.lower():
            return None  # winners were paid bond + bounty in settleExecution
        if self.am.functions.hasClaimed(epoch, self.account.address).call():
            return None  # already claimed

        receipt = self.send_tx(self.am.functions.claimBond(epoch), gas=100_000)
        logger.info("claimBond(%d) confirmed: gas=%s", epoch, receipt.get("gasUsed", "?"))
        return receipt

    def send_tx(self, fn, value=0, gas=None):
        """Build, sign, and send a transaction.

        Args:
            fn: Contract function call (e.g., self.contract.functions.syncPhase())
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
