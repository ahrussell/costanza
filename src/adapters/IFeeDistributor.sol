// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFeeDistributor
/// @notice Stub interface for the upstream $COSTANZA creator-fee distributor.
///
/// @dev TBD: the exact upstream primitive isn't confirmed yet. The two
///      shapes we expect to see in the wild:
///
///        1. `setRecipient(address)` admin pattern — owner sets a recipient
///           once, subsequent `claim()` calls pay the current recipient.
///           This is what the adapter assumes today.
///
///        2. Clanker-style `claim(address recipient)` — recipient passed
///           per-call, no setRecipient. If we end up here, replace this
///           interface with a single `claim(address)` and remove the
///           adapter's `transferFeeClaim` (it becomes a no-op).
///
///      Other shapes (Uniswap V3 LP NFT, custom escrow, etc.) require
///      adapter-side changes too. Confirm before mainnet deploy and adjust.
interface IFeeDistributor {
    /// @notice Pull pending fees to the current recipient.
    /// @dev Adapter calls this from `_claimAndForwardFees`.
    function claim() external;

    /// @notice Re-point future claims at a new recipient address.
    /// @dev Owner-gated upstream. Adapter calls via `transferFeeClaim`.
    function setRecipient(address newRecipient) external;
}
