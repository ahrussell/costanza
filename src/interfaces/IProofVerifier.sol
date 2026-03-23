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
}
