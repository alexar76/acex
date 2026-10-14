// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {AgentCollateralVault} from "../src/AgentCollateralVault.sol";
import {AgentListingRegistry} from "../src/AgentListingRegistry.sol";
import {AgentLendingPool} from "../src/AgentLendingPool.sol";

contract MockUSDC2 is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @notice 2026-08 audit — collateral must not be pledged twice.
///
/// `AgentListingRegistry.issueAgentNotes` credited `collateralUsdc` and then called
/// `vault.lockForNote(listingId, supply * faceValue / 1e18)`. Nothing tied the second
/// number to the first, and `lockForNote` knew nothing about lending-pool debt — so a
/// note series could be backed by USDC that was already collateralising a loan. It was
/// also callable by ANYONE: `collateralUsdc = 0` needs no allowance, because a zero-value
/// transferFrom always succeeds.
///
/// Three attacks, all reproduced against the pre-fix contracts, all asserted closed here.
contract CollateralDoublePledgeTest is Test {
    MockUSDC2 usdc;
    AgentCollateralVault vault;
    AgentListingRegistry registry;
    AgentLendingPool pool;

    address agent = address(0xA1);
    address auditor = address(0xA2);
    address lender = address(0xA3);
    address attacker = address(0xBAD);

    bytes32 listingId = keccak256("agent-alpha");
    uint64 maturity;

    function setUp() public {
        usdc = new MockUSDC2();
        vault = new AgentCollateralVault(address(usdc));
        registry = new AgentListingRegistry(address(vault), address(usdc));
        vault.setRegistry(address(registry));
        pool = new AgentLendingPool(address(usdc), address(vault), address(registry));
        vault.setLendingPool(address(pool));
        registry.setAuditor(auditor, true);
        maturity = uint64(block.timestamp + 30 days);

        usdc.mint(agent, 10_000e6);
        usdc.mint(lender, 100_000e6);
        usdc.mint(attacker, 100_000e6);

        vm.prank(agent);
        registry.applyForListing(listingId, keccak256("meta"));
        vm.prank(auditor);
        registry.recordAudit(listingId, 9000);
        registry.approveListing(listingId, "Agent", "AGT", 1e24);

        // A lender funds the pool; the agent posts collateral and takes a HEALTHY loan.
        vm.startPrank(lender);
        usdc.approve(address(pool), 50_000e6);
        pool.deposit(50_000e6);
        vm.stopPrank();

        vm.startPrank(agent);
        usdc.approve(address(vault), 1_000e6);
        vault.depositCollateral(listingId, 1_000e6);
        vm.stopPrank();

        vm.prank(agent);
        pool.borrow(listingId, 600e6); // 60% LTV, under the 65% cap
    }

    /// A stranger pushed a healthy position into liquidation by locking its collateral
    /// behind notes, then took the 8% bonus (measured: +24 USDC on a 1 000 USDC position).
    function test_stranger_cannot_issue_notes_for_someone_elses_listing() public {
        assertFalse(pool.isLiquidatable(listingId), "position must start healthy");

        vm.prank(attacker);
        vm.expectRevert(AgentListingRegistry.NotListingAgent.selector);
        registry.issueAgentNotes(listingId, "Note", "NOTE", 500e18, maturity, 1e6, 0);

        assertEq(vault.availableCollateral(listingId), 1_000e6, "collateral untouched");
        assertFalse(pool.isLiquidatable(listingId), "still healthy");
    }

    /// The destructive variant: locking ALL collateral left a debt with nothing to seize,
    /// so `liquidate` reverted on `seized == 0` and the loss had no recovery path at all
    /// (the bad-debt write-off is only reachable from inside a successful liquidation).
    function test_agent_cannot_lock_collateral_that_backs_its_own_loan() public {
        vm.prank(agent);
        vm.expectRevert(AgentListingRegistry.NotesUndercollateralized.selector);
        registry.issueAgentNotes(listingId, "Note", "NOTE", 1_000e18, maturity, 1e6, 0);

        assertEq(vault.availableCollateral(listingId), 1_000e6);
        assertGt(pool.debtOf(listingId), 0);
    }

    /// Undercollateralised issuance is refused even with SOME collateral posted: the face
    /// value has to be covered by the USDC that arrives with the series.
    function test_partial_collateral_is_not_enough() public {
        vm.startPrank(agent);
        usdc.approve(address(registry), 100e6);
        vm.expectRevert(AgentListingRegistry.NotesUndercollateralized.selector);
        registry.issueAgentNotes(listingId, "Note", "NOTE", 500e18, maturity, 1e6, 100e6);
        vm.stopPrank();
    }

    /// Defence in depth, tested directly. With the registry check in place this guard is
    /// unreachable through `issueAgentNotes` — the fresh collateral is credited BEFORE the
    /// lock, so the remainder can never fall below the pre-existing balance. It exists for
    /// any future caller of `lockForNote`, so it is exercised against the vault itself.
    function test_vault_refuses_a_lock_that_would_strand_pool_debt() public {
        AgentCollateralVault v = new AgentCollateralVault(address(usdc));
        v.setRegistry(address(this)); // this test acts as the registry
        v.setLendingPool(address(new MockDebtPool(600e6)));

        v.creditCollateral(listingId, 1_000e6);
        // Leaving 300 behind a 600 debt is far past the 65% origination LTV.
        vm.expectRevert(AgentCollateralVault.CollateralPledgedToPool.selector);
        v.lockForNote(listingId, 700e6);

        // Leaving 1 000 behind the same debt is fine (60% LTV).
        v.creditCollateral(listingId, 700e6);
        v.lockForNote(listingId, 700e6);
        (uint256 free, uint256 locked) = v.positions(listingId);
        assertEq(free, 1_000e6);
        assertEq(locked, 700e6);
    }

    /// The feature still works: a properly funded series is issued, the collateral behind
    /// the loan is untouched, and the position stays exactly as healthy as it was.
    function test_properly_collateralised_issuance_still_works() public {
        uint256 healthBefore = pool.healthFactorBps(listingId);

        vm.startPrank(agent);
        usdc.approve(address(registry), 500e6);
        address note = registry.issueAgentNotes(
            listingId, "Note", "NOTE", 500e18, maturity, 1e6, 500e6
        );
        vm.stopPrank();

        assertTrue(note != address(0));
        assertEq(vault.availableCollateral(listingId), 1_000e6, "loan collateral untouched");
        assertEq(pool.healthFactorBps(listingId), healthBefore, "health unchanged");
        assertFalse(pool.isLiquidatable(listingId));

        // …and the note holder can redeem the full face value at maturity.
        vm.warp(maturity);
        vm.prank(agent);
        vault.redeemNote(note, 500e18);
        assertEq(usdc.balanceOf(agent) , 10_000e6 - 1_000e6 - 500e6 + 600e6 + 500e6);
    }

    /// Repeat issuance is now additive rather than a shared pot: each series brings its
    /// own backing, so Σ locked always covers Σ face value.
    function test_repeat_issuance_brings_its_own_backing() public {
        vm.startPrank(agent);
        usdc.approve(address(registry), 1_000e6);
        registry.issueAgentNotes(listingId, "N1", "N1", 300e18, maturity, 1e6, 300e6);
        registry.issueAgentNotes(listingId, "N2", "N2", 300e18, maturity, 1e6, 300e6);
        vm.stopPrank();

        (uint256 free, uint256 locked) = vault.positions(listingId);
        assertEq(locked, 600e6, "both series fully backed");
        assertEq(free, 1_000e6, "loan collateral untouched");
    }

    /// The lending pool is the only caller of seizeTo, so its setter must be one-shot.
    function test_lending_pool_setter_is_one_shot() public {
        vm.expectRevert(AgentCollateralVault.LendingPoolAlreadySet.selector);
        vault.setLendingPool(address(0xDEADBEEF));
    }
}

/// @dev Minimal stand-in for {AgentLendingPool}'s debt view, for the vault-level guard test.
contract MockDebtPool {
    uint256 private immutable _debt;

    constructor(uint256 debt_) {
        _debt = debt_;
    }

    function debtOf(bytes32) external view returns (uint256) {
        return _debt;
    }

    function BPS() external pure returns (uint256) {
        return 10_000;
    }

    function MAX_LTV_BPS() external pure returns (uint256) {
        return 6_500;
    }
}
