// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/InvestmentManager.sol";
import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
import "../src/interfaces/IProtocolAdapter.sol";
import "./helpers/EpochTest.sol";

/// @notice Mock adapter that simulates a DeFi protocol with configurable exchange rate.
contract MockAdapter is IProtocolAdapter {
    uint256 public totalDeposited;
    uint256 public totalShares;
    uint256 public exchangeRateBps = 10000; // 100% = 1:1, 11000 = 110% (10% gain)

    constructor(string memory) {
    }

    function deposit() external payable override returns (uint256 shares) {
        shares = msg.value; // 1:1 for simplicity
        totalDeposited += msg.value;
        totalShares += shares;
    }

    function withdraw(uint256 shares) external override returns (uint256 ethAmount) {
        require(shares <= totalShares, "insufficient shares");
        // Apply exchange rate to simulate gains/losses
        ethAmount = (shares * exchangeRateBps) / 10000;
        if (ethAmount > address(this).balance) ethAmount = address(this).balance;
        totalShares -= shares;
        totalDeposited = totalDeposited > ethAmount ? totalDeposited - ethAmount : 0;
        (bool sent, ) = msg.sender.call{value: ethAmount}("");
        require(sent, "transfer failed");
    }

    function balance() external view override returns (uint256) {
        return (totalShares * exchangeRateBps) / 10000;
    }

    function name() external pure override returns (string memory) {
        return "Mock Adapter";
    }

    /// @notice Simulate gains (exchange rate increase)
    function setExchangeRate(uint256 bps) external {
        exchangeRateBps = bps;
    }

    /// @notice Fund the adapter to simulate protocol having ETH for withdrawals
    receive() external payable {}
}

contract InvestmentManagerTest is EpochTest {
    TheHumanFund fund;
    InvestmentManager im;
    MockAdapter adapterA;
    MockAdapter adapterB;
    MockAdapter adapterC;

    address owner = address(this);
    address admin = address(0xAD);

    function setUp() public {
        // Deploy fund with 10 ETH
        fund = new TheHumanFund{value: 10 ether}(
            1000, 0.0001 ether,
            address(0xBEEF), address(0)
        );

        fund.addNonprofit("NP1", "Nonprofit 1", bytes32("EIN-1"));
        fund.addNonprofit("NP2", "Nonprofit 2", bytes32("EIN-2"));
        fund.addNonprofit("NP3", "Nonprofit 3", bytes32("EIN-3"));

        // Deploy InvestmentManager
        im = new InvestmentManager(address(fund), admin);

        // Link fund -> IM
        fund.setInvestmentManager(address(im));

        // Deploy AuctionManager so syncPhase() works
        AuctionManager _am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(_am), 1200, 1200, 82800);

        // Deploy mock adapters
        adapterA = new MockAdapter("Aave Mock");
        adapterB = new MockAdapter("Lido Mock");
        adapterC = new MockAdapter("Compound Mock");

        // Register protocols (as admin)
        vm.startPrank(admin);
        im.addProtocol(address(adapterA), "Aave V3 WETH", "Lend ETH on Aave", 1, 500);   // protocol 1
        im.addProtocol(address(adapterB), "Lido wstETH", "Stake ETH via Lido", 2, 380);     // protocol 2
        im.addProtocol(address(adapterC), "Compound V3 USDC", "Lend USDC on Compound", 1, 450); // protocol 3
        vm.stopPrank();
        _registerMockVerifier(fund);
    }

    // ─── Protocol Registry ───────────────────────────────────────────────

    function test_protocolCount() public view {
        assertEq(im.protocolCount(), 3);
    }

    function test_getProtocol() public view {
        (address adapter, string memory n, uint8 risk, uint16 apy, bool active, bool exists) = im.getProtocol(1);
        assertEq(adapter, address(adapterA));
        assertEq(n, "Aave V3 WETH");
        assertEq(risk, 1);
        assertEq(apy, 500);
        assertTrue(active);
        assertTrue(exists);
    }

    function test_onlyAdminCanAddProtocol() public {
        vm.expectRevert(InvestmentManager.Unauthorized.selector);
        im.addProtocol(address(adapterA), "Test", "Test protocol", 1, 100);
    }

    function test_pauseProtocol() public {
        vm.prank(admin);
        im.setProtocolActive(1, false);

        (, , , , bool active, ) = im.getProtocol(1);
        assertFalse(active);
    }

    // ─── Deposit ─────────────────────────────────────────────────────────

    function test_deposit() public {
        // Fund submits an invest action (action type 4)
        bytes memory action = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(1 ether)));
        speedrunEpoch(fund, action, "test invest");

        // Check position
        (uint256 deposited, uint256 shares, uint256 value, , , , ) = im.getPosition(1);
        assertEq(deposited, 1 ether);
        assertEq(shares, 1 ether);
        assertEq(value, 1 ether);
    }

    function test_depositMultipleProtocols() public {
        // Invest in protocol 1
        bytes memory action1 = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(1 ether)));
        speedrunEpoch(fund, action1, "invest 1");

        // Invest in protocol 2
        bytes memory action2 = abi.encodePacked(uint8(3), abi.encode(uint256(2), uint256(0.5 ether)));
        speedrunEpoch(fund, action2, "invest 2");

        assertEq(im.totalInvestedValue(), 1.5 ether);
    }

    function test_depositExceedsMaxTotal() public {
        // Max total is 80%. Treasury is 10 ETH. Max invest = 8 ETH.
        // Try to invest 9 ETH — should fail silently (no-op via try/catch)
        bytes memory action = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(9 ether)));
        uint256 balBefore = address(fund).balance;
        speedrunEpoch(fund, action, "too much");

        // Fund balance should be unchanged (action was rejected) minus bounty
        assertEq(address(fund).balance, balBefore - 1); // -1 wei bounty
        assertEq(im.totalInvestedValue(), 0);
    }

    function test_depositExceedsMaxPerProtocol() public {
        // Max per protocol is 25%. Treasury is 10 ETH. Max per protocol = 2.5 ETH.
        // Try to invest 3 ETH in one protocol
        bytes memory action = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(3 ether)));
        uint256 balBefore = address(fund).balance;
        speedrunEpoch(fund, action, "too much per protocol");

        assertEq(address(fund).balance, balBefore - 1); // -1 wei bounty
    }

    function test_depositBreaksMinReserve() public {
        // Min reserve is 20%. If treasury is 10 ETH, min liquid = 2 ETH.
        // If we invest 2 ETH first (ok), then try another 7 ETH (would leave only 1 ETH)
        bytes memory action1 = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(2 ether)));
        speedrunEpoch(fund, action1, "invest ok");
        assertEq(im.totalInvestedValue(), 2 ether);

        // Now try 7 ETH more — total invested would be 9 ETH, fund has 1 ETH = 10% < 20%
        bytes memory action2 = abi.encodePacked(uint8(3), abi.encode(uint256(2), uint256(7 ether)));
        uint256 balBefore = address(fund).balance;
        speedrunEpoch(fund, action2, "breaks reserve");
        assertEq(address(fund).balance, balBefore - 1); // -1 wei bounty
    }

    function test_depositToInvalidProtocol() public {
        bytes memory action = abi.encodePacked(uint8(3), abi.encode(uint256(99), uint256(1 ether)));
        uint256 balBefore = address(fund).balance;
        speedrunEpoch(fund, action, "bad protocol");
        assertEq(address(fund).balance, balBefore - 1); // -1 wei bounty
    }

    function test_depositToPausedProtocol() public {
        vm.prank(admin);
        im.setProtocolActive(1, false);

        bytes memory action = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(1 ether)));
        uint256 balBefore = address(fund).balance;
        speedrunEpoch(fund, action, "paused protocol");
        assertEq(address(fund).balance, balBefore - 1); // -1 wei bounty
    }

    // ─── Withdraw ────────────────────────────────────────────────────────

    function test_withdraw() public {
        // Invest first
        bytes memory invest = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(2 ether)));
        speedrunEpoch(fund, invest, "invest");
        assertEq(im.totalInvestedValue(), 2 ether);

        // Fund the adapter so it can pay out
        vm.deal(address(adapterA), 2 ether);

        // Withdraw
        uint256 balBefore = address(fund).balance;
        bytes memory withdraw_ = abi.encodePacked(uint8(4), abi.encode(uint256(1), uint256(1 ether)));
        speedrunEpoch(fund, withdraw_, "withdraw");

        // Fund balance should increase by ~1 ETH
        assertGt(address(fund).balance, balBefore);
        assertLt(im.totalInvestedValue(), 2 ether);
    }

    function test_withdrawAll() public {
        bytes memory invest = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(2 ether)));
        speedrunEpoch(fund, invest, "invest");

        vm.deal(address(adapterA), 2 ether);

        // Withdraw more than balance — should withdraw everything
        bytes memory withdraw_ = abi.encodePacked(uint8(4), abi.encode(uint256(1), uint256(10 ether)));
        speedrunEpoch(fund, withdraw_, "withdraw all");

        (uint256 deposited, uint256 shares, , , , , ) = im.getPosition(1);
        assertEq(shares, 0);
        assertEq(deposited, 0);
    }

    function test_withdrawFromEmptyPosition() public {
        // Try to withdraw when nothing invested — should be a no-op
        bytes memory action = abi.encodePacked(uint8(4), abi.encode(uint256(1), uint256(1 ether)));
        uint256 balBefore = address(fund).balance;
        speedrunEpoch(fund, action, "withdraw empty");
        assertEq(address(fund).balance, balBefore - 1); // -1 wei bounty
    }

    function test_withdrawFromPausedProtocolStillWorks() public {
        // Invest
        bytes memory invest = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(1 ether)));
        speedrunEpoch(fund, invest, "invest");

        // Pause protocol
        vm.prank(admin);
        im.setProtocolActive(1, false);

        // Fund adapter
        vm.deal(address(adapterA), 1 ether);

        // Withdraw should still work even though protocol is paused
        bytes memory withdraw_ = abi.encodePacked(uint8(4), abi.encode(uint256(1), uint256(1 ether)));
        uint256 balBefore = address(fund).balance;
        speedrunEpoch(fund, withdraw_, "withdraw from paused");
        assertGt(address(fund).balance, balBefore);
    }

    // ─── Gains/Losses ────────────────────────────────────────────────────

    function test_valueWithGains() public {
        bytes memory invest = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(2 ether)));
        speedrunEpoch(fund, invest, "invest");

        // Simulate 10% gain
        adapterA.setExchangeRate(11000);

        (uint256 deposited, , uint256 value, , , , ) = im.getPosition(1);
        assertEq(deposited, 2 ether);
        assertEq(value, 2.2 ether); // 10% gain
    }

    function test_valueWithLoss() public {
        bytes memory invest = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(2 ether)));
        speedrunEpoch(fund, invest, "invest");

        // Simulate 20% loss
        adapterA.setExchangeRate(8000);

        (, , uint256 value, , , , ) = im.getPosition(1);
        assertEq(value, 1.6 ether);
    }

    // ─── State Hash ──────────────────────────────────────────────────────

    function test_stateHashDeterministic() public {
        bytes memory invest = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(1 ether)));
        speedrunEpoch(fund, invest, "invest");

        bytes32 hash1 = im.stateHash();
        bytes32 hash2 = im.stateHash();
        assertEq(hash1, hash2);
    }

    function test_stateHashChangesOnDeposit() public {
        bytes32 hashBefore = im.stateHash();

        bytes memory invest = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(1 ether)));
        speedrunEpoch(fund, invest, "invest");

        bytes32 hashAfter = im.stateHash();
        assertTrue(hashBefore != hashAfter);
    }

    // ─── Total Assets ────────────────────────────────────────────────────

    function test_totalAssets() public {
        assertEq(fund.totalAssets(), 10 ether);

        bytes memory invest = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(2 ether)));
        speedrunEpoch(fund, invest, "invest");

        // Total assets should still be ~10 ETH (8 liquid + 2 invested) minus bounty
        assertEq(fund.totalAssets(), 10 ether - 1); // -1 wei bounty
    }

    // ─── No InvestmentManager ────────────────────────────────────────────

    function test_investWithNoManagerIsNoop() public {
        // Deploy a fresh fund without InvestmentManager
        TheHumanFund fund2 = new TheHumanFund{value: 1 ether}(
            1000, 0.0001 ether,
            address(0xBEEF), address(0)
        );
        AuctionManager am2 = new AuctionManager(address(fund2));
        fund2.setAuctionManager(address(am2), 1200, 1200, 82800);
        _registerMockVerifier(fund2);

        bytes memory action = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(0.1 ether)));
        uint256 balBefore = address(fund2).balance;
        speedrunEpoch(fund2, action, "invest without IM");
        assertEq(address(fund2).balance, balBefore - 1); // no-op, -1 wei bounty
    }

    // ─── Bounds Management ───────────────────────────────────────────────

    function test_setBounds() public {
        vm.prank(admin);
        im.setBounds(7000, 3000, 3000);
        assertEq(im.maxTotalBps(), 7000);
        assertEq(im.maxPerProtocolBps(), 3000);
        assertEq(im.minReserveBps(), 3000);
    }

    function test_setBoundsOnlyAdmin() public {
        vm.expectRevert(InvestmentManager.Unauthorized.selector);
        im.setBounds(7000, 3000, 3000);
    }

    // ─── Only Fund Can Deposit/Withdraw ──────────────────────────────────

    function test_onlyFundCanDeposit() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(InvestmentManager.Unauthorized.selector);
        im.deposit{value: 1 ether}(1, 1 ether);
    }

    function test_onlyFundCanWithdraw() public {
        vm.expectRevert(InvestmentManager.Unauthorized.selector);
        im.withdraw(1, 1 ether);
    }

    // Accept ETH (owner is this test contract, needed for withdrawAll)
    receive() external payable {}

    // ─── WithdrawAll ──────────────────────────────────────────────────────

    function test_withdrawAll_basic() public {
        // Invest in two protocols
        bytes memory action1 = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(2 ether)));
        speedrunEpoch(fund, action1, "invest 1");
        bytes memory action2 = abi.encodePacked(uint8(3), abi.encode(uint256(2), uint256(1 ether)));
        speedrunEpoch(fund, action2, "invest 2");

        assertEq(im.totalInvestedValue(), 3 ether);

        // Fund adapters so they can pay out
        vm.deal(address(adapterA), 2 ether);
        vm.deal(address(adapterB), 1 ether);

        uint256 ownerBalBefore = address(owner).balance;
        fund.withdrawAll();

        // All positions should be zeroed
        (uint256 dep1, uint256 sh1, , , , , ) = im.getPosition(1);
        (uint256 dep2, uint256 sh2, , , , , ) = im.getPosition(2);
        assertEq(sh1, 0);
        assertEq(dep1, 0);
        assertEq(sh2, 0);
        assertEq(dep2, 0);
        assertEq(im.totalInvestedValue(), 0);

        // Owner should have received everything (invested ETH + liquid treasury)
        assertGt(address(owner).balance, ownerBalBefore);
        assertEq(address(fund).balance, 0);
    }

    function test_withdrawAll_noInvestments() public {
        // withdrawAll with no investments should still send liquid balance to owner
        uint256 ownerBalBefore = address(owner).balance;
        uint256 fundBal = address(fund).balance;
        assertGt(fundBal, 0);

        fund.withdrawAll();

        assertEq(address(fund).balance, 0);
        assertEq(address(owner).balance, ownerBalBefore + fundBal);
    }

    function test_withdrawAll_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.withdrawAll();
    }

    function test_withdrawAll_withGains() public {
        // Invest 2 ETH
        bytes memory action = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(2 ether)));
        speedrunEpoch(fund, action, "invest");

        // Simulate 50% gain
        adapterA.setExchangeRate(15000);
        vm.deal(address(adapterA), 3 ether); // fund adapter with enough to pay out gains

        uint256 ownerBalBefore = address(owner).balance;
        fund.withdrawAll();

        // Owner gets: 3 ETH from investment (2 * 1.5) + 8 ETH liquid - 1 wei bounty
        uint256 received = address(owner).balance - ownerBalBefore;
        assertEq(received, 11 ether - 1); // -1 wei bounty
    }

    function test_withdrawAll_skipsEmptyProtocols() public {
        // Only invest in protocol 1, leave 2 and 3 empty
        bytes memory action = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(1 ether)));
        speedrunEpoch(fund, action, "invest");
        vm.deal(address(adapterA), 1 ether);

        // Should succeed without reverting on empty protocols
        fund.withdrawAll();
        assertEq(address(fund).balance, 0);
        assertEq(im.totalInvestedValue(), 0);
    }

    // ─── Kill Switches ────────────────────────────────────────────────────

    function test_freezeInvestments() public {
        vm.prank(admin);
        im.freezeInvestments();
        assertTrue(im.frozenInvestments());

        vm.startPrank(admin);
        vm.expectRevert(InvestmentManager.Frozen.selector);
        im.addProtocol(address(adapterA), "New", "New protocol", 1, 100);

        vm.expectRevert(InvestmentManager.Frozen.selector);
        im.setProtocolActive(1, false);

        vm.expectRevert(InvestmentManager.Frozen.selector);
        im.setBounds(7000, 3000, 3000);
        vm.stopPrank();
    }

    function test_freezeInvestments_onlyAdmin() public {
        vm.expectRevert(InvestmentManager.Unauthorized.selector);
        im.freezeInvestments();
    }

    function test_freezeInvestments_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit InvestmentManager.PermissionFrozen("investments");
        im.freezeInvestments();
    }

    function test_freezeAdmin() public {
        vm.prank(admin);
        im.freezeAdmin();
        assertTrue(im.frozenAdmin());

        vm.prank(admin);
        vm.expectRevert(InvestmentManager.Frozen.selector);
        im.setAdmin(address(0x1234));
    }

    function test_freezeAdmin_onlyAdmin() public {
        vm.expectRevert(InvestmentManager.Unauthorized.selector);
        im.freezeAdmin();
    }

    // ─── Fuzz Tests ────────────────────────────────────────────────────

    function testFuzz_invest_boundsInvariant(uint256 amount) public {
        // Fund has 10 ETH. Max total 80% = 8 ETH, max per protocol 25% = 2.5 ETH
        amount = bound(amount, 0.01 ether, 10 ether);

        uint256 totalAssets = address(fund).balance + im.totalInvestedValue();
        uint256 maxTotal = (totalAssets * 8000) / 10000;
        uint256 maxPerProtocol = (totalAssets * 2500) / 10000;
        uint256 minReserve = (totalAssets * 2000) / 10000;

        bytes memory action = abi.encodePacked(uint8(3), abi.encode(uint256(1), amount));
        speedrunEpoch(fund, action, bytes("invest fuzz"));

        // After action, check invariants
        uint256 invested = im.totalInvestedValue();
        uint256 liquid = address(fund).balance;
        uint256 newTotal = liquid + invested;

        if (invested > 0) {
            // If deposit succeeded, all bounds must hold
            assertLe(invested, (newTotal * 8000) / 10000 + 1); // +1 for rounding
        }
        // If deposit failed (ActionRejected), invested == 0, which is fine
    }

    function testFuzz_invest_multipleProtocols_boundsHold(uint256 a1, uint256 a2, uint256 a3) public {
        a1 = bound(a1, 0.1 ether, 2 ether);
        a2 = bound(a2, 0.1 ether, 2 ether);
        a3 = bound(a3, 0.1 ether, 2 ether);

        // Invest in protocol 1
        bytes memory action1 = abi.encodePacked(uint8(3), abi.encode(uint256(1), a1));
        speedrunEpoch(fund, action1, bytes("invest 1"));

        // Invest in protocol 2
        bytes memory action2 = abi.encodePacked(uint8(3), abi.encode(uint256(2), a2));
        speedrunEpoch(fund, action2, bytes("invest 2"));

        // Invest in protocol 3
        bytes memory action3 = abi.encodePacked(uint8(3), abi.encode(uint256(3), a3));
        speedrunEpoch(fund, action3, bytes("invest 3"));

        // After all investments, min reserve must hold
        uint256 liquid = address(fund).balance;
        uint256 total = liquid + im.totalInvestedValue();
        // Liquid balance should be at least 20% of total (may be more if some invests were rejected)
        assertGe(liquid * 10000, total * 2000 - 1); // -1 for rounding
    }
}
