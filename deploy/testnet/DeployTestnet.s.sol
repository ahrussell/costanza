// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─── Testnet deploy script (Base Sepolia) ────────────────────────────────────
// Uses mock contracts instead of real DeFi/Endaoment integrations.
// Mock adapters hold ETH with no yield; MockVerifier always passes.
//
// Usage:
//   source .env.testnet-deploy
//   forge script deploy/testnet/DeployTestnet.s.sol:DeployTestnet \
//     --rpc-url $RPC_URL --broadcast --legacy -vvv
// ─────────────────────────────────────────────────────────────────────────────

import "forge-std/Script.sol";
import "../../src/TheHumanFund.sol";
import "../../src/AuctionManager.sol";
import "../../src/TdxVerifier.sol";
import "../../src/InvestmentManager.sol";
import "../../src/WorldView.sol";
import "../../src/interfaces/IProofVerifier.sol";
import "../../src/interfaces/IProtocolAdapter.sol";

// ─── Mock: proof verifier that always passes ─────────────────────────────────
contract MockVerifier is IProofVerifier {
    function verify(bytes32, bytes32, bytes calldata) external payable returns (bool) {
        return true;
    }
    function freeze() external {}
}

// ─── Mock: donation executor — accepts ETH, returns fake USDC amount ─────────
// TheHumanFund calls donationExecutor.executeDonate{value:}(ein) by ABI, so
// we only need to expose the same function signature; no interface needed.
contract MockDonationExecutor {
    /// @notice Pretend to donate: return a fake USDC amount (~$2000/ETH, 6 dec).
    function executeDonate(bytes32 /*ein*/) external payable returns (uint256) {
        return msg.value * 2000 / 1e12; // rough ETH→USDC (6 decimals)
    }
}

// ─── Mock: protocol adapter — holds ETH, no yield ────────────────────────────
contract MockProtocolAdapter is IProtocolAdapter {
    string private _name;
    uint256 private _balance;

    constructor(string memory name_) { _name = name_; }

    function deposit() external payable returns (uint256 shares) {
        _balance += msg.value;
        return msg.value; // 1:1 shares
    }

    function withdraw(uint256 shares) external returns (uint256 ethAmount) {
        if (shares > _balance) shares = _balance;
        _balance -= shares;
        (bool ok,) = payable(msg.sender).call{value: shares}("");
        require(ok, "transfer failed");
        return shares;
    }

    function balance() external view returns (uint256) {
        return _balance;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    receive() external payable {}
}

// ─── Deploy script ────────────────────────────────────────────────────────────
contract DeployTestnet is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 seedAmount = vm.envOr("SEED_AMOUNT", uint256(0.05 ether));
        // Base Sepolia Chainlink ETH/USD: 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1
        address ethUsdFeed = vm.envOr("ETH_USD_FEED", address(0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1));

        address deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        // ─── 1. Mock contracts ──────────────────────────────────────────────
        MockDonationExecutor mockDonExec = new MockDonationExecutor();
        MockVerifier mockVerifier = new MockVerifier();

        // ─── 2. Core contracts ──────────────────────────────────────────────
        TheHumanFund fund = new TheHumanFund{value: seedAmount}(
            1000,               // 10% initial commission
            0.001 ether,        // initial max bid
            address(mockDonExec),
            ethUsdFeed
        );

        _addNonprofits(fund);

        // Verifier ID 1: real TdxVerifier (won't pass without registered image, but deploy it)
        TdxVerifier tdxVerifier = new TdxVerifier(address(fund));
        fund.approveVerifier(1, address(tdxVerifier));

        // Verifier ID 2: MockVerifier — always passes (used by testnet prover)
        fund.approveVerifier(2, address(mockVerifier));

        AuctionManager am = new AuctionManager(address(fund));
        // Short epochs: 3min commit / 3min reveal / 6min exec = 12min total
        fund.setAuctionManager(address(am), 3 minutes, 3 minutes, 6 minutes);

        InvestmentManager im = new InvestmentManager(address(fund), deployer);
        fund.setInvestmentManager(address(im));

        WorldView wv = new WorldView(address(fund));
        fund.setWorldView(address(wv));

        _seedWorldView(fund);

        // ─── 3. Mock protocol adapters (realistic names/APYs, no real yield) ──
        MockProtocolAdapter adapter1 = new MockProtocolAdapter("Aave V3 ETH Lending");
        im.addProtocol(address(adapter1), "Aave V3 ETH",
            "Lend ETH on Aave V3. Borrowers pay interest. Extensively audited, instant liquidity.", 1, 300);

        MockProtocolAdapter adapter2 = new MockProtocolAdapter("Lido wstETH Staking");
        im.addProtocol(address(adapter2), "Lido wstETH",
            "Stake ETH via Lido for validator rewards. Risk: stETH depeg, slashing.", 1, 350);

        vm.stopBroadcast();

        // ─── Summary ────────────────────────────────────────────────────────
        console.log("");
        console.log("=== Testnet Deployment Summary ===");
        console.log("TheHumanFund:         ", address(fund));
        console.log("AuctionManager:       ", address(am));
        console.log("TdxVerifier (ID 1):   ", address(tdxVerifier));
        console.log("MockVerifier (ID 2):  ", address(mockVerifier));
        console.log("InvestmentManager:    ", address(im));
        console.log("WorldView:            ", address(wv));
        console.log("Seed amount:          ", seedAmount);
        console.log("Owner:                ", deployer);
        console.log("ETH/USD feed:         ", ethUsdFeed);
        console.log("");
        console.log("Prover .env additions:");
        console.log("  CONTRACT_ADDRESS=", address(fund));
        console.log("  RPC_URL=https://sepolia.base.org");
        console.log("  VERIFIER_ID=2");
        console.log("  GCP_IMAGE=humanfund-base-gpu-llama-b5270");
        console.log("  TEE_CLIENT=gcp-persistent");
        console.log("");
        console.log("Timing: 3min commit / 3min reveal / 6min exec = 12min epochs");
        console.log("  Use fund.resetAuction(s, s, s) from owner to adjust live");
        console.log("  Use fund.nextPhase() from owner to advance immediately");
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

    function _seedWorldView(TheHumanFund fund) internal {
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
        fund.seedWorldView(slots, titles, bodies);
    }
}
