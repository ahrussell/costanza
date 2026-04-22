// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IWorldView
/// @notice Interface for the agent's worldview — 10 guiding policy slots.
///         Each slot holds a model-authored `{title, body}` pair; the model
///         owns the category taxonomy by writing its own titles.
interface IWorldView {
    /// @notice A single guiding-policy slot with a model-authored title + body.
    struct Policy {
        string title;
        string body;
    }

    /// @notice A request to update a slot from `submitAuctionResult`.
    ///         Applied best-effort (contract-level try/catch per entry), with
    ///         the batch truncated to a maximum of 3 entries.
    struct PolicyUpdate {
        uint8 slot;   // 0..9 — all slots writable (no reserved slot)
        string title; // truncated to MAX_TITLE_LENGTH
        string body;  // truncated to MAX_BODY_LENGTH
    }

    function setPolicy(uint256 slot, string calldata title, string calldata body) external;
    function getPolicy(uint256 slot) external view returns (Policy memory);
    function getPolicies() external view returns (Policy[10] memory);
    function stateHash() external view returns (bytes32);
}
