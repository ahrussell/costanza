// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IProtocolAdapter
/// @notice Interface for DeFi protocol adapters used by InvestmentManager.
///         Each adapter wraps a single DeFi protocol (Aave, Lido, etc.) and
///         exposes a uniform deposit/withdraw/balance interface.
///
///         Adapters hold the receipt tokens (aTokens, wstETH, etc.) and are
///         stateful — one adapter instance per protocol registration.
interface IProtocolAdapter {
    /// @notice Deposit ETH into the underlying protocol.
    /// @return shares Protocol-specific receipt amount (e.g., aToken amount, wstETH amount).
    function deposit() external payable returns (uint256 shares);

    /// @notice Withdraw from the underlying protocol.
    /// @param shares Amount of protocol receipt tokens to redeem.
    /// @return ethAmount ETH returned (sent to msg.sender).
    function withdraw(uint256 shares) external returns (uint256 ethAmount);

    /// @notice Current value of all holdings in ETH terms.
    /// @dev Should use the protocol's native exchange rate, not an external oracle.
    function balance() external view returns (uint256 valueInEth);

    /// @notice Human-readable protocol name.
    function name() external view returns (string memory);
}
