// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/AgentMemory.sol";
import "../../src/interfaces/IAgentMemory.sol";
import "../../src/interfaces/IInvestmentManager.sol";

/// @title DeployAgentMemory
/// @notice Additive deploy on top of the live Human Fund system. Builds a
///         new `AgentMemory` contract whose `getEntries()` returns the
///         agent's 10 mutable slots PLUS per-protocol (name, description)
///         pairs sourced live from `InvestmentManager`. The new contract
///         is intended to replace the legacy v1 at `0x8de1Bb…` via a
///         subsequent `fund.setAgentMemory(<new>)` call (owner-only).
///
///         Does NOT call `fund.setAgentMemory(...)` or `fund.seedMemory(...)`.
///         Those are separate signer steps in the migration ceremony.
///         The script prints the exact next-step calls when it finishes.
///
/// Two signing modes --pick one:
///
/// 1. Keystore (mainnet, recommended):
///        forge script deploy/mainnet/DeployAgentMemory.s.sol:DeployAgentMemory \
///          --account <name> --sender 0x<deployer-address> \
///          --rpc-url $RPC_URL --broadcast --verify
///
/// 2. Env private key (testnet/local convenience):
///        export PRIVATE_KEY=0x...
///        forge script deploy/mainnet/DeployAgentMemory.s.sol:DeployAgentMemory \
///          --rpc-url $RPC_URL --broadcast
///
/// Required env (with Base-mainnet defaults --unset to use defaults):
///   FUND                --TheHumanFund address
///                           default: 0x678dC1756b123168f23a698374C000019e38318c
///   INVESTMENT_MANAGER  --InvestmentManager address
///                           default: 0x2fab8aE91B9EB3BaB18531594B20e0e086661892
///
/// ⚠️ `.env` footgun (also flagged in costanza_adapter_runbook.md): Forge
/// auto-loads `.env` from the project root regardless of shell unsets. If
/// your `.env` has a stale `INVESTMENT_MANAGER` from testnet work, pass it
/// inline at the forge invocation to override:
///
///     INVESTMENT_MANAGER=0x2fab8aE91B9EB3BaB18531594B20e0e086661892 \
///         forge script deploy/mainnet/DeployAgentMemory.s.sol:DeployAgentMemory ...
contract DeployAgentMemory is Script {
    // ─── Base mainnet defaults ──────────────────────────────────────────

    address constant DEFAULT_FUND               = 0x678dC1756b123168f23a698374C000019e38318c;
    address constant DEFAULT_INVESTMENT_MANAGER = 0x2fab8aE91B9EB3BaB18531594B20e0e086661892;

    function run() external {
        address fund = vm.envOr("FUND",               DEFAULT_FUND);
        address im   = vm.envOr("INVESTMENT_MANAGER", DEFAULT_INVESTMENT_MANAGER);

        require(fund != address(0), "FUND is zero");
        require(im   != address(0), "INVESTMENT_MANAGER is zero");

        // Sanity-check at deploy time: the IM address must respond to
        // protocolCount(). This catches the most likely misconfiguration
        // (wrong IM address pasted in) before we deploy a broken
        // AgentMemory.
        uint256 protoCount = IInvestmentManager(im).protocolCount();
        require(protoCount > 0, "IM reports protocolCount=0 (wrong address?)");

        // ─── Sign mode: env-key or keystore ─────────────────────────────

        uint256 deployerPk = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer;
        if (deployerPk != 0) {
            deployer = vm.addr(deployerPk);
            vm.startBroadcast(deployerPk);
        } else {
            deployer = msg.sender;
            vm.startBroadcast();
        }

        // ─── Deploy ─────────────────────────────────────────────────────

        AgentMemory mem = new AgentMemory(fund, im);

        vm.stopBroadcast();

        // ─── Verify wiring + summary ────────────────────────────────────

        bytes32 hash0 = mem.stateHash();
        IAgentMemory.MemoryEntry[] memory entries = mem.getEntries();

        console.log("");
        console.log("=== AgentMemory Deployment ===");
        console.log("Deployer:             ", deployer);
        console.log("");
        console.log("--- Contract ---");
        console.log("AgentMemory (NEW):    ", address(mem));
        console.log("");
        console.log("--- Wiring (immutable; verify before setAgentMemory) ---");
        console.log("fund:                 ", mem.fund());
        console.log("investmentManager:    ", address(mem.investmentManager()));
        console.log("NUM_SLOTS:            ", mem.NUM_SLOTS());
        console.log("");
        console.log("--- Initial state ---");
        console.log("getEntries() length:  ", entries.length);
        console.log("  NUM_SLOTS:          ", mem.NUM_SLOTS());
        console.log("  IM.protocolCount(): ", protoCount);
        console.log("stateHash():");
        console.logBytes32(hash0);
        console.log("");
        console.log("--- Next steps (owner ceremony) ---");
        console.log("");
        console.log("(a) Pause the Hetzner runner cron --no in-flight epoch should");
        console.log("    span the setAgentMemory swap. See agentmemory_runbook.md.");
        console.log("");
        console.log("(b) Read v1's slot contents (for the re-seed in step d):");
        console.log("    V1=0x8de1BbFA2200A9104e3C08a00F96C2c8Ee073346");
        console.log("    for i in 0..9: cast call $V1 'getEntry(uint256)' $i --rpc-url ...");
        console.log("    Capture (slot, title, body) tuples for non-empty slots.");
        console.log("");
        console.log("(c) Point fund at the new AgentMemory (owner-only):");
        console.log("    cast send $FUND 'setAgentMemory(address)'", address(mem));
        console.log("        --rpc-url https://mainnet.base.org --account humanfund-deploy");
        console.log("");
        console.log("(d) Re-seed mutable slots from v1's captured tuples (owner-only):");
        console.log("    cast send $FUND 'seedMemory(uint256[],string[],string[])' \\");
        console.log("        \"[<slots>]\" '[<titles>]' '[<bodies>]' \\");
        console.log("        --rpc-url https://mainnet.base.org --account humanfund-deploy");
        console.log("");
        console.log("(e) Build + register a new dm-verity TEE image whose");
        console.log("    prover/enclave/* hashes the new variable-length memory");
        console.log("    list. Update Hetzner GCP_IMAGE env. See runbook.");
        console.log("");
        console.log("(f) Resume the runner cron.");
        console.log("");
        console.log("Rollback (if anything's wrong post-step c): owner re-points");
        console.log("setAgentMemory(0x8de1BbFA2200A9104e3C08a00F96C2c8Ee073346) --v1");
        console.log("stays deployed with its original entries.");
    }
}
