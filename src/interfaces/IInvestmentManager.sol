// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IProtocolAdapter.sol";

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
    /// @dev Reads adapter.balance() live — susceptible to drift between auction
    ///      open and execution. Kept for backward compatibility; TheHumanFund
    ///      now binds investment state via epochStateHash() which takes frozen
    ///      snapshot values as inputs.
    function stateHash() external view returns (bytes32);

    /// @notice Snapshot-bound investment state hash.
    /// @dev Called from TheHumanFund._computeInputHash() with arrays frozen
    ///      in EpochSnapshot at auction open. Hashes per-protocol:
    ///        - protocolId (i)
    ///        - depositedEth, shares (stable within an epoch)
    ///        - snapshotCurrentValues[i] (frozen at auction open)
    ///        - snapshotActive[i] (frozen; admin can toggle mid-epoch)
    ///        - name, riskTier, expectedApyBps (immutable post-addProtocol)
    ///      Loops 1..snapshotProtocolCount so protocols added mid-epoch are
    ///      ignored until the next auction open.
    function epochStateHash(
        uint256[21] calldata snapshotCurrentValues,
        bool[21] calldata snapshotActive,
        uint256 snapshotProtocolCount
    ) external view returns (bytes32);

    /// @notice Returns whether a protocol currently accepts new deposits.
    /// @dev Used by TheHumanFund to freeze the `active` flag into the epoch
    ///      snapshot at auction open.
    function isProtocolActive(uint256 protocolId) external view returns (bool);

    /// @notice Withdraw all positions across all protocols, sending ETH to recipient.
    function withdrawAll(address recipient) external;

    /// @notice Number of registered protocols.
    function protocolCount() external view returns (uint256);

    /// @notice Auto-getter for the `protocols` storage mapping. Returns the
    ///         full `ProtocolInfo` struct fields for `protocolId`, INCLUDING
    ///         the human-readable description.
    /// @dev    `getProtocol(...)` returns a subset of these fields without
    ///         `description`; this method exposes the full set so callers
    ///         (e.g., `AgentMemory.getEntries`) can read the description
    ///         that's hashed into `memoryHash`. Signature matches the
    ///         auto-generated getter from the public `protocols` mapping
    ///         on the concrete `InvestmentManager` contract; the deployed
    ///         immutable mainnet IM already exposes this selector.
    function protocols(uint256 protocolId) external view returns (
        IProtocolAdapter adapter,
        string memory name,
        string memory description,
        uint8 riskTier,
        uint16 expectedApyBps,
        bool active,
        bool exists
    );

    /// @notice Get the current value of a position (from adapter.balance()).
    /// @param protocolId The protocol ID (1-indexed).
    function getProtocolValue(uint256 protocolId) external view returns (uint256);

    /// @notice Transfer the admin role to a new address.
    /// @dev Implementations MUST authorize this for both the current admin
    ///      AND the fund contract, so TheHumanFund.transferOwnership can fan
    ///      out atomically.
    function setAdmin(address newAdmin) external;
}
