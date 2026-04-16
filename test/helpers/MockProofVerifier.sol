// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/interfaces/IProofVerifier.sol";

/// @dev Mock verifier that accepts any proof. Used by EpochTest to drive
///      epochs through the real auction path (commit → reveal → submit)
///      without needing a TDX enclave or DCAP attestation.
contract MockProofVerifier is IProofVerifier {
    function verify(bytes32, bytes32, bytes calldata) external payable override returns (bool) {
        return true;
    }

    function freeze() external override {}
}
