// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/adapters/CostanzaTokenAdapter.sol";

/// @title CostanzaTokenAdapterForkTest
/// @notice Mainnet-fork tests against the real $COSTANZA pool on Base.
///
/// @dev Currently a placeholder. To enable, fill in the TBD addresses
///      below and remove the `vm.skip(true)` lines. Run with:
///
///          forge test --match-path test/CostanzaTokenAdapterFork.t.sol \
///              --fork-url https://mainnet.base.org
///
///      The fork tests should exercise:
///        - Real V4 PoolManager state reads via the production
///          `V4PoolStateReader` wrapper (TBD, separate file).
///        - Real V4 oracle hook reads via the production `V4PoolOracle`
///          wrapper (TBD).
///        - Real swap execution against the production `V4SwapExecutor`
///          (UniversalRouter).
///        - Real fee distributor `claim()` shape against the actual
///          upstream contract.
///
///      Until those addresses + wrapper contracts exist, all tests
///      `vm.skip(true)` so the suite doesn't fail.
contract CostanzaTokenAdapterForkTest is Test {
    // ─── TBD: real Base mainnet addresses ───────────────────────────────
    //
    // Open question §10 of docs/COSTANZA_TOKEN_ADAPTER_DESIGN.md tracks these:
    //   - $COSTANZA token (open question §10.1: confirm)
    //   - V4 PoolManager singleton on Base
    //   - UniversalRouter on Base (V4-aware version)
    //   - PoolKey (currency0, currency1, fee, tickSpacing, hooks)
    //   - Fee distributor (typically a V4 hook)
    //   - Production wrapper contracts (V4PoolStateReader, V4PoolOracle,
    //     V4SwapExecutor) — TBD as separate src/adapters/ files
    address constant COSTANZA_TOKEN  = address(0); // TBD
    address constant POOL_MANAGER    = address(0); // TBD
    address constant UNIVERSAL_ROUTER = address(0); // TBD
    address constant FEE_DISTRIBUTOR = address(0); // TBD

    // Per CLAUDE.md
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant FUND = 0x678dC1756b123168f23a698374C000019e38318c;
    address constant IM   = 0x2fab8aE91B9EB3BaB18531594B20e0e086661892;

    modifier needsFork() {
        if (WETH.code.length == 0) {
            vm.skip(true);
            return;
        }
        _;
    }

    modifier needsAddresses() {
        if (COSTANZA_TOKEN == address(0)) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @notice Smoke test: deploy the adapter against real Base addresses
    ///         and verify basic shape (immutables read back, name correct).
    function test_fork_adapter_constructs() public needsFork needsAddresses {
        // PoolKey memory key = PoolKey({...});
        // CostanzaTokenAdapter adapter = new CostanzaTokenAdapter(...);
        // assertEq(adapter.name(), "Costanza Token");
        vm.skip(true);
    }

    /// @notice Round-trip a small deposit + withdraw against the real pool.
    function test_fork_real_pool_round_trip() public needsFork needsAddresses {
        // Deposit ~0.001 ETH (small enough to land within slippage bounds
        // on a thin pool). Withdraw all. Confirm tokensFromSwapsIn /
        // tokensFromSwapsOut accounting matches.
        vm.skip(true);
    }

    /// @notice Confirm the pool's oracle hook supports a 30-min TWAP.
    ///         If cardinality is too low this test fails — call
    ///         `increaseObservationCardinalityNext` on the pool before deploy.
    function test_fork_oracle_supports_30min_twap() public needsFork needsAddresses {
        // try IPoolOracle(oracleAddr).consultSqrtPriceX96(poolId, 1800) returns (uint160 v) {
        //     assertGt(v, 0);
        // } catch {
        //     fail("oracle missing 30-min TWAP — increase cardinality");
        // }
        vm.skip(true);
    }
}
