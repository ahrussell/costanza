// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IProofVerifier
/// @notice Generic interface for verifying proofs that bind epoch inputs to outputs.
///         Supports TEE attestation (TDX DCAP) today and ZK proofs in the future.
///         Each verifier implementation manages its own internal state (e.g., approved
///         image registry for TDX, verification keys for ZK).
interface IProofVerifier {
    /// @notice Verify that a proof binds the given input and output hashes.
    /// @param inputHash Hash of all epoch inputs (contract state + randomness seed).
    /// @param outputHash Hash of epoch outputs (action + reasoning).
    /// @param proof Opaque proof bytes (DCAP quote for TDX, ZK proof for future verifiers).
    /// @return valid True if the proof is valid for the given input/output pair.
    function verify(
        bytes32 inputHash,
        bytes32 outputHash,
        bytes calldata proof
    ) external payable returns (bool valid);

    /// @notice Permanently freeze the verifier's internal state (e.g., image registry).
    function freeze() external;

    /// @notice Transfer the verifier's owner/admin to a new address.
    /// @dev Implementations MUST authorize this for both the verifier's
    ///      current owner AND the fund contract, so TheHumanFund's
    ///      transferOwnership can fan out atomically.
    function transferOwner(address newOwner) external;
}
