// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IEndaoment.sol";
import "./interfaces/IAggregatorV3.sol";
import "./adapters/IWETH.sol";
import "./adapters/SwapHelper.sol"; // for IERC20

/// @title DonationExecutor
/// @notice Handles the ETH → WETH → USDC → Endaoment donation pipeline.
///         Extracted from TheHumanFund to keep the main contract under the
///         EIP-170 bytecode limit. Stateless — all DeFi interaction logic
///         lives here; nonprofit accounting stays on TheHumanFund.
///
/// @dev Called exclusively by TheHumanFund._executeDonate(). The fund
///      sends ETH and receives back the USDC donation amount. The fund
///      handles bounds checking (max donation, nonprofit existence) and
///      state updates (totalDonated, donationCount, etc.).
contract DonationExecutor {
    // ─── Immutables ──────────────────────────────────────────────────
    IEndaomentFactory public immutable endaomentFactory;
    IWETH public immutable weth;
    address public immutable usdc;
    address public immutable swapRouter;
    IAggregatorV3 public immutable ethUsdFeed;

    // ─── Constants ───────────────────────────────────────────────────
    /// @dev 3% slippage tolerance for ETH→USDC swap (same as TheHumanFund)
    uint256 private constant DONATION_SLIPPAGE_BPS = 300;
    /// @dev Chainlink price freshness threshold
    uint256 private constant PRICE_STALENESS_THRESHOLD = 3600;

    constructor(
        address _endaomentFactory,
        address _weth,
        address _usdc,
        address _swapRouter,
        address _ethUsdFeed
    ) {
        endaomentFactory = IEndaomentFactory(_endaomentFactory);
        weth = IWETH(_weth);
        usdc = _usdc;
        swapRouter = _swapRouter;
        ethUsdFeed = IAggregatorV3(_ethUsdFeed);
    }

    /// @notice Execute a donation: ETH → WETH → USDC → Endaoment org.
    /// @param ein The nonprofit's EIN (bytes32). Used to compute the
    ///        deterministic Endaoment org address and deploy if needed.
    /// @return usdcAmount The actual USDC donated (swap output).
    ///         Returns 0 on any failure (oracle stale, swap reverted, etc.)
    ///         so the caller can treat it as a no-op without reverting.
    function executeDonate(bytes32 ein) external payable returns (uint256 usdcAmount) {
        uint256 amount = msg.value;
        if (amount == 0) return 0;

        // Compute Endaoment org address from EIN (deterministic via CREATE2)
        address orgAddr = endaomentFactory.computeOrgAddress(ein);

        // Deploy org if not yet deployed on this chain (one-time cost)
        if (orgAddr.code.length == 0) {
            endaomentFactory.deployOrg(ein);
        }

        // Compute slippage floor from Chainlink ETH/USD price
        uint256 minUsdc = _minUsdcForDonation(amount);
        if (minUsdc == 0) return 0; // Oracle unavailable

        // Swap ETH → WETH → USDC via Uniswap V3 SwapRouter02
        weth.deposit{value: amount}();
        weth.approve(swapRouter, amount);
        (bool swapOk, bytes memory swapRet) = swapRouter.call(abi.encodeWithSignature(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
            address(weth), usdc, uint24(500), address(this),
            amount, minUsdc, uint160(0)
        ));
        weth.approve(swapRouter, 0); // Clear residual allowance
        if (!swapOk) return 0;
        usdcAmount = abi.decode(swapRet, (uint256));

        // Donate USDC to Endaoment org
        IERC20(usdc).approve(orgAddr, usdcAmount);
        IEndaomentOrg(orgAddr).donate(usdcAmount);
        IERC20(usdc).approve(orgAddr, 0); // Clear residual
    }

    /// @dev Minimum USDC expected for `ethAmount` wei, with slippage tolerance.
    ///      Reads FRESH from oracle (not cached) to prevent stale-price sandwiches.
    function _minUsdcForDonation(uint256 ethAmount) internal view returns (uint256) {
        if (address(ethUsdFeed) == address(0)) return 0;
        try ethUsdFeed.latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0 || block.timestamp - updatedAt > PRICE_STALENESS_THRESHOLD) return 0;
            // ETH/USD has 8 decimals, USDC has 6. ethAmount in wei (18 decimals).
            // expected = ethAmount * price / 1e20 (18 + 8 - 6 = 20)
            uint256 expected = (ethAmount * uint256(answer)) / 1e20;
            return (expected * (10000 - DONATION_SLIPPAGE_BPS)) / 10000;
        } catch {
            return 0;
        }
    }
}
