// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IProtocolAdapter.sol";

/// @notice Minimal wstETH interface.
interface IWstETH {
    function wrap(uint256 _stETHAmount) external returns (uint256);
    function unwrap(uint256 _wstETHAmount) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function getStETHByWstETH(uint256 _wstETHAmount) external view returns (uint256);
    function stEthPerToken() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Minimal stETH interface.
interface IStETH {
    function submit(address _referral) external payable returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title WstETHAdapter
/// @notice Stakes ETH via Lido (stETH) then wraps to wstETH for DeFi compatibility.
/// @dev Risk: Medium. APY: ~3-4% (Ethereum staking rewards). Liquidity: Instant via DEX.
///      wstETH accrues value vs ETH over time (no rebase).
///      On Base, wstETH is bridged — submit/wrap must happen on L1 or via a DEX.
///      This adapter buys wstETH on a DEX (Uniswap) rather than minting directly.
contract WstETHAdapter is IProtocolAdapter {
    error Unauthorized();
    error ZeroAmount();
    error SwapFailed();
    error NoTokensReceived();
    error TransferFailed();

    /// @notice Minimum output as fraction of input (95%) to defend against sandwich attacks.
    uint256 private constant MIN_OUTPUT_BPS = 9500;
    IWstETH public immutable wstETH;
    address public immutable manager;

    // For Base: we swap ETH -> wstETH via Uniswap/Aerodrome instead of Lido submit
    // (Lido submit only works on L1)
    address public immutable swapRouter;

    constructor(address _wstETH, address _swapRouter, address _manager) {
        wstETH = IWstETH(_wstETH);
        swapRouter = _swapRouter;
        manager = _manager;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert Unauthorized();
        _;
    }

    /// @notice Deposit ETH: swap to wstETH via DEX.
    function deposit() external payable override onlyManager returns (uint256 shares) {
        if (msg.value == 0) revert ZeroAmount();

        // Swap ETH -> wstETH via Uniswap V3 exactInputSingle
        uint256 balBefore = wstETH.balanceOf(address(this));

        // Encode Uniswap V3 SwapRouter02.exactInputSingle call
        // tokenIn=WETH, tokenOut=wstETH, fee=100 (0.01%), recipient=this
        bytes memory swapData = abi.encodeWithSignature(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))",
            address(0x4200000000000000000000000000000000000006), // WETH on Base
            address(wstETH),
            uint24(100),    // 0.01% fee tier
            address(this),
            block.timestamp + 300, // deadline: 5-minute buffer
            msg.value,
            (msg.value * MIN_OUTPUT_BPS) / 10000, // slippage floor: expect ≥95% of ETH value in wstETH
            uint160(0)      // sqrtPriceLimitX96 (no limit)
        );
        (bool success, ) = swapRouter.call{value: msg.value}(swapData);
        if (!success) revert SwapFailed();

        shares = wstETH.balanceOf(address(this)) - balBefore;
        if (shares == 0) revert NoTokensReceived();
    }

    /// @notice Withdraw: swap wstETH back to ETH via DEX.
    function withdraw(uint256 shares) external override onlyManager returns (uint256 ethAmount) {
        if (shares == 0) revert ZeroAmount();

        uint256 wstETHBal = wstETH.balanceOf(address(this));
        if (shares > wstETHBal) shares = wstETHBal;

        // Approve router to spend wstETH
        wstETH.approve(swapRouter, shares);

        uint256 ethBefore = address(this).balance;

        // Swap wstETH -> WETH via Uniswap V3
        // Use exchange rate for slippage floor: wstETH is worth more than ETH,
        // so floor must be in ETH terms (getStETHByWstETH converts to stETH ≈ ETH)
        uint256 ethValue = wstETH.getStETHByWstETH(shares);
        bytes memory swapData = abi.encodeWithSignature(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))",
            address(wstETH),
            address(0x4200000000000000000000000000000000000006), // WETH
            uint24(100),
            address(this),
            block.timestamp + 300, // deadline: 5-minute buffer
            shares,
            (ethValue * MIN_OUTPUT_BPS) / 10000, // slippage floor in ETH terms
            uint160(0)
        );
        (bool success, ) = swapRouter.call(swapData);
        if (!success) revert SwapFailed();

        ethAmount = address(this).balance - ethBefore;
        (bool sent, ) = msg.sender.call{value: ethAmount}("");
        if (!sent) revert TransferFailed();
    }

    /// @notice Current value in ETH terms using wstETH exchange rate.
    function balance() external view override returns (uint256) {
        uint256 wstBal = wstETH.balanceOf(address(this));
        if (wstBal == 0) return 0;
        // wstETH accrues staking rewards — stEthPerToken() gives the exchange rate
        return wstETH.getStETHByWstETH(wstBal);
    }

    function name() external pure override returns (string memory) {
        return "Lido wstETH";
    }

    receive() external payable {}
}
