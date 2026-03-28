// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IProtocolAdapter.sol";
import "./IWETH.sol";

/// @notice Minimal cbETH interface (Coinbase Wrapped Staked ETH).
interface ICbETH {
    function balanceOf(address account) external view returns (uint256);
    function exchangeRate() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title CbETHAdapter
/// @notice Buys cbETH (Coinbase staked ETH) via DEX swap on Base.
/// @dev Risk: Medium. APY: ~3% (Ethereum staking rewards). Liquidity: Instant via DEX.
///      cbETH is native to Base (Coinbase's own chain), so deep liquidity.
///      Exchange rate monotonically increases as staking rewards accrue.
contract CbETHAdapter is IProtocolAdapter {
    ICbETH public immutable cbETH;
    IWETH public immutable weth;
    address public immutable swapRouter;
    address public immutable manager;

    constructor(address _cbETH, address _weth, address _swapRouter, address _manager) {
        cbETH = ICbETH(_cbETH);
        weth = IWETH(_weth);
        swapRouter = _swapRouter;
        manager = _manager;
    }

    modifier onlyManager() {
        require(msg.sender == manager, "only manager");
        _;
    }

    /// @notice Deposit ETH: swap to cbETH via DEX.
    function deposit() external payable override onlyManager returns (uint256 shares) {
        require(msg.value > 0, "zero deposit");

        uint256 balBefore = cbETH.balanceOf(address(this));

        // Swap ETH -> cbETH via Uniswap V3
        bytes memory swapData = abi.encodeWithSignature(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
            address(0x4200000000000000000000000000000000000006), // WETH on Base
            address(cbETH),
            uint24(500),    // 0.05% fee tier (ETH/cbETH pair)
            address(this),
            msg.value,
            0,              // amountOutMinimum
            uint160(0)
        );
        (bool success, ) = swapRouter.call{value: msg.value}(swapData);
        require(success, "swap failed");

        shares = cbETH.balanceOf(address(this)) - balBefore;
        require(shares > 0, "no cbETH received");
    }

    /// @notice Withdraw: swap cbETH back to ETH via DEX.
    function withdraw(uint256 shares) external override onlyManager returns (uint256 ethAmount) {
        require(shares > 0, "zero withdraw");

        uint256 cbBal = cbETH.balanceOf(address(this));
        if (shares > cbBal) shares = cbBal;

        cbETH.approve(swapRouter, shares);

        uint256 ethBefore = address(this).balance;

        bytes memory swapData = abi.encodeWithSignature(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
            address(cbETH),
            address(0x4200000000000000000000000000000000000006),
            uint24(500),
            address(this),
            shares,
            0,
            uint160(0)
        );
        (bool success, ) = swapRouter.call(swapData);
        require(success, "swap failed");

        // Unwrap WETH received from swap (router returns WETH, not ETH)
        uint256 wethBal = weth.balanceOf(address(this));
        if (wethBal > 0) {
            weth.withdraw(wethBal);
        }

        ethAmount = address(this).balance - ethBefore;
        (bool sent, ) = msg.sender.call{value: ethAmount}("");
        require(sent, "ETH transfer failed");
    }

    /// @notice Current value in ETH terms using cbETH exchange rate.
    function balance() external view override returns (uint256) {
        uint256 cbBal = cbETH.balanceOf(address(this));
        if (cbBal == 0) return 0;
        // cbETH.exchangeRate() returns the amount of ETH per cbETH (18 decimals)
        return (cbBal * cbETH.exchangeRate()) / 1e18;
    }

    function name() external pure override returns (string memory) {
        return "Coinbase cbETH";
    }

    receive() external payable {}
}
