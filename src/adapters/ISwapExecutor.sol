// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISwapExecutor
/// @notice Executes a single-pool swap on behalf of the adapter.
///
/// @dev Insulates the adapter from V4 swap plumbing (PoolManager
///      unlock callbacks, currency-delta settlement). Production
///      deployment wires `V4SwapExecutor` (see `V4SwapExecutor.sol`),
///      which drives PoolManager directly via `unlock` rather than
///      going through UniversalRouter — fewer dependencies, more
///      predictable gas. Tests use a mock with a configurable spot
///      rate.
///
///      The executor is responsible for:
///        - moving `amountIn` of `tokenIn` from the adapter to itself
///          (for ERC-20) or accepting it via `msg.value` (for native ETH)
///        - executing the swap against the configured V4 pool
///        - sending exactly `amountOut` of `tokenOut` back to the adapter
///          (for ERC-20) or via the adapter's `receive()` (for native ETH)
///        - reverting if `amountOut < minOut`
///
///      The adapter pre-approves the executor for `tokenIn` ERC-20
///      transfers. For native ETH, the adapter forwards `msg.value`.
interface ISwapExecutor {
    /// @notice Swap `amountIn` of `tokenIn` for at least `minOut` of `tokenOut`.
    /// @param tokenIn  Address of input token. `address(0)` for native ETH.
    /// @param tokenOut Address of output token. `address(0)` for native ETH.
    /// @param amountIn Exact amount of input token.
    /// @param minOut   Minimum acceptable output (slippage floor).
    /// @return amountOut Actual amount of output token received by the caller.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut
    ) external payable returns (uint256 amountOut);
}
