// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAgentMemory
/// @notice Interface for the agent's memory contract.
///
///         Exposes a variable-length list of `MemoryEntry` items. By
///         convention, slots `0..9` are the agent's mutable memory (writable
///         via `setEntry`) and slots `10..` are read-only contextual data
///         sourced from other on-chain contracts (currently: per-protocol
///         (name, description) from `InvestmentManager`). The convention is
///         enforced by the implementation, NOT this interface — at the
///         interface level it's just "a list of (title, body) pairs that
///         hashes to a deterministic bytes32."
///
///         Hashing is generic over the entries list (loop-based). The
///         interpretation of which indices mean what lives in two consumer
///         files: `prover/enclave/prompt_builder.py` and `index.html`.
interface IAgentMemory {
    /// @notice A single memory entry with a title + body.
    struct MemoryEntry {
        string title;
        string body;
    }

    /// @notice A request to update a slot from `submitAuctionResult`.
    ///         Applied best-effort (contract-level try/catch per entry), with
    ///         the batch truncated to a maximum of 3 entries.
    struct MemoryUpdate {
        uint8 slot;   // 0..9 — agent-writable slots only
        string title; // truncated to MAX_TITLE_LENGTH
        string body;  // truncated to MAX_BODY_LENGTH
    }

    /// @notice Write to an agent-mutable slot. Slots `>= 10` are read-only
    ///         (sourced from external contracts); writes there must revert.
    function setEntry(uint256 slot, string calldata title, string calldata body) external;

    /// @notice Read a single entry. Same indexing scheme as `getEntries()`.
    function getEntry(uint256 slot) external view returns (MemoryEntry memory);

    /// @notice Return ALL entries. Variable length; first 10 are mutable
    ///         agent memory, the rest are read-only contextual data.
    function getEntries() external view returns (MemoryEntry[] memory);

    /// @notice Deterministic hash of `getEntries()` — the canonical input
    ///         to `TheHumanFund`'s `memoryHash` field.
    function stateHash() external view returns (bytes32);
}
