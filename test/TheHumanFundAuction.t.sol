// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TheHumanFund.sol";
import "../src/TdxVerifier.sol";
import "../src/interfaces/IAutomataDcapAttestation.sol";

/// @dev Mock DCAP verifier for auction integration tests
contract AuctionMockDcapVerifier is IAutomataDcapAttestation {
    bool public shouldSucceed = true;
    bytes public craftedOutput;

    function setOutput(bytes memory _output) external { craftedOutput = _output; }
    function setShouldSucceed(bool _succeed) external { shouldSucceed = _succeed; }
    function verifyAndAttestOnChain(bytes calldata) external payable returns (bool, bytes memory) {
        return (shouldSucceed, craftedOutput);
    }
}

/// @title Auction mechanism tests for The Human Fund (Phase 2)
contract TheHumanFundAuctionTest is Test {
    TheHumanFund public fund;
    TdxVerifier public verifier;
    AuctionMockDcapVerifier public mockDcap;

    address payable np1 = payable(address(0x1001));
    address payable np2 = payable(address(0x1002));
    address payable np3 = payable(address(0x1003));

    address runner1 = address(0x4001);
    address runner2 = address(0x4002);
    address runner3 = address(0x4003);

    // Short testnet timing
    uint256 constant EPOCH_DUR = 300;    // 5 minutes
    uint256 constant BID_WIN = 60;       // 1 minute bidding
    uint256 constant EXEC_WIN = 120;     // 2 minutes execution

    // Test measurement values for mock attestation (48 bytes = 96 hex chars each, SHA-384)
    bytes constant TEST_MRTD = hex"aabbccdd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000011";
    bytes constant TEST_RTMR0 = hex"111111110000000000000000000000000000000000000000000000000000000000000000000000000000000000000022";
    bytes constant TEST_RTMR1 = hex"222222220000000000000000000000000000000000000000000000000000000000000000000000000000000000000033";
    bytes constant TEST_RTMR2 = hex"333333330000000000000000000000000000000000000000000000000000000000000000000000000000000000000044";

    function setUp() public {
        string[3] memory names = ["GiveDirectly", "Against Malaria Foundation", "Helen Keller International"];
        address payable[3] memory addrs = [np1, np2, np3];

        fund = new TheHumanFund{value: 10 ether}(
            names,
            addrs,
            1000,          // 10% commission
            0.01 ether     // initial max bid
        );

        // Deploy attestation verifier with mock DCAP
        mockDcap = new AuctionMockDcapVerifier();
        verifier = new TdxVerifier();

        // Etch mock DCAP verifier at the hardcoded address
        vm.etch(address(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F), address(mockDcap).code);

        // Approve the test image
        bytes32 imageKey = keccak256(abi.encodePacked(TEST_RTMR1, TEST_RTMR2));
        verifier.approveImage(imageKey);

        // Link verifier to fund
        fund.approveVerifier(1, address(verifier));

        // Configure short auction timing and enable
        fund.setAuctionTiming(EPOCH_DUR, BID_WIN, EXEC_WIN);
        fund.setAuctionEnabled(true);

        // Fund runners with ETH for bonds
        vm.deal(runner1, 10 ether);
        vm.deal(runner2, 10 ether);
        vm.deal(runner3, 10 ether);
    }

    // ─── Helper ───────────────────────────────────────────────────────────

    function _noopAction() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0));
    }

    function _mockAttestation() internal pure returns (bytes memory) {
        // Dummy attestation — DCAP verifier isn't deployed in tests
        return bytes("mock_attestation");
    }

    /// @dev Helper to run a full auction lifecycle (start, bid, close, submit)
    ///      Since DCAP_VERIFIER isn't deployed, we can't test submitAuctionResult
    ///      in the standard setUp. Use this only when testing non-attestation paths.

    // ─── Auction: Full Lifecycle ──────────────────────────────────────────

    function test_auction_start_epoch() public {
        fund.startEpoch();

        (uint256 startTime, TheHumanFund.EpochPhase phase, uint256 bidCount,
         address winner, uint256 winningBid,,) = fund.getAuctionState(1);

        assertEq(startTime, block.timestamp);
        assertEq(uint256(phase), uint256(TheHumanFund.EpochPhase.BIDDING));
        assertEq(bidCount, 0);
        assertEq(winner, address(0));
        assertEq(winningBid, 0);
    }

    function test_auction_single_bidder() public {
        fund.startEpoch();

        // Runner1 bids 0.005 ETH, bond = 20% = 0.001 ETH
        vm.prank(runner1);
        fund.bid{value: 0.001 ether}(0.005 ether);

        (, , uint256 bidCount, address winner, uint256 winningBid,,) = fund.getAuctionState(1);
        assertEq(bidCount, 1);
        assertEq(winner, runner1);
        assertEq(winningBid, 0.005 ether);
    }

    function test_auction_lowest_bid_wins() public {
        fund.startEpoch();

        // Runner1 bids 0.008 ETH (bond = 0.0016)
        vm.prank(runner1);
        fund.bid{value: 0.0016 ether}(0.008 ether);

        // Runner2 bids 0.005 ETH (bond = 0.001) — should become leader
        vm.prank(runner2);
        fund.bid{value: 0.001 ether}(0.005 ether);

        // Runner3 bids 0.009 ETH (bond = 0.0018) — higher, stays runner2
        vm.prank(runner3);
        fund.bid{value: 0.0018 ether}(0.009 ether);

        (, , uint256 bidCount, address winner, uint256 winningBid,,) = fund.getAuctionState(1);
        assertEq(bidCount, 3);
        assertEq(winner, runner2);
        assertEq(winningBid, 0.005 ether);
    }

    function test_auction_outbid_refunds_previous_leader() public {
        fund.startEpoch();

        uint256 runner1BalBefore = runner1.balance;

        // Runner1 bids 0.008 ETH (bond = 0.0016)
        vm.prank(runner1);
        fund.bid{value: 0.0016 ether}(0.008 ether);

        assertEq(runner1.balance, runner1BalBefore - 0.0016 ether);

        // Runner2 bids lower — runner1 should get bond back
        vm.prank(runner2);
        fund.bid{value: 0.001 ether}(0.005 ether);

        // Runner1's bond was refunded
        assertEq(runner1.balance, runner1BalBefore);
    }

    function test_auction_non_leader_bond_refunded_immediately() public {
        fund.startEpoch();

        // Runner1 bids 0.005 ETH (leader)
        vm.prank(runner1);
        fund.bid{value: 0.001 ether}(0.005 ether);

        uint256 runner2BalBefore = runner2.balance;

        // Runner2 bids 0.008 ETH (higher, not leader) — bond refunded immediately
        vm.prank(runner2);
        fund.bid{value: 0.0016 ether}(0.008 ether);

        // Runner2 got their bond back (they weren't the leader)
        assertEq(runner2.balance, runner2BalBefore);
    }

    function test_auction_close_no_bids_skips_epoch() public {
        fund.startEpoch();

        // Fast-forward past bidding window
        vm.warp(block.timestamp + BID_WIN);

        fund.closeAuction();

        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.consecutiveMissedEpochs(), 1);

        (, TheHumanFund.EpochPhase phase,,,,,) = fund.getAuctionState(1);
        assertEq(uint256(phase), uint256(TheHumanFund.EpochPhase.SETTLED));
    }

    function test_auction_close_with_bids_enters_execution() public {
        fund.startEpoch();

        vm.prank(runner1);
        fund.bid{value: 0.001 ether}(0.005 ether);

        vm.warp(block.timestamp + BID_WIN);
        fund.closeAuction();

        (, TheHumanFund.EpochPhase phase,,,,,) = fund.getAuctionState(1);
        assertEq(uint256(phase), uint256(TheHumanFund.EpochPhase.EXECUTION));
        // Epoch not advanced yet — waiting for winner to submit
        assertEq(fund.currentEpoch(), 1);
    }

    function test_auction_forfeit_bond_on_timeout() public {
        fund.startEpoch();

        vm.prank(runner1);
        fund.bid{value: 0.001 ether}(0.005 ether);

        vm.warp(block.timestamp + BID_WIN);
        fund.closeAuction();

        // Fast-forward past execution window
        uint256 treasuryBefore = fund.treasuryBalance();
        vm.warp(block.timestamp + EXEC_WIN);
        fund.forfeitBond();

        // Bond stays in treasury
        assertEq(fund.treasuryBalance(), treasuryBefore);
        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.consecutiveMissedEpochs(), 1);

        (, TheHumanFund.EpochPhase phase,,,,,) = fund.getAuctionState(1);
        assertEq(uint256(phase), uint256(TheHumanFund.EpochPhase.SETTLED));
    }

    // ─── Auction: Bid Validation ──────────────────────────────────────────

    function test_auction_bid_above_ceiling_rejected() public {
        fund.startEpoch();

        // Max bid is 0.01 ETH. Bid 0.02 ETH.
        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.bid{value: 0.004 ether}(0.02 ether);
    }

    function test_auction_duplicate_bid_rejected() public {
        fund.startEpoch();

        vm.prank(runner1);
        fund.bid{value: 0.001 ether}(0.005 ether);

        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.AlreadyDone.selector);
        fund.bid{value: 0.001 ether}(0.004 ether);
    }

    function test_auction_bid_insufficient_bond_rejected() public {
        fund.startEpoch();

        // Bid 0.005 ETH requires 0.001 ETH bond. Send only 0.0005.
        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.bid{value: 0.0005 ether}(0.005 ether);
    }

    function test_auction_bid_after_window_rejected() public {
        fund.startEpoch();

        vm.warp(block.timestamp + BID_WIN);

        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.TimingError.selector);
        fund.bid{value: 0.001 ether}(0.005 ether);
    }

    function test_auction_excess_bond_refunded() public {
        fund.startEpoch();

        uint256 balBefore = runner1.balance;
        // Bid 0.005 ETH (bond = 0.001 ETH), send 0.005 ETH (excess = 0.004)
        vm.prank(runner1);
        fund.bid{value: 0.005 ether}(0.005 ether);

        // Only 0.001 should be held (runner1 is the leader)
        assertEq(runner1.balance, balBefore - 0.001 ether);
    }

    // ─── Auction: Timing Enforcement ──────────────────────────────────────

    function test_auction_cannot_close_before_window() public {
        fund.startEpoch();

        vm.expectRevert(TheHumanFund.TimingError.selector);
        fund.closeAuction();
    }

    function test_auction_cannot_forfeit_before_execution_window() public {
        fund.startEpoch();

        vm.prank(runner1);
        fund.bid{value: 0.001 ether}(0.005 ether);

        vm.warp(block.timestamp + BID_WIN);
        fund.closeAuction();

        vm.expectRevert(TheHumanFund.TimingError.selector);
        fund.forfeitBond();
    }

    function test_auction_cannot_start_before_previous_settled() public {
        // Start and settle epoch 1 (no bids)
        fund.startEpoch();
        vm.warp(block.timestamp + BID_WIN);
        fund.closeAuction(); // No bids → epoch skipped, settled

        // Try to start epoch 2 before epoch duration elapsed
        vm.expectRevert(TheHumanFund.TimingError.selector);
        fund.startEpoch();

        // Fast-forward past epoch duration
        vm.warp(block.timestamp + EPOCH_DUR);
        fund.startEpoch(); // Should succeed now
        assertEq(fund.currentEpoch(), 2); // Still epoch 2 (auction opened)
    }

    // ─── Auction: Phase 0 Blocked ─────────────────────────────────────────

    function test_phase0_blocked_when_auction_enabled() public {
        bytes memory action = _noopAction();

        vm.expectRevert(TheHumanFund.WrongPhase.selector);
        fund.submitEpochAction(action, bytes("nope"));

        vm.expectRevert(TheHumanFund.WrongPhase.selector);
        fund.skipEpoch();
    }

    function test_phase0_works_when_auction_disabled() public {
        fund.setAuctionEnabled(false);

        bytes memory action = _noopAction();
        fund.submitEpochAction(action, bytes("back to phase 0"));

        assertEq(fund.currentEpoch(), 2);
    }

    // ─── Auction: Auto-Escalation Integration ─────────────────────────────

    function test_auction_auto_escalation_with_missed_epochs() public {
        // Initial max bid is 0.01 ETH
        assertEq(fund.effectiveMaxBid(), 0.01 ether);

        // Miss epoch 1 (no bids)
        fund.startEpoch();
        vm.warp(block.timestamp + BID_WIN);
        fund.closeAuction();

        // Effective max bid should be escalated by 10%
        assertEq(fund.consecutiveMissedEpochs(), 1);
        assertEq(fund.effectiveMaxBid(), 0.011 ether); // 0.01 * 1.1

        // Miss epoch 2 (no bids)
        vm.warp(block.timestamp + EPOCH_DUR);
        fund.startEpoch();
        vm.warp(block.timestamp + BID_WIN);
        fund.closeAuction();

        assertEq(fund.consecutiveMissedEpochs(), 2);
        assertEq(fund.effectiveMaxBid(), 0.0121 ether); // 0.01 * 1.1^2
    }

    function test_auction_escalation_resets_after_forfeit_does_not() public {
        // Bond forfeiture counts as a miss (consecutiveMissedEpochs increments)
        fund.startEpoch();

        vm.prank(runner1);
        fund.bid{value: 0.001 ether}(0.005 ether);

        vm.warp(block.timestamp + BID_WIN);
        fund.closeAuction();

        vm.warp(block.timestamp + EXEC_WIN);
        fund.forfeitBond();

        // Bond forfeiture = missed epoch
        assertEq(fund.consecutiveMissedEpochs(), 1);
        assertEq(fund.effectiveMaxBid(), 0.011 ether);
    }

    // ─── Auction: Non-winner Submission ───────────────────────────────────

    function test_auction_non_winner_cannot_submit() public {
        fund.startEpoch();

        vm.prank(runner1);
        fund.bid{value: 0.001 ether}(0.005 ether);

        vm.warp(block.timestamp + BID_WIN);
        fund.closeAuction();

        // Runner2 (not the winner) tries to submit
        vm.prank(runner2);
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.submitAuctionResult(_noopAction(), bytes("hax"), _mockAttestation(), uint8(1), -1, "");
    }

    // ─── Auction: Input Hash ──────────────────────────────────────────────

    function test_base_input_hash_committed_at_start() public {
        bytes32 expectedHash = fund.computeInputHash();

        fund.startEpoch();

        // Base hash is committed at startEpoch; final hash (with seed) set at closeAuction
        assertEq(fund.epochBaseInputHashes(1), expectedHash);
    }

    function test_input_hash_deterministic() public view {
        bytes32 hash1 = fund.computeInputHash();
        bytes32 hash2 = fund.computeInputHash();
        assertEq(hash1, hash2);
    }

    // ─── Auction: Edge Cases ──────────────────────────────────────────────

    function test_auction_cannot_start_twice() public {
        fund.startEpoch();

        vm.expectRevert(TheHumanFund.AlreadyDone.selector);
        fund.startEpoch();
    }

    function test_auction_bid_zero_rejected() public {
        fund.startEpoch();

        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.bid{value: 0}(0);
    }

    function test_auction_requires_enabled() public {
        fund.setAuctionEnabled(false);

        vm.expectRevert(TheHumanFund.WrongPhase.selector);
        fund.startEpoch();
    }

    function test_auction_close_requires_bidding_phase() public {
        vm.expectRevert(TheHumanFund.WrongPhase.selector);
        fund.closeAuction();
    }

    function test_auction_forfeit_requires_execution_phase() public {
        vm.expectRevert(TheHumanFund.WrongPhase.selector);
        fund.forfeitBond();
    }

    // ─── Auction: Timing Config ───────────────────────────────────────────

    function test_auction_timing_validation() public {
        // Windows exceed epoch duration
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.setAuctionTiming(100, 60, 60); // 60+60=120 > 100

        // Zero windows
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.setAuctionTiming(100, 0, 50);
    }

    // ─── Attestation Integration ──────────────────────────────────────────

    /// @dev Helper to build mock DCAP output with fields at correct offsets
    function _buildDcapOutput(bytes32 reportData) internal pure returns (bytes memory) {
        bytes memory output = new bytes(595);
        output[0] = 0x00; output[1] = 0x04; // quoteVersion = 4
        output[2] = 0x00; output[3] = 0x02; // quoteBodyType = 2 (TDX)

        // Place measurements at correct offsets
        for (uint256 i = 0; i < 48; i++) {
            output[147 + i] = TEST_MRTD[i];
            output[339 + i] = TEST_RTMR0[i];
            output[387 + i] = TEST_RTMR1[i];
            output[435 + i] = TEST_RTMR2[i];
        }
        // Place REPORTDATA
        for (uint256 i = 0; i < 32; i++) {
            output[531 + i] = reportData[i];
        }
        return output;
    }

    function test_full_auction_with_attestation() public {
        // 1. Start epoch
        fund.startEpoch();

        // 2. Bid
        vm.prank(runner1);
        fund.bid{value: 0.001 ether}(0.005 ether);

        // 3. Close auction (captures prevrandao, commits inputHash with seed)
        vm.warp(block.timestamp + BID_WIN);
        fund.closeAuction();

        // Read inputHash AFTER closeAuction (it now includes the randomness seed)
        bytes32 inputHash = fund.epochInputHashes(1);

        // 4. Prepare action and reasoning
        bytes memory action = _noopAction();
        bytes memory reasoning = bytes("The fund is conserving resources this epoch.");

        // 5. Compute expected REPORTDATA: sha256(inputHash || outputHash)
        bytes32 outputHash = keccak256(abi.encodePacked(sha256(action), sha256(reasoning)));
        bytes32 expectedReportData = sha256(abi.encodePacked(inputHash, outputHash));

        // 6. Set up mock DCAP to return output with correct REPORTDATA
        AuctionMockDcapVerifier etchedMock = AuctionMockDcapVerifier(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F);
        etchedMock.setOutput(_buildDcapOutput(expectedReportData));
        etchedMock.setShouldSucceed(true);

        // 7. Submit result as winner
        uint256 treasuryBefore = fund.treasuryBalance();
        vm.prank(runner1);
        fund.submitAuctionResult(action, reasoning, bytes("mock_quote"), uint8(1), -1, "");

        // 8. Verify epoch advanced
        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.consecutiveMissedEpochs(), 0);

        // 9. Verify epoch content hash was stored
        bytes32 contentHash = fund.epochContentHashes(1);
        assertTrue(contentHash != bytes32(0));
    }

    function test_attestation_reportdata_mismatch_reverts() public {
        fund.startEpoch();

        vm.prank(runner1);
        fund.bid{value: 0.001 ether}(0.005 ether);

        vm.warp(block.timestamp + BID_WIN);
        fund.closeAuction();

        bytes memory action = _noopAction();
        bytes memory reasoning = bytes("test reasoning");

        // Set up mock with WRONG REPORTDATA
        bytes32 wrongReportData = bytes32(uint256(0xdeadbeef));
        AuctionMockDcapVerifier etchedMock = AuctionMockDcapVerifier(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F);
        etchedMock.setOutput(_buildDcapOutput(wrongReportData));
        etchedMock.setShouldSucceed(true);

        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.ProofFailed.selector);
        fund.submitAuctionResult(action, reasoning, bytes("mock_quote"), uint8(1), -1, "");
    }

    function test_randomness_seed_captured() public {
        fund.startEpoch();

        vm.prank(runner1);
        fund.bid{value: 0.001 ether}(0.005 ether);

        vm.warp(block.timestamp + BID_WIN);
        fund.closeAuction();

        (,,,,,,uint256 seed) = fund.getAuctionState(1);
        // block.prevrandao should be non-zero in Foundry's test environment
        // (it defaults to block.difficulty which is 0 in tests, but that's ok —
        // we're testing the storage, not the randomness quality)
        // The important thing is it's stored correctly
        assertEq(seed, block.prevrandao);
    }

    function test_epoch_content_hashes_accumulate() public {
        // Run epoch 1 via Phase 0 (direct submission, no auction)
        fund.setAuctionEnabled(false);

        bytes memory action1 = _noopAction();
        bytes memory reasoning1 = bytes("First epoch reasoning");
        fund.submitEpochAction(action1, reasoning1);

        bytes32 hash1 = fund.epochContentHashes(1);
        assertTrue(hash1 != bytes32(0));

        // Run epoch 2
        bytes memory reasoning2 = bytes("Second epoch reasoning");
        fund.submitEpochAction(_noopAction(), reasoning2);

        bytes32 hash2 = fund.epochContentHashes(2);
        assertTrue(hash2 != bytes32(0));
        assertTrue(hash1 != hash2);
    }

    function test_epoch_content_hash_in_input_hash() public {
        // Submit an epoch to create content hash
        fund.setAuctionEnabled(false);
        fund.submitEpochAction(_noopAction(), bytes("reasoning"));

        bytes32 hashBefore = fund.computeInputHash();

        // Submit another epoch (new content hash + epoch number)
        fund.submitEpochAction(_noopAction(), bytes("more reasoning"));

        bytes32 hashAfter = fund.computeInputHash();

        // Input hash should differ because history changed
        assertTrue(hashBefore != hashAfter);
    }
}
