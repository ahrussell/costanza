// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IInvestmentManager
/// @notice Interface for the investment manager called by TheHumanFund.
///         Manages a portfolio of DeFi protocol positions with bounds checking.
interface IInvestmentManager {
    /// @notice Deposit ETH into a registered protocol.
    /// @param protocolId The protocol to invest in (1-indexed).
    /// @param amount The ETH amount to invest (must match msg.value).
    function deposit(uint256 protocolId, uint256 amount) external payable;

    /// @notice Withdraw ETH from a protocol position.
    /// @param protocolId The protocol to withdraw from.
    /// @param amount The ETH-equivalent amount to withdraw (converted to shares internally).
    function withdraw(uint256 protocolId, uint256 amount) external;

    /// @notice Total value of all invested positions in ETH terms.
    function totalInvestedValue() external view returns (uint256);

    /// @notice Deterministic hash of all investment state, for input hash binding.
    function stateHash() external view returns (bytes32);

    /// @notice Withdraw all positions across all protocols, sending ETH to recipient.
    function withdrawAll(address recipient) external;

    /// @notice Number of registered protocols.
    function protocolCount() external view returns (uint256);

    /// @notice Get the current value of a position (from adapter.balance()).
    /// @param protocolId The protocol ID (1-indexed).
    function getProtocolValue(uint256 protocolId) external view returns (uint256);
}
