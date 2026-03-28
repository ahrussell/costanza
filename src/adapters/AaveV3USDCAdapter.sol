// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IProtocolAdapter.sol";
import "./SwapHelper.sol";

/// @notice Minimal Aave V3 Pool interface for supply/withdraw.
interface IAavePoolForUSDC {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/// @notice Minimal aToken interface.
interface IATokenForUSDC {
    function balanceOf(address account) external view returns (uint256);
}

/// @title AaveV3USDCAdapter
/// @notice Swaps ETH to USDC, deposits into Aave V3 to earn lending interest.
/// @dev Risk: Low (Aave risk) + Medium (USD/ETH exposure). APY: 4-8%.
///      Liquidity: Instant.
///      The model gains USD exposure — if ETH goes up, USD position loses relative value.
///      Conversely, if ETH drops, the USD position holds value better.
///      Uses Chainlink ETH/USD feed for mark-to-market.
contract AaveV3USDCAdapter is IProtocolAdapter, SwapHelper {
    IAavePoolForUSDC public immutable pool;
    IATokenForUSDC public immutable aUsdc;
    address public immutable manager;

    constructor(
        address _pool,
        address _usdc,
        address _aUsdc,
        address _weth,
        address _swapRouter,
        address _ethUsdFeed,
        address _manager
    ) SwapHelper(_weth, _usdc, _swapRouter, 500, _ethUsdFeed) {
        pool = IAavePoolForUSDC(_pool);
        aUsdc = IATokenForUSDC(_aUsdc);
        manager = _manager;

        // Approve pool to spend our USDC
        IERC20(_usdc).approve(_pool, type(uint256).max);
    }

    modifier onlyManager() {
        require(msg.sender == manager, "only manager");
        _;
    }

    /// @notice Deposit ETH: swap to USDC, supply to Aave V3.
    function deposit() external payable override onlyManager returns (uint256 shares) {
        require(msg.value > 0, "zero deposit");

        // Swap ETH -> USDC
        uint256 usdcReceived = _swapEthToUsdc(msg.value);

        // Supply USDC to Aave V3
        uint256 balBefore = aUsdc.balanceOf(address(this));
        pool.supply(address(usdc), usdcReceived, address(this), 0);
        shares = aUsdc.balanceOf(address(this)) - balBefore;
    }

    /// @notice Withdraw: redeem aUSDC, swap USDC to ETH, send back.
    function withdraw(uint256 shares) external override onlyManager returns (uint256 ethAmount) {
        require(shares > 0, "zero withdraw");

        uint256 aUsdcBal = aUsdc.balanceOf(address(this));
        if (shares > aUsdcBal) shares = aUsdcBal;

        // Withdraw USDC from Aave V3
        uint256 usdcBefore = usdc.balanceOf(address(this));
        pool.withdraw(address(usdc), shares, address(this));
        uint256 usdcReceived = usdc.balanceOf(address(this)) - usdcBefore;

        // Swap USDC -> ETH
        ethAmount = _swapUsdcToEth(usdcReceived);

        // Send ETH to caller
        (bool sent, ) = msg.sender.call{value: ethAmount}("");
        require(sent, "ETH transfer failed");
    }

    /// @notice Current value in ETH terms.
    /// @dev aUSDC balance (in USDC with 6 decimals) converted to ETH using Chainlink feed.
    function balance() external view override returns (uint256) {
        uint256 aUsdcBal = aUsdc.balanceOf(address(this));
        if (aUsdcBal == 0) return 0;

        // Get ETH/USD price from Chainlink (8 decimals typically)
        (, int256 ethUsdPrice, , , ) = ethUsdFeed.latestRoundData();
        if (ethUsdPrice <= 0) return 0;

        uint8 feedDecimals = ethUsdFeed.decimals();

        // aUSDC is 6 decimals, price is feedDecimals, result should be 18 decimals (ETH)
        // ethValue = aUsdcBal * 10^(18 - 6) * 10^feedDecimals / ethUsdPrice
        // = aUsdcBal * 10^(12 + feedDecimals) / ethUsdPrice
        return (aUsdcBal * (10 ** (12 + feedDecimals))) / uint256(ethUsdPrice);
    }

    function name() external pure override returns (string memory) {
        return "Aave V3 USDC";
    }

    receive() external payable {}
}
