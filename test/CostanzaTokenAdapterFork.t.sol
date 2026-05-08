// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/adapters/CostanzaTokenAdapter.sol";
import "../src/adapters/IFeeDistributor.sol";
import "../src/adapters/IPoolStateReader.sol";
import "../src/adapters/V4PoolStateReader.sol";
import "../src/adapters/V4SwapExecutor.sol";

/// @title CostanzaTokenAdapterForkTest
/// @notice Mainnet-fork tests against the real $COSTANZA pool on Base.
///
/// Run with:
///   forge test --match-path test/CostanzaTokenAdapterFork.t.sol \
///       --fork-url https://mainnet.base.org
///
/// Tests skip cleanly without `--fork-url` (see `needsFork` modifier).
///
/// Coverage:
///   - V4PoolStateReader reads real PoolManager storage for the live pool.
///   - V4SwapExecutor performs an actual swap against the real V4
///     PoolManager + Doppler hook.
///   - End-to-end adapter deposit + withdraw round-trip against the
///     real pool, with a stand-in fund (vm.mockCall for currentEpoch).
///   - Doppler hook's `release` and `updateBeneficiary` ABI shapes
///     work as our `IFeeDistributor` interface assumes.
contract CostanzaTokenAdapterForkTest is Test {
    // ─── Real Base mainnet addresses ────────────────────────────────────
    address constant COSTANZA_TOKEN   = 0x3D9761a43cF76dA6CA6b3F46666e5C8Fa0989Ba3;
    address constant POOL_MANAGER     = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant DOPPLER_HOOK     = 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544;
    address constant WETH             = 0x4200000000000000000000000000000000000006;

    // PoolKey for the live $COSTANZA / WETH pool.
    uint24  constant POOL_FEE          = 8388608; // V4 dynamic-fee sentinel
    int24   constant POOL_TICK_SPACING = 200;
    bytes32 constant POOL_ID = 0x1d7463c5ce91bdd756546180433b37665c11d33063a55280f8db068f9af2d8cc;

    // Stand-ins (don't touch the real fund/IM in tests — too easy to
    // confuse a fork tx with a mainnet tx).
    address constant TEST_IM   = address(0xCAFE);
    address payable constant TEST_FUND = payable(address(0xFEED));

    modifier needsFork() {
        if (WETH.code.length == 0) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _poolKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0:   COSTANZA_TOKEN,
            currency1:   WETH,
            fee:         POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks:       DOPPLER_HOOK
        });
    }

    function _v4Key() internal pure returns (PoolKeyV4 memory) {
        return PoolKeyV4({
            currency0:   COSTANZA_TOKEN,
            currency1:   WETH,
            fee:         POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks:       DOPPLER_HOOK
        });
    }

    // ─── V4PoolStateReader against the real pool ─────────────────────────

    function test_fork_state_reader_reads_real_spot() public needsFork {
        V4PoolStateReader reader = new V4PoolStateReader(POOL_MANAGER);
        uint160 sqrt_ = reader.getSpotSqrtPriceX96(POOL_ID);
        // Pool is live and has been initialized — sqrtPriceX96 must be > 0.
        assertGt(uint256(sqrt_), 0, "spot sqrtPriceX96 should be > 0 for live pool");
        // Expected magnitude: sqrt(price). Initial tick was -231800;
        // post-LBA it's likely above MIN but well below MAX.
        // Just sanity-check it's in the V4 valid range.
        assertGt(uint256(sqrt_), 4295128739);
        assertLt(uint256(sqrt_), 1461446703485210103287273052203988822378723970342);
    }

    function test_fork_state_reader_reads_real_liquidity() public needsFork {
        V4PoolStateReader reader = new V4PoolStateReader(POOL_MANAGER);
        uint128 liq = reader.getActiveLiquidity(POOL_ID);
        // Active liquidity may be 0 if the pool is currently outside
        // any LP range, but it should be readable without reverting.
        // We just assert the call succeeded; the value itself is
        // informational.
        liq; // silence unused warning
        assertTrue(true);
    }

    // ─── V4SwapExecutor against the real pool ────────────────────────────

    function test_fork_swap_executor_buy_costanza() public needsFork {
        V4SwapExecutor exec = new V4SwapExecutor(POOL_MANAGER, _v4Key());

        // Wrap 0.001 ETH to WETH for the test contract.
        uint256 amountIn = 0.001 ether;
        vm.deal(address(this), amountIn);
        IWETH9(WETH).deposit{value: amountIn}();

        // Approve the executor to pull WETH.
        IWETH9(WETH).approve(address(exec), amountIn);

        uint256 costBalBefore = IERC20(COSTANZA_TOKEN).balanceOf(address(this));

        // Tiny minOut — we just want the swap to land. Real adapter
        // computes a tighter minOut via spot + 5% slippage.
        uint256 amountOut = exec.swap(WETH, COSTANZA_TOKEN, amountIn, 1);

        assertGt(amountOut, 0, "swap should return positive output");
        uint256 received = IERC20(COSTANZA_TOKEN).balanceOf(address(this)) - costBalBefore;
        assertEq(received, amountOut, "actual delta should match returned amountOut");
    }

    function test_fork_swap_executor_round_trip() public needsFork {
        V4SwapExecutor exec = new V4SwapExecutor(POOL_MANAGER, _v4Key());

        // Buy.
        uint256 amountIn = 0.001 ether;
        vm.deal(address(this), amountIn);
        IWETH9(WETH).deposit{value: amountIn}();
        IWETH9(WETH).approve(address(exec), amountIn);
        uint256 boughtTokens = exec.swap(WETH, COSTANZA_TOKEN, amountIn, 1);
        assertGt(boughtTokens, 0);

        // Sell back. Approve executor for the tokens.
        IERC20(COSTANZA_TOKEN).approve(address(exec), boughtTokens);
        uint256 ethBefore = IWETH9(WETH).balanceOf(address(this));
        uint256 wethOut = exec.swap(COSTANZA_TOKEN, WETH, boughtTokens, 1);
        assertGt(wethOut, 0);
        uint256 ethDelta = IWETH9(WETH).balanceOf(address(this)) - ethBefore;
        assertEq(ethDelta, wethOut);

        // Round-trip: lose to fees on both sides + slippage. Expect
        // somewhere in the 95-99% range of original on a thin pool.
        // Just sanity-check it's positive.
        assertLt(wethOut, amountIn, "round-trip should lose to fees");
    }

    // ─── End-to-end adapter against the real pool ────────────────────────

    /// @dev Deploy an adapter wired to the real V4 pool + Doppler hook,
    ///      with a vm.mockCall fund for `currentEpoch()`. We skip
    ///      registration with the real IM (don't touch mainnet state).
    function _deployForkAdapter() internal returns (CostanzaTokenAdapter) {
        V4PoolStateReader reader = new V4PoolStateReader(POOL_MANAGER);
        V4SwapExecutor exec      = new V4SwapExecutor(POOL_MANAGER, _v4Key());

        vm.mockCall(
            TEST_FUND,
            abi.encodeWithSignature("currentEpoch()"),
            abi.encode(uint256(1))
        );

        return new CostanzaTokenAdapter(
            COSTANZA_TOKEN,
            WETH,
            POOL_MANAGER,
            address(reader),
            address(exec),
            DOPPLER_HOOK,
            TEST_FUND,
            TEST_IM,
            _poolKey(),
            5 ether,                           // MAX_NET_ETH_IN
            InitialState(0, 0, 0, 0, 0)
        );
    }

    function test_fork_adapter_constructs() public needsFork {
        CostanzaTokenAdapter adapter = _deployForkAdapter();
        assertEq(adapter.name(), "Costanza Token");
        assertEq(address(adapter.costanzaToken()), COSTANZA_TOKEN);
        assertEq(adapter.poolManager(), POOL_MANAGER);
        assertFalse(adapter.nativeEthPool());     // WETH pool, not native
        assertTrue(adapter.tokenIsCurrency0());   // Costanza < WETH alphabetically
        assertEq(adapter.poolId(), POOL_ID);
    }

    function test_fork_adapter_balance_view_does_not_revert() public needsFork {
        CostanzaTokenAdapter adapter = _deployForkAdapter();
        // No tokens held; should return 0 without reverting.
        assertEq(adapter.balance(), 0);
    }

    function test_fork_adapter_deposit_works() public needsFork {
        CostanzaTokenAdapter adapter = _deployForkAdapter();

        uint256 amountIn = 0.001 ether;
        vm.deal(TEST_IM, amountIn);
        vm.prank(TEST_IM);
        uint256 shares = adapter.deposit{value: amountIn}();

        assertGt(shares, 0, "deposit should yield tokens");
        assertEq(adapter.cumulativeEthIn(), amountIn);
        assertEq(adapter.tokensFromSwapsIn(), shares);
        assertEq(IERC20(COSTANZA_TOKEN).balanceOf(address(adapter)), shares);
    }

    /// @dev With `SELL_FLOOR_BPS = 0`, an immediate post-buy sell at
    ///      the same price reverts: the round-trip would yield less
    ///      than cost basis (paying the pool's 0.7% fee on each leg).
    ///      This is the "Costanza never sells at a loss" invariant
    ///      demonstrated against the real pool — the adapter blocks
    ///      the lossy exit before the swap commits.
    function test_fork_adapter_immediate_round_trip_blocks_at_floor() public needsFork {
        CostanzaTokenAdapter adapter = _deployForkAdapter();

        uint256 amountIn = 0.001 ether;
        vm.deal(TEST_IM, amountIn);
        vm.prank(TEST_IM);
        uint256 shares = adapter.deposit{value: amountIn}();

        // Try immediate withdraw — should revert because the sell would
        // deliver less than cost basis (round-trip loses to fees).
        vm.warp(block.timestamp + 1);
        vm.prank(TEST_IM);
        vm.expectRevert(); // InsufficientOutput from V4SwapExecutor
        adapter.withdraw(shares);
    }

    // ─── Doppler hook ABI compatibility ──────────────────────────────────

    /// @dev Reality-check on Doppler: `release(poolId, beneficiary)`
    ///      reverts when the beneficiary is not registered. This is
    ///      exactly why the adapter wraps `feeDistributor.release(...)`
    ///      in a `try/catch` in `_claimAndForwardFees` — pre-registration
    ///      poke calls would otherwise revert the surrounding deposit
    ///      or withdraw.
    function test_fork_doppler_release_unregistered_beneficiary_reverts() public needsFork {
        IFeeDistributor hook = IFeeDistributor(DOPPLER_HOOK);
        address randomCaller = address(0xDEAD0BAD0);
        vm.prank(randomCaller);
        vm.expectRevert();
        hook.release(POOL_ID, randomCaller);
    }

    /// @dev `updateBeneficiary` from an unauthorized caller should
    ///      revert. We don't know which callers Doppler authorizes,
    ///      so this test just confirms "random caller can't call it" —
    ///      important for the security model.
    function test_fork_doppler_updateBeneficiary_unauthorized_reverts() public needsFork {
        IFeeDistributor hook = IFeeDistributor(DOPPLER_HOOK);
        address randomCaller = address(0xCAFEBEEF);
        vm.prank(randomCaller);
        // Expect a revert. We don't pin to a specific selector since
        // Doppler's exact error type isn't documented here.
        vm.expectRevert();
        hook.updateBeneficiary(POOL_ID, randomCaller);
    }
}

// ─── Minimal interfaces used in fork tests ──────────────────────────────

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}
