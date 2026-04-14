#!/usr/bin/env python3
"""Epoch state reading — reads full contract state for TEE input.

Reads all on-chain data from TheHumanFund and structures it for the TEE.
The TEE independently builds the prompt and computes the input hash from
this data. Used by the runner client and e2e test.
"""

from web3 import Web3


# ─── Contract State Reading ───────────────────────────────────────────────

def read_contract_state(contract, w3):
    """Read all relevant state from the contract for prompt construction."""
    state = {}

    # Basic state
    state["epoch"] = contract.functions.currentEpoch().call()
    state["treasury_balance"] = contract.functions.treasuryBalance().call()
    state["commission_rate_bps"] = contract.functions.commissionRateBps().call()
    state["max_bid"] = contract.functions.maxBid().call()
    state["effective_max_bid"] = contract.functions.effectiveMaxBid().call()
    state["deploy_timestamp"] = contract.functions.deployTimestamp().call()
    state["total_inflows"] = contract.functions.totalInflows().call()
    state["total_donated"] = contract.functions.totalDonatedToNonprofits().call()
    state["total_commissions"] = contract.functions.totalCommissionsPaid().call()
    state["total_bounties"] = contract.functions.totalBountiesPaid().call()
    state["last_donation_epoch"] = contract.functions.lastDonationEpoch().call()
    state["last_commission_change_epoch"] = contract.functions.lastCommissionChangeEpoch().call()
    state["consecutive_missed"] = contract.functions.consecutiveMissedEpochs().call()
    state["epoch_duration"] = contract.functions.epochDuration().call()

    # Per-epoch counters
    state["epoch_inflow"] = contract.functions.currentEpochInflow().call()
    state["epoch_donation_count"] = contract.functions.currentEpochDonationCount().call()

    # ETH/USD price (snapshotted by contract at epoch start)
    try:
        state["epoch_eth_usd_price"] = contract.functions.epochEthUsdPrice().call()
        state["total_donated_usd"] = contract.functions.totalDonatedToNonprofitsUsd().call()
    except Exception:
        state["epoch_eth_usd_price"] = 0
        state["total_donated_usd"] = 0

    # Nonprofits (dynamic count, read from chain)
    state["nonprofits"] = []
    np_count = contract.functions.nonprofitCount().call()
    for i in range(1, np_count + 1):
        name, description, ein, total_donated, total_donated_usd, donation_count = contract.functions.getNonprofit(i).call()
        state["nonprofits"].append({
            "id": i,
            "name": name,
            "description": description,
            "ein": "0x" + ein.hex() if isinstance(ein, bytes) else ein,
            "total_donated": total_donated,
            "total_donated_usd": total_donated_usd,
            "donation_count": donation_count,
        })

    # Decision history (read executed epoch records, most recent first)
    state["history"] = []
    for ep in range(state["epoch"] - 1, max(0, state["epoch"] - 20), -1):
        try:
            ts, action, reasoning, tb, ta, bounty, executed = contract.functions.getEpochRecord(ep).call()
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


    # Investment portfolio (if InvestmentManager is linked)
    state["investments"] = []
    state["total_invested"] = 0
    try:
        total_assets = contract.functions.totalAssets().call()
        state["total_assets"] = total_assets
        # Read investment manager address
        im_addr = contract.functions.investmentManager().call()
        if im_addr and im_addr != "0x0000000000000000000000000000000000000000":
            im_abi = [
                {"name": "protocolCount", "type": "function", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view"},
                {"name": "totalInvestedValue", "type": "function", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view"},
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
            im = w3.eth.contract(address=Web3.to_checksum_address(im_addr), abi=im_abi)
            state["total_invested"] = im.functions.totalInvestedValue().call()
            protocol_count = im.functions.protocolCount().call()

            for pid in range(1, protocol_count + 1):
                deposited, shares, value, pname, risk, apy, active = im.functions.getPosition(pid).call()
                state["investments"].append({
                    "id": pid,
                    "name": pname,
                    "deposited": deposited,
                    "shares": shares,
                    "current_value": value,
                    "risk_tier": risk,
                    "expected_apy_bps": apy,
                    "active": active,
                })
    except Exception as e:
        # No investment manager or error reading — that's fine
        state["total_assets"] = state["treasury_balance"]

    # Worldview (guiding policies)
    state["guiding_policies"] = [""] * 10
    try:
        wv_addr = contract.functions.worldView().call()
        if wv_addr and wv_addr != "0x0000000000000000000000000000000000000000":
            wv_abi = [
                {"name": "getPolicies", "type": "function", "inputs": [],
                 "outputs": [{"type": "string[10]"}], "stateMutability": "view"},
            ]
            wv = w3.eth.contract(address=Web3.to_checksum_address(wv_addr), abi=wv_abi)
            state["guiding_policies"] = list(wv.functions.getPolicies().call())
    except Exception:
        pass

    # Donor messages (unread queue)
    state["donor_messages"] = []
    try:
        msg_abi = [
            {"name": "getUnreadMessages", "type": "function", "inputs": [],
             "outputs": [
                 {"name": "senders", "type": "address[]"},
                 {"name": "amounts", "type": "uint256[]"},
                 {"name": "texts", "type": "string[]"},
                 {"name": "epochNums", "type": "uint256[]"},
             ], "stateMutability": "view"},
            {"name": "messageCount", "type": "function", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view"},
            {"name": "messageHead", "type": "function", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view"},
        ]
        msg_contract = w3.eth.contract(address=contract.address, abi=msg_abi)
        senders, amounts, texts, epoch_nums = msg_contract.functions.getUnreadMessages().call()
        state["message_count"] = msg_contract.functions.messageCount().call()
        state["message_head"] = msg_contract.functions.messageHead().call()
        for i in range(len(senders)):
            state["donor_messages"].append({
                "sender": senders[i],
                "amount": amounts[i],
                "text": texts[i],
                "epoch": epoch_nums[i],
            })
    except Exception:
        state["message_count"] = 0
        state["message_head"] = 0

    return state


def read_epoch_snapshot(contract, w3, epoch):
    """Read the frozen EpochSnapshot for the given epoch.

    Contains drifting values (balance, inflows, message boundaries, investment
    currentValues) frozen at auction open. The prover uses these to pass the
    exact state the input hash was computed from.
    """
    snap_abi = [{"name": "getEpochSnapshot", "type": "function",
                 "inputs": [{"name": "epoch", "type": "uint256"}],
                 "outputs": [{"components": [
                     {"name": "balance", "type": "uint256"},
                     {"name": "totalInflows", "type": "uint256"},
                     {"name": "currentEpochInflow", "type": "uint256"},
                     {"name": "currentEpochDonationCount", "type": "uint256"},
                     {"name": "messageHead", "type": "uint256"},
                     {"name": "messageCount", "type": "uint256"},
                     {"name": "investmentProtocolCount", "type": "uint256"},
                     {"name": "investmentCurrentValues", "type": "uint256[21]"},
                 ], "name": "", "type": "tuple"}],
                 "stateMutability": "view"}]
    snap_contract = w3.eth.contract(address=contract.address, abi=snap_abi)
    snap = snap_contract.functions.getEpochSnapshot(epoch).call()

    return {
        "balance": snap[0],
        "total_inflows": snap[1],
        "current_epoch_inflow": snap[2],
        "current_epoch_donation_count": snap[3],
        "message_head": snap[4],
        "message_count": snap[5],
        "investment_protocol_count": snap[6],
        "investment_current_values": snap[7],  # uint256[21], 1-indexed
    }


def build_contract_state_for_tee(contract, w3, state):
    """Build the structured contract_state dict for TEE input hash verification.

    This mirrors TheHumanFund._computeInputHash() exactly. The TEE computes
    the same hash from this data and binds it into the TDX REPORTDATA.

    Uses the frozen EpochSnapshot for fields that can drift after auction open
    (balance, inflows, message boundaries, investment currentValues). All other
    fields are read live since they can't change until execution.
    """
    epoch = state["epoch"]

    # Read frozen snapshot for drifting values
    snapshot = read_epoch_snapshot(contract, w3, epoch)

    cs = {}

    # 1. State hash inputs — matches _hashState()
    # Use snapshot for drifting fields, live state for non-drifting fields
    cs["state_hash_inputs"] = {
        "epoch": state["epoch"],
        "balance": snapshot["balance"],                               # frozen (drifts with donations)
        "commission_rate_bps": state["commission_rate_bps"],           # safe
        "max_bid": state["max_bid"],                                   # safe
        "consecutive_missed_epochs": state["consecutive_missed"],      # safe
        "last_donation_epoch": state["last_donation_epoch"],           # safe
        "last_commission_change_epoch": state["last_commission_change_epoch"],  # safe
        "total_inflows": snapshot["total_inflows"],                    # frozen (drifts with donations)
        "total_donated_to_nonprofits": state["total_donated"],         # safe
        "total_commissions_paid": state["total_commissions"],          # safe
        "total_bounties_paid": state["total_bounties"],                # safe
        "current_epoch_inflow": snapshot["current_epoch_inflow"],      # frozen (drifts with donations)
        "current_epoch_donation_count": snapshot["current_epoch_donation_count"],  # frozen
        "epoch_eth_usd_price": state.get("epoch_eth_usd_price", 0),   # safe (snapshotted separately)
        "epoch_duration": state["epoch_duration"],                     # safe
    }

    # 2. Nonprofits — matches _hashNonprofits() (safe: don't drift)
    cs["nonprofits"] = []
    for np in state["nonprofits"]:
        cs["nonprofits"].append({
            "name": np["name"],
            "description": np["description"],
            "ein": np["ein"],
            "total_donated": np["total_donated"],
            "total_donated_usd": np.get("total_donated_usd", 0),
            "donation_count": np["donation_count"],
        })

    # 3. Investment hash — recomputed with frozen currentValues from snapshot.
    # depositedEth and shares are safe (only change during execution), but
    # currentValue drifts with DeFi yields. We replicate InvestmentManager.stateHash()
    # using frozen values so the TEE gets a hash matching what the contract computed
    # at auction open.
    try:
        im_addr = contract.functions.investmentManager().call()
        if im_addr and im_addr != "0x0000000000000000000000000000000000000000":
            im_abi = [
                {"name": "protocolCount", "type": "function", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view"},
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
            im = w3.eth.contract(address=Web3.to_checksum_address(im_addr), abi=im_abi)
            protocol_count = im.functions.protocolCount().call()

            # Replicate InvestmentManager.stateHash() with frozen currentValues
            packed = b""
            total_value = 0
            for pid in range(1, protocol_count + 1):
                deposited, shares, _live_value, _name, _risk, _apy, _active = im.functions.getPosition(pid).call()
                frozen_value = snapshot["investment_current_values"][pid]
                total_value += frozen_value
                packed += (pid.to_bytes(32, "big") + deposited.to_bytes(32, "big")
                           + shares.to_bytes(32, "big") + frozen_value.to_bytes(32, "big"))
            packed += protocol_count.to_bytes(32, "big") + total_value.to_bytes(32, "big")
            cs["invest_hash"] = "0x" + Web3.keccak(packed).hex()
        else:
            cs["invest_hash"] = "0x" + "00" * 32
    except Exception:
        cs["invest_hash"] = "0x" + "00" * 32

    # 4. Worldview hash (pre-computed on-chain, safe: doesn't drift)
    try:
        wv_addr = contract.functions.worldView().call()
        if wv_addr and wv_addr != "0x0000000000000000000000000000000000000000":
            wv_abi = [{"name": "stateHash", "type": "function", "inputs": [],
                       "outputs": [{"type": "bytes32"}], "stateMutability": "view"}]
            wv = w3.eth.contract(address=Web3.to_checksum_address(wv_addr), abi=wv_abi)
            cs["worldview_hash"] = "0x" + wv.functions.stateHash().call().hex()
        else:
            cs["worldview_hash"] = "0x" + "00" * 32
    except Exception:
        cs["worldview_hash"] = "0x" + "00" * 32

    # 5. Message hashes — bounded by snapshot's message pointers (messages drift)
    cs["message_hashes"] = []
    try:
        snap_head = snapshot["message_head"]
        snap_count = snapshot["message_count"]
        unread = snap_count - snap_head
        count = min(unread, 20)  # MAX_MESSAGES_PER_EPOCH
        msg_hash_abi = [{"name": "messageHashes", "type": "function",
                         "inputs": [{"type": "uint256"}],
                         "outputs": [{"type": "bytes32"}], "stateMutability": "view"}]
        msg_contract = w3.eth.contract(address=contract.address, abi=msg_hash_abi)
        for i in range(count):
            h = msg_contract.functions.messageHashes(snap_head + i).call()
            cs["message_hashes"].append("0x" + h.hex())
    except Exception:
        pass

    # 6. Epoch content hashes (last 10, most recent first) — safe: don't drift
    cs["epoch_content_hashes"] = []
    try:
        max_history = min(epoch, 10)  # MAX_HISTORY_ENTRIES
        ech_abi = [{"name": "epochContentHashes", "type": "function",
                    "inputs": [{"type": "uint256"}],
                    "outputs": [{"type": "bytes32"}], "stateMutability": "view"}]
        ech_contract = w3.eth.contract(address=contract.address, abi=ech_abi)
        for i in range(max_history):
            hist_epoch = epoch - 1 - i
            h = ech_contract.functions.epochContentHashes(hist_epoch).call()
            cs["epoch_content_hashes"].append("0x" + h.hex())
    except Exception:
        pass

    # Patch the epoch_state dict in-place with frozen snapshot values.
    # The TEE's derive_contract_state() reads from epoch_state, so drifting
    # fields must be overridden before the dict reaches the TEE.
    state["treasury_balance"] = snapshot["balance"]
    state["total_inflows"] = snapshot["total_inflows"]
    state["epoch_inflow"] = snapshot["current_epoch_inflow"]
    state["epoch_donation_count"] = snapshot["current_epoch_donation_count"]
    state["message_head"] = snapshot["message_head"]
    state["message_count"] = snapshot["message_count"]
    # Truncate donor_messages to only those that were unread at snapshot time.
    # getUnreadMessages() returns the live view (may include messages that arrived
    # after auction open). messageHead can't advance between snapshot and now (only
    # _recordAndExecute advances it, and that runs after submission), so the first
    # N entries of the live unread queue are exactly the snapshot's unread set.
    # Also bound by MAX_MESSAGES_PER_EPOCH=20, matching getUnreadMessages's own cap.
    snap_unread = min(snapshot["message_count"] - snapshot["message_head"], 20)
    if snap_unread < len(state.get("donor_messages", [])):
        state["donor_messages"] = state["donor_messages"][:snap_unread]
    # Override investment currentValues with frozen snapshot values
    frozen_values = snapshot["investment_current_values"]
    total_invested = 0
    for inv in state.get("investments", []):
        pid = inv["id"]
        inv["current_value"] = frozen_values[pid]
        total_invested += frozen_values[pid]
    state["total_invested"] = total_invested
    state["total_assets"] = snapshot["balance"] + total_invested

    return cs
