// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/adapters/IFeeDistributor.sol";
import "../../src/adapters/IPoolStateReader.sol";
import "../../src/adapters/ISwapExecutor.sol";
import "../../src/adapters/IWETH.sol";

// =====================================================================
// MockCostanzaToken
// =====================================================================

/// @notice Minimal ERC-20 used as a stand-in for $COSTANZA in tests.
contract MockCostanzaToken {
    string public constant name     = "Costanza";
    string public constant symbol   = "COSTANZA";
    uint8  public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

// =====================================================================
// MockPoolStateReader
// =====================================================================

/// @notice Test-controlled pool-state reader. Stores `sqrtPriceX96` and
///         `liquidity` directly. Setters let tests simulate pool drift,
///         flash-loan manipulation, drained pools, etc.
contract MockPoolStateReader is IPoolStateReader {
    uint160 public sqrtPriceX96;
    uint128 public liquidity;
    bool    public failMode;

    error StateReaderFail();

    function setSqrtPriceX96(uint160 _v) external {
        sqrtPriceX96 = _v;
    }

    function setLiquidity(uint128 _v) external {
        liquidity = _v;
    }

    function setFailMode(bool _fail) external {
        failMode = _fail;
    }

    function getSpotSqrtPriceX96(bytes32) external view override returns (uint160) {
        if (failMode) revert StateReaderFail();
        return sqrtPriceX96;
    }

    function getActiveLiquidity(bytes32) external view override returns (uint128) {
        if (failMode) revert StateReaderFail();
        return liquidity;
    }
}

// =====================================================================
// MockSwapExecutor
// =====================================================================

/// @notice Test-controlled swap executor. Exchanges `tokenIn`/`tokenOut`
///         at a configured rate (`tokensPerEth18`, scaled by 1e18). Holds
///         a stash of both sides so it can pay out either direction.
///         Tests seed liquidity via `seedTokenLiquidity` and `receive()`.
///
/// @dev The mock honors `minOut` — reverts if computed output falls
///      below it. Lets us drive sandwich-simulation tests deterministically.
contract MockSwapExecutor is ISwapExecutor {
    address public costanzaToken;
    address public weth;

    /// @notice Tokens-per-ETH rate, scaled by 1e18. E.g., 1e18 = 1 token
    ///         per ETH; 1000e18 = 1000 tokens per ETH; 1e15 = 0.001 tokens/ETH.
    uint256 public tokensPerEth18;

    /// @notice Multiplier applied to the rate to simulate slippage. 10000
    ///         = no slippage; 9500 = 5% adverse; 11000 = 10% favorable.
    uint256 public slippageBps = 10000;

    error InsufficientOutput();

    constructor(address _costanzaToken, address _weth, uint256 _tokensPerEth18) {
        costanzaToken = _costanzaToken;
        weth = _weth;
        tokensPerEth18 = _tokensPerEth18;
    }

    function setRate(uint256 _tokensPerEth18) external {
        tokensPerEth18 = _tokensPerEth18;
    }

    function setSlippage(uint256 _bps) external {
        slippageBps = _bps;
    }

    /// @notice Seed the executor with $COSTANZA (so it can pay buyers).
    ///         ETH is funded via `receive()` (direct transfer or selfdestruct).
    function seedTokenLiquidity(uint256 amount) external {
        // Pull tokens from caller via transferFrom.
        IERC20Like(costanzaToken).transferFrom(msg.sender, address(this), amount);
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut
    ) external payable override returns (uint256 amountOut) {
        if (tokenIn == address(0)) {
            // Native ETH in — caller forwarded `msg.value`. Compute
            // tokens-out at rate × slippage.
            require(msg.value == amountIn, "msg.value mismatch");
            amountOut = (amountIn * tokensPerEth18 * slippageBps) / (1e18 * 10000);
            if (amountOut < minOut) revert InsufficientOutput();
            // Pay tokens to caller.
            IERC20Like(costanzaToken).transfer(msg.sender, amountOut);
        } else if (tokenIn == costanzaToken && tokenOut == weth) {
            // Tokens in (WETH out) — pull tokens via transferFrom.
            IERC20Like(costanzaToken).transferFrom(msg.sender, address(this), amountIn);
            amountOut = (amountIn * 1e18 * slippageBps) / (tokensPerEth18 * 10000);
            if (amountOut < minOut) revert InsufficientOutput();
            // WETH path: wrap ETH from our balance and transfer.
            IWETHLike(weth).deposit{value: amountOut}();
            IWETHLike(weth).transfer(msg.sender, amountOut);
        } else if (tokenIn == costanzaToken && tokenOut == address(0)) {
            // Tokens in, native ETH out.
            IERC20Like(costanzaToken).transferFrom(msg.sender, address(this), amountIn);
            amountOut = (amountIn * 1e18 * slippageBps) / (tokensPerEth18 * 10000);
            if (amountOut < minOut) revert InsufficientOutput();
            (bool ok, ) = msg.sender.call{value: amountOut}("");
            require(ok, "eth send failed");
        } else if (tokenIn == weth) {
            // WETH in, tokens out — pull WETH via transferFrom.
            IWETHLike(weth).transferFrom(msg.sender, address(this), amountIn);
            // Unwrap so we hold ETH (matches the native-ETH path's accounting).
            IWETHLike(weth).withdraw(amountIn);
            amountOut = (amountIn * tokensPerEth18 * slippageBps) / (1e18 * 10000);
            if (amountOut < minOut) revert InsufficientOutput();
            IERC20Like(costanzaToken).transfer(msg.sender, amountOut);
        } else {
            revert("unsupported pair");
        }
    }

    receive() external payable {}
}

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IWETHLike {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// =====================================================================
// MockFeeDistributor
// =====================================================================

/// @notice Test-controlled creator-fee distributor. Mirrors the
///         Doppler hook's two-method shape (`release`, `updateBeneficiary`)
///         with a simple per-poolId beneficiary registry.
///
///         Holds a stash of $COSTANZA + WETH representing "pending fees."
///         On `release(poolId, beneficiary)`, transfers everything to
///         the named beneficiary.
///
///         Optional reentrancy mode: when `reentrantTarget != 0`, the
///         release path makes a low-level call to `reentrantTarget`
///         BEFORE settling — used to verify the adapter's
///         `nonReentrant` guards hold.
///
///         The mock keeps a `recipient` field for backward-compatibility
///         with tests that do `setRecipient`-style wiring at setup time;
///         it's the implicit beneficiary used when `release` is called
///         without a poolId-specific override (callers can also pass
///         the beneficiary directly via the IFeeDistributor method).
contract MockFeeDistributor is IFeeDistributor {
    address public recipient;
    address public costanzaToken;
    address public weth;

    address public reentrantTarget;
    bytes   public reentrantCalldata;

    constructor(address _costanzaToken, address _weth, address _initialRecipient) {
        costanzaToken = _costanzaToken;
        weth = _weth;
        recipient = _initialRecipient;
    }

    /// @notice Direct setter — used by tests at setup time to register
    ///         the adapter as recipient before any release call. Kept
    ///         for ergonomics; the IFeeDistributor path is via
    ///         `updateBeneficiary`.
    function setRecipient(address newRecipient) external {
        recipient = newRecipient;
    }

    function updateBeneficiary(bytes32 /* poolId */, address newBeneficiary) external override {
        recipient = newBeneficiary;
    }

    /// @notice Seed pending fees (token side). Caller must `transferFrom`-approve.
    function seedTokenFees(uint256 amount) external {
        IERC20Like(costanzaToken).transferFrom(msg.sender, address(this), amount);
    }

    /// @notice Seed pending fees (WETH side). Caller must `transferFrom`-approve.
    function seedWethFees(uint256 amount) external {
        IWETHLike(weth).transferFrom(msg.sender, address(this), amount);
    }

    /// @notice Direct-deposit ETH; the mock will wrap it on `release`.
    receive() external payable {}

    /// @notice Configure a reentrancy attack: when `release()` runs, it
    ///         will `call(reentrantCalldata)` against `target` before
    ///         transferring fees. Set `target == address(0)` to disable.
    function setReentrancyAttack(address target, bytes calldata data) external {
        reentrantTarget = target;
        reentrantCalldata = data;
    }

    function release(bytes32 /* poolId */, address beneficiary) external override {
        // Fire the reentrancy hook FIRST so it lands inside the
        // adapter's protected function before fees move.
        if (reentrantTarget != address(0)) {
            (bool ok, ) = reentrantTarget.call(reentrantCalldata);
            // If guards fire, the call reverts — surface it.
            require(ok, "reentrancy attempt reverted (expected)");
        }

        // Match Doppler's semantics: the param identifies WHO is being
        // paid out, but only the registered beneficiary actually
        // receives anything. A release call against a non-registered
        // address is a no-op (returns 0 fees because that address has
        // 0 shares in the registry).
        if (beneficiary != recipient) {
            return;
        }

        // Wrap any held ETH into WETH so the adapter gets a uniform
        // ERC-20 inflow (matches real upstream distributor behavior).
        if (address(this).balance > 0) {
            IWETHLike(weth).deposit{value: address(this).balance}();
        }

        uint256 tokenBal = IERC20Like(costanzaToken).balanceOf(address(this));
        if (tokenBal > 0) {
            IERC20Like(costanzaToken).transfer(beneficiary, tokenBal);
        }
        uint256 wethBal = IWETHLike(weth).balanceOf(address(this));
        if (wethBal > 0) {
            IWETHLike(weth).transfer(beneficiary, wethBal);
        }
    }
}
