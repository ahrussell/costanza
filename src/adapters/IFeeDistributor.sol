// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFeeDistributor
/// @notice Interface for the $COSTANZA creator-fee distributor.
///
/// @dev Shaped to match the Doppler hook's actual ABI on Base:
///        - `release(poolId, beneficiary)` pulls a beneficiary's
///          accrued fees and sends them to that beneficiary's address.
///          Permissionless to call.
///        - `updateBeneficiary(poolId, newBeneficiary)` reassigns the
///          registered beneficiary. Authority is the current
///          beneficiary (the adapter, post-setup).
///
///      Production wiring:
///        - The constructor's `_feeDistributor` param is the Doppler
///          hook address (0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544
///          on Base).
///        - One-time setup before adapter operates: the existing
///          beneficiary calls
///          `dopplerHook.updateBeneficiary(poolId, address(adapter))`,
///          registering the adapter as the beneficiary.
///        - Subsequent claims route automatically:
///          adapter → `dopplerHook.release(poolId, adapter)`.
///        - Migrate path uses `updateBeneficiary` on the adapter's
///          authority (since adapter is now the beneficiary).
///
///      `MockFeeDistributor` in tests implements the same interface
///      with a simplified registry.
interface IFeeDistributor {
    /// @notice Pull pending fees to the named beneficiary.
    /// @dev Adapter calls `release(poolId, address(this))` from
    ///      `_claimAndForwardFees`. Permissionless on the upstream
    ///      side — any caller can trigger a harvest for any
    ///      registered beneficiary.
    function release(bytes32 poolId, address beneficiary) external;

    /// @notice Reassign the registered beneficiary for `poolId` to
    ///         `newBeneficiary`.
    /// @dev Caller must be the current beneficiary (or whatever
    ///      authority the upstream enforces). Adapter calls this
    ///      from `transferFeeClaim` and `migrate`.
    function updateBeneficiary(bytes32 poolId, address newBeneficiary) external;
}
