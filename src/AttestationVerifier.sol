// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IAutomataDcapAttestation.sol";
import "./interfaces/IAttestationVerifier.sol";

/// @title AttestationVerifier
/// @notice Verifies TDX DCAP attestation quotes against an approved image registry
///         and checks REPORTDATA binding for input/output integrity.
/// @dev Separated from TheHumanFund to stay within the 24KB contract size limit.
///
///      Automata DCAP output layout (abi.encodePacked, TDX V4 quote):
///        Bytes 0-1:     quoteVersion (uint16, always 4)
///        Bytes 2-3:     quoteBodyType (uint16, 2 = TDX TD10)
///        Bytes 4:       tcbStatus (uint8)
///        Bytes 5-10:    fmspcBytes (bytes6)
///        Bytes 11-594:  quoteBody (584 bytes, raw TD10ReportBody)
///        Bytes 595+:    advisoryIDs (abi.encode(string[]), if non-empty)
///
///      Within quoteBody (offsets relative to output start):
///        147-194:  MRTD        (48 bytes, SHA-384)
///        339-386:  RTMR[0]     (48 bytes)
///        387-434:  RTMR[1]     (48 bytes)
///        435-482:  RTMR[2]     (48 bytes)
///        483-530:  RTMR[3]     (48 bytes) — skipped (platform-specific)
///        531-594:  REPORTDATA  (64 bytes)
contract AttestationVerifier is IAttestationVerifier {
    // ─── Errors ──────────────────────────────────────────────────────────

    error Unauthorized();
    error InvalidParams();

    // ─── Constants ───────────────────────────────────────────────────────

    /// @dev Automata DCAP attestation verifier (same address on all chains via CREATE2)
    IAutomataDcapAttestation public constant DCAP_VERIFIER =
        IAutomataDcapAttestation(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F);

    /// @dev Byte offsets in the Automata DCAP output for TD10ReportBody fields
    uint256 private constant MRTD_OFFSET = 147;
    uint256 private constant RTMR0_OFFSET = 339;
    uint256 private constant RTMR1_OFFSET = 387;
    uint256 private constant RTMR2_OFFSET = 435;
    uint256 private constant REPORTDATA_OFFSET = 531;
    uint256 private constant MEASUREMENT_LEN = 48; // SHA-384 output
    uint256 private constant REPORTDATA_LEN = 64;
    uint256 private constant MIN_OUTPUT_LEN = 595; // Must have at least through REPORTDATA

    // ─── State ───────────────────────────────────────────────────────────

    address public owner;

    /// @notice Registry of approved TEE image measurements.
    ///         Key = keccak256(MRTD || RTMR[0] || RTMR[1] || RTMR[2])
    ///         where each field is 48 bytes (SHA-384), total 192 bytes hashed.
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

    /// @inheritdoc IAttestationVerifier
    function approveImage(bytes32 imageKey) external onlyOwner {
        approvedImages[imageKey] = true;
        emit ImageApproved(imageKey);
    }

    /// @inheritdoc IAttestationVerifier
    function revokeImage(bytes32 imageKey) external onlyOwner {
        approvedImages[imageKey] = false;
        emit ImageRevoked(imageKey);
    }

    // ─── Verification ────────────────────────────────────────────────────

    /// @inheritdoc IAttestationVerifier
    function verifyAttestation(
        bytes calldata rawQuote,
        bytes32 expectedReportData
    ) external payable returns (bool valid) {
        // Step 1: Verify the quote is genuine TDX via Automata DCAP
        (bool dcapSuccess, bytes memory output) =
            DCAP_VERIFIER.verifyAndAttestOnChain{value: msg.value}(rawQuote);
        if (!dcapSuccess) return false;
        if (output.length < MIN_OUTPUT_LEN) return false;

        // Step 2: Extract MRTD + RTMR[0..2] and verify against approved registry
        bytes32 imageKey = _computeImageKey(output);
        if (!approvedImages[imageKey]) return false;

        // Step 3: Extract REPORTDATA and verify against expected value
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

    /// @notice Compute the image key from raw measurement bytes.
    /// @dev For off-chain computation: hash the concatenation of MRTD + RTMR[0..2].
    function computeImageKey(
        bytes calldata mrtd,
        bytes calldata rtmr0,
        bytes calldata rtmr1,
        bytes calldata rtmr2
    ) external pure returns (bytes32) {
        if (mrtd.length != MEASUREMENT_LEN) revert InvalidParams();
        if (rtmr0.length != MEASUREMENT_LEN) revert InvalidParams();
        if (rtmr1.length != MEASUREMENT_LEN) revert InvalidParams();
        if (rtmr2.length != MEASUREMENT_LEN) revert InvalidParams();
        return keccak256(abi.encodePacked(mrtd, rtmr0, rtmr1, rtmr2));
    }

    // ─── Internal ────────────────────────────────────────────────────────

    /// @dev Extract MRTD + RTMR[0..2] from DCAP output and compute image key.
    function _computeImageKey(bytes memory output) internal pure returns (bytes32) {
        // Extract 192 bytes: MRTD(48) || RTMR[0](48) || RTMR[1](48) || RTMR[2](48)
        bytes memory measurements = new bytes(192);

        // Use assembly for efficient memory copying
        assembly {
            let src := add(output, 32) // skip bytes length prefix
            let dst := add(measurements, 32)

            // Copy MRTD (48 bytes at offset 147)
            let mrtdSrc := add(src, MRTD_OFFSET)
            mstore(dst, mload(mrtdSrc))           // bytes 0-31
            mstore(add(dst, 32), mload(add(mrtdSrc, 32))) // bytes 32-47 (+ 16 overflow, ok)

            // Copy RTMR[0] (48 bytes at offset 339)
            let rtmr0Src := add(src, RTMR0_OFFSET)
            mstore(add(dst, 48), mload(rtmr0Src))
            mstore(add(dst, 80), mload(add(rtmr0Src, 32)))

            // Copy RTMR[1] (48 bytes at offset 387)
            let rtmr1Src := add(src, RTMR1_OFFSET)
            mstore(add(dst, 96), mload(rtmr1Src))
            mstore(add(dst, 128), mload(add(rtmr1Src, 32)))

            // Copy RTMR[2] (48 bytes at offset 435)
            let rtmr2Src := add(src, RTMR2_OFFSET)
            mstore(add(dst, 144), mload(rtmr2Src))
            mstore(add(dst, 176), mload(add(rtmr2Src, 32)))
        }

        return keccak256(measurements);
    }
}
