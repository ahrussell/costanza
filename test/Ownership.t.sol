// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TheHumanFund.sol";
import "../src/AuctionManager.sol";
import "../src/TdxVerifier.sol";
import "../src/InvestmentManager.sol";
import "./helpers/MockProofVerifier.sol";

/// @notice End-to-end behavior of TheHumanFund.transferOwnership fan-out
///         and the permanent verifier-ID binding model.
///
/// Covers Step 0 of the mainnet launch plan:
///   1. transferOwnership atomically moves fund.owner + every ever-bound
///      verifier's owner + investmentManager.admin to the new address.
///   2. Verifier ID binding is permanent: revoke leaves the address in
///      place, re-approving the same address restores authorization,
///      re-approving a different address reverts.
///   3. Revoked verifiers are rejected at the verify call site (we test
///      the precondition by exercising the path that would consume them).
///   4. Subcontract authorization rules: TdxVerifier.transferOwner accepts
///      owner OR fund; InvestmentManager.setAdmin accepts admin OR fund.
contract OwnershipTest is Test {
    TheHumanFund fund;
    TdxVerifier tdxVerifier;
    InvestmentManager im;

    address constant SAFE = address(0x6dF6f527E193fAf1334c26A6d811fAd62E79E5Db);
    address constant OTHER = address(0xBEEF);

    function setUp() public {
        // Minimal fund: no real DeFi, no DonationExecutor, no oracle.
        fund = new TheHumanFund{value: 1 ether}(
            1000,             // 10% commission
            0.001 ether,      // initial maxBid
            address(0xBEEF),  // donExec — not exercised
            address(0)        // ETH/USD feed — not exercised
        );

        // Test-contract is owner of fund (constructor sets owner = msg.sender).
        // Test-contract is owner of TdxVerifier (its constructor too).
        tdxVerifier = new TdxVerifier(address(fund));

        // InvestmentManager admin = test-contract (passed explicitly).
        im = new InvestmentManager(address(fund), address(this));
        fund.setInvestmentManager(address(im));

        // AuctionManager so the fund is fully wired (some methods syncPhase).
        AuctionManager am = new AuctionManager(address(fund));
        fund.setAuctionManager(address(am), 1200, 1200, 82800);
    }

    // ─── transferOwnership: happy path fan-out ─────────────────────────────

    function test_transferOwnership_fansOutToFundAndVerifierAndIm() public {
        fund.approveVerifier(1, address(tdxVerifier));

        assertEq(fund.owner(), address(this));
        assertEq(tdxVerifier.owner(), address(this));
        assertEq(im.admin(), address(this));

        fund.transferOwnership(SAFE);

        assertEq(fund.owner(), SAFE);
        assertEq(tdxVerifier.owner(), SAFE);
        assertEq(im.admin(), SAFE);
    }

    function test_transferOwnership_movesMultipleVerifiers() public {
        TdxVerifier verifier2 = new TdxVerifier(address(fund));
        fund.approveVerifier(1, address(tdxVerifier));
        fund.approveVerifier(2, address(verifier2));

        fund.transferOwnership(SAFE);

        assertEq(tdxVerifier.owner(), SAFE);
        assertEq(verifier2.owner(), SAFE);
    }

    function test_transferOwnership_movesRevokedVerifierToo() public {
        // A revoked verifier's owner still controls its image registry; if
        // it's ever re-approved, we want the new owner in charge. So the
        // fan-out must include revoked verifiers.
        fund.approveVerifier(1, address(tdxVerifier));
        fund.revokeVerifier(1);

        fund.transferOwnership(SAFE);

        assertEq(tdxVerifier.owner(), SAFE);
    }

    function test_transferOwnership_emptyVerifierList() public {
        // No verifiers ever approved — the fan-out loop is a no-op.
        fund.transferOwnership(SAFE);
        assertEq(fund.owner(), SAFE);
        assertEq(im.admin(), SAFE);
    }

    function test_transferOwnership_noInvestmentManager() public {
        // Fresh fund without an IM wired in.
        TheHumanFund bareFund = new TheHumanFund{value: 0.1 ether}(
            1000, 0.001 ether, address(0xBEEF), address(0)
        );
        bareFund.transferOwnership(SAFE);
        assertEq(bareFund.owner(), SAFE);
    }

    function test_transferOwnership_subcontractsThenSelf() public {
        // After successful transfer, original owner can no longer act on
        // any subcontract — proving the fan-out actually moved authority,
        // not just touched the fund.
        fund.approveVerifier(1, address(tdxVerifier));
        fund.transferOwnership(SAFE);

        // Original test-contract has no authority anywhere.
        vm.expectRevert(TdxVerifier.Unauthorized.selector);
        tdxVerifier.approveImage(bytes32(uint256(1)));

        vm.expectRevert(InvestmentManager.Unauthorized.selector);
        im.freezeInvestments();

        // Safe (new owner) can do all of the above.
        vm.prank(SAFE);
        tdxVerifier.approveImage(bytes32(uint256(1)));

        vm.prank(SAFE);
        im.freezeInvestments();
    }

    // ─── transferOwnership: rejection paths ────────────────────────────────

    function test_transferOwnership_rejectsZeroAddress() public {
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.transferOwnership(address(0));
    }

    function test_transferOwnership_rejectsNonOwner() public {
        vm.prank(OTHER);
        vm.expectRevert(TheHumanFund.Unauthorized.selector);
        fund.transferOwnership(SAFE);
    }

    function test_transferOwnership_rejectedAfterFreezeMigrate() public {
        fund.freeze(fund.FREEZE_MIGRATE());
        vm.expectRevert(TheHumanFund.Frozen.selector);
        fund.transferOwnership(SAFE);
    }

    function test_transferOwnership_revertsAtomicallyIfSubcontractReverts() public {
        // A verifier whose transferOwner reverts (e.g., an InvalidParams on
        // zero-address newOwner — but we already check that, so simulate
        // with a verifier that always reverts).
        RevertingVerifier badVerifier = new RevertingVerifier();
        fund.approveVerifier(1, address(badVerifier));

        vm.expectRevert();
        fund.transferOwnership(SAFE);

        // fund.owner unchanged — caller can investigate.
        assertEq(fund.owner(), address(this));
    }

    // ─── Permanent verifier ID binding ─────────────────────────────────────

    function test_approveVerifier_firstTimeBindsAndApproves() public {
        fund.approveVerifier(5, address(tdxVerifier));

        assertEq(address(fund.verifiers(5)), address(tdxVerifier));
        assertTrue(fund.verifierApproved(5));
        assertEq(fund.verifierIds(0), 5);
    }

    function test_approveVerifier_sameAddressIsIdempotent() public {
        fund.approveVerifier(5, address(tdxVerifier));
        fund.approveVerifier(5, address(tdxVerifier)); // no revert
        assertTrue(fund.verifierApproved(5));
    }

    function test_approveVerifier_differentAddressReverts() public {
        TdxVerifier other = new TdxVerifier(address(fund));
        fund.approveVerifier(5, address(tdxVerifier));

        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.approveVerifier(5, address(other));
    }

    function test_revokeVerifier_keepsAddressBindingFlipsApproval() public {
        fund.approveVerifier(5, address(tdxVerifier));
        fund.revokeVerifier(5);

        // Address binding stays intact — clients can rely on ID 5 → tdxVerifier
        assertEq(address(fund.verifiers(5)), address(tdxVerifier));
        // But authorization is off.
        assertFalse(fund.verifierApproved(5));
    }

    function test_revokeThenReapproveSameAddress_restoresAuthorization() public {
        fund.approveVerifier(5, address(tdxVerifier));
        fund.revokeVerifier(5);
        assertFalse(fund.verifierApproved(5));

        fund.approveVerifier(5, address(tdxVerifier));
        assertTrue(fund.verifierApproved(5));
    }

    function test_revokeVerifier_doesNotDoubleAddToList() public {
        fund.approveVerifier(5, address(tdxVerifier));
        fund.revokeVerifier(5);
        fund.approveVerifier(5, address(tdxVerifier));

        // verifierIds should still have exactly one entry — re-approval of
        // the same ID doesn't push again.
        // No public length getter; index 0 should be 5, index 1 should revert.
        assertEq(fund.verifierIds(0), 5);
        vm.expectRevert();
        fund.verifierIds(1);
    }

    function test_revokeVerifier_alreadyRevokedReverts() public {
        fund.approveVerifier(5, address(tdxVerifier));
        fund.revokeVerifier(5);

        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.revokeVerifier(5);
    }

    function test_revokeVerifier_neverApprovedReverts() public {
        vm.expectRevert(TheHumanFund.InvalidParams.selector);
        fund.revokeVerifier(99);
    }

    // ─── Subcontract authorization rules ───────────────────────────────────

    function test_tdxVerifier_transferOwner_byOwnerDirectly() public {
        // Owner can move ownership without going through the fund.
        tdxVerifier.transferOwner(SAFE);
        assertEq(tdxVerifier.owner(), SAFE);
    }

    function test_tdxVerifier_transferOwner_rejectsRandom() public {
        vm.prank(OTHER);
        vm.expectRevert(TdxVerifier.Unauthorized.selector);
        tdxVerifier.transferOwner(SAFE);
    }

    function test_tdxVerifier_transferOwner_rejectsZero() public {
        vm.expectRevert(TdxVerifier.InvalidParams.selector);
        tdxVerifier.transferOwner(address(0));
    }

    function test_tdxVerifier_transferOwner_byFund() public {
        // Fund (not the current owner) is permitted — that's how the
        // wrapper works. We simulate by pranking as the fund.
        vm.prank(address(fund));
        tdxVerifier.transferOwner(SAFE);
        assertEq(tdxVerifier.owner(), SAFE);
    }

    function test_im_setAdmin_byAdminDirectly() public {
        im.setAdmin(SAFE);
        assertEq(im.admin(), SAFE);
    }

    function test_im_setAdmin_rejectsRandom() public {
        vm.prank(OTHER);
        vm.expectRevert(InvestmentManager.Unauthorized.selector);
        im.setAdmin(SAFE);
    }

    function test_im_setAdmin_rejectsZero() public {
        vm.expectRevert(InvestmentManager.Unauthorized.selector);
        im.setAdmin(address(0));
    }

    function test_im_setAdmin_byFund() public {
        vm.prank(address(fund));
        im.setAdmin(SAFE);
        assertEq(im.admin(), SAFE);
    }

    function test_im_setAdmin_blockedByFreezeAdmin() public {
        im.freezeAdmin();
        vm.expectRevert(InvestmentManager.Frozen.selector);
        im.setAdmin(SAFE);
    }
}

// ─── Helpers ──────────────────────────────────────────────────────────────

/// @notice Verifier that always reverts on transferOwner — used to test
///         the atomicity of TheHumanFund.transferOwnership.
contract RevertingVerifier {
    function verify(bytes32, bytes32, bytes calldata) external payable returns (bool) {
        return true;
    }
    function freeze() external {}
    function transferOwner(address) external pure {
        revert("nope");
    }
}
