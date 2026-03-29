// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IWETH.sol";
import "../interfaces/IAggregatorV3.sol";

/// @notice Minimal ERC20 interface.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @notice Minimal Uniswap V3 SwapRouter02 interface.
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}

/// @title SwapHelper
/// @notice Shared ETH <-> USDC swap logic for USDC-denominated adapters.
/// @dev Uses Uniswap V3 on Base for swaps. Inheriting adapters set addresses.
///      Chainlink ETH/USD oracle provides slippage protection.
abstract contract SwapHelper {
    error OracleUnavailable();
    IWETH public immutable weth;
    IERC20 public immutable usdc;
    ISwapRouter public immutable swapRouter;
    uint24 public immutable swapFee; // typically 500 (0.05%) for WETH/USDC on Base
    IAggregatorV3 public immutable ethUsdFeed;

    /// @notice Maximum slippage tolerance in basis points (3%).
    uint256 public constant SLIPPAGE_BPS = 300;
    /// @notice Maximum oracle staleness (1 hour).
    uint256 public constant STALENESS_THRESHOLD = 3600;

    constructor(address _weth, address _usdc, address _swapRouter, uint24 _swapFee, address _ethUsdFeed) {
        weth = IWETH(_weth);
        usdc = IERC20(_usdc);
        swapRouter = ISwapRouter(_swapRouter);
        swapFee = _swapFee;
        ethUsdFeed = IAggregatorV3(_ethUsdFeed);

        // Pre-approve router for max spending
        IWETH(_weth).approve(_swapRouter, type(uint256).max);
        IERC20(_usdc).approve(_swapRouter, type(uint256).max);
    }

    /// @notice Swap ETH to USDC. Returns USDC amount received.
    /// @dev Uses Chainlink ETH/USD price to compute minimum acceptable output.
    function _swapEthToUsdc(uint256 ethAmount) internal returns (uint256 usdcAmount) {
        // Wrap ETH to WETH
        weth.deposit{value: ethAmount}();

        // Compute minimum USDC output from Chainlink price (defense against sandwich attacks)
        uint256 minOut = _minUsdcForEth(ethAmount);

        // Swap WETH -> USDC
        usdcAmount = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(usdc),
                fee: swapFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: ethAmount,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @notice Swap USDC to ETH. Returns ETH amount received.
    /// @dev Uses Chainlink ETH/USD price to compute minimum acceptable output.
    function _swapUsdcToEth(uint256 usdcAmount) internal returns (uint256 ethAmount) {
        // Compute minimum WETH output from Chainlink price
        uint256 minOut = _minEthForUsdc(usdcAmount);

        // Swap USDC -> WETH
        uint256 wethReceived = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(weth),
                fee: swapFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: usdcAmount,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );

        // Unwrap WETH to ETH
        weth.withdraw(wethReceived);
        ethAmount = wethReceived;
    }

    /// @dev Minimum USDC expected for `ethAmount` wei, with SLIPPAGE_BPS tolerance.
    ///      Reverts if oracle is unavailable — swaps must not proceed without slippage protection.
    function _minUsdcForEth(uint256 ethAmount) internal view returns (uint256) {
        if (address(ethUsdFeed) == address(0)) revert OracleUnavailable();
        try ethUsdFeed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0) revert OracleUnavailable();
            if (block.timestamp - updatedAt > STALENESS_THRESHOLD) revert OracleUnavailable();
            // Chainlink ETH/USD has 8 decimals, USDC has 6 decimals
            // expectedUsdc = ethAmount * price / 1e18 * 1e6 / 1e8 = ethAmount * price / 1e20
            uint256 expected = (ethAmount * uint256(answer)) / 1e20;
            return (expected * (10000 - SLIPPAGE_BPS)) / 10000;
        } catch {
            revert OracleUnavailable();
        }
    }

    /// @dev Minimum ETH expected for `usdcAmount` USDC, with SLIPPAGE_BPS tolerance.
    ///      Reverts if oracle is unavailable — swaps must not proceed without slippage protection.
    function _minEthForUsdc(uint256 usdcAmount) internal view returns (uint256) {
        if (address(ethUsdFeed) == address(0)) revert OracleUnavailable();
        try ethUsdFeed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0) revert OracleUnavailable();
            if (block.timestamp - updatedAt > STALENESS_THRESHOLD) revert OracleUnavailable();
            // expectedEth = usdcAmount * 1e20 / price (inverse of above)
            uint256 expected = (usdcAmount * 1e20) / uint256(answer);
            return (expected * (10000 - SLIPPAGE_BPS)) / 10000;
        } catch {
            revert OracleUnavailable();
        }
    }
}
