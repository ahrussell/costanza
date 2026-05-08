// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ISwapExecutor.sol";

// ─── V4 minimal types ──────────────────────────────────────────────────

/// @notice V4's PoolKey, redefined locally to avoid taking a dependency
///         on @uniswap/v4-core. Five-tuple uniquely identifying a pool
///         inside the PoolManager singleton.
struct PoolKeyV4 {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @notice V4's swap parameters.
struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

/// @notice Minimal interface for the parts of V4 PoolManager we use.
interface IPoolManagerV4 {
    /// @return delta packed as `int256(int128(amount0) << 128 | uint128(int128(amount1)))`
    function swap(PoolKeyV4 memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 delta);

    function unlock(bytes calldata data) external returns (bytes memory);
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
    function sync(address currency) external;
}

/// @notice Minimal ERC-20 surface used by the executor.
interface IERC20Swap {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// ─── V4SwapExecutor ────────────────────────────────────────────────────

/// @title V4SwapExecutor
/// @notice Production implementation of `ISwapExecutor` for a single
///         Uniswap V4 pool. Per-pool — one executor instance per
///         (PoolManager, PoolKey).
///
/// @dev Uses the V4 `unlock` callback pattern rather than going through
///      UniversalRouter:
///        1. `swap(...)` validates the pair, pulls/accepts the input,
///           calls `poolManager.unlock(data)`.
///        2. `unlockCallback(data)` (called by PoolManager): does the
///           swap, settles the input-side currency delta, takes the
///           output-side delta, returns the amount taken.
///        3. `swap(...)` decodes the amount, asserts >= minOut, and
///           forwards the output to the original caller.
///
///      Direct PoolManager use is more code than UniversalRouter but
///      keeps the dependency surface small (no router, no commands
///      encoding) and the gas predictable. Adapter is the only intended
///      caller; not access-controlled at this layer because the
///      adapter holds the only `tokenIn` allowance.
contract V4SwapExecutor is ISwapExecutor {
    error Unauthorized();
    error UnsupportedPair();
    error MsgValueMismatch();
    error InsufficientOutput();
    error TransferFailed();

    /// @notice Just below MAX_TICK and just above MIN_TICK in V4's
    ///         sqrtPriceX96 representation. Used as `sqrtPriceLimitX96`
    ///         to disable the limit (i.e., let the swap execute fully
    ///         against available liquidity).
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4295128740;
    uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;

    IPoolManagerV4 public immutable poolManager;

    /// @notice PoolKey fields, flattened (struct fields can't be
    ///         immutable in Solidity).
    address public immutable currency0;
    address public immutable currency1;
    uint24  public immutable poolFee;
    int24   public immutable poolTickSpacing;
    address public immutable poolHooks;

    constructor(address _poolManager, PoolKeyV4 memory _key) {
        poolManager     = IPoolManagerV4(_poolManager);
        currency0       = _key.currency0;
        currency1       = _key.currency1;
        poolFee         = _key.fee;
        poolTickSpacing = _key.tickSpacing;
        poolHooks       = _key.hooks;
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut
    ) external payable override returns (uint256 amountOut) {
        // Pair must match this executor's pool.
        if (!_isValidPair(tokenIn, tokenOut)) revert UnsupportedPair();

        bool zeroForOne = tokenIn == currency0;

        if (tokenIn == address(0)) {
            if (msg.value != amountIn) revert MsgValueMismatch();
        } else {
            // Adapter has pre-approved us; pull the input.
            if (msg.value != 0) revert MsgValueMismatch();
            if (!IERC20Swap(tokenIn).transferFrom(msg.sender, address(this), amountIn)) {
                revert TransferFailed();
            }
        }

        bytes memory data = abi.encode(tokenIn, tokenOut, amountIn, zeroForOne);
        bytes memory result = poolManager.unlock(data);
        amountOut = abi.decode(result, (uint256));

        if (amountOut < minOut) revert InsufficientOutput();

        // Forward output to the caller (adapter).
        if (tokenOut == address(0)) {
            (bool ok, ) = msg.sender.call{value: amountOut}("");
            if (!ok) revert TransferFailed();
        } else {
            if (!IERC20Swap(tokenOut).transfer(msg.sender, amountOut)) {
                revert TransferFailed();
            }
        }
    }

    /// @notice Called by PoolManager during `unlock`. Performs the swap
    ///         and settles the resulting deltas.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();

        (address tokenIn, address tokenOut, uint256 amountIn, bool zeroForOne) =
            abi.decode(data, (address, address, uint256, bool));
        tokenOut; // silence unused — needed only for the input decoding

        PoolKeyV4 memory key = PoolKeyV4({
            currency0:   currency0,
            currency1:   currency1,
            fee:         poolFee,
            tickSpacing: poolTickSpacing,
            hooks:       poolHooks
        });

        SwapParams memory params = SwapParams({
            zeroForOne:        zeroForOne,
            amountSpecified:   -int256(amountIn),  // negative = exact-input
            sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT
        });

        int256 packedDelta = poolManager.swap(key, params, "");
        int128 d0 = int128(packedDelta >> 128);
        int128 d1 = int128(packedDelta);

        // For an exact-input swap:
        //   zeroForOne=true:  d0 < 0 (we owe currency0), d1 > 0 (pool owes us currency1)
        //   zeroForOne=false: d1 < 0 (we owe currency1), d0 > 0 (pool owes us currency0)
        if (zeroForOne) {
            _settle(currency0, uint256(int256(-d0)));
            uint256 outAmt = uint256(int256(d1));
            poolManager.take(currency1, address(this), outAmt);
            return abi.encode(outAmt);
        } else {
            _settle(currency1, uint256(int256(-d1)));
            uint256 outAmt = uint256(int256(d0));
            poolManager.take(currency0, address(this), outAmt);
            return abi.encode(outAmt);
        }

        // Quiet the compiler about tokenIn (used implicitly via
        // zeroForOne, which was derived from it in the caller).
        // (No-op; tokenIn was decoded for symmetry with future variants.)
    }

    function _settle(address currency, uint256 amount) internal {
        if (currency == address(0)) {
            poolManager.settle{value: amount}();
        } else {
            // V4 settlement for ERC-20: sync, transfer to manager, settle.
            poolManager.sync(currency);
            if (!IERC20Swap(currency).transfer(address(poolManager), amount)) {
                revert TransferFailed();
            }
            poolManager.settle();
        }
    }

    function _isValidPair(address a, address b) internal view returns (bool) {
        return (a == currency0 && b == currency1) || (a == currency1 && b == currency0);
    }

    /// @dev Accept native ETH from PoolManager during a `take` of
    ///      currency0 == address(0) on a native-ETH pool.
    receive() external payable {}
}
