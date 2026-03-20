// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IWETH.sol";

/// @notice Minimal ERC20 interface.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @notice Minimal Uniswap V3 SwapRouter interface.
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
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
abstract contract SwapHelper {
    IWETH public immutable weth;
    IERC20 public immutable usdc;
    ISwapRouter public immutable swapRouter;
    uint24 public immutable swapFee; // typically 500 (0.05%) for WETH/USDC on Base

    constructor(address _weth, address _usdc, address _swapRouter, uint24 _swapFee) {
        weth = IWETH(_weth);
        usdc = IERC20(_usdc);
        swapRouter = ISwapRouter(_swapRouter);
        swapFee = _swapFee;

        // Pre-approve router for max spending
        IWETH(_weth).approve(_swapRouter, type(uint256).max);
        IERC20(_usdc).approve(_swapRouter, type(uint256).max);
    }

    /// @notice Swap ETH to USDC. Returns USDC amount received.
    function _swapEthToUsdc(uint256 ethAmount) internal returns (uint256 usdcAmount) {
        // Wrap ETH to WETH
        weth.deposit{value: ethAmount}();

        // Swap WETH -> USDC
        usdcAmount = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(usdc),
                fee: swapFee,
                recipient: address(this),
                amountIn: ethAmount,
                amountOutMinimum: 0, // TODO: add slippage protection
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @notice Swap USDC to ETH. Returns ETH amount received.
    function _swapUsdcToEth(uint256 usdcAmount) internal returns (uint256 ethAmount) {
        // Swap USDC -> WETH
        uint256 wethReceived = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(weth),
                fee: swapFee,
                recipient: address(this),
                amountIn: usdcAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // Unwrap WETH to ETH
        weth.withdraw(wethReceived);
        ethAmount = wethReceived;
    }
}
