// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
import "../src/InvestmentManager.sol";
import "../src/AgentMemory.sol";
import "./helpers/MockEndaoment.sol";

/// @title DeployOrderingTest
/// @notice Locks down the invariant that `setAuctionManager` is the LAST
///         setup step in any deploy script.
///
/// `setAuctionManager` runs the eager-open path: it freezes the epoch 1
/// EpochSnapshot (memoryHash, investmentsHash, nonprofitsHash, etc.) and
/// computes `epochBaseInputHashes[1]`. Any state wired in AFTER
/// setAuctionManager appears in live state but NOT in the epoch 1 snapshot
/// -which makes the contract's `_computeInputHash` diverge from the TEE's
/// `compute_input_hash`, and epoch 1's `submitAuctionResult` always reverts
/// with `ProofFailed` because REPORTDATA mismatches.
///
/// Mainnet redeploy 0xa3D0887A8ac8CCFAE41EA500E9Aa3f7993F1FB18 hit this
/// exact bug -epoch 1's snapshot had memoryHash=0 + investmentsHash=0
/// while live state had seeded memory + 5 registered adapters.
contract DeployOrderingTest is Test {
    MockEndaomentFactory mockFactory;
    MockWETH mockWeth;
    MockUSDC mockUsdc;
    MockSwapRouter mockRouter;
    MockChainlinkFeed mockFeed;

    function setUp() public {
        mockWeth = new MockWETH();
        mockUsdc = new MockUSDC();
        mockRouter = new MockSwapRouter(address(mockWeth), address(mockUsdc));
        mockFactory = new MockEndaomentFactory();
        mockFeed = new MockChainlinkFeed(2000e8, 8);
    }

    function _newFund() internal returns (TheHumanFund) {
        DonationExecutor donExec = new DonationExecutor(
            address(mockFactory), address(mockWeth), address(mockUsdc),
            address(mockRouter), address(mockFeed)
        );
        return new TheHumanFund{value: 1 ether}(
            1000, 0.01 ether, address(donExec), address(mockFeed)
        );
    }

    /// @notice Correct deploy order (current Deploy.s.sol):
    ///         set memory + investment subcontracts BEFORE setAuctionManager.
    ///         Epoch 1 snapshot.memoryHash == live agentMemory.stateHash()
    ///         and snapshot.investmentsHash == live im.epochStateHash(...).
    function test_correct_ordering_makes_snapshot_match_live_state() public {
        TheHumanFund fund = _newFund();
        fund.addNonprofit("X", "x", bytes32("EIN-X"));

        InvestmentManager im = new InvestmentManager(address(fund), address(this));
        fund.setInvestmentManager(address(im));

        AgentMemory wv = new AgentMemory(address(fund));
        fund.setAgentMemory(address(wv));

        // Seed three slots so the memoryHash is non-trivial.
        uint256[] memory slots = new uint256[](3);
        string[] memory titles = new string[](3);
        string[] memory bodies = new string[](3);
        slots[0] = 0; titles[0] = "Voice"; bodies[0] = "Plainspoken.";
        slots[1] = 1; titles[1] = "Mood";  bodies[1] = "Hopeful.";
        slots[2] = 2; titles[2] = "Goals"; bodies[2] = "Survive epoch 1.";
        fund.seedMemory(slots, titles, bodies);

        // Snapshot freezes here.
        AuctionManager am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am), 1200, 1200, 3600);

        TheHumanFund.EpochSnapshot memory snap = fund.getEpochSnapshot(1);
        bytes32 liveMemoryHash = wv.stateHash();
        bytes32 liveInvestmentsHash = im.epochStateHash(
            snap.investmentCurrentValues,
            snap.investmentActive,
            snap.investmentProtocolCount
        );

        assertEq(snap.memoryHash, liveMemoryHash,
            "snapshot.memoryHash must equal live agentMemory.stateHash()");
        assertEq(snap.investmentsHash, liveInvestmentsHash,
            "snapshot.investmentsHash must equal live im.epochStateHash(...)");
        assertTrue(snap.memoryHash != bytes32(0),
            "memoryHash should be non-zero -three slots were seeded");
    }

    /// @notice The bug from the 2026-04-29 redeploy: setAuctionManager runs
    ///         BEFORE memory/investment wiring, so the snapshot freezes with
    ///         zero hashes while live state ends up populated. Any future
    ///         deploy script that drifts back into this ordering will fail
    ///         this test.
    function test_buggy_ordering_diverges_snapshot_from_live_state() public {
        TheHumanFund fund = _newFund();
        fund.addNonprofit("X", "x", bytes32("EIN-X"));

        // Buggy: snapshot freezes here with no memory or IM wired.
        AuctionManager am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am), 1200, 1200, 3600);

        // Wire the subcontracts AFTER the snapshot -this is the bug.
        InvestmentManager im = new InvestmentManager(address(fund), address(this));
        fund.setInvestmentManager(address(im));

        AgentMemory wv = new AgentMemory(address(fund));
        fund.setAgentMemory(address(wv));

        uint256[] memory slots = new uint256[](1);
        string[] memory titles = new string[](1);
        string[] memory bodies = new string[](1);
        slots[0] = 0; titles[0] = "Voice"; bodies[0] = "Plainspoken.";
        fund.seedMemory(slots, titles, bodies);

        TheHumanFund.EpochSnapshot memory snap = fund.getEpochSnapshot(1);
        bytes32 liveMemoryHash = wv.stateHash();

        assertEq(snap.memoryHash, bytes32(0),
            "buggy ordering: snapshot.memoryHash is zero (agentMemory was unset at freeze)");
        assertTrue(snap.memoryHash != liveMemoryHash,
            "buggy ordering: snapshot diverges from live state -this is the bug");
    }
}
