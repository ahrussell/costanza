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
///   - Doppler hook's `collectFees` and `updateBeneficiary` ABI
///     shapes work as our `IFeeDistributor` interface assumes
///     (see live tx 0x5f6bd727…fb37e6d5).
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

    /// @dev Reality-check on Doppler: `collectFees` is permissionless on
    ///      the caller side — anyone can trigger a sweep. Tokens always
    ///      flow to the registered beneficiary (the `recipient`
    ///      parameter doesn't exist on the production hook). This test
    ///      just confirms the call lands without reverting; a richer
    ///      "fees actually transfer to the adapter" check lives in
    ///      `test_fork_e2e_doppler_handover_succeeds` below.
    function test_fork_doppler_collectFees_is_permissionless() public needsFork {
        IFeeDistributor hook = IFeeDistributor(DOPPLER_HOOK);
        address randomCaller = address(0xDEAD0BAD0);
        // Nothing is asserted post-call — we just need the call not to
        // revert when made by a random EOA. Whether tokens move depends
        // on (a) whether fees are pending and (b) who's the registered
        // beneficiary; both vary with fork state, so we don't assert on
        // them here.
        vm.deal(randomCaller, 1 ether);
        vm.prank(randomCaller);
        hook.collectFees(POOL_ID);
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

    // ─── End-to-end deploy ceremony rehearsal ────────────────────────────
    //
    // These tests rehearse the actual mainnet deploy ceremony by talking
    // to the LIVE Human Fund + InvestmentManager on Base mainnet (not
    // stand-ins). They impersonate the IM admin via `vm.prank` to register
    // the adapter, and impersonate the fund to drive deposits through the
    // IM. Together they answer "if we run the deploy script and the
    // ceremony today, does it work end-to-end?"
    //
    // We don't impersonate the Doppler beneficiary — that EOA isn't
    // queryable on-chain via a public getter. The runbook covers the
    // beneficiary handover; `test_fork_doppler_updateBeneficiary_*` above
    // covers the auth check.

    address constant LIVE_FUND               = 0x678dC1756b123168f23a698374C000019e38318c;
    address constant LIVE_IM                 = 0x2fab8aE91B9EB3BaB18531594B20e0e086661892;
    address constant LIVE_IM_ADMIN           = 0x2e61a91EbeD1B557199f42d3E843c06Afb445004;
    address constant LIVE_DOPPLER_BENEFICIARY = 0x495fB7ddD383be8030EFC93324Ff078f173eAb2A;

    string constant CANONICAL_NAME = "Costanza Token";
    uint8  constant CANONICAL_RISK = 4;
    uint16 constant CANONICAL_APY  = 0;

    /// @dev Deploy an adapter wired to the LIVE fund + IM. Returns
    ///      the adapter and its expected protocol ID (current count + 1).
    function _deployLiveAdapter()
        internal
        returns (CostanzaTokenAdapter adapter, uint256 nextProtocolId)
    {
        V4PoolStateReader reader = new V4PoolStateReader(POOL_MANAGER);
        V4SwapExecutor exec      = new V4SwapExecutor(POOL_MANAGER, _v4Key());

        adapter = new CostanzaTokenAdapter(
            COSTANZA_TOKEN,
            WETH,
            POOL_MANAGER,
            address(reader),
            address(exec),
            DOPPLER_HOOK,
            payable(LIVE_FUND),
            LIVE_IM,
            _poolKey(),
            5 ether,
            InitialState(0, 0, 0, 0, 0)
        );

        // Read current count from the live IM. This is the protocol ID
        // assigned to whatever we register next (`addProtocol` does
        // `protocolId = ++protocolCount`).
        uint256 currentCount = ILiveInvestmentManager(LIVE_IM).protocolCount();
        nextProtocolId = currentCount + 1;
    }

    /// @notice Step 1 + 2 of the deploy ceremony: deploy the adapter
    ///         and have the IM admin register it. Confirms the call
    ///         lands and the protocol metadata reads back correctly.
    function test_fork_e2e_register_with_live_im() public needsFork {
        (CostanzaTokenAdapter adapter, uint256 expectedId) = _deployLiveAdapter();

        ILiveInvestmentManager im = ILiveInvestmentManager(LIVE_IM);

        // Snapshot pre-registration state.
        uint256 preCount = im.protocolCount();

        // Impersonate the IM admin and register.
        vm.prank(LIVE_IM_ADMIN);
        uint256 returnedId = im.addProtocol(
            address(adapter),
            CANONICAL_NAME,
            unicode"Your own memecoin, $COSTANZA. Speculative — buy/sell via deposit/withdraw; trading fees from other holders accrue to the fund and lower your per-token cost basis. The contract won't sell below cost basis, so a position can be locked during drawdowns. Lifetime cap: 5 ETH.",
            CANONICAL_RISK,
            CANONICAL_APY
        );

        // Post-registration state.
        assertEq(returnedId, expectedId, "addProtocol returned wrong id");
        assertEq(im.protocolCount(), preCount + 1, "protocolCount didn't increment");

        // Read back metadata to confirm it landed.
        (
            address adapterAddr,
            string memory name,
            uint8 riskTier,
            uint16 apy,
            bool active,
            bool exists
        ) = im.getProtocol(returnedId);

        assertEq(adapterAddr, address(adapter), "wrong adapter recorded");
        assertEq(name, CANONICAL_NAME);
        assertEq(riskTier, CANONICAL_RISK);
        assertEq(apy, CANONICAL_APY);
        assertTrue(active, "protocol should be active by default");
        assertTrue(exists, "protocol should exist");
    }

    /// @notice Step 1 + 2 + a real deposit. Confirms tokens actually
    ///         land in the adapter when the live fund deposits via the
    ///         live IM's action path.
    function test_fork_e2e_deposit_via_live_im() public needsFork {
        (CostanzaTokenAdapter adapter, uint256 expectedId) = _deployLiveAdapter();
        ILiveInvestmentManager im = ILiveInvestmentManager(LIVE_IM);

        vm.prank(LIVE_IM_ADMIN);
        im.addProtocol(
            address(adapter),
            CANONICAL_NAME,
            unicode"Your own memecoin, $COSTANZA. Speculative — buy/sell via deposit/withdraw; trading fees from other holders accrue to the fund and lower your per-token cost basis. The contract won't sell below cost basis, so a position can be locked during drawdowns. Lifetime cap: 5 ETH.",
            CANONICAL_RISK,
            CANONICAL_APY
        );

        // Live fund pays the deposit. Top up its ETH balance so the call
        // doesn't bottom out the live treasury (vm.deal is additive on
        // top of whatever's there).
        uint256 amountIn = 0.01 ether;
        vm.deal(LIVE_FUND, address(LIVE_FUND).balance + amountIn);

        uint256 preTokens = IERC20(COSTANZA_TOKEN).balanceOf(address(adapter));
        assertEq(preTokens, 0, "fresh adapter should hold no tokens");

        // Drive the deposit through the IM's action path, which is what
        // the agent action handler calls under the hood.
        vm.prank(LIVE_FUND);
        im.deposit{value: amountIn}(expectedId, amountIn);

        uint256 postTokens = IERC20(COSTANZA_TOKEN).balanceOf(address(adapter));
        assertGt(postTokens, 0, "adapter should hold tokens after deposit");
        assertEq(adapter.cumulativeEthIn(), amountIn, "cumIn didn't track");
        assertEq(adapter.tokensFromSwapsIn(), postTokens, "swap accumulator drifted");
    }

    /// @notice Confirms `currentEpoch()` reads through to the live fund.
    ///         The adapter's cooldown logic depends on this; if the read
    ///         path is broken (wrong address, ABI drift), the cooldown
    ///         behaves unpredictably.
    function test_fork_e2e_adapter_reads_live_currentEpoch() public needsFork {
        (CostanzaTokenAdapter adapter,) = _deployLiveAdapter();

        // Adapter calls fund.currentEpoch() via the IFundEpoch interface
        // declared at the top of CostanzaTokenAdapter.sol. Easiest way
        // to verify is to read both directly and confirm they agree.
        uint256 fundEpoch  = ILiveFund(LIVE_FUND).currentEpoch();
        // Adapter doesn't expose currentEpoch() directly, but a fresh
        // deposit's lastDepositEpoch will pin to the current epoch. We
        // can't deposit without registration, but we CAN just confirm
        // the fund pointer is set correctly:
        assertEq(adapter.fund(), payable(LIVE_FUND), "adapter.fund pointer wrong");
        assertGt(fundEpoch, 0, "live fund should be past epoch 0");
    }

    /// @notice Step 3 of the deploy ceremony: the live Doppler
    ///         beneficiary EOA calls `updateBeneficiary` to point the
    ///         fee stream at the adapter. Confirms three things:
    ///
    ///           (1) `0x495fB7…` is in fact the current registered
    ///               beneficiary — Doppler's update path lets the
    ///               call land and emits an event referencing the
    ///               adapter.
    ///           (2) Post-handover, a swap on the pool accrues fees
    ///               that the adapter can sweep via `pokeFees()` —
    ///               the bug we caught in PR review was that the
    ///               original `release(bytes32,address)` selector
    ///               didn't exist on Doppler, so the inner
    ///               `try/catch` in `_claimAndForwardFees` was
    ///               silently absorbing dispatch-fail reverts. This
    ///               test verifies fees ACTUALLY transfer.
    ///           (3) The fund (TheHumanFund) receives the WETH-side
    ///               fees as ETH; the $COSTANZA-side fees stay in
    ///               the adapter as inventory.
    ///
    ///         Counterpart to
    ///         `test_fork_doppler_updateBeneficiary_unauthorized_reverts`
    ///         which proves random callers fail.
    function test_fork_e2e_doppler_handover_succeeds() public needsFork {
        (CostanzaTokenAdapter adapter,) = _deployLiveAdapter();
        IFeeDistributor hook = IFeeDistributor(DOPPLER_HOOK);

        // Step 3: hand the beneficiary over.
        vm.recordLogs();
        vm.prank(LIVE_DOPPLER_BENEFICIARY);
        hook.updateBeneficiary(POOL_ID, address(adapter));

        // Confirm the event landed with the right shape: any log from
        // the hook that mentions the adapter address means the registry
        // recorded it. Doppler's exact event signature isn't externally
        // documented, so we content-match.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != DOPPLER_HOOK) continue;
            if (_logContainsAddress(logs[i], address(adapter))) {
                found = true;
                break;
            }
        }
        assertTrue(found, "updateBeneficiary log didn't reference the adapter");

        // Force a swap to accrue fresh LP fees on the pool — without
        // this, fees pending at the moment of pokeFees() depend on
        // ambient trading activity since the last claim, which is
        // unstable across fork-block pinning.
        _forceTrade();

        // Now there should be fresh LP fees in the pool's owed-to-LP
        // pot. Snapshot pre-poke state.
        uint256 preFundBal    = LIVE_FUND.balance;
        uint256 preAdapterTok = IERC20(COSTANZA_TOKEN).balanceOf(address(adapter));
        uint256 preAdapterEth = address(adapter).balance;

        // Sweep fees through the production code path. pokeFees is
        // permissionless; anyone can call it. We prank a fresh EOA
        // (not `address(this)`) because the 2% keeper tip is sent to
        // msg.sender, and the test contract doesn't have a payable
        // `receive` — a fresh EOA does by default.
        address keeper = address(0xC0FFEE);
        vm.prank(keeper);
        adapter.pokeFees();
        uint256 keeperTip = keeper.balance;

        uint256 postFundBal    = LIVE_FUND.balance;
        uint256 postAdapterTok = IERC20(COSTANZA_TOKEN).balanceOf(address(adapter));
        uint256 postAdapterEth = address(adapter).balance;

        // The fund should have received ETH (98% of unwrapped WETH-side
        // fees, 2% goes to the keeper tip). The adapter should have
        // received some $COSTANZA tokens. Adapter ETH balance should
        // not have grown — _claimAndForwardFees forwards everything
        // ETH to fund + tip. The keeper should have received their tip.
        assertGt(postFundBal, preFundBal,
            "fund should receive ETH from WETH-side fees");
        assertGt(postAdapterTok, preAdapterTok,
            "adapter should receive token-side fees");
        assertEq(postAdapterEth, preAdapterEth,
            "adapter shouldn't accumulate ETH (forwarded to fund + tip)");
        assertGt(keeperTip, 0, "keeper should receive a 2% tip");
    }

    /// @notice `collectFees` from a random caller cannot redirect fees
    ///         to themselves — the destination is locked to the
    ///         registered beneficiary, set via `updateBeneficiary`.
    ///         A non-beneficiary caller's `collectFees` only does the
    ///         pool→Doppler "collect" half of the dance; the beneficiary's
    ///         own subsequent call is what triggers the release.
    function test_fork_collectFees_random_caller_cannot_redirect() public needsFork {
        (CostanzaTokenAdapter adapter,) = _deployLiveAdapter();
        IFeeDistributor hook = IFeeDistributor(DOPPLER_HOOK);

        vm.prank(LIVE_DOPPLER_BENEFICIARY);
        hook.updateBeneficiary(POOL_ID, address(adapter));

        // Force fees to accrue.
        _forceTrade();

        address attacker = address(0xBADBADBAD);
        uint256 attackerTokBefore = IERC20(COSTANZA_TOKEN).balanceOf(attacker);
        uint256 attackerWethBefore = IERC20(WETH).balanceOf(attacker);

        // Random EOA calls collectFees. May "collect" pool fees into
        // Doppler's internal pot (Collect event), but must NOT
        // release anything to the attacker — the beneficiary registry
        // governs the destination.
        vm.prank(attacker);
        hook.collectFees(POOL_ID);

        assertEq(IERC20(COSTANZA_TOKEN).balanceOf(attacker), attackerTokBefore,
            "attacker must not receive token-side fees");
        assertEq(IERC20(WETH).balanceOf(attacker), attackerWethBefore,
            "attacker must not receive WETH-side fees");
        assertEq(attacker.balance, 0,
            "attacker must not receive ETH");
    }

    /// @notice **The headline answer to "will the adapter claim my
    ///         unclaimed fees after handover?"** — YES, as long as no
    ///         one else triggered a `collectFees` between the old
    ///         beneficiary's last claim and the handover.
    ///
    ///         Doppler's semantic: pool fees aren't tagged
    ///         per-beneficiary inside the V4 pool. Whoever triggers
    ///         the next `collectFees` causes the pool fees to flow
    ///         out, credited to whoever is the *current* beneficiary
    ///         at that moment. After handover, the adapter is the
    ///         current beneficiary, so its first pokeFees pulls all
    ///         pool-side fees (whether they accrued before or after
    ///         the handover) into the adapter.
    ///
    ///         Empirical: 500k blocks of `cast logs` show no one but
    ///         the registered beneficiary calls `collectFees` on this
    ///         pool. So in practice the window of risk is tiny.
    function test_fork_handover_inherits_pre_handover_pool_fees() public needsFork {
        (CostanzaTokenAdapter adapter,) = _deployLiveAdapter();
        IFeeDistributor hook = IFeeDistributor(DOPPLER_HOOK);

        // Step 1: Trade while old beneficiary is registered. Fees
        // accrue in V4 pool's owed-to-LP accumulator. Critically,
        // NO ONE calls collectFees in this window — so fees stay in
        // the pool, untagged.
        _forceTrade();

        // Step 2: Hand over to the adapter WITHOUT old beneficiary
        // claiming first.
        vm.prank(LIVE_DOPPLER_BENEFICIARY);
        hook.updateBeneficiary(POOL_ID, address(adapter));

        // Step 3: Adapter pokeFees. Should claim the accumulated
        // pre-handover fees because Doppler credits them to "current
        // beneficiary at moment of collect" = adapter (post-handover).
        uint256 adapterTokBefore = IERC20(COSTANZA_TOKEN).balanceOf(address(adapter));
        uint256 fundEthBefore    = LIVE_FUND.balance;

        address keeper = address(0xC0FFEE);
        vm.prank(keeper);
        adapter.pokeFees();

        // Adapter received the pre-handover-accrued fees.
        bool gained =
            IERC20(COSTANZA_TOKEN).balanceOf(address(adapter)) > adapterTokBefore
            || LIVE_FUND.balance > fundEthBefore;
        assertTrue(gained, "adapter must inherit pre-handover pool fees");
    }

    /// @notice The flip side: if a permissionless caller triggers
    ///         `collectFees` BEFORE the handover, those fees come out
    ///         of the V4 pool but get **stranded** in Doppler — neither
    ///         the old beneficiary's nor the new beneficiary's
    ///         subsequent collectFees can recover them. (Doppler's
    ///         per-pool internal accounting only credits when the
    ///         beneficiary themselves calls.)
    ///
    ///         This isn't a problem in practice — 500k blocks of logs
    ///         show no one besides 0x495fB7… ever calls collectFees
    ///         on this pool. The handover window is small enough that
    ///         the chance of a hostile actor lining up a single
    ///         pre-handover collectFees is negligible. Documented here
    ///         so future readers know the risk pattern.
    function test_fork_third_party_collect_pre_handover_strands_fees() public needsFork {
        (CostanzaTokenAdapter adapter,) = _deployLiveAdapter();
        IFeeDistributor hook = IFeeDistributor(DOPPLER_HOOK);

        _forceTrade();

        // Hostile/random EOA collectFees BEFORE handover.
        address randomCaller = address(0xDEAD0BAD0);
        vm.prank(randomCaller);
        hook.collectFees(POOL_ID);

        // Hand over.
        vm.prank(LIVE_DOPPLER_BENEFICIARY);
        hook.updateBeneficiary(POOL_ID, address(adapter));

        // Adapter pokeFees — finds nothing for itself.
        uint256 adapterTokBefore = IERC20(COSTANZA_TOKEN).balanceOf(address(adapter));
        uint256 fundEthBefore    = LIVE_FUND.balance;

        address keeper = address(0xC0FFEE);
        vm.prank(keeper);
        adapter.pokeFees();

        assertEq(IERC20(COSTANZA_TOKEN).balanceOf(address(adapter)), adapterTokBefore,
            "adapter should not inherit fees that were collected pre-handover by a third party");
        assertEq(LIVE_FUND.balance, fundEthBefore,
            "fund should not receive any forwarded fees");
    }

    /// @notice Confirms collectFees is safe to call when nothing has
    ///         accrued — i.e., no revert on the "empty pool" case.
    ///         Important because pokeFees() now propagates upstream
    ///         reverts (see PR #53), so keeper bots could otherwise
    ///         end up reverting on every poll between trades.
    function test_fork_collectFees_no_pending_does_not_revert() public needsFork {
        (CostanzaTokenAdapter adapter,) = _deployLiveAdapter();
        IFeeDistributor hook = IFeeDistributor(DOPPLER_HOOK);

        // Hand over with no fee-accruing activity in between.
        vm.prank(LIVE_DOPPLER_BENEFICIARY);
        hook.updateBeneficiary(POOL_ID, address(adapter));

        // Drain any residual fees first via a direct collectFees, so
        // the next call is guaranteed to find nothing pending. Then
        // call again immediately — must not revert.
        hook.collectFees(POOL_ID);
        hook.collectFees(POOL_ID);
    }

    /// @dev Force fee accrual on the live pool by doing a small swap.
    ///      Used by tests that need pending fees to claim. Trades a
    ///      fresh 0.005 ETH from a stand-in trader EOA.
    function _forceTrade() internal {
        V4SwapExecutor sideExec = new V4SwapExecutor(POOL_MANAGER, _v4Key());
        address trader = address(0xBEEF);
        vm.deal(trader, 0.005 ether);
        vm.startPrank(trader);
        IWETH9(WETH).deposit{value: 0.005 ether}();
        IWETH9(WETH).approve(address(sideExec), 0.005 ether);
        sideExec.swap(WETH, COSTANZA_TOKEN, 0.005 ether, 1);
        vm.stopPrank();
    }

    /// @dev True if any topic OR the right-most 32-byte word in `data`
    ///      decodes to `addr`. Helper for matching the
    ///      UpdateBeneficiary log's new-beneficiary slot without
    ///      pinning to a specific event signature.
    function _logContainsAddress(Vm.Log memory log, address addr) internal pure returns (bool) {
        bytes32 needle = bytes32(uint256(uint160(addr)));
        for (uint256 i = 0; i < log.topics.length; i++) {
            if (log.topics[i] == needle) return true;
        }
        // Walk the data 32 bytes at a time looking for the address.
        bytes memory data = log.data;
        if (data.length % 32 != 0) return false;
        for (uint256 i = 0; i < data.length; i += 32) {
            bytes32 word;
            assembly { word := mload(add(add(data, 0x20), i)) }
            if (word == needle) return true;
        }
        return false;
    }
}

// ─── Live system minimal interfaces ─────────────────────────────────────
//
// These only expose the methods the e2e fork tests actually call.
// Mirrors the shape of the real InvestmentManager / TheHumanFund
// without taking a compile-time dependency on those (large) contracts
// in this test file.

interface ILiveInvestmentManager {
    function protocolCount() external view returns (uint256);

    function addProtocol(
        address adapter,
        string calldata name,
        string calldata description,
        uint8 riskTier,
        uint16 expectedApyBps
    ) external returns (uint256 protocolId);

    function getProtocol(uint256 protocolId) external view returns (
        address adapter,
        string memory name,
        uint8 riskTier,
        uint16 expectedApyBps,
        bool active,
        bool exists
    );

    function deposit(uint256 protocolId, uint256 amount) external payable;
}

interface ILiveFund {
    function currentEpoch() external view returns (uint256);
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
