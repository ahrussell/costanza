// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/interfaces/IEndaoment.sol";
import "../../src/interfaces/IAggregatorV3.sol";
import "../../src/adapters/IWETH.sol";
import "../../src/adapters/SwapHelper.sol";

/// @dev Mock Endaoment org that accepts USDC donations (just burns them for testing).
contract MockEndaomentOrg {
    uint256 public totalDonated;

    function donate(uint256 amount) external {
        totalDonated += amount;
        // In real Endaoment, this transfers USDC from sender. In tests, we just track it.
    }
}

/// @dev Mock Endaoment factory that deploys MockEndaomentOrg contracts.
contract MockEndaomentFactory is IEndaomentFactory {
    mapping(bytes32 => address) public orgs;

    function computeOrgAddress(bytes32 orgId) external view override returns (address) {
        return orgs[orgId];
    }

    function deployOrg(bytes32 orgId) external override returns (address) {
        if (orgs[orgId] != address(0)) return orgs[orgId];
        MockEndaomentOrg org = new MockEndaomentOrg();
        orgs[orgId] = address(org);
        return address(org);
    }

    /// @dev Pre-deploy an org for testing (so computeOrgAddress returns non-zero).
    function preDeployOrg(bytes32 orgId) external returns (address) {
        return this.deployOrg(orgId);
    }
}

/// @dev Mock WETH that wraps/unwraps ETH.
contract MockWETH is IWETH {
    mapping(address => uint256) public override balanceOf;

    function deposit() external payable override {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external override {
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }

    function approve(address, uint256) external override returns (bool) {
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

/// @dev Mock USDC (6 decimals) for testing.
contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function decimals() external pure returns (uint8) { return 6; }
}

/// @dev Mock Uniswap V3 SwapRouter that "swaps" WETH for USDC at a fixed rate.
///      Returns 2000 USDC per ETH (simplified for testing).
contract MockSwapRouter {
    MockWETH public wethToken;
    MockUSDC public usdcToken;
    uint256 public constant ETH_PRICE_USD = 2000;

    constructor(address _weth, address _usdc) {
        wethToken = MockWETH(payable(_weth));
        usdcToken = MockUSDC(_usdc);
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut)
    {
        // In real Uniswap, the router pulls WETH via transferFrom.
        // Our MockWETH doesn't track allowances, so we just burn the balance directly.
        // The fund already deposited ETH → WETH and approved us.

        // Calculate USDC output: ETH amount * price * 10^6 / 10^18
        amountOut = (params.amountIn * ETH_PRICE_USD * 1e6) / 1e18;

        // Mint USDC to recipient
        usdcToken.mint(params.recipient, amountOut);
    }
}

/// @dev Mock Chainlink V3 price feed for testing. Returns fixed ETH/USD price.
contract MockChainlinkFeed is IAggregatorV3 {
    int256 public price;
    uint8 public override decimals;

    constructor(int256 _price, uint8 _decimals) {
        price = _price;
        decimals = _decimals;
    }

    function setPrice(int256 _price) external {
        price = _price;
    }

    function latestRoundData() external view override returns (
        uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
    ) {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}
