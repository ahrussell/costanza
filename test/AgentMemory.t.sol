// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
import "../src/AgentMemory.sol";
import "../src/interfaces/IAgentMemory.sol";
import "./helpers/MockEndaoment.sol";
import "./helpers/EpochTest.sol";

contract AgentMemoryTest is EpochTest {
    TheHumanFund public fund;
    AgentMemory public wv;

    function setUp() public {
        MockWETH mw = new MockWETH();
        MockUSDC mu = new MockUSDC();
        MockSwapRouter mr = new MockSwapRouter(address(mw), address(mu));
        MockEndaomentFactory mf = new MockEndaomentFactory();

        MockChainlinkFeed mfeed = new MockChainlinkFeed(2000e8, 8);
        DonationExecutor donExec = new DonationExecutor(
            address(mf), address(mw), address(mu), address(mr), address(mfeed)
        );
        fund = new TheHumanFund{value: 5 ether}(
            1000, 0.005 ether,
            address(donExec), address(mfeed)
        );

        fund.addNonprofit("GiveDirectly", "Cash transfers", bytes32("EIN-GD"));
        fund.addNonprofit("Against Malaria Foundation", "Malaria prevention", bytes32("EIN-AMF"));
        fund.addNonprofit("Helen Keller International", "NTDs", bytes32("EIN-HKI"));

        mf.preDeployOrg(bytes32("EIN-GD"));

        // Deploy AuctionManager so syncPhase() works
        AuctionManager am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am), 1200, 1200, 82800);

        wv = new AgentMemory(address(fund));
        fund.setAgentMemory(address(wv));
        _registerMockVerifier(fund);
    }

    // ─── Basic Memory Setting (via sidecar) ───────────────────────────

    function test_set_memory_entry() public {
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Setting my first memory entry.",
            uint8(1),
            "Donation strategy",
            "Prioritize high-impact, evidence-based charities"
        );

        IAgentMemory.Policy memory p = wv.getPolicy(1);
        assertEq(p.title, "Donation strategy");
        assertEq(p.body, "Prioritize high-impact, evidence-based charities");
        assertEq(fund.currentEpoch(), 2);
    }

    function test_set_multiple_entries_across_epochs() public {
        // Epoch 1: set slot 1
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Entry 1",
            uint8(1),
            "Treasury stance",
            "Grow the treasury before donating"
        );

        // Epoch 2: set slot 3
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Entry 3",
            uint8(3),
            "Portfolio",
            "Diversify across at least 3 protocols"
        );

        // Epoch 3: set slot 9 (last slot)
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Entry 9",
            uint8(9),
            "Risk cap",
            "Never invest more than 25% in one protocol"
        );

        _assertEmpty(0);
        _assertPolicy(1, "Treasury stance", "Grow the treasury before donating");
        _assertEmpty(2);
        _assertPolicy(3, "Portfolio", "Diversify across at least 3 protocols");
        _assertPolicy(9, "Risk cap", "Never invest more than 25% in one protocol");
        assertEq(fund.currentEpoch(), 4);
    }

    /// @notice Slot 0 is now writable (it was reserved in the pre-titles
    ///         schema). The model owns all 10 slots.
    function test_slot_zero_now_writable() public {
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Claiming slot 0",
            uint8(0),
            "Voice",
            "I am the fund. I speak plainly."
        );
        _assertPolicy(0, "Voice", "I am the fund. I speak plainly.");
    }

    function test_replace_existing_entry() public {
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Initial",
            uint8(1), "Stance", "Be conservative"
        );
        _assertPolicy(1, "Stance", "Be conservative");

        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Updated",
            uint8(1), "Stance", "Be aggressive"
        );
        _assertPolicy(1, "Stance", "Be aggressive");
    }

    function test_remove_entry_with_empty_strings() public {
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Set",
            uint8(5), "Temporary", "Temporary entry"
        );
        _assertPolicy(5, "Temporary", "Temporary entry");

        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Clear",
            uint8(5), "", ""
        );
        _assertEmpty(5);
    }

    // ─── Title / Body truncation ─────────────────────────────────────

    function test_title_truncated_at_max_title_length() public {
        // 80-char title; MAX_TITLE_LENGTH is 64.
        string memory longTitle = "This is a deliberately long title intended to overflow the limit!!";
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Long title",
            uint8(2),
            longTitle,
            "body here"
        );
        IAgentMemory.Policy memory p = wv.getPolicy(2);
        assertEq(bytes(p.title).length, wv.MAX_TITLE_LENGTH(), "title truncated to MAX_TITLE_LENGTH");
        assertEq(p.body, "body here");
    }

    function test_body_truncated_at_max_body_length() public {
        // Build a body > 280 chars.
        bytes memory b = new bytes(400);
        for (uint256 i = 0; i < 400; i++) b[i] = bytes1(uint8(0x41)); // 'A'
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Long body",
            uint8(4),
            "Title",
            string(b)
        );
        IAgentMemory.Policy memory p = wv.getPolicy(4);
        assertEq(p.title, "Title");
        assertEq(bytes(p.body).length, wv.MAX_BODY_LENGTH(), "body truncated to MAX_BODY_LENGTH");
    }

    // ─── State Hash ────────────────────────────────────────────────────

    function test_state_hash_changes_with_entry() public {
        bytes32 hash1 = wv.stateHash();

        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Set",
            uint8(1), "Stance", "New entry"
        );

        bytes32 hash2 = wv.stateHash();
        assertTrue(hash1 != hash2);
    }

    function test_state_hash_deterministic() public {
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Set",
            uint8(1), "Stance", "Entry A"
        );

        bytes32 hash1 = wv.stateHash();
        bytes32 hash2 = wv.stateHash();
        assertEq(hash1, hash2);
    }

    /// @notice Title-only and body-only changes both move the hash.
    function test_state_hash_includes_title_and_body() public {
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Both",
            uint8(2), "Alpha", "body-a"
        );
        bytes32 h1 = wv.stateHash();

        // Change title only
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Title only",
            uint8(2), "Beta", "body-a"
        );
        bytes32 h2 = wv.stateHash();
        assertTrue(h1 != h2, "hash reflects title change");

        // Change body only
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Body only",
            uint8(2), "Beta", "body-b"
        );
        bytes32 h3 = wv.stateHash();
        assertTrue(h2 != h3, "hash reflects body change");
    }

    function test_input_hash_includes_memory() public {
        // Run epoch 1 with no memory update, then run epoch 2 with one —
        // the two frozen snapshot hashes must differ.
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Epoch 1"
        );
        bytes32 hash1 = fund.computeInputHashForEpoch(1);

        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Epoch 2",
            uint8(1), "Stance", "Memory changes input hash"
        );
        bytes32 hash2 = fund.computeInputHashForEpoch(2);

        assertTrue(hash1 != hash2);
    }

    // ─── getPolicies ───────────────────────────────────────────────────

    function test_get_all_entries() public {
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Set 1",
            uint8(1), "A", "Alpha"
        );
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Set 4",
            uint8(4), "B", "Beta"
        );

        IAgentMemory.Policy[10] memory all = wv.getPolicies();
        assertEq(all[0].title, "");
        assertEq(all[0].body, "");
        assertEq(all[1].title, "A");
        assertEq(all[1].body, "Alpha");
        assertEq(all[2].title, "");
        assertEq(all[4].title, "B");
        assertEq(all[4].body, "Beta");
        assertEq(all[9].title, "");
    }

    // ─── Event Emission ────────────────────────────────────────────────

    function test_emits_memory_entry_set_event() public {
        vm.recordLogs();
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Event test",
            uint8(1), "Title", "Test entry"
        );

        // MemoryEntrySet is emitted among auction events. Find it.
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 topic = keccak256("MemoryEntrySet(uint256,string,string)");
        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == topic) {
                assertEq(entries[i].topics[1], bytes32(uint256(1)), "slot 1");
                // Decode non-indexed data: (string title, string body)
                (string memory t, string memory b) = abi.decode(entries[i].data, (string, string));
                assertEq(t, "Title");
                assertEq(b, "Test entry");
                found = true;
                break;
            }
        }
        assertTrue(found, "MemoryEntrySet event must be emitted");
    }

    // ─── Only Fund Can Set ─────────────────────────────────────────────

    function test_only_fund_can_set_entry() public {
        vm.prank(address(0xdead));
        vm.expectRevert("only fund");
        wv.setPolicy(1, "Title", "Unauthorized");
    }

    // ─── Multi-update batch ────────────────────────────────────────────

    function test_multi_update_batch_of_three() public {
        IAgentMemory.MemoryUpdate[] memory updates = new IAgentMemory.MemoryUpdate[](3);
        updates[0] = IAgentMemory.MemoryUpdate({slot: 1, title: "T1", body: "B1"});
        updates[1] = IAgentMemory.MemoryUpdate({slot: 5, title: "T5", body: "B5"});
        updates[2] = IAgentMemory.MemoryUpdate({slot: 9, title: "T9", body: "B9"});

        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Triple update",
            updates
        );

        _assertPolicy(1, "T1", "B1");
        _assertPolicy(5, "T5", "B5");
        _assertPolicy(9, "T9", "B9");
    }

    /// @notice A 4-entry batch is truncated to the first 3; the 4th entry is
    ///         silently dropped.
    function test_multi_update_truncated_to_max() public {
        IAgentMemory.MemoryUpdate[] memory updates = new IAgentMemory.MemoryUpdate[](4);
        updates[0] = IAgentMemory.MemoryUpdate({slot: 1, title: "T1", body: "B1"});
        updates[1] = IAgentMemory.MemoryUpdate({slot: 2, title: "T2", body: "B2"});
        updates[2] = IAgentMemory.MemoryUpdate({slot: 3, title: "T3", body: "B3"});
        updates[3] = IAgentMemory.MemoryUpdate({slot: 4, title: "T4", body: "B4"});

        speedrunEpoch(fund, abi.encodePacked(uint8(0)), "Trunc", updates);

        _assertPolicy(1, "T1", "B1");
        _assertPolicy(2, "T2", "B2");
        _assertPolicy(3, "T3", "B3");
        _assertEmpty(4); // dropped
    }

    /// @notice Duplicate slots are applied in order — last write wins.
    function test_multi_update_dup_slot_last_wins() public {
        IAgentMemory.MemoryUpdate[] memory updates = new IAgentMemory.MemoryUpdate[](2);
        updates[0] = IAgentMemory.MemoryUpdate({slot: 2, title: "First", body: "first body"});
        updates[1] = IAgentMemory.MemoryUpdate({slot: 2, title: "Last", body: "last body"});

        speedrunEpoch(fund, abi.encodePacked(uint8(0)), "Dup", updates);

        _assertPolicy(2, "Last", "last body");
    }

    /// @notice One bad entry in a batch does not block the others.
    function test_multi_update_bad_entry_does_not_block_others() public {
        IAgentMemory.MemoryUpdate[] memory updates = new IAgentMemory.MemoryUpdate[](3);
        updates[0] = IAgentMemory.MemoryUpdate({slot: 1, title: "Good1", body: "ok"});
        updates[1] = IAgentMemory.MemoryUpdate({slot: 99, title: "bad", body: "out of range"}); // invalid
        updates[2] = IAgentMemory.MemoryUpdate({slot: 3, title: "Good3", body: "ok"});

        speedrunEpoch(fund, abi.encodePacked(uint8(0)), "Mixed", updates);

        _assertPolicy(1, "Good1", "ok");
        _assertEmpty(99 % 10); // slot 9 not targeted in this test
        _assertPolicy(3, "Good3", "ok");
    }

    /// @notice Empty updates array is a valid submission shape.
    function test_multi_update_empty_array() public {
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "No updates",
            _emptyUpdates()
        );

        // All slots still empty.
        for (uint256 i = 0; i < 10; i++) _assertEmpty(i);
        assertEq(fund.currentEpoch(), 2, "epoch advanced without updates");
    }

    // ─── Memory update alongside action ────────────────────────────────

    function test_memory_update_alongside_action() public {
        // Donate AND update memory in the same epoch
        bytes memory donateAction = abi.encodePacked(uint8(1), abi.encode(uint256(1), uint256(0.1 ether)));
        speedrunEpoch(
            fund,
            donateAction,
            "Donating and recording my strategy",
            uint8(2),
            "Posture",
            "Invest conservatively in bear markets"
        );

        // Both should have happened
        (,,, uint256 donated,,) = fund.getNonprofit(1);
        assertEq(donated, 0.1 ether);
        _assertPolicy(2, "Posture", "Invest conservatively in bear markets");
    }

    function test_memory_update_with_do_nothing() public {
        // do_nothing action but still update memory
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Just updating my memory",
            uint8(1),
            "Patience",
            "Stay patient and grow"
        );

        _assertPolicy(1, "Patience", "Stay patient and grow");
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _assertPolicy(uint256 slot, string memory title, string memory body) internal view {
        IAgentMemory.Policy memory p = wv.getPolicy(slot);
        assertEq(p.title, title);
        assertEq(p.body, body);
    }

    function _assertEmpty(uint256 slot) internal view {
        IAgentMemory.Policy memory p = wv.getPolicy(slot);
        assertEq(p.title, "");
        assertEq(p.body, "");
    }
}
