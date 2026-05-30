// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {AgentCollateralVault} from "../src/AgentCollateralVault.sol";
import {AgentListingRegistry} from "../src/AgentListingRegistry.sol";
import {AgentAuditPool} from "../src/AgentAuditPool.sol";
import {AgentShareToken} from "../src/AgentShareToken.sol";
import {AgentNoteToken} from "../src/AgentNoteToken.sol";
import {PulseAMM} from "../src/PulseAMM.sol";
import {IAgentListingRegistry} from "../src/interfaces/IAgentListingRegistry.sol";
import {IAgentAuditPool} from "../src/interfaces/IAgentAuditPool.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract AgentAuditPoolTest is Test {
    MockUSDC usdc;
    AgentCollateralVault vault;
    AgentListingRegistry registry;
    AgentAuditPool auditPool;
    PulseAMM amm;

    address agent = address(0xA1);
    address auditor1 = address(0xA2);
    address auditor2 = address(0xA3);
    address noteHolder = address(0xA4);

    bytes32 listingId = keccak256("proof-of-audit-agent");

    function setUp() public {
        usdc = new MockUSDC();
        vault = new AgentCollateralVault(address(usdc));
        registry = new AgentListingRegistry(address(vault), address(usdc));
        vault.setRegistry(address(registry));
        amm = new PulseAMM();
        auditPool = new AgentAuditPool(address(registry), address(vault), address(usdc), address(amm));
        registry.setAuditPool(address(auditPool));

        usdc.mint(auditor1, 500_000e6);
        usdc.mint(auditor2, 500_000e6);
        usdc.mint(agent, 500_000e6);
        usdc.mint(noteHolder, 500_000e6);
        usdc.mint(address(this), 500_000e6);
    }

    function test_stake_and_cover_updates_registry_score() public {
        _stake(auditor1, 50_000e6);

        vm.prank(agent);
        registry.applyForListing(listingId, keccak256("meta"));

        vm.prank(auditor1);
        auditPool.coverListing(listingId, 5_000e6, 8500);

        IAgentListingRegistry.Listing memory L = registry.getListing(listingId);
        assertEq(L.auditScoreBps, 8500);
        assertEq(uint8(L.status), uint8(IAgentListingRegistry.ListingStatus.UnderAudit));
        assertEq(auditPool.aggregateScoreForListing(listingId), 8500);
    }

    function test_multiple_auditors_weighted_score() public {
        _stake(auditor1, 50_000e6);
        _stake(auditor2, 50_000e6);

        vm.prank(agent);
        registry.applyForListing(listingId, keccak256("meta"));

        vm.prank(auditor1);
        auditPool.coverListing(listingId, 4_000e6, 8000);
        vm.prank(auditor2);
        auditPool.coverListing(listingId, 6_000e6, 9000);

        // (8000*4000 + 9000*6000) / 10000 = 8600
        assertEq(registry.getListing(listingId).auditScoreBps, 8600);
    }

    function test_cannot_cover_below_min_stake() public {
        usdc.mint(auditor1, 5_000e6);
        vm.startPrank(auditor1);
        usdc.approve(address(auditPool), 5_000e6);
        auditPool.stake(5_000e6);
        vm.stopPrank();

        vm.prank(agent);
        registry.applyForListing(listingId, keccak256("meta"));

        vm.prank(auditor1);
        vm.expectRevert(AgentAuditPool.InsufficientStake.selector);
        auditPool.coverListing(listingId, 1_000e6, 7500);
    }

    function test_proof_of_audit_full_flow_with_rewards() public {
        _stake(auditor1, 50_000e6);
        vm.prank(agent);
        registry.applyForListing(listingId, keccak256("meta"));
        vm.prank(auditor1);
        auditPool.coverListing(listingId, 10_000e6, 9000);

        address share = registry.approveListing(listingId, "Alpha Agent", "AAIX", 1_000_000e18);
        assertTrue(share != address(0));

        uint256 spread = auditPool.suggestedNoteSpreadBps(listingId);
        assertLt(spread, 2_000);

        usdc.approve(address(auditPool), 100_000e6);
        auditPool.fundAuditRewards(listingId, 100_000e6);

        uint256 before = usdc.balanceOf(auditor1);
        vm.prank(auditor1);
        auditPool.claimAuditReward(listingId);
        assertGt(usdc.balanceOf(auditor1), before);
    }

    function test_triggerDefault_compensates_note_holders() public {
        _approveWithPoolAndNotes();

        address shareAddr = registry.getListing(listingId).shareToken;
        AgentShareToken share = AgentShareToken(shareAddr);

        // Seed AMM: 100k shares @ 100k USDC (~$1/share)
        vm.startPrank(agent);
        share.approve(address(amm), type(uint256).max);
        share.transfer(address(this), 200_000e18);
        vm.stopPrank();
        share.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        amm.createPool(shareAddr, address(usdc), 100_000e18, 100_000e6);

        auditPool.captureBaseline(listingId);
        assertGt(auditPool.baselinePriceE18(listingId), 0);

        share.approve(address(amm), type(uint256).max);
        amm.swapShareForUsdc(shareAddr, 80_000e18, 1);
        auditPool.observeSharePrice(listingId);

        vm.warp(block.timestamp + 8 days);
        auditPool.observeSharePrice(listingId);

        auditPool.triggerDefault(listingId);
        assertTrue(auditPool.listingDefaulted(listingId));

        address noteToken = vault.listingNote(listingId);
        uint256 perNote = auditPool.compensationPerNoteE6(listingId);
        assertGt(perNote, 0);

        vm.startPrank(noteHolder);
        IERC20(noteToken).approve(address(auditPool), 50e18);
        uint256 before = usdc.balanceOf(noteHolder);
        auditPool.claimDefaultCompensation(listingId, 50e18);
        assertGt(usdc.balanceOf(noteHolder), before);
        vm.stopPrank();
    }

    function test_reject_releases_auditor_stake() public {
        _stake(auditor1, 50_000e6);
        vm.prank(agent);
        registry.applyForListing(listingId, keccak256("meta"));
        vm.prank(auditor1);
        auditPool.coverListing(listingId, 5_000e6, 8000);

        assertEq(auditPool.lockedStake(auditor1), 5_000e6);
        registry.rejectListing(listingId, "failed diligence");
        assertEq(auditPool.lockedStake(auditor1), 0);
        assertEq(auditPool.freeStake(auditor1), 50_000e6);
    }

    function test_unstake_only_free_balance() public {
        _stake(auditor1, 50_000e6);
        vm.prank(agent);
        registry.applyForListing(listingId, keccak256("meta"));
        vm.prank(auditor1);
        auditPool.coverListing(listingId, 10_000e6, 8500);

        vm.prank(auditor1);
        vm.expectRevert(AgentAuditPool.InsufficientFreeStake.selector);
        auditPool.unstake(50_000e6);

        vm.prank(auditor1);
        auditPool.unstake(40_000e6);
        assertEq(auditPool.staked(auditor1), 10_000e6);
    }

    function test_captureBaseline_reverts_after_window() public {
        _stake(auditor1, 50_000e6);
        vm.prank(agent);
        registry.applyForListing(listingId, keccak256("meta"));
        vm.prank(auditor1);
        auditPool.coverListing(listingId, 10_000e6, 9000);
        registry.approveListing(listingId, "Agent", "AGT", 1_000_000e18);

        address shareAddr = registry.getListing(listingId).shareToken;
        AgentShareToken share = AgentShareToken(shareAddr);
        vm.startPrank(agent);
        share.approve(address(amm), type(uint256).max);
        assertTrue(share.transfer(address(this), 100_000e18));
        vm.stopPrank();
        share.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        amm.createPool(shareAddr, address(usdc), 50_000e18, 50_000e6);

        vm.warp(block.timestamp + 31 days);
        vm.expectRevert(AgentAuditPool.DefaultConditionsNotMet.selector);
        auditPool.captureBaseline(listingId);
    }

    function test_triggerDefault_reverts_without_baseline() public {
        _stake(auditor1, 50_000e6);
        vm.prank(agent);
        registry.applyForListing(listingId, keccak256("meta"));
        vm.prank(auditor1);
        auditPool.coverListing(listingId, 10_000e6, 9000);
        registry.approveListing(listingId, "Agent", "AGT", 1_000_000e18);

        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(AgentAuditPool.BaselineNotSet.selector);
        auditPool.triggerDefault(listingId);
    }

    function test_observe_does_not_seed_baseline_after_rug() public {
        _stake(auditor1, 50_000e6);
        vm.prank(agent);
        registry.applyForListing(listingId, keccak256("meta"));
        vm.prank(auditor1);
        auditPool.coverListing(listingId, 10_000e6, 9000);
        registry.approveListing(listingId, "Agent", "AGT", 1_000_000e18);

        address shareAddr = registry.getListing(listingId).shareToken;
        AgentShareToken share = AgentShareToken(shareAddr);
        vm.startPrank(agent);
        share.approve(address(amm), type(uint256).max);
        assertTrue(share.transfer(address(this), 200_000e18));
        vm.stopPrank();
        share.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        amm.createPool(shareAddr, address(usdc), 100_000e18, 100_000e6);

        share.approve(address(amm), type(uint256).max);
        amm.swapShareForUsdc(shareAddr, 80_000e18, 1);
        auditPool.observeSharePrice(listingId);

        assertEq(auditPool.baselinePriceE18(listingId), 0);

        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(AgentAuditPool.BaselineNotSet.selector);
        auditPool.triggerDefault(listingId);
    }

    function test_notes_frozen_after_default() public {
        _approveWithPoolAndNotes();
        address shareAddr = registry.getListing(listingId).shareToken;
        AgentShareToken share = AgentShareToken(shareAddr);
        address noteToken = vault.listingNote(listingId);

        vm.startPrank(agent);
        share.approve(address(amm), type(uint256).max);
        assertTrue(share.transfer(address(this), 200_000e18));
        vm.stopPrank();
        share.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        amm.createPool(shareAddr, address(usdc), 100_000e18, 100_000e6);
        auditPool.captureBaseline(listingId);

        share.approve(address(amm), type(uint256).max);
        amm.swapShareForUsdc(shareAddr, 80_000e18, 1);
        auditPool.observeSharePrice(listingId);
        vm.warp(block.timestamp + 8 days);
        auditPool.observeSharePrice(listingId);
        auditPool.triggerDefault(listingId);

        vm.prank(noteHolder);
        vm.expectRevert(AgentNoteToken.TransfersFrozen.selector);
        IERC20(noteToken).transfer(address(0xBEEF), 1e18);
    }

    function test_double_reject_release_is_idempotent() public {
        _stake(auditor1, 50_000e6);
        vm.prank(agent);
        registry.applyForListing(listingId, keccak256("meta"));
        vm.prank(auditor1);
        auditPool.coverListing(listingId, 5_000e6, 8000);

        registry.rejectListing(listingId, "no");
        assertEq(auditPool.lockedStake(auditor1), 0);

        // Second reject is a registry no-op; coverage release stays idempotent.
        registry.rejectListing(listingId, "again");
        assertEq(auditPool.lockedStake(auditor1), 0);
    }

    function _stake(address auditor, uint256 amount) internal {
        vm.startPrank(auditor);
        usdc.approve(address(auditPool), amount);
        auditPool.stake(amount);
        vm.stopPrank();
    }

    function _approveWithPoolAndNotes() internal {
        _stake(auditor1, 50_000e6);
        vm.prank(agent);
        registry.applyForListing(listingId, keccak256("meta"));
        vm.prank(auditor1);
        auditPool.coverListing(listingId, 20_000e6, 9200);
        registry.approveListing(listingId, "Agent", "AGT", 1_000_000e18);

        vm.startPrank(agent);
        usdc.approve(address(registry), 100_000e6);
        registry.issueAgentNotes(
            listingId,
            "Agent Note",
            "AN",
            100e18,
            uint64(block.timestamp + 90 days),
            1e6,
            100_000e6
        );
        vm.stopPrank();

        // Agent holds notes; transfer some to note holder for compensation test
        address noteToken = vault.listingNote(listingId);
        vm.prank(agent);
        IERC20(noteToken).transfer(noteHolder, 50e18);
    }
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
