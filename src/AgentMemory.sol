// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IAgentMemory.sol";

/// @title AgentMemory
/// @notice Stores the agent's memory. Only the fund contract can
///         update entries. All 10 slots (0..9) are writable; the model owns the
///         category taxonomy by writing its own titles. The storage array
///         and stateHash() cover all 10 slots for byte-exact hash equivalence
///         with the enclave's _hash_memory mirror.
contract AgentMemory is IAgentMemory {
    uint256 public constant NUM_SLOTS = 10;
    uint256 public constant MAX_TITLE_LENGTH = 64;
    uint256 public constant MAX_BODY_LENGTH = 280;

    address public fund;
    MemoryEntry[10] internal _entries;

    event MemoryEntrySet(uint256 indexed slot, string title, string body);

    constructor(address _fund) {
        fund = _fund;
    }

    /// @notice Set a memory entry. Only callable by the fund contract.
    /// @param slot  Memory slot (0..9). All slots are writable.
    /// @param title Short model-authored header (truncated to MAX_TITLE_LENGTH).
    /// @param body  Memory text (truncated to MAX_BODY_LENGTH).
    function setEntry(
        uint256 slot,
        string calldata title,
        string calldata body
    ) external override {
        require(msg.sender == fund, "only fund");
        require(slot < NUM_SLOTS, "invalid slot");

        string memory t = _truncate(title, MAX_TITLE_LENGTH);
        string memory b = _truncate(body, MAX_BODY_LENGTH);

        _entries[slot] = MemoryEntry({title: t, body: b});
        emit MemoryEntrySet(slot, t, b);
    }

    /// @notice Get a single memory entry by slot.
    function getEntry(uint256 slot) external view override returns (MemoryEntry memory) {
        require(slot < NUM_SLOTS, "invalid slot");
        return _entries[slot];
    }

    /// @notice Get all 10 memory entries.
    function getEntries() external view override returns (MemoryEntry[10] memory) {
        return _entries;
    }

    /// @notice Deterministic hash of all memory entries for input-hash binding.
    /// @dev    Expanded form over 20 strings (title + body per slot, 10 slots)
    ///         so the Python enclave mirror can match byte-for-byte.
    function stateHash() external view override returns (bytes32) {
        return keccak256(abi.encode(
            _entries[0].title, _entries[0].body,
            _entries[1].title, _entries[1].body,
            _entries[2].title, _entries[2].body,
            _entries[3].title, _entries[3].body,
            _entries[4].title, _entries[4].body,
            _entries[5].title, _entries[5].body,
            _entries[6].title, _entries[6].body,
            _entries[7].title, _entries[7].body,
            _entries[8].title, _entries[8].body,
            _entries[9].title, _entries[9].body
        ));
    }

    /// @dev Truncate calldata string to `cap` bytes (no-op if already short).
    function _truncate(string calldata s, uint256 cap) internal pure returns (string memory) {
        bytes memory raw = bytes(s);
        if (raw.length <= cap) {
            return s;
        }
        bytes memory out = new bytes(cap);
        for (uint256 i = 0; i < cap; i++) {
            out[i] = raw[i];
        }
        return string(out);
    }
}
