// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAttestationVerifier
/// @notice Interface for TEE attestation verification.
///         Verifies that a TDX DCAP quote came from an approved image
///         and that the REPORTDATA matches the expected computation binding.
interface IAttestationVerifier {
    /// @notice Verify a raw DCAP attestation quote against approved images and expected report data.
    /// @param rawQuote The raw TDX DCAP attestation quote bytes.
    /// @param expectedReportData The first 32 bytes of expected REPORTDATA
    ///        (sha256 of input hash || action hash || reasoning hash || seed).
    /// @return valid True if the quote is genuine, from an approved image, and REPORTDATA matches.
    function verifyAttestation(
        bytes calldata rawQuote,
        bytes32 expectedReportData
    ) external payable returns (bool valid);

    /// @notice Add an image measurement to the approved registry.
    /// @param imageKey keccak256(MRTD || RTMR[0] || RTMR[1] || RTMR[2]) — 192 bytes hashed.
    function approveImage(bytes32 imageKey) external;

    /// @notice Remove an image measurement from the approved registry.
    /// @param imageKey The image key to revoke.
    function revokeImage(bytes32 imageKey) external;

    /// @notice Check if an image is approved.
    /// @param imageKey The image key to check.
    /// @return True if the image is in the approved registry.
    function approvedImages(bytes32 imageKey) external view returns (bool);
}
