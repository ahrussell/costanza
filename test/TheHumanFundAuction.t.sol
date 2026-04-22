// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
import "../src/TdxVerifier.sol";
import "../src/interfaces/IAutomataDcapAttestation.sol";
import "./helpers/EpochTest.sol";

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

/// @title V3 Auction tests — 3-phase cyclic state machine (COMMIT / REVEAL / EXECUTION).
///        Epoch 1's auction is eagerly opened at the end of setAuctionManager, so tests
///        enter their bodies already in COMMIT of epoch 1.
contract TheHumanFundAuctionTest is EpochTest {
    TheHumanFund public fund;
    AuctionManager public am;
    TdxVerifier public verifier;
    AuctionMockDcapVerifier public mockDcap;

    address runner1 = address(0x4001);
    address runner2 = address(0x4002);
    address runner3 = address(0x4003);

    // Short testnet timing — epoch duration is derived from the sum.
    uint256 constant COMMIT_WIN = 60;     // 1 minute commit
    uint256 constant REVEAL_WIN = 30;     // 30 seconds reveal
    uint256 constant EXEC_WIN = 210;      // 3.5 minute execution
    uint256 constant EPOCH_DUR = COMMIT_WIN + REVEAL_WIN + EXEC_WIN; // 300 (5 min)

    // Test measurement values (48 bytes each, SHA-384)
    bytes constant TEST_MRTD  = hex"aabbccdd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000011";
    bytes constant TEST_RTMR1 = hex"222222220000000000000000000000000000000000000000000000000000000000000000000000000000000000000033";
    bytes constant TEST_RTMR2 = hex"333333330000000000000000000000000000000000000000000000000000000000000000000000000000000000000044";
    bytes constant TEST_RTMR3 = hex"444444440000000000000000000000000000000000000000000000000000000000000000000000000000000000000055";

    function setUp() public {
        fund = new TheHumanFund{value: 10 ether}(
            1000, 0.01 ether,
            address(0xBEEF), address(0)
        );

        am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am), COMMIT_WIN, REVEAL_WIN, EXEC_WIN);

        fund.addNonprofit("GiveDirectly", "Cash transfers", bytes32("EIN-GD"));
        fund.addNonprofit("Against Malaria Foundation", "Malaria prevention", bytes32("EIN-AMF"));
        fund.addNonprofit("Helen Keller International", "NTDs", bytes32("EIN-HKI"));

        mockDcap = new AuctionMockDcapVerifier();
        verifier = new TdxVerifier(address(fund));
        vm.etch(address(0x95175096a9B74165BE0ac84260cc14Fc1c0EF5FF), address(mockDcap).code);

        bytes32 imageKey = sha256(abi.encodePacked(TEST_MRTD, TEST_RTMR1, TEST_RTMR2));
        verifier.approveImage(imageKey);
        fund.approveVerifier(1, address(verifier));

        vm.deal(runner1, 10 ether);
        vm.deal(runner2, 10 ether);
        vm.deal(runner3, 10 ether);
        _registerMockVerifier(fund);
        // Epoch 1 auction is already in COMMIT phase — opened by setAuctionManager.
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    function _doNothingAction() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0));
    }

    function _commitHash(address runner, uint256 bidAmount, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(runner, bidAmount, salt));
    }

    /// @dev Read the executed bit off an epoch record. `fund.epochs(e)` returns
    ///      a raw tuple from the public mapping, so we can't use struct field
    ///      access — `getEpochRecord` gives us a named destructure.
    function _executed(uint256 epoch) internal view returns (bool) {
        ( , , , , , , bool ex) = fund.getEpochRecord(epoch);
        return ex;
    }

    /// @dev Run a full commit-reveal cycle for the currently-open auction:
    ///      commit → warp → reveal (auto-closes commit) → warp → syncPhase (closes reveal, captures seed)
    function _runAuctionTo(address runner, uint256 bidAmount, bytes32 salt) internal {
        // Auction for currentEpoch is already open (COMMIT phase).
        uint256 bond = fund.currentBond();
        vm.prank(runner);
        fund.commit{value: bond}(_commitHash(runner, bidAmount, salt));

        vm.warp(block.timestamp + COMMIT_WIN); // advance past commit window

        vm.prank(runner);
        fund.reveal(bidAmount, salt); // auto-closes commit via _syncPhase

        vm.warp(block.timestamp + REVEAL_WIN); // advance past reveal window
        fund.syncPhase(); // closes reveal, captures seed, binds input hash
    }

    function _buildDcapOutput(bytes32 reportData) internal pure returns (bytes memory) {
        // Matches the real Automata DCAP v1.0 output layout (see TdxVerifier.sol):
        // the +2 shift vs a textbook TD10ReportBody comes from the Output envelope
        // Automata prepends (quoteVersion + teeType).
        bytes memory output = new bytes(597);
        output[0] = 0x00; output[1] = 0x04;
        output[2] = 0x00; output[3] = 0x02;
        for (uint256 i = 0; i < 48; i++) {
            output[149 + i] = TEST_MRTD[i];
            output[389 + i] = TEST_RTMR1[i];
            output[437 + i] = TEST_RTMR2[i];
            output[485 + i] = TEST_RTMR3[i];
        }
        for (uint256 i = 0; i < 32; i++) {
            output[533 + i] = reportData[i];
        }
        return output;
    }

    function _submitAttestedResult(address runner, uint256 epoch) internal {
        bytes32 inputHash = fund.epochInputHashes(epoch);
        bytes memory action = _doNothingAction();
        bytes memory reasoning = bytes("The fund is conserving resources.");
        IAgentMemory.MemoryUpdate[] memory updates = _emptyUpdates();
        // outputHash now binds the memory update batch in addition to
        // action + reasoning — see _computeOutputHash in TheHumanFund.sol.
        bytes32 outputHash = fund.computeOutputHash(action, reasoning, updates);
        bytes32 expectedReportData = sha256(abi.encodePacked(inputHash, outputHash));

        AuctionMockDcapVerifier etchedMock = AuctionMockDcapVerifier(0x95175096a9B74165BE0ac84260cc14Fc1c0EF5FF);
        etchedMock.setOutput(_buildDcapOutput(expectedReportData));
        etchedMock.setShouldSucceed(true);

        vm.prank(runner);
        fund.submitAuctionResult(action, reasoning, bytes("mock_quote"), uint8(1), updates);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 1: Auto-Advancement via syncPhase
    // ═══════════════════════════════════════════════════════════════════════

    function test_setup_eagerlyOpensEpoch1() public view {
        // setUp already called setAuctionManager, which opens epoch 1 in COMMIT.
        assertEq(fund.currentAuctionStartTime(), block.timestamp);
        assertEq(uint256(am.phase()), uint256(IAuctionManager.AuctionPhase.COMMIT));
        assertEq(am.bond(), 0.001 ether);
    }

    function test_syncPhase_idempotent() public {
        // Epoch 1 COMMIT already open from setUp.
        uint256 epoch1 = fund.currentEpoch();
        fund.syncPhase(); // should be no-op
        assertEq(fund.currentEpoch(), epoch1);
        assertEq(uint256(am.phase()), uint256(IAuctionManager.AuctionPhase.COMMIT));
    }

    function test_syncPhase_closesCommit() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        fund.syncPhase(); // should close commit → REVEAL

        assertEq(uint256(am.phase()), uint256(IAuctionManager.AuctionPhase.REVEAL));
    }

    function test_syncPhase_closesReveal_capturesSeed() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("s1"));

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase(); // should close reveal → EXECUTION, capture seed

        assertEq(uint256(am.phase()), uint256(IAuctionManager.AuctionPhase.EXECUTION));
        assertTrue(fund.epochSeeds(1) != 0);
        assertTrue(fund.epochInputHashes(1) != bytes32(0));
    }

    function test_syncPhase_forfeitsExpiredExecution() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        uint256 treasuryBefore = fund.treasuryBalance();

        vm.warp(block.timestamp + EXEC_WIN);
        fund.syncPhase(); // should forfeit winner bond and advance to next epoch

        assertEq(fund.treasuryBalance(), treasuryBefore + 0.001 ether);
        assertEq(fund.consecutiveMissedEpochs(), 1);
        assertEq(fund.currentEpoch(), 2);
        assertFalse(_executed(1));
    }

    function test_syncPhase_multipleTransitions() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("s1")));

        // Warp past commit + reveal + execution windows
        vm.warp(block.timestamp + COMMIT_WIN + REVEAL_WIN + EXEC_WIN);
        fund.syncPhase();

        // No reveals means REVEAL resolves with no winner, then EXECUTION times out,
        // so epoch 1 was not executed and we've advanced to epoch 2.
        assertEq(fund.currentEpoch(), 2);
        assertFalse(_executed(1));
    }

    function test_syncPhase_chainsFullCycleWithReveals() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("s1"));

        // Warp past reveal + execution (execution window expires → forfeit)
        vm.warp(block.timestamp + REVEAL_WIN + EXEC_WIN);
        uint256 treasuryBefore = fund.treasuryBalance();
        fund.syncPhase();

        // Should chain: REVEAL→EXECUTION→close (forfeit, advance to next epoch's COMMIT)
        assertEq(fund.currentEpoch(), 2);
        assertGt(fund.treasuryBalance(), treasuryBefore); // winner's bond forfeited
        assertTrue(fund.epochInputHashes(1) != bytes32(0)); // seed was bound
        assertFalse(_executed(1));
    }

    function test_syncPhase_noCommits_missesEpoch() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.warp(block.timestamp + EPOCH_DUR);
        fund.syncPhase(); // closes empty epoch 1 → advances to 2

        // Epoch should advance
        assertEq(fund.currentEpoch(), 2);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 2: Auto-Advancing Actions (commit/reveal/submit auto-sync)
    // ═══════════════════════════════════════════════════════════════════════

    function test_commit_worksInOpenEpoch() public {
        // Epoch 1 COMMIT already open from setUp — no separate open step needed.
        uint256 bond = 0.01 ether; // BASE_BOND
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("s1")));

        assertEq(uint256(am.phase()), uint256(IAuctionManager.AuctionPhase.COMMIT));
        assertEq(am.getCommitters().length, 1);
    }

    function test_reveal_autoClosesCommit() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);

        // reveal() auto-closes commit via _syncPhase
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("s1"));

        assertEq(am.winner(), runner1);
    }

    function test_submit_marksEpochExecuted() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("s1"));

        vm.warp(block.timestamp + REVEAL_WIN);
        // Call syncPhase first to close reveal and bind the input hash,
        // so the test helper can read epochInputHashes to build the proof.
        fund.syncPhase();

        _submitAttestedResult(runner1, 1);

        // Post-submit: AM transitions to SETTLED, epoch flagged executed.
        assertTrue(_executed(1));
        assertEq(fund.consecutiveMissedEpochs(), 0);
        assertEq(uint256(am.phase()), uint256(IAuctionManager.AuctionPhase.SETTLED));
    }

    function test_commit_afterWindow_reverts() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.warp(block.timestamp + COMMIT_WIN);

        // _syncPhase closes commit → REVEAL, so commit now reverts
        vm.prank(runner1);
        vm.expectRevert(); // WrongPhase or similar
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("s1")));
    }

    function test_reveal_beforeCommitWindow_reverts() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("s1")));

        // Still in commit window — _syncPhase won't advance, reveal gets WrongPhase
        vm.prank(runner1);
        vm.expectRevert(AuctionManager.WrongPhase.selector);
        fund.reveal(0.005 ether, bytes32("s1"));
    }

    function test_reveal_afterRevealWindow_reverts() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("s1")));

        // Warp past both commit AND reveal windows.
        vm.warp(block.timestamp + COMMIT_WIN + REVEAL_WIN);

        vm.prank(runner1);
        vm.expectRevert(); // Phase has been auto-advanced past REVEAL
        fund.reveal(0.005 ether, bytes32("s1"));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 3: Commit Phase
    // ═══════════════════════════════════════════════════════════════════════

    function test_single_commit() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("salt1")));
        assertEq(am.getCommitters().length, 1);
    }

    function test_commit_requires_bond() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.commit{value: 0.0005 ether}(_commitHash(runner1, 0.005 ether, bytes32("salt1")));
    }

    function test_commit_refunds_excess() public {
        // Epoch 1 COMMIT already open from setUp.
        uint256 balBefore = runner1.balance;
        vm.prank(runner1);
        fund.commit{value: 0.05 ether}(_commitHash(runner1, 0.005 ether, bytes32("salt1")));
        assertEq(runner1.balance, balBefore - 0.001 ether);
    }

    function test_duplicate_commit_rejected() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("salt1")));
        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.AlreadyDone.selector);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.003 ether, bytes32("salt2")));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 4: Reveal Phase
    // ═══════════════════════════════════════════════════════════════════════

    function test_single_reveal() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("s1"));

        assertEq(am.winner(), runner1);
        assertEq(am.winningBid(), 0.005 ether);
    }

    function test_lowest_reveal_wins() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.008 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: 0.01 ether}(_commitHash(runner2, 0.005 ether, bytes32("s2")));
        vm.prank(runner3);
        fund.commit{value: 0.01 ether}(_commitHash(runner3, 0.009 ether, bytes32("s3")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.008 ether, bytes32("s1"));
        vm.prank(runner2);
        fund.reveal(0.005 ether, bytes32("s2"));
        vm.prank(runner3);
        fund.reveal(0.009 ether, bytes32("s3"));

        assertEq(am.winner(), runner2);
        assertEq(am.winningBid(), 0.005 ether);
    }

    function test_wrong_hash_reveal_reverts() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("salt1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.reveal(0.003 ether, bytes32("salt1"));
    }

    function test_reveal_without_commit_reverts() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner2);
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.reveal(0.005 ether, bytes32("s1"));
    }

    function test_duplicate_reveal_reverts() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("s1"));
        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.AlreadyDone.selector);
        fund.reveal(0.005 ether, bytes32("s1"));
    }

    function test_reveal_bid_above_ceiling_rejected() public {
        // Epoch 1 COMMIT already open from setUp.
        bytes32 salt = bytes32("salt1");
        uint256 tooHigh = 0.02 ether;
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, tooHigh, salt));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.reveal(tooHigh, salt);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 5: Lazy Bond Claiming
    // ═══════════════════════════════════════════════════════════════════════

    function test_claimBond_nonWinnerRevealer() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.008 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: 0.01 ether}(_commitHash(runner2, 0.005 ether, bytes32("s2")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.008 ether, bytes32("s1"));
        vm.prank(runner2);
        fund.reveal(0.005 ether, bytes32("s2"));

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase(); // closes reveal — runner2 wins, runner1 can claim

        assertEq(am.pendingBondRefunds(), 0.001 ether); // runner1's bond

        uint256 runner1BalBefore = runner1.balance;
        vm.prank(runner1);
        am.claimBond(1);

        assertEq(runner1.balance, runner1BalBefore + 0.001 ether);
        assertEq(am.pendingBondRefunds(), 0);
    }

    function test_claimBond_doubleClaim_reverts() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.008 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: 0.01 ether}(_commitHash(runner2, 0.005 ether, bytes32("s2")));

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
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: 0.01 ether}(_commitHash(runner2, 0.003 ether, bytes32("s2")));

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
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.008 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: 0.01 ether}(_commitHash(runner2, 0.005 ether, bytes32("s2")));

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
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: 0.01 ether}(_commitHash(runner2, 0.003 ether, bytes32("s2")));

        vm.warp(block.timestamp + COMMIT_WIN);
        // Only runner2 reveals
        vm.prank(runner2);
        fund.reveal(0.003 ether, bytes32("s2"));

        uint256 fundBalBefore = address(fund).balance;

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase();

        // runner1's bond (non-revealer) should be sent to fund treasury
        assertEq(address(fund).balance, fundBalBefore + 0.001 ether);
        // Only runner2's winner bond is pending (held for execution)
        assertEq(am.pendingBondRefunds(), 0); // no non-winning revealers (runner2 is winner)
    }

    function test_pendingBondRefunds_accounting_threeProvers() public {
        // Epoch 1 COMMIT already open from setUp.
        // 3 commit, 2 reveal, runner3 wins (lowest bid)
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.008 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: 0.01 ether}(_commitHash(runner2, 0.006 ether, bytes32("s2")));
        vm.prank(runner3);
        fund.commit{value: 0.01 ether}(_commitHash(runner3, 0.004 ether, bytes32("s3")));

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
        assertEq(address(fund).balance, fundBalBefore + 0.001 ether);
        // runner1 (non-winning revealer): bond is pending
        assertEq(am.pendingBondRefunds(), 0.001 ether);
        // runner3 (winner): bond held until settle/forfeit
    }

    function test_noReveals_allBondsForfeited() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: 0.01 ether}(_commitHash(runner2, 0.003 ether, bytes32("s2")));

        vm.warp(block.timestamp + COMMIT_WIN + REVEAL_WIN);
        uint256 fundBalBefore = address(fund).balance;
        fund.syncPhase(); // closes commit → REVEAL (2 commits), closes reveal (0 reveals)

        // All bonds forfeited to fund (2 bonds × 0.001 ETH)
        assertEq(address(fund).balance, fundBalBefore + 0.002 ether);
        assertEq(am.pendingBondRefunds(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 6: Missed Epoch Advancement (O(1))
    // ═══════════════════════════════════════════════════════════════════════

    function test_missedEpochs_O1_arithmetic() public {
        // Epoch 1 COMMIT already open from setUp. Nobody commits. Warp past 5 full epoch durations.
        vm.warp(block.timestamp + EPOCH_DUR * 5);

        fund.syncPhase();

        assertEq(fund.consecutiveMissedEpochs(), 5);
        assertEq(fund.currentEpoch(), 6);
    }

    function test_missedEpochs_capsAtMax() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.warp(block.timestamp + EPOCH_DUR * 100);
        fund.syncPhase();

        assertEq(fund.consecutiveMissedEpochs(), 50); // MAX_MISSED_EPOCHS
    }

    /// Missed epochs escalate the MAX BID (to attract bidders) but
    /// NOT the bond (which would discourage participation). Bond only
    /// escalates on winner-forfeit — see `test_winnerForfeit_bondEscalates`.
    function test_missedEpochs_escalateMaxBidButNotBond() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.warp(block.timestamp + EPOCH_DUR * 3);
        fund.syncPhase();

        assertEq(fund.consecutiveMissedEpochs(), 3);
        assertEq(fund.currentBond(), 0.001 ether, "bond unchanged during silence");
        assertEq(fund.effectiveMaxBid(), 0.01331 ether, "max bid escalated 0.01 * 1.1^3");
    }

    /// Winner-committed-and-forfeited escalates the bond by 10%.
    /// Silent epochs around it don't add to the escalation — only
    /// the forfeit itself does.
    function test_winnerForfeit_bondEscalates() public {
        uint256 bondBefore = fund.currentBond();

        // Run a full commit-reveal cycle, then let the execution window
        // expire without submitting → winner forfeit.
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        assertEq(uint256(am.phase()), uint256(IAuctionManager.AuctionPhase.EXECUTION));
        vm.warp(block.timestamp + EXEC_WIN + 1);
        fund.syncPhase();

        // Bond escalated by exactly 10%.
        uint256 expected = bondBefore + (bondBefore * 1000) / 10000;
        assertEq(fund.currentBond(), expected, "bond +10% after winner forfeit");
    }

    function test_missedEpochs_resetAfterSuccessfulExecution() public {
        // Epoch 1 COMMIT already open from setUp. Miss 3 epochs.
        vm.warp(block.timestamp + EPOCH_DUR * 3);
        fund.syncPhase();
        assertEq(fund.consecutiveMissedEpochs(), 3);

        // Now successfully execute an epoch
        uint256 epoch = fund.currentEpoch();
        // syncPhase after missed-epoch fast-forward should have left us in the
        // new epoch's COMMIT window (wall-clock landed at its start).
        assertEq(uint256(am.phase()), uint256(IAuctionManager.AuctionPhase.COMMIT));

        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("s1"));

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase(); // close reveal

        _submitAttestedResult(runner1, epoch);
        assertTrue(_executed(epoch));

        // Counters reset at epoch END (in _closeExecution), not mid-epoch.
        // Advance past the execution deadline so syncPhase triggers the close.
        vm.warp(block.timestamp + EXEC_WIN);
        fund.syncPhase();

        assertEq(fund.consecutiveMissedEpochs(), 0);
        assertEq(fund.currentBond(), 0.001 ether);
    }

    function test_forfeit_incrementsMissed() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        vm.warp(block.timestamp + EXEC_WIN);
        fund.syncPhase();

        assertEq(fund.consecutiveMissedEpochs(), 1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 6b: _syncPhase regression tests
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Issue #3 repro: winner committed+revealed but never submitted.
    ///      Wall-clock advances multiple epochs past the execution deadline.
    ///      syncPhase() must not revert and must end up in the correct epoch.
    function test_syncPhase_afterWinnerForfeitThenSkipIntoCommitWindow() public {
        // Epoch 1: full commit+reveal cycle, winner picked, but no submission.
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        assertEq(uint256(am.phase()), uint256(IAuctionManager.AuctionPhase.EXECUTION));

        // Land inside epoch 6's commit window (5 full epochs after epoch 1).
        vm.warp(fund.epochStartTime(6) + 1);

        fund.syncPhase();

        // Epoch 1 should be forfeited, currentEpoch advanced to 6, and a
        // fresh auction opened for epoch 6. 1 forfeit + 4 missed = 5.
        assertEq(fund.currentEpoch(), 6);
        assertEq(fund.consecutiveMissedEpochs(), 5);
        assertEq(uint256(am.phase()), uint256(IAuctionManager.AuctionPhase.COMMIT));
    }

    /// @dev Issue #3 variant: forfeit+skip when the wall-clock lands OUTSIDE
    ///      the new epoch's commit window. Must advance epoch but must NOT
    ///      open a fresh auction for the landed-in epoch (and must not revert).
    function test_syncPhase_afterWinnerForfeitThenSkipOutsideCommitWindow() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));

        // Land in epoch 6's REVEAL window (past commit window).
        vm.warp(fund.epochStartTime(6) + COMMIT_WIN + 1);

        fund.syncPhase();

        assertEq(fund.currentEpoch(), 6);
        assertEq(fund.consecutiveMissedEpochs(), 5);
        // Epoch 6's commit window was already past — the auction opened and
        // cascaded past COMMIT. AM phase for the current epoch must not be COMMIT.
        assertTrue(
            am.phase() != IAuctionManager.AuctionPhase.COMMIT,
            "must not be in epoch 6 COMMIT after its window elapsed"
        );
    }

    /// @dev syncPhase should be safely repeatable from any state without
    ///      changing anything between back-to-back calls.
    function test_syncPhase_repeatedCallsAreNoop() public {
        // Fully elapsed, deep skip.
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        vm.warp(block.timestamp + EXEC_WIN + EPOCH_DUR * 3);

        fund.syncPhase();
        uint256 epochAfter = fund.currentEpoch();
        uint256 missedAfter = fund.consecutiveMissedEpochs();
        IAuctionManager.AuctionPhase phaseAfter = am.phase();

        // 4 more calls — nothing should change.
        for (uint256 i = 0; i < 4; i++) {
            fund.syncPhase();
            assertEq(fund.currentEpoch(), epochAfter);
            assertEq(fund.consecutiveMissedEpochs(), missedAfter);
            assertEq(uint256(am.phase()), uint256(phaseAfter));
        }
    }

    /// @dev After a no-commit elapsed epoch, the very next epoch's commit
    ///      window should still be openable for normal participation.
    function test_syncPhase_afterNoCommitEpochNextEpochUsable() public {
        // Epoch 1 COMMIT already open from setUp. Nobody commits, epoch elapses.
        vm.warp(block.timestamp + EPOCH_DUR);
        fund.syncPhase();

        // Now in epoch 2's commit window — runner should be able to commit.
        assertEq(fund.currentEpoch(), 2);
        assertEq(uint256(am.phase()), uint256(IAuctionManager.AuctionPhase.COMMIT));

        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("s2")));

        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("s2"));

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase();
        assertTrue(fund.epochSeeds(2) != 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 7: Seed & Input Hash
    // ═══════════════════════════════════════════════════════════════════════

    function test_seed_capturedOnRevealClose() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        assertTrue(fund.epochSeeds(1) != 0);
    }

    function test_inputHash_boundToSeed() public {
        bytes32 salt = bytes32("s1");
        _runAuctionTo(runner1, 0.005 ether, salt);

        uint256 seed = fund.epochSeeds(1);
        bytes32 baseHash = fund.epochBaseInputHashes(1);
        bytes32 expectedBound = keccak256(abi.encodePacked(baseHash, seed));

        assertEq(fund.epochInputHashes(1), expectedBound);
    }

    function test_baseInputHash_committedAtAuctionOpen() public view {
        // Epoch 1 already opened by setUp. After _openAuction populates the snapshot, the
        // computeInputHash() view reads from the same snapshot and must match the stored
        // baseInputHash byte-for-byte. (Calling computeInputHash() BEFORE
        // opening the auction would hash against an empty snapshot and
        // return a different value — that's expected because the snapshot
        // is the frozen source of truth for every drifting field.)
        assertEq(fund.epochBaseInputHashes(1), fund.computeInputHash());
    }

    // test_baseInputHash_unchangedByMidEpochSetAuctionTiming removed —
    // `setAuctionTiming` no longer exists. The only timing-change path
    // is `resetAuction`, which aborts the in-flight auction atomically;
    // mid-epoch drift is impossible by construction, not by this
    // regression test. See `test_resetAuction_changesAuctionTiming` in
    // AuctionInvariants.t.sol for the positive coverage.

    // ═══════════════════════════════════════════════════════════════════════
    // Group 8: Full Attestation Integration
    // ═══════════════════════════════════════════════════════════════════════

    function test_fullAuctionWithAttestation() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        _submitAttestedResult(runner1, 1);

        assertTrue(_executed(1));
        assertEq(fund.consecutiveMissedEpochs(), 0);
        assertTrue(fund.epochContentHashes(1) != bytes32(0));
    }

    function test_attestation_mismatch_reverts() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));

        AuctionMockDcapVerifier etchedMock = AuctionMockDcapVerifier(0x95175096a9B74165BE0ac84260cc14Fc1c0EF5FF);
        etchedMock.setOutput(_buildDcapOutput(bytes32(uint256(0xdeadbeef))));
        etchedMock.setShouldSucceed(true);

        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.ProofFailed.selector);
        fund.submitAuctionResult(_doNothingAction(), bytes("test"), bytes("mock"), uint8(1), _emptyUpdates());
    }

    function test_nonWinner_cannotSubmit() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));

        vm.prank(runner2);
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.submitAuctionResult(_doNothingAction(), bytes("hax"), bytes("mock"), uint8(1), _emptyUpdates());
    }

    function test_submit_twice_reverts() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        _submitAttestedResult(runner1, 1);
        assertTrue(_executed(1));

        // Second submit (while still in EXECUTION phase) must revert via
        // the epochs[epoch].executed guard at the top of submitAuctionResult.
        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.AlreadyDone.selector);
        fund.submitAuctionResult(_doNothingAction(), bytes("again"), bytes("mock"), uint8(1), _emptyUpdates());
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 9: Wall-Clock Timing
    // ═══════════════════════════════════════════════════════════════════════

    function test_wallClock_noDrift() public {
        uint256 anchor = fund.timingAnchor();

        // Epoch 1 auction already opened at anchor by setUp.
        assertEq(fund.currentAuctionStartTime(), anchor);

        // Miss epoch 1 (0 commits)
        vm.warp(anchor + COMMIT_WIN);
        fund.syncPhase();

        // Epoch 2: start 30s late
        uint256 epoch2Scheduled = anchor + EPOCH_DUR;
        vm.warp(epoch2Scheduled + 30);
        fund.syncPhase();

        // Start time should be SCHEDULED, not late
        assertEq(fund.currentAuctionStartTime(), epoch2Scheduled);
    }

    function test_lateStart_shortensCommitWindow() public {
        uint256 anchor = fund.timingAnchor();

        // Miss epoch 1 (epoch 1 already open from setUp, just let it elapse).
        vm.warp(anchor + COMMIT_WIN);
        fund.syncPhase();

        // Start epoch 2 exactly 50s late (60s commit → 10s remaining)
        uint256 epoch2Start = anchor + EPOCH_DUR;
        vm.warp(epoch2Start + 50);
        fund.syncPhase();

        // Commit should still work (10s remaining)
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("s1")));

        // At the exact deadline, _syncPhase closes commit, then commit gets WrongPhase
        vm.warp(epoch2Start + COMMIT_WIN);
        vm.prank(runner2);
        vm.expectRevert(); // WrongPhase (commit phase has been auto-closed)
        fund.commit{value: bond}(_commitHash(runner2, 0.003 ether, bytes32("s2")));
    }

    function test_epochStartTime_view() public view {
        uint256 anchor = fund.timingAnchor();
        assertEq(fund.epochStartTime(1), anchor);
        assertEq(fund.epochStartTime(2), anchor + EPOCH_DUR);
        assertEq(fund.epochStartTime(10), anchor + 9 * EPOCH_DUR);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 10: Configuration & Edge Cases
    // ═══════════════════════════════════════════════════════════════════════

    function test_timing_validation() public {
        // resetAuction rejects zero-duration phases.
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.resetAuction(0, 30, 50);

        // setAuctionManager rejects zero-duration phases too.
        AuctionManager freshAm = new AuctionManager(address(fund));
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.setAuctionManager(address(freshAm), 0, 30, 50);
    }

    /// @dev syncPhase() is intentionally NOT sunset-gated so that in-flight
    ///      auctions can still be drained during sunset (so migrate() can
    ///      run without waiting on timeouts).
    function test_sunset_allowsSyncPhase() public {
        fund.freeze(fund.FREEZE_SUNSET());
        // Must not revert.
        fund.syncPhase();
    }

    function test_sunset_blocksCommit() public {
        // Epoch 1 COMMIT already open from setUp.
        fund.freeze(fund.FREEZE_SUNSET());

        vm.prank(runner1);
        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("s1")));
    }

    /// @dev migrate() is phase-agnostic: it calls `_resetAuction` (which
    ///      refunds in-flight bonds non-confiscatorily — invariant I3) and
    ///      then withdraws. No pre-draining required.
    function test_migrate_midAuction_refundsCommitters() public {
        // Epoch 1 COMMIT already open from setUp.
        uint256 bond = fund.currentBond();

        // runner1 commits — bond is held by the AuctionManager.
        uint256 runner1Before = runner1.balance;
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("s1")));
        assertEq(runner1.balance, runner1Before - bond);

        // Owner sunsets then migrates mid-COMMIT.
        fund.freeze(fund.FREEZE_SUNSET());
        uint256 destBefore = address(0xBEEF).balance;
        fund.migrate(address(0xBEEF));

        // runner1's bond is refunded (not forfeited to the destination).
        assertEq(runner1.balance, runner1Before, "committer bond refunded");
        assertGt(address(0xBEEF).balance, destBefore, "migration sent funds");
    }

    /// @dev Regression: migrate() works even with an in-flight auction deep
    ///      in EXECUTION phase. `_resetAuction` handles the refund; no
    ///      drain-to-SETTLED dance needed.
    function test_sunset_midAuction_canDrainAndMigrate() public {
        // Epoch 1 COMMIT already open from setUp. Run commit + reveal → EXECUTION.
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.005 ether, bytes32("s1")));
        vm.warp(block.timestamp + COMMIT_WIN);
        vm.prank(runner1);
        fund.reveal(0.005 ether, bytes32("s1"));
        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase(); // closes reveal, captures seed → EXECUTION phase
        assertEq(uint256(am.phase()), uint256(IAuctionManager.AuctionPhase.EXECUTION));

        // Owner freezes sunset while auction is still in-flight at EXECUTION.
        fund.freeze(fund.FREEZE_SUNSET());

        // migrate() succeeds immediately — no waiting on EXEC_WIN timeout.
        // `_resetAuction` refunds runner1's (winner) bond, then funds move.
        uint256 runner1BalBefore = runner1.balance;
        uint256 balBefore = address(0xBEEF).balance;
        fund.migrate(address(0xBEEF));
        assertGt(address(0xBEEF).balance, balBefore);
        assertEq(runner1.balance, runner1BalBefore + bond, "winner bond refunded on migrate");
    }

    function test_epochContentHashes_accumulate() public {
        speedrunEpoch(fund, _doNothingAction(), bytes("First"));
        bytes32 hash1 = fund.epochContentHashes(1);
        assertTrue(hash1 != bytes32(0));

        speedrunEpoch(fund, _doNothingAction(), bytes("Second"));
        bytes32 hash2 = fund.epochContentHashes(2);
        assertTrue(hash2 != bytes32(0));
        assertTrue(hash1 != hash2);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group 11: Stale Auction Auto-Cleanup via syncPhase
    // ═══════════════════════════════════════════════════════════════════════

    function test_staleCommit_noCommits_cleaned() public {
        // Epoch 1 COMMIT already open from setUp. Nobody commits, full epoch elapses.
        vm.warp(block.timestamp + EPOCH_DUR);
        fund.syncPhase(); // auto-cleans stale empty epoch, advances epoch

        assertEq(fund.currentEpoch(), 2);
        assertFalse(_executed(1));
    }

    function test_staleCommit_withCommits_cleaned() public {
        // Epoch 1 COMMIT already open from setUp.
        vm.prank(runner1);
        fund.commit{value: 0.01 ether}(_commitHash(runner1, 0.005 ether, bytes32("s1")));

        vm.warp(block.timestamp + EPOCH_DUR);
        fund.syncPhase(); // chains: COMMIT→REVEAL (1 commit), REVEAL close (0 reveals), advance

        assertEq(fund.currentEpoch(), 2);
        assertFalse(_executed(1));
    }

    function test_staleExecution_cleaned() public {
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        vm.warp(block.timestamp + EPOCH_DUR);

        uint256 treasuryBefore = address(fund).balance;
        fund.syncPhase();

        assertEq(fund.currentEpoch(), 2);
        assertGt(address(fund).balance, treasuryBefore); // forfeited bond
        assertFalse(_executed(1));
    }

    // ─── Fuzz Tests ────────────────────────────────────────────────────

    function test_equalBids_firstRevealerWins() public {
        // Epoch 1 COMMIT already open from setUp.
        uint256 epoch = fund.currentEpoch();
        uint256 bond = fund.currentBond();
        uint256 bidAmount = 0.005 ether;

        // Both commit with the same bid amount
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, bidAmount, bytes32("salt1")));
        vm.prank(runner2);
        fund.commit{value: bond}(_commitHash(runner2, bidAmount, bytes32("salt2")));

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
        assertEq(am.winner(), runner1);
        assertEq(am.winningBid(), bidAmount);
    }

    function test_loser_claimsBond_afterReveal() public {
        // Epoch 1 COMMIT already open from setUp.
        uint256 epoch = fund.currentEpoch();
        uint256 bond = fund.currentBond();

        // runner1 bids high, runner2 bids low (wins)
        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, 0.008 ether, bytes32("s1")));
        vm.prank(runner2);
        fund.commit{value: bond}(_commitHash(runner2, 0.003 ether, bytes32("s2")));

        vm.warp(block.timestamp + COMMIT_WIN);

        vm.prank(runner1);
        fund.reveal(0.008 ether, bytes32("s1"));
        vm.prank(runner2);
        fund.reveal(0.003 ether, bytes32("s2"));

        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase(); // closes reveal

        // runner2 wins
        assertEq(am.winner(), runner2);

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
        // Miss `n` epochs via the wall-clock path to build up consecutiveMissedEpochs.
        // Warps to absolute timestamps because Forge caches block.timestamp
        // within a test frame after vm.warp.
        uint256 n = bound(misses, 0, 50);
        for (uint256 i = 0; i < n; i++) {
            uint256 targetEpoch = fund.currentEpoch() + 1;
            vm.warp(fund.epochStartTime(targetEpoch) + 1);
            fund.syncPhase();
        }
        assertEq(fund.consecutiveMissedEpochs(), n > 50 ? 50 : n);

        uint256 bond = fund.currentBond();
        uint256 maxBid = fund.effectiveMaxBid();

        // Bond should never exceed its own cap: max(MIN_BOND_CAP, 10% of treasury)
        uint256 treasuryBondCap = (address(fund).balance * 1000) / 10000;
        uint256 bondCap = treasuryBondCap > 0.1 ether ? treasuryBondCap : 0.1 ether;
        assertLe(bond, bondCap);
        // effectiveMaxBid is capped at treasury * MAX_BID_BPS / 10000.
        uint256 hardCap = (address(fund).balance * fund.MAX_BID_BPS()) / 10000;
        assertLe(maxBid, hardCap);
        // Bond should always be >= BASE_BOND
        assertGe(bond, 0.001 ether);
    }

    function testFuzz_bidReveal_aboveMaxBid_reverts(uint256 bidAmount) public {
        uint256 maxBid = fund.effectiveMaxBid();
        bidAmount = bound(bidAmount, maxBid + 1, 100 ether);

        // Epoch 1 COMMIT already open from setUp.
        uint256 bond = fund.currentBond();
        bytes32 salt = bytes32("fuzz_salt");

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, bidAmount, salt));

        vm.warp(block.timestamp + COMMIT_WIN);

        vm.prank(runner1);
        vm.expectRevert(); // InvalidBid or similar
        fund.reveal(bidAmount, salt);
    }

    function testFuzz_bidReveal_validRange(uint256 bidAmount) public {
        uint256 maxBid = fund.effectiveMaxBid();
        bidAmount = bound(bidAmount, 1, maxBid);

        // Epoch 1 COMMIT already open from setUp.
        uint256 bond = fund.currentBond();
        bytes32 salt = bytes32("fuzz_valid");

        vm.prank(runner1);
        fund.commit{value: bond}(_commitHash(runner1, bidAmount, salt));

        vm.warp(block.timestamp + COMMIT_WIN);

        vm.prank(runner1);
        fund.reveal(bidAmount, salt);

        // Verify the reveal was recorded
        assertTrue(am.didReveal(runner1));
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

    function testFuzz_commitHash_preimage(uint256 bidAmount, bytes32 salt) public view {
        // Verify commit hash is deterministic and matches reveal
        bidAmount = bound(bidAmount, 1, 10 ether);
        bytes32 hash = _commitHash(runner1, bidAmount, salt);

        // Same inputs produce same hash
        assertEq(hash, keccak256(abi.encodePacked(runner1, bidAmount, salt)));

        // Different bid produces different hash
        if (bidAmount > 1) {
            assertNotEq(hash, _commitHash(runner1, bidAmount - 1, salt));
        }

        // Different runner produces different hash — runner binding prevents
        // reveal front-running where attacker reuses a legit (bid, salt) pair.
        assertNotEq(hash, _commitHash(runner2, bidAmount, salt));
    }

    /// @dev Reveal front-running attempt: attacker copies a legit runner's
    ///      commit hash, then tries to reveal it with the same (bid, salt).
    ///      Post-fix, the reveal must fail because the commit hash binds the
    ///      runner address — attacker's stored hash was keccak(attacker, bid, salt),
    ///      but the salt+bid only hashes to keccak(legit_runner, bid, salt).
    function test_reveal_frontRunning_blocked() public {
        uint256 bidAmount = 0.005 ether;
        bytes32 salt = bytes32("legit_salt");

        // Legit runner computes their commit hash and commits.
        bytes32 legitHash = _commitHash(runner1, bidAmount, salt);
        // Epoch 1 COMMIT already open from setUp.
        uint256 bond = fund.currentBond();
        vm.prank(runner1);
        fund.commit{value: bond}(legitHash);

        // Attacker observes the commit tx in the mempool and copies the hash
        // under their own address.
        vm.prank(runner2);
        fund.commit{value: bond}(legitHash);

        // Warp into reveal window.
        vm.warp(block.timestamp + COMMIT_WIN);

        // Attacker observes legit reveal tx and front-runs it with the same
        // (bid, salt) pair under their own address — this must revert because
        // their stored hash doesn't preimage to keccak(runner2, bid, salt).
        vm.prank(runner2);
        vm.expectRevert(); // InvalidParams from AuctionManager.recordReveal
        fund.reveal(bidAmount, salt);

        // Legit runner can still reveal normally.
        vm.prank(runner1);
        fund.reveal(bidAmount, salt);

        // Advance past reveal close; runner1 is the winner.
        vm.warp(block.timestamp + REVEAL_WIN);
        fund.syncPhase();
        assertEq(am.winner(), runner1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Group: Epoch Snapshot — drift isolation
    // ═══════════════════════════════════════════════════════════════════════

    function test_snapshot_valuesMatchAtAuctionOpen() public view {
        // Epoch 1 auction already opened in setUp.
        TheHumanFund.EpochSnapshot memory snap = fund.getEpochSnapshot(1);

        assertEq(snap.balance, address(fund).balance);
        assertEq(snap.totalInflows, fund.totalInflows());
        assertEq(snap.currentEpochInflow, fund.currentEpochInflow());
        assertEq(snap.currentEpochDonationCount, fund.currentEpochDonationCount());
        assertEq(snap.messageHead, fund.messageHead());
    }

    function test_snapshot_donationDoesNotChangeBaseInputHash() public {
        // Epoch 1 auction already opened in setUp.
        bytes32 hashBefore = fund.epochBaseInputHashes(1);

        // Donate after auction open
        vm.deal(address(0xDEAD), 1 ether);
        vm.prank(address(0xDEAD));
        fund.donate{value: 0.1 ether}(0);

        // baseInputHash must not have changed
        assertEq(fund.epochBaseInputHashes(1), hashBefore);
    }

    function test_snapshot_messageDoesNotChangeBaseInputHash() public {
        // Epoch 1 auction already opened in setUp.
        bytes32 hashBefore = fund.epochBaseInputHashes(1);

        // Send message after auction open
        vm.deal(address(0xDEAD), 1 ether);
        vm.prank(address(0xDEAD));
        fund.donateWithMessage{value: 0.05 ether}(0, "hello after auction open");

        // baseInputHash must not have changed
        assertEq(fund.epochBaseInputHashes(1), hashBefore);
    }

    function test_snapshot_messageBoundariesFrozen() public {
        // Note: epoch 1 was already opened at the end of setUp, so we cannot
        // retroactively add a pre-open message here. Instead we verify that
        // once the snapshot is taken, later messages do not mutate it.
        TheHumanFund.EpochSnapshot memory snap = fund.getEpochSnapshot(1);
        uint256 preOpenCount = snap.messageCount;

        // Send a message AFTER auction open.
        vm.deal(address(0xDEAD), 2 ether);
        vm.prank(address(0xDEAD));
        fund.donateWithMessage{value: 0.05 ether}(0, "after auction");

        // Snapshot should still show the original count (frozen at auction open)
        TheHumanFund.EpochSnapshot memory snapAfter = fund.getEpochSnapshot(1);
        assertEq(snapAfter.messageCount, preOpenCount);
        assertEq(snapAfter.messageHead, snap.messageHead);

        // But live state advanced.
        assertEq(fund.messageCount(), preOpenCount + 1);
    }

    function test_snapshot_scalarsFrozenAfterDonation() public {
        // Epoch 1 auction already opened in setUp.
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
        // Epoch 1: already open from setUp. Donate, complete epoch.
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
        // Epoch 1 is already open from setUp — its snapshot's messageCount is
        // whatever it was at setUp time (likely 0). Send a message after open;
        // snapshot stays frozen at the old count.
        TheHumanFund.EpochSnapshot memory snap1 = fund.getEpochSnapshot(1);
        uint256 epoch1FrozenCount = snap1.messageCount;
        uint256 epoch1FrozenHead = snap1.messageHead;

        // Run epoch 1 with no pending messages visible → submit has nothing
        // to consume, so messageHead stays where it was.
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        _submitAttestedResult(runner1, 1);
        assertEq(fund.messageHead(), epoch1FrozenHead);

        // Send a message before epoch 2 opens.
        vm.deal(address(0xDEAD), 5 ether);
        vm.prank(address(0xDEAD));
        fund.donateWithMessage{value: 0.05 ether}(0, "msg for epoch 2");

        // Warp to epoch 2's scheduled start
        vm.warp(fund.epochStartTime(2));
        fund.syncPhase();
        TheHumanFund.EpochSnapshot memory snap2 = fund.getEpochSnapshot(2);

        // Epoch 2 snapshot: head unchanged (epoch 1 consumed nothing),
        // count advanced by the new message.
        assertEq(snap2.messageHead, epoch1FrozenHead);
        assertEq(snap2.messageCount, epoch1FrozenCount + 1);
    }

    function test_snapshot_multiEpoch_donationBetweenEpochs() public {
        // Epoch 1 already open from setUp.
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

    // ═══════════════════════════════════════════════════════════════════════
    // Group: Message Queue Preservation on Failed Auctions
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Critical invariant: messageHead only advances on successful submission
    // (_recordAndExecute). Failed auctions, forfeited bonds, and missed epochs
    // must NOT drop messages from the queue. A donor who pays 0.05+ ETH for
    // a message is guaranteed that Costanza will see it in the next successful
    // epoch, not the next attempted epoch.

    function test_message_survives_forfeited_auction() public {
        // Donor sends a message AFTER epoch 1 opened (setUp opened it).
        // The snapshot for epoch 1 won't see it, but the live queue must
        // retain it through a forfeit.
        vm.deal(address(0xDEAD), 1 ether);
        vm.prank(address(0xDEAD));
        fund.donateWithMessage{value: 0.05 ether}(0, "important message");
        uint256 headBefore = fund.messageHead();
        uint256 countBefore = fund.messageCount();
        assertEq(countBefore, 1);

        // Runner commits and reveals (full auction flow)
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));

        // Runner WINS but fails to submit within the execution window
        vm.warp(block.timestamp + EXEC_WIN);
        fund.syncPhase(); // forfeits bond, advances to next epoch

        // Message queue must be unchanged — messageHead was never advanced
        assertEq(fund.messageHead(), headBefore, "messageHead preserved after forfeit");
        assertEq(fund.messageCount(), countBefore, "message still in queue");

        // Unread messages still shows the message
        (address[] memory senders,,, ) = fund.getUnreadMessages();
        assertEq(senders.length, 1);
        assertEq(senders[0], address(0xDEAD));
    }

    function test_message_consumed_after_successful_epoch_following_forfeit() public {
        // Scenario: message sent → auction 1 forfeited → auction 2 succeeds.
        // Message should be consumed in auction 2, not lost.
        vm.deal(address(0xDEAD), 1 ether);
        vm.prank(address(0xDEAD));
        fund.donateWithMessage{value: 0.05 ether}(0, "persistent message");
        uint256 headBefore = fund.messageHead();

        // Epoch 1 forfeits
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));
        vm.warp(block.timestamp + EXEC_WIN);
        fund.syncPhase();
        assertEq(fund.messageHead(), headBefore, "messageHead unchanged after forfeit");

        // Advance to epoch 2's scheduled start and run a successful auction
        vm.warp(fund.epochStartTime(2));
        fund.syncPhase(); // opens epoch 2 auction
        _runAuctionTo(runner1, 0.005 ether, bytes32("s2"));
        _submitAttestedResult(runner1, 2);

        // Now the message should be consumed
        assertEq(fund.messageHead(), headBefore + 1, "message consumed on successful epoch 2");
    }

    function test_message_arrivingAfterSnapshot_survivesToNextEpoch() public {
        // Regression: late-arriving messages (donated after auction open but
        // before submission) must not be silently skipped by messageHead
        // advancement. The TEE only sees the frozen snapshot count, so the
        // executor must advance messageHead against that frozen count too —
        // not against the live messages.length.

        // Epoch 1 already opened at setUp. M1 arrives after open — snapshot
        // for epoch 1 does NOT see it.
        vm.deal(address(0xDEAD), 2 ether);
        vm.prank(address(0xDEAD));
        fund.donateWithMessage{value: 0.05 ether}(0, "after epoch 1 open");

        TheHumanFund.EpochSnapshot memory snap1 = fund.getEpochSnapshot(1);
        uint256 epoch1FrozenCount = snap1.messageCount;
        uint256 epoch1FrozenHead = snap1.messageHead;

        // Run epoch 1 to reveal-close.
        _runAuctionTo(runner1, 0.005 ether, bytes32("s1"));

        // M2 arrives during execution — also not seen by epoch 1.
        vm.prank(address(0xDEAD));
        fund.donateWithMessage{value: 0.05 ether}(0, "late arrival");
        assertEq(fund.messageCount(), epoch1FrozenCount + 2, "live queue has 2 extra messages");

        // Epoch 1 submission consumes only what the snapshot saw.
        _submitAttestedResult(runner1, 1);
        assertEq(
            fund.messageHead(),
            epoch1FrozenHead + epoch1FrozenCount - epoch1FrozenHead,
            "messageHead advanced only past the model-visible messages"
        );
        // Simpler form: messageHead == epoch1FrozenCount (all frozen msgs consumed).
        assertEq(fund.messageHead(), epoch1FrozenCount);

        // Epoch 2 opens — its snapshot must include both late messages.
        vm.warp(fund.epochStartTime(2));
        fund.syncPhase();
        TheHumanFund.EpochSnapshot memory snap2 = fund.getEpochSnapshot(2);
        assertEq(snap2.messageHead, epoch1FrozenCount);
        assertEq(snap2.messageCount, epoch1FrozenCount + 2, "epoch 2 sees late messages");

        // And unread-messages view confirms the late messages are queued.
        (address[] memory senders, , string[] memory texts, ) = fund.getUnreadMessages();
        assertEq(senders.length, 2);
        assertEq(texts[0], "after epoch 1 open");
        assertEq(texts[1], "late arrival");
    }
}
