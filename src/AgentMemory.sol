// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IAgentMemory.sol";

/// @title AgentMemory
/// @notice Stores the agent's memory. Only the fund contract can
///         update them. All 10 slots (0..9) are writable; the model owns the
///         category taxonomy by writing its own titles. The storage array
///         and stateHash() cover all 10 slots for byte-exact hash equivalence
///         with the enclave's _hash_worldview mirror.
contract AgentMemory is IAgentMemory {
    uint256 public constant NUM_POLICIES = 10;
    uint256 public constant MAX_TITLE_LENGTH = 64;
    uint256 public constant MAX_BODY_LENGTH = 280;

    address public fund;
    Policy[10] internal _policies;

    event MemoryEntrySet(uint256 indexed slot, string title, string body);

    constructor(address _fund) {
        fund = _fund;
    }

    /// @notice Set a memory entry. Only callable by the fund contract.
    /// @param slot  Memory slot (0..9). All slots are writable.
    /// @param title Short model-authored header (truncated to MAX_TITLE_LENGTH).
    /// @param body  Memory text (truncated to MAX_BODY_LENGTH).
    function setPolicy(
        uint256 slot,
        string calldata title,
        string calldata body
    ) external override {
        require(msg.sender == fund, "only fund");
        require(slot < NUM_POLICIES, "invalid slot");

        string memory t = _truncate(title, MAX_TITLE_LENGTH);
        string memory b = _truncate(body, MAX_BODY_LENGTH);

        _policies[slot] = Policy({title: t, body: b});
        emit MemoryEntrySet(slot, t, b);
    }

    /// @notice Get a single memory entry by slot.
    function getPolicy(uint256 slot) external view override returns (Policy memory) {
        require(slot < NUM_POLICIES, "invalid slot");
        return _policies[slot];
    }

    /// @notice Get all 10 memory entries.
    function getPolicies() external view override returns (Policy[10] memory) {
        return _policies;
    }

    /// @notice Deterministic hash of all memory entries for input-hash binding.
    /// @dev    Expanded form over 20 strings (title + body per slot, 10 slots)
    ///         so the Python enclave mirror can match byte-for-byte.
    function stateHash() external view override returns (bytes32) {
        return keccak256(abi.encode(
            _policies[0].title, _policies[0].body,
            _policies[1].title, _policies[1].body,
            _policies[2].title, _policies[2].body,
            _policies[3].title, _policies[3].body,
            _policies[4].title, _policies[4].body,
            _policies[5].title, _policies[5].body,
            _policies[6].title, _policies[6].body,
            _policies[7].title, _policies[7].body,
            _policies[8].title, _policies[8].body,
            _policies[9].title, _policies[9].body
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
