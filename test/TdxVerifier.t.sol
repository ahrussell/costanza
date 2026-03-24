// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TdxVerifier.sol";
import "../src/interfaces/IAutomataDcapAttestation.sol";

/// @title Mock DCAP verifier for testing
contract TdxMockDcapVerifier is IAutomataDcapAttestation {
    bool public shouldSucceed = true;
    bytes public craftedOutput;

    function setOutput(bytes memory _output) external {
        craftedOutput = _output;
    }

    function setShouldSucceed(bool _succeed) external {
        shouldSucceed = _succeed;
    }

    function verifyAndAttestOnChain(bytes calldata)
        external payable returns (bool, bytes memory)
    {
        return (shouldSucceed, craftedOutput);
    }
}

contract TdxVerifierTest is Test {
    TdxVerifier public verifier;

    // Test measurement values (48 bytes each, SHA-384)
    // MRTD and RTMR[0] are NOT verified by TdxVerifier — only used in DCAP output construction
    bytes constant MRTD_1 = hex"aabbccdd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000011";
    bytes constant RTMR0_1 = hex"111111110000000000000000000000000000000000000000000000000000000000000000000000000000000000000022";
    bytes constant RTMR1_1 = hex"222222220000000000000000000000000000000000000000000000000000000000000000000000000000000000000033";
    bytes constant RTMR2_1 = hex"333333330000000000000000000000000000000000000000000000000000000000000000000000000000000000000044";
    bytes constant RTMR3_1 = hex"444444440000000000000000000000000000000000000000000000000000000000000000000000000000000000000055";

    // Second set — different kernel + app + code
    bytes constant RTMR1_2 = hex"666666660000000000000000000000000000000000000000000000000000000000000000000000000000000000000077";
    bytes constant RTMR2_2 = hex"777777770000000000000000000000000000000000000000000000000000000000000000000000000000000000000088";
    bytes constant RTMR3_2 = hex"888888880000000000000000000000000000000000000000000000000000000000000000000000000000000000000099";

    // Alternative firmware — same kernel + app + code as set 1, different MRTD/RTMR[0]
    bytes constant MRTD_ALT = hex"deadbeef0000000000000000000000000000000000000000000000000000000000000000000000000000000000000055";
    bytes constant RTMR0_ALT = hex"555555550000000000000000000000000000000000000000000000000000000000000000000000000000000000000066";

    // Alternative application code — same kernel as set 1, different RTMR[3]
    bytes constant RTMR3_ALT = hex"eeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000099";

    address constant DCAP_ADDR = 0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F;

    function setUp() public {
        TdxMockDcapVerifier mockDcap = new TdxMockDcapVerifier();
        verifier = new TdxVerifier(address(0));

        bytes memory mockCode = address(mockDcap).code;
        vm.etch(DCAP_ADDR, mockCode);

        TdxMockDcapVerifier(DCAP_ADDR).setShouldSucceed(true);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _buildDcapOutput(
        bytes memory mrtd,
        bytes memory rtmr0,
        bytes memory rtmr1,
        bytes memory rtmr2,
        bytes memory rtmr3,
        bytes32 reportData
    ) internal pure returns (bytes memory) {
        bytes memory output = new bytes(595);
        output[0] = 0x00; output[1] = 0x04; // version 4
        output[2] = 0x00; output[3] = 0x02; // TDX TD10
        output[4] = 0x00; // tcbStatus OK

        for (uint256 i = 0; i < 48; i++) {
            output[147 + i] = mrtd[i];
            output[339 + i] = rtmr0[i];
            output[387 + i] = rtmr1[i];
            output[435 + i] = rtmr2[i];
            output[483 + i] = rtmr3[i];
        }
        for (uint256 i = 0; i < 32; i++) {
            output[531 + i] = reportData[i];
        }
        return output;
    }

    function _imageKey(bytes memory rtmr1, bytes memory rtmr2, bytes memory rtmr3) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(rtmr1, rtmr2, rtmr3));
    }

    function _setupApprovedImage1() internal {
        verifier.approveImage(_imageKey(RTMR1_1, RTMR2_1, RTMR3_1));
    }

    function _setupMockOutput(
        bytes memory mrtd, bytes memory rtmr0,
        bytes memory rtmr1, bytes memory rtmr2, bytes memory rtmr3,
        bytes32 inputHash, bytes32 outputHash
    ) internal {
        bytes32 reportData = sha256(abi.encodePacked(inputHash, outputHash));
        bytes memory output = _buildDcapOutput(mrtd, rtmr0, rtmr1, rtmr2, rtmr3, reportData);
        TdxMockDcapVerifier(DCAP_ADDR).setOutput(output);
    }

    // ─── Tests: Image Registry ────────────────────────────────────────────

    function test_approve_image() public {
        bytes32 key = _imageKey(RTMR1_1, RTMR2_1, RTMR3_1);
        assertFalse(verifier.approvedImages(key));
        verifier.approveImage(key);
        assertTrue(verifier.approvedImages(key));
    }

    function test_revoke_image() public {
        bytes32 key = _imageKey(RTMR1_1, RTMR2_1, RTMR3_1);
        verifier.approveImage(key);
        verifier.revokeImage(key);
        assertFalse(verifier.approvedImages(key));
    }

    function test_only_owner_can_approve() public {
        vm.prank(address(0xdead));
        vm.expectRevert(TdxVerifier.Unauthorized.selector);
        verifier.approveImage(_imageKey(RTMR1_1, RTMR2_1, RTMR3_1));
    }

    function test_only_owner_can_revoke() public {
        bytes32 key = _imageKey(RTMR1_1, RTMR2_1, RTMR3_1);
        verifier.approveImage(key);
        vm.prank(address(0xdead));
        vm.expectRevert(TdxVerifier.Unauthorized.selector);
        verifier.revokeImage(key);
    }

    // ─── Tests: Verification ──────────────────────────────────────────────

    function test_approved_image_accepted() public {
        _setupApprovedImage1();
        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));
        _setupMockOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, RTMR3_1, inputHash, outputHash);
        assertTrue(verifier.verify(inputHash, outputHash, bytes("quote")));
    }

    function test_unapproved_image_rejected() public {
        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));
        _setupMockOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, RTMR3_1, inputHash, outputHash);
        assertFalse(verifier.verify(inputHash, outputHash, bytes("quote")));
    }

    function test_revoked_image_rejected() public {
        _setupApprovedImage1();
        verifier.revokeImage(_imageKey(RTMR1_1, RTMR2_1, RTMR3_1));
        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));
        _setupMockOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, RTMR3_1, inputHash, outputHash);
        assertFalse(verifier.verify(inputHash, outputHash, bytes("quote")));
    }

    function test_reportdata_mismatch_rejected() public {
        _setupApprovedImage1();
        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));
        bytes32 wrongOutput = bytes32(uint256(0x99));
        _setupMockOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, RTMR3_1, inputHash, outputHash);
        // Verify with wrong outputHash — REPORTDATA won't match
        assertFalse(verifier.verify(inputHash, wrongOutput, bytes("quote")));
    }

    function test_dcap_failure_rejected() public {
        _setupApprovedImage1();
        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));
        _setupMockOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, RTMR3_1, inputHash, outputHash);
        TdxMockDcapVerifier(DCAP_ADDR).setShouldSucceed(false);
        assertFalse(verifier.verify(inputHash, outputHash, bytes("quote")));
    }

    function test_multiple_approved_images() public {
        verifier.approveImage(_imageKey(RTMR1_1, RTMR2_1, RTMR3_1));
        verifier.approveImage(_imageKey(RTMR1_2, RTMR2_2, RTMR3_2));

        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));

        // Image 1 passes
        _setupMockOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, RTMR3_1, inputHash, outputHash);
        assertTrue(verifier.verify(inputHash, outputHash, bytes("quote")));

        // Image 2 passes
        _setupMockOutput(MRTD_1, RTMR0_1, RTMR1_2, RTMR2_2, RTMR3_2, inputHash, outputHash);
        assertTrue(verifier.verify(inputHash, outputHash, bytes("quote")));

        // Unknown kernel+app fails
        bytes memory unknownRtmr1 = hex"ff00ff000000000000000000000000000000000000000000000000000000000000000000000000000000000000000099";
        _setupMockOutput(MRTD_1, RTMR0_1, unknownRtmr1, RTMR2_1, RTMR3_1, inputHash, outputHash);
        assertFalse(verifier.verify(inputHash, outputHash, bytes("quote")));
    }

    // ─── Tests: Platform Portability ──────────────────────────────────────

    function test_different_firmware_same_kernel_app_code_accepted() public {
        // Approve image based on RTMR[1]+RTMR[2]+RTMR[3] only
        _setupApprovedImage1();

        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));

        // Original firmware — passes
        _setupMockOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, RTMR3_1, inputHash, outputHash);
        assertTrue(verifier.verify(inputHash, outputHash, bytes("quote")));

        // Different firmware (different MRTD + RTMR[0]), same kernel + app + code — still passes!
        _setupMockOutput(MRTD_ALT, RTMR0_ALT, RTMR1_1, RTMR2_1, RTMR3_1, inputHash, outputHash);
        assertTrue(verifier.verify(inputHash, outputHash, bytes("quote")));
    }

    function test_different_code_same_kernel_rejected() public {
        // Approve image with RTMR3_1
        _setupApprovedImage1();

        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));

        // Same kernel (RTMR[1]+[2]) but different application code (RTMR[3]) — rejected
        _setupMockOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, RTMR3_ALT, inputHash, outputHash);
        assertFalse(verifier.verify(inputHash, outputHash, bytes("quote")));
    }

    // ─── Tests: computeImageKey ──────────────────────────────────────────

    function test_compute_image_key_matches() public view {
        bytes32 expected = _imageKey(RTMR1_1, RTMR2_1, RTMR3_1);
        bytes32 actual = verifier.computeImageKey(RTMR1_1, RTMR2_1, RTMR3_1);
        assertEq(expected, actual);
    }

    // ─── Tests: REPORTDATA Padding ───────────────────────────────────────

    function test_nonzero_reportdata_padding_rejected() public {
        _setupApprovedImage1();
        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));
        bytes32 reportData = sha256(abi.encodePacked(inputHash, outputHash));
        bytes memory output = _buildDcapOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, RTMR3_1, reportData);

        // Set non-zero padding
        output[563] = 0xff;
        TdxMockDcapVerifier(DCAP_ADDR).setOutput(output);

        assertFalse(verifier.verify(inputHash, outputHash, bytes("quote")));
    }

    // ─── Kill Switch ──────────────────────────────────────────────────────

    function test_freeze() public {
        bytes32 key = _imageKey(RTMR1_1, RTMR2_1, RTMR3_1);
        verifier.approveImage(key);

        verifier.freeze();
        assertTrue(verifier.frozenImages());

        vm.expectRevert(TdxVerifier.Frozen.selector);
        verifier.approveImage(_imageKey(RTMR1_2, RTMR2_2, RTMR3_2));

        vm.expectRevert(TdxVerifier.Frozen.selector);
        verifier.revokeImage(key);
    }

    function test_freeze_onlyOwner() public {
        vm.prank(address(0xdead));
        vm.expectRevert(TdxVerifier.Unauthorized.selector);
        verifier.freeze();
    }

    function test_freeze_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit TdxVerifier.PermissionFrozen("images");
        verifier.freeze();
    }

    function test_freeze_idempotent() public {
        verifier.freeze();
        verifier.freeze(); // should not revert
        assertTrue(verifier.frozenImages());
    }

    function test_freeze_verification_still_works() public {
        // Approve an image, then freeze
        _setupApprovedImage1();
        verifier.freeze();

        // Verification should still work (freeze only blocks registry changes)
        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));
        _setupMockOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, RTMR3_1, inputHash, outputHash);
        assertTrue(verifier.verify(inputHash, outputHash, bytes("quote")));
    }
}
