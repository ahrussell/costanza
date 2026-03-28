// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IProtocolAdapter.sol";
import "./SwapHelper.sol";

/// @notice Minimal Compound V3 (Comet) interface.
interface IComet {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/// @title CompoundV3USDCAdapter
/// @notice Swaps ETH to USDC, deposits into Compound V3 (Comet) to earn lending interest.
/// @dev Risk: Low. APY: 3-5%. Liquidity: Instant.
///      Compound V3 uses a simpler single-asset market design.
///      Similar USD exposure risk as AaveV3USDCAdapter.
contract CompoundV3USDCAdapter is IProtocolAdapter, SwapHelper {
    IComet public immutable comet;
    address public immutable manager;

    constructor(
        address _comet,
        address _usdc,
        address _weth,
        address _swapRouter,
        address _ethUsdFeed,
        address _manager
    ) SwapHelper(_weth, _usdc, _swapRouter, 500, _ethUsdFeed) {
        comet = IComet(_comet);
        manager = _manager;

        // Approve comet to spend our USDC
        IERC20(_usdc).approve(_comet, type(uint256).max);
    }

    modifier onlyManager() {
        require(msg.sender == manager, "only manager");
        _;
    }

    function deposit() external payable override onlyManager returns (uint256 shares) {
        require(msg.value > 0, "zero deposit");

        // Swap ETH -> USDC
        uint256 usdcReceived = _swapEthToUsdc(msg.value);

        // Supply USDC to Compound V3
        uint256 balBefore = comet.balanceOf(address(this));
        comet.supply(address(usdc), usdcReceived);
        shares = comet.balanceOf(address(this)) - balBefore;
    }

    function withdraw(uint256 shares) external override onlyManager returns (uint256 ethAmount) {
        require(shares > 0, "zero withdraw");

        uint256 cometBal = comet.balanceOf(address(this));
        if (shares > cometBal) shares = cometBal;

        // Withdraw USDC from Compound V3
        uint256 usdcBefore = usdc.balanceOf(address(this));
        comet.withdraw(address(usdc), shares);
        uint256 usdcReceived = usdc.balanceOf(address(this)) - usdcBefore;

        // Swap USDC -> ETH
        ethAmount = _swapUsdcToEth(usdcReceived);

        (bool sent, ) = msg.sender.call{value: ethAmount}("");
        require(sent, "ETH transfer failed");
    }

    function balance() external view override returns (uint256) {
        uint256 usdcBal = comet.balanceOf(address(this));
        if (usdcBal == 0) return 0;

        (, int256 ethUsdPrice, , , ) = ethUsdFeed.latestRoundData();
        if (ethUsdPrice <= 0) return 0;

        uint8 feedDecimals = ethUsdFeed.decimals();
        // USDC has 6 decimals, convert to 18 decimal ETH
        return (usdcBal * (10 ** (12 + feedDecimals))) / uint256(ethUsdPrice);
    }

    function name() external pure override returns (string memory) {
        return "Compound V3 USDC";
    }

    receive() external payable {}
}
