// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPoolOracle
/// @notice Stub TWAP oracle interface for the $COSTANZA Uniswap V4 pool.
///
/// @dev Uniswap V4 has no built-in pool oracle (V3's `pool.observe()`
///      doesn't exist in V4). Oracles are implemented as opt-in hook
///      contracts attached to the pool — common upstream shapes:
///
///        - `observe(poolId, secondsAgos[]) → tickCumulatives[]` —
///          V3-shaped. Caller computes the average tick from two
///          cumulatives, then converts to sqrtPriceX96 via TickMath.
///        - `consult(poolId, secondsAgo) → averageTick` — minimal hook.
///        - Hook-specific shapes (TruncatedOracle, etc.).
///
///      The adapter sees only this interface — a thin wrapper contract
///      handles the hook-specific shape and the tick→sqrtPriceX96
///      conversion in one place. This keeps the adapter math uniform
///      with the spot reader (which also returns sqrtPriceX96) and
///      avoids porting TickMath into the adapter.
interface IPoolOracle {
    /// @notice Time-weighted average sqrtPriceX96 for `poolId` over the
    ///         last `secondsAgo` seconds.
    /// @dev Returned in Q64.96 fixed-point — same shape as
    ///      `IPoolStateReader.getSpotSqrtPriceX96`. Reverts if the
    ///      oracle has insufficient history. `balance()` wraps this in
    ///      try/catch and falls back to the cost-basis floor on failure.
    function consultSqrtPriceX96(bytes32 poolId, uint32 secondsAgo)
        external
        view
        returns (uint160 averageSqrtPriceX96);
}
