// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TdxVerifier.sol";
import "../src/interfaces/IAutomataDcapAttestation.sol";

contract TdxMockDcapVerifier is IAutomataDcapAttestation {
    bool public shouldSucceed = true;
    bytes public craftedOutput;

    function setOutput(bytes memory _output) external { craftedOutput = _output; }
    function setShouldSucceed(bool _succeed) external { shouldSucceed = _succeed; }

    function verifyAndAttestOnChain(bytes calldata)
        external payable returns (bool, bytes memory)
    {
        return (shouldSucceed, craftedOutput);
    }
}

contract TdxVerifierTest is Test {
    TdxVerifier public verifier;

    // Measurements (48 bytes each)
    bytes constant MRTD_1 = hex"aabbccdd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000011";
    bytes constant RTMR0_1 = hex"111111110000000000000000000000000000000000000000000000000000000000000000000000000000000000000022";
    bytes constant RTMR1_1 = hex"222222220000000000000000000000000000000000000000000000000000000000000000000000000000000000000033";
    bytes constant RTMR2_1 = hex"333333330000000000000000000000000000000000000000000000000000000000000000000000000000000000000044";
    bytes constant RTMR3_1 = hex"444444440000000000000000000000000000000000000000000000000000000000000000000000000000000000000055";

    // Set 2
    bytes constant MRTD_2 = hex"bbbbbbbb0000000000000000000000000000000000000000000000000000000000000000000000000000000000000066";
    bytes constant RTMR1_2 = hex"666666660000000000000000000000000000000000000000000000000000000000000000000000000000000000000077";
    bytes constant RTMR2_2 = hex"777777770000000000000000000000000000000000000000000000000000000000000000000000000000000000000088";

    // Alternative firmware
    bytes constant MRTD_ALT = hex"deadbeef0000000000000000000000000000000000000000000000000000000000000000000000000000000000000055";
    bytes constant RTMR0_ALT = hex"555555550000000000000000000000000000000000000000000000000000000000000000000000000000000000000066";

    address constant DCAP_ADDR = 0x95175096a9B74165BE0ac84260cc14Fc1c0EF5FF;

    function setUp() public {
        TdxMockDcapVerifier mockDcap = new TdxMockDcapVerifier();
        verifier = new TdxVerifier(address(0));
        vm.etch(DCAP_ADDR, address(mockDcap).code);
        TdxMockDcapVerifier(DCAP_ADDR).setShouldSucceed(true);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _buildDcapOutput(
        bytes memory mrtd, bytes memory rtmr0,
        bytes memory rtmr1, bytes memory rtmr2, bytes memory rtmr3,
        bytes32 reportData
    ) internal pure returns (bytes memory) {
        bytes memory output = new bytes(595);
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

    /// @dev imageKey = sha256(MRTD || RTMR[1] || RTMR[2])
    function _imageKey(bytes memory mrtd, bytes memory rtmr1, bytes memory rtmr2)
        internal pure returns (bytes32)
    {
        return sha256(abi.encodePacked(mrtd, rtmr1, rtmr2));
    }

    function _approveImage1() internal {
        verifier.approveImage(_imageKey(MRTD_1, RTMR1_1, RTMR2_1));
    }

    function _setupMockOutput(
        bytes memory mrtd, bytes memory rtmr0,
        bytes memory rtmr1, bytes memory rtmr2, bytes memory rtmr3,
        bytes32 inputHash, bytes32 outputHash
    ) internal {
        bytes32 reportData = sha256(abi.encodePacked(inputHash, outputHash));
        TdxMockDcapVerifier(DCAP_ADDR).setOutput(
            _buildDcapOutput(mrtd, rtmr0, rtmr1, rtmr2, rtmr3, reportData)
        );
    }

    // ─── Tests: Image Registry ────────────────────────────────────────────

    function test_approve_image() public {
        bytes32 key = _imageKey(MRTD_1, RTMR1_1, RTMR2_1);
        assertFalse(verifier.approvedImages(key));
        verifier.approveImage(key);
        assertTrue(verifier.approvedImages(key));
    }

    function test_revoke_image() public {
        bytes32 key = _imageKey(MRTD_1, RTMR1_1, RTMR2_1);
        verifier.approveImage(key);
        verifier.revokeImage(key);
        assertFalse(verifier.approvedImages(key));
    }

    function test_only_owner_can_approve() public {
        bytes32 key = _imageKey(MRTD_1, RTMR1_1, RTMR2_1);
        vm.prank(address(0xdead));
        vm.expectRevert(TdxVerifier.Unauthorized.selector);
        verifier.approveImage(key);
    }

    // ─── Tests: Verification ──────────────────────────────────────────────

    function test_approved_image_passes() public {
        _approveImage1();
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

    function test_different_mrtd_rejected() public {
        // Approve image with MRTD_1. Different MRTD means different firmware → rejected.
        _approveImage1();
        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));
        _setupMockOutput(MRTD_ALT, RTMR0_1, RTMR1_1, RTMR2_1, RTMR3_1, inputHash, outputHash);
        assertFalse(verifier.verify(inputHash, outputHash, bytes("quote")));
    }

    function test_different_rtmr0_accepted() public {
        // RTMR[0] (hardware config) is NOT checked — different VM sizes OK
        _approveImage1();
        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));
        _setupMockOutput(MRTD_1, RTMR0_ALT, RTMR1_1, RTMR2_1, RTMR3_1, inputHash, outputHash);
        assertTrue(verifier.verify(inputHash, outputHash, bytes("quote")));
    }

    function test_any_rtmr3_accepted() public {
        // RTMR[3] is NOT checked — dm-verity covers everything via RTMR[2]
        _approveImage1();
        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));

        // RTMR[3] = zeros (no extension) — passes
        bytes memory rtmr3_zeros = hex"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
        _setupMockOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, rtmr3_zeros, inputHash, outputHash);
        assertTrue(verifier.verify(inputHash, outputHash, bytes("quote")));

        // RTMR[3] = non-zero (some extension) — also passes
        _setupMockOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, RTMR3_1, inputHash, outputHash);
        assertTrue(verifier.verify(inputHash, outputHash, bytes("quote")));
    }

    function test_different_rtmr2_rejected() public {
        // RTMR[2] contains dm-verity rootfs hash — different rootfs → rejected
        _approveImage1();
        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));
        _setupMockOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_2, RTMR3_1, inputHash, outputHash);
        assertFalse(verifier.verify(inputHash, outputHash, bytes("quote")));
    }

    function test_reportdata_mismatch_rejected() public {
        _approveImage1();
        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));
        _setupMockOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, RTMR3_1, inputHash, outputHash);
        assertFalse(verifier.verify(inputHash, bytes32(uint256(0x99)), bytes("quote")));
    }

    function test_dcap_failure_rejected() public {
        _approveImage1();
        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));
        _setupMockOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, RTMR3_1, inputHash, outputHash);
        TdxMockDcapVerifier(DCAP_ADDR).setShouldSucceed(false);
        assertFalse(verifier.verify(inputHash, outputHash, bytes("quote")));
    }

    function test_nonzero_reportdata_padding_rejected() public {
        _approveImage1();
        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));
        bytes32 reportData = sha256(abi.encodePacked(inputHash, outputHash));
        bytes memory output = _buildDcapOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, RTMR3_1, reportData);
        output[563] = 0xff;
        TdxMockDcapVerifier(DCAP_ADDR).setOutput(output);
        assertFalse(verifier.verify(inputHash, outputHash, bytes("quote")));
    }

    // ─── Tests: computeImageKey ──────────────────────────────────────────

    function test_compute_image_key_matches() public view {
        bytes32 expected = _imageKey(MRTD_1, RTMR1_1, RTMR2_1);
        bytes32 actual = verifier.computeImageKey(MRTD_1, RTMR1_1, RTMR2_1);
        assertEq(expected, actual);
    }

    // ─── Tests: Multiple images ─────────────────────────────────────────

    function test_multiple_images() public {
        // GCP image
        verifier.approveImage(_imageKey(MRTD_1, RTMR1_1, RTMR2_1));
        // Phala/other platform image (different MRTD + kernel)
        verifier.approveImage(_imageKey(MRTD_2, RTMR1_2, RTMR2_2));

        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));

        _setupMockOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, RTMR3_1, inputHash, outputHash);
        assertTrue(verifier.verify(inputHash, outputHash, bytes("quote")));

        _setupMockOutput(MRTD_2, RTMR0_1, RTMR1_2, RTMR2_2, RTMR3_1, inputHash, outputHash);
        assertTrue(verifier.verify(inputHash, outputHash, bytes("quote")));
    }

    // ─── Tests: Freeze ──────────────────────────────────────────────────

    function test_freeze() public {
        _approveImage1();
        verifier.freeze();
        assertTrue(verifier.frozenImages());
        bytes32 key2 = _imageKey(MRTD_2, RTMR1_2, RTMR2_2);
        vm.expectRevert(TdxVerifier.Frozen.selector);
        verifier.approveImage(key2);
    }

    function test_freeze_only_owner() public {
        vm.prank(address(0xdead));
        vm.expectRevert(TdxVerifier.Unauthorized.selector);
        verifier.freeze();
    }

    function test_freeze_verification_still_works() public {
        _approveImage1();
        verifier.freeze();
        bytes32 inputHash = bytes32(uint256(0x1));
        bytes32 outputHash = bytes32(uint256(0x2));
        _setupMockOutput(MRTD_1, RTMR0_1, RTMR1_1, RTMR2_1, RTMR3_1, inputHash, outputHash);
        assertTrue(verifier.verify(inputHash, outputHash, bytes("quote")));
    }
}
