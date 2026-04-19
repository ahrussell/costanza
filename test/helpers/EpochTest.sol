// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/TheHumanFund.sol";
import "../../src/interfaces/IAuctionManager.sol";
import "./MockProofVerifier.sol";

/// @dev Shared base for tests that drive the contract through full epochs.
///
/// `speedrunEpoch` drives one epoch through the real auction path using the
/// owner's `nextPhase()` manual driver — no `vm.warp` needed. In the 3-phase
/// cyclic model, `nextPhase()` always advances the state machine by exactly
/// one step: COMMIT → REVEAL → EXECUTION → COMMIT (of the next epoch).
///
/// The very first auction (epoch 1's COMMIT) is opened by `setAuctionManager`
/// at deploy time, so every `speedrunEpoch` call assumes we're entering at
/// COMMIT of `currentEpoch`.
///
/// Every test class that inherits EpochTest must call
/// `_registerMockVerifier(fund)` in its own `setUp()` after
/// `setAuctionManager`. This deploys a MockProofVerifier at a reserved
/// verifier slot so `submitAuctionResult` can verify proofs.
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
    ///      advance `currentEpoch` to the next epoch's COMMIT phase.
    ///
    ///      Precondition: phase == COMMIT of currentEpoch. Either this is
    ///      the first speedrunEpoch after setAuctionManager (which eagerly
    ///      opened epoch 1), or the prior speedrunEpoch's final nextPhase()
    ///      left us in COMMIT of the subsequent epoch.
    ///
    ///      Flow (3 `nextPhase` calls, each a monotonic state-machine step):
    ///        1. commit (EPOCH_TEST_RUNNER, 1-wei bid, fixed salt)
    ///        2. nextPhase() — COMMIT → REVEAL
    ///        3. reveal
    ///        4. nextPhase() — REVEAL → EXECUTION (captures seed, binds input hash)
    ///        5. submitAuctionResult (executes action; sets epochs[e].executed)
    ///        6. nextPhase() — EXECUTION → COMMIT of next epoch
    ///                         (_closeExecution sees executed=true, skips forfeit,
    ///                          resets missed counter, opens the next auction)
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
        IAuctionManager am = fund.auctionManager();
        require(
            am.getPhase(fund.currentEpoch()) == IAuctionManager.AuctionPhase.COMMIT,
            "speedrunEpoch: expected COMMIT phase (auction not open or caller drift?)"
        );

        // 1. Commit with minimum bid + fixed salt
        uint256 bond = fund.currentBond();
        uint256 bidAmount = 1; // 1 wei — minimum nonzero
        bytes32 salt = bytes32(uint256(0xF00D));
        bytes32 commitHash = keccak256(abi.encodePacked(EPOCH_TEST_RUNNER, bidAmount, salt));
        vm.prank(EPOCH_TEST_RUNNER);
        fund.commit{value: bond}(commitHash);

        // 2. nextPhase — COMMIT → REVEAL
        fund.nextPhase();

        // 3. Reveal
        vm.prank(EPOCH_TEST_RUNNER);
        fund.reveal(bidAmount, salt);

        // 4. nextPhase — REVEAL → EXECUTION (captures seed, binds input hash)
        fund.nextPhase();

        // 5. Submit result (runner executes the action; sets epochs[e].executed)
        vm.prank(EPOCH_TEST_RUNNER);
        fund.submitAuctionResult(
            action, reasoning, bytes("mock"), EPOCH_TEST_VERIFIER_ID,
            policySlot, policyText
        );

        // 6. nextPhase — EXECUTION → COMMIT of next epoch (opens new auction)
        fund.nextPhase();
    }
}
