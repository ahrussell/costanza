// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IProtocolAdapter.sol";
import "../interfaces/IAggregatorV3.sol";
import "./IWETH.sol";

/// @notice Minimal cbETH interface (Coinbase Wrapped Staked ETH).
/// @dev The bridged cbETH on Base (0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22)
///      is a plain ERC20 — it does NOT expose Coinbase's `exchangeRate()`
///      (that lives on the L1 contract). We read the rate from Chainlink
///      instead. Keeping the interface here minimal avoids accidental use.
interface ICbETH {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title CbETHAdapter
/// @notice Buys cbETH (Coinbase staked ETH) via DEX swap on Base, prices it via Chainlink.
/// @dev Risk: Medium. APY: ~3% (Ethereum staking rewards). Liquidity: Instant via DEX.
///      cbETH is the bridged Base version; Coinbase's L1 exchangeRate isn't readable here,
///      so the Chainlink CBETH/ETH feed (0x806b4Ac04501c29769051e42783cF04dCE41440b on
///      Base mainnet) is the source of truth for rate-bound slippage and `balance()`.
contract CbETHAdapter is IProtocolAdapter {
    error Unauthorized();
    error ZeroAmount();
    error SwapFailed();
    error NoTokensReceived();
    error TransferFailed();
    error StaleOracle();

    /// @notice Minimum output as fraction of input (95%) to defend against sandwich attacks.
    uint256 private constant MIN_OUTPUT_BPS = 9500;

    /// @notice Maximum oracle staleness (24 hours). The Chainlink CBETH/ETH feed
    ///         on Base has a 24-hour heartbeat; the rate moves only with accrued
    ///         staking yield, so a heartbeat-stale value affects the slippage
    ///         floor by less than rounding error.
    uint256 private constant STALENESS_THRESHOLD = 86400;

    ICbETH public immutable cbETH;
    IWETH public immutable weth;
    address public immutable swapRouter;
    address public immutable manager;

    /// @notice Chainlink CBETH/ETH exchange rate feed (Base mainnet).
    /// @dev    Returns the ETH value of 1 cbETH in 1e18 fixed point. cbETH > ETH
    ///         because it accrues staking rewards.
    IAggregatorV3 public immutable cbEthRateFeed;

    constructor(
        address _cbETH,
        address _weth,
        address _swapRouter,
        address _cbEthRateFeed,
        address _manager
    ) {
        cbETH = ICbETH(_cbETH);
        weth = IWETH(_weth);
        swapRouter = _swapRouter;
        cbEthRateFeed = IAggregatorV3(_cbEthRateFeed);
        manager = _manager;

        // Pre-approve router for max spending (safe: only manager moves funds).
        IWETH(_weth).approve(_swapRouter, type(uint256).max);
        ICbETH(_cbETH).approve(_swapRouter, type(uint256).max);
    }

    /// @dev Read CBETH/ETH rate from Chainlink. Returns rate in 1e18 fixed point
    ///      (e.g. 1.13e18 means 1 cbETH = 1.13 ETH). Reverts on stale data.
    function _ethPerCbEth() internal view returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = cbEthRateFeed.latestRoundData();
        if (answer <= 0) revert StaleOracle();
        if (block.timestamp - updatedAt > STALENESS_THRESHOLD) revert StaleOracle();
        return uint256(answer);
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert Unauthorized();
        _;
    }

    /// @notice Deposit ETH: wrap to WETH, swap to cbETH via Uniswap V3 SwapRouter02.
    function deposit() external payable override onlyManager returns (uint256 shares) {
        if (msg.value == 0) revert ZeroAmount();

        // Wrap ETH -> WETH (SwapRouter02 doesn't auto-wrap).
        weth.deposit{value: msg.value}();

        // Compute expected cbETH output from the Chainlink rate.
        //   rate = ETH per cbETH (e.g. 1.13e18 means 1 cbETH = 1.13 ETH)
        //   expectedCbEth = ethAmount * 1e18 / rate
        uint256 rate = _ethPerCbEth();
        uint256 expectedCbEth = (msg.value * 1e18) / rate;
        uint256 minOut = (expectedCbEth * MIN_OUTPUT_BPS) / 10000;

        uint256 balBefore = cbETH.balanceOf(address(this));

        // SwapRouter02 uses a 7-field struct (no deadline).
        bytes memory swapData = abi.encodeWithSignature(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
            address(weth),
            address(cbETH),
            uint24(500),    // 0.05% fee tier (ETH/cbETH pair)
            address(this),
            msg.value,
            minOut,
            uint160(0)
        );
        (bool success, ) = swapRouter.call(swapData);
        if (!success) revert SwapFailed();

        shares = cbETH.balanceOf(address(this)) - balBefore;
        if (shares == 0) revert NoTokensReceived();
    }

    /// @notice Withdraw: swap cbETH back to WETH, unwrap, send ETH to manager.
    function withdraw(uint256 shares) external override onlyManager returns (uint256 ethAmount) {
        if (shares == 0) revert ZeroAmount();

        uint256 cbBal = cbETH.balanceOf(address(this));
        if (shares > cbBal) shares = cbBal;

        // Slippage floor in ETH terms — cbETH is worth more than ETH, so we
        // multiply by the Chainlink rate: ethValue = shares * rate / 1e18.
        uint256 ethValue = (shares * _ethPerCbEth()) / 1e18;

        uint256 wethBefore = weth.balanceOf(address(this));

        bytes memory swapData = abi.encodeWithSignature(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
            address(cbETH),
            address(weth),
            uint24(500),
            address(this),
            shares,
            (ethValue * MIN_OUTPUT_BPS) / 10000,
            uint160(0)
        );
        (bool success, ) = swapRouter.call(swapData);
        if (!success) revert SwapFailed();

        uint256 wethReceived = weth.balanceOf(address(this)) - wethBefore;
        if (wethReceived == 0) revert NoTokensReceived();

        // Unwrap WETH -> ETH, forward to manager.
        weth.withdraw(wethReceived);
        ethAmount = wethReceived;
        (bool sent, ) = msg.sender.call{value: ethAmount}("");
        if (!sent) revert TransferFailed();
    }

    /// @notice Current value in ETH terms using the Chainlink CBETH/ETH rate.
    /// @dev    `balance()` must always succeed for state-hash computation, so
    ///         on a stale feed we fall back to the conservative bridged 1:1
    ///         ratio rather than reverting.
    function balance() external view override returns (uint256) {
        uint256 cbBal = cbETH.balanceOf(address(this));
        if (cbBal == 0) return 0;
        (, int256 answer, , uint256 updatedAt, ) = cbEthRateFeed.latestRoundData();
        if (answer <= 0 || block.timestamp - updatedAt > STALENESS_THRESHOLD) {
            return cbBal; // conservative fallback: 1:1
        }
        return (cbBal * uint256(answer)) / 1e18;
    }

    function name() external pure override returns (string memory) {
        return "Coinbase cbETH";
    }

    receive() external payable {}
}
