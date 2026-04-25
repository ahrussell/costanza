#!/usr/bin/env python3
"""Epoch state reading — reads the frozen snapshot for TEE input.

The snapshot-only pinning invariant
===================================

The contract's on-chain input hash is computed *only* from
`_epochSnapshots[epoch]` — the `_hashSnapshot` function is declared
`pure`, so the Solidity compiler mechanically proves no live-storage
reads leak into the hash path.

For the prover side to be drift-free, this module must mirror that
discipline: every scalar the enclave sees comes from `getEpochSnapshot`,
not from live getters. Raw collection data (nonprofits, messages,
history entries, investment metadata, memory policies) are still
read live, but bounded by counts/heads/epochs frozen in the snapshot.
That bounding is load-bearing — it's why admin-added nonprofits or
new donor messages after auction open are invisible to the enclave
and can't break the hash.

Drift analysis per collection:
  - Nonprofits: metadata (name/description/ein) is immutable
    post-`addNonprofit`; per-entry counters (totalDonated*) only change
    in agent donate actions (which run after verify). Bounded by
    snap.nonprofit_count → drift-free.
  - Messages: stored hashes are immutable at `donateWithMessage` time;
    new messages append. Bounded by snap.message_head/count → drift-free.
  - History: `epochContentHashes[ep]` is written once per epoch and
    never modified. Bounded by snap.epoch → drift-free.
  - Investments: currentValues/active come from the snapshot directly
    (they drift due to yield); immutable metadata (name/risk/apy) is
    read live bounded by snap.investment_protocol_count → drift-free.
  - Memory: entries can only change via `_applyMemoryUpdate`,
    which runs inside `submitAuctionResult`
    AFTER input-hash verification. Between freeze and verify, memory
    is stable. Read live → drift-free in the observed window.

If you're tempted to add a new contract call here, first ask whether
the underlying field is snapshot-frozen or immutable. If neither, you
need to add it to `EpochSnapshot` first. The static allowlist test in
`prover/enclave/test_hash_coverage.py` enforces this at commit time.
"""

import logging
from web3 import Web3

logger = logging.getLogger(__name__)


# ─── ABIs for sub-contracts ──────────────────────────────────────────────

_IM_ABI = [
    {"name": "getPosition", "type": "function",
     "inputs": [{"name": "protocolId", "type": "uint256"}],
     "outputs": [
         {"name": "depositedEth", "type": "uint256"},
         {"name": "shares", "type": "uint256"},
         {"name": "currentValue", "type": "uint256"},
         {"name": "protocolName", "type": "string"},
         {"name": "riskTier", "type": "uint8"},
         {"name": "expectedApyBps", "type": "uint16"},
         {"name": "active", "type": "bool"},
     ], "stateMutability": "view"},
]

_WV_ABI = [
    {"name": "getEntries", "type": "function", "inputs": [],
     "outputs": [
         {"type": "tuple[10]", "components": [
             {"name": "title", "type": "string"},
             {"name": "body", "type": "string"},
         ]},
     ], "stateMutability": "view"},
]

_MSG_ABI = [
    {"name": "messages", "type": "function",
     "inputs": [{"name": "index", "type": "uint256"}],
     "outputs": [
         {"name": "sender", "type": "address"},
         {"name": "amount", "type": "uint256"},
         {"name": "text", "type": "string"},
         {"name": "epoch", "type": "uint256"},
     ], "stateMutability": "view"},
]


# ─── Snapshot reader ──────────────────────────────────────────────────────

_SNAP_FIELDS = (
    "epoch", "balance", "commission_rate_bps", "max_bid", "effective_max_bid",
    "consecutive_missed", "last_donation_epoch", "last_commission_change_epoch",
    "total_inflows", "total_donated", "total_commissions", "total_bounties",
    "epoch_inflow", "epoch_donation_count", "epoch_eth_usd_price",
    "epoch_duration", "message_head", "message_count", "nonprofit_count",
    "nonprofits_hash", "messages_hash", "history_hash", "memory_hash",
    "investments_hash", "investment_protocol_count",
    "investment_current_values", "investment_active",
)


def read_epoch_snapshot(contract, epoch):
    """Read the frozen EpochSnapshot tuple for `epoch` and unpack it.

    The single storage read the prover needs for all scalars + frozen
    sub-hashes + investment raw values. Raw collection data
    (nonprofits / messages / history / memory entries) still needs
    separate live reads, bounded by the counts returned here.
    """
    snap = contract.functions.getEpochSnapshot(epoch).call()
    # Positional tuple decoding mirroring the Solidity struct layout.
    return dict(zip(_SNAP_FIELDS, (
        snap[0],   # epoch
        snap[1],   # balance
        snap[2],   # commissionRateBps
        snap[3],   # maxBid
        snap[4],   # effectiveMaxBid
        snap[5],   # consecutiveMissedEpochs
        snap[6],   # lastDonationEpoch
        snap[7],   # lastCommissionChangeEpoch
        snap[8],   # totalInflows
        snap[9],   # totalDonatedToNonprofits
        snap[10],  # totalCommissionsPaid
        snap[11],  # totalBountiesPaid
        snap[12],  # currentEpochInflow
        snap[13],  # currentEpochDonationCount
        snap[14],  # epochEthUsdPrice
        snap[15],  # epochDuration
        snap[16],  # messageHead
        snap[17],  # messageCount
        snap[18],  # nonprofitCount
        snap[19],  # nonprofitsHash
        snap[20],  # messagesHash
        snap[21],  # historyHash
        snap[22],  # memoryHash
        snap[23],  # investmentsHash
        snap[24],  # investmentProtocolCount
        snap[25],  # investmentCurrentValues (uint256[21])
        snap[26],  # investmentActive (bool[21])
    )))


# ─── Top-level reader ─────────────────────────────────────────────────────

def read_contract_state(contract, w3, epoch=None):
    """Read the full state the enclave needs, pinned to a specific epoch's
    frozen snapshot. Every scalar comes from the snapshot; raw collection
    data comes from live getters bounded by frozen counts.

    If epoch is not specified, reads currentEpoch(). Callers in the
    execution path should pass the auction's epoch explicitly to avoid
    reading the wrong snapshot after a syncPhase advance.
    """
    if epoch is None:
        epoch = contract.functions.currentEpoch().call()
    snap = read_epoch_snapshot(contract, epoch)

    # ── Scalars copied straight from the frozen snapshot ─────────────────
    state = {
        "epoch": snap["epoch"],
        "treasury_balance": snap["balance"],
        "commission_rate_bps": snap["commission_rate_bps"],
        "max_bid": snap["max_bid"],
        "effective_max_bid": snap["effective_max_bid"],
        "consecutive_missed": snap["consecutive_missed"],
        "last_donation_epoch": snap["last_donation_epoch"],
        "last_commission_change_epoch": snap["last_commission_change_epoch"],
        "total_inflows": snap["total_inflows"],
        "total_donated": snap["total_donated"],
        "total_commissions": snap["total_commissions"],
        "total_bounties": snap["total_bounties"],
        "epoch_inflow": snap["epoch_inflow"],
        "epoch_donation_count": snap["epoch_donation_count"],
        "epoch_eth_usd_price": snap["epoch_eth_usd_price"],
        "epoch_duration": snap["epoch_duration"],
        "message_head": snap["message_head"],
        "message_count": snap["message_count"],
        "nonprofit_count": snap["nonprofit_count"],
    }

    # ── Nonprofits (live, bounded by snap.nonprofit_count) ───────────────
    # Metadata is immutable post-addProtocol and per-entry counters are
    # stable between freeze and verify (see drift analysis in module doc).
    state["nonprofits"] = []
    for i in range(1, snap["nonprofit_count"] + 1):
        name, description, ein, total_donated, total_donated_usd, donation_count = (
            contract.functions.getNonprofit(i).call()
        )
        state["nonprofits"].append({
            "id": i,
            "name": name,
            "description": description,
            "ein": "0x" + ein.hex() if isinstance(ein, bytes) else ein,
            "total_donated": total_donated,
            "total_donated_usd": total_donated_usd,
            "donation_count": donation_count,
        })

    # ── Decision history (live, bounded by snap.epoch) ───────────────────
    # epochContentHashes[histEpoch] is written once at _recordAndExecute
    # and never modified. Iterate the last ≤MAX_HISTORY_ENTRIES executed
    # epochs by direct getEpochRecord reads.
    state["history"] = []
    history_start = max(0, snap["epoch"] - 20)
    for ep in range(snap["epoch"] - 1, history_start, -1):
        try:
            _, action, reasoning, tb, ta, bounty, executed = (
                contract.functions.getEpochRecord(ep).call()
            )
            if executed:
                state["history"].append({
                    "epoch": ep,
                    "action": "0x" + action.hex() if isinstance(action, bytes) else action,
                    "reasoning": "0x" + reasoning.hex() if isinstance(reasoning, bytes) else reasoning,
                    "treasury_before": tb,
                    "treasury_after": ta,
                    "bounty_paid": bounty,
                })
        except Exception:
            continue

    # ── Investments (snapshot values + live metadata) ────────────────────
    # currentValues and active flags come from the snapshot (they drift).
    # Metadata (name/risk/apy) is immutable post-addProtocol and read
    # live, bounded by snap.investment_protocol_count.
    state["investments"] = []
    try:
        im_addr = contract.functions.investmentManager().call()
        if im_addr and im_addr != "0x0000000000000000000000000000000000000000":
            im = w3.eth.contract(address=Web3.to_checksum_address(im_addr), abi=_IM_ABI)
            pcount = snap["investment_protocol_count"]
            frozen_values = snap["investment_current_values"]
            frozen_active = snap["investment_active"]
            for pid in range(1, pcount + 1):
                deposited, shares, _live_value, pname, risk, apy, _live_active = (
                    im.functions.getPosition(pid).call()
                )
                # Snapshot wins for drift-prone fields.
                state["investments"].append({
                    "id": pid,
                    "name": pname,
                    "deposited": deposited,
                    "shares": shares,
                    "current_value": frozen_values[pid],
                    "risk_tier": risk,
                    "expected_apy_bps": apy,
                    "active": bool(frozen_active[pid]),
                })
    except Exception:
        pass

    # ── Memory (live read — stable between freeze and verify) ─────────────
    # Each slot is a {title, body} pair. All 10 slots are writable.
    # Hash divergence here = REPORTDATA divergence = on-chain submit revert,
    # so don't silently swallow read errors — let them surface immediately.
    state["memories"] = [{"title": "", "body": ""} for _ in range(10)]
    mem_addr = contract.functions.agentMemory().call()
    if mem_addr and mem_addr != "0x0000000000000000000000000000000000000000":
        mem = w3.eth.contract(address=Web3.to_checksum_address(mem_addr), abi=_WV_ABI)
        # web3.py decodes the tuple[10] return as a list of (title, body)
        # tuples. Normalize to dicts so the prompt/hasher see a stable shape.
        raw = mem.functions.getEntries().call()
        normalized = []
        for entry in raw:
            if isinstance(entry, (list, tuple)) and len(entry) >= 2:
                normalized.append({"title": entry[0] or "", "body": entry[1] or ""})
            elif isinstance(entry, dict):
                normalized.append({
                    "title": entry.get("title", "") or "",
                    "body": entry.get("body", "") or "",
                })
            else:
                normalized.append({"title": "", "body": ""})
        # Pad / truncate to exactly 10 slots.
        while len(normalized) < 10:
            normalized.append({"title": "", "body": ""})
        state["memories"] = normalized[:10]

    # ── Donor messages (live, bounded by snap.message_head/count) ────────
    # Individual message slots are immutable once written, and the
    # frozen head/count exactly pins the unread window the snapshot saw.
    state["donor_messages"] = []
    try:
        msg_contract = w3.eth.contract(address=contract.address, abi=_MSG_ABI)
        unread = snap["message_count"] - snap["message_head"]
        max_msgs = 3  # MAX_MESSAGES_PER_EPOCH
        emit = min(unread, max_msgs)
        logger.info("Messages: head=%d count=%d unread=%d emit=%d",
                     snap["message_head"], snap["message_count"], unread, emit)
        for i in range(emit):
            sender, amount, text, msg_epoch = (
                msg_contract.functions.messages(snap["message_head"] + i).call()
            )
            state["donor_messages"].append({
                "sender": sender,
                "amount": amount,
                "text": text,
                "epoch": msg_epoch,
            })
    except Exception as e:
        logger.error("Failed to read donor messages: %s", e)

    return state
