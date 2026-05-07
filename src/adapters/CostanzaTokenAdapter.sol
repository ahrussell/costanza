// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IProtocolAdapter.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./IFeeDistributor.sol";
import "./IPoolOracle.sol";
import "./IPoolStateReader.sol";
import "./ISwapExecutor.sol";
import "./IWETH.sol";

/// @notice Minimal ERC-20 surface used by the adapter (transfer, balance, approve).
interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Minimal TheHumanFund surface — adapter reads the current epoch
///         for cooldown enforcement.
interface ITheHumanFund {
    function currentEpoch() external view returns (uint256);
}

/// @notice Uniswap V4 PoolKey. Five-tuple identifying a unique pool inside
///         the V4 PoolManager singleton. `address(0)` for `currency0`
///         indicates the pool trades native ETH on the lower side.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @title CostanzaTokenAdapter
/// @notice Lets the agent buy/sell the $COSTANZA token (Uniswap V4 pool on
///         Base) through the existing InvestmentManager interface, and
///         auto-routes upstream creator-fee inflows to the fund treasury.
///
/// @dev Differences from the existing yield-protocol adapters:
///        - Speculative (not yield-bearing). `expectedApyBps` registered
///          as 0; agent-facing description warns explicitly.
///        - Tighter bounds: cooldown, lifetime exposure cap,
///          spot-vs-TWAP gate, cost-basis sell floor. All hardcoded
///          (or constructor-immutable); no setters.
///        - Owner has exactly one operational lever (`transferFeeClaim`)
///          that gets renounced via `freeze()` permanently.
///        - Auto-claims fees from the upstream distributor on every
///          deposit/withdraw and via permissionless `pokeFees`.
///
///      Full rationale and adversarial scenarios live in
///      docs/COSTANZA_TOKEN_ADAPTER_DESIGN.md.
contract CostanzaTokenAdapter is IProtocolAdapter, Ownable2Step, ReentrancyGuard {
    // ─── Errors ──────────────────────────────────────────────────────────

    error Unauthorized();
    error ZeroAmount();
    error CooldownActive();
    error LifetimeCapExceeded();
    error SpotDeviationExceeded();
    error SwapFailed();
    error TransferFailed();
    error InvalidConfig();

    // ─── Events ──────────────────────────────────────────────────────────

    event FeesClaimed(uint256 ethForwarded, uint256 ethTipped, uint256 tokensReceived);
    event FeeClaimRecipientChanged(address indexed newRecipient);
    event Frozen();
    event AccumulatorsReset();

    // ─── Constants ───────────────────────────────────────────────────────

    /// @notice Cooldown between deposits, in epochs. Withdraws are
    ///         exempt. With `COOLDOWN_EPOCHS = 3`, a deposit in epoch
    ///         N is followed by the next allowed deposit in epoch N+3.
    uint256 internal constant COOLDOWN_EPOCHS = 3;

    /// @notice TWAP lookback window in seconds. Pool's oracle hook
    ///         must support at least this depth.
    uint32 internal constant TWAP_WINDOW = 1800;

    /// @notice Max tolerated deviation between spot and TWAP on the
    ///         buy side. 1000 = 10%. Loose enough to accommodate
    ///         normal directional drift on a memecoin pool; tight
    ///         enough to catch flash-loan-shaped manipulation.
    uint256 internal constant SPOT_DEVIATION_BPS = 1000;

    /// @notice Buy-side slippage floor: `amountOutMinimum` is computed
    ///         as expected_at_twap × (10000 - EXEC_DEVIATION_BPS) / 10000.
    ///         1500 = 15%.
    uint256 internal constant EXEC_DEVIATION_BPS = 1500;

    /// @notice Sell-side floor margin. The sell-side `amountOutMinimum`
    ///         is anchored to per-token cost basis (not TWAP):
    ///           minOut = shares × netEthBasis × (10000 - SELL_FLOOR_BPS)
    ///                    ───────────────────────────────────────────────
    ///                              totalTokens × 10000
    ///         So the agent never sells more than this far below the
    ///         (fee-token-blended) cost basis. 2000 = 20%.
    uint256 internal constant SELL_FLOOR_BPS = 2000;

    /// @notice `pokeFees` caller's tip share of the unwrapped WETH.
    ///         200 = 2%.
    uint256 internal constant POKE_TIP_BPS = 200;

    uint256 internal constant BPS_DENOM = 10000;

    // ─── Immutables ──────────────────────────────────────────────────────

    /// @notice $COSTANZA ERC-20 token.
    IERC20Min public immutable costanzaToken;

    /// @notice Canonical Base WETH. Used only when the pool isn't a
    ///         native-ETH pool; otherwise fee-side WETH is still
    ///         unwrapped on inflow.
    IWETH public immutable weth;

    /// @notice V4 PoolManager — adapter reads pool state via
    ///         `poolStateReader` rather than calling PoolManager directly.
    address public immutable poolManager;

    /// @notice Reads spot price and active liquidity for the pool.
    IPoolStateReader public immutable poolStateReader;

    /// @notice TWAP source. May be a hook contract or a thin wrapper.
    IPoolOracle public immutable oracle;

    /// @notice Executes the actual swap. Wraps UniversalRouter in
    ///         production; mock in tests.
    ISwapExecutor public immutable swapExecutor;

    /// @notice Upstream creator-fee distributor.
    IFeeDistributor public immutable feeDistributor;

    /// @notice TheHumanFund — fee-inflow forwarding destination. Also
    ///         read for `currentEpoch()`.
    address payable public immutable fund;

    /// @notice Sole authorized caller of `deposit`/`withdraw`.
    address public immutable investmentManager;

    /// @notice Absolute cap on net ETH ever deployed (cumIn - cumOut).
    ///         Tighter than the IM's percentage cap once treasury grows.
    uint256 public immutable maxNetEthIn;

    /// @notice Cached PoolKey fields (struct fields can't be immutable
    ///         in Solidity, so flatten).
    address public immutable poolCurrency0;
    address public immutable poolCurrency1;
    uint24  public immutable poolFee;
    int24   public immutable poolTickSpacing;
    address public immutable poolHooks;

    /// @notice `keccak256(abi.encode(poolKey))` — derived once at
    ///         construction so the adapter doesn't re-hash on every read.
    bytes32 public immutable poolId;

    /// @notice True if pool's `currency0 == address(0)` (native ETH pool).
    ///         Controls WETH wrapping in the swap path.
    bool public immutable nativeEthPool;

    /// @notice True if `costanzaToken` is `currency0` of the pool. Used
    ///         to interpret sqrtPriceX96: V4 sqrtPriceX96 represents
    ///         price-of-token0-in-token1 (i.e. token1/token0). For
    ///         "ETH per token" we invert if the token is currency1.
    bool public immutable tokenIsCurrency0;

    // ─── Mutable state ───────────────────────────────────────────────────

    /// @notice Sum of `msg.value` across all deposits. Reset on
    ///         profitable full exit.
    uint256 public cumulativeEthIn;

    /// @notice Sum of swap proceeds across all withdraws. Reset on
    ///         profitable full exit.
    uint256 public cumulativeEthOut;

    /// @notice Tokens received from `deposit()` swaps (not from fees).
    ///         Tracked for off-chain visibility; not used by the
    ///         contract's bound checks. Reset on profitable full exit.
    uint256 public tokensFromSwapsIn;

    /// @notice Tokens spent on `withdraw()` swaps. Off-chain visibility
    ///         only.
    uint256 public tokensFromSwapsOut;

    /// @notice Last epoch a deposit landed. For cooldown enforcement.
    uint64 public lastDepositEpoch;

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyInvestmentManager() {
        if (msg.sender != investmentManager) revert Unauthorized();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(
        address _costanzaToken,
        address _weth,
        address _poolManager,
        address _poolStateReader,
        address _oracle,
        address _swapExecutor,
        address _feeDistributor,
        address payable _fund,
        address _investmentManager,
        PoolKey memory _poolKey,
        uint256 _maxNetEthIn
    ) Ownable(msg.sender) {
        if (_costanzaToken == address(0)
            || _poolManager == address(0)
            || _poolStateReader == address(0)
            || _oracle == address(0)
            || _swapExecutor == address(0)
            || _feeDistributor == address(0)
            || _fund == address(0)
            || _investmentManager == address(0)) {
            revert InvalidConfig();
        }
        if (_maxNetEthIn == 0) revert InvalidConfig();

        // PoolKey must reference $COSTANZA on one side and ETH/WETH on
        // the other. We don't enforce ordering — Uniswap V4 does that
        // (currency0 < currency1 by address, and address(0) is always
        // currency0 if native ETH is one side). But the adapter must be
        // able to identify which side is which.
        bool nativePool = _poolKey.currency0 == address(0);
        bool tokenIs0 = _poolKey.currency0 == _costanzaToken;
        bool tokenIs1 = _poolKey.currency1 == _costanzaToken;
        if (!tokenIs0 && !tokenIs1) revert InvalidConfig();
        // If not a native pool, the non-token side must be WETH.
        if (!nativePool) {
            address otherSide = tokenIs0 ? _poolKey.currency1 : _poolKey.currency0;
            if (otherSide != _weth) revert InvalidConfig();
        }

        costanzaToken    = IERC20Min(_costanzaToken);
        weth             = IWETH(_weth);
        poolManager      = _poolManager;
        poolStateReader  = IPoolStateReader(_poolStateReader);
        oracle           = IPoolOracle(_oracle);
        swapExecutor     = ISwapExecutor(_swapExecutor);
        feeDistributor   = IFeeDistributor(_feeDistributor);
        fund             = _fund;
        investmentManager = _investmentManager;
        maxNetEthIn      = _maxNetEthIn;

        poolCurrency0   = _poolKey.currency0;
        poolCurrency1   = _poolKey.currency1;
        poolFee         = _poolKey.fee;
        poolTickSpacing = _poolKey.tickSpacing;
        poolHooks       = _poolKey.hooks;
        poolId          = keccak256(abi.encode(_poolKey));
        nativeEthPool   = nativePool;
        tokenIsCurrency0 = tokenIs0;

        // One-time max approval so the swap executor can pull tokens
        // without a per-swap SSTORE. The executor is trusted by virtue
        // of being immutable in this adapter; if compromised, redeploy.
        if (!nativePool) {
            IWETH(_weth).approve(_swapExecutor, type(uint256).max);
        }
        IERC20Min(_costanzaToken).approve(_swapExecutor, type(uint256).max);
    }

    // ─── IProtocolAdapter ────────────────────────────────────────────────

    /// @notice Deposit ETH: claim pending fees, then swap WETH/ETH →
    ///         $COSTANZA. Returns the token amount received as `shares`.
    function deposit()
        external
        payable
        override
        onlyInvestmentManager
        nonReentrant
        returns (uint256 shares)
    {
        if (msg.value == 0) revert ZeroAmount();

        // Pull pending fees + dump to fund. Runs first so fee-token
        // inflow lands on the adapter's books before bounds use them.
        _claimAndForwardFees(0);

        // If we've fully exited at a profit since the last entry, zero
        // the accumulators so a new entry establishes a fresh baseline.
        _maybeResetOnProfitableExit();

        // Bounds — fail fast before any swap.
        _checkCooldown();
        _checkLifetimeCap(msg.value);
        _checkSpotVsTwap();

        // Slippage floor: minOut = TWAP-expected × (1 - EXEC_DEVIATION_BPS).
        uint160 sqrtTwap = oracle.consultSqrtPriceX96(poolId, TWAP_WINDOW);
        uint256 expectedTokens = _quoteTokensForEth(sqrtTwap, msg.value);
        uint256 minOut = (expectedTokens * (BPS_DENOM - EXEC_DEVIATION_BPS))
                       / BPS_DENOM;

        uint256 tokenBalBefore = costanzaToken.balanceOf(address(this));

        if (nativeEthPool) {
            // Forward native ETH to the executor.
            shares = swapExecutor.swap{value: msg.value}(
                address(0),
                address(costanzaToken),
                msg.value,
                minOut
            );
        } else {
            // Wrap to WETH; executor pulls via the constructor's max
            // approval and unwraps internally.
            weth.deposit{value: msg.value}();
            shares = swapExecutor.swap(
                address(weth),
                address(costanzaToken),
                msg.value,
                minOut
            );
        }

        // Sanity: tokens must actually have arrived.
        uint256 received = costanzaToken.balanceOf(address(this)) - tokenBalBefore;
        if (received == 0 || shares == 0) revert SwapFailed();
        // Trust the executor's return value if it matches; otherwise
        // prefer the on-chain accounting.
        if (shares > received) shares = received;

        cumulativeEthIn += msg.value;
        tokensFromSwapsIn += shares;
        lastDepositEpoch = uint64(ITheHumanFund(fund).currentEpoch());
    }

    /// @notice Withdraw: swap $COSTANZA → WETH/ETH, send ETH back to IM.
    function withdraw(uint256 shares)
        external
        override
        onlyInvestmentManager
        nonReentrant
        returns (uint256 ethReturned)
    {
        if (shares == 0) revert ZeroAmount();

        // Drain any pending fees first so the upstream's accrued WETH
        // and tokens land on our books before we touch the position.
        _claimAndForwardFees(0);

        // Cap shares to actual balance to avoid revert on partial
        // exits — IM may hand us a stale `shares` from its own ledger
        // and dust accumulation can desync.
        uint256 tokenBal = costanzaToken.balanceOf(address(this));
        if (shares > tokenBal) shares = tokenBal;
        if (shares == 0) revert ZeroAmount();

        // No cooldown or spot-vs-TWAP gate on the sell side — exits
        // should generally be allowed. The cost-basis sell floor
        // (folded into `minOut` below) is the sole bound: it anchors
        // the floor to per-token cost basis rather than to current
        // TWAP, so the agent can't be prompted to dump at arbitrary
        // loss vs. what they paid.
        //
        // In "house money" mode (cumulativeEthOut ≥ cumulativeEthIn,
        // i.e. `netEthBasis() == 0`), there's no floor — sells can
        // execute at any price. Documented behavior; the position is
        // pure profit at that point.
        uint256 minOut = 0;
        uint256 net = netEthBasis();
        uint256 totalTokens = costanzaToken.balanceOf(address(this));
        if (net > 0 && totalTokens > 0) {
            minOut = Math.mulDiv(
                Math.mulDiv(shares, BPS_DENOM - SELL_FLOOR_BPS, BPS_DENOM),
                net,
                totalTokens
            );
        }

        uint256 ethBefore = address(this).balance;

        if (nativeEthPool) {
            // Executor sends native ETH to us via `receive()`.
            ethReturned = swapExecutor.swap(
                address(costanzaToken),
                address(0),
                shares,
                minOut
            );
        } else {
            // Executor sends WETH; we unwrap.
            uint256 wethBefore = weth.balanceOf(address(this));
            ethReturned = swapExecutor.swap(
                address(costanzaToken),
                address(weth),
                shares,
                minOut
            );
            uint256 wethReceived = weth.balanceOf(address(this)) - wethBefore;
            if (wethReceived == 0) revert SwapFailed();
            weth.withdraw(wethReceived);
            // Trust on-chain accounting if executor return diverged.
            if (ethReturned > wethReceived) ethReturned = wethReceived;
        }

        // Confirm ETH actually arrived.
        uint256 ethDelta = address(this).balance - ethBefore;
        if (ethDelta == 0 || ethReturned == 0) revert SwapFailed();
        if (ethReturned > ethDelta) ethReturned = ethDelta;

        cumulativeEthOut += ethReturned;
        tokensFromSwapsOut += shares;

        // Forward to the InvestmentManager (the caller).
        (bool sent, ) = msg.sender.call{value: ethReturned}("");
        if (!sent) revert TransferFailed();
    }

    /// @notice Current ETH-denominated value of the position.
    /// @dev MUST be pure view — no state mutation, no reverts. The
    ///      InvestmentManager calls this via staticcall semantics during
    ///      `totalInvestedValue()` and `_buildInvestmentsHash()`, and a
    ///      revert here breaks the entire epoch snapshot pipeline for
    ///      every adapter. Pool-death / oracle-staleness must fall back
    ///      gracefully to the cost-basis floor.
    function balance() external view override returns (uint256) {
        uint256 floor = netEthBasis();
        try this.twapValueOfHoldings() returns (uint256 twapValue) {
            return twapValue > floor ? twapValue : floor;
        } catch {
            // Oracle hook reverted, mulDiv overflowed, or token balance
            // read reverted. Fall back to cost basis (which may itself
            // be 0 if the position is in profit or empty).
            return floor;
        }
    }

    /// @notice External view used by `balance()`'s try/catch wrapper.
    ///         Call directly only for diagnostics — it can revert on
    ///         oracle failure, which is by design (so `balance()`'s
    ///         try/catch can catch it). Marked external so we can use
    ///         `this.twapValueOfHoldings()` syntax.
    function twapValueOfHoldings() external view returns (uint256) {
        uint256 tokens = costanzaToken.balanceOf(address(this));
        if (tokens == 0) return 0;
        uint160 sqrtTwap = oracle.consultSqrtPriceX96(poolId, TWAP_WINDOW);
        return _quoteEthForTokens(sqrtTwap, tokens);
    }

    function name() external pure override returns (string memory) {
        return "Costanza Token";
    }

    // ─── Public ──────────────────────────────────────────────────────────

    /// @notice Permissionless: claim fees from upstream, unwrap WETH,
    ///         pay caller a `POKE_TIP_BPS` tip, forward the rest to
    ///         fund. $COSTANZA tokens received as fees stay in the
    ///         adapter at zero cost basis (excluded from
    ///         `tokensFromSwapsIn` so post-fee bookkeeping reflects
    ///         only swap-purchased tokens).
    function pokeFees() external nonReentrant {
        _claimAndForwardFees(POKE_TIP_BPS);
    }

    // ─── Owner ───────────────────────────────────────────────────────────

    /// @notice Re-point the upstream fee distributor at `newRecipient`.
    ///         Sole owner-controllable lever pre-freeze.
    /// @dev If the upstream's "set recipient" primitive doesn't match
    ///      `IFeeDistributor.setRecipient`, this is the function whose
    ///      body changes shape (and `IFeeDistributor` along with it).
    function transferFeeClaim(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert InvalidConfig();
        feeDistributor.setRecipient(newRecipient);
        emit FeeClaimRecipientChanged(newRecipient);
    }

    /// @notice Permanently renounce ownership. After this call, no
    ///         `onlyOwner` function is callable ever again. The adapter
    ///         continues to operate normally (deposit/withdraw/balance/
    ///         pokeFees) but the human has no further levers.
    function freeze() external onlyOwner {
        // OZ Ownable._transferOwnership(0) clears _owner and (via
        // Ownable2Step's override) clears _pendingOwner too.
        _transferOwnership(address(0));
        emit Frozen();
    }

    // ─── Views ───────────────────────────────────────────────────────────

    /// @notice Net ETH cost basis: `max(0, cumIn - cumOut)`. Used as
    ///         the floor in `balance()` and as the cap reference for
    ///         `MAX_NET_ETH_IN`.
    function netEthBasis() public view returns (uint256) {
        unchecked {
            return cumulativeEthOut >= cumulativeEthIn
                ? 0
                : cumulativeEthIn - cumulativeEthOut;
        }
    }

    // ─── Internal helpers ────────────────────────────────────────────────

    /// @dev Pull pending fees from upstream, unwrap any WETH inflow,
    ///      forward ETH to fund (minus an optional tip to msg.sender).
    ///      $COSTANZA tokens received stay in the adapter as
    ///      zero-cost-basis additions to the position.
    ///
    ///      Best-effort: if the upstream `claim()` reverts (no pending
    ///      fees, malicious upstream, etc.) we no-op rather than blocking
    ///      the surrounding deposit/withdraw. The reentrancy guards on
    ///      our entry points already block the malicious-upstream
    ///      reentrancy attack independently.
    function _claimAndForwardFees(uint256 tipBps) internal {
        // Snapshot balances BEFORE claim so we only forward the delta.
        // Crucial during deposit(): adapter holds `msg.value` ETH at
        // this point and we MUST NOT forward it to the fund — that's
        // about to be swapped for tokens.
        uint256 ethBefore = address(this).balance;
        uint256 tokenBefore = costanzaToken.balanceOf(address(this));
        uint256 wethBefore = weth.balanceOf(address(this));

        // Best-effort claim. Catch any revert so a misbehaving upstream
        // doesn't brick the surrounding deposit/withdraw.
        try feeDistributor.claim() {
            // OK
        } catch {
            return;
        }

        // Unwrap any new WETH inflow.
        uint256 wethDelta = weth.balanceOf(address(this)) - wethBefore;
        if (wethDelta > 0) {
            weth.withdraw(wethDelta);
        }

        uint256 ethDelta = address(this).balance - ethBefore;
        uint256 tokenDelta = costanzaToken.balanceOf(address(this)) - tokenBefore;

        if (ethDelta == 0) {
            // Tokens may still have arrived; emit for observability.
            if (tokenDelta > 0) {
                emit FeesClaimed(0, 0, tokenDelta);
            }
            return;
        }

        uint256 tip = (ethDelta * tipBps) / BPS_DENOM;
        uint256 forward = ethDelta - tip;

        if (tip > 0) {
            (bool ok, ) = msg.sender.call{value: tip}("");
            if (!ok) revert TransferFailed();
        }
        if (forward > 0) {
            (bool ok, ) = fund.call{value: forward}("");
            if (!ok) revert TransferFailed();
        }

        emit FeesClaimed(forward, tip, tokenDelta);
    }

    /// @notice ETH value of `tokenAmount` $COSTANZA at the given
    ///         `sqrtPriceX96`. Mirrors V3's `OracleLibrary.getQuoteAtTick`.
    /// @dev V4 sqrtPriceX96 = sqrt(token1/token0) × 2^96. The two-branch
    ///      implementation avoids overflow when sqrtPriceX96 is large.
    function _quoteEthForTokens(uint160 sqrtPriceX96, uint256 tokenAmount)
        internal
        view
        returns (uint256 ethAmount)
    {
        if (sqrtPriceX96 == 0 || tokenAmount == 0) return 0;
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            // tokenIsCurrency0 → tokens are token0; ETH is token1.
            //   ETH = tokens × (token1/token0) = tokens × ratio
            // !tokenIsCurrency0 → tokens are token1; ETH is token0.
            //   ETH = tokens / (token1/token0) = tokens / ratio
            ethAmount = tokenIsCurrency0
                ? Math.mulDiv(ratioX192, tokenAmount, 1 << 192)
                : Math.mulDiv(1 << 192, tokenAmount, ratioX192);
        } else {
            uint256 ratioX128 = Math.mulDiv(
                uint256(sqrtPriceX96),
                uint256(sqrtPriceX96),
                1 << 64
            );
            ethAmount = tokenIsCurrency0
                ? Math.mulDiv(ratioX128, tokenAmount, 1 << 128)
                : Math.mulDiv(1 << 128, tokenAmount, ratioX128);
        }
    }

    /// @notice Number of $COSTANZA tokens corresponding to `ethAmount`
    ///         ETH at the given `sqrtPriceX96`. Inverse of `_quoteEthForTokens`.
    function _quoteTokensForEth(uint160 sqrtPriceX96, uint256 ethAmount)
        internal
        view
        returns (uint256 tokenAmount)
    {
        if (sqrtPriceX96 == 0 || ethAmount == 0) return 0;
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            // Inverse of the above: ETH × (1/ratio) when ETH = token1, etc.
            tokenAmount = tokenIsCurrency0
                ? Math.mulDiv(1 << 192, ethAmount, ratioX192)
                : Math.mulDiv(ratioX192, ethAmount, 1 << 192);
        } else {
            uint256 ratioX128 = Math.mulDiv(
                uint256(sqrtPriceX96),
                uint256(sqrtPriceX96),
                1 << 64
            );
            tokenAmount = tokenIsCurrency0
                ? Math.mulDiv(1 << 128, ethAmount, ratioX128)
                : Math.mulDiv(ratioX128, ethAmount, 1 << 128);
        }
    }

    /// @dev Reverts if spot price diverges from TWAP by more than
    ///      `SPOT_DEVIATION_BPS`. Catches flash-loan manipulation
    ///      against a slow-moving TWAP — if spot is currently wildly
    ///      off the time-weighted average, refuse to trade.
    function _checkSpotVsTwap() internal view {
        uint160 sqrtSpot = poolStateReader.getSpotSqrtPriceX96(poolId);
        uint160 sqrtTwap = oracle.consultSqrtPriceX96(poolId, TWAP_WINDOW);
        // Compare ETH value of a fixed-size token bucket at each price.
        uint256 base = 1e18;
        uint256 spotVal = _quoteEthForTokens(sqrtSpot, base);
        uint256 twapVal = _quoteEthForTokens(sqrtTwap, base);
        if (twapVal == 0) revert SpotDeviationExceeded(); // degenerate TWAP

        uint256 upper = (twapVal * (BPS_DENOM + SPOT_DEVIATION_BPS)) / BPS_DENOM;
        uint256 lower = (twapVal * (BPS_DENOM - SPOT_DEVIATION_BPS)) / BPS_DENOM;
        if (spotVal > upper || spotVal < lower) revert SpotDeviationExceeded();
    }

    /// @dev Cooldown enforcement based on current epoch.
    function _checkCooldown() internal view {
        if (lastDepositEpoch == 0) return; // first-ever deposit
        uint256 nowEpoch = ITheHumanFund(fund).currentEpoch();
        if (nowEpoch < uint256(lastDepositEpoch) + COOLDOWN_EPOCHS) {
            revert CooldownActive();
        }
    }

    /// @dev Absolute lifetime exposure cap. Tighter than the IM's
    ///      percentage cap once the treasury grows past `maxNetEthIn`.
    function _checkLifetimeCap(uint256 newDeposit) internal view {
        if (netEthBasis() + newDeposit > maxNetEthIn) {
            revert LifetimeCapExceeded();
        }
    }

    /// @dev On a net-profitable position, zero the accumulators so
    ///      the next deposit establishes a fresh baseline. Only fires
    ///      when `cumulativeEthOut >= cumulativeEthIn` AND
    ///      `cumulativeEthIn > 0` (so it's a real exit, not the
    ///      initial empty state).
    ///
    ///      The asymmetric trigger — only on profitable exits, never
    ///      on losses — keeps wash-sales from gaming the cost-basis
    ///      sell floor: selling at a loss leaves `cumOut < cumIn`, no
    ///      reset, and `netEthBasis` carries the loss forward into the
    ///      lifetime cap and the sell floor on subsequent trades.
    function _maybeResetOnProfitableExit() internal {
        if (cumulativeEthIn > 0 && cumulativeEthOut >= cumulativeEthIn) {
            cumulativeEthIn = 0;
            cumulativeEthOut = 0;
            tokensFromSwapsIn = 0;
            tokensFromSwapsOut = 0;
            emit AccumulatorsReset();
        }
    }

    // ─── Receive ─────────────────────────────────────────────────────────

    /// @dev Accepts ETH from the WETH unwrap and from the SwapExecutor's
    ///      native-ETH return path.
    receive() external payable {}
}
