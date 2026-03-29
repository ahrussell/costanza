// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IInvestmentManager.sol";
import "./interfaces/IProtocolAdapter.sol";

/// @title InvestmentManager
/// @notice Manages a portfolio of DeFi protocol investments for TheHumanFund.
///         Enforces allocation bounds, tracks positions, and provides state
///         hashing for TEE attestation binding.
///
///         Only the fund contract can deposit/withdraw. The admin can manage
///         the protocol registry (add/pause/remove protocols).
///
/// @dev Adapters are stateful contracts that hold receipt tokens. Each adapter
///      is registered with a unique protocol ID. Paused protocols can still
///      be withdrawn from but not deposited into.
contract InvestmentManager is IInvestmentManager {
    // ─── Errors ──────────────────────────────────────────────────────────

    error Unauthorized();
    error InvalidProtocol();
    error ProtocolPaused();
    error ProtocolNotFound();
    error AmountMismatch();
    error ExceedsMaxTotal();
    error ExceedsMaxPerProtocol();
    error InsufficientReserve();
    error WithdrawFailed();
    error ZeroAmount();
    error TransferFailed();
    error Frozen();

    // ─── Events ──────────────────────────────────────────────────────────

    event ProtocolAdded(uint256 indexed protocolId, string name, address adapter, uint8 riskTier);
    event ProtocolPausedEvent(uint256 indexed protocolId, bool paused);
    event Deposited(uint256 indexed protocolId, uint256 amount, uint256 shares);
    event Withdrawn(uint256 indexed protocolId, uint256 shares, uint256 ethReturned);
    event BoundsUpdated(uint256 maxTotalBps, uint256 maxPerProtocolBps, uint256 minReserveBps);

    // ─── Types ───────────────────────────────────────────────────────────

    struct ProtocolInfo {
        IProtocolAdapter adapter;
        string name;
        string description;    // Human-readable description for the agent prompt
        uint8 riskTier;        // 1=low, 2=medium, 3=medium-high, 4=high
        uint16 expectedApyBps; // Expected APY in basis points (informational)
        bool active;           // Can accept new deposits
        bool exists;
    }

    struct Position {
        uint256 depositedEth;    // Cumulative ETH deposited
        uint256 shares;          // Current protocol receipt token balance
    }

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice The fund contract — only caller for deposit/withdraw.
    address public immutable fund;

    /// @notice Admin for protocol registry management.
    address public admin;

    /// @notice Protocol registry (1-indexed to match nonprofit IDs).
    mapping(uint256 => ProtocolInfo) public protocols;

    /// @notice Current positions per protocol.
    mapping(uint256 => Position) public positions;

    /// @notice Number of registered protocols.
    uint256 public override protocolCount;

    /// @notice Max total allocation as % of total assets (basis points).
    /// @dev 8000 = 80%. Total assets = fund.balance + totalInvestedValue().
    uint256 public maxTotalBps = 8000;

    /// @notice Max allocation per protocol as % of total assets (basis points).
    /// @dev 2500 = 25%.
    uint256 public maxPerProtocolBps = 2500;

    /// @notice Min reserve that must stay liquid in the fund (basis points).
    /// @dev 2000 = 20%. Fund balance must stay >= this % of total assets.
    uint256 public minReserveBps = 2000;

    uint256 public constant MAX_PROTOCOLS = 20;

    // Kill switches
    bool public frozenInvestments;
    bool public frozenAdmin;

    event PermissionFrozen(string name);

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(address _fund, address _admin) {
        fund = _fund;
        admin = _admin;
    }

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyFund() {
        if (msg.sender != fund) revert Unauthorized();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    // ─── Protocol Registry ───────────────────────────────────────────────

    /// @notice Register a new protocol adapter.
    /// @param adapter The adapter contract address.
    /// @param _name Human-readable protocol name.
    /// @param riskTier Risk level 1-4 (1=low, 4=high).
    /// @param expectedApyBps Expected APY in basis points (informational only).
    /// @return protocolId The assigned protocol ID.
    function addProtocol(
        address adapter,
        string calldata _name,
        string calldata _description,
        uint8 riskTier,
        uint16 expectedApyBps
    ) external onlyAdmin returns (uint256 protocolId) {
        if (frozenInvestments) revert Frozen();
        if (protocolCount >= MAX_PROTOCOLS) revert InvalidProtocol();
        protocolId = ++protocolCount;
        protocols[protocolId] = ProtocolInfo({
            adapter: IProtocolAdapter(adapter),
            name: _name,
            description: _description,
            riskTier: riskTier,
            expectedApyBps: expectedApyBps,
            active: true,
            exists: true
        });
        emit ProtocolAdded(protocolId, _name, adapter, riskTier);
    }

    /// @notice Pause or unpause a protocol (paused = no new deposits, withdrawals still work).
    function setProtocolActive(uint256 protocolId, bool active) external onlyAdmin {
        if (frozenInvestments) revert Frozen();
        if (!protocols[protocolId].exists) revert ProtocolNotFound();
        protocols[protocolId].active = active;
        emit ProtocolPausedEvent(protocolId, !active);
    }

    /// @notice Update allocation bounds.
    function setBounds(uint256 _maxTotalBps, uint256 _maxPerProtocolBps, uint256 _minReserveBps) external onlyAdmin {
        if (frozenInvestments) revert Frozen();
        require(_maxTotalBps <= 10000 && _maxPerProtocolBps <= 10000 && _minReserveBps <= 10000);
        require(_maxTotalBps + _minReserveBps <= 10000, "total + reserve > 100%");
        maxTotalBps = _maxTotalBps;
        maxPerProtocolBps = _maxPerProtocolBps;
        minReserveBps = _minReserveBps;
        emit BoundsUpdated(_maxTotalBps, _maxPerProtocolBps, _minReserveBps);
    }

    /// @notice Transfer admin role.
    function setAdmin(address _admin) external onlyAdmin {
        if (frozenAdmin) revert Frozen();
        admin = _admin;
    }

    // ─── Kill Switches ───────────────────────────────────────────────────

    function freezeInvestments() external onlyAdmin {
        frozenInvestments = true;
        emit PermissionFrozen("investments");
    }

    function freezeAdmin() external onlyAdmin {
        frozenAdmin = true;
        emit PermissionFrozen("admin");
    }

    // ─── Deposit / Withdraw ──────────────────────────────────────────────

    /// @notice Deposit ETH into a protocol. Only callable by the fund.
    /// @dev msg.value must equal amount. Bounds are checked against total assets
    ///      (fund balance + all invested value).
    function deposit(uint256 protocolId, uint256 amount) external payable override onlyFund {
        if (amount == 0) revert ZeroAmount();
        if (msg.value != amount) revert AmountMismatch();
        if (!protocols[protocolId].exists) revert InvalidProtocol();
        if (!protocols[protocolId].active) revert ProtocolPaused();

        // Bounds checking
        // totalAssets = what the fund had before sending us this ETH + all invested
        // The fund's balance has already been reduced by `amount` (sent as msg.value),
        // so fund.balance is the post-send balance.
        uint256 currentInvested = totalInvestedValue();
        uint256 fundBalance = fund.balance; // post-send (already reduced by amount)
        uint256 totalAssets = fundBalance + currentInvested + amount;

        // Max total allocation check
        uint256 newTotalInvested = currentInvested + amount;
        if (newTotalInvested > (totalAssets * maxTotalBps) / 10000) revert ExceedsMaxTotal();

        // Max per-protocol check
        uint256 protocolValue = protocols[protocolId].adapter.balance() + amount;
        if (protocolValue > (totalAssets * maxPerProtocolBps) / 10000) revert ExceedsMaxPerProtocol();

        // Min reserve check (fund must keep enough liquid)
        if (fundBalance < (totalAssets * minReserveBps) / 10000) revert InsufficientReserve();

        // Execute deposit via adapter
        uint256 shares = protocols[protocolId].adapter.deposit{value: amount}();

        // Track position
        positions[protocolId].depositedEth += amount;
        positions[protocolId].shares += shares;

        emit Deposited(protocolId, amount, shares);
    }

    /// @notice Withdraw ETH from a protocol position. Only callable by the fund.
    /// @param protocolId The protocol to withdraw from.
    /// @param amount ETH-equivalent amount to withdraw. Converted to shares proportionally.
    function withdraw(uint256 protocolId, uint256 amount) external override onlyFund {
        if (amount == 0) revert ZeroAmount();
        if (!protocols[protocolId].exists) revert InvalidProtocol();

        Position storage pos = positions[protocolId];
        if (pos.shares == 0) revert WithdrawFailed();

        // Convert ETH amount to shares proportionally
        uint256 currentValue = protocols[protocolId].adapter.balance();
        if (currentValue == 0) revert WithdrawFailed();

        uint256 sharesToWithdraw;
        if (amount >= currentValue) {
            // Withdraw everything
            sharesToWithdraw = pos.shares;
        } else {
            sharesToWithdraw = (pos.shares * amount) / currentValue;
            if (sharesToWithdraw == 0) sharesToWithdraw = 1; // withdraw at least 1 share
        }

        // Execute withdrawal via adapter
        uint256 ethReturned = protocols[protocolId].adapter.withdraw(sharesToWithdraw);

        // Update position tracking
        if (sharesToWithdraw >= pos.shares) {
            pos.shares = 0;
            pos.depositedEth = 0;
        } else {
            pos.shares -= sharesToWithdraw;
            // Proportionally reduce deposited tracking
            uint256 depositedReduction = (pos.depositedEth * sharesToWithdraw) / (pos.shares + sharesToWithdraw);
            pos.depositedEth = pos.depositedEth > depositedReduction ? pos.depositedEth - depositedReduction : 0;
        }

        // Send ETH back to the fund
        (bool sent, ) = fund.call{value: ethReturned}("");
        if (!sent) revert TransferFailed();

        emit Withdrawn(protocolId, sharesToWithdraw, ethReturned);
    }

    /// @notice Withdraw all positions across all protocols and send ETH to recipient.
    /// @dev Only callable by the fund contract. Skips protocols with no shares.
    function withdrawAll(address recipient) external override onlyFund {
        for (uint256 i = 1; i <= protocolCount; i++) {
            Position storage pos = positions[i];
            if (pos.shares == 0 || !protocols[i].exists) continue;

            uint256 shares = pos.shares;
            try protocols[i].adapter.withdraw(shares) returns (uint256 ethReturned) {
                pos.shares = 0;
                pos.depositedEth = 0;
                emit Withdrawn(i, shares, ethReturned);
            } catch {
                // Skip failed adapter — partial withdrawal better than total failure
            }
        }

        // Send all recovered ETH to recipient in a single transfer
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool sent, ) = recipient.call{value: bal}("");
            if (!sent) revert TransferFailed();
        }
    }

    // ─── Views ───────────────────────────────────────────────────────────

    /// @notice Total value of all invested positions in ETH terms.
    function totalInvestedValue() public view override returns (uint256 total) {
        for (uint256 i = 1; i <= protocolCount; i++) {
            if (positions[i].shares > 0 && protocols[i].exists) {
                total += protocols[i].adapter.balance();
            }
        }
    }

    /// @notice Deterministic hash of all investment state.
    /// @dev Included in TheHumanFund's _computeInputHash() for TEE attestation binding.
    function stateHash() external view override returns (bytes32) {
        bytes memory packed;
        for (uint256 i = 1; i <= protocolCount; i++) {
            Position storage pos = positions[i];
            uint256 currentValue = (pos.shares > 0 && protocols[i].exists)
                ? protocols[i].adapter.balance()
                : 0;
            packed = abi.encodePacked(
                packed,
                i,
                pos.depositedEth,
                pos.shares,
                currentValue
            );
        }
        return keccak256(abi.encodePacked(packed, protocolCount, totalInvestedValue()));
    }

    /// @notice Get position details for a protocol.
    function getPosition(uint256 protocolId) external view returns (
        uint256 depositedEth,
        uint256 shares,
        uint256 currentValue,
        string memory protocolName,
        uint8 riskTier,
        uint16 expectedApyBps,
        bool active
    ) {
        Position storage pos = positions[protocolId];
        ProtocolInfo storage proto = protocols[protocolId];
        depositedEth = pos.depositedEth;
        shares = pos.shares;
        currentValue = (pos.shares > 0 && proto.exists) ? proto.adapter.balance() : 0;
        protocolName = proto.name;
        riskTier = proto.riskTier;
        expectedApyBps = proto.expectedApyBps;
        active = proto.active;
    }

    /// @notice Get protocol info.
    function getProtocol(uint256 protocolId) external view returns (
        address adapter,
        string memory _name,
        uint8 riskTier,
        uint16 expectedApyBps,
        bool active,
        bool exists
    ) {
        ProtocolInfo storage proto = protocols[protocolId];
        return (address(proto.adapter), proto.name, proto.riskTier, proto.expectedApyBps, proto.active, proto.exists);
    }

    // ─── Receive ETH ─────────────────────────────────────────────────────

    /// @dev Accept ETH from adapters during withdrawals.
    receive() external payable {}
}
