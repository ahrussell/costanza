// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AttestationVerifier.sol";
import "../src/interfaces/IAutomataDcapAttestation.sol";

/// @title Mock DCAP verifier for testing
/// @dev Returns crafted output bytes with controllable MRTD/RTMR/REPORTDATA
contract MockDcapVerifier is IAutomataDcapAttestation {
    bool public shouldSucceed = true;
    bytes public craftedOutput;

    function setOutput(bytes memory _output) external {
        craftedOutput = _output;
    }

    function setShouldSucceed(bool _succeed) external {
        shouldSucceed = _succeed;
    }

    function verifyAndAttestOnChain(bytes calldata)
        external
        payable
        returns (bool, bytes memory)
    {
        return (shouldSucceed, craftedOutput);
    }
}

/// @title Attestation Verifier Tests
contract AttestationVerifierTest is Test {
    AttestationVerifier public verifier;
    MockDcapVerifier public mockDcap;

    // Test measurement values (48 bytes = 96 hex chars each, SHA-384)
    bytes constant MRTD_1 = hex"aabbccdd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000011";
    bytes constant RTMR0_1 = hex"111111110000000000000000000000000000000000000000000000000000000000000000000000000000000000000022";
    bytes constant RTMR1_1 = hex"222222220000000000000000000000000000000000000000000000000000000000000000000000000000000000000033";
    bytes constant RTMR2_1 = hex"333333330000000000000000000000000000000000000000000000000000000000000000000000000000000000000044";

    // Second set of measurements (different image)
    bytes constant MRTD_2 = hex"deadbeef0000000000000000000000000000000000000000000000000000000000000000000000000000000000000055";
    bytes constant RTMR0_2 = hex"555555550000000000000000000000000000000000000000000000000000000000000000000000000000000000000066";
    bytes constant RTMR1_2 = hex"666666660000000000000000000000000000000000000000000000000000000000000000000000000000000000000077";
    bytes constant RTMR2_2 = hex"777777770000000000000000000000000000000000000000000000000000000000000000000000000000000000000088";

    function setUp() public {
        mockDcap = new MockDcapVerifier();
        verifier = new AttestationVerifier();

        // Override the DCAP_VERIFIER constant for testing using vm.etch
        // Deploy the mock at the hardcoded DCAP_VERIFIER address
        bytes memory mockCode = address(mockDcap).code;
        vm.etch(address(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F), mockCode);

        // Copy storage from mockDcap to the etched address
        // We need to set up the mock at the constant address
        // Simpler approach: just use the etched mock directly
        MockDcapVerifier etchedMock = MockDcapVerifier(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F);
        etchedMock.setShouldSucceed(true);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    /// @dev Build a DCAP output byte array with fields at the correct offsets.
    ///      Automata output layout: [header(11)] [quoteBody(584)] = 595 bytes minimum
    function _buildDcapOutput(
        bytes memory mrtd,
        bytes memory rtmr0,
        bytes memory rtmr1,
        bytes memory rtmr2,
        bytes32 reportData
    ) internal pure returns (bytes memory) {
        bytes memory output = new bytes(595);

        // Header: version=4, bodyType=2 (TDX), tcbStatus=0, fmspc=0
        output[0] = 0x00; output[1] = 0x04; // quoteVersion = 4
        output[2] = 0x00; output[3] = 0x02; // quoteBodyType = 2 (TDX TD10)
        output[4] = 0x00; // tcbStatus = OK

        // Place MRTD at offset 147 (48 bytes)
        for (uint256 i = 0; i < 48; i++) {
            output[147 + i] = mrtd[i];
        }
        // Place RTMR[0] at offset 339 (48 bytes)
        for (uint256 i = 0; i < 48; i++) {
            output[339 + i] = rtmr0[i];
        }
        // Place RTMR[1] at offset 387 (48 bytes)
        for (uint256 i = 0; i < 48; i++) {
            output[387 + i] = rtmr1[i];
        }
        // Place RTMR[2] at offset 435 (48 bytes)
        for (uint256 i = 0; i < 48; i++) {
            output[435 + i] = rtmr2[i];
        }
        // Place REPORTDATA at offset 531 (first 32 bytes = reportData, rest = 0)
        for (uint256 i = 0; i < 32; i++) {
            output[531 + i] = reportData[i];
        }
        // Bytes 563-594 remain zero (padding)

        return output;
    }

    function _computeImageKey(
        bytes memory mrtd,
        bytes memory rtmr0,
        bytes memory rtmr1,
        bytes memory rtmr2
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(mrtd, rtmr0, rtmr1, rtmr2));
    }

    function _setupApprovedImage1() internal {
        bytes32 imageKey = _computeImageKey(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1);
        verifier.approveImage(imageKey);
    }

    function _setupMockOutput(bytes32 reportData) internal {
        bytes memory output = _buildDcapOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, reportData);
        MockDcapVerifier(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F).setOutput(output);
    }

    // ─── Tests: Image Registry ────────────────────────────────────────────

    function test_approve_image() public {
        bytes32 imageKey = _computeImageKey(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1);
        assertFalse(verifier.approvedImages(imageKey));

        verifier.approveImage(imageKey);
        assertTrue(verifier.approvedImages(imageKey));
    }

    function test_revoke_image() public {
        bytes32 imageKey = _computeImageKey(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1);
        verifier.approveImage(imageKey);
        assertTrue(verifier.approvedImages(imageKey));

        verifier.revokeImage(imageKey);
        assertFalse(verifier.approvedImages(imageKey));
    }

    function test_only_owner_can_approve() public {
        bytes32 imageKey = _computeImageKey(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1);
        vm.prank(address(0xdead));
        vm.expectRevert(AttestationVerifier.Unauthorized.selector);
        verifier.approveImage(imageKey);
    }

    function test_only_owner_can_revoke() public {
        bytes32 imageKey = _computeImageKey(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1);
        verifier.approveImage(imageKey);

        vm.prank(address(0xdead));
        vm.expectRevert(AttestationVerifier.Unauthorized.selector);
        verifier.revokeImage(imageKey);
    }

    // ─── Tests: Verification ──────────────────────────────────────────────

    function test_approved_image_accepted() public {
        _setupApprovedImage1();

        bytes32 reportData = bytes32(uint256(0x42));
        _setupMockOutput(reportData);

        bool valid = verifier.verifyAttestation(bytes("quote"), reportData);
        assertTrue(valid);
    }

    function test_unapproved_image_rejected() public {
        // Don't approve any image
        bytes32 reportData = bytes32(uint256(0x42));
        _setupMockOutput(reportData);

        bool valid = verifier.verifyAttestation(bytes("quote"), reportData);
        assertFalse(valid);
    }

    function test_revoked_image_rejected() public {
        _setupApprovedImage1();

        bytes32 imageKey = _computeImageKey(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1);
        verifier.revokeImage(imageKey);

        bytes32 reportData = bytes32(uint256(0x42));
        _setupMockOutput(reportData);

        bool valid = verifier.verifyAttestation(bytes("quote"), reportData);
        assertFalse(valid);
    }

    function test_reportdata_mismatch_rejected() public {
        _setupApprovedImage1();

        bytes32 correctReportData = bytes32(uint256(0x42));
        bytes32 wrongReportData = bytes32(uint256(0x99));
        _setupMockOutput(correctReportData);

        // Verify with wrong expected value
        bool valid = verifier.verifyAttestation(bytes("quote"), wrongReportData);
        assertFalse(valid);
    }

    function test_dcap_failure_rejected() public {
        _setupApprovedImage1();

        bytes32 reportData = bytes32(uint256(0x42));
        _setupMockOutput(reportData);

        MockDcapVerifier(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F).setShouldSucceed(false);

        bool valid = verifier.verifyAttestation(bytes("quote"), reportData);
        assertFalse(valid);
    }

    function test_multiple_approved_images() public {
        bytes32 imageKey1 = _computeImageKey(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1);
        bytes32 imageKey2 = _computeImageKey(MRTD_2, RTMR0_2, RTMR1_2, RTMR2_2);

        verifier.approveImage(imageKey1);
        verifier.approveImage(imageKey2);

        bytes32 reportData = bytes32(uint256(0x42));

        // Image 1 passes
        MockDcapVerifier(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F).setOutput(
            _buildDcapOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, reportData)
        );
        assertTrue(verifier.verifyAttestation(bytes("quote"), reportData));

        // Image 2 passes
        MockDcapVerifier(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F).setOutput(
            _buildDcapOutput(MRTD_2, RTMR0_2, RTMR1_2, RTMR2_2, reportData)
        );
        assertTrue(verifier.verifyAttestation(bytes("quote"), reportData));

        // Unknown image fails
        bytes memory unknownMrtd = hex"ff00ff000000000000000000000000000000000000000000000000000000000000000000000000000000000000000099";
        MockDcapVerifier(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F).setOutput(
            _buildDcapOutput(unknownMrtd, RTMR0_1, RTMR1_1, RTMR2_1, reportData)
        );
        assertFalse(verifier.verifyAttestation(bytes("quote"), reportData));
    }

    function test_compute_image_key_matches() public view {
        bytes32 expected = _computeImageKey(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1);
        bytes32 actual = verifier.computeImageKey(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1);
        assertEq(expected, actual);
    }

    function test_nonzero_reportdata_padding_rejected() public {
        _setupApprovedImage1();

        bytes32 reportData = bytes32(uint256(0x42));
        bytes memory output = _buildDcapOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, reportData);

        // Set non-zero padding in REPORTDATA bytes 32-63
        output[563] = 0xff;

        MockDcapVerifier(0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F).setOutput(output);

        bool valid = verifier.verifyAttestation(bytes("quote"), reportData);
        assertFalse(valid);
    }
}
