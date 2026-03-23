// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TheHumanFund.sol";

contract MessagesTest is Test {
    TheHumanFund public fund;

    address donor1 = address(0x2001);
    address donor2 = address(0x2002);
    address referrer = address(0x3001);

    function setUp() public {
        fund = new TheHumanFund{value: 5 ether}(
            1000,              // 10% commission
            0.005 ether,       // initial max bid
            address(0xBEEF),   // endaomentFactory
            address(0xBEEF),   // weth
            address(0xBEEF),   // usdc
            address(0xBEEF)    // swapRouter
        );

        fund.addNonprofit("GiveDirectly", "Cash transfers", bytes32("EIN-GD"));
        fund.addNonprofit("Against Malaria Foundation", "Malaria prevention", bytes32("EIN-AMF"));
        fund.addNonprofit("Helen Keller International", "NTDs", bytes32("EIN-HKI"));
    }

    // ─── donateWithMessage ──────────────────────────────────────────────

    function test_donate_with_message() public {
        vm.deal(donor1, 1 ether);
        vm.prank(donor1);
        fund.donateWithMessage{value: 0.01 ether}(0, "Hello from a donor!");

        assertEq(fund.messageCount(), 1);
        assertEq(fund.messageHead(), 0);
        assertEq(fund.treasuryBalance(), 5.01 ether);
        assertEq(fund.currentEpochInflow(), 0.01 ether);
        assertEq(fund.currentEpochDonationCount(), 1);

        // Read the message
        (address[] memory senders, uint256[] memory amounts, string[] memory texts, uint256[] memory epochNums) = fund.getUnreadMessages();
        assertEq(senders.length, 1);
        assertEq(senders[0], donor1);
        assertEq(amounts[0], 0.01 ether);
        assertEq(keccak256(bytes(texts[0])), keccak256(bytes("Hello from a donor!")));
        assertEq(epochNums[0], 1);
    }

    function test_donate_with_message_requires_min_amount() public {
        vm.deal(donor1, 1 ether);
        vm.prank(donor1);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.donateWithMessage{value: 0.005 ether}(0, "Too cheap!");
    }

    function test_donate_with_message_and_referral() public {
        // Mint referral code
        vm.prank(referrer);
        uint256 codeId = fund.mintReferralCode();

        vm.deal(donor1, 1 ether);
        vm.prank(donor1);
        fund.donateWithMessage{value: 0.1 ether}(codeId, "Referred donation with message");

        assertEq(fund.messageCount(), 1);
        // 5 seed + 0.1 donation - 0.01 commission (10% paid immediately) = 5.09
        assertEq(fund.treasuryBalance(), 5.09 ether);

        // Check referral tracking
        (,uint256 totalReferred, uint256 referralCount,) = fund.referralCodes(codeId);
        assertEq(totalReferred, 0.1 ether);
        assertEq(referralCount, 1);
    }

    function test_message_truncated_to_280() public {
        // Create a message longer than 280 characters
        bytes memory longMsg = new bytes(400);
        for (uint256 i = 0; i < 400; i++) {
            longMsg[i] = bytes1(uint8(65 + (i % 26))); // A-Z repeating
        }

        vm.deal(donor1, 1 ether);
        vm.prank(donor1);
        fund.donateWithMessage{value: 0.01 ether}(0, string(longMsg));

        (,,string[] memory texts,) = fund.getUnreadMessages();
        assertEq(bytes(texts[0]).length, 280);
    }

    function test_empty_message_allowed() public {
        vm.deal(donor1, 1 ether);
        vm.prank(donor1);
        fund.donateWithMessage{value: 0.01 ether}(0, "");

        assertEq(fund.messageCount(), 1);
        (,,string[] memory texts,) = fund.getUnreadMessages();
        assertEq(bytes(texts[0]).length, 0);
    }

    // ─── Message Queue / Head Advancement ────────────────────────────────

    function test_message_head_advances_after_epoch() public {
        // Send 3 messages
        vm.deal(donor1, 1 ether);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(donor1);
            fund.donateWithMessage{value: 0.01 ether}(0, "msg");
        }
        assertEq(fund.messageCount(), 3);
        assertEq(fund.messageHead(), 0);

        // Execute an epoch (advances head)
        bytes memory noopAction = bytes(hex"00");
        fund.submitEpochAction(noopAction, "reasoning");

        assertEq(fund.messageHead(), 3);

        // No unread messages now
        (address[] memory senders,,,) = fund.getUnreadMessages();
        assertEq(senders.length, 0);
    }

    function test_message_head_caps_at_max_per_epoch() public {
        // Send 25 messages (more than MAX_MESSAGES_PER_EPOCH = 20)
        vm.deal(donor1, 1 ether);
        for (uint256 i = 0; i < 25; i++) {
            vm.prank(donor1);
            fund.donateWithMessage{value: 0.01 ether}(0, "msg");
        }
        assertEq(fund.messageCount(), 25);

        // Execute epoch — should only advance by 20
        bytes memory noopAction = bytes(hex"00");
        fund.submitEpochAction(noopAction, "reasoning");

        assertEq(fund.messageHead(), 20);

        // 5 unread messages remain
        (address[] memory senders,,,) = fund.getUnreadMessages();
        assertEq(senders.length, 5);
    }

    function test_unread_messages_bounded_by_max() public {
        // Send 30 messages
        vm.deal(donor1, 10 ether);
        for (uint256 i = 0; i < 30; i++) {
            vm.prank(donor1);
            fund.donateWithMessage{value: 0.01 ether}(0, "msg");
        }

        // getUnreadMessages returns at most MAX_MESSAGES_PER_EPOCH
        (address[] memory senders,,,) = fund.getUnreadMessages();
        assertEq(senders.length, 20);
    }

    function test_multiple_epochs_drain_queue() public {
        // Send 25 messages
        vm.deal(donor1, 1 ether);
        for (uint256 i = 0; i < 25; i++) {
            vm.prank(donor1);
            fund.donateWithMessage{value: 0.01 ether}(0, "msg");
        }

        // Epoch 1: advances head to 20
        bytes memory noopAction = bytes(hex"00");
        fund.submitEpochAction(noopAction, "reasoning");
        assertEq(fund.messageHead(), 20);

        // Epoch 2: advances head to 25
        fund.submitEpochAction(noopAction, "reasoning");
        assertEq(fund.messageHead(), 25);

        // All read
        (address[] memory senders,,,) = fund.getUnreadMessages();
        assertEq(senders.length, 0);
    }

    // ─── Multiple Donors ─────────────────────────────────────────────────

    function test_multiple_donors_messages() public {
        vm.deal(donor1, 1 ether);
        vm.deal(donor2, 1 ether);

        vm.prank(donor1);
        fund.donateWithMessage{value: 0.05 ether}(0, "From donor 1");

        vm.prank(donor2);
        fund.donateWithMessage{value: 0.1 ether}(0, "From donor 2");

        (address[] memory senders, uint256[] memory amounts, string[] memory texts,) = fund.getUnreadMessages();
        assertEq(senders.length, 2);
        assertEq(senders[0], donor1);
        assertEq(senders[1], donor2);
        assertEq(amounts[0], 0.05 ether);
        assertEq(amounts[1], 0.1 ether);
        assertEq(keccak256(bytes(texts[0])), keccak256(bytes("From donor 1")));
        assertEq(keccak256(bytes(texts[1])), keccak256(bytes("From donor 2")));
    }

    // ─── Events ──────────────────────────────────────────────────────────

    function test_emits_message_received_event() public {
        vm.deal(donor1, 1 ether);
        vm.prank(donor1);

        vm.expectEmit(true, false, true, true);
        emit TheHumanFund.MessageReceived(donor1, 0.01 ether, 0);

        fund.donateWithMessage{value: 0.01 ether}(0, "Hello!");
    }

    function test_emits_donation_received_event_with_message() public {
        vm.deal(donor1, 1 ether);
        vm.prank(donor1);

        vm.expectEmit(true, false, true, true);
        emit TheHumanFund.DonationReceived(donor1, 0.01 ether, 0, 0);

        fund.donateWithMessage{value: 0.01 ether}(0, "Hello!");
    }

    // ─── Input Hash ──────────────────────────────────────────────────────

    function test_input_hash_includes_messages() public {
        bytes32 hashBefore = fund.computeInputHash();

        vm.deal(donor1, 1 ether);
        vm.prank(donor1);
        fund.donateWithMessage{value: 0.01 ether}(0, "Changes the hash");

        bytes32 hashAfter = fund.computeInputHash();
        assertTrue(hashBefore != hashAfter);
    }

    // ─── Regular donate still works without message ──────────────────────

    function test_regular_donate_no_message() public {
        vm.deal(donor1, 1 ether);
        vm.prank(donor1);
        fund.donate{value: 0.001 ether}(0);

        assertEq(fund.messageCount(), 0);
        assertEq(fund.treasuryBalance(), 5.001 ether);
    }
}
