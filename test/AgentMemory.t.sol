// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
import "../src/AgentMemory.sol";
import "../src/InvestmentManager.sol";
import "../src/interfaces/IAgentMemory.sol";
import "./helpers/MockEndaoment.sol";
import "./helpers/EpochTest.sol";

contract AgentMemoryTest is EpochTest {
    TheHumanFund public fund;
    AgentMemory public wv;
    InvestmentManager public im;

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

        // AgentMemory now requires an IM reference in its constructor so it
        // can read live (name, description) per protocol for the read-only
        // entries at indices 10+. No protocols are registered in this base
        // setUp; tests that exercise the description path register their
        // own. Wired BEFORE setAgentMemory so the snapshot freezes a v2
        // memory hash that includes whatever protocols are registered.
        im = new InvestmentManager(address(fund), address(this));
        fund.setInvestmentManager(address(im));

        // Deploy AuctionManager so syncPhase() works
        AuctionManager am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am), 1200, 1200, 82800);

        wv = new AgentMemory(address(fund), address(im));
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

        IAgentMemory.MemoryEntry memory p = wv.getEntry(1);
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
        _assertEntry(1, "Treasury stance", "Grow the treasury before donating");
        _assertEmpty(2);
        _assertEntry(3, "Portfolio", "Diversify across at least 3 protocols");
        _assertEntry(9, "Risk cap", "Never invest more than 25% in one protocol");
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
        _assertEntry(0, "Voice", "I am the fund. I speak plainly.");
    }

    function test_replace_existing_entry() public {
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Initial",
            uint8(1), "Stance", "Be conservative"
        );
        _assertEntry(1, "Stance", "Be conservative");

        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Updated",
            uint8(1), "Stance", "Be aggressive"
        );
        _assertEntry(1, "Stance", "Be aggressive");
    }

    function test_remove_entry_with_empty_strings() public {
        speedrunEpoch(
            fund,
            abi.encodePacked(uint8(0)),
            "Set",
            uint8(5), "Temporary", "Temporary entry"
        );
        _assertEntry(5, "Temporary", "Temporary entry");

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
        IAgentMemory.MemoryEntry memory p = wv.getEntry(2);
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
        IAgentMemory.MemoryEntry memory p = wv.getEntry(4);
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

    // ─── getEntries ───────────────────────────────────────────────────

    function test_get_all_entries_with_no_protocols() public {
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

        IAgentMemory.MemoryEntry[] memory all = wv.getEntries();
        // No protocols registered → length is exactly NUM_SLOTS.
        assertEq(all.length, 10);
        assertEq(all[0].title, "");
        assertEq(all[0].body, "");
        assertEq(all[1].title, "A");
        assertEq(all[1].body, "Alpha");
        assertEq(all[2].title, "");
        assertEq(all[4].title, "B");
        assertEq(all[4].body, "Beta");
        assertEq(all[9].title, "");
    }

    // ─── Investment descriptions (slots 10+) ──────────────────────────

    /// @notice Registering a protocol appends a read-only entry at the
    ///         next available position past slot 9.
    function test_descriptions_appear_at_slot_10_plus() public {
        // Deploy a stub adapter — IM just needs SOMETHING address-shaped
        // for registration; nothing in this test calls into the adapter.
        address stubAdapter = address(0xA1);

        im.addProtocol(stubAdapter, "Aave V3 USDC",
            "Swap ETH to USDC, lend on Aave.", 2, 500);

        IAgentMemory.MemoryEntry[] memory all = wv.getEntries();
        assertEq(all.length, 11, "10 mutable slots + 1 protocol description");
        assertEq(all[10].title, "Aave V3 USDC");
        assertEq(all[10].body, "Swap ETH to USDC, lend on Aave.");

        // getEntry(10) returns the same value as getEntries()[10].
        IAgentMemory.MemoryEntry memory ten = wv.getEntry(10);
        assertEq(ten.title, "Aave V3 USDC");
        assertEq(ten.body, "Swap ETH to USDC, lend on Aave.");
    }

    function test_multiple_protocols_in_order() public {
        im.addProtocol(address(0xA1), "Aave V3 USDC", "desc-1", 2, 500);
        im.addProtocol(address(0xA2), "Lido wstETH",  "desc-2", 1, 350);
        im.addProtocol(address(0xA3), "Coinbase cbETH", "desc-3", 1, 300);

        IAgentMemory.MemoryEntry[] memory all = wv.getEntries();
        assertEq(all.length, 13, "10 + 3 protocols");
        assertEq(all[10].title, "Aave V3 USDC");   assertEq(all[10].body, "desc-1");
        assertEq(all[11].title, "Lido wstETH");    assertEq(all[11].body, "desc-2");
        assertEq(all[12].title, "Coinbase cbETH"); assertEq(all[12].body, "desc-3");
    }

    /// @notice Slots 10+ are read-only. Direct setEntry attempts revert.
    function test_setEntry_reverts_for_read_only_slot() public {
        // Even from the fund — the slot bounds are a contract invariant.
        vm.prank(address(fund));
        vm.expectRevert("slot is read-only");
        wv.setEntry(10, "hostile title", "hostile body");
    }

    function test_getEntry_reverts_past_descriptions() public {
        // No protocols → slot 10 is past the end.
        vm.expectRevert("invalid slot");
        wv.getEntry(10);
    }

    /// @notice stateHash incorporates protocol descriptions. Adding a
    ///         protocol must move the hash even with no memory change.
    function test_stateHash_changes_when_protocol_added() public {
        bytes32 h0 = wv.stateHash();
        im.addProtocol(address(0xA1), "Aave V3 USDC", "desc-1", 2, 500);
        bytes32 h1 = wv.stateHash();
        assertTrue(h0 != h1, "stateHash must reflect new protocol");
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
        wv.setEntry(1, "Title", "Unauthorized");
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

        _assertEntry(1, "T1", "B1");
        _assertEntry(5, "T5", "B5");
        _assertEntry(9, "T9", "B9");
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

        _assertEntry(1, "T1", "B1");
        _assertEntry(2, "T2", "B2");
        _assertEntry(3, "T3", "B3");
        _assertEmpty(4); // dropped
    }

    /// @notice Duplicate slots are applied in order — last write wins.
    function test_multi_update_dup_slot_last_wins() public {
        IAgentMemory.MemoryUpdate[] memory updates = new IAgentMemory.MemoryUpdate[](2);
        updates[0] = IAgentMemory.MemoryUpdate({slot: 2, title: "First", body: "first body"});
        updates[1] = IAgentMemory.MemoryUpdate({slot: 2, title: "Last", body: "last body"});

        speedrunEpoch(fund, abi.encodePacked(uint8(0)), "Dup", updates);

        _assertEntry(2, "Last", "last body");
    }

    /// @notice One bad entry in a batch does not block the others.
    function test_multi_update_bad_entry_does_not_block_others() public {
        IAgentMemory.MemoryUpdate[] memory updates = new IAgentMemory.MemoryUpdate[](3);
        updates[0] = IAgentMemory.MemoryUpdate({slot: 1, title: "Good1", body: "ok"});
        updates[1] = IAgentMemory.MemoryUpdate({slot: 99, title: "bad", body: "out of range"}); // invalid
        updates[2] = IAgentMemory.MemoryUpdate({slot: 3, title: "Good3", body: "ok"});

        speedrunEpoch(fund, abi.encodePacked(uint8(0)), "Mixed", updates);

        _assertEntry(1, "Good1", "ok");
        _assertEmpty(99 % 10); // slot 9 not targeted in this test
        _assertEntry(3, "Good3", "ok");
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
        _assertEntry(2, "Posture", "Invest conservatively in bear markets");
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

        _assertEntry(1, "Patience", "Stay patient and grow");
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _assertEntry(uint256 slot, string memory title, string memory body) internal view {
        IAgentMemory.MemoryEntry memory p = wv.getEntry(slot);
        assertEq(p.title, title);
        assertEq(p.body, body);
    }

    function _assertEmpty(uint256 slot) internal view {
        IAgentMemory.MemoryEntry memory p = wv.getEntry(slot);
        assertEq(p.title, "");
        assertEq(p.body, "");
    }
}
