// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAutomataDcapAttestation
/// @notice Interface for calling the Automata DCAP attestation verifier.
///         Deployed at the same address on all chains via CREATE2:
///         0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F
interface IAutomataDcapAttestation {
    /// @notice Verify a raw DCAP attestation quote on-chain.
    /// @param rawQuote The raw TDX/SGX attestation quote bytes.
    /// @return success Whether the quote is valid.
    /// @return output The decoded attestation output (contains report data, RTMR values, etc.).
    function verifyAndAttestOnChain(bytes calldata rawQuote)
        external
        payable
        returns (bool success, bytes memory output);
}
