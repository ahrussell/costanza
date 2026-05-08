// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPoolStateReader
/// @notice Reads spot price and active liquidity for a Uniswap V4 pool.
///
/// @dev V4 pool state lives inside the singleton PoolManager and is read
///      via `extsload` per the canonical storage layout (or via the
///      `StateLibrary` helper from the v4-core repo). This interface
///      isolates that complexity from the adapter so:
///        - the adapter logic is testable with simple mocks
///        - the V4 storage-layout coupling lives in one small wrapper
///          contract that can be redeployed independently
///
///      Production deployment wires `V4PoolStateReader` (see
///      `V4PoolStateReader.sol`), which wraps `IPoolManager.extsload`
///      against the live PoolManager singleton. Tests use a mock that
///      lets us drive spot/liquidity directly.
interface IPoolStateReader {
    /// @notice Current spot sqrtPrice for `poolId` (Q64.96 format).
    /// @dev Reverts if the pool doesn't exist. Caller squares to get the
    ///      raw price ratio. Spot is manipulable in a single block —
    ///      the adapter pairs this with a self-maintained spot-vs-history
    ///      gate to bound the manipulation window.
    function getSpotSqrtPriceX96(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96);

    /// @notice Active liquidity at the current tick for `poolId`.
    /// @dev Used for the per-tx pool-size cap. "Active liquidity" here
    ///      is the `liquidity` field of the V4 pool's slot0 — it
    ///      represents in-range liquidity, which is what determines
    ///      single-tick price impact.
    function getActiveLiquidity(bytes32 poolId)
        external
        view
        returns (uint128 liquidity);
}
