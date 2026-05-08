// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/adapters/CostanzaTokenAdapter.sol";
import "../src/InvestmentManager.sol";
import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
import "./helpers/CostanzaTokenAdapterMocks.sol";
import "./helpers/MockEndaoment.sol";
import "./helpers/V4PriceMath.sol";

/// @title CostanzaTokenAdapterAdversarial
/// @notice Simulation harness for adversarial scenarios.
///
/// Real fund + IM + adapter; mocked V4 plumbing for deterministic
/// control of price + fee inflows. We bypass the auction flow and
/// call `im.deposit/withdraw` directly via `vm.prank(address(fund))`
/// — this lets us advance wall-clock time freely (needed for the
/// history gate) without having to keep the auction in the right
/// phase. The adapter + IM behavior under test is the same.
///
/// "On-paper" treasury = `fund.balance + im.totalInvestedValue()`,
/// which uses `adapter.balance()` (cost-basis floored).
/// "Realizable" treasury marks tokens to current spot —
/// the gap between on-paper and realizable is hidden loss.
///
/// **These tests are documentation, not regression coverage.** They're
/// the executable backing for `docs/COSTANZA_TOKEN_ADAPTER_ADVERSARIAL_REPORT.md`.
/// Skipped by default; set `RUN_ADVERSARIAL_SIM=1` to run them:
///
///     RUN_ADVERSARIAL_SIM=1 forge test \
///         --match-path test/CostanzaTokenAdapterAdversarial.t.sol -vv
contract CostanzaTokenAdapterAdversarial is Test {
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

    uint256 constant NATURAL_RATE = 1000e18; // 1000 tokens per ETH

    /// @dev Skip unless explicitly opted in. These are sim-driven docs,
    ///      not part of the default test suite.
    modifier needsOptIn() {
        if (vm.envOr("RUN_ADVERSARIAL_SIM", uint256(0)) == 0) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        fund = new TheHumanFund{value: 10 ether}(
            1000, 0.0001 ether,
            address(0xBEEF), address(0)
        );
        fund.addNonprofit("NP1", "Nonprofit 1", bytes32("EIN-1"));

        im = new InvestmentManager(address(fund), admin);
        fund.setInvestmentManager(address(im));

        am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am), 1200, 1200, 82800);

        // Mocks.
        token          = new MockCostanzaToken();
        weth           = new MockWETH();
        stateReader    = new MockPoolStateReader();
        swapper        = new MockSwapExecutor(address(token), address(weth), NATURAL_RATE);
        feeDistributor = new MockFeeDistributor(address(token), address(weth), address(this));

        token.mint(address(this), 100_000_000 ether);
        token.approve(address(swapper), type(uint256).max);
        swapper.seedTokenLiquidity(50_000_000 ether);
        vm.deal(address(swapper), 10_000 ether);

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

        _setSpot(NATURAL_RATE);
        feeDistributor.setRecipient(address(adapter));

        vm.prank(admin);
        im.addProtocol(
            address(adapter),
            "Costanza Token",
            "Speculative position in $COSTANZA.",
            4, 0
        );
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _setSpot(uint256 tokensPerEth18) internal {
        uint160 sqrt_ = V4PriceMath.sqrtPriceX96FromTokensPerEth18(tokensPerEth18, false);
        stateReader.setSqrtPriceX96(sqrt_);
    }

    /// @dev Set both spot and swapper rate together (pool moves naturally).
    function _setMarket(uint256 tokensPerEth18) internal {
        _setSpot(tokensPerEth18);
        swapper.setRate(tokensPerEth18);
    }

    /// @dev Bypass the auction flow: call IM directly as the fund.
    ///      Returns true if the deposit succeeded, false if any layer
    ///      reverted (cap, cooldown, gate, slippage, etc.).
    function _depositViaIM(uint256 amount) internal returns (bool ok) {
        vm.deal(address(fund), address(fund).balance + amount);
        vm.prank(address(fund));
        try im.deposit{value: amount}(1, amount) {
            return true;
        } catch {
            return false;
        }
    }

    function _withdrawViaIM(uint256 amount) internal returns (bool ok) {
        vm.prank(address(fund));
        try im.withdraw(1, amount) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Advance wall-clock time and re-sync the fund. The fund's
    ///      `currentEpoch` advances via `_advanceToNow`, which the
    ///      adapter's cooldown reads. The history gate reads
    ///      `block.timestamp` directly, so the skip widens it.
    function _advanceTime(uint256 t) internal {
        skip(t);
        fund.syncPhase();
    }

    function _treasuryOnPaper() internal view returns (uint256) {
        return address(fund).balance + im.totalInvestedValue();
    }

    function _treasuryRealizable() internal view returns (uint256) {
        try adapter.spotValueOfHoldings() returns (uint256 v) {
            return address(fund).balance + v;
        } catch {
            return address(fund).balance;
        }
    }

    function _logTreasury(string memory label) internal view {
        uint256 onPaper = _treasuryOnPaper();
        uint256 realizable = _treasuryRealizable();
        console.log(label);
        console.log("  on-paper:    ", onPaper);
        console.log("  realizable:  ", realizable);
        if (onPaper > realizable) {
            console.log("  hidden loss: ", onPaper - realizable);
        }
    }

    function _seedFeeTokens(uint256 amount) internal {
        token.mint(address(this), amount);
        token.approve(address(feeDistributor), amount);
        feeDistributor.seedTokenFees(amount);
    }

    // ───────────────────────────────────────────────────────────────────
    // S1: MEV Sandwich Marathon
    //
    // Adversary sandwich-attacks every adapter buy: pumps spot 5%
    // (each token costs 5% more ETH), agent buys at the pumped rate,
    // adversary unwinds. Cooldown limits frequency; lifetime cap +
    // IM 25% cap limit total exposure. We measure long-term bleed.
    // ───────────────────────────────────────────────────────────────────

    function test_S1_mev_sandwich_marathon() public needsOptIn {
        console.log("");
        console.log("=== S1: MEV Sandwich Marathon ===");
        _logTreasury("start");

        uint256 attempts = 0;
        uint256 successes = 0;

        // 100 attempts, 13 hours apart (well clear of cooldown).
        for (uint256 i = 0; i < 100; i++) {
            attempts++;
            // Pump market 5% (tokens-per-ETH drops 5%).
            _setMarket((NATURAL_RATE * 100) / 105);
            // Agent attempts a 0.5 ETH deposit.
            if (_depositViaIM(0.5 ether)) {
                successes++;
            }
            // Restore market for between-attempt periods.
            _setMarket(NATURAL_RATE);
            // Wait between attempts (cooldown + history-gate widening).
            _advanceTime(13 hours);
        }

        console.log("");
        console.log("Attempts:        ", attempts);
        console.log("Successful buys: ", successes);
        console.log("cumulativeEthIn:  ", adapter.cumulativeEthIn());
        console.log("tokensFromSwapsIn:", adapter.tokensFromSwapsIn());
        _logTreasury("end");
    }

    // ───────────────────────────────────────────────────────────────────
    // S2: The Pump-Buy-Dump Trap
    //
    // Adversary pumps spot 50% over a sustained period (long enough
    // for the history gate to widen). Agent (FOMO/prompt-injected)
    // buys at peak. Adversary unwinds; spot returns to natural.
    // Position locked at high cost basis; sells revert.
    // ───────────────────────────────────────────────────────────────────

    function test_S2_pump_buy_dump_trap() public needsOptIn {
        console.log("");
        console.log("=== S2: Pump-Buy-Dump Trap ===");
        _logTreasury("start");

        // Bootstrap a small deposit so the history gate has a sample.
        require(_depositViaIM(0.01 ether), "bootstrap deposit failed");
        _logTreasury("after bootstrap deposit");

        // Adversary slowly pumps spot to ~50% premium. Need to clear
        // both the cooldown (3 epochs × ~24h = ~72h) and the history
        // gate (50% deviation needs ~22h drift). 80h skip handles both.
        _advanceTime(80 hours);
        _setMarket((NATURAL_RATE * 100) / 150); // 667 tokens/ETH

        _logTreasury("after pump (no agent action yet)");

        // Agent goes all-in: 4 ETH at the pumped price.
        bool ok = _depositViaIM(4 ether);
        console.log("FOMO deposit succeeded:", ok);

        console.log("");
        console.log("Adapter state after FOMO:");
        console.log("  cumulativeEthIn:  ", adapter.cumulativeEthIn());
        console.log("  tokensFromSwapsIn:", adapter.tokensFromSwapsIn());

        // Adversary unwinds; spot returns to natural.
        _advanceTime(28 hours);
        _setMarket(NATURAL_RATE);
        _logTreasury("after market returns to natural");

        // Agent tries to sell — sell floor blocks (would yield less
        // than cost basis).
        bool sold = _withdrawViaIM(2 ether);
        console.log("Attempted exit succeeded:", sold);
        _logTreasury("after attempted exit");
    }

    // ───────────────────────────────────────────────────────────────────
    // S3: The Drawdown of Doom (no fee salvation)
    //
    // Real bear: $COSTANZA drops 50% over 30 days. Agent has 5 ETH
    // cost basis at par. No fees flow in. Position is locked
    // indefinitely.
    // ───────────────────────────────────────────────────────────────────

    function test_S3_sustained_drawdown_no_fees() public needsOptIn {
        console.log("");
        console.log("=== S3: The Drawdown of Doom ===");
        _logTreasury("start");

        // Build the position to the IM cap (25% of ~10 ETH).
        // Cooldown is 3 epochs × ~23.67h epoch = ~71h between buys —
        // skip 80h per iteration to clear it.
        for (uint256 i = 0; i < 5; i++) {
            require(_depositViaIM(0.4 ether), "buy failed");
            _advanceTime(80 hours);
        }
        _logTreasury("after building position to cap");
        console.log("netEthBasis:  ", adapter.netEthBasis());
        console.log("tokens held:  ", token.balanceOf(address(adapter)));

        // Drawdown over 30 days, 24h steps. Each step: ~2.3% drop in
        // token value (compound to ~50% over 30 steps).
        uint256 currentRate = NATURAL_RATE;
        for (uint256 i = 0; i < 30; i++) {
            currentRate = (currentRate * 1023) / 1000;
            _setMarket(currentRate);
            _advanceTime(24 hours);

            // Agent attempts to exit periodically (all blocked).
            if (i % 5 == 0) {
                bool sold = _withdrawViaIM(0.5 ether);
                if (sold) console.log("  [warn] sell succeeded mid-drawdown!");
            }
        }

        console.log("");
        console.log("Final spot rate (tokens/ETH):", currentRate);
        _logTreasury("end (after 30-day drawdown)");
    }

    // ───────────────────────────────────────────────────────────────────
    // S4: The Phoenix (drawdown with fee salvation)
    //
    // Same as S3 but fees actively flow in. Per-token cost basis drops
    // over time; eventually sells unlock.
    // ───────────────────────────────────────────────────────────────────

    function test_S4_drawdown_with_fees() public needsOptIn {
        console.log("");
        console.log("=== S4: The Phoenix ===");

        // Build a 1 ETH position.
        require(_depositViaIM(1 ether), "buy failed");
        _logTreasury("after 1 ETH buy");
        console.log("netEthBasis:", adapter.netEthBasis());
        console.log("tokens held:", token.balanceOf(address(adapter)));

        // Drawdown 30%.
        _advanceTime(20 hours);
        _setMarket((NATURAL_RATE * 130) / 100); // 1300 tokens/ETH
        _logTreasury("after 30% drawdown");

        // Try to sell — should fail.
        bool sold1 = _withdrawViaIM(0.5 ether);
        console.log("Pre-fee sell attempt succeeded:", sold1);
        _logTreasury("after failed exit attempt");

        // Fees flow in: 800 free tokens. Per-token basis drops.
        _advanceTime(2 hours);
        _seedFeeTokens(800 ether);
        adapter.pokeFees();
        console.log("");
        console.log("After fee inflow:");
        console.log("  tokens held:           ", token.balanceOf(address(adapter)));
        console.log("  netEthBasis:            ", adapter.netEthBasis());
        // per-token basis = netEthBasis × 1e18 / totalTokens (in 1e18 units)
        console.log("  per-token basis x1e18:  ",
            (adapter.netEthBasis() * 1e18) / token.balanceOf(address(adapter)));

        // Now per-token basis is 1 ETH / 1800 tokens ≈ 0.000556 ETH.
        // Spot is 1/1300 ≈ 0.000769 ETH per token. Sell should clear.
        bool sold2 = _withdrawViaIM(0.5 ether);
        console.log("Post-fee sell attempt succeeded:", sold2);
        _logTreasury("after fee-enabled exit");
    }

    // ───────────────────────────────────────────────────────────────────
    // S5: The Beneficiary Hijack Attempt
    //
    // Random attacker tries every owner-gated and IM-gated entry point
    // on the adapter. None should permit them to drain or hijack.
    // ───────────────────────────────────────────────────────────────────

    function test_S5_beneficiary_hijack_attempt() public needsOptIn {
        console.log("");
        console.log("=== S5: Beneficiary Hijack Attempt ===");

        // Build a position so there's something to drain.
        require(_depositViaIM(1 ether), "buy failed");

        address attacker = address(0xBADD);
        address attackerBeneficiary = address(0xBADD0BAD);
        uint256 attackerEthBefore = attacker.balance;
        uint256 attackerTokensBefore = token.balanceOf(attacker);

        // (a) Random caller tries transferFeeClaim.
        vm.prank(attacker);
        try adapter.transferFeeClaim(attackerBeneficiary) {
            console.log("  transferFeeClaim succeeded (BAD)");
        } catch {
            console.log("  transferFeeClaim reverted (good)");
        }

        // (b) Random caller tries deposit.
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        try adapter.deposit{value: 1 ether}() {
            console.log("  deposit from attacker succeeded (BAD)");
        } catch {
            console.log("  deposit from attacker reverted (good)");
        }

        // (c) Random caller tries withdraw.
        vm.prank(attacker);
        try adapter.withdraw(100 ether) {
            console.log("  withdraw from attacker succeeded (BAD)");
        } catch {
            console.log("  withdraw from attacker reverted (good)");
        }

        // (d) Random caller tries migrate.
        vm.prank(attacker);
        try adapter.migrate(attackerBeneficiary) {
            console.log("  migrate from attacker succeeded (BAD)");
        } catch {
            console.log("  migrate from attacker reverted (good)");
        }

        // (e) Random caller tries freeze.
        vm.prank(attacker);
        try adapter.freeze() {
            console.log("  freeze from attacker succeeded (BAD)");
        } catch {
            console.log("  freeze from attacker reverted (good)");
        }

        console.log("");
        console.log("Attacker ETH gain:    ", attacker.balance - attackerEthBefore);
        console.log("Attacker token gain:  ", token.balanceOf(attacker) - attackerTokensBefore);
        console.log("Adapter tokens still: ", token.balanceOf(address(adapter)));
    }

    // ───────────────────────────────────────────────────────────────────
    // S6: The Doppler Compromise
    //
    // Adversary takes over the fee distributor (in our mock, by
    // changing the recipient registration). Future fees stop flowing
    // to the adapter. Existing position is untouched. Adapter degrades
    // gracefully — no reverts on routine ops, just no fee inflow.
    // ───────────────────────────────────────────────────────────────────

    function test_S6_doppler_compromise() public needsOptIn {
        console.log("");
        console.log("=== S6: Doppler Compromise ===");

        // Build position; accumulate legitimate fees.
        require(_depositViaIM(1 ether), "buy failed");
        _seedFeeTokens(200 ether);
        adapter.pokeFees();
        _logTreasury("after legit ops");

        // Adversary takes over Doppler hook and re-routes the
        // beneficiary registration to themselves.
        feeDistributor.setRecipient(address(0xBADD0BAD));

        // New fees seeded — they now go to attacker.
        _seedFeeTokens(500 ether);

        // Routine ops: pokeFees still runs (try/catch swallows the
        // failed claim).
        adapter.pokeFees();
        console.log("");
        console.log("After hostile poke:");
        console.log("  adapter tokens:  ", token.balanceOf(address(adapter)));
        console.log("  attacker tokens: ", token.balanceOf(address(0xBADD0BAD)));

        // Withdraws still work (independent of fee inflow).
        _advanceTime(13 hours);
        bool ok = _withdrawViaIM(0.5 ether);
        console.log("");
        console.log("Withdraw post-compromise succeeded:", ok);
        _logTreasury("after withdraw");

        console.log("");
        console.log("Adapter still functional; attacker captured future fee flow only.");
        console.log("Existing position is safe.");
    }
}
