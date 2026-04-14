// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IAutomataDcapAttestation.sol";
import "./interfaces/IProofVerifier.sol";

/// @title TdxVerifier
/// @notice Verifies Intel TDX DCAP attestation quotes for TheHumanFund.
///
///         Image key = sha256(MRTD || RTMR[1] || RTMR[2])
///
///         This covers:
///           - MRTD:    VM firmware (OVMF) — prevents bare-metal runners from using
///                      malicious firmware that could lie about kernel measurements
///           - RTMR[1]: Bootloader (GRUB/shim) — measured by firmware
///           - RTMR[2]: Kernel + command line — includes dm-verity root hash, which
///                      transitively covers the entire rootfs (all code, model weights)
///
///         RTMR[0] (virtual hardware config) is skipped — runners can use different VM
///         sizes without re-registration.
///
///         RTMR[3] is skipped — with full dm-verity rootfs, RTMR[2] already covers all
///         code via the root hash in the kernel command line. See DMVERITY_NOTES.md.
///
/// @dev Automata DCAP output layout (offsets relative to output start):
///          147-194:  MRTD        (48 bytes) — verified
///          339-386:  RTMR[0]     (48 bytes) — NOT verified
///          387-434:  RTMR[1]     (48 bytes) — verified
///          435-482:  RTMR[2]     (48 bytes) — verified
///          483-530:  RTMR[3]     (48 bytes) — NOT verified
///          531-594:  REPORTDATA  (64 bytes) — verified
contract TdxVerifier is IProofVerifier {
    // ─── Errors ──────────────────────────────────────────────────────────

    error Unauthorized();
    error InvalidParams();
    error Frozen();

    // ─── Constants ───────────────────────────────────────────────────────

    /// @dev Automata DCAP attestation verifier v1.0 (same address on all chains via CREATE2).
    ///      We intentionally use v1.0 instead of v1.1 because v1.0 reads from the
    ///      permissionless base PCCS DAOs (AutomataFmspcTcbDao, AutomataEnclaveIdentityDao),
    ///      which any keeper can update with Intel-signed collateral. v1.1 uses versioned
    ///      DAOs that require ATTESTER_ROLE — appropriate for multi-operator AVS use cases,
    ///      but unnecessary for a single-operator agent and creates a vendor dependency on
    ///      Automata running mainnet keepers. See WHITEPAPER.md TEE section for details.
    IAutomataDcapAttestation public constant DCAP_VERIFIER =
        IAutomataDcapAttestation(0x95175096a9B74165BE0ac84260cc14Fc1c0EF5FF);

    /// @dev Byte offsets in the Automata DCAP output for TD10ReportBody fields
    uint256 private constant MRTD_OFFSET = 147;
    uint256 private constant RTMR1_OFFSET = 387;
    uint256 private constant RTMR2_OFFSET = 435;
    uint256 private constant REPORTDATA_OFFSET = 531;
    uint256 private constant MEASUREMENT_LEN = 48; // SHA-384 output
    uint256 private constant MIN_OUTPUT_LEN = 595;  // Must have at least through REPORTDATA

    // ─── State ───────────────────────────────────────────────────────────

    address public owner;
    address public fund; // The fund contract, authorized to call freeze()

    /// @notice Registry of approved firmware + kernel + rootfs measurements.
    ///         Key = sha256(MRTD || RTMR[1] || RTMR[2])
    ///         where each field is 48 bytes (SHA-384), total 144 bytes hashed.
    mapping(bytes32 => bool) public approvedImages;

    bool public frozenImages;

    // ─── Events ──────────────────────────────────────────────────────────

    event ImageApproved(bytes32 indexed imageKey);
    event ImageRevoked(bytes32 indexed imageKey);
    event PermissionFrozen(string name);

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(address _fund) {
        owner = msg.sender;
        fund = _fund;
    }

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    // ─── Image Registry ──────────────────────────────────────────────────

    /// @notice Approve an image by its firmware + kernel measurement key.
    function approveImage(bytes32 imageKey) external onlyOwner {
        if (frozenImages) revert Frozen();
        approvedImages[imageKey] = true;
        emit ImageApproved(imageKey);
    }

    /// @notice Revoke a previously approved image.
    function revokeImage(bytes32 imageKey) external onlyOwner {
        if (frozenImages) revert Frozen();
        approvedImages[imageKey] = false;
        emit ImageRevoked(imageKey);
    }

    // ─── Kill Switch ───────────────────────────────────────────────────

    /// @notice Permanently freeze the image registry. Callable by owner or fund contract.
    function freeze() external override {
        if (msg.sender != owner && msg.sender != fund) revert Unauthorized();
        frozenImages = true;
        emit PermissionFrozen("images");
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

        // Step 2: Check image key — sha256(MRTD || RTMR[1] || RTMR[2])
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

    /// @notice Compute the image key from raw measurement bytes.
    /// @dev imageKey = sha256(MRTD || RTMR[1] || RTMR[2])
    function computeImageKey(
        bytes calldata mrtd,
        bytes calldata rtmr1,
        bytes calldata rtmr2
    ) external pure returns (bytes32) {
        if (mrtd.length != MEASUREMENT_LEN) revert InvalidParams();
        if (rtmr1.length != MEASUREMENT_LEN) revert InvalidParams();
        if (rtmr2.length != MEASUREMENT_LEN) revert InvalidParams();
        return sha256(abi.encodePacked(mrtd, rtmr1, rtmr2));
    }

    // ─── Internal ────────────────────────────────────────────────────────

    /// @dev Extract MRTD + RTMR[1] + RTMR[2] from DCAP output and compute image key.
    ///      imageKey = sha256(MRTD(48) || RTMR[1](48) || RTMR[2](48))
    function _computeImageKey(bytes memory output) internal pure returns (bytes32) {
        bytes memory measurements = new bytes(144);

        assembly {
            let src := add(output, 32) // skip bytes length prefix
            let dst := add(measurements, 32)

            // Copy MRTD (48 bytes at offset 147)
            let mrtdSrc := add(src, MRTD_OFFSET)
            mstore(dst, mload(mrtdSrc))                     // bytes 0-31
            mstore(add(dst, 32), mload(add(mrtdSrc, 32)))   // bytes 32-47 (+ 16 overflow, ok)

            // Copy RTMR[1] (48 bytes at offset 387)
            let rtmr1Src := add(src, RTMR1_OFFSET)
            mstore(add(dst, 48), mload(rtmr1Src))            // bytes 48-79
            mstore(add(dst, 80), mload(add(rtmr1Src, 32)))   // bytes 80-95 (+ 16 overflow, ok)

            // Copy RTMR[2] (48 bytes at offset 435)
            let rtmr2Src := add(src, RTMR2_OFFSET)
            mstore(add(dst, 96), mload(rtmr2Src))            // bytes 96-127
            mstore(add(dst, 128), mload(add(rtmr2Src, 32)))  // bytes 128-143 (+ 16 overflow, ok)
        }

        return sha256(measurements);
    }
}
