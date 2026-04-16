// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
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
        bytes memory noopAction = abi.encodePacked(uint8(0));
        speedrunEpoch(fund, noopAction, "epoch 1");

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

    function _assertCrossStackMatch(uint256 epoch, string memory label) internal {
        bytes32 solidityHash = fund.computeInputHashForEpoch(epoch);
        string memory stateJson = _buildStateJson(epoch);
        bytes32 pythonHash = _callPythonHash(stateJson);
        assertEq(solidityHash, pythonHash,
            string.concat("Solidity/Python hashes must match: ", label));
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
        // epoch — this is the single source of truth after the
        // pure-_hashSnapshot refactor.
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

        return string.concat(
            scalars,
            ',"nonprofits":', nps,
            ',"investments":[]',                     // no investment manager in this test
            ',"guiding_policies":[]',                // no worldview in this test
            ',"donor_messages":', msgs,
            ',"history":', hist,
            '}'
        );
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
