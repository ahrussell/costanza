// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/TheHumanFund.sol";
import "../../src/interfaces/IAuctionManager.sol";
import "./MockProofVerifier.sol";

/// @dev Shared base for tests that drive the contract through full epochs.
///
/// `speedrunEpoch` drives one epoch through the real auction path using
/// the owner's `nextPhase()` manual driver — no `vm.warp` needed. Each
/// call: opens auction → commit → close commit → reveal → close reveal
/// → submitAuctionResult → advance to next epoch.
///
/// Every test class that inherits EpochTest must call
/// `_registerMockVerifier(fund)` in its own `setUp()` after
/// `setAuctionManager`. This deploys a MockProofVerifier at a
/// reserved verifier slot so `submitAuctionResult` can verify proofs.
abstract contract EpochTest is Test {
    /// @dev Reserved verifier ID for the mock. Slot 7 avoids collision
    ///      with real verifier tests that use slot 1.
    uint8 internal constant EPOCH_TEST_VERIFIER_ID = 7;

    /// @dev Canonical runner address used by speedrunEpoch. Tests that
    ///      need to assert on runner balances can reference this.
    address internal constant EPOCH_TEST_RUNNER = address(0xE90C);

    /// @dev Deploy and register the mock verifier. Must be called in
    ///      each test class's setUp() after setAuctionManager.
    function _registerMockVerifier(TheHumanFund fund) internal {
        MockProofVerifier mock = new MockProofVerifier();
        fund.approveVerifier(EPOCH_TEST_VERIFIER_ID, address(mock));
        vm.deal(EPOCH_TEST_RUNNER, 100 ether);
    }

    /// @dev Execute one epoch's action via the real auction path and
    ///      advance `currentEpoch`. Uses the owner's `nextPhase()` as
    ///      the manual driver — time-independent, no vm.warp.
    ///
    ///      Flow:
    ///        1. nextPhase() — opens auction (IDLE/SETTLED → COMMIT)
    ///        2. commit (EPOCH_TEST_RUNNER, minimum bid, fixed salt)
    ///        3. nextPhase() — COMMIT → REVEAL
    ///        4. reveal
    ///        5. nextPhase() — REVEAL → EXECUTION (captures seed)
    ///        6. submitAuctionResult (executes the action)
    ///        7. nextPhase() — SETTLED → advance epoch + open next
    function speedrunEpoch(
        TheHumanFund fund,
        bytes memory action,
        bytes memory reasoning
    ) internal {
        _speedrunEpochInternal(fund, action, reasoning, -1, "");
    }

    /// @dev Execute one epoch's action with a worldview sidecar update.
    function speedrunEpoch(
        TheHumanFund fund,
        bytes memory action,
        bytes memory reasoning,
        int8 policySlot,
        string memory policyText
    ) internal {
        _speedrunEpochInternal(fund, action, reasoning, policySlot, policyText);
    }

    function _speedrunEpochInternal(
        TheHumanFund fund,
        bytes memory action,
        bytes memory reasoning,
        int8 policySlot,
        string memory policyText
    ) private {
        // 1. Ensure an auction is open for currentEpoch. If the prior
        //    speedrunEpoch already opened it (step 7 advances + opens),
        //    skip the opening call.
        IAuctionManager am = fund.auctionManager();
        IAuctionManager.AuctionPhase phase = am.getPhase(fund.currentEpoch());
        if (phase != IAuctionManager.AuctionPhase.COMMIT) {
            fund.nextPhase();
        }

        // 2. Commit with minimum bid + fixed salt
        uint256 bond = fund.currentBond();
        uint256 bidAmount = 1; // 1 wei — minimum nonzero
        bytes32 salt = bytes32(uint256(0xF00D));
        bytes32 commitHash = keccak256(abi.encodePacked(EPOCH_TEST_RUNNER, bidAmount, salt));
        vm.prank(EPOCH_TEST_RUNNER);
        fund.commit{value: bond}(commitHash);

        // 3. Close commit → REVEAL
        fund.nextPhase();

        // 4. Reveal
        vm.prank(EPOCH_TEST_RUNNER);
        fund.reveal(bidAmount, salt);

        // 5. Close reveal → EXECUTION (captures seed, binds input hash)
        fund.nextPhase();

        // 6. Submit auction result — runner executes the action
        vm.prank(EPOCH_TEST_RUNNER);
        fund.submitAuctionResult(
            action, reasoning, bytes("mock"), EPOCH_TEST_VERIFIER_ID,
            policySlot, policyText
        );

        // 7. Advance to next epoch + open auction
        fund.nextPhase();
    }
}
