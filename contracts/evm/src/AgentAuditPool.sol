// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IAgentAuditPool} from "./interfaces/IAgentAuditPool.sol";
import {IAgentListingRegistry} from "./interfaces/IAgentListingRegistry.sol";
import {AgentCollateralVault} from "./AgentCollateralVault.sol";
import {AgentNoteToken} from "./AgentNoteToken.sol";
import {PulseAMM} from "./PulseAMM.sol";

/// @title AgentAuditPool — Proof-of-Audit (staked auditor market)
/// @notice Permissionless auditors stake USDC, cover listings with insured scores,
///         earn revenue share, and slash to note holders on CapShare rug defaults.
contract AgentAuditPool is IAgentAuditPool, ReentrancyGuard, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error Unauthorized();
    error InsufficientStake();
    error InsufficientFreeStake();
    error InvalidScore();
    error InvalidAmount();
    error InvalidListing();
    error CoverageNotFound();
    error AlreadyDefaulted();
    error DefaultNotTriggered();
    error DefaultConditionsNotMet();
    error BaselineNotSet();
    error BaselineAlreadySet();
    error NoCompensation();
    error NothingToClaim();
    error ExceedsClaimableNotes();
    error TooManyCoverages();

    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_STAKE_USDC = 10_000e6;
    uint256 public constant MIN_COVER_USDC = 1_000e6;
    uint256 public constant MIN_AUDIT_SCORE_BPS = 7000;
    uint256 public constant DEFAULT_DROP_BPS = 5000; // 50% drawdown from baseline
    uint256 public constant DEFAULT_WINDOW = 7 days;
    /// @dev Longer than {DEFAULT_WINDOW} so agents can seed PulseAMM liquidity first.
    uint256 public constant BASELINE_CAPTURE_WINDOW = 30 days;
    /// @dev Minimum TWAP observation time that must accumulate before a baseline can be captured,
    ///      so the baseline is a time-weighted average over a real window — not a single-block /
    ///      low-volume spot price an attacker can seed and snapshot.
    uint256 public constant MIN_OBSERVATION_WINDOW = 1 days;


    /// @notice Distinct samples required before a baseline may be captured.
    /// @dev `captureBaseline` is callable by anyone, so the caller picks the moment. With a
    ///      minimum number of samples the moment is worth much less: the baseline is an
    ///      average of several independent reads, not whichever instant the caller liked.
    uint256 public constant MIN_OBSERVATIONS_FOR_BASELINE = 3;
    uint256 public constant MAX_NOTE_SPREAD_BPS = 2_000; // 20% APR cap from score curve
    /// @dev Hard cap on coverages per listing so {_recomputeAggregateScore} and the
    ///      default/release loops stay bounded and cannot be griefed into a gas-DoS.
    uint256 public constant MAX_COVERAGES_PER_LISTING = 256;

    IERC20 public immutable usdc;
    IAgentListingRegistry public immutable registry;
    AgentCollateralVault public immutable vault;
    PulseAMM public pulseAmm;

    mapping(address => uint256) public staked;
    mapping(address => uint256) public lockedStake;
    mapping(bytes32 => Coverage[]) internal _coverages;
    mapping(bytes32 => uint256) public totalCoverForListing;
    mapping(bytes32 => uint256) public aggregateScoreForListing;
    mapping(bytes32 => bool) public listingDefaulted;
    mapping(bytes32 => uint256) public compensationPerNoteE6;  // kept for events/views (lossy)
    mapping(bytes32 => uint256) public defaultCompensationPool; // REMAINING pool (decremented)
    mapping(bytes32 => uint256) public defaultSlashTotal;       // ORIGINAL slash (payout numerator)
    mapping(bytes32 => uint256) public defaultNoteSupply;
    mapping(bytes32 => uint256) public totalNotesClaimed;
    mapping(bytes32 => mapping(address => uint256)) public notesClaimedByHolder;

    mapping(bytes32 => uint256) public baselinePriceE18;
    mapping(bytes32 => uint64) public approvedAt;
    /// @notice Snapshots of PulseAMM's time-weighted price accumulator. The TWAP between two
    ///         snapshots is their accumulator difference over their time difference: every
    ///         price counts for exactly as long as it held in the pool. (The sample-and-hold
    ///         average this replaced weighted a sample until the next observation, so a crash
    ///         held for one block counted for a day.)
    mapping(bytes32 => uint64) public firstObservedAt;
    mapping(bytes32 => uint256) public firstObservedCumulative;
    mapping(bytes32 => uint64) public lastObservedAt;
    mapping(bytes32 => uint256) public lastObservedCumulative;
    mapping(bytes32 => uint256) public lastObservedPriceE18;
    mapping(bytes32 => uint64) public baselineAt;
    mapping(bytes32 => uint256) public baselineCumulative;
    /// @notice Distinct blocks in which this listing's price was observed.
    mapping(bytes32 => uint256) public observationCount;

    mapping(bytes32 => mapping(address => uint256)) public pendingAuditRewards;
    mapping(bytes32 => mapping(address => uint256)) public claimedAuditRewards;

    modifier onlyRegistry() {
        if (msg.sender != address(registry)) revert Unauthorized();
        _;
    }

    constructor(address registry_, address vault_, address usdc_, address pulseAmm_) Ownable(msg.sender) {
        if (registry_ == address(0) || vault_ == address(0) || usdc_ == address(0)) revert ZeroAddress();
        registry = IAgentListingRegistry(registry_);
        vault = AgentCollateralVault(vault_);
        usdc = IERC20(usdc_);
        if (pulseAmm_ != address(0)) {
            pulseAmm = PulseAMM(pulseAmm_);
        }
    }

    /// @notice One-shot, like {AgentListingRegistry.setAuditPool} and
    ///         {AgentCollateralVault.setLendingPool}. This AMM is the price oracle that
    ///         decides whether a listing defaulted, and a default slashes staked auditor
    ///         USDC and pays it to note holders — so an owner able to re-point it at any
    ///         time can manufacture that outcome. The constructor already takes the AMM;
    ///         this setter exists only for a deployment that passed address(0).
    ///         Trade-off accepted: migrating to a redeployed AMM needs a new pool contract.
    function setPulseAMM(address pulseAmm_) external onlyOwner {
        if (address(pulseAmm) != address(0) || pulseAmm_ == address(0)) revert ZeroAddress();
        pulseAmm = PulseAMM(pulseAmm_);
    }

    // ───────────────────────── staking ─────────────────────────

    /// @notice Stake USDC to become an auditor (min 10k USDC to cover listings).
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        staked[msg.sender] += amount;
        emit Staked(msg.sender, amount, staked[msg.sender]);
    }

    /// @notice Withdraw free stake (not locked as listing insurance).
    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        uint256 free = staked[msg.sender] - lockedStake[msg.sender];
        if (amount > free) revert InsufficientFreeStake();
        staked[msg.sender] -= amount;
        usdc.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount, staked[msg.sender]);
    }

    function freeStake(address auditor) public view returns (uint256) {
        uint256 s = staked[auditor];
        uint256 l = lockedStake[auditor];
        return s > l ? s - l : 0;
    }

    // ───────────────────────── coverage ─────────────────────────

    /// @notice Insure a listing with staked USDC and publish an audit score (≥70%).
    function coverListing(bytes32 listingId, uint256 coverAmount, uint256 scoreBps)
        external
        nonReentrant
        whenNotPaused
    {
        if (coverAmount < MIN_COVER_USDC) revert InvalidAmount();
        if (scoreBps < MIN_AUDIT_SCORE_BPS || scoreBps > BPS) revert InvalidScore();
        if (staked[msg.sender] < MIN_STAKE_USDC) revert InsufficientStake();
        if (freeStake(msg.sender) < coverAmount) revert InsufficientFreeStake();

        IAgentListingRegistry.Listing memory L = registry.getListing(listingId);
        if (L.agentWallet == address(0)) revert InvalidListing();
        if (
            L.status != IAgentListingRegistry.ListingStatus.Pending
                && L.status != IAgentListingRegistry.ListingStatus.UnderAudit
        ) {
            revert InvalidListing();
        }

        if (_coverages[listingId].length >= MAX_COVERAGES_PER_LISTING) revert TooManyCoverages();

        lockedStake[msg.sender] += coverAmount;
        _coverages[listingId].push(
            Coverage({
                auditor: msg.sender,
                coverAmount: coverAmount,
                scoreBps: scoreBps,
                coveredAt: uint64(block.timestamp),
                phase: CoveragePhase.Open
            })
        );

        totalCoverForListing[listingId] += coverAmount;
        _recomputeAggregateScore(listingId);

        emit ListingCovered(
            listingId, msg.sender, coverAmount, scoreBps, aggregateScoreForListing[listingId]
        );
    }

    function _recomputeAggregateScore(bytes32 listingId) internal {
        Coverage[] storage covs = _coverages[listingId];
        uint256 weighted;
        uint256 total;
        for (uint256 i = 0; i < covs.length; i++) {
            Coverage storage c = covs[i];
            if (c.phase == CoveragePhase.Slashed || c.phase == CoveragePhase.Released) continue;
            weighted += c.scoreBps * c.coverAmount;
            total += c.coverAmount;
        }
        if (total == 0) return;

        uint256 aggregate = weighted / total;
        aggregateScoreForListing[listingId] = aggregate;

        if (aggregate >= MIN_AUDIT_SCORE_BPS) {
            registry.recordAudit(listingId, aggregate);
        }
    }

    // ───────────────────────── registry hooks ─────────────────────────

    function onListingApproved(bytes32 listingId) external onlyRegistry {
        Coverage[] storage covs = _coverages[listingId];
        for (uint256 i = 0; i < covs.length; i++) {
            if (covs[i].phase == CoveragePhase.Open) {
                covs[i].phase = CoveragePhase.Insuring;
            }
        }
        approvedAt[listingId] = uint64(block.timestamp);
        // Nothing is observed here: the CapShare's pool cannot exist yet (approval mints the
        // token), and time before the pool exists must not enter the average — it used to,
        // at a price of zero, and let a baseline be captured near zero.
    }

    function onListingRejected(bytes32 listingId) external onlyRegistry {
        _releaseListingCoverage(listingId);
    }

    function _releaseListingCoverage(bytes32 listingId) internal {
        if (totalCoverForListing[listingId] == 0) return;

        Coverage[] storage covs = _coverages[listingId];
        for (uint256 i = 0; i < covs.length; i++) {
            Coverage storage c = covs[i];
            if (c.phase == CoveragePhase.Released || c.phase == CoveragePhase.Slashed) continue;
            lockedStake[c.auditor] -= c.coverAmount;
            c.phase = CoveragePhase.Released;
            emit CoverageReleased(listingId, c.auditor, c.coverAmount);
        }
        totalCoverForListing[listingId] = 0;
        aggregateScoreForListing[listingId] = 0;
    }

    // ───────────────────────── TWAP oracle ─────────────────────────

    /// @notice One-shot baseline: the time-weighted price since the pool was first observed,
    ///         over at least MIN_OBSERVATION_WINDOW and MIN_OBSERVATIONS_FOR_BASELINE distinct
    ///         blocks (must run before triggerDefault).
    function captureBaseline(bytes32 listingId) external whenNotPaused {
        IAgentListingRegistry.Listing memory L = registry.getListing(listingId);
        if (L.status != IAgentListingRegistry.ListingStatus.Approved) revert InvalidListing();
        if (baselinePriceE18[listingId] != 0) revert BaselineAlreadySet();
        if (block.timestamp > approvedAt[listingId] + BASELINE_CAPTURE_WINDOW) {
            revert DefaultConditionsNotMet();
        }

        _observeSharePrice(listingId);
        uint64 first = firstObservedAt[listingId];
        if (first == 0 || block.timestamp - first < MIN_OBSERVATION_WINDOW) {
            revert DefaultConditionsNotMet();
        }
        if (observationCount[listingId] < MIN_OBSERVATIONS_FOR_BASELINE) {
            revert DefaultConditionsNotMet();
        }

        uint256 twap = twapPriceE18(listingId);
        if (twap == 0) revert DefaultConditionsNotMet();

        baselinePriceE18[listingId] = twap;
        baselineAt[listingId] = uint64(block.timestamp);
        baselineCumulative[listingId] = lastObservedCumulative[listingId];
        emit SharePriceObserved(listingId, lastObservedPriceE18[listingId], twap);
    }

    /// @notice Snapshot the pool's price accumulator (anyone may poke). Never sets baseline.
    function observeSharePrice(bytes32 listingId) external whenNotPaused {
        _observeSharePrice(listingId);
    }

    function _observeSharePrice(bytes32 listingId) internal {
        (uint256 cumulative, bool ok) = _cumulativePrice(listingId);
        if (!ok) return;
        uint64 nowTs = uint64(block.timestamp);
        if (firstObservedAt[listingId] == 0) {
            firstObservedAt[listingId] = nowTs;
            firstObservedCumulative[listingId] = cumulative;
        }
        // One sample per block: calling twice in one block used to count as two of the
        // independent samples a baseline requires.
        if (lastObservedAt[listingId] != nowTs) {
            observationCount[listingId] += 1;
        }
        lastObservedAt[listingId] = nowTs;
        lastObservedCumulative[listingId] = cumulative;
        lastObservedPriceE18[listingId] = _currentSharePriceE18(listingId);

        emit SharePriceObserved(listingId, lastObservedPriceE18[listingId], twapPriceE18(listingId));
    }

    /// @notice Time-weighted price since the pool was first observed.
    function twapPriceE18(bytes32 listingId) public view returns (uint256) {
        uint64 first = firstObservedAt[listingId];
        if (first == 0) return 0;
        (uint256 cumulative, bool ok) = _cumulativePrice(listingId);
        if (!ok) return 0;
        if (block.timestamp <= first) return _currentSharePriceE18(listingId);
        return (cumulative - firstObservedCumulative[listingId]) / (block.timestamp - first);
    }

    /// @notice Time-weighted price since the baseline was captured (0 before that).
    function twapSinceBaselineE18(bytes32 listingId) public view returns (uint256) {
        uint64 since = baselineAt[listingId];
        if (since == 0 || block.timestamp <= since) return 0;
        (uint256 cumulative, bool ok) = _cumulativePrice(listingId);
        if (!ok) return 0;
        return (cumulative - baselineCumulative[listingId]) / (block.timestamp - since);
    }

    /// @dev The listing's pool accumulator, if it has a live pool quoted in this pool's USDC.
    function _cumulativePrice(bytes32 listingId) internal view returns (uint256, bool) {
        IAgentListingRegistry.Listing memory L = registry.getListing(listingId);
        if (L.shareToken == address(0) || address(pulseAmm) == address(0)) return (0, false);
        (, IERC20 quote,,, bool active) = pulseAmm.pools(L.shareToken);
        if (!active || address(quote) != address(usdc)) return (0, false);
        return (pulseAmm.currentCumulativePrice(L.shareToken), true);
    }

    function _currentSharePriceE18(bytes32 listingId) internal view returns (uint256) {
        IAgentListingRegistry.Listing memory L = registry.getListing(listingId);
        if (L.shareToken == address(0)) return 0;
        if (address(pulseAmm) == address(0)) return 0;

        (, IERC20 quote,,, bool active) = pulseAmm.pools(L.shareToken);
        // A pool quoted in anything but this pool's USDC prices nothing it pays out in.
        if (!active || address(quote) != address(usdc)) return 0;
        // Block-start reserves, not the live ones: a crash and its reversal inside one
        // transaction (a flash swap in the observer's or the trigger's own call) used to be
        // read as the market price.
        return pulseAmm.blockStartPriceE18(L.shareToken);
    }

    // ───────────────────────── default & compensation ─────────────────────────

    /// @notice Slash auditor insurance when CapShare TWAP drops ≥50% within 7 days of approval.
    function triggerDefault(bytes32 listingId) external nonReentrant whenNotPaused {
        if (listingDefaulted[listingId]) revert AlreadyDefaulted();

        IAgentListingRegistry.Listing memory L = registry.getListing(listingId);
        if (L.status != IAgentListingRegistry.ListingStatus.Approved) revert InvalidListing();
        if (block.timestamp < approvedAt[listingId] + DEFAULT_WINDOW) revert DefaultConditionsNotMet();

        uint256 baseline = baselinePriceE18[listingId];
        if (baseline == 0) {
            // No baseline established. While the capture window is still open, capture must happen
            // first (revert). Once it has elapsed with no baseline, the agent never established a
            // priced market — treat as a default so auditor stake / note holders aren't locked
            // forever by a never-seeded pool.
            if (block.timestamp <= approvedAt[listingId] + BASELINE_CAPTURE_WINDOW) revert BaselineNotSet();
            _executeDefault(listingId, "baseline_never_established");
            return;
        }

        _observeSharePrice(listingId);
        // The average price SINCE the baseline, weighted by how long each price held: a
        // collapse that lasts is a default, a crash held for a block barely moves it.
        uint256 twap = twapSinceBaselineE18(listingId);
        if (twap == 0) revert DefaultConditionsNotMet();
        uint256 threshold = baseline * (BPS - DEFAULT_DROP_BPS);
        if (twap * BPS > threshold) revert DefaultConditionsNotMet();

        // The TWAP alone is not enough. `_observeSharePrice` credits an entire unobserved
        // interval at the price recorded at its START, and anyone may record one — so a
        // flash-crash of the pool, one `observeSharePrice` call, an immediate arbitrage back,
        // and then silence writes a price into the average that the market never held. The
        // spot check makes that useless: a drawdown only counts as a default if the market is
        // STILL down when the default is claimed. A genuinely collapsed CapShare satisfies
        // both; a manipulated snapshot of a recovered one satisfies neither.
        uint256 spot = _currentSharePriceE18(listingId);
        if (spot == 0 || spot * BPS > threshold) revert DefaultConditionsNotMet();

        _executeDefault(listingId, "capshare_drawdown");
    }

    /// @notice Governance path when AgentNotes collateral is insolvent (rug / note default).
    function triggerNoteDefault(bytes32 listingId) external onlyOwner {
        if (listingDefaulted[listingId]) revert AlreadyDefaulted();
        IAgentListingRegistry.Listing memory L = registry.getListing(listingId);
        if (L.status != IAgentListingRegistry.ListingStatus.Approved) revert InvalidListing();
        _executeDefault(listingId, "note_default");
    }

    function _executeDefault(bytes32 listingId, string memory reason) internal {
        listingDefaulted[listingId] = true;

        uint256 slashTotal;
        Coverage[] storage covs = _coverages[listingId];
        for (uint256 i = 0; i < covs.length; i++) {
            Coverage storage c = covs[i];
            if (c.phase != CoveragePhase.Insuring) continue;
            slashTotal += c.coverAmount;
            lockedStake[c.auditor] -= c.coverAmount;
            staked[c.auditor] -= c.coverAmount;
            c.phase = CoveragePhase.Slashed;
        }

        address noteToken = vault.listingNote(listingId);
        uint256 noteSupply;
        if (noteToken != address(0)) {
            noteSupply = IERC20(noteToken).totalSupply();
            if (slashTotal > 0 && noteSupply > 0) {
                AgentNoteToken(noteToken).freezeForDefault();
                defaultNoteSupply[listingId] = noteSupply;
            }
        }

        if (noteSupply > 0 && slashTotal > 0) {
            // Store the ORIGINAL slash + note supply; payout is computed proportionally with a
            // single division at claim time (no two-stage rounding loss). compensationPerNoteE6
            // is retained only as a lossy display value in the event.
            defaultSlashTotal[listingId] = slashTotal;
            defaultNoteSupply[listingId] = noteSupply;
            compensationPerNoteE6[listingId] = (slashTotal * 1e18) / noteSupply;
            defaultCompensationPool[listingId] = slashTotal;
        } else if (slashTotal > 0) {
            usdc.safeTransfer(owner(), slashTotal);
            slashTotal = 0;
        }

        totalCoverForListing[listingId] = 0;
        emit ListingDefaulted(listingId, slashTotal, compensationPerNoteE6[listingId], reason);
    }

    /// @notice Note holders claim slashed auditor stake; burns notes in-place (no pool lock-up).
    function claimDefaultCompensation(bytes32 listingId, uint256 noteAmount)
        external
        nonReentrant
        whenNotPaused
    {
        if (!listingDefaulted[listingId]) revert DefaultNotTriggered();
        if (noteAmount == 0) revert InvalidAmount();

        address noteToken = vault.listingNote(listingId);
        if (noteToken == address(0)) revert NoCompensation();

        uint256 slashTotal = defaultSlashTotal[listingId];
        uint256 supply = defaultNoteSupply[listingId];
        if (slashTotal == 0 || supply == 0) revert NoCompensation();

        if (IERC20(noteToken).balanceOf(msg.sender) < noteAmount) revert ExceedsClaimableNotes();

        uint256 newTotal = totalNotesClaimed[listingId] + noteAmount;
        if (newTotal > supply) revert ExceedsClaimableNotes();

        // Single division (numerator kept large) → no two-stage rounding loss.
        uint256 payout = (noteAmount * slashTotal) / supply;
        if (payout == 0) revert NothingToClaim();
        if (payout > defaultCompensationPool[listingId]) {
            payout = defaultCompensationPool[listingId];
        }

        totalNotesClaimed[listingId] = newTotal;
        notesClaimedByHolder[listingId][msg.sender] += noteAmount;
        defaultCompensationPool[listingId] -= payout;

        AgentNoteToken(noteToken).burnForDefault(msg.sender, noteAmount);
        usdc.safeTransfer(msg.sender, payout);
        emit DefaultCompensationClaimed(listingId, msg.sender, noteAmount, payout);
    }

    // ───────────────────────── audit rewards ─────────────────────────

    /// @notice Fund auditor revenue share (hub / PulseDistributor bridge sends listing fee slice).
    function fundAuditRewards(bytes32 listingId, uint256 usdcAmount) external nonReentrant whenNotPaused {
        if (usdcAmount == 0) revert InvalidAmount();
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        Coverage[] storage covs = _coverages[listingId];
        uint256 total = totalCoverForListing[listingId];
        if (total == 0) return;

        for (uint256 i = 0; i < covs.length; i++) {
            Coverage storage c = covs[i];
            if (c.phase != CoveragePhase.Insuring) continue;
            pendingAuditRewards[listingId][c.auditor] += (usdcAmount * c.coverAmount) / total;
        }

        emit AuditRewardFunded(listingId, usdcAmount);
    }

    function claimAuditReward(bytes32 listingId) external nonReentrant whenNotPaused {
        uint256 pending = pendingAuditRewards[listingId][msg.sender];
        if (pending == 0) revert NothingToClaim();
        pendingAuditRewards[listingId][msg.sender] = 0;
        claimedAuditRewards[listingId][msg.sender] += pending;
        usdc.safeTransfer(msg.sender, pending);
        emit AuditRewardClaimed(listingId, msg.sender, pending);
    }

    // ───────────────────────── pricing curve ─────────────────────────

    /// @notice Higher audit scores → lower AgentNote spread (market rate from reputation).
    function suggestedNoteSpreadBps(bytes32 listingId) external view returns (uint256) {
        uint256 score = aggregateScoreForListing[listingId];
        if (score < MIN_AUDIT_SCORE_BPS) return MAX_NOTE_SPREAD_BPS;
        uint256 spread = MAX_NOTE_SPREAD_BPS - ((score - MIN_AUDIT_SCORE_BPS) * MAX_NOTE_SPREAD_BPS)
            / (BPS - MIN_AUDIT_SCORE_BPS);
        return spread < 100 ? 100 : spread;
    }

    function getListingAuditState(bytes32 listingId)
        external
        view
        returns (ListingAuditState memory)
    {
        return ListingAuditState({
            totalCover: totalCoverForListing[listingId],
            aggregateScoreBps: aggregateScoreForListing[listingId],
            baselinePriceE18: baselinePriceE18[listingId],
            twapPriceE18: twapPriceE18(listingId),
            defaulted: listingDefaulted[listingId],
            compensationPerNoteE6: compensationPerNoteE6[listingId]
        });
    }

    function coverages(bytes32 listingId, uint256 index) external view returns (Coverage memory) {
        return _coverages[listingId][index];
    }

    function coverageCount(bytes32 listingId) external view returns (uint256) {
        return _coverages[listingId].length;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
