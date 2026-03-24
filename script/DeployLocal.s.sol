// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/TheHumanFund.sol";
import "../src/TdxVerifier.sol";
import "../src/interfaces/IAutomataDcapAttestation.sol";

/// @dev Mock DCAP verifier for local testing — accepts any quote and returns
///      crafted output with the caller-provided REPORTDATA.
///      In local testing, the enclave produces mock attestation bytes that
///      embed the REPORTDATA directly, so we just pass them through.
contract LocalMockDcapVerifier is IAutomataDcapAttestation {
    function verifyAndAttestOnChain(bytes calldata rawQuote)
        external payable returns (bool, bytes memory)
    {
        // The mock enclave sends report_data as the "quote"
        // We need to build a fake DCAP output with REPORTDATA at the right offset
        // For local testing: always return success with a crafted output
        // that has the REPORTDATA from the rawQuote placed at byte 531

        bytes memory output = new bytes(595);
        // Header
        output[0] = 0x00; output[1] = 0x04; // version 4
        output[2] = 0x00; output[3] = 0x02; // TDX

        // Place approved MRTD + RTMR[0..2] at correct offsets
        // Use all-zeros for local testing — the approved image key will match
        // (we approve the all-zeros image key)

        // Place REPORTDATA at offset 531 from the rawQuote
        // The mock enclave sends compute_report_data output (64 bytes) as rawQuote
        uint256 len = rawQuote.length < 64 ? rawQuote.length : 64;
        for (uint256 i = 0; i < len; i++) {
            output[531 + i] = rawQuote[i];
        }

        return (true, output);
    }
}

contract DeployLocal is Script {
    function run() external {
        // Anvil's first default private key
        uint256 deployerKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // 1. Deploy mock DCAP verifier at the hardcoded Automata address
        LocalMockDcapVerifier mockDcap = new LocalMockDcapVerifier();
        // We need to etch the mock at the constant address — but forge script can't vm.etch
        // Instead, we'll deploy the verifier with a reference to our mock
        // Actually for local testing, we can just deploy at a normal address
        // and the AttestationVerifier will call the hardcoded address which won't exist
        // We need a different approach...

        // Deploy TheHumanFund (use deployer as placeholder for Endaoment/DeFi addresses in local mode)
        TheHumanFund fund = new TheHumanFund{value: 1 ether}(
            1000,           // 10% commission
            0.001 ether,    // max bid
            deployer,       // endaoment factory (placeholder)
            deployer,       // weth (placeholder)
            deployer,       // usdc (placeholder)
            deployer,       // swap router (placeholder)
            address(0)      // ethUsdFeed (not needed for local testing)
        );

        // Add test nonprofits
        fund.addNonprofit("GiveDirectly", "Cash transfers to extreme poverty", bytes32("27-1661997"));
        fund.addNonprofit("EFF", "Digital civil liberties", bytes32("04-3091431"));
        fund.addNonprofit("MSF", "Emergency medical care", bytes32("13-3433452"));

        // Deploy TdxVerifier
        TdxVerifier verifier = new TdxVerifier(address(fund));

        // Approve the all-zeros image key (local testing — no real RTMR values)
        // Now only RTMR[1] + RTMR[2] = 96 bytes
        bytes memory zeros96 = new bytes(96);
        bytes32 imageKey = keccak256(zeros96);
        verifier.approveImage(imageKey);

        // Register TDX verifier at ID 1
        fund.approveVerifier(1, address(verifier));

        // Configure short timing for local testing (30s epoch, 10s bid, 15s exec)
        fund.setAuctionTiming(30, 10, 5, 10);
        fund.setAuctionEnabled(true);

        console.log("=== Local Deployment ===");
        console.log("TheHumanFund:", address(fund));
        console.log("TdxVerifier (ID 1):", address(verifier));
        console.log("MockDcapVerifier:", address(mockDcap));
        console.log("Deployer:", deployer);
        console.log("");
        console.log("Timing: 30s epoch, 10s bid window, 15s exec window");
        console.log("Auction: enabled");
        console.log("");
        console.log("NOTE: Mock DCAP at", address(mockDcap), "but Automata constant is 0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F");
        console.log("For local testing, use --unlocked to etch mock code at the constant address");

        vm.stopBroadcast();
    }
}
