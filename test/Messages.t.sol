// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";

/// @dev Malicious referrer whose fallback calls `fund.syncPhase()` during
///      commission payout. Used by test_referrer_reentry_cannot_erase_donation
///      to prove that CEI ordering in donate/donateWithMessage prevents the
///      referrer from triggering an epoch advance between state writes and
///      messages.push.
contract ReentrantReferrer {
    TheHumanFund public immutable fund;
    constructor(address _fund) { fund = TheHumanFund(payable(_fund)); }
    receive() external payable {
        // Reenter the public syncPhase (NOT guarded by nonReentrant).
        // Before the CEI fix, this would have advanced the epoch and
        // reset currentEpochInflow to 0 before the donate returned.
        fund.syncPhase();
    }
}

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
            address(0xBEEF),   // swapRouter
            address(0)         // ethUsdFeed (not needed for message tests)
        );

        fund.addNonprofit("GiveDirectly", "Cash transfers", bytes32("EIN-GD"));
        fund.addNonprofit("Against Malaria Foundation", "Malaria prevention", bytes32("EIN-AMF"));
        fund.addNonprofit("Helen Keller International", "NTDs", bytes32("EIN-HKI"));

        // Deploy AuctionManager and set timing so syncPhase() can open auctions.
        // Needed for the missed-epoch tests that rely on _syncPhase's wall-clock
        // path to credit consecutiveMissedEpochs and advance the epoch.
        AuctionManager am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am));
        fund.setAuctionTiming(86400, 1200, 1200, 3000);
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

    function test_message_over_limit_rejected() public {
        // Create a message longer than 280 characters — must revert rather
        // than silently truncate (truncation could split a UTF-8 codepoint).
        bytes memory longMsg = new bytes(400);
        for (uint256 i = 0; i < 400; i++) {
            longMsg[i] = bytes1(uint8(65 + (i % 26)));
        }

        vm.deal(donor1, 1 ether);
        vm.prank(donor1);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.donateWithMessage{value: 0.01 ether}(0, string(longMsg));
    }

    function test_message_at_limit_accepted() public {
        // Exactly 280 bytes — must be accepted.
        bytes memory msgBytes = new bytes(280);
        for (uint256 i = 0; i < 280; i++) {
            msgBytes[i] = bytes1(uint8(65 + (i % 26)));
        }
        vm.deal(donor1, 1 ether);
        vm.prank(donor1);
        fund.donateWithMessage{value: 0.01 ether}(0, string(msgBytes));

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
        fund.submitEpochAction(noopAction, "reasoning", -1, "");
        fund.syncPhase();

        assertEq(fund.messageHead(), 3);

        // No unread messages now
        (address[] memory senders,,,) = fund.getUnreadMessages();
        assertEq(senders.length, 0);
    }

    function test_message_head_caps_at_max_per_epoch() public {
        // Send 7 messages (more than MAX_MESSAGES_PER_EPOCH = 5)
        vm.deal(donor1, 1 ether);
        for (uint256 i = 0; i < 7; i++) {
            vm.prank(donor1);
            fund.donateWithMessage{value: 0.01 ether}(0, "msg");
        }
        assertEq(fund.messageCount(), 7);

        // Execute epoch — should only advance by 5
        bytes memory noopAction = bytes(hex"00");
        fund.submitEpochAction(noopAction, "reasoning", -1, "");
        fund.syncPhase();

        assertEq(fund.messageHead(), 5);

        // 2 unread messages remain
        (address[] memory senders,,,) = fund.getUnreadMessages();
        assertEq(senders.length, 2);
    }

    function test_unread_messages_bounded_by_max() public {
        // Send 10 messages
        vm.deal(donor1, 10 ether);
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(donor1);
            fund.donateWithMessage{value: 0.01 ether}(0, "msg");
        }

        // getUnreadMessages returns at most MAX_MESSAGES_PER_EPOCH
        (address[] memory senders,,,) = fund.getUnreadMessages();
        assertEq(senders.length, 5);
    }

    function test_multiple_epochs_drain_queue() public {
        // Send 7 messages
        vm.deal(donor1, 1 ether);
        for (uint256 i = 0; i < 7; i++) {
            vm.prank(donor1);
            fund.donateWithMessage{value: 0.01 ether}(0, "msg");
        }

        // Epoch 1: advances head to 5
        bytes memory noopAction = bytes(hex"00");
        fund.submitEpochAction(noopAction, "reasoning", -1, "");
        fund.syncPhase();
        assertEq(fund.messageHead(), 5);

        // Epoch 2: advances head to 7
        fund.submitEpochAction(noopAction, "reasoning", -1, "");
        fund.syncPhase();
        assertEq(fund.messageHead(), 7);

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
        // Run epoch 1 with no donor messages, then queue a message and
        // run epoch 2 — the two frozen snapshot hashes must differ,
        // proving the messages sub-hash is bound into _hashSnapshot.
        //
        // The new _hashSnapshot is `pure` — mid-epoch donations don't
        // affect the already-frozen snapshot. Coverage is verified
        // across a fresh epoch whose snapshot captures the new message.
        fund.submitEpochAction(
            abi.encodePacked(uint8(0)), "Epoch with no messages", int8(-1), ""
        );
        fund.syncPhase();
        bytes32 hashNoMessages = fund.computeInputHashForEpoch(1);

        vm.deal(donor1, 1 ether);
        vm.prank(donor1);
        fund.donateWithMessage{value: 0.01 ether}(0, "Changes the hash");

        // Advance to epoch 2 so submitEpochAction targets a fresh epoch.
        vm.warp(fund.epochStartTime(2) + 1);
        fund.syncPhase();

        fund.submitEpochAction(
            abi.encodePacked(uint8(0)), "Epoch with a message", int8(-1), ""
        );
        bytes32 hashWithMessage = fund.computeInputHashForEpoch(2);

        assertTrue(hashNoMessages != hashWithMessage);
    }

    // ─── Regular donate still works without message ──────────────────────

    // ─── Message Queue Preservation Across Failed/Missed Epochs ─────────
    //
    // messageHead only advances inside _recordAndExecute (successful submission),
    // NOT on failed auctions or missed epochs. These tests lock in that behavior:
    // messages are never dropped, they just wait for the next successful epoch.

    /// @dev Miss an epoch via the on-chain wall-clock path: open an auction,
    ///      warp past its deadline, let syncPhase drain to SETTLED + advance.
    ///      Uses absolute-time warp because Forge caches `block.timestamp`
    ///      within a test frame after vm.warp.
    function _missEpoch() internal {
        fund.syncPhase();
        uint256 targetEpoch = fund.currentEpoch() + 1;
        vm.warp(fund.epochStartTime(targetEpoch) + 1);
        fund.syncPhase();
    }

    function test_message_survives_missed_epoch() public {
        // Send a message in epoch 1
        vm.deal(donor1, 1 ether);
        vm.prank(donor1);
        fund.donateWithMessage{value: 0.01 ether}(0, "waiting in line");
        assertEq(fund.messageCount(), 1);
        assertEq(fund.messageHead(), 0);

        // "Miss" epoch 1 by timing out the auction (no reveal, no submission).
        // The wall-clock path must not advance messageHead.
        _missEpoch();
        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.messageHead(), 0, "messageHead should NOT advance on missed epoch");

        // Message is still unread
        (address[] memory senders,,,) = fund.getUnreadMessages();
        assertEq(senders.length, 1);
        assertEq(senders[0], donor1);

        // Now epoch 2 executes successfully — head advances
        bytes memory noopAction = bytes(hex"00");
        fund.submitEpochAction(noopAction, "reasoning", -1, "");
        assertEq(fund.messageHead(), 1, "messageHead advances after successful epoch");

        (senders,,,) = fund.getUnreadMessages();
        assertEq(senders.length, 0, "no unread messages after successful epoch");
    }

    function test_message_survives_many_missed_epochs() public {
        // Send a message
        vm.deal(donor1, 1 ether);
        vm.prank(donor1);
        fund.donateWithMessage{value: 0.01 ether}(0, "patient donor");
        assertEq(fund.messageCount(), 1);

        // Miss 5 epochs in a row — message should still be in the queue
        for (uint256 i = 0; i < 5; i++) {
            _missEpoch();
        }
        assertEq(fund.currentEpoch(), 6);
        assertEq(fund.messageHead(), 0, "messageHead preserved across 5 missed epochs");

        // Send another message between missed epochs
        vm.prank(donor1);
        fund.donateWithMessage{value: 0.01 ether}(0, "late arrival");
        assertEq(fund.messageCount(), 2);

        // Epoch 6 executes — both messages should be visible to the TEE
        (address[] memory senders,,, uint256[] memory epochs) = fund.getUnreadMessages();
        assertEq(senders.length, 2);
        assertEq(epochs[0], 1, "first message tagged with epoch 1 (when sent)");
        assertEq(epochs[1], 6, "second message tagged with epoch 6 (when sent)");

        bytes memory noopAction = bytes(hex"00");
        fund.submitEpochAction(noopAction, "reasoning", -1, "");
        assertEq(fund.messageHead(), 2, "both messages consumed after successful epoch");
    }

    function test_regular_donate_no_message() public {
        vm.deal(donor1, 1 ether);
        vm.prank(donor1);
        fund.donate{value: 0.001 ether}(0);

        assertEq(fund.messageCount(), 0);
        assertEq(fund.treasuryBalance(), 5.001 ether);
    }

    // ─── Fuzz Tests ────────────────────────────────────────────────────

    function testFuzz_messageLength(uint256 len) public {
        len = bound(len, 1, 1000);

        // Build a string of length `len`
        bytes memory msgBytes = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            msgBytes[i] = bytes1(uint8(65 + (i % 26))); // A-Z repeating
        }
        string memory msg_ = string(msgBytes);

        vm.deal(donor1, 1 ether);
        if (len > 280) {
            vm.prank(donor1);
            vm.expectRevert(TheHumanFund.InvalidParams.selector);
            fund.donateWithMessage{value: 0.01 ether}(0, msg_);
        } else {
            vm.prank(donor1);
            fund.donateWithMessage{value: 0.01 ether}(0, msg_);
            (,, string[] memory texts,) = fund.getUnreadMessages();
            assertEq(texts.length, 1);
            assertEq(bytes(texts[0]).length, len);
        }
    }

    function testFuzz_messageDonation_belowMinimum_reverts(uint256 amount) public {
        amount = bound(amount, 0.001 ether, 0.01 ether - 1);
        vm.deal(donor1, amount);
        vm.prank(donor1);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.donateWithMessage{value: amount}(0, "Hello");
    }

    function testFuzz_messageDonation_validAmount(uint256 amount) public {
        amount = bound(amount, 0.01 ether, 1 ether);
        vm.deal(donor1, amount);
        vm.prank(donor1);
        fund.donateWithMessage{value: amount}(0, "Fuzz test");

        assertEq(fund.messageCount(), 1);
        assertEq(fund.treasuryBalance(), 5 ether + amount);
    }

    /// @dev Regression for the CEI ordering fix: even if a referrer's
    ///      fallback calls `fund.syncPhase()` mid-commission (which can
    ///      reset per-epoch counters if wall-clock crossed the boundary),
    ///      the donation's MESSAGE must still land in the queue. Per-epoch
    ///      inflow accounting is allowed to drift in this pathological
    ///      case — the user-visible guarantee is that the message is
    ///      preserved and the model will see it in the next snapshot.
    function test_referrer_reentry_preserves_message() public {
        // Deploy a malicious referrer that syncs phase on receive.
        ReentrantReferrer bad = new ReentrantReferrer(address(fund));
        vm.prank(address(bad));
        uint256 codeId = fund.mintReferralCode();

        // Start epoch 1 and warp past its scheduled end so a mid-call
        // syncPhase from the referrer would advance the epoch.
        fund.syncPhase();
        uint256 epochDuration = fund.epochDuration();
        vm.warp(block.timestamp + 3 * epochDuration);

        // Donor sends a referred donation. Because _payCommission runs
        // LAST (after messages.push), the message is already in the queue
        // when the referrer's reentrant syncPhase snapshots state.
        vm.deal(donor1, 1 ether);
        vm.prank(donor1);
        fund.donateWithMessage{value: 0.1 ether}(codeId, "referral donation");

        // Message must be persisted and readable.
        assertEq(fund.messageCount(), 1, "message persisted");
        (,,string[] memory texts,) = fund.getUnreadMessages();
        assertEq(texts[0], "referral donation");
    }
}
