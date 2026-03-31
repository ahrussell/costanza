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


def build_contract_state_for_tee(contract, w3, state):
    """Build the structured contract_state dict for TEE input hash verification.

    This mirrors TheHumanFund._computeInputHash() exactly. The TEE computes
    the same hash from this data and binds it into the TDX REPORTDATA.
    """
    cs = {}

    # 1. State hash inputs — matches _hashState()
    cs["state_hash_inputs"] = {
        "epoch": state["epoch"],
        "balance": state["treasury_balance"],
        "commission_rate_bps": state["commission_rate_bps"],
        "max_bid": state["max_bid"],
        "consecutive_missed_epochs": state["consecutive_missed"],
        "last_donation_epoch": state["last_donation_epoch"],
        "last_commission_change_epoch": state["last_commission_change_epoch"],
        "total_inflows": state["total_inflows"],
        "total_donated_to_nonprofits": state["total_donated"],
        "total_commissions_paid": state["total_commissions"],
        "total_bounties_paid": state["total_bounties"],
        "current_epoch_inflow": state["epoch_inflow"],
        "current_epoch_donation_count": state["epoch_donation_count"],
        "epoch_eth_usd_price": state.get("epoch_eth_usd_price", 0),
        "epoch_duration": state["epoch_duration"],
    }

    # 2. Nonprofits — matches _hashNonprofits()
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

    # 3. Investment hash (pre-computed on-chain)
    try:
        im_addr = contract.functions.investmentManager().call()
        if im_addr and im_addr != "0x0000000000000000000000000000000000000000":
            im_abi = [{"name": "stateHash", "type": "function", "inputs": [],
                       "outputs": [{"type": "bytes32"}], "stateMutability": "view"}]
            im = w3.eth.contract(address=Web3.to_checksum_address(im_addr), abi=im_abi)
            cs["invest_hash"] = "0x" + im.functions.stateHash().call().hex()
        else:
            cs["invest_hash"] = "0x" + "00" * 32
    except Exception:
        cs["invest_hash"] = "0x" + "00" * 32

    # 4. Worldview hash (pre-computed on-chain)
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

    # 5. Message hashes (pre-cached on-chain per message)
    cs["message_hashes"] = []
    try:
        message_head = state["message_head"]
        message_count = state["message_count"]
        unread = message_count - message_head
        count = min(unread, 20)  # MAX_MESSAGES_PER_EPOCH
        msg_hash_abi = [{"name": "messageHashes", "type": "function",
                         "inputs": [{"type": "uint256"}],
                         "outputs": [{"type": "bytes32"}], "stateMutability": "view"}]
        msg_contract = w3.eth.contract(address=contract.address, abi=msg_hash_abi)
        for i in range(count):
            h = msg_contract.functions.messageHashes(message_head + i).call()
            cs["message_hashes"].append("0x" + h.hex())
    except Exception:
        pass

    # 6. Epoch content hashes (last 10, most recent first)
    cs["epoch_content_hashes"] = []
    try:
        epoch = state["epoch"]
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

    return cs
