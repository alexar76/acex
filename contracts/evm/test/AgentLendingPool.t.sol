// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {AgentCollateralVault} from "../src/AgentCollateralVault.sol";
import {AgentListingRegistry} from "../src/AgentListingRegistry.sol";
import {AgentLendingPool} from "../src/AgentLendingPool.sol";
import {IAgentListingRegistry} from "../src/interfaces/IAgentListingRegistry.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @notice Money-market behaviour of {AgentLendingPool}: interest accrual, LTV,
///         funded/partial liquidation with bonus, pool solvency, bad-debt write-off,
///         collateral withdrawal, share-inflation guard and reserves.
contract AgentLendingPoolTest is Test {
    MockUSDC usdc;
    AgentCollateralVault vault;
    AgentListingRegistry registry;
    AgentLendingPool pool;

    address agent = address(0xA1);
    address auditor = address(0xA2);
    address lender = address(0xA3);
    address liquidator = address(0xA4);

    bytes32 listingId = keccak256("agent-alpha");

    function setUp() public {
        usdc = new MockUSDC();
        vault = new AgentCollateralVault(address(usdc));
        registry = new AgentListingRegistry(address(vault), address(usdc));
        vault.setRegistry(address(registry));
        pool = new AgentLendingPool(address(usdc), address(vault), address(registry));
        vault.setLendingPool(address(pool));

        registry.setAuditor(auditor, true);

        usdc.mint(agent, 2_000_000e6);
        usdc.mint(lender, 2_000_000e6);
        usdc.mint(liquidator, 2_000_000e6);

        _approveListing();
    }

    // ───────────────────────── helpers ─────────────────────────
    function _approveListing() internal {
        vm.prank(agent);
        registry.applyForListing(listingId, keccak256("meta"));
        vm.prank(auditor);
        registry.recordAudit(listingId, 9000);
        registry.approveListing(listingId, "Agent", "AGT", 1e24);
    }

    function _depositCollateral(uint256 amount) internal {
        vm.startPrank(agent);
        usdc.approve(address(vault), amount);
        vault.depositCollateral(listingId, amount);
        vm.stopPrank();
    }

    function _lenderDeposit(uint256 amount) internal {
        vm.startPrank(lender);
        usdc.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();
    }

    function _borrow(uint256 amount) internal {
        vm.prank(agent);
        pool.borrow(listingId, amount);
    }

    // ───────────────────────── LTV ─────────────────────────────
    function test_borrow_respects_origination_ltv() public {
        _depositCollateral(100_000e6);
        _lenderDeposit(500_000e6);

        // exactly 65% LTV is allowed
        _borrow(65_000e6);
        assertEq(pool.debtOf(listingId), 65_000e6);

        // one wei over the cap reverts
        vm.prank(agent);
        vm.expectRevert(AgentLendingPool.InsufficientCollateral.selector);
        pool.borrow(listingId, 1e6);
    }

    // ───────────────────────── interest ────────────────────────
    function test_interest_accrues_on_debt() public {
        _depositCollateral(100_000e6);
        _lenderDeposit(500_000e6);
        _borrow(50_000e6);

        vm.warp(block.timestamp + 365 days);
        pool.accrue();

        // 10% simple APR → ~55,000 USDC
        assertApproxEqAbs(pool.debtOf(listingId), 55_000e6, 5e6);
    }

    function test_full_repay_clears_debt_with_interest() public {
        _depositCollateral(100_000e6);
        _lenderDeposit(500_000e6);
        _borrow(50_000e6);

        vm.warp(block.timestamp + 180 days);
        pool.accrue();
        uint256 debt = pool.debtOf(listingId);
        assertGt(debt, 50_000e6);

        vm.startPrank(agent);
        usdc.approve(address(pool), debt);
        pool.repay(listingId, debt);
        vm.stopPrank();

        assertEq(pool.debtOf(listingId), 0);
        assertEq(pool.listingBorrower(listingId), address(0));
    }

    // ───────────────────────── lender yield ────────────────────
    function test_lender_earns_yield() public {
        _depositCollateral(100_000e6);
        _lenderDeposit(100_000e6);
        _borrow(50_000e6);

        vm.warp(block.timestamp + 365 days);

        // agent repays principal + interest → pool holds cash again
        uint256 debt = pool.debtOf(listingId);
        vm.startPrank(agent);
        usdc.approve(address(pool), debt);
        pool.repay(listingId, debt);
        vm.stopPrank();

        uint256 shares = pool.lenderShares(lender);
        uint256 before = usdc.balanceOf(lender);
        vm.prank(lender);
        pool.withdraw(shares);
        uint256 gained = usdc.balanceOf(lender) - before;

        // lender gets back more than the 100k deposited (interest minus reserve cut)
        assertGt(gained, 100_000e6);
        // protocol kept a reserve slice
        assertGt(pool.totalReserves(), 0);
    }

    // ───────────────────────── collateral withdrawal ───────────
    function test_withdraw_collateral_respects_health() public {
        _depositCollateral(100_000e6);
        _lenderDeposit(500_000e6);
        _borrow(50_000e6); // 50% LTV

        // remaining 80k still covers 50k at 65% LTV → ok
        vm.prank(agent);
        pool.withdrawCollateral(listingId, 20_000e6, agent);
        assertEq(vault.availableCollateral(listingId), 80_000e6);

        // pulling another 5k (→75k) breaks the 65% origination LTV
        vm.prank(agent);
        vm.expectRevert(AgentLendingPool.InsufficientCollateral.selector);
        pool.withdrawCollateral(listingId, 5_000e6, agent);
    }

    function test_withdraw_collateral_only_agent() public {
        _depositCollateral(100_000e6);
        vm.prank(liquidator);
        vm.expectRevert(AgentLendingPool.Unauthorized.selector);
        pool.withdrawCollateral(listingId, 1e6, liquidator);
    }

    // ───────────────────────── liquidation ─────────────────────
    function test_liquidation_reverts_when_healthy() public {
        pool.setBorrowRate(5_000); // 50% APR
        _depositCollateral(100_000e6);
        _lenderDeposit(500_000e6);
        _borrow(65_000e6);

        vm.startPrank(liquidator);
        usdc.approve(address(pool), 100_000e6);
        vm.expectRevert(AgentLendingPool.Healthy.selector);
        pool.liquidate(listingId, 10_000e6);
        vm.stopPrank();
    }

    function test_partial_liquidation_bonus_and_solvency() public {
        pool.setBorrowRate(5_000); // 50% APR
        _depositCollateral(100_000e6);
        _lenderDeposit(500_000e6);
        _borrow(65_000e6);

        // after 1y debt ≈ 97,500 > 80k threshold → liquidatable
        vm.warp(block.timestamp + 365 days);
        pool.accrue();
        assertTrue(pool.isLiquidatable(listingId));

        uint256 debt = pool.debtOf(listingId);
        uint256 expectedRepaid = debt / 2; // close factor 50%
        uint256 expectedSeized = (expectedRepaid * 10_800) / 10_000; // +8% bonus

        uint256 poolCashBefore = pool.getCash();
        uint256 liqBalBefore = usdc.balanceOf(liquidator);
        uint256 collBefore = vault.availableCollateral(listingId);

        vm.startPrank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
        (uint256 repaid, uint256 seized) = pool.liquidate(listingId, type(uint256).max);
        vm.stopPrank();

        assertApproxEqAbs(repaid, expectedRepaid, 2);
        assertApproxEqAbs(seized, expectedSeized, 2);

        // liquidator net profit == bonus (received collateral − USDC repaid)
        uint256 liqDelta = usdc.balanceOf(liquidator) - liqBalBefore; // = seized - repaid
        assertApproxEqAbs(liqDelta, seized - repaid, 2);

        // pool received the repayment in cash (solvency)
        assertEq(pool.getCash(), poolCashBefore + repaid);
        // collateral reduced by exactly the seized amount
        assertEq(vault.availableCollateral(listingId), collBefore - seized);
        // remaining debt reduced (allow sub-wei index round-trip rounding)
        assertApproxEqAbs(pool.debtOf(listingId), debt - repaid, 1e3);
    }

    function test_bad_debt_written_off_when_collateral_exhausted() public {
        pool.setBorrowRate(5_000);
        _depositCollateral(10_000e6);
        _lenderDeposit(500_000e6);
        _borrow(6_500e6); // max LTV

        // 10 years at 50% APR → debt ≈ 39,000 ≫ 10k collateral
        vm.warp(block.timestamp + 3650 days);
        pool.accrue();
        assertGt(pool.debtOf(listingId), vault.availableCollateral(listingId));

        vm.startPrank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
        // close-factor repay would need >collateral worth of seize → caps to all
        // collateral and writes off the residual.
        pool.liquidate(listingId, type(uint256).max);
        vm.stopPrank();

        assertEq(vault.availableCollateral(listingId), 0);
        assertEq(pool.debtOf(listingId), 0); // residual written off
        assertEq(pool.scaledDebt(listingId), 0);
        assertEq(pool.listingBorrower(listingId), address(0));
    }

    // ───────────────────────── inflation guard ─────────────────
    function test_first_deposit_below_minimum_reverts() public {
        uint256 tooSmall = pool.MIN_FIRST_DEPOSIT() - 1;
        vm.startPrank(lender);
        usdc.approve(address(pool), 1e6);
        vm.expectRevert(AgentLendingPool.BelowMinimumDeposit.selector);
        pool.deposit(tooSmall);
        vm.stopPrank();
    }

    function test_minimum_liquidity_locked_on_first_deposit() public {
        _lenderDeposit(100_000e6);
        assertEq(pool.lenderShares(pool.BURN_ADDRESS()), pool.MINIMUM_LIQUIDITY());
        assertEq(pool.lenderShares(lender), 100_000e6 - pool.MINIMUM_LIQUIDITY());
    }

    // ───────────────────────── reserves ────────────────────────
    function test_owner_reduces_reserves() public {
        _depositCollateral(100_000e6);
        _lenderDeposit(500_000e6);
        _borrow(50_000e6);

        vm.warp(block.timestamp + 365 days);
        uint256 debt = pool.debtOf(listingId);
        vm.startPrank(agent);
        usdc.approve(address(pool), debt);
        pool.repay(listingId, debt);
        vm.stopPrank();

        uint256 reserves = pool.totalReserves();
        assertGt(reserves, 0);

        address sink = address(0xBEEF);
        pool.reduceReserves(reserves, sink);
        assertEq(usdc.balanceOf(sink), reserves);
        assertEq(pool.totalReserves(), 0);
    }

    function test_borrow_rate_param_bounded() public {
        vm.expectRevert(AgentLendingPool.ParamOutOfRange.selector);
        pool.setBorrowRate(5_001);
    }
}
