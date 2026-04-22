// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAgentMemory
/// @notice Interface for the agent's memory — 10 persistent slots.
///         Each slot holds a model-authored `{title, body}` pair; the model
///         owns the category taxonomy by writing its own titles.
interface IAgentMemory {
    /// @notice A single memory slot with a model-authored title + body.
    struct MemoryEntry {
        string title;
        string body;
    }

    /// @notice A request to update a slot from `submitAuctionResult`.
    ///         Applied best-effort (contract-level try/catch per entry), with
    ///         the batch truncated to a maximum of 3 entries.
    struct MemoryUpdate {
        uint8 slot;   // 0..9 — all slots writable (no reserved slot)
        string title; // truncated to MAX_TITLE_LENGTH
        string body;  // truncated to MAX_BODY_LENGTH
    }

    function setEntry(uint256 slot, string calldata title, string calldata body) external;
    function getEntry(uint256 slot) external view returns (MemoryEntry memory);
    function getEntries() external view returns (MemoryEntry[10] memory);
    function stateHash() external view returns (bytes32);
}
