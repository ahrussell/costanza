// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IAgentMemory.sol";
import "./interfaces/IInvestmentManager.sol";

/// @title AgentMemory
/// @notice Stores the agent's memory and exposes a unified entries list that
///         also includes per-protocol (name, description) read live from
///         `InvestmentManager`. The agent owns indices 0..9 via `setEntry`;
///         indices 10..(10 + protocolCount - 1) are read-only contextual
///         data that anyone reading `getEntries()` sees alongside the
///         mutable memory.
///
///         All entries — mutable + contextual — feed into `stateHash()`,
///         which is the canonical `memoryHash` input for `TheHumanFund`.
///         A loop-based hash absorbs any future protocolCount growth
///         without code changes.
///
///         The semantic split between "agent memory" (0..9) and "investment
///         descriptions" (10+) is convention, not enforced by this contract
///         beyond the `setEntry` slot range check. Consumer code (TEE
///         prompt builder + frontend) interprets the split when rendering;
///         the contract just serves the list and hashes it.
contract AgentMemory is IAgentMemory {
    uint256 public constant NUM_SLOTS = 10;
    uint256 public constant MAX_TITLE_LENGTH = 64;
    uint256 public constant MAX_BODY_LENGTH = 280;

    address public immutable fund;
    IInvestmentManager public immutable investmentManager;

    MemoryEntry[NUM_SLOTS] internal _entries;

    event MemoryEntrySet(uint256 indexed slot, string title, string body);

    constructor(address _fund, address _im) {
        require(_fund != address(0), "fund=0");
        require(_im   != address(0), "im=0");
        fund = _fund;
        investmentManager = IInvestmentManager(_im);
    }

    /// @notice Write to an agent-mutable slot. Only the fund can call; only
    ///         slots `0..NUM_SLOTS-1` are writable. Slots `>= NUM_SLOTS` are
    ///         read-only views onto `InvestmentManager`.
    function setEntry(
        uint256 slot,
        string calldata title,
        string calldata body
    ) external override {
        require(msg.sender == fund, "only fund");
        require(slot < NUM_SLOTS, "slot is read-only");

        string memory t = _truncate(title, MAX_TITLE_LENGTH);
        string memory b = _truncate(body,  MAX_BODY_LENGTH);

        _entries[slot] = MemoryEntry({title: t, body: b});
        emit MemoryEntrySet(slot, t, b);
    }

    /// @notice Single-entry getter. Same indexing scheme as `getEntries()`.
    ///         Slots 0..9 read mutable storage; slots 10..(10+protocolCount-1)
    ///         read the corresponding protocol's (name, description) live
    ///         from `InvestmentManager`.
    function getEntry(uint256 slot) external view override returns (MemoryEntry memory) {
        if (slot < NUM_SLOTS) {
            return _entries[slot];
        }
        uint256 protocolId = slot - NUM_SLOTS + 1; // 1-indexed in IM
        require(protocolId <= investmentManager.protocolCount(), "invalid slot");
        (, string memory name, string memory desc, , , , ) = investmentManager.protocols(protocolId);
        return MemoryEntry({title: name, body: desc});
    }

    /// @notice Full entries list. Length is `NUM_SLOTS + protocolCount`:
    ///         indices 0..9 are mutable agent memory; indices
    ///         10..(10 + protocolCount - 1) are protocol (name, description)
    ///         pairs in `protocolId` order (protocol 1 at index 10, etc.).
    function getEntries() external view override returns (MemoryEntry[] memory) {
        uint256 count = investmentManager.protocolCount();
        MemoryEntry[] memory out = new MemoryEntry[](NUM_SLOTS + count);
        for (uint256 i = 0; i < NUM_SLOTS; i++) {
            out[i] = _entries[i];
        }
        for (uint256 i = 1; i <= count; i++) {
            (, string memory name, string memory desc, , , , ) = investmentManager.protocols(i);
            out[NUM_SLOTS + i - 1] = MemoryEntry({title: name, body: desc});
        }
        return out;
    }

    /// @notice Deterministic hash of `getEntries()`. The canonical input to
    ///         `TheHumanFund`'s `memoryHash` field.
    /// @dev    Rolling per-item hash binding each item's index, matching the
    ///         pattern used by `InvestmentManager.epochStateHash` and
    ///         mirrored in the enclave's `_hash_memory` function. Position
    ///         is bound into each rolling hash so reordering breaks the
    ///         hash (defense against runner-side permutation attacks).
    function stateHash() external view override returns (bytes32) {
        MemoryEntry[] memory entries = this.getEntries();
        bytes32 rolling = bytes32(0);
        for (uint256 i = 0; i < entries.length; i++) {
            rolling = keccak256(abi.encode(rolling, i, entries[i].title, entries[i].body));
        }
        return keccak256(abi.encode(rolling, entries.length));
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
