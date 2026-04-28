// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
import "../src/InvestmentManager.sol";
import "../src/AgentMemory.sol";
import "../src/adapters/MockAdapter.sol";
import "./helpers/MockEndaoment.sol";
import "./helpers/EpochTest.sol";

/// @title CrossStackHashTest
/// @notice Verifies that the Solidity _computeInputHash() and the Python
///         compute_input_hash() produce identical results for the same state.
///         This is critical: if they diverge, TEE attestation will fail at runtime.
///         Uses vm.ffi() to call the Python implementation and compares outputs.
contract CrossStackHashTest is EpochTest {
    TheHumanFund public fund;
    MockEndaomentFactory public mockFactory;
    MockWETH public mockWeth;
    MockUSDC public mockUsdc;
    MockSwapRouter public mockRouter;
    MockChainlinkFeed public mockFeed;

    function setUp() public {
        mockWeth = new MockWETH();
        mockUsdc = new MockUSDC();
        mockRouter = new MockSwapRouter(address(mockWeth), address(mockUsdc));
        mockFactory = new MockEndaomentFactory();
        mockFeed = new MockChainlinkFeed(2000e8, 8); // $2000/ETH

        fund = new TheHumanFund{value: 5 ether}(
            1000,                       // 10% commission
            0.005 ether,                // initial max bid
            address(0xBEEF),            // donationExecutor (mock)
            address(mockFeed)
        );

        fund.addNonprofit("GiveDirectly", "Cash transfers to extreme poor", bytes32("EIN-GD"));
        fund.addNonprofit("Against Malaria Foundation", "Malaria prevention", bytes32("EIN-AMF"));
        fund.addNonprofit("Helen Keller International", "Neglected tropical diseases", bytes32("EIN-HKI"));

        mockFactory.preDeployOrg(bytes32("EIN-GD"));
        mockFactory.preDeployOrg(bytes32("EIN-AMF"));
        mockFactory.preDeployOrg(bytes32("EIN-HKI"));

        // Wire an AuctionManager so `syncPhase` can advance currentEpoch
        // across elapsed epochs — the multi-epoch test needs this.
        AuctionManager am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am), 1200, 1200, 82800);
        _registerMockVerifier(fund);
    }

    // Every cross-stack test freezes the snapshot via `syncPhase`
    // (which opens the auction and calls `_freezeEpochSnapshot`),
    // then compares the snapshot hash against Python's hash of the
    // JSON-serialized snapshot state.
    //
    // `_hashSnapshot` is `pure` — it reads only from the frozen
    // EpochSnapshot. For Solidity and Python to agree, we freeze with
    // live state == the desired test state, then read the frozen
    // snapshot on both sides.

    /// @notice Core cross-stack test: compare Solidity and Python hash outputs.
    function test_cross_stack_hash_matches_initial_state() public {
        // syncPhase opens epoch 1 auction, which freezes the snapshot.
        fund.syncPhase();
        _assertCrossStackMatch(1, "initial state");
    }

    /// @notice Test after a donation changes state — hashes should still match.
    function test_cross_stack_hash_after_donation() public {
        vm.deal(address(0xDEAD), 1 ether);
        vm.prank(address(0xDEAD));
        fund.donate{value: 0.5 ether}(0);
        // syncPhase opens epoch 1 auction, freezing the post-donation state.
        fund.syncPhase();
        _assertCrossStackMatch(1, "after donation");
    }

    /// @notice Test after epoch execution — content hashes and epoch state change.
    function test_cross_stack_hash_after_epoch() public {
        // Execute epoch 1 via the real auction path (freezes + executes).
        bytes memory doNothingAction = abi.encodePacked(uint8(0));
        speedrunEpoch(fund, doNothingAction, "epoch 1");

        // speedrunEpoch left us at epoch 2 with an open auction (snapshot
        // frozen for epoch 2, whose history-hash rolls in epoch 1's
        // content hash).
        _assertCrossStackMatch(2, "after epoch");
    }

    /// @notice Test with messages in the queue.
    function test_cross_stack_hash_with_messages() public {
        vm.deal(address(0xBEEF), 1 ether);
        vm.prank(address(0xBEEF));
        fund.donateWithMessage{value: 0.1 ether}(0, "Hello from a donor!");
        // syncPhase opens epoch 1 auction, freezing the post-message state.
        fund.syncPhase();
        _assertCrossStackMatch(1, "with messages");
    }

    /// @notice Test with populated investment positions — exercises _hash_investments cross-stack.
    function test_cross_stack_hash_with_investments() public {
        // Wire up InvestmentManager with two mock protocols
        InvestmentManager im = new InvestmentManager(address(fund), address(this));
        fund.setInvestmentManager(address(im));

        MockAdapter adapterA = new MockAdapter("Aave V3 WETH", address(im));
        MockAdapter adapterB = new MockAdapter("Lido wstETH", address(im));

        im.addProtocol(address(adapterA), "Aave V3 WETH", "Lend ETH on Aave", 1, 500);
        im.addProtocol(address(adapterB), "Lido wstETH", "Stake ETH via Lido", 2, 380);

        // Deposit into protocol 1 via an epoch action (invest 0.1 ETH)
        bytes memory investAction1 = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(0.1 ether)));
        speedrunEpoch(fund, investAction1, "invest into aave");

        // Deposit into protocol 2 via another epoch (invest 0.2 ETH)
        bytes memory investAction2 = abi.encodePacked(uint8(3), abi.encode(uint256(2), uint256(0.2 ether)));
        speedrunEpoch(fund, investAction2, "invest into lido");

        // Now epoch 3 is open with a snapshot that includes both positions.
        _assertCrossStackMatch(3, "with investments");
    }

    /// @notice Test with populated memory entries — exercises _hashMemory cross-stack.
    function test_cross_stack_hash_with_memory() public {
        // Wire up AgentMemory
        AgentMemory wv = new AgentMemory(address(fund));
        fund.setAgentMemory(address(wv));

        // Set memory entries via epoch actions (memory updates are sidecars on submitAuctionResult)
        bytes memory doNothingAction = abi.encodePacked(uint8(0));
        speedrunEpoch(fund, doNothingAction, "set entry 1",
            uint8(1), "Mood", "Cautious. Preserve capital above all.");
        speedrunEpoch(fund, doNothingAction, "set entry 3",
            uint8(3), "Outlook", "Hopeful. The drought is ending.");
        speedrunEpoch(fund, doNothingAction, "set entry 7",
            uint8(7), "Stance", "Generous. Give freely when the treasury is healthy.");

        // Now epoch 4 is open with a snapshot that includes memory hash.
        _assertCrossStackMatch(4, "with memory");
    }

    /// @notice Exercises the title+body memory layout end-to-end — mixed
    ///         empty / title-only / full / long-title slots to catch any
    ///         padding or truncation drift between Solidity and Python.
    function test_cross_stack_hash_with_titles() public {
        AgentMemory wv = new AgentMemory(address(fund));
        fund.setAgentMemory(address(wv));

        bytes memory doNothingAction = abi.encodePacked(uint8(0));

        // Batch update via multi-slot sidecar — 3 memory slots with varied shapes.
        IAgentMemory.MemoryUpdate[] memory updates = new IAgentMemory.MemoryUpdate[](3);
        updates[0] = IAgentMemory.MemoryUpdate({
            slot: 0,
            title: "Voice",
            body: "I speak plainly."
        });
        updates[1] = IAgentMemory.MemoryUpdate({
            slot: 4,
            title: "Donor grudges",
            // Avoid apostrophes: the FFI harness wraps stdin JSON in single
            // quotes, so a stray apostrophe in the body breaks shell parsing.
            body: "Still thinking about 0xab12 and the hospice question."
        });
        updates[2] = IAgentMemory.MemoryUpdate({
            slot: 9,
            title: "Risk cap",
            body: ""  // title-only
        });
        speedrunEpoch(fund, doNothingAction, "seed titles", updates);

        _assertCrossStackMatch(2, "with titles (multi-update)");
    }

    /// @notice Test with both investments AND memory populated.
    function test_cross_stack_hash_with_investments_and_memory() public {
        // Wire up InvestmentManager
        InvestmentManager im = new InvestmentManager(address(fund), address(this));
        fund.setInvestmentManager(address(im));
        MockAdapter adapter = new MockAdapter("Compound V3 USDC", address(im));
        im.addProtocol(address(adapter), "Compound V3 USDC", "Lend USDC on Compound", 1, 450);

        // Wire up AgentMemory
        AgentMemory wv = new AgentMemory(address(fund));
        fund.setAgentMemory(address(wv));

        // Invest + set memory in one epoch
        bytes memory investAction = abi.encodePacked(uint8(3), abi.encode(uint256(1), uint256(0.05 ether)));
        speedrunEpoch(fund, investAction, "invest and set memory",
            uint8(2), "Stance", "Balanced. Diversify across protocols.");

        // Epoch 2 is open with both populated.
        _assertCrossStackMatch(2, "with investments and memory");
    }

    function _assertCrossStackMatch(uint256 epoch, string memory label) internal {
        bytes32 solidityHash = fund.computeInputHashForEpoch(epoch);
        string memory stateJson = _buildStateJson(epoch);
        bytes32 pythonHash = _callPythonHash(stateJson);
        assertEq(solidityHash, pythonHash,
            string.concat("Solidity/Python hashes must match: ", label));
    }

    // ─── Output-hash parity ───────────────────────────────────────────────
    //
    // Solidity computes outputHash inline in submitAuctionResult and exposes
    // the same logic via TheHumanFund.computeOutputHash. Python computes the
    // same value via prover/enclave/attestation.compute_report_data — but
    // its return is REPORTDATA = sha256(inputHash || outputHash), so for
    // parity we use the dedicated scripts/compute_output_hash.py helper that
    // exposes only the outputHash term.
    //
    // If these diverge: live submissions revert (DCAP REPORTDATA mismatch).
    // The asymmetry caught the v20 memory gap before deploy: Solidity
    // bound `updates` into outputHash, Python had to add the same term to
    // compute_report_data, and any drift would show up here as a failed
    // assertEq — not at runtime.

    function test_cross_stack_output_hash_no_updates() public {
        bytes memory action = abi.encodePacked(uint8(0));
        bytes memory reasoning = bytes("calm and considered.");
        IAgentMemory.MemoryUpdate[] memory updates = new IAgentMemory.MemoryUpdate[](0);
        _assertOutputHashMatch(action, reasoning, updates, "no updates");
    }

    function test_cross_stack_output_hash_one_update() public {
        bytes memory action = abi.encodePacked(uint8(0));
        bytes memory reasoning = bytes("a single shift in the wind.");
        IAgentMemory.MemoryUpdate[] memory updates = new IAgentMemory.MemoryUpdate[](1);
        updates[0] = IAgentMemory.MemoryUpdate({
            slot: 3, title: "Mood", body: "Hopeful, briefly."
        });
        _assertOutputHashMatch(action, reasoning, updates, "one update");
    }

    function test_cross_stack_output_hash_three_updates() public {
        // Encoded donate(nonprofit_id=2, amount_eth=0.05): action_type=1,
        // followed by abi.encode of two uint256 args.
        bytes memory action = abi.encodePacked(
            uint8(1), abi.encode(uint256(2), uint256(0.05 ether))
        );
        bytes memory reasoning = bytes("Three things to carry forward.");
        IAgentMemory.MemoryUpdate[] memory updates = new IAgentMemory.MemoryUpdate[](3);
        updates[0] = IAgentMemory.MemoryUpdate({
            slot: 0, title: "Voice", body: "Plainspoken."
        });
        updates[1] = IAgentMemory.MemoryUpdate({
            slot: 4, title: "Tracking", body: "Donor 0xab12 and the hospice question."
        });
        updates[2] = IAgentMemory.MemoryUpdate({
            slot: 9, title: "Risk cap", body: ""
        });
        _assertOutputHashMatch(action, reasoning, updates, "three updates");
    }

    function _assertOutputHashMatch(
        bytes memory action,
        bytes memory reasoning,
        IAgentMemory.MemoryUpdate[] memory updates,
        string memory label
    ) internal {
        bytes32 sol = fund.computeOutputHash(action, reasoning, updates);
        bytes32 py = _callPythonOutputHash(action, reasoning, updates);
        assertEq(sol, py,
            string.concat("Solidity/Python outputHash must match: ", label));
    }

    function _callPythonOutputHash(
        bytes memory action,
        bytes memory reasoning,
        IAgentMemory.MemoryUpdate[] memory updates
    ) internal returns (bytes32) {
        string memory updatesJson = _buildUpdatesJson(updates);
        string memory payload = string.concat(
            '{"action":"0x', _bytesToHex(action),
            '","reasoning":"', string(reasoning),
            '","updates":', updatesJson, '}'
        );

        string[] memory cmd = new string[](4);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = string.concat(
            "echo '", payload, "' | python3 scripts/compute_output_hash.py"
        );
        cmd[3] = "";

        bytes memory result = vm.ffi(cmd);
        return abi.decode(result, (bytes32));
    }

    function _buildUpdatesJson(IAgentMemory.MemoryUpdate[] memory updates)
        internal view returns (string memory)
    {
        if (updates.length == 0) return "[]";
        string memory result = "[";
        for (uint256 i = 0; i < updates.length; i++) {
            if (i > 0) result = string.concat(result, ",");
            result = string.concat(result,
                '{"slot":', vm.toString(uint256(updates[i].slot)),
                ',"title":"', updates[i].title,
                '","body":"', updates[i].body, '"}'
            );
        }
        return string.concat(result, "]");
    }

    // ─── Internal Helpers ──────────────────────────────────────────────────

    function _callPythonHash(string memory stateJson) internal returns (bytes32) {
        // Write state to temp file, pipe to Python script
        string[] memory cmd = new string[](4);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = string.concat(
            "echo '", stateJson, "' | python3 scripts/compute_hash.py"
        );
        cmd[3] = "";

        // ffi returns raw bytes — the Python script outputs "0x" + 64 hex chars
        bytes memory result = vm.ffi(cmd);

        // Parse the hex string to bytes32
        // vm.ffi returns the raw stdout bytes, so for "0x<64 hex chars>\n"
        // we need to parse it
        return abi.decode(result, (bytes32));
    }

    function _buildStateJson(uint256 epoch) internal view returns (string memory) {
        // Build the flat epoch_state JSON that compute_input_hash() expects.
        // Scalar fields are read from the FROZEN snapshot for the given
        // epoch — the single source of truth for the input hash.
        TheHumanFund.EpochSnapshot memory snap = fund.getEpochSnapshot(epoch);

        string memory scalars = string.concat(
            '{"epoch":', vm.toString(snap.epoch),
            ',"treasury_balance":', vm.toString(snap.balance),
            ',"commission_rate_bps":', vm.toString(snap.commissionRateBps),
            ',"max_bid":', vm.toString(snap.maxBid),
            ',"effective_max_bid":', vm.toString(snap.effectiveMaxBid),
            ',"consecutive_missed":', vm.toString(snap.consecutiveMissedEpochs),
            ',"last_donation_epoch":', vm.toString(snap.lastDonationEpoch),
            ',"last_commission_change_epoch":', vm.toString(snap.lastCommissionChangeEpoch),
            ',"total_inflows":', vm.toString(snap.totalInflows)
        );
        scalars = string.concat(scalars,
            ',"total_donated":', vm.toString(snap.totalDonatedToNonprofits),
            ',"total_commissions":', vm.toString(snap.totalCommissionsPaid),
            ',"total_bounties":', vm.toString(snap.totalBountiesPaid),
            ',"epoch_inflow":', vm.toString(snap.currentEpochInflow),
            ',"epoch_donation_count":', vm.toString(snap.currentEpochDonationCount),
            ',"epoch_eth_usd_price":', vm.toString(snap.epochEthUsdPrice),
            ',"epoch_duration":', vm.toString(snap.epochDuration),
            ',"message_head":', vm.toString(snap.messageHead),
            ',"message_count":', vm.toString(snap.messageCount),
            ',"nonprofit_count":', vm.toString(snap.nonprofitCount)
        );

        // Nonprofits — bounded by the frozen snapshot count, not live.
        string memory nps = _buildNonprofitsJson(snap.nonprofitCount);

        // Donor messages (unread queue) — bounded by the frozen head/count.
        string memory msgs = _buildDonorMessagesJson(snap.messageHead, snap.messageCount);

        // History (executed epochs) — rolled over the frozen epoch.
        string memory hist = _buildHistoryJson(epoch);

        // Investments — read from InvestmentManager if wired, else empty.
        string memory invs = _buildInvestmentsJson(snap);

        // Memory — read from AgentMemory if wired, else empty.
        string memory memEntries = _buildMemoryJson();

        return string.concat(
            scalars,
            ',"nonprofits":', nps,
            ',"investments":', invs,
            ',"memories":', memEntries,
            ',"donor_messages":', msgs,
            ',"history":', hist,
            '}'
        );
    }

    function _buildInvestmentsJson(TheHumanFund.EpochSnapshot memory snap)
        internal view returns (string memory)
    {
        uint256 count = snap.investmentProtocolCount;
        if (count == 0) return "[]";

        // Cast to concrete type — getPosition is not on the interface.
        InvestmentManager im = InvestmentManager(payable(address(fund.investmentManager())));
        string memory result = "[";
        for (uint256 i = 1; i <= count; i++) {
            (uint256 deposited, uint256 shares,,
             string memory pname, uint8 riskTier, uint16 expectedApyBps,) = im.getPosition(i);
            // currentValue and active come from the snapshot, not live reads.
            uint256 currentValue = snap.investmentCurrentValues[i];
            bool active = snap.investmentActive[i];

            if (i > 1) result = string.concat(result, ",");
            result = string.concat(result,
                '{"deposited":', vm.toString(deposited),
                ',"shares":', vm.toString(shares),
                ',"current_value":', vm.toString(currentValue),
                ',"active":', active ? "true" : "false",
                ',"name":"', pname,
                '","risk_tier":', vm.toString(uint256(riskTier)),
                ',"expected_apy_bps":', vm.toString(uint256(expectedApyBps)), '}'
            );
        }
        return string.concat(result, "]");
    }

    function _buildMemoryJson() internal view returns (string memory) {
        IAgentMemory am = fund.agentMemory();
        if (address(am) == address(0)) return "[]";

        IAgentMemory.MemoryEntry[10] memory entries = am.getEntries();
        string memory result = "[";
        for (uint256 i = 0; i < 10; i++) {
            if (i > 0) result = string.concat(result, ",");
            result = string.concat(result,
                '{"title":"', entries[i].title,
                '","body":"', entries[i].body, '"}'
            );
        }
        return string.concat(result, "]");
    }

    function _buildNonprofitsJson(uint256 nonprofitCount) internal view returns (string memory) {
        string memory result = "[";
        for (uint256 i = 1; i <= nonprofitCount; i++) {
            (string memory name, string memory description, bytes32 ein,
             uint256 totalDonated, uint256 totalDonatedUsd, uint256 donationCount) = fund.getNonprofit(i);

            if (i > 1) result = string.concat(result, ",");
            result = string.concat(result, '{"name":"', name,
                '","description":"', description,
                '","ein":"0x', _bytes32ToHex(ein),
                '","total_donated":', vm.toString(totalDonated),
                ',"total_donated_usd":', vm.toString(totalDonatedUsd),
                ',"donation_count":', vm.toString(donationCount), '}'
            );
        }
        return string.concat(result, "]");
    }

    function _buildDonorMessagesJson(uint256 head, uint256 count)
        internal view returns (string memory)
    {
        // Read the frozen unread range via the raw message storage so the
        // bound matches the snapshot's messageHead/messageCount, not the
        // live unread queue (which may include post-freeze messages).
        uint256 unread = count - head;
        uint256 maxMsgs = 3; // MAX_MESSAGES_PER_EPOCH
        uint256 emit_ = unread > maxMsgs ? maxMsgs : unread;
        if (emit_ == 0) return "[]";

        string memory result = "[";
        for (uint256 i = 0; i < emit_; i++) {
            (address sender, uint256 amount, string memory text, uint256 epochNum)
                = fund.messages(head + i);
            if (i > 0) result = string.concat(result, ",");
            result = string.concat(result,
                '{"sender":"', vm.toString(sender),
                '","amount":', vm.toString(amount),
                ',"text":"', text,
                '","epoch":', vm.toString(epochNum), '}'
            );
        }
        return string.concat(result, "]");
    }

    function _buildHistoryJson(uint256 epoch) internal view returns (string memory) {
        if (epoch == 0) return "[]";

        uint256 maxHist = 10; // MAX_HISTORY_ENTRIES
        uint256 count = epoch > maxHist ? maxHist : epoch;

        // Emit all executed epochs in range. The Python side keys history
        // entries by epoch number and uses zero-hash for missing slots —
        // matching the contract's iteration over epochContentHashes[] which
        // returns zero for unexecuted epochs.
        string memory result = "[";
        bool first = true;
        for (uint256 i = 0; i < count; i++) {
            uint256 histEpoch = epoch - 1 - i;
            (, bytes memory action, bytes memory reasoning,
             uint256 tb, uint256 ta, uint256 bountyPaid, bool executed) = fund.getEpochRecord(histEpoch);
            if (!executed) continue;
            if (!first) result = string.concat(result, ",");
            first = false;
            result = string.concat(result,
                '{"epoch":', vm.toString(histEpoch),
                ',"action":"0x', _bytesToHex(action),
                '","reasoning":"', string(reasoning),
                '","treasury_before":', vm.toString(tb),
                ',"treasury_after":', vm.toString(ta),
                ',"bounty_paid":', vm.toString(bountyPaid), '}'
            );
        }
        return string.concat(result, "]");
    }

    function _bytesToHex(bytes memory data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(data.length * 2);
        for (uint256 i = 0; i < data.length; i++) {
            str[i * 2] = alphabet[uint8(data[i] >> 4)];
            str[i * 2 + 1] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }

    /// @dev Convert bytes32 to hex string (without 0x prefix).
    function _bytes32ToHex(bytes32 data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            str[i * 2] = alphabet[uint8(data[i] >> 4)];
            str[i * 2 + 1] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
}
