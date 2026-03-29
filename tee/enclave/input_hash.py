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
