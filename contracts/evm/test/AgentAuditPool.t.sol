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
        amm.setQuoteToken(address(usdc));
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

        // Baseline is a TWAP over MIN_OBSERVATIONS_FOR_BASELINE independent samples: one
        // sample plus elapsed time was the manipulable shape (whoever observed once at a
        // sandwiched price chose both the number and its weight).
        _accumulateBaselineObservations();
        auditPool.captureBaseline(listingId);
        assertGt(auditPool.baselinePriceE18(listingId), 0);

        share.approve(address(amm), type(uint256).max);
        amm.swapShareForUsdc(shareAddr, 80_000e18, 1);

        // A genuine collapse is still detected — but now it has to be detected the honest way:
        // by the crashed price actually persisting through observations, not by one snapshot
        // inheriting the weight of a week of silence. Poking daily is what an interested party
        // (a note holder, the auditor, a keeper) does.
        _observeDaily(9);

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
        _accumulateBaselineObservations();
        auditPool.captureBaseline(listingId);

        share.approve(address(amm), type(uint256).max);
        amm.swapShareForUsdc(shareAddr, 80_000e18, 1);
        _observeDaily(9);
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

    /// Observe once a day for `days_` days. (Under the old sample-and-hold average a single sample
    /// may weight, so accumulating real crashed time takes real samples.
    function _observeDaily(uint256 days_) internal {
        for (uint256 i = 0; i < days_; i++) {
            vm.warp(block.timestamp + 1 days);
            auditPool.observeSharePrice(listingId);
        }
    }

    /// Observe the pool enough times, spread over enough time, that a baseline may be
    /// captured: MIN_OBSERVATIONS_FOR_BASELINE samples and MIN_OBSERVATION_WINDOW of
    /// accumulated (interval-capped) time.
    function _accumulateBaselineObservations() internal {
        for (uint256 i = 0; i < auditPool.MIN_OBSERVATIONS_FOR_BASELINE(); i++) {
            auditPool.observeSharePrice(listingId);
            vm.warp(block.timestamp + 12 hours);
        }
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

    // ── SEC regressions: baseline must be a TWAP over a real window, never spot ──
    function test_captureBaseline_requires_observation_window() public {
        _approveWithPoolAndNotes();
        address shareAddr = registry.getListing(listingId).shareToken;
        AgentShareToken share = AgentShareToken(shareAddr);
        vm.startPrank(agent);
        share.approve(address(amm), type(uint256).max);
        share.transfer(address(this), 200_000e18);
        vm.stopPrank();
        share.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        amm.createPool(shareAddr, address(usdc), 100_000e18, 100_000e6);

        // No accumulated observation time → can't snapshot a (manipulable) spot baseline.
        auditPool.observeSharePrice(listingId);
        vm.expectRevert(AgentAuditPool.DefaultConditionsNotMet.selector);
        auditPool.captureBaseline(listingId);

        // Elapsed time alone is still not enough: a second sample satisfies the window but
        // not MIN_OBSERVATIONS_FOR_BASELINE, and a one-sample baseline is the thing being
        // prevented.
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(AgentAuditPool.DefaultConditionsNotMet.selector);
        auditPool.captureBaseline(listingId);

        // Enough independent samples → baseline is set from the TWAP.
        _accumulateBaselineObservations();
        auditPool.captureBaseline(listingId);
        assertGt(auditPool.baselinePriceE18(listingId), 0);
    }

    function test_default_when_baseline_never_established() public {
        _approveWithPoolAndNotes();  // no AMM pool seeded → baseline can never be captured
        // Within the capture window, a missing baseline blocks default (capture still possible).
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(AgentAuditPool.BaselineNotSet.selector);
        auditPool.triggerDefault(listingId);
        // Past the capture window with no baseline → defaults (auditor stake not locked forever).
        vm.warp(block.timestamp + 31 days);
        auditPool.triggerDefault(listingId);
        assertTrue(auditPool.listingDefaulted(listingId));
    }


    // ── 2026-08 audit: the CapShare price oracle ────────────────────────────
    //
    // A default pays slashed auditor stake to NOTE HOLDERS, and `issueAgentNotes` mints the
    // whole series to the agent — so the insured party profits from a default on its own
    // listing. The price that decides it comes from PulseAMM reserves, which made three
    // things load-bearing: who may open the pool, how much liquidity it must hold, and
    // whether a stale observation can stand in for the market.

    function test_only_a_market_maker_may_open_the_oracle_pool() public {
        _stake(auditor1, 50_000e6);
        vm.prank(agent);
        registry.applyForListing(listingId, keccak256("meta"));
        vm.prank(auditor1);
        auditPool.coverListing(listingId, 20_000e6, 9200);
        registry.approveListing(listingId, "Agent", "AGT", 1_000_000e18);
        address shareAddr = registry.getListing(listingId).shareToken;

        // The first caller for a share token fixes the pool forever, so this used to be a
        // front-run: whoever opened it defined the oracle. The allow-list existed but was
        // never read.
        vm.startPrank(agent);
        AgentShareToken(shareAddr).approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        vm.expectRevert(PulseAMM.Unauthorized.selector);
        amm.createPool(shareAddr, address(usdc), 100_000e18, 100_000e6);
        vm.stopPrank();

        // Allow-listed, and it works.
        amm.setMarketMaker(agent, true);
        vm.prank(agent);
        amm.createPool(shareAddr, address(usdc), 100_000e18, 100_000e6);
        (,, uint256 rShare,, bool active) = amm.pools(shareAddr);
        assertTrue(active);
        assertEq(rShare, 100_000e18);
    }

    function test_a_dust_pool_cannot_become_the_oracle() public {
        _stake(auditor1, 50_000e6);
        vm.prank(agent);
        registry.applyForListing(listingId, keccak256("meta"));
        vm.prank(auditor1);
        auditPool.coverListing(listingId, 20_000e6, 9200);
        registry.approveListing(listingId, "Agent", "AGT", 1_000_000e18);
        address shareAddr = registry.getListing(listingId).shareToken;

        vm.prank(agent);
        AgentShareToken(shareAddr).transfer(address(this), 200_000e18);
        AgentShareToken(shareAddr).approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);

        // MIN_RESERVE is 1000 RAW units — 0.001 USDC. A pool at that size is free to move,
        // and (because `active` blocks re-creation) it would have been the permanent oracle.
        vm.expectRevert(PulseAMM.BelowMinimumLiquidity.selector);
        amm.createPool(shareAddr, address(usdc), 2000e18, 2000);
        assertEq(amm.MIN_INITIAL_USDC(), 1_000e6);
    }

    /// The load-bearing one: `_observeSharePrice` credits a whole unobserved interval at the
    /// price recorded at its START, and anyone may record one. So a flash-crash, one
    /// `observeSharePrice`, an immediate arbitrage back, then silence, wrote a price into the
    /// TWAP that the market never held — and the agent could claim the auditors' stake.
    /// A baseline must never be one sample. Whoever calls captureBaseline picks the moment, so
    /// the defence is that the moment is worth little: the value is an average of several
    /// independent reads.
    function test_baseline_needs_several_independent_samples() public {
        _approveWithPoolAndNotes();
        address shareAddr = registry.getListing(listingId).shareToken;
        AgentShareToken share = AgentShareToken(shareAddr);
        vm.startPrank(agent);
        share.approve(address(amm), type(uint256).max);
        share.transfer(address(this), 200_000e18);
        vm.stopPrank();
        share.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        amm.createPool(shareAddr, address(usdc), 100_000e18, 100_000e6);

        // One sample, then all the elapsed time in the world.
        auditPool.observeSharePrice(listingId);
        vm.warp(block.timestamp + 20 days);
        assertEq(auditPool.observationCount(listingId), 1);
        vm.expectRevert(AgentAuditPool.DefaultConditionsNotMet.selector);
        auditPool.captureBaseline(listingId);

        _accumulateBaselineObservations();
        auditPool.captureBaseline(listingId);
        assertGt(auditPool.baselinePriceE18(listingId), 0);
        assertGe(auditPool.observationCount(listingId), auditPool.MIN_OBSERVATIONS_FOR_BASELINE());
    }

    /// The weight of one sample is bounded, so waiting is not a way to buy influence.
    function _seededPool() internal returns (address shareAddr) {
        _approveWithPoolAndNotes();
        shareAddr = registry.getListing(listingId).shareToken;
        AgentShareToken share = AgentShareToken(shareAddr);
        vm.startPrank(agent);
        share.approve(address(amm), type(uint256).max);
        share.transfer(address(this), 400_000e18);
        vm.stopPrank();
        share.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        amm.createPool(shareAddr, address(usdc), 100_000e18, 100_000e6);
    }

    /// A price counts for as long as it held in the pool — not until somebody observes.
    function test_a_price_counts_for_exactly_as_long_as_it_held() public {
        address shareAddr = _seededPool();
        auditPool.observeSharePrice(listingId);
        vm.warp(block.timestamp + 1 days);
        uint256 out = amm.swapShareForUsdc(shareAddr, 100_000e18, 1); // price falls to ~1/4
        vm.warp(block.timestamp + 1 days);
        amm.swapUsdcForShare(shareAddr, out, 1);                    // back to ~1
        vm.warp(block.timestamp + 30 days);                          // silence
        auditPool.observeSharePrice(listingId);
        // 31 days near 1.0 and 1 day near 0.25: the average stays near 1, and the
        // 30 silent days count as what they were, not as the last sample.
        uint256 twap = auditPool.twapPriceE18(listingId);
        assertGt(twap, 940_000);
        assertLt(twap, 990_000);
    }

    function test_two_observations_in_one_block_are_one_sample() public {
        _seededPool();
        auditPool.observeSharePrice(listingId);
        auditPool.observeSharePrice(listingId);
        assertEq(auditPool.observationCount(listingId), 1);
    }

    /// Before the pool existed the oracle read zero, and that time entered the average: a
    /// baseline captured two seconds after the pool opened was ~0, and nothing could ever
    /// fall 50% below it.
    function test_time_before_the_pool_does_not_enter_the_baseline() public {
        _approveWithPoolAndNotes();
        address shareAddr = registry.getListing(listingId).shareToken;
        auditPool.observeSharePrice(listingId);   // no pool yet: records nothing
        vm.warp(block.timestamp + 1 days);
        AgentShareToken share = AgentShareToken(shareAddr);
        vm.startPrank(agent);
        share.approve(address(amm), type(uint256).max);
        share.transfer(address(this), 200_000e18);
        vm.stopPrank();
        share.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        amm.createPool(shareAddr, address(usdc), 100_000e18, 100_000e6);
        auditPool.observeSharePrice(listingId);
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);
        auditPool.observeSharePrice(listingId);
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);
        vm.expectRevert(AgentAuditPool.DefaultConditionsNotMet.selector);
        auditPool.captureBaseline(listingId);
    }

    /// The 2026-10-08 review's PoC against block-start pricing alone: crash as the last swap
    /// of one block, observe and recover in the next, once a day for nine days, then crash
    /// again before claiming the default. Each crash stood for two seconds.
    function test_a_crash_held_across_one_block_cannot_manufacture_a_default() public {
        address shareAddr = _seededPool();
        _accumulateBaselineObservations();
        auditPool.captureBaseline(listingId);
        uint256 baseline = auditPool.baselinePriceE18(listingId);

        for (uint256 d = 0; d < 9; d++) {
            vm.warp(block.timestamp + 1 days);
            vm.roll(block.number + 1);
            uint256 out = amm.swapShareForUsdc(shareAddr, 80_000e18, 1);
            vm.warp(block.timestamp + 2);
            vm.roll(block.number + 1);
            auditPool.observeSharePrice(listingId);
            amm.swapUsdcForShare(shareAddr, out, 1);
        }
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        amm.swapShareForUsdc(shareAddr, 80_000e18, 1);
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);
        assertGt(auditPool.twapSinceBaselineE18(listingId) * 10_000, baseline * 5_000);
        vm.expectRevert(AgentAuditPool.DefaultConditionsNotMet.selector);
        auditPool.triggerDefault(listingId);
        assertFalse(auditPool.listingDefaulted(listingId));
    }

    /// The spot check in triggerDefault read the pool inside the trigger transaction, and each
    /// observation read it inside the observer's transaction — so one atomic crash, observe,
    /// recover per day poisoned the TWAP, and one more atomic crash inside the trigger call
    /// satisfied the "market is still down" check. Every price the pool's oracle reads is now
    /// the reserves as they stood when the block began.
    function test_atomic_crashes_cannot_poison_the_twap_or_the_trigger() public {
        _approveWithPoolAndNotes();
        address shareAddr = registry.getListing(listingId).shareToken;
        AgentShareToken share = AgentShareToken(shareAddr);

        vm.startPrank(agent);
        share.approve(address(amm), type(uint256).max);
        share.transfer(address(this), 400_000e18);
        vm.stopPrank();
        share.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        amm.createPool(shareAddr, address(usdc), 100_000e18, 100_000e6);

        _accumulateBaselineObservations();
        auditPool.captureBaseline(listingId);
        uint256 baseline = auditPool.baselinePriceE18(listingId);

        // Nine days of one atomic crash -> observe -> recover each, nobody else observing.
        for (uint256 d = 0; d < 9; d++) {
            vm.warp(block.timestamp + 1 days);
            uint256 out = amm.swapShareForUsdc(shareAddr, 80_000e18, 1);
            auditPool.observeSharePrice(listingId);
            amm.swapUsdcForShare(shareAddr, out, 1);
        }
        assertGt(auditPool.twapPriceE18(listingId) * 10_000, baseline * 5_000,
                 "atomic crashes must not move the TWAP");

        // And a crash inside the very call that claims the default proves nothing.
        vm.warp(block.timestamp + 1 days);
        amm.swapShareForUsdc(shareAddr, 80_000e18, 1);
        vm.expectRevert(AgentAuditPool.DefaultConditionsNotMet.selector);
        auditPool.triggerDefault(listingId);
        assertFalse(auditPool.listingDefaulted(listingId));
    }

    function test_flash_crash_then_recovery_cannot_trigger_a_default() public {
        _approveWithPoolAndNotes();
        address shareAddr = registry.getListing(listingId).shareToken;
        AgentShareToken share = AgentShareToken(shareAddr);

        vm.startPrank(agent);
        share.approve(address(amm), type(uint256).max);
        share.transfer(address(this), 200_000e18);
        vm.stopPrank();
        share.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        amm.createPool(shareAddr, address(usdc), 100_000e18, 100_000e6);

        _accumulateBaselineObservations();
        auditPool.captureBaseline(listingId);
        uint256 baseline = auditPool.baselinePriceE18(listingId);
        assertGt(baseline, 0);

        // Crash it, snapshot the crash, then put the price back in the same block.
        uint256 usdcOut = amm.swapShareForUsdc(shareAddr, 80_000e18, 1);
        auditPool.observeSharePrice(listingId);
        amm.swapUsdcForShare(shareAddr, usdcOut, 1);

        // Silence, which USED to be enough: one crashed snapshot took the weight of the whole
        // gap and dragged the average under the drawdown threshold. The pool's accumulator
        // weights a price by how long it actually held, so a crash that never outlived its
        // transaction weighs nothing at all.
        vm.warp(block.timestamp + 8 days);
        auditPool.observeSharePrice(listingId);
        assertGt(
            auditPool.twapPriceE18(listingId) * 10_000,
            baseline * 5_000,
            "a single sandwiched sample plus silence must NOT be able to move the TWAP "
            "below the drawdown threshold"
        );

        // …but the market recovered, so there is no default to claim.
        vm.expectRevert(AgentAuditPool.DefaultConditionsNotMet.selector);
        auditPool.triggerDefault(listingId);
        assertFalse(auditPool.listingDefaulted(listingId));
    }

}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
