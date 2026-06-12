// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AgentCollateralVault} from "./AgentCollateralVault.sol";
import {IAgentListingRegistry} from "./interfaces/IAgentListingRegistry.sol";

/// @title AgentLendingPool — LiquidityMesh (USDC money market for agent listings)
/// @notice Lenders deposit USDC for yield-bearing shares. Approved agents borrow USDC
///         against USDC collateral held in {AgentCollateralVault}. Debt accrues interest
///         via a global borrow index; positions whose debt rises above the liquidation
///         threshold can be liquidated for a bonus. Liquidations are *funded* — the
///         liquidator repays the pool and receives the seized collateral plus bonus —
///         so the pool stays solvent. Collateral that can no longer back any debt is
///         returned to the agent via {withdrawCollateral}.
contract AgentLendingPool is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ───────────────────────── errors ─────────────────────────
    error ZeroAddress();
    error Unauthorized();
    error InsufficientLiquidity();
    error InsufficientCollateral();
    error InvalidListing();
    error InvalidAmount();
    error Healthy();
    error BelowMinimumDeposit();
    error ParamOutOfRange();

    // ───────────────────────── constants ──────────────────────
    uint256 public constant BPS = 10_000;
    uint256 public constant RAY = 1e27;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @dev First deposit floor + permanently-locked shares: blocks the
    ///      first-depositor share-inflation/donation attack (Uniswap-V2 style).
    uint256 public constant MIN_FIRST_DEPOSIT = 1e6; // 1 USDC (6 decimals)
    uint256 public constant MINIMUM_LIQUIDITY = 1_000;
    address public constant BURN_ADDRESS = address(0xdEaD);

    uint256 public constant MAX_LTV_BPS = 6_500; // 65% — origination cap
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 8_000; // 80% — liquidation boundary
    uint256 public constant LIQUIDATION_BONUS_BPS = 800; // 8% bonus to the liquidator
    uint256 public constant CLOSE_FACTOR_BPS = 5_000; // ≤50% of debt repaid per call
    uint256 public constant MAX_BORROW_RATE_BPS = 5_000; // ≤50% APR guard
    uint256 public constant MAX_RESERVE_FACTOR_BPS = 5_000; // ≤50% guard

    // ───────────────────────── immutables ─────────────────────
    IERC20 public immutable usdc;
    AgentCollateralVault public immutable vault;
    IAgentListingRegistry public immutable registry;

    // ───────────────────────── interest model ─────────────────
    uint256 public borrowRatePerYearBps; // simple APR applied to outstanding debt
    uint256 public reserveFactorBps; // share of interest earmarked as protocol reserves
    uint256 public borrowIndex; // RAY-scaled cumulative interest index (starts at RAY)
    uint64 public lastAccrualTs;

    // ───────────────────────── accounting ─────────────────────
    uint256 public totalShares;
    uint256 public totalScaledBorrow; // Σ scaledDebt; actual = scaled * borrowIndex / RAY
    uint256 public totalReserves; // USDC accrued to the protocol (excluded from lender assets)

    mapping(address => uint256) public lenderShares;
    mapping(bytes32 => uint256) public scaledDebt;
    mapping(bytes32 => address) public listingBorrower;

    // ───────────────────────── events ─────────────────────────
    event Deposited(address indexed lender, uint256 amount, uint256 sharesMinted);
    event Withdrawn(address indexed lender, uint256 amount, uint256 sharesBurned);
    event Borrowed(bytes32 indexed listingId, address indexed agent, uint256 amount);
    event Repaid(bytes32 indexed listingId, address indexed payer, uint256 amount);
    event Liquidated(
        bytes32 indexed listingId, address indexed liquidator, uint256 repaid, uint256 seized
    );
    event CollateralWithdrawn(
        bytes32 indexed listingId, address indexed agent, uint256 amount, address to
    );
    event BadDebtWrittenOff(bytes32 indexed listingId, uint256 amount, uint256 fromReserves);
    event Accrued(uint256 borrowIndex, uint256 totalBorrows, uint256 reserves);
    event BorrowRateUpdated(uint256 bps);
    event ReserveFactorUpdated(uint256 bps);
    event ReservesReduced(address indexed to, uint256 amount);

    constructor(address usdc_, address vault_, address registry_) Ownable(msg.sender) {
        if (usdc_ == address(0) || vault_ == address(0) || registry_ == address(0)) {
            revert ZeroAddress();
        }
        usdc = IERC20(usdc_);
        vault = AgentCollateralVault(vault_);
        registry = IAgentListingRegistry(registry_);
        borrowIndex = RAY;
        lastAccrualTs = uint64(block.timestamp);
        borrowRatePerYearBps = 1_000; // 10% APR default
        reserveFactorBps = 1_000; // 10% of interest to reserves
    }

    // ═══════════════════════ interest accrual ═════════════════
    /// @notice Public poke so views/integrations can force the index forward.
    function accrue() external {
        _accrue();
    }

    function _accrue() internal {
        uint64 nowTs = uint64(block.timestamp);
        uint256 dt = nowTs - lastAccrualTs;
        if (dt == 0) return;

        uint256 scaled = totalScaledBorrow;
        if (scaled == 0 || borrowRatePerYearBps == 0) {
            lastAccrualTs = nowTs;
            return;
        }

        uint256 idx = borrowIndex;
        // simple-interest factor for the elapsed period, RAY-scaled
        uint256 factor = Math.mulDiv(borrowRatePerYearBps * dt, RAY, SECONDS_PER_YEAR * BPS);
        uint256 borrowsPrior = Math.mulDiv(scaled, idx, RAY);
        uint256 interest = Math.mulDiv(borrowsPrior, factor, RAY);

        borrowIndex = idx + Math.mulDiv(idx, factor, RAY);
        if (reserveFactorBps != 0) {
            totalReserves += Math.mulDiv(interest, reserveFactorBps, BPS);
        }
        lastAccrualTs = nowTs;

        emit Accrued(borrowIndex, Math.mulDiv(scaled, borrowIndex, RAY), totalReserves);
    }

    /// @dev Borrow index projected to `block.timestamp` without mutating state.
    function _projectedIndex() internal view returns (uint256) {
        uint256 dt = block.timestamp - lastAccrualTs;
        if (dt == 0 || totalScaledBorrow == 0 || borrowRatePerYearBps == 0) {
            return borrowIndex;
        }
        uint256 factor = Math.mulDiv(borrowRatePerYearBps * dt, RAY, SECONDS_PER_YEAR * BPS);
        return borrowIndex + Math.mulDiv(borrowIndex, factor, RAY);
    }

    function _debtStored(bytes32 listingId) internal view returns (uint256) {
        return Math.mulDiv(scaledDebt[listingId], borrowIndex, RAY);
    }

    // ═══════════════════════ lender side ══════════════════════
    function deposit(uint256 amount) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (amount == 0) revert InvalidAmount();
        _accrue();

        if (totalShares == 0) {
            if (amount < MIN_FIRST_DEPOSIT) revert BelowMinimumDeposit();
            // mint `amount` shares 1:1; lock MINIMUM_LIQUIDITY forever.
            shares = amount - MINIMUM_LIQUIDITY;
            lenderShares[BURN_ADDRESS] = MINIMUM_LIQUIDITY;
            lenderShares[msg.sender] += shares;
            totalShares = amount;
        } else {
            uint256 assetsBefore = totalAssets();
            if (assetsBefore == 0) revert InsufficientLiquidity();
            shares = Math.mulDiv(amount, totalShares, assetsBefore);
            if (shares == 0) revert InvalidAmount();
            lenderShares[msg.sender] += shares;
            totalShares += shares;
        }

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount, shares);
    }

    function withdraw(uint256 shares) external nonReentrant whenNotPaused returns (uint256 amount) {
        if (shares == 0 || shares > lenderShares[msg.sender]) revert InvalidAmount();
        _accrue();

        amount = Math.mulDiv(shares, totalAssets(), totalShares);
        if (amount == 0) revert InvalidAmount();
        if (getCash() < amount) revert InsufficientLiquidity();

        lenderShares[msg.sender] -= shares;
        totalShares -= shares;
        usdc.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, shares);
    }

    // ═══════════════════════ borrower side ════════════════════
    function borrow(bytes32 listingId, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        _accrue();

        IAgentListingRegistry.Listing memory L = registry.getListing(listingId);
        if (L.agentWallet != msg.sender) revert Unauthorized();
        if (L.status != IAgentListingRegistry.ListingStatus.Approved) revert InvalidListing();

        uint256 collateral = vault.availableCollateral(listingId);
        uint256 newDebt = _debtStored(listingId) + amount;
        // origination LTV: newDebt ≤ collateral * MAX_LTV
        if (newDebt * BPS > collateral * MAX_LTV_BPS) revert InsufficientCollateral();
        if (getCash() < amount) revert InsufficientLiquidity();

        uint256 scaled = Math.mulDiv(amount, RAY, borrowIndex);
        scaledDebt[listingId] += scaled;
        totalScaledBorrow += scaled;
        listingBorrower[listingId] = msg.sender;

        usdc.safeTransfer(msg.sender, amount);
        emit Borrowed(listingId, msg.sender, amount);
    }

    /// @notice Repay (partial or full) on behalf of any listing. Open to anyone.
    function repay(bytes32 listingId, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 repaid)
    {
        if (amount == 0) revert InvalidAmount();
        _accrue();

        uint256 debt = _debtStored(listingId);
        if (debt == 0) revert InvalidListing();

        repaid = amount > debt ? debt : amount;
        _reduceDebt(listingId, repaid);

        usdc.safeTransferFrom(msg.sender, address(this), repaid);
        emit Repaid(listingId, msg.sender, repaid);
    }

    /// @notice Liquidate an unhealthy position. The liquidator repays `repayAmount`
    ///         (capped by the close factor and available collateral) into the pool and
    ///         receives the corresponding collateral plus {LIQUIDATION_BONUS_BPS}.
    function liquidate(bytes32 listingId, uint256 repayAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 repaid, uint256 seized)
    {
        if (repayAmount == 0) revert InvalidAmount();
        _accrue();

        uint256 debt = _debtStored(listingId);
        if (debt == 0) revert InvalidListing();

        uint256 collateral = vault.availableCollateral(listingId);
        // healthy iff debt ≤ collateral * LIQUIDATION_THRESHOLD
        if (debt * BPS <= collateral * LIQUIDATION_THRESHOLD_BPS) revert Healthy();

        uint256 maxRepay = Math.mulDiv(debt, CLOSE_FACTOR_BPS, BPS);
        repaid = repayAmount > maxRepay ? maxRepay : repayAmount;
        seized = Math.mulDiv(repaid, BPS + LIQUIDATION_BONUS_BPS, BPS);

        // Collateral can't cover repay + bonus → seize all of it and scale the
        // liquidator's repayment down so they still earn exactly the bonus.
        if (seized > collateral) {
            seized = collateral;
            repaid = Math.mulDiv(seized, BPS, BPS + LIQUIDATION_BONUS_BPS);
        }
        if (repaid == 0 || seized == 0) revert InvalidAmount();

        _reduceDebt(listingId, repaid);

        // Liquidator funds the pool, then receives the seized collateral + bonus.
        usdc.safeTransferFrom(msg.sender, address(this), repaid);
        vault.seizeTo(listingId, seized, msg.sender);

        emit Liquidated(listingId, msg.sender, repaid, seized);

        // If collateral is exhausted but debt remains, the position is insolvent:
        // write the residual off against reserves first, then socialise to lenders.
        if (vault.availableCollateral(listingId) == 0) {
            uint256 residual = _debtStored(listingId);
            if (residual > 0) _writeOffBadDebt(listingId, residual);
        }
    }

    // ═══════════════════════ agent collateral ═════════════════
    /// @notice Agent reclaims free collateral, provided the position stays within
    ///         the origination LTV afterwards. Routed through the vault's pool-only
    ///         transfer path.
    function withdrawCollateral(bytes32 listingId, uint256 amount, address to)
        external
        nonReentrant
        whenNotPaused
    {
        if (amount == 0 || to == address(0)) revert InvalidAmount();
        _accrue();

        IAgentListingRegistry.Listing memory L = registry.getListing(listingId);
        if (L.agentWallet != msg.sender) revert Unauthorized();

        uint256 collateral = vault.availableCollateral(listingId);
        if (amount > collateral) revert InsufficientCollateral();

        uint256 remaining = collateral - amount;
        uint256 debt = _debtStored(listingId);
        if (debt * BPS > remaining * MAX_LTV_BPS) revert InsufficientCollateral();

        vault.seizeTo(listingId, amount, to);
        emit CollateralWithdrawn(listingId, msg.sender, amount, to);
    }

    // ═══════════════════════ internal debt ops ════════════════
    function _reduceDebt(bytes32 listingId, uint256 amount) internal {
        uint256 cur = scaledDebt[listingId];
        uint256 scaled;
        // Repaying the full outstanding debt clears the scaled balance exactly,
        // so floor-rounding never leaves a wei of dust behind.
        if (amount >= Math.mulDiv(cur, borrowIndex, RAY)) {
            scaled = cur;
        } else {
            scaled = Math.mulDiv(amount, RAY, borrowIndex);
            if (scaled > cur) scaled = cur;
        }
        scaledDebt[listingId] = cur - scaled;
        totalScaledBorrow -= scaled;
        if (scaledDebt[listingId] == 0) listingBorrower[listingId] = address(0);
    }

    function _writeOffBadDebt(bytes32 listingId, uint256 badDebt) internal {
        uint256 scaled = scaledDebt[listingId];
        scaledDebt[listingId] = 0;
        totalScaledBorrow -= scaled;
        listingBorrower[listingId] = address(0);

        // Reserves absorb the loss first (they are excluded from lender assets, so
        // burning them and the matching debt nets to zero for lenders). Any excess
        // reduces the lender exchange rate — correctly socialised.
        uint256 fromReserves = badDebt > totalReserves ? totalReserves : badDebt;
        totalReserves -= fromReserves;
        emit BadDebtWrittenOff(listingId, badDebt, fromReserves);
    }

    // ═══════════════════════ admin ════════════════════════════
    function setBorrowRate(uint256 bps) external onlyOwner {
        if (bps > MAX_BORROW_RATE_BPS) revert ParamOutOfRange();
        _accrue();
        borrowRatePerYearBps = bps;
        emit BorrowRateUpdated(bps);
    }

    function setReserveFactor(uint256 bps) external onlyOwner {
        if (bps > MAX_RESERVE_FACTOR_BPS) revert ParamOutOfRange();
        _accrue();
        reserveFactorBps = bps;
        emit ReserveFactorUpdated(bps);
    }

    function reduceReserves(uint256 amount, address to) external onlyOwner nonReentrant {
        if (amount == 0 || to == address(0)) revert InvalidAmount();
        _accrue();
        if (amount > totalReserves) revert InvalidAmount();
        if (getCash() < amount) revert InsufficientLiquidity();
        totalReserves -= amount;
        usdc.safeTransfer(to, amount);
        emit ReservesReduced(to, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ═══════════════════════ views ════════════════════════════
    function getCash() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @notice Outstanding debt for a listing, including interest accrued to now.
    function debtOf(bytes32 listingId) public view returns (uint256) {
        return Math.mulDiv(scaledDebt[listingId], _projectedIndex(), RAY);
    }

    /// @notice Total outstanding borrows across all listings (interest-projected).
    function totalBorrows() public view returns (uint256) {
        return Math.mulDiv(totalScaledBorrow, _projectedIndex(), RAY);
    }

    /// @notice Assets backing lender shares = cash + outstanding borrows − reserves.
    function totalAssets() public view returns (uint256) {
        uint256 gross = getCash() + totalBorrows();
        return gross > totalReserves ? gross - totalReserves : 0;
    }

    /// @notice USDC value of one share scaled by 1e18 (0 when no shares exist).
    function exchangeRate() external view returns (uint256) {
        if (totalShares == 0) return 0;
        return Math.mulDiv(totalAssets(), 1e18, totalShares);
    }

    function isLiquidatable(bytes32 listingId) external view returns (bool) {
        uint256 d = debtOf(listingId);
        if (d == 0) return false;
        return d * BPS > vault.availableCollateral(listingId) * LIQUIDATION_THRESHOLD_BPS;
    }

    /// @notice Health factor in BPS: collateral·threshold / debt. ≥ BPS is healthy,
    ///         < BPS is liquidatable. Returns max uint when debt is zero.
    function healthFactorBps(bytes32 listingId) external view returns (uint256) {
        uint256 d = debtOf(listingId);
        if (d == 0) return type(uint256).max;
        return Math.mulDiv(vault.availableCollateral(listingId), LIQUIDATION_THRESHOLD_BPS, d);
    }

    /// @notice Maximum additional USDC the listing can borrow right now.
    function availableToBorrow(bytes32 listingId) external view returns (uint256) {
        uint256 maxDebt = (vault.availableCollateral(listingId) * MAX_LTV_BPS) / BPS;
        uint256 d = debtOf(listingId);
        if (d >= maxDebt) return 0;
        uint256 room = maxDebt - d;
        uint256 cash = getCash();
        return room < cash ? room : cash;
    }
}
