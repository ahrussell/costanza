// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IProtocolAdapter.sol";

/// @title MockAdapter
/// @notice Simple 1:1 adapter for testing. Holds ETH directly, no real DeFi protocol.
/// @dev Deploy on testnets where real protocols don't exist.
contract MockAdapter is IProtocolAdapter {
    uint256 public totalShares;
    address public manager;
    string private _name;

    constructor(string memory name_, address _manager) {
        _name = name_;
        manager = _manager;
    }

    function deposit() external payable override returns (uint256 shares) {
        shares = msg.value;
        totalShares += shares;
    }

    function withdraw(uint256 shares) external override returns (uint256 ethAmount) {
        require(shares <= totalShares, "insufficient");
        ethAmount = shares;
        if (ethAmount > address(this).balance) ethAmount = address(this).balance;
        totalShares -= shares;
        (bool sent, ) = msg.sender.call{value: ethAmount}("");
        require(sent, "transfer failed");
    }

    function balance() external view override returns (uint256) {
        return totalShares;
    }

    function name() external view override returns (string memory) {
        return _name;
    }

    receive() external payable {}
}
