// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IWorldView.sol";

/// @title WorldView
/// @notice Stores the agent's guiding policies. Only the fund contract can
///         update them. Slots 1-9 are writable; slot 0 is reserved (unused
///         in the live prompt). The storage array and stateHash() cover all
///         10 slots for byte-exact hash equivalence with the enclave's
///         _hash_worldview mirror.
contract WorldView is IWorldView {
    uint256 public constant NUM_POLICIES = 10;
    uint256 public constant MAX_POLICY_LENGTH = 280;

    address public fund;
    string[10] public policies;

    event GuidingPolicyUpdated(uint256 indexed slot, string policy);

    constructor(address _fund) {
        fund = _fund;
    }

    /// @notice Set a guiding policy. Only callable by the fund contract.
    /// @param slot Policy slot (1-9). Slot 0 is reserved and cannot be written.
    /// @param policy The policy text (truncated to 280 bytes if longer).
    function setPolicy(uint256 slot, string calldata policy) external override {
        require(msg.sender == fund, "only fund");
        // Slot 0 is reserved and unused in the live prompt (the display loops
        // over slots 1..7). Reject writes to keep state clean and prevent the
        // agent from filling an unused slot.
        require(slot > 0 && slot < NUM_POLICIES, "invalid slot");

        string memory p = policy;
        if (bytes(policy).length > MAX_POLICY_LENGTH) {
            bytes memory truncated = new bytes(MAX_POLICY_LENGTH);
            bytes memory raw = bytes(policy);
            for (uint256 i = 0; i < MAX_POLICY_LENGTH; i++) {
                truncated[i] = raw[i];
            }
            p = string(truncated);
        }

        policies[slot] = p;
        emit GuidingPolicyUpdated(slot, p);
    }

    /// @notice Get a single policy by slot.
    function getPolicy(uint256 slot) external view override returns (string memory) {
        require(slot < NUM_POLICIES, "invalid slot");
        return policies[slot];
    }

    /// @notice Get all 10 policies.
    function getPolicies() external view override returns (string[10] memory) {
        return policies;
    }

    /// @notice Deterministic hash of all policies for input hash binding.
    function stateHash() external view override returns (bytes32) {
        return keccak256(abi.encode(
            policies[0], policies[1], policies[2], policies[3], policies[4],
            policies[5], policies[6], policies[7], policies[8], policies[9]
        ));
    }
}
