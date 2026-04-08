// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
import "../src/WorldView.sol";
import "./helpers/MockEndaoment.sol";

contract WorldViewTest is Test {
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
        fund.setAuctionManager(address(am));

        wv = new WorldView(address(fund));
        fund.setWorldView(address(wv));
    }

    // ─── Basic Policy Setting (via sidecar) ───────────────────────────

    function test_set_guiding_policy() public {
        fund.submitEpochAction(
            abi.encodePacked(uint8(0)),
            "Setting my first guiding policy.",
            int8(0),
            "Prioritize high-impact, evidence-based charities"
        );
        fund.syncPhase();

        assertEq(wv.getPolicy(0), "Prioritize high-impact, evidence-based charities");
        assertEq(fund.currentEpoch(), 2);
    }

    function test_set_multiple_policies_across_epochs() public {
        // Epoch 1: set slot 0
        fund.submitEpochAction(
            abi.encodePacked(uint8(0)),
            "Policy 0", int8(0), "Grow the treasury before donating"
        );
        fund.syncPhase();

        // Epoch 2: set slot 3
        fund.submitEpochAction(
            abi.encodePacked(uint8(0)),
            "Policy 3", int8(3), "Diversify across at least 3 protocols"
        );
        fund.syncPhase();

        // Epoch 3: set slot 9 (last slot)
        fund.submitEpochAction(
            abi.encodePacked(uint8(0)),
            "Policy 9", int8(9), "Never invest more than 25% in one protocol"
        );
        fund.syncPhase();

        assertEq(wv.getPolicy(0), "Grow the treasury before donating");
        assertEq(wv.getPolicy(1), ""); // untouched
        assertEq(wv.getPolicy(3), "Diversify across at least 3 protocols");
        assertEq(wv.getPolicy(9), "Never invest more than 25% in one protocol");
        assertEq(fund.currentEpoch(), 4);
    }

    function test_replace_existing_policy() public {
        fund.submitEpochAction(
            abi.encodePacked(uint8(0)),
            "Initial", int8(0), "Be conservative"
        );
        fund.syncPhase();
        assertEq(wv.getPolicy(0), "Be conservative");

        fund.submitEpochAction(
            abi.encodePacked(uint8(0)),
            "Updated", int8(0), "Be aggressive"
        );
        fund.syncPhase();
        assertEq(wv.getPolicy(0), "Be aggressive");
    }

    function test_remove_policy_with_empty_string() public {
        fund.submitEpochAction(
            abi.encodePacked(uint8(0)),
            "Set", int8(5), "Temporary policy"
        );
        fund.syncPhase();
        assertEq(wv.getPolicy(5), "Temporary policy");

        fund.submitEpochAction(
            abi.encodePacked(uint8(0)),
            "Clear", int8(5), ""
        );
        fund.syncPhase();
        assertEq(wv.getPolicy(5), "");
    }

    // ─── State Hash ────────────────────────────────────────────────────

    function test_state_hash_changes_with_policy() public {
        bytes32 hash1 = wv.stateHash();

        fund.submitEpochAction(
            abi.encodePacked(uint8(0)),
            "Set", int8(0), "New policy"
        );
        fund.syncPhase();

        bytes32 hash2 = wv.stateHash();
        assertTrue(hash1 != hash2);
    }

    function test_state_hash_deterministic() public {
        fund.submitEpochAction(
            abi.encodePacked(uint8(0)),
            "Set", int8(0), "Policy A"
        );
        fund.syncPhase();

        bytes32 hash1 = wv.stateHash();
        bytes32 hash2 = wv.stateHash();
        assertEq(hash1, hash2);
    }

    function test_input_hash_includes_worldview() public {
        bytes32 hash1 = fund.computeInputHash();

        fund.submitEpochAction(
            abi.encodePacked(uint8(0)),
            "Test", int8(0), "Policy changes input hash"
        );
        fund.syncPhase();

        bytes32 hash2 = fund.computeInputHash();
        assertTrue(hash1 != hash2);
    }

    // ─── getPolicies ───────────────────────────────────────────────────

    function test_get_all_policies() public {
        fund.submitEpochAction(
            abi.encodePacked(uint8(0)),
            "Set 0", int8(0), "Alpha"
        );
        fund.syncPhase();
        fund.submitEpochAction(
            abi.encodePacked(uint8(0)),
            "Set 4", int8(4), "Beta"
        );
        fund.syncPhase();

        string[10] memory all = wv.getPolicies();
        assertEq(all[0], "Alpha");
        assertEq(all[1], "");
        assertEq(all[4], "Beta");
        assertEq(all[9], "");
    }

    // ─── Event Emission ────────────────────────────────────────────────

    function test_emits_guiding_policy_event() public {
        vm.expectEmit(true, false, false, true);
        emit WorldView.GuidingPolicyUpdated(0, "Test policy");

        fund.submitEpochAction(
            abi.encodePacked(uint8(0)),
            "Event test", int8(0), "Test policy"
        );
        fund.syncPhase();
    }

    // ─── Only Fund Can Set ─────────────────────────────────────────────

    function test_only_fund_can_set_policy() public {
        vm.prank(address(0xdead));
        vm.expectRevert("only fund");
        wv.setPolicy(0, "Unauthorized");
    }

    // ─── Sidecar Policy Update ──────────────────────────────────────────

    function test_policy_update_alongside_action() public {
        // Donate AND update worldview in the same epoch
        bytes memory donateAction = abi.encodePacked(uint8(1), abi.encode(uint256(1), uint256(0.1 ether)));
        fund.submitEpochAction(
            donateAction,
            "Donating and recording my strategy",
            int8(2),
            "Invest conservatively in bear markets"
        );
        fund.syncPhase();

        // Both should have happened
        (,,, uint256 donated,,) = fund.getNonprofit(1);
        assertEq(donated, 0.1 ether);
        assertEq(wv.getPolicy(2), "Invest conservatively in bear markets");
    }

    function test_policy_update_with_noop() public {
        // Noop action but still update worldview
        fund.submitEpochAction(
            abi.encodePacked(uint8(0)),
            "Just updating my worldview",
            int8(0),
            "Stay patient and grow"
        );
        fund.syncPhase();

        assertEq(wv.getPolicy(0), "Stay patient and grow");
    }

    function test_skip_policy_with_negative_slot() public {
        // Slot -1 means no policy update
        fund.submitEpochAction(
            abi.encodePacked(uint8(0)),
            "No policy change",
            int8(-1),
            "This should be ignored"
        );
        fund.syncPhase();

        assertEq(wv.getPolicy(0), "");
    }
}
