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

/// @title V2 Auction tests — auto-advancing phases with syncPhase() and lazy bond claims
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

        am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am));

        fund.addNonprofit("GiveDirectly", "Cash transfers", bytes32("EIN-GD"));
        fund.addNonprofit("Against Malaria Foundation", "Malaria prevention", bytes32("EIN-AMF"));
        fund.addNonprofit("Helen Keller International", "NTDs", bytes32("EIN-HKI"));

        mockDcap = new AuctionMockDcapVerifier();
        verifier = new TdxVerifier(address(fund));
        vm.etch(address(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F), address(mockDcap).code);

        bytes32 imageKey = sha256(abi.encodePacked(TEST_MRTD, TEST_RTMR1, TEST_RTMR2));
        verifier.approveImage(imageKey);
        fund.approveVerifier(1, address(verifier));

        fund.setAuctionTiming(EPOCH_DUR, COMMIT_WIN, REVEAL_WIN, EXEC_WIN);

        vm.deal(runner1, 10 ether);
        vm.deal(runner2, 10 ether);
        vm.deal(runner3, 10 ether);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    function _noopAction() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0));
    }

    function _commitHash(uint256 bidAmount, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bidAmount, salt));
    }

    /// @dev Run a full commit-reveal cycle using auto-advancing API:
    ///      syncPhase (opens auction) → commit → warp → reveal (auto-closes commit) → warp → syncPhase (closes reveal, captures seed)
    function _runAuctionTo(address runner, uint256 bidAmount, bytes32 salt) internal {
        fund.syncPhase(); // opens auction for current epoch

        uint256 bond = fund.currentBond();
        vm.prank(runner);
        fund.commit{value: bond}(_commitHash(bidAmount, salt));

        vm.warp(block.timestamp + COMMIT_WIN); // advance past commit window

        vm.prank(runner);
        fund.reveal(bidAmount, salt); // auto-closes commit via _syncPhase

        vm.warp(block.timestamp + REVEAL_WIN); // advance past reveal window
        fund.syncPhase(); // closes reveal, captures seed, binds input hash
    }

    function _buildDcapOutput(bytes32 reportData) internal pure returns (bytes memory) {
        bytes memory output = new bytes(595);
        output[0] = 0x00; output[1] = 0x04;
        output[2] = 0x00; output[3] = 0x02;
        for (uint256 i = 0; i < 48; i++) {
            output[147 + i] = TEST_MRTD[i];
            output[387 + i] = TEST_RTMR1[i];
            output[435 + i] = TEST_RTMR2[i];
            output[483 + i] = TEST_RTMR3[i];
        }
        for (uint256 i = 0; i < 32; i++) {
            output[531 + i] = reportData[i];
        }
        return output;
    }

    function _submitAttestedResult(address runner, uint256 epoch) internal {
        bytes32 inputHash = fund.epochInputHashes(epoch);
        bytes memory action = _noopAction();
        bytes memory reasoning = bytes("The fund is conserving resources.");
        bytes32 outputHash = keccak256(abi.encodePacked(sha256(action), sha256(reasoning)));
        bytes32 expectedReportData = sha256(abi.encodePacked(inputHash, outputHash));

        AuctionMockDcapVerifier etchedMock = AuctionMockDcapVerifier(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F);
        etchedMock.setOutput(_buildDcapOutput(expectedReportData));
        etchedMock.setShouldSucceed(true);

        vm.prank(runner);
        fund.submitAuctionResult(action, reasoning, bytes("mock_quote"), uint8(1), -1, "");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 1: Auto-Advancement via syncPhase
    // ═══════════════════════════════════════════════════════════════════════

    function test_syncPhase_opensAuction() public {
        fund.syncPhase();

        assertEq(am.getStartTime(1), block.timestamp);
        assertEq(uint256(am.getPhase(1)), uint256(IAuctionManager.AuctionPhase.COMMIT));
        assertEq(am.getBond(1), 0.01 ether);
    }

    function test_syncPhase_idempotent() public {
        fund.syncPhase();
        uint256 epoch1 = fund.currentEpoch();
        fund.syncPhase(); // should be no-op
        assertEq(fund.currentEpoch(), epoch1);
        assertEq(uint256(am.getPhase(1)), uint256(IAuctionManager.AuctionPhase.COMMIT));
    }

    function test_syncPhase_closesCommit() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.syncPhase(); // should close commit → REVEAL

        assertEq(uint256(am.getPhase(1)), uint256(IAuctionManager.AuctionPhase.REVEAL));
    }

    function test_syncPhase_closesReveal_capturesSeed() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("s1"));

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase(); // should close reveal → EXECUTION, capture seed

        assertEq(uint256(am.getPhase(1)), uint256(IAuctionManager.AuctionPhase.EXECUTION));
        assertTrue(am.getRandomnessSeed(1) != 0);
        assertTrue(fund.epochInputHashes(1) != bytes32(0));
    }

    function test_syncPhase_forfeitsExpiredExecution() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        uint256 treasuryBefore = fund.treasuryBalance();

        vm.warp(block.timestamp + EXEC_WIN);
        fund.syncPhase(); // should forfeit → SETTLED

        assertEq(fund.treasuryBalance(), treasuryBefore + 0.01 ether);
        assertEq(fund.consecutiveMissedEpochs(), 1);
    }

    function test_syncPhase_multipleTransitions() public {
        // Open auction, commit, then warp past everything
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s1")));

        // Warp past commit + reveal + execution windows
        vm.warp(block.timestamp + COMMIT_WIN + REVEAL_WIN + EXEC_WIN);
        fund.syncPhase();

        // Should have chained: COMMIT→REVEAL (no reveals)→SETTLED
        // (No reveals means REVEAL settles immediately, doesn't reach EXECUTION)
        assertEq(uint256(am.getPhase(1)), uint256(IAuctionManager.AuctionPhase.SETTLED));
    }

    function test_syncPhase_chainsFullCycleWithReveals() public {
        // Open auction, commit, reveal, then warp past everything
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("s1"));

        // Warp past reveal + execution (execution window expires → forfeit)
        vm.warp(block.timestamp + REVEAL_WIN + EXEC_WIN);
        uint256 treasuryBefore = fund.treasuryBalance();
        fund.syncPhase();

        // Should chain: REVEAL→EXECUTION→SETTLED (forfeit)
        assertEq(uint256(am.getPhase(1)), uint256(IAuctionManager.AuctionPhase.SETTLED));
        assertGt(fund.treasuryBalance(), treasuryBefore); // winner's bond forfeited
        assertTrue(fund.epochInputHashes(1) != bytes32(0)); // seed was bound
    }

    function test_syncPhase_noCommits_missesEpoch() public {
        fund.syncPhase();
        vm.warp(block.timestamp + COMMIT_WIN);
        fund.syncPhase(); // closes commit (0 commits → SETTLED)

        // Epoch should advance
        assertEq(fund.currentEpoch(), 2);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 2: Auto-Advancing Actions (commit/reveal/submit auto-sync)
    // ═══════════════════════════════════════════════════════════════════════

    function test_commit_autoOpensAuction() public {
        // Call commit directly — should auto-open auction via _syncPhase
        uint256 bond = 0.01 ether; // BASE_BOND
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(0.005 ether, bytes32("s1")));

        assertEq(uint256(am.getPhase(1)), uint256(IAuctionManager.AuctionPhase.COMMIT));
        assertEq(am.getCommitters(1).length, 1);
    }

    function test_reveal_autoClosesCommit() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);

        // reveal() auto-closes commit via _syncPhase
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("s1"));

        assertEq(am.getWinner(1), runner1);
    }

    function test_submit_autoClosesReveal() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("s1"));

        vm.warp(block.timestamp + REVEAL_WIN);
        // Call syncPhase first to close reveal and bind the input hash,
        // so the test helper can read epochInputHashes to build the proof.
        fund.syncPhase();

        _submitAttestedResult(runner1, 1);
        fund.syncPhase();

        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.consecutiveMissedEpochs(), 0);
    }

    function test_commit_afterWindow_reverts() public {
        fund.syncPhase();
        vm.warp(block.timestamp + COMMIT_WIN);

        // _syncPhase closes commit (0 commits → SETTLED), then commit reverts
        vm.prank(runner1);
        vm.expectRevert(); // WrongPhase or similar
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s1")));
    }

    function test_reveal_beforeCommitWindow_reverts() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s1")));

        // Still in commit window — _syncPhase won't advance, reveal gets WrongPhase
        vm.prank(runner1);
        vm.expectRevert(AuctionManager.WrongPhase.selector);
        fund.reveal(0.005 ether, bytes32("s1"));
    }

    function test_reveal_afterRevealWindow_reverts() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s1")));

        // Warp past both commit AND reveal windows
        // _syncPhase advances COMMIT→REVEAL→EXECUTION (if commits+reveals) or SETTLED
        // Since only 1 commit and 0 reveals at this point, it goes COMMIT→REVEAL→SETTLED
        vm.warp(block.timestamp + COMMIT_WIN + REVEAL_WIN);

        vm.prank(runner1);
        vm.expectRevert(); // Phase has been auto-advanced past REVEAL
        fund.reveal(0.005 ether, bytes32("s1"));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 3: Commit Phase
    // ═══════════════════════════════════════════════════════════════════════

    function test_single_commit() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("salt1")));
        assertEq(am.getCommitters(1).length, 1);
    }

    function test_commit_requires_bond() public {
        fund.syncPhase();
        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.commit{value: 0.0005 ether}(_commitHash(0.005 ether, bytes32("salt1")));
    }

    function test_commit_refunds_excess() public {
        fund.syncPhase();
        uint256 balBefore = runner1.balance;
        vm.prank(runner1);
        fund.commit{value: 0.05 ether}(_commitHash(0.005 ether, bytes32("salt1")));
        assertEq(runner1.balance, balBefore - 0.01 ether);
    }

    function test_duplicate_commit_rejected() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("salt1")));
        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.AlreadyDone.selector);
        fund.commit{value: 0.01 ether}(_commitHash(0.003 ether, bytes32("salt2")));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 4: Reveal Phase
    // ═══════════════════════════════════════════════════════════════════════

    function test_single_reveal() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("s1"));

        assertEq(am.getWinner(1), runner1);
        assertEq(am.getWinningBid(1), 0.005 ether);
    }

    function test_lowest_reveal_wins() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.008 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s2")));
        vm.prank(runner3);
        fund.commit{value: 0.01 ether}(_commitHash(0.009 ether, bytes32("s3")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.008 ether, bytes32("s1"));
        vm.prank(runner2);
        fund.reveal(0.005 ether, bytes32("s2"));
        vm.prank(runner3);
        fund.reveal(0.009 ether, bytes32("s3"));

        assertEq(am.getWinner(1), runner2);
        assertEq(am.getWinningBid(1), 0.005 ether);
    }

    function test_wrong_hash_reveal_reverts() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("salt1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.reveal(0.003 ether, bytes32("salt1"));
    }

    function test_reveal_without_commit_reverts() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner2);
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.reveal(0.005 ether, bytes32("s1"));
    }

    function test_duplicate_reveal_reverts() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("s1"));
        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.AlreadyDone.selector);
        fund.reveal(0.005 ether, bytes32("s1"));
    }

    function test_reveal_bid_above_ceiling_rejected() public {
        fund.syncPhase();
        bytes32 salt = bytes32("salt1");
        uint256 tooHigh = 0.02 ether;
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(tooHigh, salt));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.reveal(tooHigh, salt);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 5: Lazy Bond Claiming
    // ═══════════════════════════════════════════════════════════════════════

    function test_claimBond_nonWinnerRevealer() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.008 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s2")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.008 ether, bytes32("s1"));
        vm.prank(runner2);
        fund.reveal(0.005 ether, bytes32("s2"));

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase(); // closes reveal — runner2 wins, runner1 can claim

        assertEq(am.pendingBondRefunds(), 0.01 ether); // runner1's bond

        uint256 runner1BalBefore = runner1.balance;
        vm.prank(runner1);
        am.claimBond(1);

        assertEq(runner1.balance, runner1BalBefore + 0.01 ether);
        assertEq(am.pendingBondRefunds(), 0);
    }

    function test_claimBond_doubleClaim_reverts() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.008 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s2")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.008 ether, bytes32("s1"));
        vm.prank(runner2);
        fund.reveal(0.005 ether, bytes32("s2"));

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase();

        vm.prank(runner1);
        am.claimBond(1);

        vm.prank(runner1);
        vm.expectRevert(AuctionManager.AlreadyDone.selector);
        am.claimBond(1);
    }

    function test_claimBond_nonRevealer_reverts() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: 0.01 ether}(_commitHash(0.003 ether, bytes32("s2")));

        vm.warp(block.timestamp + COMMIT_WIN);
        // Only runner2 reveals
        vm.prank(runner2);
        fund.reveal(0.003 ether, bytes32("s2"));

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase();

        // runner1 didn't reveal — can't claim
        vm.prank(runner1);
        vm.expectRevert(AuctionManager.Unauthorized.selector);
        am.claimBond(1);
    }

    function test_claimBond_winner_reverts() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.008 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s2")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.008 ether, bytes32("s1"));
        vm.prank(runner2);
        fund.reveal(0.005 ether, bytes32("s2"));

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase();

        // runner2 is the winner — can't use claimBond
        vm.prank(runner2);
        vm.expectRevert(AuctionManager.InvalidParams.selector);
        am.claimBond(1);
    }

    function test_forfeitedBonds_sentToFund() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: 0.01 ether}(_commitHash(0.003 ether, bytes32("s2")));

        vm.warp(block.timestamp + COMMIT_WIN);
        // Only runner2 reveals
        vm.prank(runner2);
        fund.reveal(0.003 ether, bytes32("s2"));

        uint256 fundBalBefore = address(fund).balance;

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase();

        // runner1's bond (non-revealer) should be sent to fund treasury
        assertEq(address(fund).balance, fundBalBefore + 0.01 ether);
        // Only runner2's winner bond is pending (held for execution)
        assertEq(am.pendingBondRefunds(), 0); // no non-winning revealers (runner2 is winner)
    }

    function test_pendingBondRefunds_accounting_threeProvers() public {
        fund.syncPhase();
        // 3 commit, 2 reveal, runner3 wins (lowest bid)
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.008 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: 0.01 ether}(_commitHash(0.006 ether, bytes32("s2")));
        vm.prank(runner3);
        fund.commit{value: 0.01 ether}(_commitHash(0.004 ether, bytes32("s3")));

        vm.warp(block.timestamp + COMMIT_WIN);
        // runner1 and runner3 reveal, runner2 doesn't
        vm.prank(runner1);
        fund.reveal(0.008 ether, bytes32("s1"));
        vm.prank(runner3);
        fund.reveal(0.004 ether, bytes32("s3"));

        uint256 fundBalBefore = address(fund).balance;

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase();

        // runner2 (non-revealer): bond forfeited to fund
        assertEq(address(fund).balance, fundBalBefore + 0.01 ether);
        // runner1 (non-winning revealer): bond is pending
        assertEq(am.pendingBondRefunds(), 0.01 ether);
        // runner3 (winner): bond held until settle/forfeit
    }

    function test_noReveals_allBondsForfeited() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: 0.01 ether}(_commitHash(0.003 ether, bytes32("s2")));

        vm.warp(block.timestamp + COMMIT_WIN + REVEAL_WIN);
        uint256 fundBalBefore = address(fund).balance;
        fund.syncPhase(); // closes commit → REVEAL (2 commits), closes reveal → SETTLED (0 reveals)

        // All bonds forfeited to fund (2 bonds × 0.01 ETH)
        assertEq(address(fund).balance, fundBalBefore + 0.02 ether);
        assertEq(am.pendingBondRefunds(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 6: Missed Epoch Advancement (O(1))
    // ═══════════════════════════════════════════════════════════════════════

    function test_missedEpochs_O1_arithmetic() public {
        fund.syncPhase(); // open epoch 1
        // Nobody commits. Warp past 5 full epoch durations.
        vm.warp(block.timestamp + EPOCH_DUR * 5);

        fund.syncPhase();

        assertEq(fund.consecutiveMissedEpochs(), 5);
        assertEq(fund.currentEpoch(), 6);
    }

    function test_missedEpochs_capsAtMax() public {
        fund.syncPhase();
        vm.warp(block.timestamp + EPOCH_DUR * 100);
        fund.syncPhase();

        assertEq(fund.consecutiveMissedEpochs(), 50); // MAX_MISSED_EPOCHS
    }

    function test_missedEpochs_bondEscalates() public {
        fund.syncPhase();
        vm.warp(block.timestamp + EPOCH_DUR * 3);
        fund.syncPhase();

        assertEq(fund.consecutiveMissedEpochs(), 3);
        assertEq(fund.currentBond(), 0.01331 ether); // 0.01 * 1.1^3
        assertEq(fund.effectiveMaxBid(), 0.01331 ether); // 0.01 * 1.1^3
    }

    function test_missedEpochs_resetAfterSuccessfulExecution() public {
        // Miss 3 epochs
        fund.syncPhase();
        vm.warp(block.timestamp + EPOCH_DUR * 3);
        fund.syncPhase();
        assertEq(fund.consecutiveMissedEpochs(), 3);

        // Now successfully execute an epoch
        uint256 epoch = fund.currentEpoch();
        // Need to be within the commit window of the new epoch
        uint256 epochStart = fund.epochStartTime(epoch);
        vm.warp(epochStart); // ensure we're at the start
        fund.syncPhase(); // open auction for new epoch

        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("s1"));

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase(); // close reveal

        _submitAttestedResult(runner1, epoch);
        fund.syncPhase();

        assertEq(fund.consecutiveMissedEpochs(), 0);
        assertEq(fund.currentBond(), 0.01 ether);
    }

    function test_forfeit_incrementsMissed() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        vm.warp(block.timestamp + EXEC_WIN);
        fund.syncPhase();

        assertEq(fund.consecutiveMissedEpochs(), 1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 7: Seed & Input Hash
    // ═══════════════════════════════════════════════════════════════════════

    function test_seed_capturedOnRevealClose() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        assertTrue(am.getRandomnessSeed(1) != 0);
    }

    function test_inputHash_boundToSeed() public {
        bytes32 salt = bytes32("s1");
        _runAuctionTo(runner1, 0.005 ether, salt);

        uint256 seed = am.getRandomnessSeed(1);
        bytes32 baseHash = fund.epochBaseInputHashes(1);
        bytes32 expectedBound = keccak256(abi.encodePacked(baseHash, seed));

        assertEq(fund.epochInputHashes(1), expectedBound);
    }

    function test_baseInputHash_committedAtAuctionOpen() public {
        bytes32 expectedHash = fund.computeInputHash();
        fund.syncPhase();
        assertEq(fund.epochBaseInputHashes(1), expectedHash);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 8: Full Attestation Integration
    // ═══════════════════════════════════════════════════════════════════════

    function test_fullAuctionWithAttestation() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        _submitAttestedResult(runner1, 1);
        fund.syncPhase();

        assertEq(fund.currentEpoch(), 2);
        assertEq(fund.consecutiveMissedEpochs(), 0);
        assertTrue(fund.epochContentHashes(1) != bytes32(0));
    }

    function test_attestation_mismatch_reverts() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));

        AuctionMockDcapVerifier etchedMock = AuctionMockDcapVerifier(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F);
        etchedMock.setOutput(_buildDcapOutput(bytes32(uint256(0xdeadbeef))));
        etchedMock.setShouldSucceed(true);

        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.ProofFailed.selector);
        fund.submitAuctionResult(_noopAction(), bytes("test"), bytes("mock"), uint8(1), -1, "");
    }

    function test_nonWinner_cannotSubmit() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));

        vm.prank(runner2);
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.submitAuctionResult(_noopAction(), bytes("hax"), bytes("mock"), uint8(1), -1, "");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 9: Wall-Clock Timing
    // ═══════════════════════════════════════════════════════════════════════

    function test_wallClock_noDrift() public {
        uint256 anchor = fund.timingAnchor();

        // Epoch 1: start on time
        fund.syncPhase();
        assertEq(am.getStartTime(1), anchor);

        // Miss epoch 1 (0 commits)
        vm.warp(anchor + COMMIT_WIN);
        fund.syncPhase();

        // Epoch 2: start 30s late
        uint256 epoch2Scheduled = anchor + EPOCH_DUR;
        vm.warp(epoch2Scheduled + 30);
        fund.syncPhase();

        // Start time should be SCHEDULED, not late
        assertEq(am.getStartTime(2), epoch2Scheduled);
    }

    function test_lateStart_shortensCommitWindow() public {
        uint256 anchor = fund.timingAnchor();

        // Miss epoch 1
        fund.syncPhase();
        vm.warp(anchor + COMMIT_WIN);
        fund.syncPhase();

        // Start epoch 2 exactly 50s late (60s commit → 10s remaining)
        uint256 epoch2Start = anchor + EPOCH_DUR;
        vm.warp(epoch2Start + 50);
        fund.syncPhase();

        // Commit should still work (10s remaining)
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(0.005 ether, bytes32("s1")));

        // At the exact deadline, _syncPhase closes commit, then commit gets WrongPhase
        vm.warp(epoch2Start + COMMIT_WIN);
        vm.prank(runner2);
        vm.expectRevert(); // WrongPhase (commit phase has been auto-closed)
        fund.commit{value: bond}(_commitHash(0.003 ether, bytes32("s2")));
    }

    function test_epochStartTime_view() public view {
        uint256 anchor = fund.timingAnchor();
        assertEq(fund.epochStartTime(1), anchor);
        assertEq(fund.epochStartTime(2), anchor + EPOCH_DUR);
        assertEq(fund.epochStartTime(10), anchor + 9 * EPOCH_DUR);
    }

    function test_projectedEpoch() public {
        fund.syncPhase();
        vm.warp(block.timestamp + EPOCH_DUR * 3);
        // Contract thinks we're on epoch 1, but 3 epoch durations have passed
        assertEq(fund.projectedEpoch(), 4); // 1 + 3
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 10: Configuration & Edge Cases
    // ═══════════════════════════════════════════════════════════════════════

    function test_timing_validation() public {
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.setAuctionTiming(100, 40, 30, 40); // 110 > 100

        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.setAuctionTiming(100, 0, 30, 50);
    }

    function test_directSubmission_coexists() public {
        fund.submitEpochAction(_noopAction(), bytes("direct"), -1, "");
        fund.syncPhase();
        assertEq(fund.currentEpoch(), 2);
    }

    function test_sunset_blocksSyncPhase() public {
        fund.freeze(fund.FREEZE_SUNSET());
        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.syncPhase();
    }

    function test_sunset_blocksCommit() public {
        fund.syncPhase();
        fund.freeze(fund.FREEZE_SUNSET());

        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s1")));
    }

    function test_migrate_requiresNoActiveAuction() public {
        fund.syncPhase();
        fund.freeze(fund.FREEZE_SUNSET());

        vm.expectRevert(TheHumanFund.WrongPhase.selector);
        fund.migrate(address(0xBEEF));
    }

    function test_epochContentHashes_accumulate() public {
        fund.submitEpochAction(_noopAction(), bytes("First"), -1, "");
        fund.syncPhase();
        bytes32 hash1 = fund.epochContentHashes(1);
        assertTrue(hash1 != bytes32(0));

        fund.submitEpochAction(_noopAction(), bytes("Second"), -1, "");
        fund.syncPhase();
        bytes32 hash2 = fund.epochContentHashes(2);
        assertTrue(hash2 != bytes32(0));
        assertTrue(hash1 != hash2);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 11: Stale Auction Auto-Cleanup via syncPhase
    // ═══════════════════════════════════════════════════════════════════════

    function test_staleCommit_noCommits_cleaned() public {
        fund.syncPhase();
        vm.warp(block.timestamp + EPOCH_DUR);
        fund.syncPhase(); // auto-cleans stale COMMIT (0 commits → SETTLED), advances epoch

        assertEq(fund.currentEpoch(), 2);
        assertEq(uint256(am.getPhase(1)), uint256(IAuctionManager.AuctionPhase.SETTLED));
    }

    function test_staleCommit_withCommits_cleaned() public {
        fund.syncPhase();
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + EPOCH_DUR);
        fund.syncPhase(); // chains: COMMIT→REVEAL (1 commit), REVEAL→SETTLED (0 reveals)

        assertEq(fund.currentEpoch(), 2);
    }

    function test_staleExecution_cleaned() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        vm.warp(block.timestamp + EPOCH_DUR);

        uint256 treasuryBefore = address(fund).balance;
        fund.syncPhase();

        assertEq(fund.currentEpoch(), 2);
        assertGt(address(fund).balance, treasuryBefore); // forfeited bond
    }

    // ─── Fuzz Tests ────────────────────────────────────────────────────

    function test_equalBids_firstRevealerWins() public {
        fund.syncPhase();
        uint256 epoch = fund.currentEpoch();
        uint256 bond = fund.currentBond();
        uint256 bidAmount = 0.005 ether;

        // Both commit with the same bid amount
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(bidAmount, bytes32("salt1")));
        vm.prank(runner2);
        fund.commit{value: bond}(_commitHash(bidAmount, bytes32("salt2")));

        vm.warp(block.timestamp + COMMIT_WIN);

        // runner1 reveals first
        vm.prank(runner1);
        fund.reveal(bidAmount, bytes32("salt1"));

        // runner2 reveals second with same bid
        vm.prank(runner2);
        fund.reveal(bidAmount, bytes32("salt2"));

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase();

        // First revealer should win (strict less-than comparison)
        assertEq(am.getWinner(epoch), runner1);
        assertEq(am.getWinningBid(epoch), bidAmount);
    }

    function test_loser_claimsBond_afterReveal() public {
        fund.syncPhase();
        uint256 epoch = fund.currentEpoch();
        uint256 bond = fund.currentBond();

        // runner1 bids high, runner2 bids low (wins)
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(0.008 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: bond}(_commitHash(0.003 ether, bytes32("s2")));

        vm.warp(block.timestamp + COMMIT_WIN);

        vm.prank(runner1);
        fund.reveal(0.008 ether, bytes32("s1"));
        vm.prank(runner2);
        fund.reveal(0.003 ether, bytes32("s2"));

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase(); // closes reveal

        // runner2 wins
        assertEq(am.getWinner(epoch), runner2);

        // runner1 (loser) claims bond
        uint256 balBefore = runner1.balance;
        vm.prank(runner1);
        am.claimBond(epoch);
        assertEq(runner1.balance, balBefore + bond);

        // runner1 can't double-claim
        vm.prank(runner1);
        vm.expectRevert();
        am.claimBond(epoch);
    }

    function testFuzz_bondEscalation_neverOverflows(uint8 misses) public {
        // Skip epochs to build up consecutiveMissedEpochs
        uint256 n = bound(misses, 0, 50);
        for (uint256 i = 0; i < n; i++) {
            fund.skipEpoch();
        }
        assertEq(fund.consecutiveMissedEpochs(), n > 50 ? 50 : n);

        uint256 bond = fund.currentBond();
        uint256 maxBid = fund.effectiveMaxBid();

        // Bond should never exceed its own cap: max(MIN_BOND_CAP, 10% of treasury)
        uint256 treasuryBondCap = (address(fund).balance * 1000) / 10000;
        uint256 bondCap = treasuryBondCap > 1 ether ? treasuryBondCap : 1 ether;
        assertLe(bond, bondCap);
        // effectiveMaxBid should never exceed 2% of treasury
        uint256 hardCap = (address(fund).balance * 200) / 10000;
        assertLe(maxBid, hardCap);
        // Bond should always be >= BASE_BOND
        assertGe(bond, 0.01 ether);
    }

    function testFuzz_bidReveal_aboveMaxBid_reverts(uint256 bidAmount) public {
        uint256 maxBid = fund.effectiveMaxBid();
        bidAmount = bound(bidAmount, maxBid + 1, 100 ether);

        fund.syncPhase();
        uint256 bond = fund.currentBond();
        bytes32 salt = bytes32("fuzz_salt");

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(bidAmount, salt));

        vm.warp(block.timestamp + COMMIT_WIN);

        vm.prank(runner1);
        vm.expectRevert(); // InvalidBid or similar
        fund.reveal(bidAmount, salt);
    }

    function testFuzz_bidReveal_validRange(uint256 bidAmount) public {
        uint256 maxBid = fund.effectiveMaxBid();
        bidAmount = bound(bidAmount, 1, maxBid);

        fund.syncPhase();
        uint256 bond = fund.currentBond();
        bytes32 salt = bytes32("fuzz_valid");

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(bidAmount, salt));

        vm.warp(block.timestamp + COMMIT_WIN);

        vm.prank(runner1);
        fund.reveal(bidAmount, salt);

        // Verify the reveal was recorded
        assertTrue(am.didReveal(fund.currentEpoch(), runner1));
    }

    function testFuzz_epochArithmetic_O1advancement(uint8 missedCount) public {
        // Test that missing N epochs advances correctly in O(1)
        uint256 n = bound(missedCount, 1, 50);
        uint256 startEpoch = fund.currentEpoch();

        // Warp past N full epoch durations
        vm.warp(block.timestamp + EPOCH_DUR * n);
        fund.syncPhase();

        uint256 endEpoch = fund.currentEpoch();
        // Should have advanced by at least n epochs (may be n+1 if auction opens)
        assertGe(endEpoch, startEpoch + n);
    }

    function testFuzz_commitHash_preimage(uint256 bidAmount, bytes32 salt) public {
        // Verify commit hash is deterministic and matches reveal
        bidAmount = bound(bidAmount, 1, 10 ether);
        bytes32 hash = _commitHash(bidAmount, salt);

        // Same inputs produce same hash
        assertEq(hash, keccak256(abi.encodePacked(bidAmount, salt)));

        // Different bid produces different hash
        if (bidAmount > 1) {
            assertNotEq(hash, _commitHash(bidAmount - 1, salt));
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group: Epoch Snapshot — drift isolation
    // ═══════════════════════════════════════════════════════════════════════

    function test_snapshot_valuesMatchAtAuctionOpen() public {
        fund.syncPhase(); // opens auction for epoch 1
        TheHumanFund.EpochSnapshot memory snap = fund.getEpochSnapshot(1);

        assertEq(snap.balance, address(fund).balance);
        assertEq(snap.totalInflows, fund.totalInflows());
        assertEq(snap.currentEpochInflow, fund.currentEpochInflow());
        assertEq(snap.currentEpochDonationCount, fund.currentEpochDonationCount());
        assertEq(snap.messageHead, fund.messageHead());
    }

    function test_snapshot_donationDoesNotChangeBaseInputHash() public {
        fund.syncPhase(); // opens auction for epoch 1
        bytes32 hashBefore = fund.epochBaseInputHashes(1);

        // Donate after auction open
        vm.deal(address(0xDEAD), 1 ether);
        vm.prank(address(0xDEAD));
        fund.donate{value: 0.1 ether}(0);

        // baseInputHash must not have changed
        assertEq(fund.epochBaseInputHashes(1), hashBefore);
    }

    function test_snapshot_messageDoesNotChangeBaseInputHash() public {
        fund.syncPhase(); // opens auction for epoch 1
        bytes32 hashBefore = fund.epochBaseInputHashes(1);

        // Send message after auction open
        vm.deal(address(0xDEAD), 1 ether);
        vm.prank(address(0xDEAD));
        fund.donateWithMessage{value: 0.05 ether}(0, "hello after auction open");

        // baseInputHash must not have changed
        assertEq(fund.epochBaseInputHashes(1), hashBefore);
    }

    function test_snapshot_messageBoundariesFrozen() public {
        // Send a message BEFORE auction open
        vm.deal(address(0xDEAD), 2 ether);
        vm.prank(address(0xDEAD));
        fund.donateWithMessage{value: 0.05 ether}(0, "before auction");

        fund.syncPhase(); // opens auction for epoch 1
        TheHumanFund.EpochSnapshot memory snap = fund.getEpochSnapshot(1);

        // Snapshot should record 1 message
        assertEq(snap.messageCount, 1);
        assertEq(snap.messageHead, 0);

        // Send another message AFTER auction open
        vm.prank(address(0xDEAD));
        fund.donateWithMessage{value: 0.05 ether}(0, "after auction");

        // Snapshot should still show 1 message (frozen at auction open)
        TheHumanFund.EpochSnapshot memory snapAfter = fund.getEpochSnapshot(1);
        assertEq(snapAfter.messageCount, 1);
        assertEq(snapAfter.messageHead, 0);
    }

    function test_snapshot_scalarsFrozenAfterDonation() public {
        fund.syncPhase(); // opens auction for epoch 1
        TheHumanFund.EpochSnapshot memory snapBefore = fund.getEpochSnapshot(1);

        // Donate after auction open — changes live state but not snapshot
        vm.deal(address(0xDEAD), 1 ether);
        vm.prank(address(0xDEAD));
        fund.donate{value: 0.5 ether}(0);

        TheHumanFund.EpochSnapshot memory snapAfter = fund.getEpochSnapshot(1);

        // Snapshot values must be identical
        assertEq(snapAfter.balance, snapBefore.balance);
        assertEq(snapAfter.totalInflows, snapBefore.totalInflows);
        assertEq(snapAfter.currentEpochInflow, snapBefore.currentEpochInflow);
        assertEq(snapAfter.currentEpochDonationCount, snapBefore.currentEpochDonationCount);

        // But live state has changed
        assertGt(address(fund).balance, snapAfter.balance);
    }

    function test_snapshot_multiEpoch_independentSnapshots() public {
        // Epoch 1: open auction, donate, complete epoch
        fund.syncPhase();
        TheHumanFund.EpochSnapshot memory snap1 = fund.getEpochSnapshot(1);

        vm.deal(address(0xDEAD), 5 ether);
        vm.prank(address(0xDEAD));
        fund.donate{value: 0.5 ether}(0);

        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        _submitAttestedResult(runner1, 1);

        // Warp to epoch 2's scheduled start so syncPhase opens the next auction
        vm.warp(fund.epochStartTime(2));
        fund.syncPhase(); // advances to epoch 2, opens auction
        TheHumanFund.EpochSnapshot memory snap2 = fund.getEpochSnapshot(2);

        // Epoch 2 snapshot should differ from epoch 1 (donation + bounty changed state)
        assertGt(snap2.totalInflows, snap1.totalInflows);

        // Epoch 1 snapshot should be unchanged (frozen)
        TheHumanFund.EpochSnapshot memory snap1After = fund.getEpochSnapshot(1);
        assertEq(snap1After.balance, snap1.balance);
        assertEq(snap1After.totalInflows, snap1.totalInflows);
    }

    function test_snapshot_multiEpoch_messagesAdvanceCorrectly() public {
        // Send message before epoch 1
        vm.deal(address(0xDEAD), 5 ether);
        vm.prank(address(0xDEAD));
        fund.donateWithMessage{value: 0.05 ether}(0, "msg for epoch 1");

        // Epoch 1: auction open, snapshot should see 1 message
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        TheHumanFund.EpochSnapshot memory snap1 = fund.getEpochSnapshot(1);
        assertEq(snap1.messageCount, 1);
        assertEq(snap1.messageHead, 0);

        // Execute epoch 1 — messageHead advances past the processed message
        _submitAttestedResult(runner1, 1);

        // Send another message before epoch 2
        vm.prank(address(0xDEAD));
        fund.donateWithMessage{value: 0.05 ether}(0, "msg for epoch 2");

        // Warp to epoch 2's scheduled start
        vm.warp(fund.epochStartTime(2));
        fund.syncPhase();
        TheHumanFund.EpochSnapshot memory snap2 = fund.getEpochSnapshot(2);

        // Epoch 2 snapshot: messageHead should have advanced, new message visible
        assertEq(snap2.messageHead, 1); // epoch 1 consumed message 0
        assertEq(snap2.messageCount, 2); // 2 total messages, head=1 means 1 unread
    }

    function test_snapshot_multiEpoch_donationBetweenEpochs() public {
        // Epoch 1
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        TheHumanFund.EpochSnapshot memory snap1 = fund.getEpochSnapshot(1);
        _submitAttestedResult(runner1, 1);

        // Donate between epochs (after epoch 1 execution, before epoch 2 auction open)
        vm.deal(address(0xDEAD), 5 ether);
        vm.prank(address(0xDEAD));
        fund.donate{value: 1 ether}(0);

        // Warp to epoch 2's scheduled start
        vm.warp(fund.epochStartTime(2));
        fund.syncPhase();
        TheHumanFund.EpochSnapshot memory snap2 = fund.getEpochSnapshot(2);

        // Epoch 2 snapshot should include the donation in its balance
        // (donation happened before auction open, so it's part of the frozen state)
        assertGt(snap2.balance, snap1.balance);

        // Donate AFTER epoch 2 auction open
        vm.prank(address(0xDEAD));
        fund.donate{value: 0.5 ether}(0);

        // Epoch 2 snapshot should NOT have changed
        TheHumanFund.EpochSnapshot memory snap2After = fund.getEpochSnapshot(2);
        assertEq(snap2After.balance, snap2.balance);

        // But live balance should be higher
        assertGt(address(fund).balance, snap2.balance);
    }
}
