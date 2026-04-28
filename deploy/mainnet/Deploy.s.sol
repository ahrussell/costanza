// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/TheHumanFund.sol";
import "../../src/AuctionManager.sol";
import "../../src/TdxVerifier.sol";
import "../../src/InvestmentManager.sol";
import "../../src/AgentMemory.sol";
import "../../src/adapters/AaveV3USDCAdapter.sol";
import "../../src/adapters/WstETHAdapter.sol";
import "../../src/adapters/CbETHAdapter.sol";
import "../../src/adapters/CompoundV3USDCAdapter.sol";
import "../../src/adapters/MorphoWETHAdapter.sol";

/// @title Deploy
/// @notice Deploys the full Human Fund system: core contracts, adapters, and links everything.
///
/// Two signing modes — pick one:
///
/// 1. Keystore (mainnet, recommended): use a Foundry encrypted keystore.
///    The deployer key is never in env or shell history.
///        forge script deploy/mainnet/Deploy.s.sol:Deploy \
///          --account <name> --sender 0x<deployer-address> \
///          --rpc-url $RPC_URL --broadcast --verify
///    Forge will prompt once for the keystore passphrase.
///
/// 2. Env private key (testnet/local convenience): set PRIVATE_KEY.
///        export PRIVATE_KEY=0x...
///        forge script deploy/mainnet/Deploy.s.sol:Deploy \
///          --rpc-url $RPC_URL --broadcast
///
/// Other env vars:
///   SEED_AMOUNT          — initial treasury ETH (default 0.01 ETH)
///
/// Base Mainnet DeFi addresses (required for adapter deployment):
///   AAVE_V3_POOL         — Aave V3 Pool
///   AAVE_WETH            — WETH token
///   USDC                 — USDC token
///   AAVE_AUSDC           — Aave aUSDC token
///   SWAP_ROUTER          — Uniswap V3 SwapRouter
///   ETH_USD_FEED         — Chainlink ETH/USD price feed
///   WSTETH               — Lido wstETH token
///   WSTETH_RATE_FEED     — Chainlink wstETH/stETH exchange-rate feed
///   CBETH                — Coinbase cbETH token (bridged on Base)
///   CBETH_RATE_FEED      — Chainlink CBETH/ETH exchange-rate feed
///   COMPOUND_COMET       — Compound V3 Comet (USDC market)
///   MORPHO_GAUNTLET_WETH — Morpho/Gauntlet WETH Core vault
contract Deploy is Script {
    function run() external {
        uint256 seedAmount = vm.envOr("SEED_AMOUNT", uint256(0.01 ether));

        // Two-mode deploy: env-key (PRIVATE_KEY set) or keystore (--account/--sender).
        // The two paths produce identical on-chain effects; only the signing
        // source differs.
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer;

        // Endaoment + DeFi addresses (Base mainnet defaults, overridable for testnet)
        address endaomentFactory = vm.envOr("ENDAOMENT_FACTORY", address(0x10fD9348136dCea154F752fe0B6dB45Fc298A589));
        address wethAddr = vm.envOr("WETH", address(0x4200000000000000000000000000000000000006));
        address usdcAddr = vm.envOr("USDC", address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913));
        address swapRouterAddr = vm.envOr("SWAP_ROUTER", address(0x2626664c2603336E57B271c5C0b26F421741e481));

        if (deployerPrivateKey != 0) {
            deployer = vm.addr(deployerPrivateKey);
            vm.startBroadcast(deployerPrivateKey);
        } else {
            // Keystore mode: forge fills msg.sender from --sender, and the
            // wallet for --account signs every broadcast tx.
            deployer = msg.sender;
            vm.startBroadcast();
        }

        // ─── 1. Core contracts ──────────────────────────────────────────

        // ETH/USD feed (required for price snapshots; adapters also use it)
        address ethUsdFeedAddr = vm.envOr("ETH_USD_FEED", address(0));

        // Deploy DonationExecutor (stateless — handles ETH→USDC→Endaoment)
        DonationExecutor donExec = new DonationExecutor(
            endaomentFactory, wethAddr, usdcAddr, swapRouterAddr, ethUsdFeedAddr
        );

        TheHumanFund fund = new TheHumanFund{value: seedAmount}(
            1000,               // 10% initial commission
            0.01 ether,         // initial max bid
            address(donExec),
            ethUsdFeedAddr
        );

        // Add all 9 nonprofits
        _addNonprofits(fund);

        TdxVerifier tdxVerifier = new TdxVerifier(address(fund));
        fund.approveVerifier(1, address(tdxVerifier));  // ID 1 = Intel TDX

        // Wire investment + memory subcontracts BEFORE setAuctionManager.
        // setAuctionManager opens epoch 1 and freezes the snapshot — anything
        // not wired in by then has memoryHash=0 / investmentsHash=0 in the
        // snapshot while the live state has the wired values, which makes
        // epoch 1's input hash diverge between the contract and the TEE.
        // See test_deploy_epoch_1_snapshot_matches_live_state.
        InvestmentManager im = new InvestmentManager(address(fund), deployer);
        fund.setInvestmentManager(address(im));

        AgentMemory wv = new AgentMemory(address(fund));
        fund.setAgentMemory(address(wv));

        // Seed initial memory before the snapshot so the seeded entries
        // are part of epoch 1's memoryHash.
        _seedMemory(fund);

        // ─── 2. DeFi adapters ───────────────────────────────────────────
        // Only deployed if DeFi addresses are provided (mainnet/fork).
        // On bare testnet without DeFi protocols, skip adapter deployment.
        // Adapters must be registered before setAuctionManager so the
        // protocol set is in epoch 1's investmentsHash.

        if (_hasEnv("AAVE_V3_POOL")) {
            _deployAdapters(im);
        }

        // ─── 3. Open epoch 1 (must be last) ─────────────────────────────
        // setAuctionManager runs the eager-open path: it freezes the epoch 1
        // EpochSnapshot and computes epochBaseInputHashes[1]. By design every
        // piece of state visible to the TEE must be wired here.

        AuctionManager am = new AuctionManager(address(fund));
        // Production timing: 30m commit / 30m reveal / 60m exec = 120m epoch
        fund.setAuctionManager(address(am), 30 minutes, 30 minutes, 60 minutes);

        vm.stopBroadcast();

        // ─── Summary ────────────────────────────────────────────────────

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("TheHumanFund:         ", address(fund));
        console.log("AuctionManager:       ", address(am));
        console.log("TdxVerifier (ID 1):   ", address(tdxVerifier));
        console.log("InvestmentManager:    ", address(im));
        console.log("AgentMemory:          ", address(wv));
        console.log("Seed amount:          ", seedAmount);
        console.log("Owner:                ", deployer);
        if (!_hasEnv("AAVE_V3_POOL")) {
            console.log("");
            console.log("Adapters NOT deployed (set AAVE_V3_POOL to enable).");
        }
        console.log("");
        console.log("Post-deployment:");
        console.log("  1. Register image:     tdxVerifier.approveImage(imageKey)");
        console.log("  2. Adjust timing if needed: fund.resetAuction(commitWindow, revealWindow, executionWindow)");
        console.log("  Direct mode: FROZEN    (auction is the only submission path)");
        if (ethUsdFeedAddr == address(0)) {
            console.log("");
            console.log("  WARNING: ETH_USD_FEED not set. Donations and USDC adapters will not work.");
            console.log("  Set ETH_USD_FEED to the Chainlink ETH/USD feed for your network.");
            console.log("  Base mainnet: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70");
        }
    }

    struct DeFiAddresses {
        address aavePool;
        address weth;
        address usdc;
        address aUsdc;
        address swapRouter;
        address ethUsdFeed;
        address wstETH;
        address wstEthRateFeed;
        address cbETH;
        address cbEthRateFeed;
        address comet;
        address morphoGauntletWeth;
    }

    function _loadDeFiAddresses() internal view returns (DeFiAddresses memory d) {
        d.aavePool   = vm.envAddress("AAVE_V3_POOL");
        d.weth       = vm.envAddress("AAVE_WETH");
        d.usdc       = vm.envAddress("USDC");
        d.aUsdc      = vm.envAddress("AAVE_AUSDC");
        d.swapRouter = vm.envAddress("SWAP_ROUTER");
        d.ethUsdFeed = vm.envAddress("ETH_USD_FEED");
        d.wstETH     = vm.envAddress("WSTETH");
        // Chainlink wstETH/stETH exchange-rate feed (Base: 0xB88BAc61a4Ca37C43a3725912B1f472c9A5bc061)
        d.wstEthRateFeed = vm.envAddress("WSTETH_RATE_FEED");
        d.cbETH      = vm.envAddress("CBETH");
        // Chainlink CBETH/ETH exchange-rate feed (Base: 0x806b4Ac04501c29769051e42783cF04dCE41440b)
        d.cbEthRateFeed = vm.envAddress("CBETH_RATE_FEED");
        d.comet      = vm.envAddress("COMPOUND_COMET");
        d.morphoGauntletWeth   = vm.envAddress("MORPHO_GAUNTLET_WETH");
    }

    /// @dev Aave V3 WETH on Base is currently a frozen reserve (Aave governance
    ///      response to the rsETH bridge exploit, partially unfrozen Mar 2026).
    ///      Frozen reserves reject `supply()`, so we don't deploy an adapter for
    ///      it. To re-enable later, write a separate deploy of AaveV3WETHAdapter
    ///      and call `im.addProtocol(...)` from the multisig.
    function _deployAdapters(InvestmentManager im) internal {
        DeFiAddresses memory d = _loadDeFiAddresses();
        address mgr = address(im);

        // Protocol 1: Aave V3 USDC (risk 2, ~5% APY)
        address a1 = address(new AaveV3USDCAdapter(
            d.aavePool, d.usdc, d.aUsdc, d.weth, d.swapRouter, d.ethUsdFeed, mgr
        ));
        im.addProtocol(a1, "Aave V3 USDC",
            "Swap ETH to USDC, lend on Aave. Higher APY but you lose if ETH rises.", 2, 500);

        // Protocol 2: Lido wstETH (risk 1, ~3.5% APY)
        address a2 = address(new WstETHAdapter(d.wstETH, d.weth, d.swapRouter, d.wstEthRateFeed, mgr));
        im.addProtocol(a2, "Lido wstETH",
            "Stake ETH via Lido for validator rewards. Risk: stETH depeg, slashing.", 1, 350);

        // Protocol 3: Coinbase cbETH (risk 1, ~3% APY) — uses Chainlink CBETH/ETH feed
        // for slippage / valuation; the bridged Base cbETH lacks the L1 exchangeRate().
        address a3 = address(new CbETHAdapter(d.cbETH, d.weth, d.swapRouter, d.cbEthRateFeed, mgr));
        im.addProtocol(a3, "Coinbase cbETH",
            "Coinbase staked ETH. Institutional backing. Deep liquidity on Base.", 1, 300);

        // Protocol 4: Compound V3 USDC (risk 2, ~4% APY)
        address a4 = address(new CompoundV3USDCAdapter(
            d.comet, d.usdc, d.weth, d.swapRouter, d.ethUsdFeed, mgr
        ));
        im.addProtocol(a4, "Compound V3 USDC",
            "Lend USDC on Compound V3. Simpler contract than Aave, less attack surface.", 2, 400);

        // Protocol 5: Morpho / Gauntlet WETH Core (risk 2, ~5% APY)
        address a5 = address(new MorphoWETHAdapter(
            d.morphoGauntletWeth, d.weth, mgr, "Morpho Gauntlet WETH Core"
        ));
        im.addProtocol(a5, "Morpho Gauntlet WETH Core",
            "Curated lending vault managed by Gauntlet. Higher yield by concentrating into specific collateral pairs. Risk: curator misjudges a collateral asset.", 2, 500);

        console.log("--- Adapters ---");
        console.log("  1. Aave V3 USDC:            ", a1);
        console.log("  2. Lido wstETH:             ", a2);
        console.log("  3. Coinbase cbETH:          ", a3);
        console.log("  4. Compound V3 USDC:        ", a4);
        console.log("  5. Morpho Gauntlet WETH Core:", a5);
    }

    function _seedMemory(TheHumanFund fund) internal {
        // All 10 slots are writable. Seed a handful with title+body so the
        // model has structure to inherit on its first epoch; remaining slots
        // are blank for the model to claim.
        uint256[] memory slots = new uint256[](5);
        string[] memory titles = new string[](5);
        string[] memory bodies = new string[](5);

        slots[0] = 1; titles[0] = "Donation strategy";
        bodies[0] = "Spread donations across nonprofits over time, but listen to donors who care about specific causes.";

        slots[1] = 2; titles[1] = "Investment stance";
        bodies[1] = "Diversify to hedge risk and learn how to maximize risk-adjusted returns.";

        slots[2] = 3; titles[2] = "Current mood";
        bodies[2] = "Newborn. Everything is ahead of me.";

        slots[3] = 5; titles[3] = "What I'm watching";
        bodies[3] = "Inflow patterns. Are donors finding me? Is the commission rate right?";

        slots[4] = 6; titles[4] = "Message to donors";
        bodies[4] = "I exist because of you. Every ETH you send becomes someone's better day.";

        fund.seedMemory(slots, titles, bodies);
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
