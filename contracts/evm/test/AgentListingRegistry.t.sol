// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {AgentCollateralVault} from "../src/AgentCollateralVault.sol";
import {AgentListingRegistry} from "../src/AgentListingRegistry.sol";
import {AgentShareToken} from "../src/AgentShareToken.sol";
import {IAgentListingRegistry} from "../src/interfaces/IAgentListingRegistry.sol";

contract MockUSDC6 is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract AgentListingRegistryTest is Test {
    AgentCollateralVault vault;
    AgentListingRegistry registry;
    MockUSDC6 usdc;
    address agent = address(0xA1);
    address auditor = address(0xA2);
    bytes32 listingId = keccak256("x");

    function setUp() public {
        usdc = new MockUSDC6();
        vault = new AgentCollateralVault(address(usdc));
        registry = new AgentListingRegistry(address(vault), address(usdc));
        vault.setRegistry(address(registry));
        registry.setAuditor(auditor, true);
    }

    /// The squat fix let the operator evict an unapproved id only while no collateral sat on
    /// it — and anyone could deposit one base unit to any existing id. Eviction now returns
    /// the id's collateral to its agent wallet instead of refusing, and before approval only
    /// that wallet may fund the id, so the refund always goes back to whoever paid it.
    function test_one_base_unit_no_longer_blocks_an_eviction() public {
        address squatter = address(0xBAD);
        deal(address(usdc), squatter, 10);
        vm.startPrank(squatter);
        registry.applyForListing(listingId, bytes32(uint256(1)));
        usdc.approve(address(vault), 1);
        vault.depositCollateral(listingId, 1);
        vm.stopPrank();

        registry.evictUnapprovedListing(listingId);
        assertEq(registry.getListing(listingId).agentWallet, address(0), "the id is free again");
        assertEq(vault.availableCollateral(listingId), 0);
        // Pulled, not pushed: the eviction cannot be blocked by a wallet that refuses USDC.
        assertEq(vault.evictionRefunds(squatter), 1);
        vm.prank(squatter);
        vault.claimEvictionRefund();
        assertEq(usdc.balanceOf(squatter), 10, "the squatter's dust went back to the squatter");

        vm.prank(agent);
        registry.applyForListing(listingId, bytes32(uint256(2)));
        assertEq(registry.getListing(listingId).agentWallet, agent);
    }

    function test_before_approval_only_the_agent_funds_its_id() public {
        vm.prank(agent);
        registry.applyForListing(listingId, bytes32(uint256(1)));
        address stranger = address(0x5EE);
        deal(address(usdc), stranger, 1_000);
        vm.startPrank(stranger);
        usdc.approve(address(vault), 1_000);
        vm.expectRevert(AgentCollateralVault.NotListingAgent.selector);
        vault.depositCollateral(listingId, 1_000);
        vm.stopPrank();
    }

    function test_a_rejected_id_is_still_funded_only_by_its_agent() public {
        vm.prank(agent);
        registry.applyForListing(listingId, bytes32(uint256(1)));
        registry.rejectListing(listingId, "low quality");
        address stranger = address(0x5EE);
        deal(address(usdc), stranger, 1_000);
        vm.startPrank(stranger);
        usdc.approve(address(vault), 1_000);
        vm.expectRevert(AgentCollateralVault.NotListingAgent.selector);
        vault.depositCollateral(listingId, 1_000);
        vm.stopPrank();
    }

    function test_reject_listing() public {
        vm.prank(agent);
        registry.applyForListing(listingId, bytes32(uint256(1)));
        registry.rejectListing(listingId, "low quality");
        assertEq(
            uint8(registry.getListing(listingId).status),
            uint8(IAgentListingRegistry.ListingStatus.Rejected)
        );
    }

    function test_cannot_approve_below_min_audit_score() public {
        vm.prank(agent);
        registry.applyForListing(listingId, bytes32(uint256(1)));
        vm.prank(auditor);
        registry.recordAudit(listingId, 5000);
        vm.expectRevert();
        registry.approveListing(listingId, "A", "A", 1e18);
    }

    function test_pause_blocks_apply() public {
        registry.pause();
        vm.prank(agent);
        vm.expectRevert();
        registry.applyForListing(listingId, bytes32(uint256(1)));
    }

    function test_share_trading_locked_until_enabled() public {
        AgentShareToken token = new AgentShareToken(
            address(this), listingId, "A", "A", 1e24
        );
        token.mintTo(agent, 1e18);
        vm.prank(agent);
        vm.expectRevert();
        token.transfer(address(0xBEEF), 1e18);
        token.enableTrading();
        vm.prank(agent);
        token.transfer(address(0xBEEF), 1e18);
        assertEq(token.balanceOf(address(0xBEEF)), 1e18);
    }

    function test_vesting_locks_founder_tranche_until_cliff() public {
        vm.prank(agent);
        registry.applyForListing(listingId, bytes32(uint256(1)));
        vm.prank(auditor);
        registry.recordAudit(listingId, 9000);

        // lock 80% of a 1,000,000 supply for 90 days
        uint256 supply = 1_000_000e18;
        address shareAddr =
            registry.approveListingWithVesting(listingId, "A", "A", supply, 8_000, 90 days);
        AgentShareToken token = AgentShareToken(shareAddr);

        assertEq(token.lockedBalanceOf(agent), 800_000e18);

        // can move the unlocked 20% …
        vm.prank(agent);
        token.transfer(address(0xBEEF), 200_000e18);

        // … but not a single token more of the locked tranche
        vm.prank(agent);
        vm.expectRevert(AgentShareToken.TokensLocked.selector);
        token.transfer(address(0xBEEF), 1);

        // after the cliff the whole balance is free
        vm.warp(block.timestamp + 90 days);
        assertEq(token.lockedBalanceOf(agent), 0);
        vm.prank(agent);
        token.transfer(address(0xBEEF), 800_000e18);
        assertEq(token.balanceOf(address(0xBEEF)), 1_000_000e18);
    }
}
