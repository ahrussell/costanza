// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TheHumanFund.sol";
import "./helpers/MockEndaoment.sol";

/// @title CrossStackHashTest
/// @notice Verifies that the Solidity _computeInputHash() and the Python
///         compute_input_hash() produce identical results for the same state.
///         This is critical: if they diverge, TEE attestation will fail at runtime.
///         Uses vm.ffi() to call the Python implementation and compares outputs.
contract CrossStackHashTest is Test {
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
            address(mockFactory),
            address(mockWeth),
            address(mockUsdc),
            address(mockRouter),
            address(mockFeed)
        );

        fund.addNonprofit("GiveDirectly", "Cash transfers to extreme poor", bytes32("EIN-GD"));
        fund.addNonprofit("Against Malaria Foundation", "Malaria prevention", bytes32("EIN-AMF"));
        fund.addNonprofit("Helen Keller International", "Neglected tropical diseases", bytes32("EIN-HKI"));

        mockFactory.preDeployOrg(bytes32("EIN-GD"));
        mockFactory.preDeployOrg(bytes32("EIN-AMF"));
        mockFactory.preDeployOrg(bytes32("EIN-HKI"));
    }

    /// @notice Core cross-stack test: compare Solidity and Python hash outputs.
    function test_cross_stack_hash_matches_initial_state() public {
        bytes32 solidityHash = fund.computeInputHash();

        // Build the same state as JSON for Python
        string memory stateJson = _buildStateJson();

        // Call Python via FFI
        bytes32 pythonHash = _callPythonHash(stateJson);

        assertEq(solidityHash, pythonHash, "Solidity and Python hashes must match");
    }

    /// @notice Test after a donation changes state — hashes should still match.
    function test_cross_stack_hash_after_donation() public {
        // Donate to change state
        vm.deal(address(0xDEAD), 1 ether);
        vm.prank(address(0xDEAD));
        fund.donate{value: 0.5 ether}(0);

        bytes32 solidityHash = fund.computeInputHash();
        string memory stateJson = _buildStateJson();
        bytes32 pythonHash = _callPythonHash(stateJson);

        assertEq(solidityHash, pythonHash, "Hashes must match after donation");
    }

    /// @notice Test after epoch execution — content hashes and epoch state change.
    function test_cross_stack_hash_after_epoch() public {
        // Execute an epoch (noop action)
        bytes memory noopAction = abi.encodePacked(uint8(0));
        fund.submitEpochAction(noopAction, "Test reasoning", -1, "");

        bytes32 solidityHash = fund.computeInputHash();
        string memory stateJson = _buildStateJson();
        bytes32 pythonHash = _callPythonHash(stateJson);

        assertEq(solidityHash, pythonHash, "Hashes must match after epoch execution");
    }

    /// @notice Test with messages in the queue.
    function test_cross_stack_hash_with_messages() public {
        vm.deal(address(0xBEEF), 1 ether);
        vm.prank(address(0xBEEF));
        fund.donateWithMessage{value: 0.1 ether}(0, "Hello from a donor!");

        bytes32 solidityHash = fund.computeInputHash();
        string memory stateJson = _buildStateJson();
        bytes32 pythonHash = _callPythonHash(stateJson);

        assertEq(solidityHash, pythonHash, "Hashes must match with messages");
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

    function _buildStateJson() internal view returns (string memory) {
        // Build the flat epoch_state JSON that compute_input_hash() expects.
        // This must exactly mirror the structure the runner passes to the
        // enclave — the enclave is a dumb hasher and reads all display data
        // directly from this dict.

        // Scalar state fields (matches _hashState() layout)
        string memory scalars = string.concat(
            '{"epoch":', vm.toString(fund.currentEpoch()),
            ',"treasury_balance":', vm.toString(address(fund).balance),
            ',"commission_rate_bps":', vm.toString(fund.commissionRateBps()),
            ',"max_bid":', vm.toString(fund.maxBid()),
            ',"effective_max_bid":', vm.toString(fund.effectiveMaxBid()),
            ',"consecutive_missed":', vm.toString(fund.consecutiveMissedEpochs()),
            ',"last_donation_epoch":', vm.toString(fund.lastDonationEpoch()),
            ',"last_commission_change_epoch":', vm.toString(fund.lastCommissionChangeEpoch()),
            ',"total_inflows":', vm.toString(fund.totalInflows())
        );
        scalars = string.concat(scalars,
            ',"total_donated":', vm.toString(fund.totalDonatedToNonprofits()),
            ',"total_commissions":', vm.toString(fund.totalCommissionsPaid()),
            ',"total_bounties":', vm.toString(fund.totalBountiesPaid()),
            ',"epoch_inflow":', vm.toString(fund.currentEpochInflow()),
            ',"epoch_donation_count":', vm.toString(fund.currentEpochDonationCount()),
            ',"epoch_eth_usd_price":', vm.toString(fund.epochEthUsdPrice()),
            ',"epoch_duration":', vm.toString(fund.epochDuration())
        );

        // Nonprofits
        string memory nps = _buildNonprofitsJson();

        // Donor messages (unread queue)
        string memory msgs = _buildDonorMessagesJson();

        // History (executed epochs)
        string memory hist = _buildHistoryJson();

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

    function _buildNonprofitsJson() internal view returns (string memory) {
        string memory result = "[";
        for (uint256 i = 1; i <= fund.nonprofitCount(); i++) {
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

    function _buildDonorMessagesJson() internal view returns (string memory) {
        (address[] memory senders, uint256[] memory amounts,
         string[] memory texts, uint256[] memory epochNums) = fund.getUnreadMessages();

        if (senders.length == 0) return "[]";

        string memory result = "[";
        for (uint256 i = 0; i < senders.length; i++) {
            if (i > 0) result = string.concat(result, ",");
            result = string.concat(result,
                '{"sender":"', vm.toString(senders[i]),
                '","amount":', vm.toString(amounts[i]),
                ',"text":"', texts[i],
                '","epoch":', vm.toString(epochNums[i]), '}'
            );
        }
        return string.concat(result, "]");
    }

    function _buildHistoryJson() internal view returns (string memory) {
        uint256 epoch = fund.currentEpoch();
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
             uint256 tb, uint256 ta, , bool executed) = fund.getEpochRecord(histEpoch);
            if (!executed) continue;
            if (!first) result = string.concat(result, ",");
            first = false;
            result = string.concat(result,
                '{"epoch":', vm.toString(histEpoch),
                ',"action":"0x', _bytesToHex(action),
                '","reasoning":"', string(reasoning),
                '","treasury_before":', vm.toString(tb),
                ',"treasury_after":', vm.toString(ta), '}'
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
