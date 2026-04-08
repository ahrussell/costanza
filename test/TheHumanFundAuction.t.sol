// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
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

/// @title Auction mechanism tests — commit-reveal sealed bids with fixed escalating bond
contract TheHumanFundAuctionTest is Test {
    TheHumanFund public fund;
    AuctionManager public am;
    TdxVerifier public verifier;
    AuctionMockDcapVerifier public mockDcap;

    address runner1 = address(0x4001);
    address runner2 = address(0x4002);
    address runner3 = address(0x4003);

    // Short testnet timing
    uint256 constant EPOCH_DUR = 300;     // 5 minutes
    uint256 constant COMMIT_WIN = 60;     // 1 minute commit
    uint256 constant REVEAL_WIN = 30;     // 30 seconds reveal
    uint256 constant EXEC_WIN = 120;      // 2 minutes execution

    // Test measurement values (48 bytes each, SHA-384)
    bytes constant TEST_MRTD  = hex"aabbccdd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000011";
    bytes constant TEST_RTMR1 = hex"222222220000000000000000000000000000000000000000000000000000000000000000000000000000000000000033";
    bytes constant TEST_RTMR2 = hex"333333330000000000000000000000000000000000000000000000000000000000000000000000000000000000000044";
    bytes constant TEST_RTMR3 = hex"444444440000000000000000000000000000000000000000000000000000000000000000000000000000000000000055";

    function setUp() public {
        fund = new TheHumanFund{value: 10 ether}(
            1000, 0.01 ether,
            address(0xBEEF), address(0xBEEF), address(0xBEEF), address(0xBEEF), address(0)
        );

        // Deploy and wire auction manager
        am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am));

        fund.addNonprofit("GiveDirectly", "Cash transfers", bytes32("EIN-GD"));
        fund.addNonprofit("Against Malaria Foundation", "Malaria prevention", bytes32("EIN-AMF"));
        fund.addNonprofit("Helen Keller International", "NTDs", bytes32("EIN-HKI"));

        // Deploy attestation verifier with mock DCAP
        mockDcap = new AuctionMockDcapVerifier();
        verifier = new TdxVerifier(address(fund));
        vm.etch(address(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F), address(mockDcap).code);

        bytes32 imageKey = sha256(abi.encodePacked(TEST_MRTD, TEST_RTMR1, TEST_RTMR2));
        verifier.approveImage(imageKey);
        fund.approveVerifier(1, address(verifier));

        // Configure short timing
        fund.setAuctionTiming(EPOCH_DUR, COMMIT_WIN, REVEAL_WIN, EXEC_WIN);

        // Fund runners
        vm.deal(runner1, 10 ether);
        vm.deal(runner2, 10 ether);
        vm.deal(runner3, 10 ether);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    function _noopAction() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0));
    }

    /// @dev Generate a commit hash from bid amount and salt
    function _commitHash(uint256 bidAmount, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bidAmount, salt));
    }

    /// @dev Run a full commit-reveal cycle: start → commit → closeCommit → reveal → closeReveal
    function _runAuctionTo(address runner, uint256 bidAmount, bytes32 salt) internal {
        fund.startEpoch();

        uint256 bond = fund.currentBond();
        vm.prank(runner);
        fund.commit{value: bond}(_commitHash(bidAmount, salt));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        vm.prank(runner);
        fund.reveal(bidAmount, salt);

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.closeReveal();
    }

    /// @dev Build mock DCAP output with fields at correct offsets
    function _buildDcapOutput(bytes32 reportData) internal pure returns (bytes memory) {
        bytes memory output = new bytes(595);
        output[0] = 0x00; output[1] = 0x04; // quoteVersion = 4
        output[2] = 0x00; output[3] = 0x02; // quoteBodyType = 2 (TDX)
        for (uint256 i = 0; i < 48; i++) {
            output[147 + i] = TEST_MRTD[i];   // MRTD — now verified
            output[387 + i] = TEST_RTMR1[i];
            output[435 + i] = TEST_RTMR2[i];
            output[483 + i] = TEST_RTMR3[i];  // Not verified but included for completeness
        }
        for (uint256 i = 0; i < 32; i++) {
            output[531 + i] = reportData[i];
        }
        return output;
    }

    // ─── Auction: Start Epoch ───────────────────────────────────────────────

    function test_start_epoch() public {
        fund.startEpoch();

        assertEq(am.getStartTime(1), block.timestamp);
        assertEq(uint256(am.getPhase(1)), uint256(IAuctionManager.AuctionPhase.COMMIT));
        assertEq(am.getWinner(1), address(0));
        assertEq(am.getWinningBid(1), 0);
        assertEq(am.getBond(1), 0.001 ether); // BASE_BOND
    }

    function test_cannot_start_twice() public {
        fund.startEpoch();
        // Auto-cleanup tries closeCommitPhase, which reverts TimingError (window hasn't elapsed)
        vm.expectRevert(AuctionManager.TimingError.selector);
        fund.startEpoch();
    }

    // ─── Auction: Commit Phase ──────────────────────────────────────────────

    function test_single_commit() public {
        fund.startEpoch();

        vm.prank(runner1);
        fund.commit{value: 0.001 ether}(_commitHash(0.005 ether, bytes32("salt1")));

        // Verify commit was recorded via auction manager
        assertEq(am.getCommitters(1).length, 1);
    }

    function test_commit_requires_bond() public {
        fund.startEpoch();

        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.commit{value: 0.0005 ether}(_commitHash(0.005 ether, bytes32("salt1")));
    }

    function test_commit_refunds_excess() public {
        fund.startEpoch();
        uint256 balBefore = runner1.balance;

        vm.prank(runner1);
        fund.commit{value: 0.05 ether}(_commitHash(0.005 ether, bytes32("salt1")));

        // Only 0.001 bond held
        assertEq(runner1.balance, balBefore - 0.001 ether);
    }

    function test_duplicate_commit_rejected() public {
        fund.startEpoch();

        vm.prank(runner1);
        fund.commit{value: 0.001 ether}(_commitHash(0.005 ether, bytes32("salt1")));

        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.AlreadyDone.selector);
        fund.commit{value: 0.001 ether}(_commitHash(0.003 ether, bytes32("salt2")));
    }

    function test_commit_after_window_rejected() public {
        fund.startEpoch();
        vm.warp(block.timestamp + COMMIT_WIN);

        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.TimingError.selector);
        fund.commit{value: 0.001 ether}(_commitHash(0.005 ether, bytes32("salt1")));
    }

    function test_empty_commit_hash_rejected() public {
        fund.startEpoch();

        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.commit{value: 0.001 ether}(bytes32(0));
    }

    // ─── Auction: Close Commit ──────────────────────────────────────────────

    function test_close_commit_no_commits_skips_epoch() public {
        fund.startEpoch();
        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.consecutiveMissedEpochs(), 1);
    }

    function test_close_commit_enters_reveal() public {
        fund.startEpoch();

        vm.prank(runner1);
        fund.commit{value: 0.001 ether}(_commitHash(0.005 ether, bytes32("salt1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        assertEq(uint256(am.getPhase(1)), uint256(IAuctionManager.AuctionPhase.REVEAL));
    }

    function test_cannot_close_commit_before_window() public {
        fund.startEpoch();
        vm.expectRevert(TheHumanFund.TimingError.selector);
        fund.closeCommit();
    }

    // ─── Auction: Reveal Phase ──────────────────────────────────────────────

    function test_single_reveal() public {
        fund.startEpoch();

        bytes32 salt = bytes32("salt1");
        uint256 bidAmount = 0.005 ether;

        vm.prank(runner1);
        fund.commit{value: 0.001 ether}(_commitHash(bidAmount, salt));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        vm.prank(runner1);
        fund.reveal(bidAmount, salt);

        assertEq(am.getWinner(1), runner1);
        assertEq(am.getWinningBid(1), bidAmount);
    }

    function test_lowest_reveal_wins() public {
        fund.startEpoch();

        bytes32 salt1 = bytes32("salt1");
        bytes32 salt2 = bytes32("salt2");
        bytes32 salt3 = bytes32("salt3");

        vm.prank(runner1);
        fund.commit{value: 0.001 ether}(_commitHash(0.008 ether, salt1));
        vm.prank(runner2);
        fund.commit{value: 0.001 ether}(_commitHash(0.005 ether, salt2));
        vm.prank(runner3);
        fund.commit{value: 0.001 ether}(_commitHash(0.009 ether, salt3));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        vm.prank(runner1);
        fund.reveal(0.008 ether, salt1);
        vm.prank(runner2);
        fund.reveal(0.005 ether, salt2);
        vm.prank(runner3);
        fund.reveal(0.009 ether, salt3);

        assertEq(am.getWinner(1), runner2);
        assertEq(am.getWinningBid(1), 0.005 ether);
    }

    function test_wrong_hash_reveal_reverts() public {
        fund.startEpoch();

        vm.prank(runner1);
        fund.commit{value: 0.001 ether}(_commitHash(0.005 ether, bytes32("salt1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        // Try to reveal with wrong amount
        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.reveal(0.003 ether, bytes32("salt1"));
    }

    function test_reveal_without_commit_reverts() public {
        fund.startEpoch();

        vm.prank(runner1);
        fund.commit{value: 0.001 ether}(_commitHash(0.005 ether, bytes32("salt1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        // Runner2 never committed
        vm.prank(runner2);
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.reveal(0.005 ether, bytes32("salt1"));
    }

    function test_duplicate_reveal_reverts() public {
        fund.startEpoch();

        bytes32 salt = bytes32("salt1");
        vm.prank(runner1);
        fund.commit{value: 0.001 ether}(_commitHash(0.005 ether, salt));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        vm.prank(runner1);
        fund.reveal(0.005 ether, salt);

        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.AlreadyDone.selector);
        fund.reveal(0.005 ether, salt);
    }

    function test_reveal_bid_above_ceiling_rejected() public {
        fund.startEpoch();

        bytes32 salt = bytes32("salt1");
        uint256 tooHigh = 0.02 ether; // max bid is 0.01

        vm.prank(runner1);
        fund.commit{value: 0.001 ether}(_commitHash(tooHigh, salt));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.reveal(tooHigh, salt);
    }

    function test_reveal_after_window_rejected() public {
        fund.startEpoch();

        bytes32 salt = bytes32("salt1");
        vm.prank(runner1);
        fund.commit{value: 0.001 ether}(_commitHash(0.005 ether, salt));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        vm.warp(block.timestamp + REVEAL_WIN);

        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.TimingError.selector);
        fund.reveal(0.005 ether, salt);
    }

    // ─── Auction: Close Reveal ──────────────────────────────────────────────

    function test_close_reveal_no_reveals_forfeits_all_bonds() public {
        fund.startEpoch();

        // Two runners commit but neither reveals
        vm.prank(runner1);
        fund.commit{value: 0.001 ether}(_commitHash(0.005 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: 0.001 ether}(_commitHash(0.003 ether, bytes32("s2")));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.closeReveal();

        // Both bonds stay in AM (forfeited, not refunded)
        assertEq(address(am).balance, 0.002 ether);
        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.consecutiveMissedEpochs(), 1);
    }

    function test_close_reveal_refunds_non_winners() public {
        fund.startEpoch();

        bytes32 s1 = bytes32("s1");
        bytes32 s2 = bytes32("s2");

        vm.prank(runner1);
        fund.commit{value: 0.001 ether}(_commitHash(0.008 ether, s1));
        vm.prank(runner2);
        fund.commit{value: 0.001 ether}(_commitHash(0.005 ether, s2));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        vm.prank(runner1);
        fund.reveal(0.008 ether, s1);
        vm.prank(runner2);
        fund.reveal(0.005 ether, s2);

        uint256 runner1BalBefore = runner1.balance;

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.closeReveal();

        // Runner1 (non-winner who revealed) has bond credited (pull-based)
        assertEq(runner1.balance, runner1BalBefore); // No immediate refund
        assertEq(am.claimableBonds(runner1), 0.001 ether);

        // Runner1 claims their bond
        vm.prank(runner1);
        am.claimBond();
        assertEq(runner1.balance, runner1BalBefore + 0.001 ether);
        assertEq(am.claimableBonds(runner1), 0);
    }

    function test_close_reveal_non_revealer_loses_bond() public {
        fund.startEpoch();

        bytes32 s1 = bytes32("s1");
        bytes32 s2 = bytes32("s2");

        vm.prank(runner1);
        fund.commit{value: 0.001 ether}(_commitHash(0.008 ether, s1));
        vm.prank(runner2);
        fund.commit{value: 0.001 ether}(_commitHash(0.005 ether, s2));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        // Only runner2 reveals
        vm.prank(runner2);
        fund.reveal(0.005 ether, s2);

        uint256 runner1BalBefore = runner1.balance;

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.closeReveal();

        // Runner1 (non-revealer) does NOT get bond back
        assertEq(runner1.balance, runner1BalBefore);
        // Non-revealer's bond sent to fund treasury; winner's bond still in AM until settlement
        assertEq(address(am).balance, 0.001 ether);
    }

    function test_close_reveal_enters_execution() public {
        fund.startEpoch();

        bytes32 salt = bytes32("s1");
        vm.prank(runner1);
        fund.commit{value: 0.001 ether}(_commitHash(0.005 ether, salt));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        vm.prank(runner1);
        fund.reveal(0.005 ether, salt);

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.closeReveal();

        assertEq(uint256(am.getPhase(1)), uint256(IAuctionManager.AuctionPhase.EXECUTION));
        assertEq(fund.currentEpoch(), 1); // Not advanced yet
    }

    function test_cannot_close_reveal_before_window() public {
        fund.startEpoch();

        vm.prank(runner1);
        fund.commit{value: 0.001 ether}(_commitHash(0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        vm.expectRevert(TheHumanFund.TimingError.selector);
        fund.closeReveal();
    }

    // ─── Auction: Forfeit Bond ──────────────────────────────────────────────

    function test_forfeit_bond_on_timeout() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));

        uint256 treasuryBefore = fund.treasuryBalance();
        vm.warp(block.timestamp + EXEC_WIN);
        fund.forfeitBond();

        // Forfeited bond transferred from AM to fund
        assertEq(fund.treasuryBalance(), treasuryBefore + 0.001 ether);
        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.consecutiveMissedEpochs(), 1);
    }

    function test_cannot_forfeit_before_execution_window() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));

        vm.expectRevert(TheHumanFund.TimingError.selector);
        fund.forfeitBond();
    }

    function test_forfeit_requires_execution_phase() public {
        // No auction started — AM reverts with InvalidParams (epoch mismatch)
        vm.expectRevert(AuctionManager.InvalidParams.selector);
        fund.forfeitBond();
    }

    // ─── Auction: Bond Escalation ───────────────────────────────────────────

    function test_bond_escalates_on_missed_epochs() public {
        assertEq(fund.currentBond(), 0.001 ether);

        // Miss epoch 1
        uint256 t0 = block.timestamp;
        fund.startEpoch();
        vm.warp(t0 + COMMIT_WIN);
        fund.closeCommit();

        assertEq(fund.consecutiveMissedEpochs(), 1);
        assertEq(fund.currentBond(), 0.0011 ether); // 0.001 * 1.1

        // Miss epoch 2
        uint256 t1 = t0 + EPOCH_DUR;
        vm.warp(t1);
        fund.startEpoch();
        vm.warp(t1 + COMMIT_WIN);
        fund.closeCommit();

        assertEq(fund.consecutiveMissedEpochs(), 2);
        assertEq(fund.currentBond(), 0.00121 ether); // 0.001 * 1.1^2
    }

    function test_bond_escalates_after_forfeit() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));

        vm.warp(block.timestamp + EXEC_WIN);
        fund.forfeitBond();

        assertEq(fund.consecutiveMissedEpochs(), 1);
        assertEq(fund.currentBond(), 0.0011 ether);
    }

    // ─── Auction: Bid Ceiling Auto-Escalation ───────────────────────────────

    function test_bid_ceiling_escalates() public {
        assertEq(fund.effectiveMaxBid(), 0.01 ether);

        // Miss epoch 1
        fund.startEpoch();
        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        assertEq(fund.effectiveMaxBid(), 0.011 ether);
    }

    // ─── Direct Submission Coexistence ────────────────────────────────────────

    function test_direct_submission_works_alongside_auction() public {
        fund.submitEpochAction(_noopAction(), bytes("direct submit"), -1, "");
        assertEq(fund.currentEpoch(), 2);
    }

    // ─── Auction: Timing ────────────────────────────────────────────────────

    function test_cannot_start_before_previous_settled() public {
        fund.startEpoch();
        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit(); // No commits → settled

        vm.expectRevert(TheHumanFund.TimingError.selector);
        fund.startEpoch();

        vm.warp(block.timestamp + EPOCH_DUR);
        fund.startEpoch();
        assertEq(fund.currentEpoch(), 2);
    }

    function test_timing_validation() public {
        // Windows exceed epoch duration
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.setAuctionTiming(100, 40, 30, 40); // 40+30+40=110 > 100

        // Zero windows
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.setAuctionTiming(100, 0, 30, 50);
    }

    // ─── Auction: Non-winner Submission ─────────────────────────────────────

    function test_non_winner_cannot_submit() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));

        vm.prank(runner2);
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.submitAuctionResult(_noopAction(), bytes("hax"), bytes("mock"), uint8(1), -1, "");
    }

    // ─── Auction: Input Hash ────────────────────────────────────────────────

    function test_base_input_hash_committed_at_start() public {
        bytes32 expectedHash = fund.computeInputHash();
        fund.startEpoch();
        assertEq(fund.epochBaseInputHashes(1), expectedHash);
    }

    function test_input_hash_deterministic() public view {
        assertEq(fund.computeInputHash(), fund.computeInputHash());
    }

    function test_randomness_seed_captured() public {
        bytes32 salt = bytes32("s1");
        _runAuctionTo(runner1, 0.005 ether, salt);

        // Seed mixes prevrandao with XOR of revealed salts
        uint256 expectedSeed = uint256(keccak256(abi.encodePacked(block.prevrandao, salt)));
        assertEq(am.getRandomnessSeed(1), expectedSeed);
    }

    // ─── Attestation Integration ────────────────────────────────────────────

    function test_full_auction_with_attestation() public {
        bytes32 salt = bytes32("s1");
        uint256 bidAmount = 0.005 ether;

        _runAuctionTo(runner1, bidAmount, salt);

        bytes32 inputHash = fund.epochInputHashes(1);
        bytes memory action = _noopAction();
        bytes memory reasoning = bytes("The fund is conserving resources.");

        bytes32 outputHash = keccak256(abi.encodePacked(sha256(action), sha256(reasoning)));
        bytes32 expectedReportData = sha256(abi.encodePacked(inputHash, outputHash));

        AuctionMockDcapVerifier etchedMock = AuctionMockDcapVerifier(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F);
        etchedMock.setOutput(_buildDcapOutput(expectedReportData));
        etchedMock.setShouldSucceed(true);

        vm.prank(runner1);
        fund.submitAuctionResult(action, reasoning, bytes("mock_quote"), uint8(1), -1, "");

        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.consecutiveMissedEpochs(), 0);
        assertTrue(fund.epochContentHashes(1) != bytes32(0));
    }

    function test_attestation_reportdata_mismatch_reverts() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));

        bytes32 wrongReportData = bytes32(uint256(0xdeadbeef));
        AuctionMockDcapVerifier etchedMock = AuctionMockDcapVerifier(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F);
        etchedMock.setOutput(_buildDcapOutput(wrongReportData));
        etchedMock.setShouldSucceed(true);

        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.ProofFailed.selector);
        fund.submitAuctionResult(_noopAction(), bytes("test"), bytes("mock"), uint8(1), -1, "");
    }

    // ─── Epoch Content Hashes ───────────────────────────────────────────────

    function test_epoch_content_hashes_accumulate() public {
        fund.submitEpochAction(_noopAction(), bytes("First"), -1, "");
        bytes32 hash1 = fund.epochContentHashes(1);
        assertTrue(hash1 != bytes32(0));

        fund.submitEpochAction(_noopAction(), bytes("Second"), -1, "");
        bytes32 hash2 = fund.epochContentHashes(2);
        assertTrue(hash2 != bytes32(0));
        assertTrue(hash1 != hash2);
    }

    function test_epoch_content_hash_in_input_hash() public {
        fund.submitEpochAction(_noopAction(), bytes("reasoning"), -1, "");
        bytes32 hashBefore = fund.computeInputHash();

        fund.submitEpochAction(_noopAction(), bytes("more reasoning"), -1, "");
        bytes32 hashAfter = fund.computeInputHash();

        assertTrue(hashBefore != hashAfter);
    }

    // ─── Sunset / Migration ─────────────────────────────────────────────

    function test_sunset_blocksStartEpoch() public {
        fund.freeze(fund.FREEZE_SUNSET());

        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.startEpoch();
    }

    function test_sunset_blocksCommit() public {
        // Start an epoch before sunset
        fund.startEpoch();
        // Now freeze
        fund.freeze(fund.FREEZE_SUNSET());

        uint256 bond = fund.currentBond();
        bytes32 commitHash = _commitHash(0.001 ether, bytes32("salt1"));

        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.commit{value: bond}(commitHash);
    }

    function test_migrate_requiresNoActiveAuction() public {
        // Start an epoch — puts auction in COMMIT phase
        fund.startEpoch();
        fund.freeze(fund.FREEZE_SUNSET());

        vm.expectRevert(TheHumanFund.WrongPhase.selector);
        fund.migrate(address(0xBEEF));
    }

    // ─── Stale Auction Auto-Cleanup ──────────────────────────────────────────

    function test_auto_clean_stale_commit_no_commits() public {
        fund.startEpoch();
        // Nobody commits. Warp past full epoch duration.
        vm.warp(block.timestamp + EPOCH_DUR);

        // startEpoch() should auto-clean the stale COMMIT phase (0 commits → SETTLED)
        fund.startEpoch();

        // Epoch 1 was missed, now on epoch 2's auction
        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.consecutiveMissedEpochs(), 1);
        assertEq(uint256(am.getPhase(1)), uint256(IAuctionManager.AuctionPhase.SETTLED));
    }

    function test_auto_clean_stale_commit_with_commits() public {
        fund.startEpoch();
        uint256 bond = fund.currentBond();

        // Runner commits but nobody calls closeCommit
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(0.005 ether, bytes32("s1")));

        // Warp past full epoch
        vm.warp(block.timestamp + EPOCH_DUR);

        // startEpoch() chains: closeCommit (1 commit → REVEAL) → closeReveal (0 reveals → SETTLED)
        fund.startEpoch();

        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.consecutiveMissedEpochs(), 1);
        // Runner's bond stays in AM (forfeit — same as existing 0-reveal behavior)
        assertEq(address(am).balance, bond);
    }

    function test_auto_clean_stale_reveal_no_reveals() public {
        fund.startEpoch();
        uint256 bond = fund.currentBond();

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(0.005 ether, bytes32("s1")));

        // closeCommit is called (commits > 0, so epoch not advanced), moving AM to REVEAL
        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        // Nobody reveals. Warp past full epoch.
        vm.warp(block.timestamp + EPOCH_DUR);

        // startEpoch() should auto-clean: closeReveal (0 reveals → SETTLED)
        fund.startEpoch();

        // currentEpoch advances by 1 (the stale epoch 1)
        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.consecutiveMissedEpochs(), 1);
        // Bond stays in AM (forfeit — same as existing 0-reveal behavior)
        assertEq(address(am).balance, bond);
    }

    function test_auto_clean_stale_reveal_with_reveals() public {
        fund.startEpoch();
        uint256 bond = fund.currentBond();

        // Two runners commit
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(0.003 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: bond}(_commitHash(0.005 ether, bytes32("s2")));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        // Both reveal — runner1 wins (lower bid)
        vm.prank(runner1);
        fund.reveal(0.003 ether, bytes32("s1"));
        vm.prank(runner2);
        fund.reveal(0.005 ether, bytes32("s2"));

        // Nobody calls closeReveal. Warp past full epoch.
        vm.warp(block.timestamp + EPOCH_DUR);

        uint256 treasuryBefore = address(fund).balance;

        // startEpoch() chains: closeReveal (runner1 wins, runner2 refunded) → forfeitExecution (runner1 bond forfeit)
        fund.startEpoch();

        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.consecutiveMissedEpochs(), 1);
        // Winner's (runner1) bond was forfeit to treasury
        assertGt(address(fund).balance, treasuryBefore);
        // Loser (runner2) bond was credited for claim
        assertEq(am.claimableBonds(runner2), bond);
    }

    function test_auto_clean_stale_execution() public {
        // Full commit-reveal cycle, then nobody submits
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));

        // Warp past execution window AND full epoch duration
        vm.warp(block.timestamp + EPOCH_DUR);

        uint256 treasuryBefore = address(fund).balance;

        fund.startEpoch();

        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.consecutiveMissedEpochs(), 1);
        assertGt(address(fund).balance, treasuryBefore);
    }

    function test_missed_epoch_count_reflects_elapsed_time() public {
        fund.startEpoch();
        // Nobody commits. Warp past 3 full epoch durations.
        vm.warp(block.timestamp + EPOCH_DUR * 3);

        fund.startEpoch();

        // 3 epoch durations elapsed → 3 missed epochs credited
        assertEq(fund.consecutiveMissedEpochs(), 3);
        // currentEpoch advanced by 3 (wall-clock alignment)
        assertEq(fund.currentEpoch(), 4);
        // Bond should reflect 3 missed epochs: 0.001 * 1.1^3 = 0.001331
        assertEq(fund.currentBond(), 0.001331 ether);
        // Effective max bid: 0.01 * 1.1^3 = 0.01331
        assertEq(fund.effectiveMaxBid(), 0.01331 ether);
    }

    function test_missed_epoch_count_caps_at_max() public {
        fund.startEpoch();
        // Warp past 100 epoch durations (well beyond MAX_MISSED_EPOCHS of 50)
        vm.warp(block.timestamp + EPOCH_DUR * 100);

        fund.startEpoch();

        assertEq(fund.consecutiveMissedEpochs(), 50); // capped at MAX_MISSED_EPOCHS
    }

    function test_successful_epoch_after_stale_cleanup_resets_missed_count() public {
        // Let an epoch go stale for 3 epoch durations
        fund.startEpoch();
        vm.warp(block.timestamp + EPOCH_DUR * 3);
        fund.startEpoch();

        assertEq(fund.consecutiveMissedEpochs(), 3);

        // Now run a successful auction on the new epoch
        uint256 epoch = fund.currentEpoch();
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("s1"));

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.closeReveal();

        // Submit result (no attestation needed — use direct submission for simplicity)
        // Actually, we need to go through the auction path. Use a noop via submitAuctionResult.
        bytes32 inputHash = fund.epochInputHashes(epoch);
        bytes memory action = _noopAction();
        bytes memory reasoning = bytes("Recovery epoch.");
        bytes32 outputHash = keccak256(abi.encodePacked(sha256(action), sha256(reasoning)));
        bytes32 expectedReportData = sha256(abi.encodePacked(inputHash, outputHash));

        AuctionMockDcapVerifier etchedMock = AuctionMockDcapVerifier(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F);
        etchedMock.setOutput(_buildDcapOutput(expectedReportData));
        etchedMock.setShouldSucceed(true);

        vm.prank(runner1);
        fund.submitAuctionResult(action, reasoning, bytes("mock_quote"), uint8(1), -1, "");

        // consecutiveMissedEpochs should be reset
        assertEq(fund.consecutiveMissedEpochs(), 0);
        assertEq(fund.currentBond(), 0.001 ether); // back to base
    }

    // ─── Wall-Clock Anchored Timing ────────────────────────────────────

    function test_wall_clock_no_drift() public {
        uint256 anchor = fund.timingAnchor();

        // Epoch 1: start on time
        fund.startEpoch();
        assertEq(am.getStartTime(1), anchor);

        // Complete epoch 1 (0 commits → miss)
        vm.warp(anchor + COMMIT_WIN);
        fund.closeCommit();

        // Epoch 2: start 30 seconds LATE
        uint256 epoch2Scheduled = anchor + EPOCH_DUR;
        uint256 lateStart = epoch2Scheduled + 30;
        vm.warp(lateStart);
        fund.startEpoch();

        // Start time should be the SCHEDULED time, not the late call time
        assertEq(am.getStartTime(2), epoch2Scheduled);
        assertTrue(am.getStartTime(2) < lateStart);

        // Complete epoch 2 (0 commits → miss)
        // Commit window deadline is epoch2Scheduled + COMMIT_WIN, so warp past it
        vm.warp(epoch2Scheduled + COMMIT_WIN);
        fund.closeCommit();

        // Epoch 3: should start at anchor + 2*EPOCH_DUR, NOT shifted by the 30s late start
        uint256 epoch3Scheduled = anchor + 2 * EPOCH_DUR;
        vm.warp(epoch3Scheduled);
        fund.startEpoch();
        assertEq(am.getStartTime(3), epoch3Scheduled);
    }

    function test_late_start_shortens_commit_window() public {
        uint256 anchor = fund.timingAnchor();

        // Start and miss epoch 1
        fund.startEpoch();
        vm.warp(anchor + COMMIT_WIN);
        fund.closeCommit();

        // Start epoch 2 exactly 50 seconds late (60s commit window → 10s remaining)
        uint256 epoch2Start = anchor + EPOCH_DUR;
        vm.warp(epoch2Start + 50);
        fund.startEpoch();

        // Commit should still work (10 seconds remaining)
        uint256 bond = fund.currentBond();
        vm.deal(runner1, 1 ether);
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(0.005 ether, bytes32("s1")));

        // But at the exact deadline, commit should fail
        vm.warp(epoch2Start + COMMIT_WIN);
        vm.deal(runner2, 1 ether);
        vm.prank(runner2);
        vm.expectRevert(AuctionManager.TimingError.selector);
        fund.commit{value: bond}(_commitHash(0.003 ether, bytes32("s2")));
    }

    function test_epochStartTime_view() public {
        uint256 anchor = fund.timingAnchor();
        assertEq(fund.epochStartTime(1), anchor);
        assertEq(fund.epochStartTime(2), anchor + EPOCH_DUR);
        assertEq(fund.epochStartTime(5), anchor + 4 * EPOCH_DUR);
        assertEq(fund.epochStartTime(10), anchor + 9 * EPOCH_DUR);
    }

    function test_setAuctionTiming_reanchors() public {
        uint256 originalAnchor = fund.timingAnchor();

        // Start and miss epoch 1
        fund.startEpoch();
        vm.warp(block.timestamp + COMMIT_WIN);
        fund.closeCommit();

        // Advance to epoch 2
        vm.warp(originalAnchor + EPOCH_DUR);
        fund.startEpoch();
        assertEq(fund.currentEpoch(), 2);

        // Change timing — should re-anchor at epoch 2's scheduled start
        uint256 epoch2Start = originalAnchor + EPOCH_DUR;
        uint256 newEpochDur = 600; // double the duration
        fund.setAuctionTiming(newEpochDur, COMMIT_WIN, REVEAL_WIN, EXEC_WIN);

        assertEq(fund.timingAnchor(), epoch2Start);
        assertEq(fund.anchorEpoch(), 2);

        // Epoch 3 should use the new duration from the new anchor
        assertEq(fund.epochStartTime(3), epoch2Start + newEpochDur);
    }

    function test_migrate_afterAuctionSettles() public {
        // Run a full auction cycle to settlement
        bytes32 salt = bytes32("s1");
        uint256 bidAmount = 0.005 ether;
        _runAuctionTo(runner1, bidAmount, salt);

        // Submit attested result to settle the auction
        bytes32 inputHash = fund.epochInputHashes(1);
        bytes memory action = _noopAction();
        bytes memory reasoning = bytes("Conserving resources.");

        bytes32 outputHash = keccak256(abi.encodePacked(sha256(action), sha256(reasoning)));
        bytes32 expectedReportData = sha256(abi.encodePacked(inputHash, outputHash));

        AuctionMockDcapVerifier etchedMock = AuctionMockDcapVerifier(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F);
        etchedMock.setOutput(_buildDcapOutput(expectedReportData));
        etchedMock.setShouldSucceed(true);

        vm.prank(runner1);
        fund.submitAuctionResult(action, reasoning, bytes("mock_quote"), uint8(1), -1, "");

        // Now sunset + migrate
        address dest = address(0xCAFE);
        uint256 bal = address(fund).balance;
        fund.freeze(fund.FREEZE_SUNSET());
        fund.migrate(dest);

        assertEq(address(fund).balance, 0);
        assertEq(dest.balance, bal);
    }
}
