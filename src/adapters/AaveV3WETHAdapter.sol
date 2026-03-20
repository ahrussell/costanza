// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IProtocolAdapter.sol";
import "./IWETH.sol";

/// @notice Minimal Aave V3 Pool interface for supply/withdraw.
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/// @notice Minimal aToken interface.
interface IAToken {
    function balanceOf(address account) external view returns (uint256);
}

/// @title AaveV3WETHAdapter
/// @notice Deposits ETH into Aave V3 as WETH, earning interest from borrowers.
/// @dev Risk: Low. APY: 3-6% variable. Liquidity: Instant.
///      Receipt token: aWETH (1:1 with underlying + accrued interest).
contract AaveV3WETHAdapter is IProtocolAdapter {
    IAavePool public immutable pool;
    IWETH public immutable weth;
    IAToken public immutable aWeth;
    address public immutable manager; // InvestmentManager

    constructor(address _pool, address _weth, address _aWeth, address _manager) {
        pool = IAavePool(_pool);
        weth = IWETH(_weth);
        aWeth = IAToken(_aWeth);
        manager = _manager;

        // Approve pool to spend our WETH (max approval, standard for Aave)
        IWETH(_weth).approve(_pool, type(uint256).max);
    }

    modifier onlyManager() {
        require(msg.sender == manager, "only manager");
        _;
    }

    /// @notice Deposit ETH: wrap to WETH, supply to Aave V3.
    function deposit() external payable override onlyManager returns (uint256 shares) {
        uint256 amount = msg.value;
        require(amount > 0, "zero deposit");

        // Wrap ETH to WETH
        weth.deposit{value: amount}();

        // Supply WETH to Aave V3
        uint256 balBefore = aWeth.balanceOf(address(this));
        pool.supply(address(weth), amount, address(this), 0);
        shares = aWeth.balanceOf(address(this)) - balBefore;
    }

    /// @notice Withdraw: redeem aWETH, unwrap WETH, send ETH back.
    function withdraw(uint256 shares) external override onlyManager returns (uint256 ethAmount) {
        require(shares > 0, "zero withdraw");

        // Withdraw WETH from Aave V3
        uint256 wethBefore = weth.balanceOf(address(this));
        pool.withdraw(address(weth), shares, address(this));
        uint256 wethReceived = weth.balanceOf(address(this)) - wethBefore;

        // Unwrap WETH to ETH
        weth.withdraw(wethReceived);

        // Send ETH to caller (InvestmentManager)
        ethAmount = wethReceived;
        (bool sent, ) = msg.sender.call{value: ethAmount}("");
        require(sent, "ETH transfer failed");
    }

    /// @notice Current value in ETH terms. aWETH balance includes accrued interest.
    function balance() external view override returns (uint256) {
        return aWeth.balanceOf(address(this));
    }

    function name() external pure override returns (string memory) {
        return "Aave V3 WETH";
    }

    receive() external payable {}
}
