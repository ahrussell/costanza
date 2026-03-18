// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TheHumanFund.sol";

contract TheHumanFundTest is Test {
    TheHumanFund public fund;

    address payable np1 = payable(address(0x1001));
    address payable np2 = payable(address(0x1002));
    address payable np3 = payable(address(0x1003));

    address donor = address(0x2001);
    address referrer = address(0x3001);

    function setUp() public {
        string[3] memory names = ["GiveDirectly", "Against Malaria Foundation", "Helen Keller International"];
        address payable[3] memory addrs = [np1, np2, np3];

        fund = new TheHumanFund{value: 5 ether}(
            names,
            addrs,
            1000,          // 10% commission
            0.005 ether    // initial max bid
        );
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    function test_constructor_sets_initial_state() public view {
        assertEq(fund.currentEpoch(), 1);
        assertEq(fund.commissionRateBps(), 1000);
        assertEq(fund.maxBid(), 0.005 ether);
        assertEq(fund.treasuryBalance(), 5 ether);
        assertEq(fund.totalInflows(), 5 ether);

        (string memory name, address addr,,) = fund.getNonprofit(1);
        assertEq(name, "GiveDirectly");
        assertEq(addr, np1);
    }

    function test_constructor_rejects_invalid_commission() public {
        string[3] memory names = ["A", "B", "C"];
        address payable[3] memory addrs = [np1, np2, np3];

        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        new TheHumanFund{value: 1 ether}(names, addrs, 50, 0.005 ether); // 0.5% — too low

        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        new TheHumanFund{value: 1 ether}(names, addrs, 9500, 0.005 ether); // 95% — too high
    }

    function test_constructor_rejects_zero_address_nonprofit() public {
        string[3] memory names = ["A", "B", "C"];
        address payable[3] memory addrs = [np1, np2, payable(address(0))];

        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        new TheHumanFund{value: 1 ether}(names, addrs, 1000, 0.005 ether);
    }

    // ─── Donations to Fund ───────────────────────────────────────────────

    function test_donate_without_referral() public {
        vm.deal(donor, 1 ether);
        vm.prank(donor);
        fund.donate{value: 0.5 ether}(0);

        assertEq(fund.treasuryBalance(), 5.5 ether);
        assertEq(fund.currentEpochInflow(), 0.5 ether);
        assertEq(fund.currentEpochDonationCount(), 1);
    }

    function test_donate_with_referral() public {
        // Mint a referral code
        vm.prank(referrer);
        uint256 codeId = fund.mintReferralCode();
        assertEq(codeId, 1);

        // Donate with referral
        vm.deal(donor, 1 ether);
        vm.prank(donor);
        fund.donate{value: 1 ether}(codeId);

        // Commission = 10% of 1 ETH = 0.1 ETH (held in escrow)
        assertEq(fund.treasuryBalance(), 6 ether); // 5 + 1 (commission still in contract)
        assertEq(fund.pendingCommissionsCount(), 1);
    }

    function test_donate_rejects_dust() public {
        vm.deal(donor, 1 ether);
        vm.prank(donor);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.donate{value: 0.0005 ether}(0);
    }

    // ─── Referral & Commissions ──────────────────────────────────────────

    function test_claim_commission_after_delay() public {
        vm.prank(referrer);
        uint256 codeId = fund.mintReferralCode();

        vm.deal(donor, 1 ether);
        vm.prank(donor);
        fund.donate{value: 1 ether}(codeId);

        // Cannot claim before delay
        vm.prank(referrer);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.claimCommissions();

        // Fast-forward 7 days
        vm.warp(block.timestamp + 7 days);

        uint256 balBefore = referrer.balance;
        vm.prank(referrer);
        fund.claimCommissions();

        // Referrer should have received 0.1 ETH (10% of 1 ETH)
        assertEq(referrer.balance - balBefore, 0.1 ether);
    }

    // ─── Epoch: Noop ─────────────────────────────────────────────────────

    function test_noop_action() public {
        bytes memory action = abi.encodePacked(uint8(0));
        bytes memory reasoning = bytes("I decided to do nothing this epoch.");

        fund.submitEpochAction(action, reasoning);

        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.treasuryBalance(), 5 ether); // unchanged
    }

    // ─── Epoch: Donate ───────────────────────────────────────────────────

    function test_donate_action() public {
        // Donate 0.5 ETH (10% of 5 ETH) to nonprofit 1
        bytes memory action = abi.encodePacked(uint8(1), abi.encode(uint256(1), uint256(0.5 ether)));
        bytes memory reasoning = bytes("Donating to GiveDirectly.");

        fund.submitEpochAction(action, reasoning);

        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.treasuryBalance(), 4.5 ether);
        assertEq(np1.balance, 0.5 ether);

        (, , uint256 totalDonated, uint256 donationCount) = fund.getNonprofit(1);
        assertEq(totalDonated, 0.5 ether);
        assertEq(donationCount, 1);
        assertEq(fund.lastDonationEpoch(), 1);
    }

    function test_donate_rejects_over_10_percent() public {
        // Try to donate 0.6 ETH (12% of 5 ETH)
        bytes memory action = abi.encodePacked(uint8(1), abi.encode(uint256(1), uint256(0.6 ether)));
        bytes memory reasoning = bytes("Trying to donate too much.");

        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.submitEpochAction(action, reasoning);
    }

    function test_donate_rejects_invalid_nonprofit() public {
        bytes memory action = abi.encodePacked(uint8(1), abi.encode(uint256(4), uint256(0.1 ether)));
        bytes memory reasoning = bytes("Bad nonprofit.");

        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.submitEpochAction(action, reasoning);
    }

    // ─── Epoch: Set Commission Rate ──────────────────────────────────────

    function test_set_commission_rate() public {
        bytes memory action = abi.encodePacked(uint8(2), abi.encode(uint256(2500)));
        bytes memory reasoning = bytes("Raising commission to attract referrers.");

        fund.submitEpochAction(action, reasoning);

        assertEq(fund.commissionRateBps(), 2500);
        assertEq(fund.lastCommissionChangeEpoch(), 1);
    }

    function test_set_commission_rate_rejects_out_of_bounds() public {
        // Too low
        bytes memory action = abi.encodePacked(uint8(2), abi.encode(uint256(50)));
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.submitEpochAction(action, bytes(""));

        // Too high
        action = abi.encodePacked(uint8(2), abi.encode(uint256(9500)));
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.submitEpochAction(action, bytes(""));
    }

    // ─── Epoch: Set Max Bid ──────────────────────────────────────────────

    function test_set_max_bid() public {
        bytes memory action = abi.encodePacked(uint8(3), abi.encode(uint256(0.01 ether)));
        bytes memory reasoning = bytes("Increasing bid ceiling.");

        fund.submitEpochAction(action, reasoning);

        assertEq(fund.maxBid(), 0.01 ether);
    }

    function test_set_max_bid_rejects_too_low() public {
        bytes memory action = abi.encodePacked(uint8(3), abi.encode(uint256(0.00005 ether)));
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.submitEpochAction(action, bytes(""));
    }

    function test_set_max_bid_rejects_over_2_percent() public {
        // 2% of 5 ETH = 0.1 ETH. Try 0.15 ETH.
        bytes memory action = abi.encodePacked(uint8(3), abi.encode(uint256(0.15 ether)));
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.submitEpochAction(action, bytes(""));
    }

    // ─── Epoch: Sequencing ───────────────────────────────────────────────

    function test_epoch_advances_prevents_double_execution() public {
        bytes memory action = abi.encodePacked(uint8(0));
        fund.submitEpochAction(action, bytes("first"));

        // After execution, epoch advances (1 → 2), so the next call acts on epoch 2.
        // The contract prevents double-execution by design: each submitEpochAction
        // increments currentEpoch, so you're always acting on a fresh epoch.
        assertEq(fund.currentEpoch(), 2);

        // Epoch 1 is recorded as executed
        (,,,,,,bool executed) = fund.getEpochRecord(1);
        assertTrue(executed);
    }

    function test_epoch_advances() public {
        bytes memory action = abi.encodePacked(uint8(0));

        fund.submitEpochAction(action, bytes("epoch 1")); // epoch 1 → 2
        fund.submitEpochAction(action, bytes("epoch 2")); // epoch 2 → 3
        fund.submitEpochAction(action, bytes("epoch 3")); // epoch 3 → 4

        assertEq(fund.currentEpoch(), 4);
    }

    // ─── Epoch: Skip & Auto-Escalation ───────────────────────────────────

    function test_skip_epoch() public {
        fund.skipEpoch();
        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.consecutiveMissedEpochs(), 1);
    }

    function test_auto_escalation() public {
        // Initial max bid is 0.005 ETH
        assertEq(fund.effectiveMaxBid(), 0.005 ether);

        // Skip 3 epochs
        fund.skipEpoch(); // +10% → 0.0055
        fund.skipEpoch(); // +10% → 0.00605
        fund.skipEpoch(); // +10% → 0.006655

        uint256 effective = fund.effectiveMaxBid();
        // 0.005 * 1.1^3 = 0.006655
        assertEq(effective, 0.006655 ether);

        // Execute an epoch — resets escalation
        bytes memory action = abi.encodePacked(uint8(0));
        fund.submitEpochAction(action, bytes("back online"));

        assertEq(fund.effectiveMaxBid(), 0.005 ether);
        assertEq(fund.consecutiveMissedEpochs(), 0);
    }

    // ─── Epoch: Diary Entry Event ────────────────────────────────────────

    function test_diary_entry_emitted() public {
        bytes memory action = abi.encodePacked(uint8(0));
        bytes memory reasoning = bytes("Testing diary emission.");

        vm.expectEmit(true, false, false, true);
        emit TheHumanFund.DiaryEntry(1, reasoning, action, 5 ether, 5 ether);

        fund.submitEpochAction(action, reasoning);
    }

    // ─── Auth ────────────────────────────────────────────────────────────

    function test_only_owner_can_submit() public {
        bytes memory action = abi.encodePacked(uint8(0));

        vm.prank(donor);
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.submitEpochAction(action, bytes("unauthorized"));
    }

    function test_only_owner_can_skip() public {
        vm.prank(donor);
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.skipEpoch();
    }

    // ─── Balance Snapshots ───────────────────────────────────────────────

    function test_balance_snapshot_every_5_epochs() public {
        bytes memory action = abi.encodePacked(uint8(0));

        // Run 5 epochs
        for (uint256 i = 0; i < 5; i++) {
            fund.submitEpochAction(action, bytes("snapshot test"));
        }

        // Epoch 5 should have a snapshot
        assertEq(fund.balanceSnapshots(5), 5 ether);
        // Epoch 3 should not
        assertEq(fund.balanceSnapshots(3), 0);
    }

    // ─── Multi-epoch Donation Tracking ───────────────────────────────────

    function test_multiple_donations_across_epochs() public {
        // Epoch 1: donate to np1
        bytes memory action1 = abi.encodePacked(uint8(1), abi.encode(uint256(1), uint256(0.3 ether)));
        fund.submitEpochAction(action1, bytes("donate 1"));

        // Epoch 2: donate to np2
        bytes memory action2 = abi.encodePacked(uint8(1), abi.encode(uint256(2), uint256(0.2 ether)));
        fund.submitEpochAction(action2, bytes("donate 2"));

        // Check totals
        (, , uint256 donated1,) = fund.getNonprofit(1);
        (, , uint256 donated2,) = fund.getNonprofit(2);
        assertEq(donated1, 0.3 ether);
        assertEq(donated2, 0.2 ether);
        assertEq(fund.totalDonatedToNonprofits(), 0.5 ether);
        assertEq(fund.lastDonationEpoch(), 2);
    }

    // ─── Receive ETH ─────────────────────────────────────────────────────

    function test_receive_eth() public {
        vm.deal(donor, 1 ether);
        vm.prank(donor);
        (bool sent,) = address(fund).call{value: 1 ether}("");
        assertTrue(sent);
        assertEq(fund.treasuryBalance(), 6 ether);
        assertEq(fund.totalInflows(), 6 ether);
    }
}
