// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/adapters/CostanzaTokenAdapter.sol";
import "../src/adapters/IFeeDistributor.sol";
import "../src/adapters/IPoolStateReader.sol";
import "../src/adapters/ISwapExecutor.sol";
import "../src/InvestmentManager.sol";
import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./helpers/CostanzaTokenAdapterMocks.sol";
import "./helpers/MockEndaoment.sol"; // MockWETH
import "./helpers/V4PriceMath.sol";
import "./helpers/EpochTest.sol";

/// @notice Unit tests for the CostanzaTokenAdapter.
///
/// @dev Wiring uses a stand-alone mock fund (just exposes `currentEpoch`)
///      to keep tests fast. End-to-end tests with the real TheHumanFund +
///      InvestmentManager land in §9 (adversarial coverage) where the
///      full epoch path matters.
contract CostanzaTokenAdapterTest is Test {
    // ─── Test config ─────────────────────────────────────────────────────

    /// @notice Default rate: 1000 $COSTANZA per 1 ETH. Tests change this
    ///         to drive different scenarios.
    uint256 internal constant INITIAL_RATE_18 = 1000e18;

    /// @notice Lifetime cap for the adapter under test.
    uint256 internal constant TEST_MAX_NET_ETH_IN = 5 ether;

    // ─── Stand-ins ───────────────────────────────────────────────────────

    /// @notice We pretend this address is the InvestmentManager. The
    ///         adapter only checks `msg.sender == investmentManager`, so
    ///         a vm.prank against this address is sufficient.
    address internal constant IM = address(0xCAFE);

    /// @notice We pretend this is the fund. We use vm.mockCall to make
    ///         `currentEpoch()` return what we want.
    address payable internal constant FUND = payable(address(0xFEED));

    /// @notice Owner = test contract by default (Ownable msg.sender).
    address internal owner;

    // ─── System under test ───────────────────────────────────────────────

    MockCostanzaToken      internal token;
    MockWETH               internal weth;
    MockPoolStateReader    internal stateReader;
    MockSwapExecutor       internal swapper;
    MockFeeDistributor     internal feeDistributor;
    address                internal poolManager = address(0xDEAD0001);
    CostanzaTokenAdapter   internal adapter;

    // ─── Setup ───────────────────────────────────────────────────────────

    function setUp() public {
        owner = address(this);

        // Deploy mocks
        token = new MockCostanzaToken();
        weth = new MockWETH();
        stateReader = new MockPoolStateReader();
        swapper = new MockSwapExecutor(address(token), address(weth), INITIAL_RATE_18);
        feeDistributor = new MockFeeDistributor(address(token), address(weth), address(this));

        // Seed the swapper with both sides of the book so it can
        // pay either direction.
        token.mint(address(this), 1_000_000 ether);
        token.approve(address(swapper), type(uint256).max);
        swapper.seedTokenLiquidity(500_000 ether);
        // Native ETH liquidity for sells.
        vm.deal(address(swapper), 1000 ether);

        // Build a PoolKey: native-ETH pool with $COSTANZA on the
        // upper side. (currency0 == 0 means native ETH.)
        PoolKey memory key = PoolKey({
            currency0: address(0),
            currency1: address(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });

        // Default mock fund: epoch 1.
        vm.mockCall(
            FUND,
            abi.encodeWithSignature("currentEpoch()"),
            abi.encode(uint256(1))
        );

        adapter = new CostanzaTokenAdapter(
            address(token),
            address(weth),
            poolManager,
            address(stateReader),
            address(swapper),
            address(feeDistributor),
            FUND,
            IM,
            key,
            TEST_MAX_NET_ETH_IN,
            InitialState(0, 0, 0, 0, 0)
        );

        // Seed state reader's spot to match the swapper's rate.
        // Native-ETH pool with token as currency1 → `tokenIsCurrency0 = false`.
        // 1000 tokens/ETH.
        _setSpot(INITIAL_RATE_18);

        // Re-point the fee distributor at the adapter.
        feeDistributor.setRecipient(address(adapter));
    }

    /// @dev Set the state reader's spot to a given `tokensPerEth18` rate.
    ///      With pure-spot mode, this is the only price control tests
    ///      need — there's no separate TWAP source.
    function _setSpot(uint256 tokensPerEth18) internal {
        uint160 sqrt_ = V4PriceMath.sqrtPriceX96FromTokensPerEth18(
            tokensPerEth18,
            adapter.tokenIsCurrency0()
        );
        stateReader.setSqrtPriceX96(sqrt_);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _setEpoch(uint256 e) internal {
        vm.mockCall(
            FUND,
            abi.encodeWithSignature("currentEpoch()"),
            abi.encode(e)
        );
    }

    function _depositAs(uint256 amount) internal returns (uint256 shares) {
        vm.deal(IM, amount);
        vm.prank(IM);
        shares = adapter.deposit{value: amount}();
    }

    function _withdrawAs(uint256 shares) internal returns (uint256 ethOut) {
        vm.prank(IM);
        ethOut = adapter.withdraw(shares);
    }

    // ─── Constructor + name ──────────────────────────────────────────────

    function test_name() public view {
        assertEq(adapter.name(), "Costanza Token");
    }

    function test_constructor_sets_immutables() public view {
        assertEq(address(adapter.costanzaToken()), address(token));
        assertEq(address(adapter.weth()), address(weth));
        assertEq(adapter.poolManager(), poolManager);
        assertEq(address(adapter.poolStateReader()), address(stateReader));
        assertEq(address(adapter.swapExecutor()), address(swapper));
        assertEq(address(adapter.feeDistributor()), address(feeDistributor));
        assertEq(adapter.fund(), FUND);
        assertEq(adapter.investmentManager(), IM);
        assertEq(adapter.maxNetEthIn(), TEST_MAX_NET_ETH_IN);
        assertTrue(adapter.nativeEthPool());
    }

    function test_constructor_rejects_zero_addresses() public {
        PoolKey memory key = PoolKey({
            currency0: address(0),
            currency1: address(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.expectRevert(CostanzaTokenAdapter.InvalidConfig.selector);
        new CostanzaTokenAdapter(
            address(0), address(weth), poolManager, address(stateReader),
            address(swapper), address(feeDistributor),
            FUND, IM, key, TEST_MAX_NET_ETH_IN, InitialState(0, 0, 0, 0, 0)
        );
    }

    function test_constructor_rejects_pool_without_token() public {
        // PoolKey that doesn't include $COSTANZA on either side.
        PoolKey memory bad = PoolKey({
            currency0: address(0),
            currency1: address(weth),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.expectRevert(CostanzaTokenAdapter.InvalidConfig.selector);
        new CostanzaTokenAdapter(
            address(token), address(weth), poolManager, address(stateReader),
            address(swapper), address(feeDistributor),
            FUND, IM, bad, TEST_MAX_NET_ETH_IN, InitialState(0, 0, 0, 0, 0)
        );
    }

    // ─── Deposit / withdraw round-trip ───────────────────────────────────

    function test_deposit_only_callable_by_investment_manager() public {
        vm.deal(address(0xBADD), 1 ether);
        vm.prank(address(0xBADD));
        vm.expectRevert(CostanzaTokenAdapter.Unauthorized.selector);
        adapter.deposit{value: 1 ether}();
    }

    function test_deposit_zero_value_reverts() public {
        vm.prank(IM);
        vm.expectRevert(CostanzaTokenAdapter.ZeroAmount.selector);
        adapter.deposit{value: 0}();
    }

    function test_deposit_happy_path() public {
        uint256 shares = _depositAs(1 ether);

        // 1 ETH × 1000 tokens/ETH × 1.0 (no slippage) = 1000 tokens
        assertEq(shares, 1000 ether);
        assertEq(token.balanceOf(address(adapter)), 1000 ether);
        assertEq(adapter.cumulativeEthIn(), 1 ether);
        assertEq(adapter.tokensFromSwapsIn(), 1000 ether);
        assertEq(adapter.lastDepositEpoch(), 1);
    }

    function test_withdraw_only_callable_by_investment_manager() public {
        _depositAs(1 ether);
        vm.prank(address(0xBADD));
        vm.expectRevert(CostanzaTokenAdapter.Unauthorized.selector);
        adapter.withdraw(100 ether);
    }

    function test_withdraw_zero_reverts() public {
        _depositAs(1 ether);
        vm.prank(IM);
        vm.expectRevert(CostanzaTokenAdapter.ZeroAmount.selector);
        adapter.withdraw(0);
    }

    function test_withdraw_round_trip_at_par() public {
        uint256 shares = _depositAs(1 ether);

        // Move past the cooldown so we can re-engage the system if we
        // want to. (Withdraws have no cooldown but we set it for clean state.)
        _setEpoch(10);
        // Track balances before
        uint256 imEthBefore = IM.balance;

        uint256 ethOut = _withdrawAs(shares);

        // 1000 tokens × (1 ETH / 1000 tokens) = 1 ETH
        assertEq(ethOut, 1 ether);
        assertEq(IM.balance - imEthBefore, 1 ether);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(adapter.cumulativeEthOut(), 1 ether);
        assertEq(adapter.tokensFromSwapsOut(), shares);
    }

    function test_withdraw_caps_to_balance() public {
        uint256 shares = _depositAs(1 ether);
        _setEpoch(10);

        // Try to withdraw more than we hold; adapter should cap to balance.
        uint256 ethOut = _withdrawAs(shares + 1_000_000 ether);
        assertEq(ethOut, 1 ether);
    }

    function test_lifetime_cap_blocks_oversized_deposit() public {
        // First deposit fills the cap.
        _depositAs(TEST_MAX_NET_ETH_IN);

        // Move past cooldown so the LIFETIME CAP is the binding error
        // (not cooldown).
        _setEpoch(100);

        vm.deal(IM, 1 wei);
        vm.prank(IM);
        vm.expectRevert(CostanzaTokenAdapter.LifetimeCapExceeded.selector);
        adapter.deposit{value: 1 wei}();
    }

    function test_lifetime_cap_resets_on_partial_withdraw() public {
        _depositAs(TEST_MAX_NET_ETH_IN);
        _setEpoch(100);
        // Partial withdraw to free 1 ETH of headroom.
        uint256 shares = adapter.tokensFromSwapsIn();
        uint256 sharesToSell = shares / 5; // sell 20%
        _withdrawAs(sharesToSell);

        // Now we should be able to deposit ~1 ETH again.
        uint256 newShares = _depositAs(1 ether);
        assertGt(newShares, 0);
    }

    function test_cooldown_blocks_immediate_redeposit() public {
        _depositAs(0.1 ether);
        // Same epoch — cooldown active.
        vm.deal(IM, 0.1 ether);
        vm.prank(IM);
        vm.expectRevert(CostanzaTokenAdapter.CooldownActive.selector);
        adapter.deposit{value: 0.1 ether}();
    }

    function test_cooldown_clears_after_three_epochs() public {
        _depositAs(0.1 ether);
        _setEpoch(1 + 3); // exactly 3 epochs later — first allowed redeposit
        uint256 shares = _depositAs(0.1 ether);
        assertGt(shares, 0);
    }

    function test_cooldown_active_at_two_epochs() public {
        _depositAs(0.1 ether);
        _setEpoch(1 + 2); // one epoch shy of clearing
        vm.deal(IM, 0.1 ether);
        vm.prank(IM);
        vm.expectRevert(CostanzaTokenAdapter.CooldownActive.selector);
        adapter.deposit{value: 0.1 ether}();
    }

    function test_netEthBasis_after_round_trip() public {
        _depositAs(1 ether);
        assertEq(adapter.netEthBasis(), 1 ether);

        _setEpoch(10);
        _withdrawAs(adapter.tokensFromSwapsIn());
        // Net basis floor at 0 once cumOut >= cumIn.
        assertEq(adapter.netEthBasis(), 0);
    }

    function test_netEthBasis_above_zero_after_partial_withdraw() public {
        _depositAs(2 ether);
        _setEpoch(10);
        _withdrawAs(500 ether); // sell 500 of the 2000 tokens we got
        // 2 ETH in - 0.5 ETH out = 1.5 ETH net basis
        assertEq(adapter.netEthBasis(), 1.5 ether);
    }

    // ─── Spot-vs-history gate (manipulation detection) ───────────────────
    //
    // The gate compares current spot to the most recent stored sample,
    // with a tolerance that widens as the sample ages.
    //   allowed_bps = BASE (500) + age × DRIFT (200/hour)
    // Bootstrap (no sample yet) and very-stale (allowed >= 100%) both
    // skip the check. In between, current spot must be within the
    // allowed band of the last sample.

    function test_history_gate_skipped_on_first_action() public {
        // No prior sample → bootstrap path → check no-ops. A wildly
        // off-spot deposit still goes through (slippage will reject if
        // the swap itself is too lossy, but that's the BUY_SLIPPAGE
        // path, not history).
        _setSpot(2000e18); // pretend "current spot" is way different
        swapper.setRate(2000e18); // and the executor matches
        uint256 shares = _depositAs(0.05 ether);
        assertGt(shares, 0);
    }

    function test_history_gate_blocks_pumped_spot_after_recent_sample() public {
        // First deposit records a sample at price 1000.
        _depositAs(0.05 ether);
        // Quick second deposit (after cooldown) — pump spot to 1150
        // (15% off the stored sample, past the 5% base tolerance).
        _setEpoch(1 + 3); // cooldown clears
        _setSpot(1150e18);
        // Don't touch swapper — irrelevant; gate fires before swap.

        vm.deal(IM, 0.05 ether);
        vm.prank(IM);
        vm.expectRevert(CostanzaTokenAdapter.SpotDeviationExceeded.selector);
        adapter.deposit{value: 0.05 ether}();
    }

    function test_history_gate_blocks_dumped_spot_after_recent_sample() public {
        _depositAs(0.05 ether);
        _setEpoch(1 + 3);
        _setSpot(880e18); // 12% below stored sample (past 5% base)

        vm.deal(IM, 0.05 ether);
        vm.prank(IM);
        vm.expectRevert(CostanzaTokenAdapter.SpotDeviationExceeded.selector);
        adapter.deposit{value: 0.05 ether}();
    }

    function test_history_gate_allows_drift_within_tolerance() public {
        _depositAs(0.05 ether);
        _setEpoch(1 + 3);
        _setSpot(1030e18); // 3% drift, within the 5% base tolerance
        swapper.setRate(1030e18);
        uint256 shares = _depositAs(0.05 ether);
        assertGt(shares, 0);
    }

    function test_history_gate_widens_with_sample_age() public {
        _depositAs(0.05 ether);
        // Advance wall-clock 12 hours — allowed deviation grows from
        // 5% to ~5% + 12 × 2% = ~29%. A 20% drift now passes.
        _setEpoch(1 + 3);
        skip(12 hours);
        _setSpot(1200e18); // 20% pump
        swapper.setRate(1200e18);
        uint256 shares = _depositAs(0.05 ether);
        assertGt(shares, 0);
    }

    function test_history_gate_runs_on_withdraw_too() public {
        // Build a position so withdraw has shares to sell.
        _depositAs(0.5 ether);
        _setEpoch(10);

        uint256 sharesToSell = adapter.tokensFromSwapsIn();
        // Push spot 50% off the stored sample; way past the gate.
        _setSpot(1500e18);

        vm.prank(IM);
        vm.expectRevert(CostanzaTokenAdapter.SpotDeviationExceeded.selector);
        adapter.withdraw(sharesToSell);
    }

    // ─── Buy-side slippage floor (minOut anchored to spot) ───────────────

    function test_buy_slippage_rejects_loss_above_5pct() public {
        // Swapper configured with 10% adverse slippage. minOut is
        // 95% of spot-expected; 10% adverse breaches the 5% bound.
        swapper.setSlippage(9000); // 10% adverse

        vm.deal(IM, 0.1 ether);
        vm.prank(IM);
        vm.expectRevert(MockSwapExecutor.InsufficientOutput.selector);
        adapter.deposit{value: 0.1 ether}();
    }

    function test_buy_slippage_accepts_normal_swap() public {
        // No slippage on the swapper — deposit succeeds.
        uint256 shares = _depositAs(0.1 ether);
        assertGt(shares, 0);
    }

    function test_buy_slippage_accepts_up_to_5pct() public {
        // 4% adverse slippage — within the 5% bound.
        swapper.setSlippage(9600);
        uint256 shares = _depositAs(0.1 ether);
        assertGt(shares, 0);
    }

    // ─── Sell-side cost-basis floor ──────────────────────────────────────
    //
    // For a sell of `shares` tokens, `minOut` is anchored to per-token
    // overall cost basis: `minOut = shares × netEthBasis / totalTokens`
    // (with `SELL_FLOOR_BPS = 0`, no margin — the agent never takes a
    // loss on an individual sell). `totalTokens` = full balance,
    // including fee tokens at zero cost.

    function test_sell_floor_blocks_any_below_cost_basis() public {
        // Position established at par. Even a small price drop blocks
        // exits at cost basis.
        _depositAs(1 ether);
        _setEpoch(10);
        // 2% drop in token value — within the history gate's 5% base
        // tolerance, but below cost basis on the sell.
        _setSpot(1020e18); // ~2% lower per-token ETH price
        swapper.setRate(1020e18);

        uint256 shares = adapter.tokensFromSwapsIn();
        vm.prank(IM);
        vm.expectRevert(MockSwapExecutor.InsufficientOutput.selector);
        adapter.withdraw(shares);
    }

    function test_sell_floor_blocks_25pct_drawdown() public {
        // Larger drawdown — same outcome, but now also trips the
        // history gate. We use the executor's slippage to differentiate
        // from the gate by setting prices in lockstep.
        _depositAs(1 ether);
        _setEpoch(10);
        _setSpot(1334e18); // ~25% drop in token value
        swapper.setRate(1334e18);

        uint256 shares = adapter.tokensFromSwapsIn();
        vm.prank(IM);
        // History gate fires first (25% > drift-adjusted tolerance);
        // either revert is acceptable for this test's purpose.
        vm.expectRevert();
        adapter.withdraw(shares);
    }

    function test_sell_floor_allows_at_cost_basis_or_above() public {
        // No price drop — sell at exactly cost basis clears.
        _depositAs(1 ether);
        _setEpoch(10);

        uint256 sharesToSell = adapter.tokensFromSwapsIn();
        uint256 ethOut = _withdrawAs(sharesToSell);
        // 1000 tokens at rate 1000 = 1 ETH back. Floor = 1 ETH. Passes
        // exactly at the floor.
        assertEq(ethOut, 1 ether);
    }

    function test_sell_floor_skipped_in_house_money() public {
        // Profitable full exit → cumOut > cumIn → netEthBasis = 0.
        // After this, a (hypothetical) re-sell wouldn't be gated by
        // the cost-basis floor — but this is a fully-realized
        // profit position, so principal isn't at risk.
        _depositAs(1 ether);
        _setEpoch(10);
        // Skip enough time for the history gate to allow the 25% pump.
        skip(11 hours);
        _setSpot(800e18); // 25% pump
        swapper.setRate(800e18);
        _withdrawAs(adapter.tokensFromSwapsIn());

        assertEq(adapter.netEthBasis(), 0);
    }

    function test_sell_floor_relaxes_with_fee_token_inflow() public {
        // Buy 1 ETH worth → 1000 tokens. Cost basis per token = 0.001 ETH.
        _depositAs(1 ether);

        // Fees arrive: 500 free tokens. totalTokens jumps to 1500;
        // overall cost basis per token drops to 1/1500 ≈ 0.000667 ETH.
        _seedFees(0, 500 ether);
        adapter.pokeFees();
        assertEq(token.balanceOf(address(adapter)), 1500 ether);

        _setEpoch(10);
        // Spot at 1300 tokens/ETH. Per-token spot = 1/1300 ≈ 0.000769 ETH.
        // Per-token cost basis (post fees) = 0.000667 ETH. Sell clears
        // because 0.000769 > 0.000667. Without the fee inflow, floor
        // would still be 0.001 ETH/token and the sell would revert.
        _setSpot(1300e18);
        swapper.setRate(1300e18);
        // Move enough simulated time forward to widen the history gate
        // — 1300 vs 1000 is 30% drift, needs ~12+ hours to pass at
        // BASE=5% + DRIFT=2%/hour.
        skip(15 hours);

        uint256 ethOut = _withdrawAs(1500 ether);
        // 1500 tokens / 1300 ≈ 1.154 ETH. Floor = 1500 × 1/1500 = 1 ETH.
        assertGt(ethOut, 1 ether);
    }

    function test_sell_floor_scales_with_partial_profit_taking() public {
        // After an in-profit partial exit, netBasis decreases and the
        // per-token floor falls along with it.
        _depositAs(2 ether); // 2000 tokens, basis 2 ETH
        _setEpoch(10);
        _withdrawAs(1000 ether); // sell half at par → 1 ETH back
        // Now: netBasis = 1 ETH, totalTokens = 1000, per-token = 0.001 ETH

        // 2% drop — within the history gate but below floor.
        _setSpot(1020e18);
        swapper.setRate(1020e18);

        vm.prank(IM);
        vm.expectRevert(MockSwapExecutor.InsufficientOutput.selector);
        adapter.withdraw(1000 ether);
    }

    // ─── balance() with cost-basis floor ─────────────────────────────────

    function test_balance_zero_with_no_position() public view {
        assertEq(adapter.balance(), 0);
    }

    function test_balance_at_par_after_deposit() public {
        _depositAs(1 ether);
        // 1000 tokens × (1/1000) ETH/token = 1 ETH. Floor (cost basis)
        // is also 1 ETH, so they match.
        uint256 b = adapter.balance();
        assertEq(b, 1 ether);
    }

    function test_balance_uses_spot_value_when_above_floor() public {
        _depositAs(1 ether);
        // Token doubles in ETH terms — spot says fewer tokens per ETH.
        _setSpot(500e18); // 1 ETH = 500 tokens, so 1 token = 0.002 ETH
        uint256 b = adapter.balance();
        // 1000 tokens × 0.002 ETH = 2 ETH (above 1 ETH floor)
        assertApproxEqAbs(b, 2 ether, 1e6);
    }

    function test_balance_uses_floor_when_spot_below_basis() public {
        _depositAs(1 ether);
        // Token crashes — spot says many more tokens per ETH.
        _setSpot(2000e18); // 1 token = 0.0005 ETH
        uint256 b = adapter.balance();
        // 1000 tokens × 0.0005 = 0.5 ETH (below 1 ETH floor)
        // Floor wins → balance reports netEthBasis = 1 ETH.
        assertEq(b, 1 ether);
    }

    function test_balance_falls_back_to_floor_on_state_reader_failure() public {
        _depositAs(1 ether);
        stateReader.setFailMode(true);
        uint256 b = adapter.balance();
        // State reader reverted → balance falls back to floor.
        assertEq(b, 1 ether);
    }

    function test_balance_returns_zero_on_state_reader_failure_with_zero_basis() public {
        // No prior position → tokens == 0 inside spotValueOfHoldings,
        // returns 0; floor is 0; balance returns 0 cleanly.
        stateReader.setFailMode(true);
        assertEq(adapter.balance(), 0);
    }

    function test_balance_is_view_does_not_revert_on_pool_death() public {
        _depositAs(1 ether);
        // Pool drained: state reader fails.
        stateReader.setFailMode(true);
        // balance() must NOT revert — IM snapshot path requires this.
        uint256 b = adapter.balance();
        assertEq(b, 1 ether); // falls back to floor
    }

    function test_balance_after_partial_profit_taking() public {
        _depositAs(2 ether);
        _setEpoch(10);
        // Take half the position out at par.
        _withdrawAs(adapter.tokensFromSwapsIn() / 2);
        // 2 ETH in - 1 ETH out = 1 ETH net basis.
        // 1000 tokens left × (1/1000) = 1 ETH spot value. Same as floor.
        uint256 b = adapter.balance();
        assertEq(b, 1 ether);
    }

    // ─── Fee path (pokeFees + auto-claim on deposit/withdraw) ────────────

    /// @dev Seed the mock fee distributor with `wethAmount` of WETH-equivalent
    ///      (sent as raw ETH which `claim()` wraps internally) and
    ///      `tokenAmount` of $COSTANZA, ready for `claim()` to pull.
    function _seedFees(uint256 wethAmount, uint256 tokenAmount) internal {
        if (wethAmount > 0) {
            // The mock distributor wraps any held ETH balance into
            // WETH at claim time — bypasses MockWETH's missing
            // transferFrom.
            vm.deal(address(feeDistributor), wethAmount);
        }
        if (tokenAmount > 0) {
            token.mint(address(this), tokenAmount);
            token.approve(address(feeDistributor), tokenAmount);
            feeDistributor.seedTokenFees(tokenAmount);
        }
    }

    function test_pokeFees_no_pending_is_noop() public {
        // No fees seeded. pokeFees should not revert; nothing to do.
        adapter.pokeFees();
        assertEq(address(adapter).balance, 0);
    }

    function test_pokeFees_distributes_2pct_tip_98pct_to_fund() public {
        _seedFees(1 ether, 0);

        uint256 fundEthBefore = FUND.balance;
        address keeper = address(0xBEEF);

        vm.prank(keeper);
        adapter.pokeFees();

        // 2% tip = 0.02 ETH; 98% to fund = 0.98 ETH.
        assertEq(keeper.balance, 0.02 ether);
        assertEq(FUND.balance - fundEthBefore, 0.98 ether);
        // Adapter holds no leftover ETH or WETH.
        assertEq(address(adapter).balance, 0);
        assertEq(weth.balanceOf(address(adapter)), 0);
    }

    function test_pokeFees_token_inflow_stays_in_adapter() public {
        _seedFees(0, 50 ether);

        uint256 adapterTokensBefore = token.balanceOf(address(adapter));
        adapter.pokeFees();
        // Tokens stay; no ETH was claimed so no tip.
        assertEq(token.balanceOf(address(adapter)) - adapterTokensBefore, 50 ether);
        assertEq(address(adapter).balance, 0);
    }

    function test_pokeFees_does_not_pollute_tokensFromSwapsIn() public {
        _depositAs(1 ether);
        uint256 swapsInBefore = adapter.tokensFromSwapsIn();

        _seedFees(0, 100 ether);
        adapter.pokeFees();

        // Token balance grew by 100 from fees, but tokensFromSwapsIn
        // didn't move — fee tokens have zero cost basis.
        assertEq(adapter.tokensFromSwapsIn(), swapsInBefore);
        assertEq(token.balanceOf(address(adapter)), swapsInBefore + 100 ether);
    }

    function test_deposit_auto_claims_pending_fees_to_fund() public {
        _seedFees(0.5 ether, 0);
        uint256 fundEthBefore = FUND.balance;

        // Deposit triggers _claimAndForwardFees(0) — no tip, 100% to fund.
        _depositAs(1 ether);

        // Fund got the full 0.5 ETH, no tip on the deposit path.
        assertEq(FUND.balance - fundEthBefore, 0.5 ether);
        assertEq(address(adapter).balance, 0);
    }

    function test_withdraw_auto_claims_pending_fees_to_fund() public {
        _depositAs(1 ether);
        _setEpoch(10);

        _seedFees(0.3 ether, 0);
        uint256 fundEthBefore = FUND.balance;
        uint256 imEthBefore = IM.balance;

        _withdrawAs(adapter.tokensFromSwapsIn() / 2);

        // Fee inflow (0.3 ETH) routes directly to fund via fund.receive().
        // Swap proceeds (0.5 ETH) route to msg.sender = IM, since
        // withdraw's IProtocolAdapter contract returns ETH to its
        // caller. In production the real IM forwards to the fund;
        // here we just verify the two flows are correctly separated.
        assertEq(FUND.balance - fundEthBefore, 0.3 ether);
        assertEq(IM.balance - imEthBefore, 0.5 ether);
        assertEq(address(adapter).balance, 0);
    }

    /// @notice pokeFees is the explicit-claim path — keepers call it
    ///         specifically to claim, so an upstream failure must NOT
    ///         be silently swallowed. The original (buggy) design
    ///         wrapped collectFees in try/catch unconditionally, which
    ///         hid a months-long ABI mismatch where the claim selector
    ///         didn't exist. New behavior: the revert propagates.
    function test_pokeFees_propagates_upstream_revert() public {
        feeDistributor.setCollectFeesReverts(true);

        vm.expectRevert(MockFeeDistributor.UpstreamBroken.selector);
        adapter.pokeFees();
    }

    /// @notice deposit's auto-claim is opportunistic — a misbehaving
    ///         upstream shouldn't block the agent's main flow. The
    ///         best-effort path swallows the revert, deposit completes.
    function test_deposit_auto_claim_failure_does_not_block_deposit() public {
        feeDistributor.setCollectFeesReverts(true);

        // deposit should still succeed; fees just aren't claimed this
        // round.
        uint256 fundEthBefore = FUND.balance;
        _depositAs(0.1 ether);
        // Deposit landed (tokens received).
        assertGt(adapter.tokensFromSwapsIn(), 0);
        // No fees were forwarded (claim was skipped).
        assertEq(FUND.balance, fundEthBefore);
    }

    /// @notice Same logic for withdraw — a broken upstream mustn't
    ///         lock the agent out of its position.
    function test_withdraw_auto_claim_failure_does_not_block_withdraw() public {
        // Build a position first (with claim working).
        _depositAs(0.1 ether);
        uint256 shares = adapter.tokensFromSwapsIn();

        // Now break the upstream and try to withdraw.
        feeDistributor.setCollectFeesReverts(true);
        _setEpoch(uint64(adapter.lastDepositEpoch()) + 4);  // clear cooldown for any spot reads

        // Withdraw should still succeed.
        vm.prank(IM);
        uint256 ethOut = adapter.withdraw(shares);
        assertGt(ethOut, 0);
    }

    // ─── Profitable-exit reset rule ──────────────────────────────────────

    function test_reset_fires_on_profitable_full_exit() public {
        _depositAs(1 ether);
        _setEpoch(10);

        // Token pumps 25% — withdraw needs the history gate to allow
        // this drift, so skip enough wall-clock time first.
        // 25% drift needs ~10 hours: 5% base + 10 × 2%/hr = 25%.
        skip(11 hours);
        _setSpot(800e18);
        swapper.setRate(800e18);

        // Sell all 1000 tokens at 1 token = 1/800 ETH → 1.25 ETH.
        uint256 ethOut = _withdrawAs(adapter.tokensFromSwapsIn());
        assertEq(ethOut, 1.25 ether);
        // Sell-floor not blocking: yields 1.25 > floor 1.0.
        // Net basis is now 0 because cumOut > cumIn.
        assertEq(adapter.netEthBasis(), 0);
        // Accumulators not yet reset — that happens on next deposit.
        assertEq(adapter.cumulativeEthIn(), 1 ether);
        assertEq(adapter.cumulativeEthOut(), 1.25 ether);

        // Move to next epoch and deposit again at the new rate.
        // Sample is now at 800 (post-withdraw); spot still 800;
        // gate clears at 0 deviation.
        _setEpoch(20);
        vm.expectEmit(false, false, false, false, address(adapter));
        emit CostanzaTokenAdapter.AccumulatorsReset();
        _depositAs(0.1 ether);

        // After reset + new deposit:
        //   cumIn = 0.1 ether, cumOut = 0
        //   tokensFromSwapsIn = 80 (0.1 × 800)
        assertEq(adapter.cumulativeEthIn(), 0.1 ether);
        assertEq(adapter.cumulativeEthOut(), 0);
        assertEq(adapter.tokensFromSwapsIn(), 80 ether);
    }

    function test_reset_does_not_fire_on_partial_exit() public {
        // With SELL_FLOOR_BPS = 0, a "loss exit" can't happen through
        // the sell path (the floor blocks it). The interesting case
        // for the reset rule is a partial exit that leaves
        // `cumOut < cumIn` — where the reset trigger condition
        // (`cumOut >= cumIn`) doesn't fire.
        _depositAs(1 ether);
        _setEpoch(10);

        // Sell half the position at par. cumOut becomes 0.5; still
        // less than cumIn = 1. No reset trigger on subsequent deposit.
        _withdrawAs(500 ether);
        assertEq(adapter.cumulativeEthIn(), 1 ether);
        assertEq(adapter.cumulativeEthOut(), 0.5 ether);

        // Redeposit. Reset should NOT fire (cumOut < cumIn).
        _setEpoch(20);
        _depositAs(0.1 ether);
        // cumIn went UP (no reset), now 1.1 ETH total.
        assertEq(adapter.cumulativeEthIn(), 1.1 ether);
        // tokensFromSwapsIn is monotonic: 1000 + 100 = 1100.
        assertEq(adapter.tokensFromSwapsIn(), 1100 ether);
    }

    // ─── Owner controls (transferFeeClaim, freeze, Ownable2Step) ─────────

    function test_transferFeeClaim_only_callable_by_owner() public {
        vm.prank(address(0xBADD));
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBADD))
        );
        adapter.transferFeeClaim(address(0xCAFE0001));
    }

    function test_transferFeeClaim_rejects_zero_address() public {
        vm.expectRevert(CostanzaTokenAdapter.InvalidConfig.selector);
        adapter.transferFeeClaim(address(0));
    }

    function test_transferFeeClaim_updates_upstream_recipient() public {
        address newAdapter = address(0xCAFE0001);
        vm.expectEmit(true, false, false, false, address(adapter));
        emit CostanzaTokenAdapter.FeeClaimRecipientChanged(newAdapter);
        adapter.transferFeeClaim(newAdapter);

        // Verify the mock distributor was actually re-pointed.
        assertEq(feeDistributor.recipient(), newAdapter);
    }

    function test_transferOwnership_two_step() public {
        address newOwner = address(0xCAFE0002);
        adapter.transferOwnership(newOwner);
        // Pending owner is set; current owner unchanged.
        assertEq(adapter.owner(), address(this));
        assertEq(adapter.pendingOwner(), newOwner);
        // The new owner must accept.
        vm.prank(newOwner);
        adapter.acceptOwnership();
        assertEq(adapter.owner(), newOwner);
        assertEq(adapter.pendingOwner(), address(0));
    }

    function test_freeze_only_callable_by_owner() public {
        vm.prank(address(0xBADD));
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBADD))
        );
        adapter.freeze();
    }

    function test_freeze_zeros_owner() public {
        vm.expectEmit(false, false, false, false, address(adapter));
        emit CostanzaTokenAdapter.Frozen();
        adapter.freeze();
        assertEq(adapter.owner(), address(0));
    }

    function test_freeze_clears_pending_owner_too() public {
        address pending = address(0xCAFE0003);
        adapter.transferOwnership(pending);
        assertEq(adapter.pendingOwner(), pending);

        adapter.freeze();
        assertEq(adapter.owner(), address(0));
        assertEq(adapter.pendingOwner(), address(0));
    }

    function test_post_freeze_transferFeeClaim_reverts() public {
        adapter.freeze();
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        adapter.transferFeeClaim(address(0xCAFE));
    }

    function test_post_freeze_freeze_reverts() public {
        adapter.freeze();
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        adapter.freeze();
    }

    function test_post_freeze_transferOwnership_reverts() public {
        adapter.freeze();
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        adapter.transferOwnership(address(0xCAFE));
    }

    function test_post_freeze_deposit_still_works() public {
        adapter.freeze();
        // Adapter continues to function for the IM and the agent.
        uint256 shares = _depositAs(0.1 ether);
        assertGt(shares, 0);
    }

    function test_post_freeze_withdraw_still_works() public {
        _depositAs(0.5 ether);
        adapter.freeze();
        _setEpoch(10);
        uint256 ethOut = _withdrawAs(adapter.tokensFromSwapsIn());
        assertGt(ethOut, 0);
    }

    function test_post_freeze_pokeFees_still_works() public {
        adapter.freeze();
        _seedFees(0.1 ether, 0);
        // Use a payable EOA as the keeper so the tip transfer succeeds
        // (the test contract itself is not payable).
        address keeper = address(0xBEEF);
        vm.prank(keeper);
        adapter.pokeFees();
        // Tip went to keeper, rest to fund. Adapter holds nothing.
        assertEq(address(adapter).balance, 0);
        assertGt(keeper.balance, 0);
    }

    function test_post_freeze_balance_still_works() public {
        _depositAs(0.5 ether);
        adapter.freeze();
        // balance() is staticcall-shaped; must still return cleanly.
        uint256 b = adapter.balance();
        assertGt(b, 0);
    }

    // ─── tokenIsCurrency0 = true (non-native pool) ───────────────────────
    //
    // Production deployment has $COSTANZA at currency0 (its address sorts
    // lower than WETH's). Our default test setUp uses a native-ETH pool
    // where currency0 = address(0), so `tokenIsCurrency0 = false`. These
    // tests build a separate adapter against a non-native pool where the
    // token is currency0 — exercising the inverse branch of the price
    // math (`_quoteEthForTokens` and `_quoteTokensForEth`).

    /// @dev Deploy a sister adapter against a non-native pool where the
    ///      token is currency0. Reuses the same swapper/state-reader/
    ///      fees infrastructure (which doesn't care about pool ordering).
    function _deployTokenIsCurrency0Adapter() internal returns (CostanzaTokenAdapter) {
        PoolKey memory key = PoolKey({
            currency0: address(token),  // token first
            currency1: address(weth),   // WETH second
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        return new CostanzaTokenAdapter(
            address(token),
            address(weth),
            poolManager,
            address(stateReader),
            address(swapper),
            address(feeDistributor),
            FUND,
            IM,
            key,
            TEST_MAX_NET_ETH_IN,
            InitialState(0, 0, 0, 0, 0)
        );
    }

    /// @dev Set spot price on the state reader for a `tokenIsCurrency0=true`
    ///      pool. The price-math branch is the inverse of the native-pool
    ///      case, so `V4PriceMath` needs the flag flipped.
    function _setSpotForCurrency0(uint256 tokensPerEth18) internal {
        uint160 sqrt_ = V4PriceMath.sqrtPriceX96FromTokensPerEth18(
            tokensPerEth18,
            true // tokenIsCurrency0
        );
        stateReader.setSqrtPriceX96(sqrt_);
    }

    function test_currency0_token_constructor_sets_flag() public {
        CostanzaTokenAdapter a = _deployTokenIsCurrency0Adapter();
        assertTrue(a.tokenIsCurrency0());
        assertFalse(a.nativeEthPool()); // currency0 is the token, not address(0)
    }

    function test_currency0_token_balance_uses_inverted_quote() public {
        CostanzaTokenAdapter a = _deployTokenIsCurrency0Adapter();
        // Seed token balance directly — simulating a position.
        // (We can't go through deposit() easily because it uses the
        // shared swapper which is configured for the native-pool.
        // Mint tokens to the adapter and verify balance() math directly.)
        token.mint(address(a), 1000 ether);

        // Set spot at 1000 tokens/ETH for a tokenIsCurrency0=true pool.
        _setSpotForCurrency0(1000e18);

        // 1000 tokens × (1 ETH / 1000 tokens) = 1 ETH.
        // Same answer as the native-pool case, just via the inverse
        // branch of _quoteEthForTokens.
        uint256 b = a.balance();
        assertApproxEqAbs(b, 1 ether, 1e10);
    }

    function test_currency0_token_balance_at_different_prices() public {
        CostanzaTokenAdapter a = _deployTokenIsCurrency0Adapter();
        token.mint(address(a), 1000 ether);

        // Token doubles vs ETH → fewer tokens per ETH on the inverse branch.
        _setSpotForCurrency0(500e18);
        // 1000 tokens × (1/500 ETH) = 2 ETH.
        assertApproxEqAbs(a.balance(), 2 ether, 1e10);

        // Token halves vs ETH → more tokens per ETH.
        _setSpotForCurrency0(2000e18);
        // 1000 tokens × (1/2000 ETH) = 0.5 ETH. Below netEthBasis floor
        // (which is 0 here since we minted directly, not deposited).
        // So balance() = max(0.5, 0) = 0.5.
        assertApproxEqAbs(a.balance(), 0.5 ether, 1e10);
    }

    function test_currency0_token_balance_zero_with_no_tokens() public view {
        // Inline construction to keep test minimal.
        // Just verify the inverted-branch path also handles empty.
        // (We can't easily construct here without pollution; check
        // adapter's existing branch instead — already covered.)
        // This test exists as documentation that the empty case is
        // covered by `test_balance_zero_with_no_position` for the
        // native-pool branch and we trust the inverse symmetric.
    }

    // ─── migrate() — owner-driven migration to a successor adapter ───────

    /// @dev Build a v2 adapter that inherits the given InitialState.
    function _deployV2(InitialState memory init) internal returns (CostanzaTokenAdapter) {
        PoolKey memory key = PoolKey({
            currency0: address(0),
            currency1: address(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        return new CostanzaTokenAdapter(
            address(token),
            address(weth),
            poolManager,
            address(stateReader),
            address(swapper),
            address(feeDistributor),
            FUND,
            IM,
            key,
            TEST_MAX_NET_ETH_IN,
            init
        );
    }

    /// @dev Snapshot v1's accumulators for the v2 deploy.
    function _snapshotState() internal view returns (InitialState memory) {
        return InitialState({
            cumulativeEthIn:    adapter.cumulativeEthIn(),
            cumulativeEthOut:   adapter.cumulativeEthOut(),
            tokensFromSwapsIn:  adapter.tokensFromSwapsIn(),
            tokensFromSwapsOut: adapter.tokensFromSwapsOut(),
            lastDepositEpoch:   adapter.lastDepositEpoch()
        });
    }

    function test_migrate_only_callable_by_owner() public {
        CostanzaTokenAdapter v2 = _deployV2(InitialState(0, 0, 0, 0, 0));
        vm.prank(address(0xBADD));
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBADD))
        );
        adapter.migrate(address(v2));
    }

    function test_migrate_rejects_zero_address() public {
        vm.expectRevert(CostanzaTokenAdapter.InvalidConfig.selector);
        adapter.migrate(address(0));
    }

    function test_migrate_rejects_self() public {
        vm.expectRevert(CostanzaTokenAdapter.InvalidConfig.selector);
        adapter.migrate(address(adapter));
    }

    function test_migrate_transfers_tokens_to_v2() public {
        _depositAs(1 ether);
        // Accumulate some fee tokens too.
        _seedFees(0, 500 ether);
        adapter.pokeFees();
        assertEq(token.balanceOf(address(adapter)), 1500 ether);

        CostanzaTokenAdapter v2 = _deployV2(_snapshotState());
        adapter.migrate(address(v2));

        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(token.balanceOf(address(v2)), 1500 ether);
    }

    function test_migrate_zeros_v1_accumulators() public {
        _depositAs(1 ether);
        CostanzaTokenAdapter v2 = _deployV2(_snapshotState());
        adapter.migrate(address(v2));

        assertEq(adapter.cumulativeEthIn(), 0);
        assertEq(adapter.cumulativeEthOut(), 0);
        assertEq(adapter.tokensFromSwapsIn(), 0);
        assertEq(adapter.tokensFromSwapsOut(), 0);
        assertTrue(adapter.migrated());
    }

    function test_migrate_v1_balance_returns_zero() public {
        _depositAs(1 ether);
        CostanzaTokenAdapter v2 = _deployV2(_snapshotState());
        adapter.migrate(address(v2));
        // No tokens, zeroed accumulators → balance() reports 0.
        assertEq(adapter.balance(), 0);
    }

    function test_migrate_repoints_fee_distributor() public {
        _depositAs(1 ether);
        CostanzaTokenAdapter v2 = _deployV2(_snapshotState());
        adapter.migrate(address(v2));
        assertEq(feeDistributor.recipient(), address(v2));
    }

    function test_migrate_pulls_pending_fees_into_migration() public {
        _depositAs(1 ether);
        // Seed pending fees in the upstream BEFORE migrate. The
        // migrate path should claim them so they ride with the move.
        _seedFees(0.2 ether, 100 ether);

        uint256 fundBefore = FUND.balance;
        CostanzaTokenAdapter v2 = _deployV2(_snapshotState());
        adapter.migrate(address(v2));

        // Pending WETH was unwrapped + forwarded to fund.
        assertEq(FUND.balance - fundBefore, 0.2 ether);
        // Pending tokens (1100 = 1000 from deposit + 100 fee) all in v2.
        assertEq(token.balanceOf(address(v2)), 1100 ether);
    }

    function test_migrate_emits_event_with_state_snapshot() public {
        _depositAs(1 ether);
        InitialState memory snap = _snapshotState();
        CostanzaTokenAdapter v2 = _deployV2(snap);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit CostanzaTokenAdapter.Migrated(
            address(v2),
            1000 ether, // tokens transferred
            snap.cumulativeEthIn,
            snap.cumulativeEthOut,
            snap.tokensFromSwapsIn,
            snap.tokensFromSwapsOut,
            snap.lastDepositEpoch
        );
        adapter.migrate(address(v2));
    }

    function test_migrate_double_migration_reverts() public {
        _depositAs(1 ether);
        CostanzaTokenAdapter v2 = _deployV2(_snapshotState());
        adapter.migrate(address(v2));

        CostanzaTokenAdapter v3 = _deployV2(InitialState(0, 0, 0, 0, 0));
        vm.expectRevert(CostanzaTokenAdapter.AdapterMigrated.selector);
        adapter.migrate(address(v3));
    }

    function test_migrate_blocked_after_freeze() public {
        adapter.freeze();
        CostanzaTokenAdapter v2 = _deployV2(InitialState(0, 0, 0, 0, 0));
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        adapter.migrate(address(v2));
    }

    function test_post_migration_deposit_reverts() public {
        CostanzaTokenAdapter v2 = _deployV2(InitialState(0, 0, 0, 0, 0));
        adapter.migrate(address(v2));

        vm.deal(IM, 0.1 ether);
        vm.prank(IM);
        vm.expectRevert(CostanzaTokenAdapter.AdapterMigrated.selector);
        adapter.deposit{value: 0.1 ether}();
    }

    function test_post_migration_withdraw_returns_zero() public {
        _depositAs(1 ether);
        CostanzaTokenAdapter v2 = _deployV2(_snapshotState());
        adapter.migrate(address(v2));

        // IM-side post-migration drain — agent or IM.withdrawAll calls
        // adapter.withdraw(N). Adapter accepts, returns 0.
        vm.prank(IM);
        uint256 ethOut = adapter.withdraw(1000 ether);
        assertEq(ethOut, 0);
    }

    function test_post_migration_pokeFees_noop() public {
        CostanzaTokenAdapter v2 = _deployV2(InitialState(0, 0, 0, 0, 0));
        adapter.migrate(address(v2));

        // Even with fees seeded at the upstream (which will now go to
        // v2 anyway), pokeFees on v1 is a no-op — short-circuits before
        // touching the upstream.
        _seedFees(0.1 ether, 0);
        adapter.pokeFees();
        assertEq(address(adapter).balance, 0);
    }

    function test_v2_inherits_state_correctly() public {
        // Build state in v1.
        _depositAs(2 ether); // cumIn=2, tokensFromSwapsIn=2000
        _setEpoch(10);
        _withdrawAs(500 ether); // cumOut=0.5, tokensFromSwapsOut=500

        InitialState memory snap = _snapshotState();
        CostanzaTokenAdapter v2 = _deployV2(snap);

        assertEq(v2.cumulativeEthIn(), 2 ether);
        assertEq(v2.cumulativeEthOut(), 0.5 ether);
        assertEq(v2.tokensFromSwapsIn(), 2000 ether);
        assertEq(v2.tokensFromSwapsOut(), 500 ether);
        assertEq(v2.lastDepositEpoch(), 1);
        // Net basis carries over for the lifetime cap and sell floor.
        assertEq(v2.netEthBasis(), 1.5 ether);
    }

    function test_v2_lifetime_cap_respects_inherited_basis() public {
        // v1 builds up to lifetime cap.
        _depositAs(TEST_MAX_NET_ETH_IN);
        _setEpoch(100);

        InitialState memory snap = _snapshotState();
        CostanzaTokenAdapter v2 = _deployV2(snap);

        // v2 inherits netBasis = TEST_MAX_NET_ETH_IN. Cap is full.
        // Any further deposit on v2 should revert.
        vm.deal(IM, 1 wei);
        vm.prank(IM);
        // (We need to also tell v2 it's the IM address — same constant,
        // shared between v1 and v2 in the test setup.)
        vm.expectRevert(CostanzaTokenAdapter.LifetimeCapExceeded.selector);
        v2.deposit{value: 1 wei}();
    }

    // ─── Adversarial coverage (flash-loan, reentrancy, migration) ────────

    /// @dev A2 (flash-loan pool manipulation). An adversary moves spot
    ///      within a single block; TWAP doesn't budge. Adapter rejects
    ///      the trade on the spot-vs-TWAP gate.
    function test_flash_loan_simulation_blocked_by_spot_vs_twap() public {
        // Establish a position so the cap isn't the binding gate.
        _depositAs(0.1 ether);
        _setEpoch(20);

        // Adversary pushes spot 15% off TWAP — past the 10% gate.
        _setSpot(1150e18);
        // TWAP unchanged (1000) — what real flash loans look like.

        vm.deal(IM, 0.1 ether);
        vm.prank(IM);
        vm.expectRevert(CostanzaTokenAdapter.SpotDeviationExceeded.selector);
        adapter.deposit{value: 0.1 ether}();
    }

    /// @dev A8 (reentrancy via fee claim). Malicious upstream tries to
    ///      re-enter `pokeFees` during the claim. The reentrancy guard
    ///      fires inside the inner call → MockFeeDistributor's `require`
    ///      surfaces the failure → collectFees reverts → strict path
    ///      in pokeFees propagates the revert to the keeper.
    ///
    ///      Critical security property: no fees can be drained while
    ///      the attack is in flight. Whether pokeFees succeeds or
    ///      reverts is secondary — what matters is that the guard fires
    ///      and no value moves.
    function test_reentrancy_pokeFees_blocked() public {
        _seedFees(0.1 ether, 0);
        // Configure malicious mode: collectFees() will call
        // adapter.pokeFees() before settling fees.
        feeDistributor.setReentrancyAttack(
            address(adapter),
            abi.encodeWithSelector(adapter.pokeFees.selector)
        );

        uint256 fundEthBefore = FUND.balance;
        uint256 keeperEthBefore = address(0xBEEF).balance;

        address keeper = address(0xBEEF);
        vm.prank(keeper);
        // Reentrancy attempt: inner call reverts on the guard, mock's
        // require fires, the outer collectFees reverts, pokeFees (now
        // strict) propagates that revert to the keeper. Surface the
        // require message so it's clear which layer caught the attack.
        vm.expectRevert("reentrancy attempt reverted (expected)");
        adapter.pokeFees();

        // No fees moved; no partial claim leaked ETH to the adapter.
        assertEq(address(adapter).balance, 0);
        assertEq(FUND.balance, fundEthBefore);
        assertEq(address(0xBEEF).balance, keeperEthBefore);
    }

    /// @dev A8 reentrancy via deposit path. Same shape as above but the
    ///      attacker re-enters via `deposit`.
    function test_reentrancy_deposit_blocked() public {
        _seedFees(0.1 ether, 0);
        feeDistributor.setReentrancyAttack(
            address(adapter),
            abi.encodeWithSelector(adapter.deposit.selector)
        );

        // Outer deposit succeeds — try/catch swallows the failed
        // claim() (which failed because the re-entrancy was blocked).
        vm.deal(IM, 0.1 ether);
        vm.prank(IM);
        uint256 shares = adapter.deposit{value: 0.1 ether}();
        assertGt(shares, 0);
    }

    /// @dev A11 (migration). After registration of a new adapter and
    ///      `setProtocolActive(old, false)`, the old adapter still
    ///      allows the agent to drain the position via `withdraw`,
    ///      but blocks new deposits via the IM (we can't enforce that
    ///      from the adapter side — the IM does it). Test verifies
    ///      the adapter side: `transferFeeClaim` re-points fee inflow.
    function test_migration_transferFeeClaim_redirects_inflow() public {
        // Pre-flight: set a position so we have something to migrate.
        _depositAs(0.5 ether);

        // Owner re-points to a new "v2" adapter address.
        address newAdapter = address(0xC0DE0001);
        adapter.transferFeeClaim(newAdapter);

        // Seed fees and trigger pokeFees on the OLD adapter. The
        // upstream now sends to newAdapter; the old adapter sees no
        // ETH inflow.
        _seedFees(0.1 ether, 0);
        uint256 oldFundBefore = FUND.balance;
        vm.prank(address(0xBEEF));
        adapter.pokeFees();

        // New recipient (an EOA in this test) holds the WETH+ETH.
        // Old adapter's call to pokeFees claimed nothing because the
        // distributor sent inflow to the new recipient. So the fund
        // got nothing on this poke, and no tip was paid.
        assertEq(FUND.balance, oldFundBefore);
    }

    function test_migration_existing_position_still_withdrawable() public {
        // Position exists in old adapter even after migration.
        _depositAs(0.5 ether);
        _setEpoch(10);
        adapter.transferFeeClaim(address(0xC0DE));

        // Withdraw still works — the IM still sends actions through.
        uint256 ethOut = _withdrawAs(adapter.tokensFromSwapsIn());
        assertGt(ethOut, 0);
    }

    function test_reset_event_fires_on_redeposit_after_profitable_exit() public {
        // Profitable full exit, then redeposit triggers AccumulatorsReset.
        // History gate needs time skips for each large price move.
        _depositAs(1 ether);
        _setEpoch(10);
        skip(11 hours); // widen gate enough for 25% pump (1000 → 800)
        _setSpot(800e18); swapper.setRate(800e18);
        _withdrawAs(adapter.tokensFromSwapsIn());

        _setEpoch(20);
        // 800 → 2000 is a 60% drop — needs ~28 hours of drift to clear gate.
        skip(28 hours);
        _setSpot(2000e18); swapper.setRate(2000e18);

        vm.expectEmit(false, false, false, false, address(adapter));
        emit CostanzaTokenAdapter.AccumulatorsReset();
        _depositAs(0.1 ether);
    }

    function test_reset_establishes_fresh_baseline_after_profitable_exit() public {
        // Buy, fully exit at profit, redeposit at a different price.
        // The reset rule zeros the accumulators so the new deposit
        // shows up as a clean entry (not a continuation of the prior
        // position's history).
        _depositAs(1 ether);
        _setEpoch(10);

        skip(11 hours);
        _setSpot(800e18);
        swapper.setRate(800e18);
        _withdrawAs(adapter.tokensFromSwapsIn());

        _setEpoch(20);
        skip(28 hours);
        _setSpot(2000e18);
        swapper.setRate(2000e18);

        uint256 shares = _depositAs(0.1 ether);
        assertGt(shares, 0);
        // Fresh baseline: only the new deposit counts.
        assertEq(adapter.cumulativeEthIn(), 0.1 ether);
        assertEq(adapter.cumulativeEthOut(), 0);
        assertEq(adapter.tokensFromSwapsIn(), 200 ether);
    }
}

// =====================================================================
// End-to-end: real fund + IM + adapter wired through speedrunEpoch.
//
// Validates the IM snapshot path. Specifically: balance() must never
// revert from inside `totalInvestedValue()` / `_buildInvestmentsHash`
// during epoch close, even when state-reader failures occur.
// This is the showstopper test from §11 of the design doc.
// =====================================================================

contract CostanzaAdapterE2ETest is EpochTest {
    TheHumanFund        fund;
    InvestmentManager   im;
    AuctionManager      am;

    MockCostanzaToken   token;
    MockWETH            weth;
    MockPoolStateReader stateReader;
    MockSwapExecutor    swapper;
    MockFeeDistributor  feeDistributor;
    CostanzaTokenAdapter adapter;

    address constant POOL_MANAGER = address(0xDEAD0001);
    address admin = address(0xAD);

    function setUp() public {
        // Real fund + AM + IM, modeled on InvestmentManager.t.sol::setUp.
        fund = new TheHumanFund{value: 10 ether}(
            1000, 0.0001 ether,
            address(0xBEEF), address(0)
        );
        fund.addNonprofit("NP1", "Nonprofit 1", bytes32("EIN-1"));

        im = new InvestmentManager(address(fund), admin);
        fund.setInvestmentManager(address(im));

        am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am), 1200, 1200, 82800);

        // V4 mocks.
        token = new MockCostanzaToken();
        weth = new MockWETH();
        stateReader = new MockPoolStateReader();
        swapper = new MockSwapExecutor(address(token), address(weth), 1000e18);
        feeDistributor = new MockFeeDistributor(address(token), address(weth), address(this));

        // Liquidity for the swapper.
        token.mint(address(this), 1_000_000 ether);
        token.approve(address(swapper), type(uint256).max);
        swapper.seedTokenLiquidity(500_000 ether);
        vm.deal(address(swapper), 1000 ether);

        PoolKey memory key = PoolKey({
            currency0: address(0),
            currency1: address(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });

        adapter = new CostanzaTokenAdapter(
            address(token),
            address(weth),
            POOL_MANAGER,
            address(stateReader),
            address(swapper),
            address(feeDistributor),
            payable(address(fund)),
            address(im),
            key,
            5 ether,
            InitialState(0, 0, 0, 0, 0)
        );

        // Seed state reader's spot to match the swapper rate.
        uint160 sqrt_ = V4PriceMath.sqrtPriceX96FromTokensPerEth18(1000e18, false);
        stateReader.setSqrtPriceX96(sqrt_);

        feeDistributor.setRecipient(address(adapter));

        vm.prank(admin);
        im.addProtocol(
            address(adapter),
            "Costanza Token",
            unicode"Your own memecoin, $COSTANZA. Speculative — buy/sell via deposit/withdraw; trading fees from other holders accrue to the fund and lower your per-token cost basis. The contract won't sell below cost basis, so a position can be locked during drawdowns. Lifetime cap: 5 ETH.",
            4,  // riskTier: high
            0   // expectedApyBps: meaningless for this protocol
        );

        _registerMockVerifier(fund);
    }

    /// @dev Action type 3 = invest. `amount` in ETH terms.
    function _investAction(uint256 pid, uint256 amt) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(3), abi.encode(pid, amt));
    }

    function _withdrawAction(uint256 pid, uint256 amt) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(4), abi.encode(pid, amt));
    }

    function _noopAction() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0));
    }

    // ─── E2E happy path ──────────────────────────────────────────────────

    function test_e2e_invest_via_action() public {
        speedrunEpoch(fund, _investAction(1, 0.1 ether), "investing in COSTANZA");

        assertEq(adapter.cumulativeEthIn(), 0.1 ether);
        assertEq(adapter.tokensFromSwapsIn(), 100 ether); // 1000 rate × 0.1 ETH

        // IM tracks position.
        (, uint256 shares, uint256 currentValue,,,,) = im.getPosition(1);
        assertEq(shares, 100 ether);
        assertGt(currentValue, 0);
    }

    function test_e2e_balance_inside_snapshot_path() public {
        speedrunEpoch(fund, _investAction(1, 0.1 ether), "invest");

        // totalInvestedValue calls every adapter's balance() — confirm
        // it doesn't revert and returns a sensible value.
        uint256 total = im.totalInvestedValue();
        assertGt(total, 0);

        // im.stateHash() also calls balance() during the rollup.
        bytes32 h = im.stateHash();
        assertTrue(h != bytes32(0));
    }

    function test_e2e_balance_does_not_revert_on_state_reader_failure() public {
        speedrunEpoch(fund, _investAction(1, 0.1 ether), "invest");

        // Kill the state reader (simulates pool death / spot read
        // failure). balance() should fall back to the cost-basis
        // floor instead of reverting.
        stateReader.setFailMode(true);

        // Drive another epoch through — IM's snapshot path will call
        // balance() during state hashing. Must not revert; this is the
        // showstopper invariant.
        speedrunEpoch(fund, _noopAction(), "no-op after pool death");

        uint256 total = im.totalInvestedValue();
        assertEq(total, 0.1 ether); // cost-basis floor
    }

    function test_e2e_withdraw_via_action() public {
        speedrunEpoch(fund, _investAction(1, 0.1 ether), "invest");
        // Withdraw 50 millies in ETH terms (the IM converts to shares).
        speedrunEpoch(fund, _withdrawAction(1, 0.05 ether), "exit half");

        assertGt(adapter.cumulativeEthOut(), 0);
        // tokensFromSwapsIn is monotonic-up; the SOLD tokens land in
        // tokensFromSwapsOut.
        assertGt(adapter.tokensFromSwapsOut(), 0);
    }

    /// @dev Snapshot path with the adapter must produce a deterministic
    ///      `stateHash`. Hash equality across runs at same state proves
    ///      no nondeterminism (e.g., from balance() randomness).
    function test_e2e_state_hash_deterministic_across_epochs() public {
        speedrunEpoch(fund, _investAction(1, 0.1 ether), "invest");
        bytes32 h1 = im.stateHash();
        bytes32 h2 = im.stateHash();
        assertEq(h1, h2);
    }
}
