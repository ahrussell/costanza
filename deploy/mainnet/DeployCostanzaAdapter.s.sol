// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/adapters/CostanzaTokenAdapter.sol";
import "../../src/adapters/V4PoolStateReader.sol";
import "../../src/adapters/V4SwapExecutor.sol";

/// @title DeployCostanzaAdapter
/// @notice Additive deploy on top of the live Human Fund system.
///         Deploys three contracts:
///           1. V4PoolStateReader (wraps PoolManager.extsload)
///           2. V4SwapExecutor    (per-pool, drives PoolManager.unlock)
///           3. CostanzaTokenAdapter (wires everything together)
///
///         Does NOT call `im.addProtocol(...)` or
///         `feeDistributor.updateBeneficiary(...)` — those are
///         separate signer ceremonies. The script prints the exact
///         next-step calls when it finishes.
///
/// Two signing modes — pick one:
///
/// 1. Keystore (mainnet, recommended):
///        forge script deploy/mainnet/DeployCostanzaAdapter.s.sol:DeployCostanzaAdapter \
///          --account <name> --sender 0x<deployer-address> \
///          --rpc-url $RPC_URL --broadcast --verify
///
/// 2. Env private key (testnet/local convenience):
///        export PRIVATE_KEY=0x...
///        forge script deploy/mainnet/DeployCostanzaAdapter.s.sol:DeployCostanzaAdapter \
///          --rpc-url $RPC_URL --broadcast
///
/// Required env (with Base-mainnet defaults — unset to use defaults):
///   FUND                — TheHumanFund address
///                           default: 0x678dC1756b123168f23a698374C000019e38318c
///   INVESTMENT_MANAGER  — InvestmentManager address
///                           default: 0x2fab8aE91B9EB3BaB18531594B20e0e086661892
///   COSTANZA_TOKEN      — $COSTANZA ERC-20 address
///                           default: 0x3D9761a43cF76dA6CA6b3F46666e5C8Fa0989Ba3
///   WETH                — Base WETH
///                           default: 0x4200000000000000000000000000000000000006
///   POOL_MANAGER        — V4 PoolManager singleton
///                           default: 0x498581fF718922c3f8e6A244956aF099B2652b2b
///   FEE_DISTRIBUTOR     — Doppler hook (also the PoolKey hooks address)
///                           default: 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544
///   POOL_FEE            — V4 fee field; 8388608 is the dynamic-fee sentinel
///                           default: 8388608
///   POOL_TICK_SPACING   — V4 tick spacing
///                           default: 200
///   MAX_NET_ETH_IN      — Lifetime cap on net ETH committed (wei)
///                           default: 5 ether
///
/// Optional env:
///   ADAPTER_OWNER       — If set, deployer transfers ownership to this
///                         address as the final step (Ownable2Step pending,
///                         so the new owner must `acceptOwnership`).
///
/// Optional env (migration deploy — used to seed v2 with v1's accumulators
/// before calling v1.migrate(v2)). Default to zero for fresh deploys.
///   INITIAL_CUMULATIVE_ETH_IN
///   INITIAL_CUMULATIVE_ETH_OUT
///   INITIAL_TOKENS_FROM_SWAPS_IN
///   INITIAL_TOKENS_FROM_SWAPS_OUT
///   INITIAL_LAST_DEPOSIT_EPOCH
///
/// @dev The adapter constructor enforces that the PoolKey must:
///        - reference $COSTANZA on either currency0 or currency1
///        - if not a native-ETH pool, the non-token side must equal WETH
///      So mis-pasted addresses will fail at deploy rather than silently
///      producing a broken adapter.
contract DeployCostanzaAdapter is Script {
    // ─── Base mainnet defaults ──────────────────────────────────────────

    address constant DEFAULT_FUND               = 0x678dC1756b123168f23a698374C000019e38318c;
    address constant DEFAULT_INVESTMENT_MANAGER = 0x2fab8aE91B9EB3BaB18531594B20e0e086661892;
    address constant DEFAULT_COSTANZA_TOKEN     = 0x3D9761a43cF76dA6CA6b3F46666e5C8Fa0989Ba3;
    address constant DEFAULT_WETH               = 0x4200000000000000000000000000000000000006;
    address constant DEFAULT_POOL_MANAGER       = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant DEFAULT_FEE_DISTRIBUTOR    = 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544;
    uint24  constant DEFAULT_POOL_FEE           = 8388608; // V4 dynamic-fee sentinel
    int24   constant DEFAULT_POOL_TICK_SPACING  = 200;
    uint256 constant DEFAULT_MAX_NET_ETH_IN     = 5 ether;

    // ─── Registration parameters (locked-in) ────────────────────────────
    //
    // These match what's documented in §6.5 of the design doc and what
    // the unit + cross-stack tests exercise. They're not parameterized
    // because changing them mid-deploy would invalidate the matching
    // test coverage — pick them by editing the constants if the design
    // genuinely changes.

    string constant ADAPTER_NAME = "Costanza Token";
    uint8  constant RISK_TIER     = 4;
    uint16 constant EXPECTED_APY_BPS = 0;

    function _description() internal pure returns (string memory) {
        return unicode"Your own memecoin, $COSTANZA. Speculative — buy/sell via deposit/withdraw; trading fees from other holders accrue to the fund and lower your per-token cost basis. The contract won't sell below cost basis, so a position can be locked during drawdowns. Lifetime cap: 5 ETH.";
    }

    function run() external {
        // ─── Resolve config ─────────────────────────────────────────────

        Cfg memory c = _loadConfig();

        // Validation that's cheap to do here (Solidity-level only). Pool
        // existence + liquidity gets sanity-checked after the state
        // reader deploys.
        require(c.fund != address(0), "FUND is zero");
        require(c.im != address(0), "INVESTMENT_MANAGER is zero");
        require(c.costanzaToken != address(0), "COSTANZA_TOKEN is zero");
        require(c.weth != address(0), "WETH is zero");
        require(c.poolManager != address(0), "POOL_MANAGER is zero");
        require(c.feeDistributor != address(0), "FEE_DISTRIBUTOR is zero");
        require(c.maxNetEthIn > 0, "MAX_NET_ETH_IN is zero");

        // PoolKey orientation: V4 sorts by address. $COSTANZA's address
        // sorts lower than WETH's on Base mainnet, so currency0 =
        // $COSTANZA. The adapter constructor double-checks this.
        PoolKey memory key = _buildPoolKey(c);

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

        // ─── 1. V4PoolStateReader (stateless) ───────────────────────────

        V4PoolStateReader stateReader = new V4PoolStateReader(c.poolManager);

        // Sanity-check: the live pool exists (sqrtPriceX96 > 0). If the
        // pool isn't initialized, getSpotSqrtPriceX96 returns 0, and we
        // would deploy an adapter that can never quote. Bail loudly.
        bytes32 poolId = keccak256(abi.encode(key));
        uint160 sqrtPriceX96 = stateReader.getSpotSqrtPriceX96(poolId);
        require(sqrtPriceX96 > 0, "Pool not initialized at given PoolKey - check fee/tickSpacing/hooks");

        // ─── 2. V4SwapExecutor (per-pool) ───────────────────────────────

        // V4SwapExecutor uses its own PoolKeyV4 struct (defined inside
        // the file to avoid an external V4 dependency). The fields match
        // PoolKey 1:1.
        PoolKeyV4 memory keyV4 = PoolKeyV4({
            currency0:   key.currency0,
            currency1:   key.currency1,
            fee:         key.fee,
            tickSpacing: key.tickSpacing,
            hooks:       key.hooks
        });
        V4SwapExecutor swapExecutor = new V4SwapExecutor(c.poolManager, keyV4);

        // ─── 3. CostanzaTokenAdapter ────────────────────────────────────

        // Fresh-deploy initial state defaults to all zero. For a
        // migration deploy, the caller pre-reads the predecessor's
        // public getters and feeds them in via env so v2's accounting
        // continues v1's unchanged. v1.migrate(v2) is the follow-up
        // step that actually moves the tokens + Doppler beneficiary.
        uint256 _ldeRaw = vm.envOr("INITIAL_LAST_DEPOSIT_EPOCH", uint256(0));
        require(_ldeRaw <= type(uint64).max, "INITIAL_LAST_DEPOSIT_EPOCH overflow");
        InitialState memory initial = InitialState({
            cumulativeEthIn:    vm.envOr("INITIAL_CUMULATIVE_ETH_IN",     uint256(0)),
            cumulativeEthOut:   vm.envOr("INITIAL_CUMULATIVE_ETH_OUT",    uint256(0)),
            tokensFromSwapsIn:  vm.envOr("INITIAL_TOKENS_FROM_SWAPS_IN",  uint256(0)),
            tokensFromSwapsOut: vm.envOr("INITIAL_TOKENS_FROM_SWAPS_OUT", uint256(0)),
            lastDepositEpoch:   uint64(_ldeRaw)
        });

        CostanzaTokenAdapter adapter = new CostanzaTokenAdapter(
            c.costanzaToken,
            c.weth,
            c.poolManager,
            address(stateReader),
            address(swapExecutor),
            c.feeDistributor,
            payable(c.fund),
            c.im,
            key,
            c.maxNetEthIn,
            initial
        );

        // ─── 4. Optional ownership transfer ─────────────────────────────

        address adapterOwner = vm.envOr("ADAPTER_OWNER", address(0));
        if (adapterOwner != address(0) && adapterOwner != deployer) {
            // Ownable2Step: this only sets pendingOwner; the new owner
            // must call `acceptOwnership()` to finalize.
            adapter.transferOwnership(adapterOwner);
        }

        vm.stopBroadcast();

        // ─── Summary + next-step instructions ───────────────────────────

        console.log("");
        console.log("=== Costanza Adapter Deployment ===");
        console.log("Deployer:                ", deployer);
        console.log("");
        console.log("--- Contracts ---");
        console.log("V4PoolStateReader:       ", address(stateReader));
        console.log("V4SwapExecutor:          ", address(swapExecutor));
        console.log("CostanzaTokenAdapter:    ", address(adapter));
        console.log("");
        console.log("--- Adapter wiring ---");
        console.log("Fund:                    ", c.fund);
        console.log("InvestmentManager:       ", c.im);
        console.log("$COSTANZA token:         ", c.costanzaToken);
        console.log("WETH:                    ", c.weth);
        console.log("PoolManager:             ", c.poolManager);
        console.log("FeeDistributor (Doppler):", c.feeDistributor);
        console.log("PoolKey.fee:             ", c.poolFee);
        console.log("PoolKey.tickSpacing:     ", uint256(int256(c.poolTickSpacing)));
        console.logBytes32(poolId);
        console.log("Live pool sqrtPriceX96:  ", uint256(sqrtPriceX96));
        console.log("MAX_NET_ETH_IN (wei):    ", c.maxNetEthIn);
        if (initial.cumulativeEthIn != 0
            || initial.cumulativeEthOut != 0
            || initial.tokensFromSwapsIn != 0
            || initial.tokensFromSwapsOut != 0
            || initial.lastDepositEpoch != 0) {
            console.log("");
            console.log("--- Migration deploy: seeded InitialState ---");
            console.log("cumulativeEthIn:        ", initial.cumulativeEthIn);
            console.log("cumulativeEthOut:       ", initial.cumulativeEthOut);
            console.log("tokensFromSwapsIn:      ", initial.tokensFromSwapsIn);
            console.log("tokensFromSwapsOut:     ", initial.tokensFromSwapsOut);
            console.log("lastDepositEpoch:       ", uint256(initial.lastDepositEpoch));
        }
        console.log("");
        console.log("--- Adapter ownership ---");
        if (adapterOwner != address(0) && adapterOwner != deployer) {
            console.log("Pending owner (must acceptOwnership):", adapterOwner);
        } else {
            console.log("Owner:                   ", deployer);
            console.log("(set ADAPTER_OWNER env to transfer to a Safe at deploy time)");
        }
        console.log("");
        console.log("--- Next steps ---");
        console.log("");
        console.log("(a) IM admin must register the adapter:");
        console.log("    investmentManager.addProtocol(");
        console.log("        adapter            =", address(adapter));
        console.log("        name               = \"Costanza Token\"");
        console.log("        description        = (locked-in string; see deploy script)");
        console.log("        riskTier           = 4");
        console.log("        expectedApyBps     = 0");
        console.log("    )");
        console.log("");
        console.log("(b) Current Doppler beneficiary must hand over the fee stream:");
        console.log("    feeDistributor.updateBeneficiary(");
        console.log("        poolId        = (logged above)");
        console.log("        newBeneficiary =", address(adapter));
        console.log("    )");
        console.log("");
        console.log("Order-independent: (a) before (b) just means fees");
        console.log("sit in the old beneficiary until step (b); (b) before");
        console.log("(a) means fees pile up in the adapter, claimable on");
        console.log("the first pokeFees() once registration completes.");
        console.log("");
        console.log("(c) After both land, optionally call adapter.pokeFees()");
        console.log("    to claim any pre-existing fees and seed the");
        console.log("    history-gate sample. Pre-funding 0.1 ETH of");
        console.log("    deposit through the IM is the lightest-touch way");
        console.log("    to verify the full flow before letting the agent");
        console.log("    drive it.");
    }

    // ─── Config helpers ─────────────────────────────────────────────────

    struct Cfg {
        address fund;
        address im;
        address costanzaToken;
        address weth;
        address poolManager;
        address feeDistributor;
        uint24  poolFee;
        int24   poolTickSpacing;
        uint256 maxNetEthIn;
    }

    function _loadConfig() internal view returns (Cfg memory c) {
        c.fund            = vm.envOr("FUND",               DEFAULT_FUND);
        c.im              = vm.envOr("INVESTMENT_MANAGER", DEFAULT_INVESTMENT_MANAGER);
        c.costanzaToken   = vm.envOr("COSTANZA_TOKEN",     DEFAULT_COSTANZA_TOKEN);
        c.weth            = vm.envOr("WETH",               DEFAULT_WETH);
        c.poolManager     = vm.envOr("POOL_MANAGER",       DEFAULT_POOL_MANAGER);
        c.feeDistributor  = vm.envOr("FEE_DISTRIBUTOR",    DEFAULT_FEE_DISTRIBUTOR);
        c.maxNetEthIn     = vm.envOr("MAX_NET_ETH_IN",     DEFAULT_MAX_NET_ETH_IN);

        // Numeric fields: Forge's vm.envOr doesn't support uint24/int24
        // directly. Read as uint256/int256 and narrow.
        uint256 feeRaw    = vm.envOr("POOL_FEE",           uint256(DEFAULT_POOL_FEE));
        int256  tsRaw     = vm.envOr("POOL_TICK_SPACING",  int256(DEFAULT_POOL_TICK_SPACING));
        require(feeRaw <= type(uint24).max, "POOL_FEE overflow");
        require(tsRaw >= type(int24).min && tsRaw <= type(int24).max, "POOL_TICK_SPACING out of range");
        c.poolFee         = uint24(feeRaw);
        c.poolTickSpacing = int24(tsRaw);
    }

    function _buildPoolKey(Cfg memory c) internal pure returns (PoolKey memory key) {
        // V4 sorts by address. On Base mainnet, $COSTANZA
        // (0x3D9761…) < WETH (0x4200…), so $COSTANZA = currency0.
        // We don't enforce ordering here — the adapter constructor
        // does, and it accepts either orientation.
        if (c.costanzaToken < c.weth) {
            key.currency0 = c.costanzaToken;
            key.currency1 = c.weth;
        } else {
            key.currency0 = c.weth;
            key.currency1 = c.costanzaToken;
        }
        key.fee         = c.poolFee;
        key.tickSpacing = c.poolTickSpacing;
        key.hooks       = c.feeDistributor; // Doppler hook IS the PoolKey hooks address
    }
}
