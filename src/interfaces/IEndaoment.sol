// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal interface for Endaoment's OrgFundFactory on Base.
///         Used to compute deterministic org addresses from EINs and deploy orgs.
///         Factory address on Base: 0x10fd9348136dcea154f752fe0b6db45fc298a589
interface IEndaomentFactory {
    /// @notice Compute the deterministic address for an org given its EIN.
    /// @param orgId The EIN encoded as bytes32 (e.g., formatBytes32String("52-0907625"))
    function computeOrgAddress(bytes32 orgId) external view returns (address);

    /// @notice Deploy an org contract for the given EIN. Idempotent if already deployed.
    function deployOrg(bytes32 orgId) external returns (address);
}

/// @notice Minimal interface for an Endaoment Entity (Org) contract.
///         Orgs accept USDC donations via donate().
interface IEndaomentOrg {
    /// @notice Donate USDC to this org. Caller must have approved USDC first.
    /// @param amount Amount of USDC (6 decimals) to donate.
    function donate(uint256 amount) external;
}
