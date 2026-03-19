// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/TheHumanFund.sol";
import "../src/AttestationVerifier.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 seedAmount = vm.envOr("SEED_AMOUNT", uint256(0.01 ether));

        // Testnet nonprofit addresses (use deployer address as placeholder)
        address deployer = vm.addr(deployerPrivateKey);
        address payable np1 = payable(vm.envOr("NONPROFIT_1", deployer));
        address payable np2 = payable(vm.envOr("NONPROFIT_2", deployer));
        address payable np3 = payable(vm.envOr("NONPROFIT_3", deployer));

        string[3] memory names = [
            "GiveDirectly",
            "Against Malaria Foundation",
            "Helen Keller International"
        ];
        address payable[3] memory addrs = [np1, np2, np3];

        vm.startBroadcast(deployerPrivateKey);

        TheHumanFund fund = new TheHumanFund{value: seedAmount}(
            names,
            addrs,
            1000,           // 10% initial commission
            0.0001 ether    // initial max bid (minimum allowed)
        );

        // Deploy attestation verifier and link to fund
        AttestationVerifier verifier = new AttestationVerifier();
        fund.setVerifier(address(verifier));

        console.log("TheHumanFund deployed at:", address(fund));
        console.log("AttestationVerifier deployed at:", address(verifier));
        console.log("Seed amount:", seedAmount);
        console.log("Owner:", deployer);
        console.log("");
        console.log("Next steps:");
        console.log("  1. Compute image key: verifier.computeImageKey(mrtd, rtmr0, rtmr1, rtmr2)");
        console.log("  2. Approve image: verifier.approveImage(imageKey)");
        console.log("  3. Enable auction: fund.setAuctionEnabled(true)");

        vm.stopBroadcast();
    }
}
