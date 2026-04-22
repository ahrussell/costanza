// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
import "./helpers/MockEndaoment.sol";
import "./helpers/EpochTest.sol";

contract TheHumanFundTest is EpochTest {
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

        DonationExecutor donExec = new DonationExecutor(
            address(mockFactory), address(mockWeth), address(mockUsdc),
            address(mockRouter), address(mockFeed)
        );
        fund = new TheHumanFund{value: 5 ether}(
            1000,                       // 10% commission
            0.005 ether,                // initial max bid
            address(donExec),
            address(mockFeed)
        );

        fund.addNonprofit("GiveDirectly", "Cash transfers to extreme poor", bytes32("EIN-GD"));
        fund.addNonprofit("Against Malaria Foundation", "Malaria prevention", bytes32("EIN-AMF"));
        fund.addNonprofit("Helen Keller International", "Neglected tropical diseases", bytes32("EIN-HKI"));

        // Pre-deploy mock Endaoment orgs so donations work
        mockFactory.preDeployOrg(bytes32("EIN-GD"));
        mockFactory.preDeployOrg(bytes32("EIN-AMF"));
        mockFactory.preDeployOrg(bytes32("EIN-HKI"));

        // Deploy AuctionManager; setAuctionManager eagerly opens epoch 1's
        // auction so every test enters with phase=COMMIT of epoch 1.
        AuctionManager am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am), 1200, 1200, 82800); // 20m / 20m / 23h = 24h
        _registerMockVerifier(fund);
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
        new TheHumanFund{value: 1 ether}(50, 0.005 ether, address(0xBEEF), address(0)); // 0.5% — too low

        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        new TheHumanFund{value: 1 ether}(9500, 0.005 ether, address(0xBEEF), address(0)); // 95% — too high
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

    // ─── Epoch: do_nothing ───────────────────────────────────────────────

    function test_do_nothing_action() public {
        bytes memory action = abi.encodePacked(uint8(0));
        bytes memory reasoning = bytes("I decided to do nothing this epoch.");

        speedrunEpoch(fund, action, reasoning);

        assertEq(fund.currentEpoch(), 2);
        // Treasury loses 1 wei (minimum auction bounty paid to runner).
        assertEq(fund.treasuryBalance(), 5 ether - 1);
    }

    // ─── Epoch: Donate ───────────────────────────────────────────────────

    function test_donate_action() public {
        // Donate 0.49 ETH to nonprofit 1. Must be under 10% of treasury
        // at execution time (5 ETH - 1 wei bounty = ~4.999... ETH).
        uint256 donateAmount = 0.49 ether;
        bytes memory action = abi.encodePacked(uint8(1), abi.encode(uint256(1), donateAmount));
        bytes memory reasoning = bytes("Donating to GiveDirectly.");

        speedrunEpoch(fund, action, reasoning);

        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.treasuryBalance(), 5 ether - 1 - donateAmount); // -1 wei bounty

        (, , , uint256 totalDonated,, uint256 donationCount) = fund.getNonprofit(1);
        assertEq(totalDonated, donateAmount);
        assertEq(donationCount, 1);
        assertEq(fund.lastDonationEpoch(), 1);
    }

    function test_donate_out_of_bounds_becomes_do_nothing() public {
        // Try to donate 0.6 ETH (12% of 5 ETH) — should become do_nothing, not revert
        bytes memory action = abi.encodePacked(uint8(1), abi.encode(uint256(1), uint256(0.6 ether)));
        bytes memory reasoning = bytes("Trying to donate too much.");

        uint256 treasuryBefore = fund.treasuryBalance();
        speedrunEpoch(fund, action, reasoning);

        // Epoch advances; treasury loses only the 1 wei bounty (action was do_nothing)
        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.treasuryBalance(), treasuryBefore - 1);
        assertEq(fund.lastDonationEpoch(), 0); // Never donated
    }

    function test_donate_invalid_nonprofit_becomes_do_nothing() public {
        bytes memory action = abi.encodePacked(uint8(1), abi.encode(uint256(4), uint256(0.1 ether)));
        bytes memory reasoning = bytes("Bad nonprofit.");

        uint256 treasuryBefore = fund.treasuryBalance();
        speedrunEpoch(fund, action, reasoning);

        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.treasuryBalance(), treasuryBefore - 1); // -1 wei bounty
    }

    // ─── Epoch: Set Commission Rate ──────────────────────────────────────

    function test_set_commission_rate() public {
        bytes memory action = abi.encodePacked(uint8(2), abi.encode(uint256(2500)));
        bytes memory reasoning = bytes("Raising commission to attract referrers.");

        speedrunEpoch(fund, action, reasoning);

        assertEq(fund.commissionRateBps(), 2500);
        assertEq(fund.lastCommissionChangeEpoch(), 1);
    }

    function test_set_commission_rate_out_of_bounds_becomes_do_nothing() public {
        uint256 originalRate = fund.commissionRateBps();

        // Too low — should become do_nothing
        bytes memory action = abi.encodePacked(uint8(2), abi.encode(uint256(50)));
        speedrunEpoch(fund, action, bytes("rate too low"));
        assertEq(fund.commissionRateBps(), originalRate);
        assertEq(fund.currentEpoch(), 2);

        // Too high — should become do_nothing
        action = abi.encodePacked(uint8(2), abi.encode(uint256(9500)));
        speedrunEpoch(fund, action, bytes("rate too high"));
        assertEq(fund.commissionRateBps(), originalRate);
        assertEq(fund.currentEpoch(), 3);
    }

    // ─── Epoch: Sequencing ───────────────────────────────────────────────

    function test_epoch_advances_prevents_double_execution() public {
        bytes memory action = abi.encodePacked(uint8(0));
        speedrunEpoch(fund, action, bytes("first"));

        // After execution, epoch advances (1 → 2), so the next call acts on epoch 2.
        // The contract prevents double-execution by design: each epoch action
        // increments currentEpoch, so you're always acting on a fresh epoch.
        assertEq(fund.currentEpoch(), 2);

        // Epoch 1 is recorded as executed
        (,,,,,,bool executed) = fund.getEpochRecord(1);
        assertTrue(executed);
    }

    function test_epoch_advances() public {
        bytes memory action = abi.encodePacked(uint8(0));

        speedrunEpoch(fund, action, bytes("epoch 1")); // epoch 1 → 2
        speedrunEpoch(fund, action, bytes("epoch 2")); // epoch 2 → 3
        speedrunEpoch(fund, action, bytes("epoch 3")); // epoch 3 → 4

        assertEq(fund.currentEpoch(), 4);
    }

    // ─── Epoch: Miss & Auto-Escalation ───────────────────────────────────

    /// @dev Simulate a missed epoch by warping past the current epoch's
    ///      execution deadline and letting syncPhase fast-forward. The
    ///      auction is always open from setUp (or from the prior epoch's
    ///      close-and-open cycle).
    ///      NOTE: Forge caches `block.timestamp` within a single test frame
    ///      after `vm.warp`, so we must warp to an absolute target read from
    ///      the contract rather than `block.timestamp + X`.
    function _missEpoch() internal {
        uint256 targetEpoch = fund.currentEpoch() + 1;
        vm.warp(fund.epochStartTime(targetEpoch) + 1); // 1s into next epoch
        fund.syncPhase(); // close-execution + advance + open next; credits missed
    }

    function test_missed_epoch_advances_and_credits() public {
        _missEpoch();
        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.consecutiveMissedEpochs(), 1);
    }

    function test_auto_escalation() public {
        // Initial max bid is 0.005 ETH
        assertEq(fund.effectiveMaxBid(), 0.005 ether);

        // Miss 3 epochs
        _missEpoch(); // +10% → 0.0055
        _missEpoch(); // +10% → 0.00605
        _missEpoch(); // +10% → 0.006655

        uint256 effective = fund.effectiveMaxBid();
        // 0.005 * 1.1^3 = 0.006655
        assertEq(effective, 0.006655 ether);

        // Execute an epoch — resets escalation
        bytes memory action = abi.encodePacked(uint8(0));
        speedrunEpoch(fund, action, bytes("back online"));

        assertEq(fund.effectiveMaxBid(), 0.005 ether);
        assertEq(fund.consecutiveMissedEpochs(), 0);
    }

    // ─── Epoch: Diary Entry Event ────────────────────────────────────────

    function test_diary_entry_emitted() public {
        bytes memory action = abi.encodePacked(uint8(0));
        bytes memory reasoning = bytes("Testing diary emission.");

        vm.recordLogs();
        speedrunEpoch(fund, action, reasoning);

        // DiaryEntry is emitted among other auction events. Find it.
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 diaryTopic = keccak256("DiaryEntry(uint256,bytes,bytes,uint256,uint256)");
        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == diaryTopic) {
                assertEq(entries[i].topics[1], bytes32(uint256(1)), "epoch 1");
                found = true;
                break;
            }
        }
        assertTrue(found, "DiaryEntry event must be emitted");
    }

    // ─── Multi-epoch Donation Tracking ───────────────────────────────────

    function test_multiple_donations_across_epochs() public {
        // Epoch 1: donate to np1
        bytes memory action1 = abi.encodePacked(uint8(1), abi.encode(uint256(1), uint256(0.3 ether)));
        speedrunEpoch(fund, action1, bytes("donate 1"));

        // Epoch 2: donate to np2
        bytes memory action2 = abi.encodePacked(uint8(1), abi.encode(uint256(2), uint256(0.2 ether)));
        speedrunEpoch(fund, action2, bytes("donate 2"));

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

        speedrunEpoch(fund, action, reasoning);

        // epochContentHash should be set for epoch 1
        bytes32 contentHash = fund.epochContentHashes(1);
        assertTrue(contentHash != bytes32(0));

        // Verify it matches the expected formula. _recordAndExecute
        // captures treasuryBefore AFTER the bounty is paid (1 wei).
        (, , , uint256 tBefore, uint256 tAfter, uint256 bounty,) = fund.getEpochRecord(1);
        bytes32 expected = keccak256(abi.encode(
            keccak256(reasoning), keccak256(action), tBefore, tAfter, bounty
        ));
        assertEq(contentHash, expected);
    }

    function test_epoch_content_hash_included_in_input_hash() public {
        // Run two epochs and verify that their frozen snapshot hashes
        // differ — proving the historyHash sub-hash (which rolls in
        // epochContentHashes) is bound into _hashSnapshot.
        speedrunEpoch(fund, abi.encodePacked(uint8(0)), bytes("reasoning 1"));
        bytes32 hash1 = fund.computeInputHashForEpoch(1);

        speedrunEpoch(fund, abi.encodePacked(uint8(0)), bytes("reasoning 2"));
        bytes32 hash2 = fund.computeInputHashForEpoch(2);

        // Epoch 2's snapshot differs from epoch 1's in at least:
        //   - snap.epoch (1 vs 2)
        //   - snap.historyHash (epoch 2 has one prior content hash to roll in)
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
        slots[0] = 1; // slot 0 is reserved; use slot 1
        policies[0] = "test";
        fund.seedWorldView(slots, policies);
    }

    function test_freezeAuctionConfig() public {
        fund.freeze(fund.FREEZE_AUCTION_CONFIG());

        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.resetAuction(3600, 1800, 7200);

        AuctionManager freshAm = new AuctionManager(address(fund));
        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.setAuctionManager(address(freshAm), 3600, 1800, 7200);
    }

    // test_freezePrompt removed — approvedPromptHash eliminated (dm-verity covers prompt)

    function test_freezeMigrate() public {
        fund.freeze(fund.FREEZE_MIGRATE());

        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.withdrawAll();

        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.migrate(address(0xBEEF));
    }

    // ─── Sunset / Migration ─────────────────────────────────────────────

    function test_sunset_blocksDonations() public {
        fund.freeze(fund.FREEZE_SUNSET());

        vm.deal(donor, 1 ether);
        vm.prank(donor);
        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.donate{value: 0.01 ether}(0);
    }

    function test_sunset_blocksDonationsWithMessage() public {
        fund.freeze(fund.FREEZE_SUNSET());

        vm.deal(donor, 1 ether);
        vm.prank(donor);
        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.donateWithMessage{value: 0.01 ether}(0, "hello");
    }

    function test_sunset_blocksReceive() public {
        fund.freeze(fund.FREEZE_SUNSET());

        uint256 balBefore = address(fund).balance;
        // receive() reverts, so low-level call returns false
        (bool sent,) = address(fund).call{value: 1 ether}("");
        assertFalse(sent, "receive should reject ETH after sunset");
        assertEq(address(fund).balance, balBefore);
    }

    function test_migrate_requiresSunset() public {
        // migrate without FREEZE_SUNSET should revert
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.migrate(address(0xBEEF));
    }

    function test_migrate_onlyOwner() public {
        fund.freeze(fund.FREEZE_SUNSET());

        vm.prank(donor);
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.migrate(address(0xBEEF));
    }

    function test_migrate_sendsToDestination() public {
        address destination = address(0xBEEF);
        uint256 fundBalance = address(fund).balance;

        fund.freeze(fund.FREEZE_SUNSET());
        fund.migrate(destination);

        assertEq(address(fund).balance, 0);
        assertEq(destination.balance, fundBalance);
    }

    function test_migrate_emitsSunsetEvent() public {
        address destination = address(0xBEEF);

        fund.freeze(fund.FREEZE_SUNSET());

        vm.expectEmit(true, false, false, false);
        emit TheHumanFund.Sunset(destination);
        fund.migrate(destination);
    }

    // ─── Ownership Transfer ────────────────────────────────────────────

    function test_transferOwnership() public {
        address newOwner = address(0xBEEF);
        fund.transferOwnership(newOwner);
        assertEq(fund.owner(), newOwner);
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(donor);
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.transferOwnership(address(0xBEEF));
    }

    function test_transferOwnership_rejectsZeroAddress() public {
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.transferOwnership(address(0));
    }

    function test_transferOwnership_frozenByMigrate() public {
        fund.freeze(fund.FREEZE_MIGRATE());
        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.transferOwnership(address(0xBEEF));
    }

    function test_transferOwnership_emitsEvent() public {
        address newOwner = address(0xBEEF);
        vm.expectEmit(true, false, false, false);
        emit TheHumanFund.OwnershipTransferred(newOwner);
        fund.transferOwnership(newOwner);
    }

    function test_transferOwnership_newOwnerCanAct() public {
        address newOwner = address(0xBEEF);
        fund.transferOwnership(newOwner);

        // Old owner can no longer act (any onlyOwner function will do)
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.approveVerifier(2, address(0xCAFE));

        // New owner can act
        vm.prank(newOwner);
        fund.approveVerifier(2, address(0xCAFE));
    }

    // ─── Fuzz Tests ────────────────────────────────────────────────────

    function testFuzz_donate_validAmount(uint256 amount) public {
        amount = bound(amount, 0.001 ether, 10 ether);
        vm.deal(donor, amount);
        vm.prank(donor);
        fund.donate{value: amount}(0);
        assertEq(fund.treasuryBalance(), 5 ether + amount);
    }

    function testFuzz_donate_belowMinimum_reverts(uint256 amount) public {
        amount = bound(amount, 1, 0.001 ether - 1);
        vm.deal(donor, amount);
        vm.prank(donor);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.donate{value: amount}(0);
    }

    function testFuzz_commissionRate_validRange(uint256 rate) public {
        rate = bound(rate, 100, 9000);
        bytes memory action = abi.encodePacked(uint8(2), abi.encode(rate));
        speedrunEpoch(fund, action, bytes("Adjusting commission"));
        assertEq(fund.commissionRateBps(), rate);
    }

    function testFuzz_commissionRate_belowMin_rejected(uint256 rate) public {
        rate = bound(rate, 0, 99);
        bytes memory action = abi.encodePacked(uint8(2), abi.encode(rate));
        speedrunEpoch(fund, action, bytes("Bad rate"));
        // Commission rate unchanged
        assertEq(fund.commissionRateBps(), 1000);
    }

    function testFuzz_commissionRate_aboveMax_rejected(uint256 rate) public {
        rate = bound(rate, 9001, type(uint256).max);
        bytes memory action = abi.encodePacked(uint8(2), abi.encode(rate));
        speedrunEpoch(fund, action, bytes("Bad rate"));
        assertEq(fund.commissionRateBps(), 1000);
    }

    function testFuzz_donate_action_boundedByTreasury(uint256 amount) public {
        // Treasury is 5 ETH, max donation is 10% = 0.5 ETH
        uint256 treasury = address(fund).balance;
        uint256 maxDonation = (treasury * 1000) / 10000; // MAX_DONATION_BPS = 1000
        amount = bound(amount, maxDonation + 1, 100 ether);

        bytes memory action = abi.encodePacked(uint8(1), abi.encode(uint256(0), amount));
        // Should emit ActionRejected (amount exceeds 10% of treasury)
        speedrunEpoch(fund, action, bytes("Too generous"));
        // Fund balance loses only 1 wei bounty (action was rejected, not reverted)
        assertEq(address(fund).balance, treasury - 1);
    }

    function testFuzz_actionEncoding_malformedBytes_neverReverts(uint256 seed) public {
        // Generate random action bytes of varying lengths
        uint256 len = bound(seed, 0, 200);
        bytes memory action = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            action[i] = bytes1(uint8(uint256(keccak256(abi.encode(seed, i))) % 256));
        }
        // Should never revert — malformed actions emit ActionRejected or are a no-op
        speedrunEpoch(fund, action, bytes("fuzz"));
        // Treasury never decreases from malformed actions (except valid donate actions)
        // which are bounded, plus 1 wei bounty. Just verify no revert happened.
    }
}
