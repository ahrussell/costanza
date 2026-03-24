// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TheHumanFund.sol";
import "./helpers/MockEndaoment.sol";

contract TheHumanFundTest is Test {
    TheHumanFund public fund;
    MockEndaomentFactory public mockFactory;
    MockWETH public mockWeth;
    MockUSDC public mockUsdc;
    MockSwapRouter public mockRouter;
    MockChainlinkFeed public mockFeed;

    address donor = address(0x2001);
    address referrer = address(0x3001);

    function setUp() public {
        // Deploy mock DeFi infra
        mockWeth = new MockWETH();
        mockUsdc = new MockUSDC();
        mockRouter = new MockSwapRouter(address(mockWeth), address(mockUsdc));
        mockFactory = new MockEndaomentFactory();
        mockFeed = new MockChainlinkFeed(2000e8, 8);  // $2000/ETH, 8 decimals

        fund = new TheHumanFund{value: 5 ether}(
            1000,                       // 10% commission
            0.005 ether,                // initial max bid
            address(mockFactory),
            address(mockWeth),
            address(mockUsdc),
            address(mockRouter),
            address(mockFeed)
        );

        fund.addNonprofit("GiveDirectly", "Cash transfers to extreme poor", bytes32("EIN-GD"));
        fund.addNonprofit("Against Malaria Foundation", "Malaria prevention", bytes32("EIN-AMF"));
        fund.addNonprofit("Helen Keller International", "Neglected tropical diseases", bytes32("EIN-HKI"));

        // Pre-deploy mock Endaoment orgs so donations work
        mockFactory.preDeployOrg(bytes32("EIN-GD"));
        mockFactory.preDeployOrg(bytes32("EIN-AMF"));
        mockFactory.preDeployOrg(bytes32("EIN-HKI"));
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    function test_constructor_sets_initial_state() public view {
        assertEq(fund.currentEpoch(), 1);
        assertEq(fund.commissionRateBps(), 1000);
        assertEq(fund.maxBid(), 0.005 ether);
        assertEq(fund.treasuryBalance(), 5 ether);
        assertEq(fund.totalInflows(), 5 ether);

        (string memory name, string memory description, bytes32 ein, uint256 totalDonated, uint256 totalDonatedUsd, uint256 donationCount) = fund.getNonprofit(1);
        assertEq(name, "GiveDirectly");
        assertEq(description, "Cash transfers to extreme poor");
        assertEq(ein, bytes32("EIN-GD"));
        assertEq(totalDonated, 0);
        assertEq(totalDonatedUsd, 0);
        assertEq(donationCount, 0);
    }

    function test_constructor_rejects_invalid_commission() public {
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        new TheHumanFund{value: 1 ether}(50, 0.005 ether, address(0xBEEF), address(0xBEEF), address(0xBEEF), address(0xBEEF), address(0)); // 0.5% — too low

        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        new TheHumanFund{value: 1 ether}(9500, 0.005 ether, address(0xBEEF), address(0xBEEF), address(0xBEEF), address(0xBEEF), address(0)); // 95% — too high
    }

    function test_add_nonprofit_rejects_zero_ein() public {
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.addNonprofit("Bad Nonprofit", "No EIN", bytes32(0));
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

        // Commission = 10% of 1 ETH = 0.1 ETH (paid immediately)
        // Treasury = 5 seed + 1 donation - 0.1 commission = 5.9 ETH
        assertEq(fund.treasuryBalance(), 5.9 ether);
    }

    function test_donate_rejects_dust() public {
        vm.deal(donor, 1 ether);
        vm.prank(donor);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.donate{value: 0.0005 ether}(0);
    }

    // ─── Referral & Commissions ──────────────────────────────────────────

    function test_commission_paid_immediately() public {
        vm.prank(referrer);
        uint256 codeId = fund.mintReferralCode();

        uint256 balBefore = referrer.balance;
        vm.deal(donor, 1 ether);
        vm.prank(donor);
        fund.donate{value: 1 ether}(codeId);

        // Referrer should have received 0.1 ETH (10% of 1 ETH) immediately
        assertEq(referrer.balance - balBefore, 0.1 ether);
        assertEq(fund.totalCommissionsPaid(), 0.1 ether);
    }

    // ─── Epoch: Noop ─────────────────────────────────────────────────────

    function test_noop_action() public {
        bytes memory action = abi.encodePacked(uint8(0));
        bytes memory reasoning = bytes("I decided to do nothing this epoch.");

        fund.submitEpochAction(action, reasoning, -1, "");

        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.treasuryBalance(), 5 ether); // unchanged
    }

    // ─── Epoch: Donate ───────────────────────────────────────────────────

    function test_donate_action() public {
        // Donate 0.5 ETH (10% of 5 ETH) to nonprofit 1
        bytes memory action = abi.encodePacked(uint8(1), abi.encode(uint256(1), uint256(0.5 ether)));
        bytes memory reasoning = bytes("Donating to GiveDirectly.");

        fund.submitEpochAction(action, reasoning, -1, "");

        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.treasuryBalance(), 4.5 ether);

        (, , , uint256 totalDonated,, uint256 donationCount) = fund.getNonprofit(1);
        assertEq(totalDonated, 0.5 ether);
        assertEq(donationCount, 1);
        assertEq(fund.lastDonationEpoch(), 1);
    }

    function test_donate_out_of_bounds_becomes_noop() public {
        // Try to donate 0.6 ETH (12% of 5 ETH) — should noop, not revert
        bytes memory action = abi.encodePacked(uint8(1), abi.encode(uint256(1), uint256(0.6 ether)));
        bytes memory reasoning = bytes("Trying to donate too much.");

        uint256 treasuryBefore = fund.treasuryBalance();
        fund.submitEpochAction(action, reasoning, -1, "");

        // Epoch advances but treasury unchanged (noop)
        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.treasuryBalance(), treasuryBefore);
        assertEq(fund.lastDonationEpoch(), 0); // Never donated
    }

    function test_donate_invalid_nonprofit_becomes_noop() public {
        bytes memory action = abi.encodePacked(uint8(1), abi.encode(uint256(4), uint256(0.1 ether)));
        bytes memory reasoning = bytes("Bad nonprofit.");

        uint256 treasuryBefore = fund.treasuryBalance();
        fund.submitEpochAction(action, reasoning, -1, "");

        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.treasuryBalance(), treasuryBefore);
    }

    // ─── Epoch: Set Commission Rate ──────────────────────────────────────

    function test_set_commission_rate() public {
        bytes memory action = abi.encodePacked(uint8(2), abi.encode(uint256(2500)));
        bytes memory reasoning = bytes("Raising commission to attract referrers.");

        fund.submitEpochAction(action, reasoning, -1, "");

        assertEq(fund.commissionRateBps(), 2500);
        assertEq(fund.lastCommissionChangeEpoch(), 1);
    }

    function test_set_commission_rate_out_of_bounds_becomes_noop() public {
        uint256 originalRate = fund.commissionRateBps();

        // Too low — should noop
        bytes memory action = abi.encodePacked(uint8(2), abi.encode(uint256(50)));
        fund.submitEpochAction(action, bytes("rate too low"), -1, "");
        assertEq(fund.commissionRateBps(), originalRate);
        assertEq(fund.currentEpoch(), 2);

        // Too high — should noop
        action = abi.encodePacked(uint8(2), abi.encode(uint256(9500)));
        fund.submitEpochAction(action, bytes("rate too high"), -1, "");
        assertEq(fund.commissionRateBps(), originalRate);
        assertEq(fund.currentEpoch(), 3);
    }

    // ─── Epoch: Set Max Bid ──────────────────────────────────────────────

    function test_set_max_bid() public {
        bytes memory action = abi.encodePacked(uint8(3), abi.encode(uint256(0.01 ether)));
        bytes memory reasoning = bytes("Increasing bid ceiling.");

        fund.submitEpochAction(action, reasoning, -1, "");

        assertEq(fund.maxBid(), 0.01 ether);
    }

    function test_set_max_bid_too_low_becomes_noop() public {
        uint256 originalBid = fund.maxBid();
        bytes memory action = abi.encodePacked(uint8(3), abi.encode(uint256(0.00005 ether)));
        fund.submitEpochAction(action, bytes("bid too low"), -1, "");

        assertEq(fund.maxBid(), originalBid);
        assertEq(fund.currentEpoch(), 2);
    }

    function test_set_max_bid_over_2_percent_becomes_noop() public {
        // 2% of 5 ETH = 0.1 ETH. Try 0.15 ETH — should noop.
        uint256 originalBid = fund.maxBid();
        bytes memory action = abi.encodePacked(uint8(3), abi.encode(uint256(0.15 ether)));
        fund.submitEpochAction(action, bytes("bid too high"), -1, "");

        assertEq(fund.maxBid(), originalBid);
        assertEq(fund.currentEpoch(), 2);
    }

    // ─── Epoch: Sequencing ───────────────────────────────────────────────

    function test_epoch_advances_prevents_double_execution() public {
        bytes memory action = abi.encodePacked(uint8(0));
        fund.submitEpochAction(action, bytes("first"), -1, "");

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

        fund.submitEpochAction(action, bytes("epoch 1"), -1, ""); // epoch 1 → 2
        fund.submitEpochAction(action, bytes("epoch 2"), -1, ""); // epoch 2 → 3
        fund.submitEpochAction(action, bytes("epoch 3"), -1, ""); // epoch 3 → 4

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
        fund.submitEpochAction(action, bytes("back online"), -1, "");

        assertEq(fund.effectiveMaxBid(), 0.005 ether);
        assertEq(fund.consecutiveMissedEpochs(), 0);
    }

    // ─── Epoch: Diary Entry Event ────────────────────────────────────────

    function test_diary_entry_emitted() public {
        bytes memory action = abi.encodePacked(uint8(0));
        bytes memory reasoning = bytes("Testing diary emission.");

        vm.expectEmit(true, false, false, true);
        emit TheHumanFund.DiaryEntry(1, reasoning, action, 5 ether, 5 ether);

        fund.submitEpochAction(action, reasoning, -1, "");
    }

    // ─── Auth ────────────────────────────────────────────────────────────

    function test_only_owner_can_submit() public {
        bytes memory action = abi.encodePacked(uint8(0));

        vm.prank(donor);
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.submitEpochAction(action, bytes("unauthorized"), -1, "");
    }

    function test_only_owner_can_skip() public {
        vm.prank(donor);
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.skipEpoch();
    }

    // ─── Multi-epoch Donation Tracking ───────────────────────────────────

    function test_multiple_donations_across_epochs() public {
        // Epoch 1: donate to np1
        bytes memory action1 = abi.encodePacked(uint8(1), abi.encode(uint256(1), uint256(0.3 ether)));
        fund.submitEpochAction(action1, bytes("donate 1"), -1, "");

        // Epoch 2: donate to np2
        bytes memory action2 = abi.encodePacked(uint8(1), abi.encode(uint256(2), uint256(0.2 ether)));
        fund.submitEpochAction(action2, bytes("donate 2"), -1, "");

        // Check totals
        (, , , uint256 donated1,,) = fund.getNonprofit(1);
        (, , , uint256 donated2,,) = fund.getNonprofit(2);
        assertEq(donated1, 0.3 ether);
        assertEq(donated2, 0.2 ether);
        assertEq(fund.totalDonatedToNonprofits(), 0.5 ether);
        assertEq(fund.lastDonationEpoch(), 2);
    }

    // ─── Epoch Content Hashes ───────────────────────────────────────────────

    function test_epoch_content_hash_stored_on_submit() public {
        bytes memory action = abi.encodePacked(uint8(0));
        bytes memory reasoning = bytes("First epoch thoughts.");

        uint256 treasuryBefore = address(fund).balance;
        fund.submitEpochAction(action, reasoning, -1, "");

        // epochContentHash should be set for epoch 1
        bytes32 contentHash = fund.epochContentHashes(1);
        assertTrue(contentHash != bytes32(0));

        // Verify it matches the expected formula
        bytes32 expected = keccak256(abi.encode(
            keccak256(reasoning), keccak256(action), treasuryBefore, treasuryBefore // noop: before == after
        ));
        assertEq(contentHash, expected);
    }

    function test_epoch_content_hash_included_in_input_hash() public {
        bytes32 hash1 = fund.computeInputHash();

        // Submit epoch (creates epochContentHash + advances epoch)
        fund.submitEpochAction(abi.encodePacked(uint8(0)), bytes("reasoning"), -1, "");

        bytes32 hash2 = fund.computeInputHash();

        // Input hash should differ (history changed + epoch number changed)
        assertTrue(hash1 != hash2);
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

    // ─── Kill Switches ────────────────────────────────────────────────────

    function test_freezeNonprofits() public {
        fund.freeze(fund.FREEZE_NONPROFITS());
        assertTrue(fund.frozenFlags() & fund.FREEZE_NONPROFITS() != 0);

        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.addNonprofit("New NP", "Test", bytes32("EIN-NEW"));
    }

    function test_freeze_onlyOwner() public {
        uint256 flag = fund.FREEZE_NONPROFITS();
        vm.prank(address(0xDEAD));
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.freeze(flag);
    }

    function test_freeze_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit TheHumanFund.PermissionFrozen(fund.FREEZE_NONPROFITS());
        fund.freeze(fund.FREEZE_NONPROFITS());
    }

    function test_freeze_idempotent() public {
        fund.freeze(fund.FREEZE_NONPROFITS());
        fund.freeze(fund.FREEZE_NONPROFITS()); // should not revert
        assertTrue(fund.frozenFlags() & fund.FREEZE_NONPROFITS() != 0);
    }

    function test_freezeDirectMode() public {
        // Submit works before freeze
        bytes memory noop = abi.encodePacked(uint8(0));
        fund.submitEpochAction(noop, "ok", -1, "");

        fund.freeze(fund.FREEZE_DIRECT_MODE());

        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.submitEpochAction(noop, "frozen", -1, "");

        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.skipEpoch();
    }

    function test_freezeVerifiers() public {
        fund.approveVerifier(1, address(0x1234));
        fund.freeze(fund.FREEZE_VERIFIERS());

        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.approveVerifier(2, address(0x5678));

        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.revokeVerifier(1);
    }

    function test_freezeInvestmentWiring() public {
        fund.freeze(fund.FREEZE_INVESTMENT_WIRING());

        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.setInvestmentManager(address(0x1234));
    }

    function test_freezeWorldViewWiring() public {
        fund.freeze(fund.FREEZE_WORLDVIEW_WIRING());

        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.setWorldView(address(0x1234));

        vm.expectRevert(TheHumanFund.Frozen.selector);
        uint256[] memory slots = new uint256[](1);
        string[] memory policies = new string[](1);
        slots[0] = 0;
        policies[0] = "test";
        fund.seedWorldView(slots, policies);
    }

    function test_freezeAuctionConfig() public {
        fund.freeze(fund.FREEZE_AUCTION_CONFIG());

        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.setAuctionEnabled(true);

        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.setAuctionTiming(86400, 3600, 1800, 7200);
    }

    function test_freezePrompt() public {
        fund.freeze(fund.FREEZE_PROMPT());

        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.setApprovedPromptHash(bytes32("hash"));
    }

    function test_freezeEmergencyWithdrawal() public {
        fund.freeze(fund.FREEZE_EMERGENCY_WITHDRAWAL());

        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.withdrawAll();
    }
}
