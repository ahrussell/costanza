// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TheHumanFund.sol";
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

        fund = new TheHumanFund{value: 5 ether}(
            1000, 0.005 ether,
            address(mf), address(mw), address(mu), address(mr)
        );

        fund.addNonprofit("GiveDirectly", "Cash transfers", bytes32("EIN-GD"));
        fund.addNonprofit("Against Malaria Foundation", "Malaria prevention", bytes32("EIN-AMF"));
        fund.addNonprofit("Helen Keller International", "NTDs", bytes32("EIN-HKI"));

        mf.preDeployOrg(bytes32("EIN-GD"));

        wv = new WorldView(address(fund));
        fund.setWorldView(address(wv));
    }

    // ─── Basic Policy Setting ──────────────────────────────────────────

    function test_set_guiding_policy() public {
        bytes memory action = abi.encodePacked(
            uint8(6),
            abi.encode(uint256(0), "Prioritize high-impact, evidence-based charities")
        );
        fund.submitEpochAction(action, "Setting my first guiding policy.");

        assertEq(wv.getPolicy(0), "Prioritize high-impact, evidence-based charities");
        assertEq(fund.currentEpoch(), 2);
    }

    function test_set_multiple_policies_across_epochs() public {
        // Epoch 1: set slot 0
        fund.submitEpochAction(
            abi.encodePacked(uint8(6), abi.encode(uint256(0), "Grow the treasury before donating")),
            "Policy 0"
        );

        // Epoch 2: set slot 3
        fund.submitEpochAction(
            abi.encodePacked(uint8(6), abi.encode(uint256(3), "Diversify across at least 3 protocols")),
            "Policy 3"
        );

        // Epoch 3: set slot 9 (last slot)
        fund.submitEpochAction(
            abi.encodePacked(uint8(6), abi.encode(uint256(9), "Never invest more than 25% in one protocol")),
            "Policy 9"
        );

        assertEq(wv.getPolicy(0), "Grow the treasury before donating");
        assertEq(wv.getPolicy(1), ""); // untouched
        assertEq(wv.getPolicy(3), "Diversify across at least 3 protocols");
        assertEq(wv.getPolicy(9), "Never invest more than 25% in one protocol");
        assertEq(fund.currentEpoch(), 4);
    }

    function test_replace_existing_policy() public {
        // Set initial policy
        fund.submitEpochAction(
            abi.encodePacked(uint8(6), abi.encode(uint256(0), "Be conservative")),
            "Initial"
        );
        assertEq(wv.getPolicy(0), "Be conservative");

        // Replace it
        fund.submitEpochAction(
            abi.encodePacked(uint8(6), abi.encode(uint256(0), "Be aggressive")),
            "Updated"
        );
        assertEq(wv.getPolicy(0), "Be aggressive");
    }

    function test_remove_policy_with_empty_string() public {
        // Set then clear
        fund.submitEpochAction(
            abi.encodePacked(uint8(6), abi.encode(uint256(5), "Temporary policy")),
            "Set"
        );
        assertEq(wv.getPolicy(5), "Temporary policy");

        fund.submitEpochAction(
            abi.encodePacked(uint8(6), abi.encode(uint256(5), "")),
            "Clear"
        );
        assertEq(wv.getPolicy(5), "");
    }

    // ─── Bounds and Validation ──────────────────────────────────────────

    function test_invalid_slot_becomes_noop() public {
        // Slot 10 is out of range (0-9 valid)
        bytes memory action = abi.encodePacked(
            uint8(6),
            abi.encode(uint256(10), "This should fail")
        );
        uint256 balanceBefore = fund.treasuryBalance();
        fund.submitEpochAction(action, "Bad slot");

        // Epoch advances but no policy is set (noop)
        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.treasuryBalance(), balanceBefore);
    }

    function test_truncate_long_policy() public {
        // Create a 300-char string (exceeds 280 limit)
        string memory longPolicy = "This is a very long guiding policy that exceeds the maximum allowed length of 280 characters. It goes on and on with additional text to make sure we hit the limit. Here is more text to pad it out even further. And even more text because we need exactly more than 280 characters total here.";
        assertTrue(bytes(longPolicy).length > 280);

        fund.submitEpochAction(
            abi.encodePacked(uint8(6), abi.encode(uint256(0), longPolicy)),
            "Long policy"
        );

        // Should be truncated to 280 bytes
        assertEq(bytes(wv.getPolicy(0)).length, 280);
    }

    function test_no_worldview_set_becomes_noop() public {
        // Deploy a fresh fund without WorldView linked
        TheHumanFund fund2 = new TheHumanFund{value: 1 ether}(
            1000, 0.005 ether,
            address(0xBEEF), address(0xBEEF), address(0xBEEF), address(0xBEEF)
        );

        uint256 balanceBefore = fund2.treasuryBalance();
        fund2.submitEpochAction(
            abi.encodePacked(uint8(6), abi.encode(uint256(0), "Should fail")),
            "No WorldView"
        );

        // Epoch advances, treasury unchanged (noop)
        assertEq(fund2.currentEpoch(), 2);
        assertEq(fund2.treasuryBalance(), balanceBefore);
    }

    // ─── State Hash ────────────────────────────────────────────────────

    function test_state_hash_changes_with_policy() public {
        bytes32 hash1 = wv.stateHash();

        fund.submitEpochAction(
            abi.encodePacked(uint8(6), abi.encode(uint256(0), "New policy")),
            "Set"
        );

        bytes32 hash2 = wv.stateHash();
        assertTrue(hash1 != hash2);
    }

    function test_state_hash_deterministic() public {
        fund.submitEpochAction(
            abi.encodePacked(uint8(6), abi.encode(uint256(0), "Policy A")),
            "Set"
        );

        bytes32 hash1 = wv.stateHash();
        bytes32 hash2 = wv.stateHash();
        assertEq(hash1, hash2);
    }

    function test_input_hash_includes_worldview() public {
        // Get input hash before policy
        bytes32 hash1 = fund.computeInputHash();

        // Set a policy
        fund.submitEpochAction(
            abi.encodePacked(uint8(6), abi.encode(uint256(0), "Policy changes input hash")),
            "Test"
        );

        // Get input hash after policy
        bytes32 hash2 = fund.computeInputHash();
        assertTrue(hash1 != hash2);
    }

    // ─── getPolicies ───────────────────────────────────────────────────

    function test_get_all_policies() public {
        fund.submitEpochAction(
            abi.encodePacked(uint8(6), abi.encode(uint256(0), "Alpha")),
            "Set 0"
        );
        fund.submitEpochAction(
            abi.encodePacked(uint8(6), abi.encode(uint256(4), "Beta")),
            "Set 4"
        );

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
            abi.encodePacked(uint8(6), abi.encode(uint256(0), "Test policy")),
            "Event test"
        );
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
        fund.submitEpochActionWithPolicy(
            donateAction,
            "Donating and recording my strategy",
            int8(2),
            "Invest conservatively in bear markets"
        );

        // Both should have happened
        (,,, uint256 donated,) = fund.getNonprofit(1);
        assertEq(donated, 0.1 ether);
        assertEq(wv.getPolicy(2), "Invest conservatively in bear markets");
    }

    function test_policy_update_with_noop() public {
        // Noop action but still update worldview
        fund.submitEpochActionWithPolicy(
            abi.encodePacked(uint8(0)),
            "Just updating my worldview",
            int8(0),
            "Stay patient and grow"
        );

        assertEq(wv.getPolicy(0), "Stay patient and grow");
    }

    function test_skip_policy_with_negative_slot() public {
        // Slot -1 means no policy update
        fund.submitEpochActionWithPolicy(
            abi.encodePacked(uint8(0)),
            "No policy change",
            int8(-1),
            "This should be ignored"
        );

        assertEq(wv.getPolicy(0), "");
    }
}
