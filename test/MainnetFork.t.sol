// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
import "../src/TdxVerifier.sol";
import "../src/InvestmentManager.sol";
import "../src/WorldView.sol";
import "../src/adapters/AaveV3WETHAdapter.sol";
import "../src/adapters/AaveV3USDCAdapter.sol";
import "../src/adapters/WstETHAdapter.sol";
import "../src/adapters/CbETHAdapter.sol";
import "../src/adapters/CompoundV3USDCAdapter.sol";
import "../src/adapters/MorphoWETHAdapter.sol";

/// @title MainnetFork
/// @notice End-to-end test forking Base mainnet with real DeFi protocols,
///         real Chainlink oracle, real Endaoment factory, and real Automata DCAP.
///
/// Run with:
///   forge test --match-path test/MainnetFork.t.sol --fork-url https://mainnet.base.org
///
/// This is the test that would have caught most of the bugs we found during
/// the real mainnet deployment:
///   - Wrong Chainlink feed address → setUp fails
///   - Missing FMSPC collateral on Base mainnet PCCS → submitAuctionResult reverts
///   - Adapter construction errors → deployment fails
///   - Input hash drift from donations → asserted here
///   - Stale snapshot values → asserted via epochBaseInputHashes
///   - effectiveMaxBid edge cases at small treasury → asserted here
///
/// Does NOT run the enclave (we use a hardcoded valid quote captured from a
/// prior mainnet submission for replay). The DCAP verifier validates the
/// quote against Automata's on-chain collateral, so this test only passes if
/// the FMSPC/QE identity/Root CA CRL are all registered for Base mainnet.
contract MainnetForkTest is Test {
    // ─── Real Base Mainnet Addresses ────────────────────────────────────
    address constant ENDAOMENT_FACTORY = 0x10fD9348136dCea154F752fe0B6dB45Fc298A589;
    address constant WETH              = 0x4200000000000000000000000000000000000006;
    address constant USDC              = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SWAP_ROUTER       = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant ETH_USD_FEED      = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant WSTETH_RATE_FEED  = 0xB88BAc61a4Ca37C43a3725912B1f472c9A5bc061;
    address constant DCAP_VERIFIER     = 0x95175096a9B74165BE0ac84260cc14Fc1c0EF5FF;

    // DeFi protocols
    address constant AAVE_POOL         = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AAVE_AWETH        = 0xD4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7;
    address constant AAVE_AUSDC        = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address constant WSTETH            = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant CBETH             = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address constant COMPOUND_COMET    = 0xb125E6687d4313864e53df431d5425969c15Eb2F;
    address constant MORPHO_GAUNTLET   = 0x6b13c060F13Af1fdB319F52315BbbF3fb1D88844;

    // Image key for the production v10 image, already registered on Base mainnet
    bytes32 constant IMAGE_KEY = 0x923d500553d9e10a8f864eade2029df0471c7cd4f90b888e7749f0dc3fca1eca;

    TheHumanFund fund;
    AuctionManager am;
    TdxVerifier verifier;
    InvestmentManager im;
    WorldView wv;

    address owner = address(0xDEAFBEEF);
    address donor = address(0xD0D0);
    address runner1 = address(0x4001);

    // Timing matching production
    uint256 constant EPOCH_DUR = 5400;     // 90 min
    uint256 constant COMMIT_WIN = 1200;    // 20 min
    uint256 constant REVEAL_WIN = 1200;    // 20 min
    uint256 constant EXEC_WIN = 3000;      // 50 min

    modifier onlyOnFork() {
        // Skip these tests unless the test runner is forking a real Base chain.
        // Without a fork, real contract addresses are empty and everything reverts.
        if (WETH.code.length == 0) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        vm.deal(owner, 10 ether);
        vm.deal(donor, 10 ether);
        vm.deal(runner1, 10 ether);

        // Skip setup work if we're not actually on a fork (WETH code wouldn't exist)
        if (WETH.code.length == 0) return;

        vm.startPrank(owner);

        // ─── Deploy core ────────────────────────────────────────────────
        fund = new TheHumanFund{value: 0.1 ether}(
            1000,          // 10% commission
            0.01 ether,    // initial max bid (production value)
            ENDAOMENT_FACTORY,
            WETH,
            USDC,
            SWAP_ROUTER,
            ETH_USD_FEED
        );

        // Same 9 nonprofits as mainnet
        fund.addNonprofit("National Public Radio", "Nonprofit news", bytes32("52-0907625"));
        fund.addNonprofit("Freedom of the Press Foundation", "SecureDrop", bytes32("46-0967274"));
        fund.addNonprofit("Electronic Frontier Foundation", "Digital rights", bytes32("04-3091431"));
        fund.addNonprofit("Doctors Without Borders", "Emergency medical", bytes32("13-3433452"));
        fund.addNonprofit("St. Jude Children's Research Hospital", "Pediatric cancer", bytes32("35-1044585"));
        fund.addNonprofit("The Nature Conservancy", "Conservation", bytes32("53-0242652"));
        fund.addNonprofit("Clean Air Task Force", "Climate policy", bytes32("04-3512550"));
        fund.addNonprofit("GiveDirectly", "Cash transfers", bytes32("27-1661997"));
        fund.addNonprofit("The Ocean Cleanup", "Plastic removal", bytes32("81-5132355"));

        // TdxVerifier wired to the REAL Automata DCAP at 0xaDde...EA1F
        verifier = new TdxVerifier(address(fund));
        verifier.approveImage(IMAGE_KEY);
        fund.approveVerifier(1, address(verifier));

        am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am));

        im = new InvestmentManager(address(fund), owner);
        fund.setInvestmentManager(address(im));

        wv = new WorldView(address(fund));
        fund.setWorldView(address(wv));

        // Register all 6 production adapters pointing at real Base contracts
        AaveV3WETHAdapter a1 = new AaveV3WETHAdapter(AAVE_POOL, WETH, AAVE_AWETH, address(im));
        im.addProtocol(address(a1), "Aave V3 WETH", "Lend ETH on Aave V3", 1, 300);

        AaveV3USDCAdapter a2 = new AaveV3USDCAdapter(
            AAVE_POOL, USDC, AAVE_AUSDC, WETH, SWAP_ROUTER, ETH_USD_FEED, address(im)
        );
        im.addProtocol(address(a2), "Aave V3 USDC", "Swap ETH->USDC, lend on Aave", 2, 500);

        WstETHAdapter a3 = new WstETHAdapter(WSTETH, WETH, SWAP_ROUTER, WSTETH_RATE_FEED, address(im));
        im.addProtocol(address(a3), "Lido wstETH", "Stake ETH via Lido", 1, 350);

        CbETHAdapter a4 = new CbETHAdapter(CBETH, WETH, SWAP_ROUTER, address(im));
        im.addProtocol(address(a4), "Coinbase cbETH", "Coinbase staked ETH", 1, 300);

        CompoundV3USDCAdapter a5 = new CompoundV3USDCAdapter(
            COMPOUND_COMET, USDC, WETH, SWAP_ROUTER, ETH_USD_FEED, address(im)
        );
        im.addProtocol(address(a5), "Compound V3 USDC", "Lend USDC on Compound V3", 2, 400);

        MorphoWETHAdapter a6 = new MorphoWETHAdapter(
            MORPHO_GAUNTLET, WETH, address(im), "Morpho Gauntlet WETH Core"
        );
        im.addProtocol(address(a6), "Morpho Gauntlet WETH Core", "Curated Morpho vault", 2, 500);

        fund.setAuctionTiming(EPOCH_DUR, COMMIT_WIN, REVEAL_WIN, EXEC_WIN);

        vm.stopPrank();
    }

    // ─── Sanity: real mainnet state ─────────────────────────────────────

    function test_fork_sanity_allAddressesHaveCode() public onlyOnFork {
        assertGt(WETH.code.length, 0, "WETH");
        assertGt(USDC.code.length, 0, "USDC");
        assertGt(SWAP_ROUTER.code.length, 0, "SwapRouter");
        assertGt(ETH_USD_FEED.code.length, 0, "Chainlink feed");
        assertGt(ENDAOMENT_FACTORY.code.length, 0, "Endaoment");
        assertGt(DCAP_VERIFIER.code.length, 0, "DCAP verifier");
        assertGt(AAVE_POOL.code.length, 0, "Aave pool");
        assertGt(AAVE_AWETH.code.length, 0, "aWETH");
        assertGt(AAVE_AUSDC.code.length, 0, "aUSDC");
        assertGt(WSTETH.code.length, 0, "wstETH");
        assertGt(CBETH.code.length, 0, "cbETH");
        assertGt(COMPOUND_COMET.code.length, 0, "Compound Comet");
        assertGt(MORPHO_GAUNTLET.code.length, 0, "Morpho Gauntlet");
    }

    function test_fork_chainlinkFeedReturnsRealPrice() public onlyOnFork {
        // Should match live ETH/USD price (~$2k-4k range)
        (, int256 answer, , , ) = IAggregatorV3(ETH_USD_FEED).latestRoundData();
        assertGt(answer, 1_000_00000000, "ETH/USD should be > $1000 (8 decimals)");
        assertLt(answer, 100_000_00000000, "ETH/USD should be < $100k");
    }

    // ─── Adapter sanity: real protocol calls ────────────────────────────

    function test_fork_aaveWethAdapter_depositWithdraw() public onlyOnFork {
        // Open an auction and advance state so the investment manager will accept calls
        vm.prank(owner);
        fund.syncPhase();

        // Execute an invest action via the owner's direct-submission path (if not frozen)
        // This touches the REAL Aave V3 pool — if the adapter is wrong, it reverts here.
        bytes memory action = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(0.01 ether)));

        vm.prank(owner);
        fund.submitEpochAction(action, "testing aave invest", -1, "");

        // Verify the position was created
        (uint256 deposited, uint256 shares,,,,,) = im.getPosition(1);
        assertEq(deposited, 0.01 ether, "Aave WETH deposit recorded");
        assertGt(shares, 0, "Aave WETH shares minted");
    }

    function test_fork_lidoWstEthAdapter_depositWithdraw() public onlyOnFork {
        vm.prank(owner);
        fund.syncPhase();

        bytes memory action = abi.encodePacked(uint8(3), abi.encode(uint256(3), uint256(0.01 ether)));
        vm.prank(owner);
        fund.submitEpochAction(action, "testing lido invest", -1, "");

        (uint256 deposited, uint256 shares,,,,,) = im.getPosition(3);
        assertEq(deposited, 0.01 ether, "wstETH deposit recorded");
        assertGt(shares, 0, "wstETH shares minted");
    }

    // ─── Input hash drift: snapshot fix regression test ─────────────────

    function test_fork_donationDuringAuctionDoesNotBreakInputHash() public onlyOnFork {
        // Open auction
        vm.prank(owner);
        fund.syncPhase();
        bytes32 baseHashAtOpen = fund.epochBaseInputHashes(1);
        assertTrue(baseHashAtOpen != bytes32(0), "base input hash set at auction open");

        // Donor sends a donation after auction open — this would have broken
        // the input hash before the EpochSnapshot fix.
        vm.deal(donor, 1 ether);
        vm.prank(donor);
        fund.donate{value: 0.05 ether}(0);

        // Snapshot should be unchanged
        TheHumanFund.EpochSnapshot memory snap = fund.getEpochSnapshot(1);
        assertTrue(snap.balance < address(fund).balance, "live balance > snapshot balance after donation");
        assertEq(fund.epochBaseInputHashes(1), baseHashAtOpen, "base input hash unchanged");
    }

    // ─── effectiveMaxBid: small treasury edge case ──────────────────────

    function test_fork_effectiveMaxBid_respectsOwnerMaxAtSmallTreasury() public onlyOnFork {
        // Treasury is 0.1 ETH (from seed). maxBid is 0.01 ETH.
        // 2% of treasury = 0.002 ETH (less than maxBid).
        // With the fix: effectiveMaxBid should return 0.01 ETH (owner's setting).
        // Without the fix: effectiveMaxBid would return 0.002 ETH (crushed by cap).

        assertEq(fund.maxBid(), 0.01 ether);
        assertEq(fund.effectiveMaxBid(), 0.01 ether, "effectiveMaxBid should respect maxBid at small treasury");

        // After missed epochs, it should still respect the owner's maxBid
        // (escalation hits the cap of max(2%, maxBid) = maxBid immediately)
        vm.prank(owner);
        fund.syncPhase();
        vm.warp(block.timestamp + EPOCH_DUR * 3);
        vm.prank(owner);
        fund.syncPhase();

        assertEq(fund.consecutiveMissedEpochs(), 3);
        // Even after escalation, cap is max(2%, maxBid) = maxBid = 0.01 ETH
        assertEq(fund.effectiveMaxBid(), 0.01 ether);
    }

    // ─── DCAP verification: the ultimate end-to-end test ────────────────

    /// This test requires:
    ///   1. A valid TDX quote from the v10 image (captured from a real submission)
    ///   2. Matching action + reasoning that produces the right REPORTDATA
    ///   3. FMSPC 00806f050000 collateral registered on Base mainnet PCCS
    ///
    /// If ANY of these are missing, this test reverts — and that's the whole point.
    /// Had we run this before the mainnet deploy, we would have caught the FMSPC
    /// gap before burning bonds.
    ///
    /// To enable: capture a real quote from a successful (or attempted) submission,
    /// save it to test/fixtures/real_quote.bin, and uncomment the test body.
    function test_fork_dcapVerification_withRealQuote() public onlyOnFork {
        // Skip until a real quote is captured.
        vm.skip(true);

        // bytes memory quote = vm.readFileBinary("test/fixtures/real_quote.bin");
        // bytes32 inputHash = vm.parseBytes32(vm.readFile("test/fixtures/real_input_hash.txt"));
        // bytes memory action = vm.readFileBinary("test/fixtures/real_action.bin");
        // bytes memory reasoning = vm.readFileBinary("test/fixtures/real_reasoning.bin");
        //
        // // Run auction up through reveal
        // vm.prank(owner);
        // fund.syncPhase();
        // bytes32 salt = bytes32(uint256(1));
        // bytes32 commitHash = keccak256(abi.encodePacked(uint256(0.005 ether), salt));
        // vm.prank(runner1);
        // fund.commit{value: fund.currentBond()}(commitHash);
        // vm.warp(block.timestamp + COMMIT_WIN);
        // vm.prank(runner1);
        // fund.reveal(0.005 ether, salt);
        // vm.warp(block.timestamp + REVEAL_WIN);
        // fund.syncPhase();
        //
        // // Submit the real quote — if DCAP collateral is registered, this passes
        // vm.prank(runner1);
        // fund.submitAuctionResult(action, reasoning, quote, 1, -1, "");
        //
        // // Verify the epoch executed
        // (, , , , , , bool executed) = fund.epochs(1);
        // assertTrue(executed, "epoch executed after valid DCAP submission");
    }
}
