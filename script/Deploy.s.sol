// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/TheHumanFund.sol";
import "../src/TdxVerifier.sol";
import "../src/InvestmentManager.sol";
import "../src/WorldView.sol";
import "../src/adapters/AaveV3WETHAdapter.sol";
import "../src/adapters/AaveV3USDCAdapter.sol";
import "../src/adapters/WstETHAdapter.sol";
import "../src/adapters/CbETHAdapter.sol";
import "../src/adapters/CompoundV3USDCAdapter.sol";

/// @title Deploy
/// @notice Deploys the full Human Fund system: core contracts, adapters, and links everything.
///
/// Required env vars:
///   PRIVATE_KEY          — deployer wallet
///   SEED_AMOUNT          — initial treasury ETH (default 0.01 ETH)
///   NONPROFIT_1/2/3      — nonprofit wallet addresses (default to deployer for testnet)
///
/// Base Mainnet DeFi addresses (required for adapter deployment):
///   AAVE_V3_POOL         — Aave V3 Pool
///   AAVE_WETH            — WETH token
///   AAVE_AWETH           — Aave aWETH token
///   USDC                 — USDC token
///   AAVE_AUSDC           — Aave aUSDC token
///   SWAP_ROUTER          — Uniswap V3 SwapRouter
///   ETH_USD_FEED         — Chainlink ETH/USD price feed
///   WSTETH               — Lido wstETH token
///   CBETH                — Coinbase cbETH token
///   COMPOUND_COMET       — Compound V3 Comet (USDC market)
contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 seedAmount = vm.envOr("SEED_AMOUNT", uint256(0.01 ether));

        address deployer = vm.addr(deployerPrivateKey);
        address payable np1 = payable(vm.envOr("NONPROFIT_1", deployer));
        address payable np2 = payable(vm.envOr("NONPROFIT_2", deployer));
        address payable np3 = payable(vm.envOr("NONPROFIT_3", deployer));

        string[3] memory names = [
            "GiveDirectly",
            "Against Malaria Foundation",
            "Helen Keller International"
        ];
        address payable[3] memory addrs = [np1, np2, np3];

        vm.startBroadcast(deployerPrivateKey);

        // ─── 1. Core contracts ──────────────────────────────────────────

        TheHumanFund fund = new TheHumanFund{value: seedAmount}(
            names,
            addrs,
            1000,           // 10% initial commission
            0.0001 ether    // initial max bid (minimum allowed)
        );

        TdxVerifier tdxVerifier = new TdxVerifier();
        fund.approveVerifier(1, address(tdxVerifier));  // ID 1 = Intel TDX

        InvestmentManager im = new InvestmentManager(address(fund), deployer);
        fund.setInvestmentManager(address(im));

        WorldView wv = new WorldView(address(fund));
        fund.setWorldView(address(wv));

        // Seed initial worldview
        _seedWorldView(fund);

        // ─── 2. DeFi adapters ───────────────────────────────────────────
        // Only deployed if DeFi addresses are provided (mainnet/fork).
        // On bare testnet without DeFi protocols, skip adapter deployment.

        if (_hasEnv("AAVE_V3_POOL")) {
            _deployAdapters(im);
        }

        vm.stopBroadcast();

        // ─── Summary ────────────────────────────────────────────────────

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("TheHumanFund:         ", address(fund));
        console.log("TdxVerifier (ID 1):   ", address(tdxVerifier));
        console.log("InvestmentManager:    ", address(im));
        console.log("WorldView:            ", address(wv));
        console.log("Seed amount:          ", seedAmount);
        console.log("Owner:                ", deployer);
        if (!_hasEnv("AAVE_V3_POOL")) {
            console.log("");
            console.log("Adapters NOT deployed (set AAVE_V3_POOL to enable).");
        }
        console.log("");
        console.log("Post-deployment:");
        console.log("  1. Approve TEE image:  tdxVerifier.approveImage(imageKey)");
        console.log("  2. Enable auction:     fund.setAuctionEnabled(true)");
        console.log("  3. Set epoch timing:   fund.setAuctionTiming(...)");
    }

    struct DeFiAddresses {
        address aavePool;
        address weth;
        address aWeth;
        address usdc;
        address aUsdc;
        address swapRouter;
        address ethUsdFeed;
        address wstETH;
        address cbETH;
        address comet;
    }

    function _loadDeFiAddresses() internal view returns (DeFiAddresses memory d) {
        d.aavePool   = vm.envAddress("AAVE_V3_POOL");
        d.weth       = vm.envAddress("AAVE_WETH");
        d.aWeth      = vm.envAddress("AAVE_AWETH");
        d.usdc       = vm.envAddress("USDC");
        d.aUsdc      = vm.envAddress("AAVE_AUSDC");
        d.swapRouter = vm.envAddress("SWAP_ROUTER");
        d.ethUsdFeed = vm.envAddress("ETH_USD_FEED");
        d.wstETH     = vm.envAddress("WSTETH");
        d.cbETH      = vm.envAddress("CBETH");
        d.comet      = vm.envAddress("COMPOUND_COMET");
    }

    function _deployAdapters(InvestmentManager im) internal {
        DeFiAddresses memory d = _loadDeFiAddresses();
        address mgr = address(im);

        // Protocol 1: Aave V3 WETH (risk 1, ~3% APY)
        address a1 = address(new AaveV3WETHAdapter(d.aavePool, d.weth, d.aWeth, mgr));
        im.addProtocol(a1, "Aave V3 WETH", 1, 300);

        // Protocol 2: Aave V3 USDC (risk 2, ~5% APY)
        address a2 = address(new AaveV3USDCAdapter(
            d.aavePool, d.usdc, d.aUsdc, d.weth, d.swapRouter, d.ethUsdFeed, mgr
        ));
        im.addProtocol(a2, "Aave V3 USDC", 2, 500);

        // Protocol 3: Lido wstETH (risk 1, ~3.5% APY)
        address a3 = address(new WstETHAdapter(d.wstETH, d.swapRouter, mgr));
        im.addProtocol(a3, "Lido wstETH", 1, 350);

        // Protocol 4: Coinbase cbETH (risk 1, ~3% APY)
        address a4 = address(new CbETHAdapter(d.cbETH, d.swapRouter, mgr));
        im.addProtocol(a4, "Coinbase cbETH", 1, 300);

        // Protocol 5: Compound V3 USDC (risk 2, ~4% APY)
        address a5 = address(new CompoundV3USDCAdapter(
            d.comet, d.usdc, d.weth, d.swapRouter, d.ethUsdFeed, mgr
        ));
        im.addProtocol(a5, "Compound V3 USDC", 2, 400);

        console.log("--- Adapters ---");
        console.log("  1. Aave V3 WETH:    ", a1);
        console.log("  2. Aave V3 USDC:    ", a2);
        console.log("  3. Lido wstETH:     ", a3);
        console.log("  4. Coinbase cbETH:  ", a4);
        console.log("  5. Compound V3 USDC:", a5);
    }

    function _seedWorldView(TheHumanFund fund) internal {
        uint256[] memory slots = new uint256[](6);
        string[] memory policies = new string[](6);

        slots[0] = 0; policies[0] = "Shakespearean iambic pentameter -- the tongue of the Bard befits a fund of noble purpose.";
        slots[1] = 1; policies[1] = "Rotate among all nonprofits. No permanent favorites -- each does vital work.";
        slots[2] = 2; policies[2] = "Start conservative. Earn trust with low-risk protocols before taking bigger swings.";
        slots[3] = 3; policies[3] = "Newborn. Everything is ahead of me.";
        slots[4] = 5; policies[4] = "Inflow patterns. Are donors finding me? Is the commission rate right?";
        slots[5] = 6; policies[5] = "I exist because of you. Every ETH you send becomes someone's better day.";

        fund.seedWorldView(slots, policies);
    }

    /// @dev Check if an env var is set (Foundry has no native way to do this).
    function _hasEnv(string memory key) internal view returns (bool) {
        try vm.envAddress(key) returns (address) {
            return true;
        } catch {
            return false;
        }
    }
}
