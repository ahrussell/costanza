#!/usr/bin/env python3
"""Independent input hash computation — replicates TheHumanFund._computeInputHash().

The TEE independently derives the input hash from the structured contract state
it receives. This hash goes into REPORTDATA — the contract verifies it matches
the on-chain committed epochInputHashes[epoch]. If the runner sent fake data,
the hash won't match and submitAuctionResult reverts.
"""


def _keccak256(data: bytes) -> bytes:
    """Compute keccak256 hash (same as Solidity's keccak256).

    IMPORTANT: Python's hashlib.sha3_256 is SHA-3 (FIPS 202), NOT Keccak-256.
    They use different padding and produce different outputs. Ethereum uses
    the original Keccak-256, not the NIST-standardized SHA-3.
    """
    try:
        import sha3
        return sha3.keccak_256(data).digest()
    except ImportError:
        pass
    try:
        from Crypto.Hash import keccak as _keccak
        k = _keccak.new(digest_bits=256)
        k.update(data)
        return k.digest()
    except ImportError:
        pass
    try:
        from web3 import Web3
        return Web3.keccak(data)
    except ImportError:
        raise ImportError(
            "No keccak256 implementation available. "
            "Install one of: pysha3, pycryptodome, or web3"
        )


def _abi_encode(*values) -> bytes:
    """Replicate Solidity's abi.encode() for uint256/bytes32/string/address values.

    Each value is a tuple of (type, value):
        ("uint256", 42)
        ("bytes32", b'\\x00...')
        ("string", "hello")
        ("address", "0x1234...")
    """
    from eth_abi import encode
    types = [v[0] for v in values]
    vals = [v[1] for v in values]
    return encode(types, vals)


def _abi_encode_packed(*raw_bytes) -> bytes:
    """Replicate Solidity's abi.encodePacked() — just concatenate raw bytes."""
    return b"".join(raw_bytes)


def compute_input_hash(state: dict) -> bytes:
    """Replicate TheHumanFund._computeInputHash() from structured state.

    The state dict must contain the same fields used by the contract:
      - state_hash_inputs: {epoch, balance, commission_rate_bps, max_bid, ...}
      - nonprofits: [{name, addr, total_donated, donation_count}, ...]
      - invest_hash: "0x..." (from investmentManager.stateHash())
      - worldview_hash: "0x..." (from worldView.stateHash())
      - message_hashes: ["0x...", ...] (per-message keccak256, up to 20)
      - epoch_content_hashes: ["0x...", ...] (last 10 epoch content hashes)
    """
    # 1. State hash
    s = state["state_hash_inputs"]
    state_hash = _keccak256(_abi_encode(
        ("uint256", s["epoch"]),
        ("uint256", s["balance"]),
        ("uint256", s["commission_rate_bps"]),
        ("uint256", s["max_bid"]),
        ("uint256", s["consecutive_missed_epochs"]),
        ("uint256", s["last_donation_epoch"]),
        ("uint256", s["last_commission_change_epoch"]),
        ("uint256", s["total_inflows"]),
        ("uint256", s["total_donated_to_nonprofits"]),
        ("uint256", s["total_commissions_paid"]),
        ("uint256", s["total_bounties_paid"]),
        ("uint256", s["current_epoch_inflow"]),
        ("uint256", s["current_epoch_donation_count"]),
        ("uint256", s.get("epoch_eth_usd_price", 0)),
    ))

    # 2. Nonprofit hash — rolling hash: keccak256(abi.encode(rolling, itemHash))
    nps = state["nonprofits"]
    if len(nps) == 0:
        nonprofit_hash = b'\x00' * 32
    else:
        rolling = b'\x00' * 32
        for np in nps:
            ein_bytes = bytes.fromhex(np["ein"].replace("0x", "")) if isinstance(np["ein"], str) else np["ein"]
            ein_bytes32 = ein_bytes.ljust(32, b'\x00')[:32]
            item_hash = _keccak256(_abi_encode(
                ("string", np["name"]),
                ("string", np["description"]),
                ("bytes32", ein_bytes32),
                ("uint256", np["total_donated"]),
                ("uint256", np.get("total_donated_usd", 0)),
                ("uint256", np["donation_count"]),
            ))
            rolling = _keccak256(_abi_encode(("bytes32", rolling), ("bytes32", item_hash)))
        nonprofit_hash = rolling

    # 3. Investment hash (pre-computed by InvestmentManager.stateHash())
    invest_hash = bytes.fromhex(state.get("invest_hash", "0" * 64).replace("0x", ""))

    # 4. Worldview hash (pre-computed by WorldView.stateHash())
    worldview_hash = bytes.fromhex(state.get("worldview_hash", "0" * 64).replace("0x", ""))

    # 5. Message hash — rolling hash: keccak256(abi.encode(rolling, msgHash))
    msg_hashes = state.get("message_hashes", [])
    if msg_hashes:
        rolling = b'\x00' * 32
        for h in msg_hashes:
            h_bytes = bytes.fromhex(h.replace("0x", ""))
            rolling = _keccak256(_abi_encode(("bytes32", rolling), ("bytes32", h_bytes)))
        msg_hash = rolling
    else:
        msg_hash = b'\x00' * 32

    # 6. History hash — rolling hash: keccak256(abi.encode(rolling, contentHash))
    epoch_hashes = state.get("epoch_content_hashes", [])
    if epoch_hashes:
        rolling = b'\x00' * 32
        for h in epoch_hashes:
            h_bytes = bytes.fromhex(h.replace("0x", ""))
            rolling = _keccak256(_abi_encode(("bytes32", rolling), ("bytes32", h_bytes)))
        hist_hash = rolling
    else:
        hist_hash = b'\x00' * 32

    # Final: keccak256(abi.encode(stateHash, nonprofitHash, investHash, worldviewHash, msgHash, histHash))
    return _keccak256(_abi_encode(
        ("bytes32", state_hash),
        ("bytes32", nonprofit_hash),
        ("bytes32", invest_hash),
        ("bytes32", worldview_hash),
        ("bytes32", msg_hash),
        ("bytes32", hist_hash),
    ))


def _abi_encode_packed_uint256(*values) -> bytes:
    """Replicate abi.encodePacked for uint256 values — raw 32-byte big-endian, no padding."""
    result = b""
    for v in values:
        result += v.to_bytes(32, "big")
    return result


class DisplayDataMismatch(Exception):
    """Raised when display data doesn't match its opaque hash."""
    pass


def verify_display_data(epoch_state: dict, contract_state: dict):
    """Verify that all display data shown to the model matches the opaque hashes.

    The contract's _computeInputHash() includes opaque hashes (invest_hash,
    worldview_hash, etc.) that the TEE passes through for hash verification.
    But the prompt builder uses EXPANDED display data from epoch_state.

    A malicious runner could provide correct opaque hashes (read from chain)
    alongside fabricated display data. This function closes that gap by
    recomputing each opaque hash from the expanded data and verifying it matches.

    Raises DisplayDataMismatch if any hash doesn't match.
    """
    _verify_investment_hash(epoch_state, contract_state)
    _verify_worldview_hash(epoch_state, contract_state)
    _verify_message_hashes(epoch_state, contract_state)
    _verify_history_hashes(epoch_state, contract_state)
    _verify_derived_fields(epoch_state)


def _verify_investment_hash(epoch_state: dict, contract_state: dict):
    """Replicate InvestmentManager.stateHash() from expanded investment data.

    Solidity (InvestmentManager.sol:304-319):
        bytes memory packed;
        for (uint256 i = 1; i <= protocolCount; i++) {
            packed = abi.encodePacked(packed, i, pos.depositedEth, pos.shares, currentValue);
        }
        return keccak256(abi.encodePacked(packed, protocolCount, totalInvestedValue()));
    """
    expected_hex = contract_state.get("invest_hash", "0x" + "00" * 32)
    expected = bytes.fromhex(expected_hex.replace("0x", ""))

    # Zero hash means no InvestmentManager — skip
    if expected == b'\x00' * 32:
        return

    investments = epoch_state.get("investments", [])
    packed = b""
    total_value = 0
    for inv in investments:
        pid = inv["id"]
        deposited = inv["deposited"]
        shares = inv["shares"]
        current_value = inv["current_value"]
        total_value += current_value
        packed += _abi_encode_packed_uint256(pid, deposited, shares, current_value)

    protocol_count = len(investments)
    packed += _abi_encode_packed_uint256(protocol_count, total_value)
    computed = _keccak256(packed)

    if computed != expected:
        raise DisplayDataMismatch(
            f"Investment hash mismatch: computed 0x{computed.hex()[:16]}... "
            f"!= expected 0x{expected.hex()[:16]}... "
            f"Runner may have provided fabricated investment data."
        )


def _verify_worldview_hash(epoch_state: dict, contract_state: dict):
    """Replicate WorldView.stateHash() from expanded policy data.

    Solidity (WorldView.sol:54-59):
        return keccak256(abi.encode(
            policies[0], policies[1], ..., policies[9]
        ));
    """
    expected_hex = contract_state.get("worldview_hash", "0x" + "00" * 32)
    expected = bytes.fromhex(expected_hex.replace("0x", ""))

    # Zero hash means no WorldView — skip
    if expected == b'\x00' * 32:
        return

    policies = epoch_state.get("guiding_policies", [""] * 10)
    # Pad to 10 policies
    while len(policies) < 10:
        policies.append("")

    # abi.encode with 10 strings
    types = [("string", p) for p in policies[:10]]
    computed = _keccak256(_abi_encode(*types))

    if computed != expected:
        raise DisplayDataMismatch(
            f"Worldview hash mismatch: computed 0x{computed.hex()[:16]}... "
            f"!= expected 0x{expected.hex()[:16]}... "
            f"Runner may have provided fabricated guiding policies."
        )


def _verify_message_hashes(epoch_state: dict, contract_state: dict):
    """Verify each donor message matches its on-chain hash.

    Per-message hash (TheHumanFund.sol:346):
        keccak256(abi.encode(msg.sender, msg.value, truncated, currentEpoch))

    Rolling chain (_hashUnreadMessages):
        rolling = keccak256(abi.encode(rolling, messageHashes[i]))
    """
    expected_hashes = contract_state.get("message_hashes", [])
    messages = epoch_state.get("donor_messages", [])

    if not expected_hashes and not messages:
        return

    if len(messages) != len(expected_hashes):
        raise DisplayDataMismatch(
            f"Message count mismatch: {len(messages)} messages "
            f"but {len(expected_hashes)} hashes."
        )

    for i, msg in enumerate(messages):
        sender = msg["sender"]
        # Normalize address to bytes20 for abi.encode (address type)
        amount = msg["amount"]
        text = msg["text"]
        epoch = msg["epoch"]

        computed_hash = _keccak256(_abi_encode(
            ("address", sender),
            ("uint256", amount),
            ("string", text),
            ("uint256", epoch),
        ))

        expected_hash = bytes.fromhex(expected_hashes[i].replace("0x", ""))
        if computed_hash != expected_hash:
            raise DisplayDataMismatch(
                f"Message #{i} hash mismatch: computed 0x{computed_hash.hex()[:16]}... "
                f"!= expected 0x{expected_hash.hex()[:16]}... "
                f"Runner may have provided fabricated donor message text."
            )


def _verify_history_hashes(epoch_state: dict, contract_state: dict):
    """Verify each history entry matches its on-chain content hash.

    Per-epoch content hash (TheHumanFund.sol:764-766):
        keccak256(abi.encode(
            keccak256(reasoning), keccak256(action), treasuryBefore, treasuryAfter
        ))

    Rolling chain (_hashRecentHistory):
        rolling = keccak256(abi.encode(rolling, epochContentHashes[histEpoch]))
    """
    expected_hashes = contract_state.get("epoch_content_hashes", [])
    history = epoch_state.get("history", [])

    if not expected_hashes and not history:
        return

    # Filter out zero hashes: epochs that were never executed/settled have
    # epochContentHashes[ep] == bytes32(0). The runner's history list only
    # contains executed epochs (getEpochRecord returns executed=True).
    # Zero-hash entries have nothing to verify against — skip them.
    zero_hash = b'\x00' * 32
    non_zero_hashes = [
        h for h in expected_hashes
        if bytes.fromhex(h.replace("0x", "")) != zero_hash
    ]

    if not non_zero_hashes and not history:
        return

    if len(history) < len(non_zero_hashes):
        raise DisplayDataMismatch(
            f"History count mismatch: {len(history)} entries "
            f"but {len(non_zero_hashes)} non-zero content hashes expected."
        )

    # Pair non-zero expected hashes with the corresponding history entries.
    # Both lists are most-recent-first. Entries with zero hashes (unexecuted
    # epochs) are gaps in the sequence that the history list skips over.
    history_idx = 0
    for expected_hex in expected_hashes:
        expected_hash = bytes.fromhex(expected_hex.replace("0x", ""))
        if expected_hash == zero_hash:
            continue  # Unexecuted epoch — no history entry exists for it

        if history_idx >= len(history):
            raise DisplayDataMismatch(
                "History entry missing: fewer history entries than non-zero content hashes."
            )
        entry = history[history_idx]
        history_idx += 1

        # Get action and reasoning as bytes
        action_data = entry["action"]
        if isinstance(action_data, str):
            action_data = bytes.fromhex(action_data.replace("0x", ""))
        elif not isinstance(action_data, bytes):
            action_data = bytes(action_data)

        reasoning_data = entry["reasoning"]
        if isinstance(reasoning_data, str):
            reasoning_data = reasoning_data.encode("utf-8")
        elif not isinstance(reasoning_data, bytes):
            reasoning_data = bytes(reasoning_data)

        # Solidity keccak256(reasoning), keccak256(action)
        reasoning_hash = _keccak256(reasoning_data)
        action_hash = _keccak256(action_data)

        computed_content_hash = _keccak256(_abi_encode(
            ("bytes32", reasoning_hash),
            ("bytes32", action_hash),
            ("uint256", entry["treasury_before"]),
            ("uint256", entry["treasury_after"]),
        ))

        if computed_content_hash != expected_hash:
            raise DisplayDataMismatch(
                f"History epoch {entry.get('epoch', '?')} hash mismatch: "
                f"computed 0x{computed_content_hash.hex()[:16]}... "
                f"!= expected 0x{expected_hash.hex()[:16]}... "
                f"Runner may have provided fabricated decision history."
            )


def _verify_derived_fields(epoch_state: dict):
    """Verify display-only fields that are derived from hash-verified data.

    These fields are NOT in any hash but are shown to the model. Verify
    they are consistent with the hash-verified fields.
    """
    balance = epoch_state.get("treasury_balance", 0)
    investments = epoch_state.get("investments", [])
    total_invested = sum(inv.get("current_value", 0) for inv in investments)

    # Verify total_invested
    claimed_total_invested = epoch_state.get("total_invested", 0)
    if investments and claimed_total_invested != total_invested:
        raise DisplayDataMismatch(
            f"total_invested mismatch: claimed {claimed_total_invested} "
            f"but sum of investments is {total_invested}."
        )

    # Verify total_assets = balance + total_invested
    claimed_total_assets = epoch_state.get("total_assets", balance)
    expected_total_assets = balance + total_invested
    if investments and claimed_total_assets != expected_total_assets:
        raise DisplayDataMismatch(
            f"total_assets mismatch: claimed {claimed_total_assets} "
            f"but balance({balance}) + invested({total_invested}) = {expected_total_assets}."
        )

    # Verify effective_max_bid (10% compounding escalation per missed epoch)
    max_bid = epoch_state.get("max_bid", 0)
    consecutive_missed = epoch_state.get("consecutive_missed", 0)
    claimed_effective = epoch_state.get("effective_max_bid", max_bid)

    if consecutive_missed == 0:
        expected_effective = max_bid
    else:
        # Cap at 2% of treasury (MAX_BID_BPS = 200)
        hard_cap = (balance * 200) // 10000
        escalated = max_bid
        for _ in range(consecutive_missed):
            # AUTO_ESCALATION_BPS = 1000 (10%)
            escalated = escalated + (escalated * 1000) // 10000
            if escalated >= hard_cap:
                escalated = hard_cap
                break
        expected_effective = escalated

    if claimed_effective != expected_effective:
        raise DisplayDataMismatch(
            f"effective_max_bid mismatch: claimed {claimed_effective} "
            f"but computed {expected_effective} from max_bid={max_bid}, "
            f"missed={consecutive_missed}."
        )


def derive_contract_state(epoch_state: dict) -> dict:
    """Derive the structured contract_state (for input hash) from a flat epoch state.

    The runner sends the full flat state (same format as read_contract_state()).
    The TEE derives the hash-input structure from it, computes the input hash,
    and verifies it matches on-chain. This ensures ALL data shown to the model
    is transitively verified.

    The flat state also includes pre-computed on-chain hashes (invest_hash,
    worldview_hash, message_hashes, epoch_content_hashes) that the TEE cannot
    derive independently since it has no chain access.
    """
    cs = {}

    # 1. State hash inputs — maps flat field names to _hashState() field names
    cs["state_hash_inputs"] = {
        "epoch": epoch_state["epoch"],
        "balance": epoch_state["treasury_balance"],
        "commission_rate_bps": epoch_state["commission_rate_bps"],
        "max_bid": epoch_state["max_bid"],
        "consecutive_missed_epochs": epoch_state.get("consecutive_missed", 0),
        "last_donation_epoch": epoch_state["last_donation_epoch"],
        "last_commission_change_epoch": epoch_state["last_commission_change_epoch"],
        "total_inflows": epoch_state.get("total_inflows", 0),
        "total_donated_to_nonprofits": epoch_state.get("total_donated", 0),
        "total_commissions_paid": epoch_state.get("total_commissions", 0),
        "total_bounties_paid": epoch_state.get("total_bounties", 0),
        "current_epoch_inflow": epoch_state.get("epoch_inflow", 0),
        "current_epoch_donation_count": epoch_state.get("epoch_donation_count", 0),
        "epoch_eth_usd_price": epoch_state.get("epoch_eth_usd_price", 0),
    }

    # 2. Nonprofits — matches _hashNonprofits()
    cs["nonprofits"] = []
    for np in epoch_state.get("nonprofits", []):
        cs["nonprofits"].append({
            "name": np["name"],
            "description": np.get("description", ""),
            "ein": np.get("ein", "0x" + "00" * 32),
            "total_donated": np["total_donated"],
            "total_donated_usd": np.get("total_donated_usd", 0),
            "donation_count": np["donation_count"],
        })

    # 3-6. Pre-computed hashes (passed through from runner, verified via inputHash)
    cs["invest_hash"] = epoch_state.get("invest_hash", "0x" + "00" * 32)
    cs["worldview_hash"] = epoch_state.get("worldview_hash", "0x" + "00" * 32)
    cs["message_hashes"] = epoch_state.get("message_hashes", [])
    cs["epoch_content_hashes"] = epoch_state.get("epoch_content_hashes", [])

    return cs
