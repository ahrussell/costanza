// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IProtocolAdapter.sol";
import "../interfaces/IERC4626.sol";
import "./IWETH.sol";

/// @title MorphoWETHAdapter
/// @notice Deposits ETH into a Morpho Blue ERC-4626 curated WETH vault.
/// @dev Works with any ERC-4626 vault whose underlying asset is WETH.
///      Used for Gauntlet WETH Core and Steakhouse WETH vaults on Base.
///      Risk: Medium. APY: 4-7% variable. Liquidity: Instant.
contract MorphoWETHAdapter is IProtocolAdapter {
    IERC4626 public immutable vault;
    IWETH public immutable weth;
    address public immutable manager;
    string private _name;

    constructor(address _vault, address _weth, address _manager, string memory name_) {
        vault = IERC4626(_vault);
        weth = IWETH(_weth);
        manager = _manager;
        _name = name_;

        // Approve vault to spend our WETH
        IWETH(_weth).approve(_vault, type(uint256).max);
    }

    modifier onlyManager() {
        require(msg.sender == manager, "only manager");
        _;
    }

    /// @notice Deposit ETH: wrap to WETH, deposit into Morpho vault.
    function deposit() external payable override onlyManager returns (uint256 shares) {
        uint256 amount = msg.value;
        require(amount > 0, "zero deposit");

        // Wrap ETH to WETH
        weth.deposit{value: amount}();

        // Deposit WETH into ERC-4626 vault
        shares = vault.deposit(amount, address(this));
    }

    /// @notice Withdraw: redeem vault shares for WETH, unwrap to ETH.
    function withdraw(uint256 shares) external override onlyManager returns (uint256 ethAmount) {
        require(shares > 0, "zero withdraw");

        // Redeem shares for WETH
        uint256 wethReceived = vault.redeem(shares, address(this), address(this));

        // Unwrap WETH to ETH
        weth.withdraw(wethReceived);

        // Send ETH to caller (InvestmentManager)
        ethAmount = wethReceived;
        (bool sent, ) = msg.sender.call{value: ethAmount}("");
        require(sent, "ETH transfer failed");
    }

    /// @notice Current value in ETH. Vault shares appreciate as interest accrues.
    function balance() external view override returns (uint256) {
        uint256 shares = vault.balanceOf(address(this));
        if (shares == 0) return 0;
        return vault.convertToAssets(shares);
    }

    function name() external view override returns (string memory) {
        return _name;
    }

    receive() external payable {}
}
