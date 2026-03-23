// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IAutomataDcapAttestation.sol";
import "./interfaces/IProofVerifier.sol";

/// @title TdxVerifier
/// @notice Verifies Intel TDX DCAP attestation quotes for TheHumanFund.
///         Only checks RTMR[1] (kernel) and RTMR[2] (application) for platform
///         portability — skips MRTD and RTMR[0] which vary by cloud provider firmware.
///
/// @dev Automata DCAP output layout (abi.encodePacked, TDX V4 quote):
///        Bytes 0-1:     quoteVersion (uint16, always 4)
///        Bytes 2-3:     quoteBodyType (uint16, 2 = TDX TD10)
///        Bytes 4:       tcbStatus (uint8)
///        Bytes 5-10:    fmspcBytes (bytes6)
///        Bytes 11-594:  quoteBody (584 bytes, raw TD10ReportBody)
///        Bytes 595+:    advisoryIDs (abi.encode(string[]), if non-empty)
///
///      Within quoteBody (offsets relative to output start):
///        147-194:  MRTD        (48 bytes, SHA-384) — NOT verified (firmware-specific)
///        339-386:  RTMR[0]     (48 bytes) — NOT verified (firmware config)
///        387-434:  RTMR[1]     (48 bytes) — verified (kernel)
///        435-482:  RTMR[2]     (48 bytes) — verified (application / rootfs)
///        483-530:  RTMR[3]     (48 bytes) — NOT verified (runtime / platform-specific)
///        531-594:  REPORTDATA  (64 bytes) — verified
///
///      REPORTDATA formula: sha256(inputHash || outputHash), zero-padded to 64 bytes.
///      The inputHash includes the randomness seed. The outputHash covers action + reasoning.
contract TdxVerifier is IProofVerifier {
    // ─── Errors ──────────────────────────────────────────────────────────

    error Unauthorized();
    error InvalidParams();

    // ─── Constants ───────────────────────────────────────────────────────

    /// @dev Automata DCAP attestation verifier (same address on all chains via CREATE2)
    IAutomataDcapAttestation public constant DCAP_VERIFIER =
        IAutomataDcapAttestation(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F);

    /// @dev Byte offsets in the Automata DCAP output for TD10ReportBody fields
    uint256 private constant RTMR1_OFFSET = 387;
    uint256 private constant RTMR2_OFFSET = 435;
    uint256 private constant REPORTDATA_OFFSET = 531;
    uint256 private constant MEASUREMENT_LEN = 48; // SHA-384 output
    uint256 private constant MIN_OUTPUT_LEN = 595;  // Must have at least through REPORTDATA

    // ─── State ───────────────────────────────────────────────────────────

    address public owner;

    /// @notice Registry of approved kernel + application measurements.
    ///         Key = keccak256(RTMR[1] || RTMR[2])
    ///         where each field is 48 bytes (SHA-384), total 96 bytes hashed.
    mapping(bytes32 => bool) public approvedImages;

    // ─── Events ──────────────────────────────────────────────────────────

    event ImageApproved(bytes32 indexed imageKey);
    event ImageRevoked(bytes32 indexed imageKey);

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor() {
        owner = msg.sender;
    }

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    // ─── Image Registry ──────────────────────────────────────────────────

    /// @notice Approve a kernel + application image by its measurement key.
    function approveImage(bytes32 imageKey) external onlyOwner {
        approvedImages[imageKey] = true;
        emit ImageApproved(imageKey);
    }

    /// @notice Revoke a previously approved image.
    function revokeImage(bytes32 imageKey) external onlyOwner {
        approvedImages[imageKey] = false;
        emit ImageRevoked(imageKey);
    }

    // ─── IProofVerifier ─────────────────────────────────────────────────

    /// @notice Verify a TDX DCAP attestation quote.
    /// @param inputHash Hash of all epoch inputs (includes randomness seed).
    /// @param outputHash Hash of epoch outputs (action + reasoning).
    /// @param proof Raw TDX DCAP attestation quote bytes.
    /// @return valid True if DCAP passes, image is approved, and REPORTDATA matches.
    function verify(
        bytes32 inputHash,
        bytes32 outputHash,
        bytes calldata proof
    ) external payable override returns (bool valid) {
        // Step 1: Verify the quote is genuine TDX via Automata DCAP
        (bool dcapSuccess, bytes memory output) =
            DCAP_VERIFIER.verifyAndAttestOnChain{value: msg.value}(proof);
        if (!dcapSuccess) return false;
        if (output.length < MIN_OUTPUT_LEN) return false;

        // Step 2: Extract RTMR[1] + RTMR[2] and verify against approved registry
        bytes32 imageKey = _computeImageKey(output);
        if (!approvedImages[imageKey]) return false;

        // Step 3: Compute expected REPORTDATA and compare
        bytes32 expectedReportData = sha256(abi.encodePacked(inputHash, outputHash));

        bytes32 actualReportData;
        assembly {
            actualReportData := mload(add(add(output, 32), REPORTDATA_OFFSET))
        }
        if (actualReportData != expectedReportData) return false;

        // Step 4: Verify REPORTDATA padding is zero (bytes 32-63)
        bytes32 reportDataPadding;
        assembly {
            reportDataPadding := mload(add(add(output, 32), 563))
        }
        if (reportDataPadding != bytes32(0)) return false;

        return true;
    }

    // ─── Views ───────────────────────────────────────────────────────────

    /// @notice Compute the image key from raw RTMR[1] and RTMR[2] measurement bytes.
    /// @dev For off-chain computation: hash the concatenation of RTMR[1] + RTMR[2].
    function computeImageKey(
        bytes calldata rtmr1,
        bytes calldata rtmr2
    ) external pure returns (bytes32) {
        if (rtmr1.length != MEASUREMENT_LEN) revert InvalidParams();
        if (rtmr2.length != MEASUREMENT_LEN) revert InvalidParams();
        return keccak256(abi.encodePacked(rtmr1, rtmr2));
    }

    // ─── Internal ────────────────────────────────────────────────────────

    /// @dev Extract RTMR[1] + RTMR[2] from DCAP output and compute image key.
    function _computeImageKey(bytes memory output) internal pure returns (bytes32) {
        // Extract 96 bytes: RTMR[1](48) || RTMR[2](48)
        bytes memory measurements = new bytes(96);

        assembly {
            let src := add(output, 32) // skip bytes length prefix
            let dst := add(measurements, 32)

            // Copy RTMR[1] (48 bytes at offset 387)
            let rtmr1Src := add(src, RTMR1_OFFSET)
            mstore(dst, mload(rtmr1Src))                     // bytes 0-31
            mstore(add(dst, 32), mload(add(rtmr1Src, 32)))   // bytes 32-47 (+ 16 overflow, ok)

            // Copy RTMR[2] (48 bytes at offset 435)
            let rtmr2Src := add(src, RTMR2_OFFSET)
            mstore(add(dst, 48), mload(rtmr2Src))            // bytes 48-79
            mstore(add(dst, 80), mload(add(rtmr2Src, 32)))   // bytes 80-95 (+ 16 overflow, ok)
        }

        return keccak256(measurements);
    }
}
