#!/usr/bin/env python3
"""Input hash computation — byte-exact replication of TheHumanFund._computeInputHash().

The enclave is a dumb signer. It takes the flat epoch state from the runner,
computes keccak hashes over every display field the model will see, combines
them into the same structure the contract uses, and binds the result into the
TDX REPORTDATA. On-chain verification is pure hash equality against
`epochInputHashes[epoch]` (which the contract computed the same way at
auction open). If the runner fabricates, truncates, reorders, or omits any
display field, the hashes diverge and the submission reverts.

There is no separate "verify display data" step. There are no "opaque"
sub-hashes passed through from the runner. The enclave re-derives every
leaf hash from the raw data the model sees.

Contract-side reference:
  TheHumanFund._computeInputHash()   -> this file's compute_input_hash()
  TheHumanFund._hashState()          -> _hash_state()
  TheHumanFund._hashNonprofits()     -> _hash_nonprofits()
  TheHumanFund._hashUnreadMessages() -> _hash_messages()
  TheHumanFund._hashRecentHistory()  -> _hash_history()
  InvestmentManager.stateHash()      -> _hash_investments()
  WorldView.stateHash()              -> _hash_worldview()
"""

MAX_MESSAGES_PER_EPOCH = 5
MAX_HISTORY_ENTRIES = 10
WORLDVIEW_SLOTS = 10
DEFAULT_EPOCH_DURATION = 86400


# ─── Keccak / ABI helpers ─────────────────────────────────────────────────

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
    """Replicate Solidity's abi.encode() for typed values.

    Each argument is a (type, value) tuple:
        ("uint256", 42)
        ("bytes32", b'\\x00...')
        ("string", "hello")
        ("address", "0x1234...")
    """
    from eth_abi import encode
    types = [v[0] for v in values]
    vals = [v[1] for v in values]
    return encode(types, vals)


def _u256_packed(value: int) -> bytes:
    """Pack a uint256 as 32-byte big-endian (matches abi.encodePacked for uint256)."""
    return int(value).to_bytes(32, "big")


def _bytes32(value) -> bytes:
    """Coerce a hex string or bytes to a 32-byte value."""
    if isinstance(value, bytes):
        return value.ljust(32, b"\x00")[:32]
    if isinstance(value, str):
        h = value.replace("0x", "")
        return bytes.fromhex(h).ljust(32, b"\x00")[:32]
    raise TypeError(f"Cannot coerce {type(value).__name__} to bytes32")


# ─── Leaf hashes (mirror contract helpers exactly) ────────────────────────

def _hash_state(s: dict) -> bytes:
    """Replicate TheHumanFund._hashState().

    Solidity splits into two halves to avoid stack-too-deep with ~15 fields.
    We do the same so the byte-exact hash matches.

    The `effective_max_bid` field is included directly (see contract change
    that adds it to _hashState alongside maxBid + consecutiveMissedEpochs).
    This eliminates any Python/Solidity formula-drift class of bug: the
    enclave is a dumb hasher, it never re-derives anything.
    """
    h1 = _keccak256(_abi_encode(
        ("uint256", s["epoch"]),
        ("uint256", s["treasury_balance"]),
        ("uint256", s["commission_rate_bps"]),
        ("uint256", s["max_bid"]),
        ("uint256", s["effective_max_bid"]),
        ("uint256", s["consecutive_missed"]),
        ("uint256", s["last_donation_epoch"]),
        ("uint256", s["last_commission_change_epoch"]),
        ("uint256", s["total_inflows"]),
    ))
    return _keccak256(_abi_encode(
        ("bytes32", h1),
        ("uint256", s["total_donated"]),
        ("uint256", s["total_commissions"]),
        ("uint256", s["total_bounties"]),
        ("uint256", s["epoch_inflow"]),
        ("uint256", s["epoch_donation_count"]),
        ("uint256", s["epoch_eth_usd_price"]),
        ("uint256", s.get("epoch_duration", DEFAULT_EPOCH_DURATION)),
    ))


def _hash_nonprofits(nonprofits: list) -> bytes:
    """Replicate TheHumanFund._hashNonprofits().

    Rolling hash:
        rolling = 0
        for each nonprofit i in 1..nonprofitCount:
            item = keccak256(abi.encode(name, description, ein,
                             totalDonated, totalDonatedUsd, donationCount))
            rolling = keccak256(abi.encode(rolling, item))
    """
    if not nonprofits:
        return b"\x00" * 32
    rolling = b"\x00" * 32
    for np in nonprofits:
        ein = _bytes32(np.get("ein", b"\x00" * 32))
        item_hash = _keccak256(_abi_encode(
            ("string", np["name"]),
            ("string", np.get("description", "")),
            ("bytes32", ein),
            ("uint256", np["total_donated"]),
            ("uint256", np.get("total_donated_usd", 0)),
            ("uint256", np["donation_count"]),
        ))
        rolling = _keccak256(_abi_encode(
            ("bytes32", rolling),
            ("bytes32", item_hash),
        ))
    return rolling


def _hash_investments(investments: list) -> bytes:
    """Replicate InvestmentManager.stateHash().

    Solidity:
        bytes memory packed;
        for (i = 1; i <= protocolCount; i++) {
            packed = abi.encodePacked(packed, i, depositedEth, shares, currentValue);
        }
        return keccak256(abi.encodePacked(packed, protocolCount, totalInvestedValue));

    The runner passes `investments[]` with every slot from 1..protocolCount
    (including zeroed positions). `current_value` must be the snapshot value
    frozen at auction open (not live), so drift between snapshot time and
    inference time does not perturb the hash.
    """
    if not investments:
        return b"\x00" * 32
    packed = b""
    total_value = 0
    for inv in investments:
        pid = inv["id"]
        deposited = inv["deposited"]
        shares = inv["shares"]
        current_value = inv["current_value"]
        total_value += current_value
        packed += _u256_packed(pid) + _u256_packed(deposited) + _u256_packed(shares) + _u256_packed(current_value)
    packed += _u256_packed(len(investments)) + _u256_packed(total_value)
    return _keccak256(packed)


def _hash_worldview(policies: list) -> bytes:
    """Replicate WorldView.stateHash().

    Solidity:
        return keccak256(abi.encode(
            policies[0], policies[1], ..., policies[9]
        ));

    Zero-length worldview → b'\\x00' * 32 (matches bytes32(0) sentinel).
    """
    if not policies:
        return b"\x00" * 32
    # Pad / truncate to exactly WORLDVIEW_SLOTS entries.
    padded = list(policies[:WORLDVIEW_SLOTS])
    while len(padded) < WORLDVIEW_SLOTS:
        padded.append("")
    return _keccak256(_abi_encode(*[("string", p) for p in padded]))


def _hash_messages(donor_messages: list) -> bytes:
    """Replicate TheHumanFund._hashUnreadMessages().

    Per-message hash (stored at donateWithMessage time):
        keccak256(abi.encode(sender, amount, text, epoch))

    Rolling hash over up to MAX_MESSAGES_PER_EPOCH entries:
        rolling = 0
        for i in 0..count:
            rolling = keccak256(abi.encode(rolling, messageHashes[head+i]))

    The runner pre-truncates donor_messages to exactly the snapshot's unread
    count (see build_contract_state_for_tee), so we just hash every entry.
    """
    count = min(len(donor_messages), MAX_MESSAGES_PER_EPOCH)
    if count == 0:
        return b"\x00" * 32
    rolling = b"\x00" * 32
    for i in range(count):
        msg = donor_messages[i]
        per_msg_hash = _keccak256(_abi_encode(
            ("address", msg["sender"]),
            ("uint256", msg["amount"]),
            ("string", msg["text"]),
            ("uint256", msg["epoch"]),
        ))
        rolling = _keccak256(_abi_encode(
            ("bytes32", rolling),
            ("bytes32", per_msg_hash),
        ))
    return rolling


def _hash_history(history: list, current_epoch: int) -> bytes:
    """Replicate TheHumanFund._hashRecentHistory().

    Solidity:
        if (currentEpoch == 0) return bytes32(0);
        count = min(currentEpoch, MAX_HISTORY_ENTRIES);
        rolling = 0;
        for (i = 0; i < count; i++) {
            histEpoch = currentEpoch - 1 - i;  // most recent first
            rolling = keccak256(abi.encode(rolling, epochContentHashes[histEpoch]));
        }

    Per-epoch content hash (set in _recordAndExecute):
        keccak256(abi.encode(keccak256(reasoning), keccak256(action),
                             treasuryBefore, treasuryAfter))

    Unexecuted epochs have epochContentHashes[ep] == 0, which shows up as a
    zero leaf in the rolling hash. The runner's `history` list is indexed
    by epoch number; slots we can't find get zero.
    """
    if current_epoch == 0:
        return b"\x00" * 32

    # Build an index by epoch for O(1) lookup, mirroring on-chain storage.
    by_epoch = {}
    for entry in history:
        if entry is None:
            continue
        ep = entry.get("epoch")
        if ep is None:
            continue
        by_epoch[int(ep)] = entry

    count = min(current_epoch, MAX_HISTORY_ENTRIES)
    rolling = b"\x00" * 32
    zero_hash = b"\x00" * 32

    for i in range(count):
        hist_epoch = current_epoch - 1 - i  # most recent first
        entry = by_epoch.get(hist_epoch)
        if entry is None:
            content_hash = zero_hash
        else:
            content_hash = _content_hash_for_entry(entry)
        rolling = _keccak256(_abi_encode(
            ("bytes32", rolling),
            ("bytes32", content_hash),
        ))
    return rolling


def _content_hash_for_entry(entry: dict) -> bytes:
    """keccak256(abi.encode(keccak256(reasoning), keccak256(action), tb, ta))."""
    action_data = entry["action"]
    if isinstance(action_data, str):
        action_data = bytes.fromhex(action_data.replace("0x", ""))
    elif not isinstance(action_data, bytes):
        action_data = bytes(action_data)

    reasoning_data = entry["reasoning"]
    if isinstance(reasoning_data, str):
        if reasoning_data.startswith("0x"):
            reasoning_data = bytes.fromhex(reasoning_data[2:])
        else:
            reasoning_data = reasoning_data.encode("utf-8")
    elif not isinstance(reasoning_data, bytes):
        reasoning_data = bytes(reasoning_data)

    return _keccak256(_abi_encode(
        ("bytes32", _keccak256(reasoning_data)),
        ("bytes32", _keccak256(action_data)),
        ("uint256", entry["treasury_before"]),
        ("uint256", entry["treasury_after"]),
    ))


# ─── Top-level entry point ────────────────────────────────────────────────

def compute_input_hash(epoch_state: dict) -> bytes:
    """Compute the input hash from the flat epoch state.

    This is a byte-exact replica of TheHumanFund._computeInputHash(). The
    enclave calls this on the runner-supplied epoch_state and binds the
    result into REPORTDATA. On-chain verification is hash equality —
    no separate display-data verification, no re-derivation of any field.

    The runner is free to lie about any field; if it does, the computed
    hash won't match `epochInputHashes[epoch]` and submitAuctionResult reverts.
    """
    state_hash = _hash_state(epoch_state)
    nonprofit_hash = _hash_nonprofits(epoch_state.get("nonprofits", []))
    invest_hash = _hash_investments(epoch_state.get("investments", []))
    worldview_hash = _hash_worldview(epoch_state.get("guiding_policies", []))
    msg_hash = _hash_messages(epoch_state.get("donor_messages", []))
    hist_hash = _hash_history(epoch_state.get("history", []), epoch_state.get("epoch", 0))

    return _keccak256(_abi_encode(
        ("bytes32", state_hash),
        ("bytes32", nonprofit_hash),
        ("bytes32", invest_hash),
        ("bytes32", worldview_hash),
        ("bytes32", msg_hash),
        ("bytes32", hist_hash),
    ))
