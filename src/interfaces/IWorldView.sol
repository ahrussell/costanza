// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IWorldView
/// @notice Interface for the agent's worldview — 10 guiding policy slots.
interface IWorldView {
    function setPolicy(uint256 slot, string calldata policy) external;
    function getPolicy(uint256 slot) external view returns (string memory);
    function getPolicies() external view returns (string[10] memory);
    function stateHash() external view returns (bytes32);
}
