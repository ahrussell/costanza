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

    # 2. Nonprofit hash
    nps = state["nonprofits"]
    if len(nps) == 0:
        nonprofit_hash = b'\x00' * 32
    else:
        # Match contract: keccak256(abi.encodePacked(hash1, hash2, ...))
        # where each hash = keccak256(abi.encode(name, description, ein, totalDonated, totalDonatedUsd, donationCount))
        packed = b""
        for np in nps:
            ein_bytes = bytes.fromhex(np["ein"].replace("0x", "")) if isinstance(np["ein"], str) else np["ein"]
            ein_bytes32 = ein_bytes.ljust(32, b'\x00')[:32]
            per_np_hash = _keccak256(_abi_encode(
                ("string", np["name"]),
                ("string", np["description"]),
                ("bytes32", ein_bytes32),
                ("uint256", np["total_donated"]),
                ("uint256", np.get("total_donated_usd", 0)),
                ("uint256", np["donation_count"]),
            ))
            packed += per_np_hash
        nonprofit_hash = _keccak256(packed)

    # 3. Investment hash (pre-computed by InvestmentManager.stateHash())
    invest_hash = bytes.fromhex(state.get("invest_hash", "0" * 64).replace("0x", ""))

    # 4. Worldview hash (pre-computed by WorldView.stateHash())
    worldview_hash = bytes.fromhex(state.get("worldview_hash", "0" * 64).replace("0x", ""))

    # 5. Message hash — keccak256 of packed per-message hashes
    msg_hashes = state.get("message_hashes", [])
    if msg_hashes:
        packed = b""
        for h in msg_hashes:
            packed += bytes.fromhex(h.replace("0x", ""))
        msg_hash = _keccak256(packed)
    else:
        msg_hash = b'\x00' * 32

    # 6. History hash — keccak256 of packed epoch content hashes (most recent first)
    epoch_hashes = state.get("epoch_content_hashes", [])
    if epoch_hashes:
        packed = b""
        for h in epoch_hashes:
            packed += bytes.fromhex(h.replace("0x", ""))
        hist_hash = _keccak256(packed)
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
