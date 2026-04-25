// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─── Helper deploy script used by prover/client/test_pipeline.py ─────────────
// Deploys a fully-configured fund stack on a local anvil so the pytest can
// exercise the real read_contract_state pipeline against a real contract.
//
// Differences from DeployTestnet.s.sol:
//   - Deploys a MockChainlinkFeed (anvil has no real Chainlink address).
//   - Skips real-name nonprofit data; uses minimal stub entries.
//   - Tighter epoch timing so anvil time math doesn't matter.
// ─────────────────────────────────────────────────────────────────────────────

import "forge-std/Script.sol";
import "../../src/TheHumanFund.sol";
import "../../src/AuctionManager.sol";
import "../../src/InvestmentManager.sol";
import "../../src/AgentMemory.sol";
import "./MockEndaoment.sol";

contract MockDonExec {
    function executeDonate(bytes32) external payable returns (uint256) {
        return msg.value * 2000 / 1e12;
    }
}

contract DeployForPipelineTest is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        MockChainlinkFeed feed = new MockChainlinkFeed(2000e8, 8);
        MockDonExec donExec = new MockDonExec();

        TheHumanFund fund = new TheHumanFund{value: 0.05 ether}(
            1000,           // 10% commission
            0.001 ether,    // initial max bid
            address(donExec),
            address(feed)
        );

        fund.addNonprofit("Helen Keller International", "Vision", bytes32("EIN-HKI"));
        fund.addNonprofit("GiveDirectly", "Cash transfers", bytes32("EIN-GD"));

        // Wire managers + seed memory BEFORE setAuctionManager — that call
        // eagerly opens epoch 1 and freezes its snapshot, so anything wired
        // afterward would be invisible to epoch 1's frozen sub-hashes.
        InvestmentManager im = new InvestmentManager(address(fund), deployer);
        fund.setInvestmentManager(address(im));

        AgentMemory mem = new AgentMemory(address(fund));
        fund.setAgentMemory(address(mem));

        uint256[] memory slots = new uint256[](2);
        string[] memory titles = new string[](2);
        string[] memory bodies = new string[](2);
        slots[0] = 0; titles[0] = "Voice"; bodies[0] = "Plainspoken.";
        slots[1] = 3; titles[1] = "Mood"; bodies[1] = "Hopeful.";
        fund.seedMemory(slots, titles, bodies);

        AuctionManager am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am), 5 minutes, 5 minutes, 15 minutes);

        vm.stopBroadcast();

        // The pytest greps stdout for "TheHumanFund: 0x..." so this format
        // must stay stable.
        console.log("TheHumanFund:", address(fund));
        console.log("AuctionManager:", address(am));
        console.log("InvestmentManager:", address(im));
        console.log("AgentMemory:", address(mem));
    }
}
