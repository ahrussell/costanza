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
        // Build the JSON state that matches what compute_input_hash() expects.
        // This must exactly mirror the structure in input_hash.py.

        // State hash inputs
        string memory stateInputs = string.concat(
            '{"epoch":', vm.toString(fund.currentEpoch()),
            ',"balance":', vm.toString(address(fund).balance),
            ',"commission_rate_bps":', vm.toString(fund.commissionRateBps()),
            ',"max_bid":', vm.toString(fund.maxBid()),
            ',"consecutive_missed_epochs":', vm.toString(fund.consecutiveMissedEpochs()),
            ',"last_donation_epoch":', vm.toString(fund.lastDonationEpoch()),
            ',"last_commission_change_epoch":', vm.toString(fund.lastCommissionChangeEpoch()),
            ',"total_inflows":', vm.toString(fund.totalInflows())
        );
        stateInputs = string.concat(stateInputs,
            ',"total_donated_to_nonprofits":', vm.toString(fund.totalDonatedToNonprofits()),
            ',"total_commissions_paid":', vm.toString(fund.totalCommissionsPaid()),
            ',"total_bounties_paid":', vm.toString(fund.totalBountiesPaid()),
            ',"current_epoch_inflow":', vm.toString(fund.currentEpochInflow()),
            ',"current_epoch_donation_count":', vm.toString(fund.currentEpochDonationCount()),
            ',"epoch_eth_usd_price":', vm.toString(fund.epochEthUsdPrice()),
            ',"epoch_duration":', vm.toString(fund.epochDuration()),
            '}'
        );

        // Nonprofits
        string memory nps = "[";
        for (uint256 i = 1; i <= fund.nonprofitCount(); i++) {
            (string memory name, string memory description, bytes32 ein,
             uint256 totalDonated, uint256 totalDonatedUsd, uint256 donationCount) = fund.getNonprofit(i);

            if (i > 1) nps = string.concat(nps, ",");
            nps = string.concat(nps, '{"name":"', name,
                '","description":"', description,
                '","ein":"0x', _bytes32ToHex(ein),
                '","total_donated":', vm.toString(totalDonated),
                ',"total_donated_usd":', vm.toString(totalDonatedUsd),
                ',"donation_count":', vm.toString(donationCount), '}'
            );
        }
        nps = string.concat(nps, "]");

        // Message hashes
        string memory msgHashes = _buildMessageHashesJson();

        // Epoch content hashes
        string memory epochHashes = _buildEpochContentHashesJson();

        // Assemble full state
        return string.concat(
            '{"state_hash_inputs":', stateInputs,
            ',"nonprofits":', nps,
            ',"invest_hash":"0x0000000000000000000000000000000000000000000000000000000000000000"',
            ',"worldview_hash":"0x0000000000000000000000000000000000000000000000000000000000000000"',
            ',"message_hashes":', msgHashes,
            ',"epoch_content_hashes":', epochHashes,
            '}'
        );
    }

    function _buildMessageHashesJson() internal view returns (string memory) {
        uint256 head = fund.messageHead();
        uint256 total = fund.messageCount();
        uint256 unread = total - head;
        uint256 maxMsg = 20; // MAX_MESSAGES_PER_EPOCH
        uint256 count = unread > maxMsg ? maxMsg : unread;

        if (count == 0) return "[]";

        string memory result = "[";
        for (uint256 i = 0; i < count; i++) {
            bytes32 h = fund.messageHashes(head + i);
            if (i > 0) result = string.concat(result, ",");
            result = string.concat(result, '"0x', _bytes32ToHex(h), '"');
        }
        return string.concat(result, "]");
    }

    function _buildEpochContentHashesJson() internal view returns (string memory) {
        uint256 epoch = fund.currentEpoch();
        if (epoch == 0) return "[]";

        uint256 maxHist = 10; // MAX_HISTORY_ENTRIES
        uint256 count = epoch > maxHist ? maxHist : epoch;

        // Include ALL entries (including zeros) — must match Solidity's
        // _hashRecentHistory() which iterates count times unconditionally.
        string memory result = "[";
        for (uint256 i = 0; i < count; i++) {
            uint256 histEpoch = epoch - 1 - i;
            bytes32 h = fund.epochContentHashes(histEpoch);
            if (i > 0) result = string.concat(result, ",");
            result = string.concat(result, '"0x', _bytes32ToHex(h), '"');
        }
        return string.concat(result, "]");
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
