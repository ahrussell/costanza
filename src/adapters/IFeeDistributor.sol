// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFeeDistributor
/// @notice Interface for the $COSTANZA creator-fee distributor.
///
/// @dev Shaped to match the Doppler hook's actual ABI on Base
///      (verified against tx 0x5f6bd727…fb37e6d5):
///        - `collectFees(poolId)` settles the pool's accrued LP fees
///          via the V4 PoolManager and forwards them to whoever is
///          the registered beneficiary for `poolId`. Permissionless
///          on the call side — any caller can trigger the sweep,
///          but the destination address is fixed by the hook's
///          internal beneficiary registry.
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
///          adapter → `dopplerHook.collectFees(poolId)` → tokens land
///          in the adapter (because adapter == registered beneficiary).
///        - Migrate path uses `updateBeneficiary` on the adapter's
///          authority (since adapter is now the beneficiary).
///
///      `MockFeeDistributor` in tests implements the same interface
///      with a simplified registry.
interface IFeeDistributor {
    /// @notice Settle pending pool fees and forward them to the
    ///         registered beneficiary for `poolId`.
    /// @dev Adapter calls this from `_claimAndForwardFees`. The hook
    ///      internally looks up the beneficiary; the caller does not
    ///      get to specify a destination. Permissionless on the
    ///      caller side — any address can trigger the sweep, but
    ///      tokens always flow to the registered beneficiary.
    function collectFees(bytes32 poolId) external;

    /// @notice Reassign the registered beneficiary for `poolId` to
    ///         `newBeneficiary`.
    /// @dev Caller must be the current beneficiary (or whatever
    ///      authority the upstream enforces). Adapter calls this
    ///      from `transferFeeClaim` and `migrate`.
    function updateBeneficiary(bytes32 poolId, address newBeneficiary) external;
}
