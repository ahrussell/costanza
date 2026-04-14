// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IProtocolAdapter.sol";
import "../interfaces/IAggregatorV3.sol";
import "./IWETH.sol";

/// @notice Minimal wstETH interface.
/// @dev The bridged wstETH on Base (0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452)
///      is a plain ERC20 — it does NOT expose Lido's exchange-rate functions
///      (stEthPerToken / getStETHByWstETH). We read the rate from Chainlink
///      instead. Keeping the interface here minimal avoids accidental use.
interface IWstETH {
    function balanceOf(address account) external view returns (uint256);
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
    error StaleOracle();

    /// @notice Minimum output as fraction of expected (95%) to defend against sandwich attacks.
    uint256 private constant MIN_OUTPUT_BPS = 9500;
    /// @notice Maximum oracle staleness (24 hours). The Chainlink wstETH/stETH
    ///         exchange-rate feed on Base has a 24-hour heartbeat — the rate
    ///         moves ~0.02% per day so even a full-heartbeat-stale value
    ///         affects the 5% slippage floor by less than a rounding error.
    uint256 private constant STALENESS_THRESHOLD = 86400;

    IWstETH public immutable wstETH;
    IWETH   public immutable weth;
    address public immutable manager;

    // For Base: we swap ETH -> wstETH via Uniswap instead of Lido submit
    // (Lido submit only works on L1). Base's Uniswap V3 SwapRouter02 does NOT
    // accept ETH directly on exactInputSingle — we wrap to WETH first, approve
    // the router once (in the constructor), and swap token-to-token.
    address public immutable swapRouter;

    /// @notice Chainlink wstETH/stETH exchange rate feed (Base mainnet).
    /// @dev    Returns the stETH value of 1 wstETH in 1e18 fixed point. Since
    ///         stETH ≈ 1 ETH at Lido submit, this doubles as the wstETH/ETH rate.
    IAggregatorV3 public immutable wstEthRateFeed;

    constructor(
        address _wstETH,
        address _weth,
        address _swapRouter,
        address _wstEthRateFeed,
        address _manager
    ) {
        wstETH = IWstETH(_wstETH);
        weth = IWETH(_weth);
        swapRouter = _swapRouter;
        wstEthRateFeed = IAggregatorV3(_wstEthRateFeed);
        manager = _manager;

        // One-time max approvals so the swap path never has to pay for SLOAD+SSTORE.
        // Safe because `manager` is the only caller that can move funds in/out.
        IWETH(_weth).approve(_swapRouter, type(uint256).max);
        IWstETH(_wstETH).approve(_swapRouter, type(uint256).max);
    }

    /// @dev Read wstETH/ETH rate from Chainlink. Returns rate in 1e18 fixed point
    ///      (e.g. 1.23e18 means 1 wstETH = 1.23 ETH). Reverts on stale data.
    function _wstEthPerEth() internal view returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = wstEthRateFeed.latestRoundData();
        if (answer <= 0) revert StaleOracle();
        if (block.timestamp - updatedAt > STALENESS_THRESHOLD) revert StaleOracle();
        return uint256(answer);
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert Unauthorized();
        _;
    }

    /// @notice Deposit ETH: wrap to WETH, swap to wstETH via Uniswap V3.
    function deposit() external payable override onlyManager returns (uint256 shares) {
        if (msg.value == 0) revert ZeroAmount();

        // Wrap ETH -> WETH (SwapRouter02 on Base does not auto-wrap).
        weth.deposit{value: msg.value}();

        // Compute expected wstETH output from the Chainlink exchange rate.
        //   rate = wstETH/ETH (e.g. 1.23e18 means 1 wstETH = 1.23 ETH)
        //   expectedWstETH = ethAmount / rate * 1e18
        // At rate = 1.23e18, 1 ETH buys ~0.813 wstETH.
        uint256 rate = _wstEthPerEth();
        uint256 expectedWstETH = (msg.value * 1e18) / rate;
        uint256 minOut = (expectedWstETH * MIN_OUTPUT_BPS) / 10000; // 95% floor

        uint256 balBefore = wstETH.balanceOf(address(this));

        // Uniswap V3 SwapRouter02.exactInputSingle — 7-field struct (no deadline;
        // SwapRouter02 dropped the deadline field when introducing multicall support).
        // tokenIn=WETH, tokenOut=wstETH, fee=100 (0.01%), recipient=this.
        bytes memory swapData = abi.encodeWithSignature(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
            address(weth),
            address(wstETH),
            uint24(100),    // 0.01% fee tier
            address(this),
            msg.value,
            minOut,
            uint160(0)      // sqrtPriceLimitX96 (no limit)
        );
        (bool success, ) = swapRouter.call(swapData);
        if (!success) revert SwapFailed();

        shares = wstETH.balanceOf(address(this)) - balBefore;
        if (shares == 0) revert NoTokensReceived();
    }

    /// @notice Withdraw: swap wstETH back to WETH, unwrap, send ETH to manager.
    function withdraw(uint256 shares) external override onlyManager returns (uint256 ethAmount) {
        if (shares == 0) revert ZeroAmount();

        uint256 wstETHBal = wstETH.balanceOf(address(this));
        if (shares > wstETHBal) shares = wstETHBal;

        // Slippage floor in ETH terms — wstETH is worth more than ETH, so we
        // multiply by the Chainlink rate: ethValue = shares * rate / 1e18.
        uint256 ethValue = (shares * _wstEthPerEth()) / 1e18;

        uint256 wethBefore = weth.balanceOf(address(this));

        bytes memory swapData = abi.encodeWithSignature(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
            address(wstETH),
            address(weth),
            uint24(100),
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

    /// @notice Current value in ETH terms using the Chainlink wstETH/stETH rate.
    /// @dev    Non-view Chainlink read is fine here because `balance()` is called
    ///         from other non-view paths; the feed is staleness-checked internally.
    function balance() external view override returns (uint256) {
        uint256 wstBal = wstETH.balanceOf(address(this));
        if (wstBal == 0) return 0;
        // Read rate directly (can't call _wstEthPerEth which reverts on stale —
        // balance() must always succeed for state-hash computation). Fall back
        // to the bridged 1:1 ratio if the feed is stale rather than reverting.
        (, int256 answer, , uint256 updatedAt, ) = wstEthRateFeed.latestRoundData();
        if (answer <= 0 || block.timestamp - updatedAt > STALENESS_THRESHOLD) {
            return wstBal; // conservative fallback: 1:1
        }
        return (wstBal * uint256(answer)) / 1e18;
    }

    function name() external pure override returns (string memory) {
        return "Lido wstETH";
    }

    receive() external payable {}
}
