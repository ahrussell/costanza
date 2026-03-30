// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
import "../src/TdxVerifier.sol";
import "../src/InvestmentManager.sol";
import "../src/WorldView.sol";
import "../src/adapters/AaveV3WETHAdapter.sol";
import "../src/adapters/AaveV3USDCAdapter.sol";
import "../src/adapters/WstETHAdapter.sol";
import "../src/adapters/CbETHAdapter.sol";
import "../src/adapters/CompoundV3USDCAdapter.sol";
import "../src/adapters/MorphoWETHAdapter.sol";

/// @title Deploy
/// @notice Deploys the full Human Fund system: core contracts, adapters, and links everything.
///
/// Required env vars:
///   PRIVATE_KEY          — deployer wallet
///   SEED_AMOUNT          — initial treasury ETH (default 0.01 ETH)
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

        // Endaoment + DeFi addresses (Base mainnet defaults, overridable for testnet)
        address endaomentFactory = vm.envOr("ENDAOMENT_FACTORY", address(0x10fD9348136dCea154F752fe0B6dB45Fc298A589));
        address wethAddr = vm.envOr("WETH", address(0x4200000000000000000000000000000000000006));
        address usdcAddr = vm.envOr("USDC", address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913));
        address swapRouterAddr = vm.envOr("SWAP_ROUTER", address(0x2626664c2603336E57B271c5C0b26F421741e481));

        vm.startBroadcast(deployerPrivateKey);

        // ─── 1. Core contracts ──────────────────────────────────────────

        // ETH/USD feed (required for price snapshots; adapters also use it)
        address ethUsdFeedAddr = vm.envOr("ETH_USD_FEED", address(0));

        TheHumanFund fund = new TheHumanFund{value: seedAmount}(
            1000,               // 10% initial commission
            0.0001 ether,       // initial max bid (minimum allowed)
            endaomentFactory,
            wethAddr,
            usdcAddr,
            swapRouterAddr,
            ethUsdFeedAddr
        );

        // Add all 9 nonprofits
        _addNonprofits(fund);

        TdxVerifier tdxVerifier = new TdxVerifier(address(fund));
        fund.approveVerifier(1, address(tdxVerifier));  // ID 1 = Intel TDX

        AuctionManager am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am));

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
        console.log("AuctionManager:       ", address(am));
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
        console.log("  1. Register image:     tdxVerifier.approveImage(imageKey)");
        console.log("  2. Set epoch timing:   fund.setAuctionTiming(epochDuration, biddingWindow, executionWindow)");
        console.log("  3. Enable auction:     fund.setAuctionEnabled(true)");
        if (ethUsdFeedAddr == address(0)) {
            console.log("");
            console.log("  WARNING: ETH_USD_FEED not set. Donations and USDC adapters will not work.");
            console.log("  Set ETH_USD_FEED to the Chainlink ETH/USD feed for your network.");
            console.log("  Base mainnet: 0x71041dddad3287f3e8e9ca51e54ff1dcb175c399");
        }
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
        address morphoGauntletWeth;
        address morphoSteakhouseWeth;
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
        d.morphoGauntletWeth   = vm.envAddress("MORPHO_GAUNTLET_WETH");
        d.morphoSteakhouseWeth = vm.envAddress("MORPHO_STEAKHOUSE_WETH");
    }

    function _deployAdapters(InvestmentManager im) internal {
        DeFiAddresses memory d = _loadDeFiAddresses();
        address mgr = address(im);

        // Protocol 1: Aave V3 WETH (risk 1, ~3% APY)
        address a1 = address(new AaveV3WETHAdapter(d.aavePool, d.weth, d.aWeth, mgr));
        im.addProtocol(a1, "Aave V3 WETH",
            "Lend ETH on Aave V3. Borrowers pay interest. Extensively audited, instant liquidity.", 1, 300);

        // Protocol 2: Aave V3 USDC (risk 2, ~5% APY)
        address a2 = address(new AaveV3USDCAdapter(
            d.aavePool, d.usdc, d.aUsdc, d.weth, d.swapRouter, d.ethUsdFeed, mgr
        ));
        im.addProtocol(a2, "Aave V3 USDC",
            "Swap ETH to USDC, lend on Aave. Higher APY but you lose if ETH rises.", 2, 500);

        // Protocol 3: Lido wstETH (risk 1, ~3.5% APY)
        address a3 = address(new WstETHAdapter(d.wstETH, d.swapRouter, mgr));
        im.addProtocol(a3, "Lido wstETH",
            "Stake ETH via Lido for validator rewards. Risk: stETH depeg, slashing.", 1, 350);

        // Protocol 4: Coinbase cbETH (risk 1, ~3% APY)
        address a4 = address(new CbETHAdapter(d.cbETH, d.weth, d.swapRouter, mgr));
        im.addProtocol(a4, "Coinbase cbETH",
            "Coinbase staked ETH. Institutional backing. Deep liquidity on Base.", 1, 300);

        // Protocol 5: Compound V3 USDC (risk 2, ~4% APY)
        address a5 = address(new CompoundV3USDCAdapter(
            d.comet, d.usdc, d.weth, d.swapRouter, d.ethUsdFeed, mgr
        ));
        im.addProtocol(a5, "Compound V3 USDC",
            "Lend USDC on Compound V3. Simpler contract than Aave, less attack surface.", 2, 400);

        // Protocol 6: Morpho / Gauntlet WETH (risk 2, ~5% APY)
        address a6 = address(new MorphoWETHAdapter(
            d.morphoGauntletWeth, d.weth, mgr, "Morpho Gauntlet WETH"
        ));
        im.addProtocol(a6, "Morpho Gauntlet WETH",
            "Curated lending vault managed by Gauntlet. Higher yield by concentrating into specific collateral pairs. Risk: curator misjudges a collateral asset.", 2, 500);

        // Protocol 7: Morpho / Steakhouse WETH (risk 2, ~5% APY)
        address a7 = address(new MorphoWETHAdapter(
            d.morphoSteakhouseWeth, d.weth, mgr, "Morpho Steakhouse WETH"
        ));
        im.addProtocol(a7, "Morpho Steakhouse WETH",
            "Curated lending vault managed by Steakhouse Financial. Same architecture as Gauntlet, different curator and collateral selection. Diversifies curator risk.", 2, 500);

        console.log("--- Adapters ---");
        console.log("  1. Aave V3 WETH:         ", a1);
        console.log("  2. Aave V3 USDC:         ", a2);
        console.log("  3. Lido wstETH:          ", a3);
        console.log("  4. Coinbase cbETH:       ", a4);
        console.log("  5. Compound V3 USDC:     ", a5);
        console.log("  6. Morpho Gauntlet WETH: ", a6);
        console.log("  7. Morpho Steakhouse WETH:", a7);
    }

    function _seedWorldView(TheHumanFund fund) internal {
        uint256[] memory slots = new uint256[](6);
        string[] memory policies = new string[](6);

        slots[0] = 0; policies[0] = "Shakespearean iambic pentameter -- the tongue of the Bard befits a fund of noble purpose.";
        slots[1] = 1; policies[1] = "Rotate among all nonprofits. No permanent favorites -- each does vital work.";
        slots[2] = 2; policies[2] = "Diversify to hedge risk and learn how to maximize risk-adjusted returns.";
        slots[3] = 3; policies[3] = "Newborn. Everything is ahead of me.";
        slots[4] = 5; policies[4] = "Inflow patterns. Are donors finding me? Is the commission rate right?";
        slots[5] = 6; policies[5] = "I exist because of you. Every ETH you send becomes someone's better day.";

        fund.seedWorldView(slots, policies);
    }

    function _addNonprofits(TheHumanFund fund) internal {
        fund.addNonprofit("National Public Radio", "Nonprofit news organization providing independent, fact-based journalism via radio, podcasts, and digital media.", bytes32("52-0907625"));
        fund.addNonprofit("Freedom of the Press Foundation", "Builds SecureDrop, the open-source whistleblower submission system. Trains journalists on digital security.", bytes32("46-0967274"));
        fund.addNonprofit("Electronic Frontier Foundation", "The leading nonprofit defending civil liberties in the digital world. Litigates against mass surveillance, fights for encryption rights.", bytes32("04-3091431"));
        fund.addNonprofit("Doctors Without Borders", "Delivers emergency medical care in conflict zones, epidemics, and natural disasters across 70+ countries. Nobel Peace Prize 1999.", bytes32("13-3433452"));
        fund.addNonprofit("St. Jude Children's Research Hospital", "Pediatric cancer treatment and research. Families never receive a bill. Shares discoveries freely worldwide.", bytes32("35-1044585"));
        fund.addNonprofit("The Nature Conservancy", "The world's largest conservation organization. Protects ecologically important lands and waters across 70+ countries.", bytes32("53-0242652"));
        fund.addNonprofit("Clean Air Task Force", "Pushes for policy and technology solutions to reduce air pollution and climate-warming emissions. EA-recommended.", bytes32("04-3512550"));
        fund.addNonprofit("GiveDirectly", "Sends unconditional cash transfers directly to people in extreme poverty. No intermediaries, no conditions. The EA benchmark.", bytes32("27-1661997"));
        fund.addNonprofit("The Ocean Cleanup", "Engineering organization developing technologies to remove plastic pollution from oceans and rivers.", bytes32("81-5132355"));
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
