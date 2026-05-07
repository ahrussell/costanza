// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title V4PriceMath (test helper)
/// @notice Convert between human-readable prices and V4's `sqrtPriceX96`
///         representation. Tests use this to seed mock pool state at
///         a desired price.
///
/// @dev V4 sqrtPriceX96 = sqrt(token1Amount / token0Amount) × 2^96.
///      We standardize input as "tokens per ETH × 1e18" — e.g.,
///      1000e18 means "1 ETH buys 1000 tokens." The library inverts
///      the ratio if the token sits on the lower side of the pool.
library V4PriceMath {
    /// @notice Compute sqrtPriceX96 for a pool whose token-side trades at
    ///         `tokensPerEth18` tokens per ETH (scaled by 1e18).
    /// @param tokensPerEth18  Tokens-per-ETH in 1e18 fixed-point.
    /// @param tokenIsCurrency0 Whether the token is currency0 (lower-address side).
    ///                         If true: ratio (token1/token0) = ETH/token = 1/tokensPerEth.
    ///                         If false: ratio (token1/token0) = token/ETH = tokensPerEth.
    function sqrtPriceX96FromTokensPerEth18(uint256 tokensPerEth18, bool tokenIsCurrency0)
        internal
        pure
        returns (uint160)
    {
        require(tokensPerEth18 > 0, "rate=0");
        uint256 ratioX192 = tokenIsCurrency0
            ? Math.mulDiv(1e18, 1 << 192, tokensPerEth18)
            : Math.mulDiv(tokensPerEth18, 1 << 192, 1e18);
        uint256 result = Math.sqrt(ratioX192);
        require(result <= type(uint160).max, "sqrtPrice overflow");
        return uint160(result);
    }
}
