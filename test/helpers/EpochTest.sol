// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/TheHumanFund.sol";

/// @dev Shared base for tests that drive the contract through full epochs.
///
/// This helper exists so test call sites don't hard-code a particular
/// epoch-advancement mechanism. Today `speedrunEpoch` wraps the legacy
/// `submitEpochAction` direct-mode path. Once the `_nextPhase` refactor
/// lands and direct mode is removed, the implementation here will switch
/// to running a real commit → reveal → submit flow against a mock proof
/// verifier — and every test call site stays unchanged.
///
/// Guideline for new tests: if you're driving a noop/donate/etc. epoch
/// and don't specifically need to assert on direct-mode-specific behavior,
/// use `speedrunEpoch`. Reserve direct `fund.submitEpochAction` calls for
/// tests that assert on direct mode's own semantics (e.g. its freeze
/// flag, its revert paths). Those tests will be deleted with direct mode.
abstract contract EpochTest is Test {
    /// @dev Execute one epoch's action and advance `currentEpoch`.
    ///      Equivalent today to `submitEpochAction + syncPhase`.
    function speedrunEpoch(
        TheHumanFund fund,
        bytes memory action,
        bytes memory reasoning
    ) internal {
        fund.submitEpochAction(action, reasoning, -1, "");
        fund.syncPhase();
    }

    /// @dev Execute one epoch's action with a worldview sidecar update.
    function speedrunEpoch(
        TheHumanFund fund,
        bytes memory action,
        bytes memory reasoning,
        int8 policySlot,
        string memory policyText
    ) internal {
        fund.submitEpochAction(action, reasoning, policySlot, policyText);
        fund.syncPhase();
    }
}
