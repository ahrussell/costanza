// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
import "../src/WorldView.sol";
import "./helpers/MockEndaoment.sol";
import "./helpers/EpochTest.sol";

contract WorldViewTest is EpochTest {
    TheHumanFund public fund;
    WorldView public wv;

    function setUp() public {
        MockWETH mw = new MockWETH();
        MockUSDC mu = new MockUSDC();
        MockSwapRouter mr = new MockSwapRouter(address(mw), address(mu));
        MockEndaomentFactory mf = new MockEndaomentFactory();

        MockChainlinkFeed mfeed = new MockChainlinkFeed(2000e8, 8);
        fund = new TheHumanFund{value: 5 ether}(
            1000, 0.005 ether,
            address(mf), address(mw), address(mu), address(mr), address(mfeed)
        );

        fund.addNonprofit("GiveDirectly", "Cash transfers", bytes32("EIN-GD"));
        fund.addNonprofit("Against Malaria Foundation", "Malaria prevention", bytes32("EIN-AMF"));
        fund.addNonprofit("Helen Keller International", "NTDs", bytes32("EIN-HKI"));

        mf.preDeployOrg(bytes32("EIN-GD"));

        // Deploy AuctionManager so syncPhase() works
        AuctionManager am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am), 1200, 1200, 82800);

        wv = new WorldView(address(fund));
        fund.setWorldView(address(wv));
    }

    // ─── Basic Policy Setting (via sidecar) ───────────────────────────

    function test_set_guiding_policy() public {
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Setting my first guiding policy.",
            int8(1),
            "Prioritize high-impact, evidence-based charities"
        );

        assertEq(wv.getPolicy(1), "Prioritize high-impact, evidence-based charities");
        assertEq(fund.currentEpoch(), 2);
    }

    function test_set_multiple_policies_across_epochs() public {
        // Epoch 1: set slot 1 (slot 0 is reserved)
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Policy 1", int8(1), "Grow the treasury before donating"
        );

        // Epoch 2: set slot 3
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Policy 3", int8(3), "Diversify across at least 3 protocols"
        );

        // Epoch 3: set slot 9 (last slot)
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Policy 9", int8(9), "Never invest more than 25% in one protocol"
        );

        assertEq(wv.getPolicy(0), ""); // reserved, never writable
        assertEq(wv.getPolicy(1), "Grow the treasury before donating");
        assertEq(wv.getPolicy(2), ""); // untouched
        assertEq(wv.getPolicy(3), "Diversify across at least 3 protocols");
        assertEq(wv.getPolicy(9), "Never invest more than 25% in one protocol");
        assertEq(fund.currentEpoch(), 4);
    }

    function test_replace_existing_policy() public {
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Initial", int8(1), "Be conservative"
        );
        assertEq(wv.getPolicy(1), "Be conservative");

        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Updated", int8(1), "Be aggressive"
        );
        assertEq(wv.getPolicy(1), "Be aggressive");
    }

    function test_remove_policy_with_empty_string() public {
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Set", int8(5), "Temporary policy"
        );
        assertEq(wv.getPolicy(5), "Temporary policy");

        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Clear", int8(5), ""
        );
        assertEq(wv.getPolicy(5), "");
    }

    // ─── State Hash ────────────────────────────────────────────────────

    function test_state_hash_changes_with_policy() public {
        bytes32 hash1 = wv.stateHash();

        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Set", int8(1), "New policy"
        );

        bytes32 hash2 = wv.stateHash();
        assertTrue(hash1 != hash2);
    }

    function test_state_hash_deterministic() public {
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Set", int8(1), "Policy A"
        );

        bytes32 hash1 = wv.stateHash();
        bytes32 hash2 = wv.stateHash();
        assertEq(hash1, hash2);
    }

    function test_input_hash_includes_worldview() public {
        // Run epoch 1 with no worldview update, then advance time and run
        // epoch 2 with a worldview mutation — the two frozen snapshot
        // hashes must differ, proving the worldview sub-hash is bound
        // into _hashSnapshot.
        //
        // (The new _hashSnapshot is `pure` — it reads only from the frozen
        // EpochSnapshot struct — so within-epoch mutations don't affect
        // its output. Field coverage is tested across epoch boundaries.)
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Epoch 1", int8(-1), ""  // no worldview update
        );
        bytes32 hash1 = fund.computeInputHashForEpoch(1);

        // Advance to epoch 2 so submitEpochAction targets a fresh epoch.
        vm.warp(fund.epochStartTime(2) + 1);
        fund.syncPhase();

        fund.submitEpochAction(
            abi.encodePacked(uint8(0)),
            "Epoch 2", int8(1), "Policy changes input hash"
        );
        bytes32 hash2 = fund.computeInputHashForEpoch(2);

        assertTrue(hash1 != hash2);
    }

    // ─── getPolicies ───────────────────────────────────────────────────

    function test_get_all_policies() public {
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Set 1", int8(1), "Alpha"
        );
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Set 4", int8(4), "Beta"
        );

        string[10] memory all = wv.getPolicies();
        assertEq(all[0], ""); // reserved
        assertEq(all[1], "Alpha");
        assertEq(all[2], "");
        assertEq(all[4], "Beta");
        assertEq(all[9], "");
    }

    // ─── Event Emission ────────────────────────────────────────────────

    function test_emits_guiding_policy_event() public {
        vm.expectEmit(true, false, false, true);
        emit WorldView.GuidingPolicyUpdated(1, "Test policy");

        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Event test", int8(1), "Test policy"
        );
    }

    // ─── Only Fund Can Set ─────────────────────────────────────────────

    function test_only_fund_can_set_policy() public {
        vm.prank(address(0xdead));
        vm.expectRevert("only fund");
        wv.setPolicy(1, "Unauthorized");
    }

    /// @notice Slot 0 is reserved (legacy "diary style" slot). Writes must
    ///         revert even when called by the fund. The enclave display
    ///         skips slot 0, so allowing writes would just accumulate dead
    ///         state that's hashed but never shown.
    function test_setPolicy_rejects_slot_zero_from_fund() public {
        vm.expectRevert("invalid slot");
        vm.prank(address(fund));
        wv.setPolicy(0, "Reserved slot");
    }

    /// @notice The fund wraps worldView.setPolicy in a try/catch and
    ///         silently ignores failures — the agent's primary action
    ///         still executes, and a bad worldview slot doesn't brick
    ///         the epoch. Slot 0 attempts should therefore:
    ///           - not revert the fund call,
    ///           - leave slot 0 empty (WorldView rejected the write),
    ///           - still advance the epoch as normal.
    function test_epochAction_slot_zero_silently_ignored() public {
        uint256 epochBefore = fund.currentEpoch();
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Trying slot 0", int8(0), "Should be ignored"
        );
        // Epoch still advanced — action executed normally
        assertEq(fund.currentEpoch(), epochBefore + 1);
        // Slot 0 is still empty — WorldView rejected the write
        assertEq(wv.getPolicy(0), "");
    }

    // ─── Sidecar Policy Update ──────────────────────────────────────────

    function test_policy_update_alongside_action() public {
        // Donate AND update worldview in the same epoch
        bytes memory donateAction = abi.encodePacked(uint8(1), abi.encode(uint256(1), uint256(0.1 ether)));
        speedrunEpoch(
            fund,
            donateAction,
            "Donating and recording my strategy",
            int8(2),
            "Invest conservatively in bear markets"
        );

        // Both should have happened
        (,,, uint256 donated,,) = fund.getNonprofit(1);
        assertEq(donated, 0.1 ether);
        assertEq(wv.getPolicy(2), "Invest conservatively in bear markets");
    }

    function test_policy_update_with_noop() public {
        // Noop action but still update worldview
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Just updating my worldview",
            int8(1),
            "Stay patient and grow"
        );

        assertEq(wv.getPolicy(1), "Stay patient and grow");
    }

    function test_skip_policy_with_negative_slot() public {
        // Slot -1 means no policy update
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "No policy change",
            int8(-1),
            "This should be ignored"
        );

        assertEq(wv.getPolicy(0), "");
    }
}
