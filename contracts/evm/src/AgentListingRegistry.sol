// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IAgentListingRegistry} from "./interfaces/IAgentListingRegistry.sol";
import {IAgentAuditPool} from "./interfaces/IAgentAuditPool.sol";
import {AgentShareToken} from "./AgentShareToken.sol";
import {AgentNoteToken} from "./AgentNoteToken.sol";
import {AgentCollateralVault} from "./AgentCollateralVault.sol";

/// @title AgentListingRegistry — ALP (Agent Listing Protocol)
/// @notice IPO-style listing: apply → Proof-of-Audit → mint CapShares → optional AgentNotes.
contract AgentListingRegistry is IAgentListingRegistry, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    error ListingExists();
    error InvalidStatus();
    error AuditScoreTooLow();
    error ZeroAddress();

    uint256 public constant MIN_AUDIT_SCORE_BPS = 7000; // 70%
    uint256 public constant BPS = 10_000;

    error LockBpsTooHigh();
    error NotListingAgent();
    error NotesUndercollateralized();
    error ScoreOutOfRange();
    error ListingNotEvictable();

    AgentCollateralVault public immutable vault;

    mapping(bytes32 => Listing) public listings;
    mapping(address => bool) public auditors;

    /// @notice Proof-of-Audit pool (permissionless staked auditors). Zero = legacy allowlist only.
    address public auditPool;
    bool private _auditPoolSet;

    IERC20 public immutable usdc;

    constructor(address vault_, address usdc_) Ownable(msg.sender) {
        if (vault_ == address(0) || usdc_ == address(0)) revert ZeroAddress();
        vault = AgentCollateralVault(vault_);
        usdc = IERC20(usdc_);
    }

    function setAuditor(address auditor, bool allowed) external onlyOwner {
        auditors[auditor] = allowed;
    }

    function setAuditPool(address pool_) external onlyOwner {
        if (_auditPoolSet || pool_ == address(0)) revert ZeroAddress();
        auditPool = pool_;
        _auditPoolSet = true;
    }

    function applyForListing(bytes32 listingId, bytes32 metadataHash)
        external
        override
        whenNotPaused
    {
        if (listings[listingId].agentWallet != address(0)) revert ListingExists();
        listings[listingId] = Listing({
            listingId: listingId,
            agentWallet: msg.sender,
            metadataHash: metadataHash,
            auditScoreBps: 0,
            shareToken: address(0),
            maxSupply: 0,
            status: ListingStatus.Pending,
            listedAt: 0
        });
        emit ListingApplied(listingId, msg.sender, metadataHash);
    }

    /// @notice Release a listing id that was claimed but never approved.
    /// @dev `applyForListing` is first-come on a caller-chosen id and there was no way back:
    ///      whoever claimed an id was its `agentWallet` forever, which let a squatter block
    ///      the intended agent (and, because `withdrawCollateral` authorizes on
    ///      `agentWallet` without checking status, collect anything deposited to that id).
    ///      Only the operator can evict, and only before approval, so this can never be used
    ///      against a live listing; any collateral on the id is returned to its agent wallet
    ///      (the only party allowed to fund an unapproved id), so no one's funds are
    ///      stranded. The evicted id becomes claimable again.
    function evictUnapprovedListing(bytes32 listingId) external onlyOwner {
        Listing storage L = listings[listingId];
        if (L.agentWallet == address(0)) revert ListingNotEvictable();
        if (L.status == ListingStatus.Approved || L.status == ListingStatus.Delisted) {
            revert ListingNotEvictable();
        }
        // Collateral no longer blocks the eviction — one base unit deposited by the squatter
        // used to keep the id forever. It goes back to the agent wallet, the only party that
        // can fund an unapproved id.
        vault.releaseOnEviction(listingId, L.agentWallet);
        if (auditPool != address(0) && L.status == ListingStatus.UnderAudit) {
            // Give any auditor their locked cover back before the id is recycled.
            IAgentAuditPool(auditPool).onListingRejected(listingId);
        }
        delete listings[listingId];
        emit ListingRejected(listingId, "evicted: unapproved id released");
    }

    function recordAudit(bytes32 listingId, uint256 auditScoreBps) external whenNotPaused {
        if (msg.sender != auditPool && !auditors[msg.sender]) revert();
        // A score is a fraction of BPS. Unbounded, a >100% score flowed into the audit
        // pool's coverage-weighted aggregate and into the note-spread curve.
        if (auditScoreBps > BPS) revert ScoreOutOfRange();
        Listing storage L = listings[listingId];
        if (L.status != ListingStatus.Pending && L.status != ListingStatus.UnderAudit) {
            revert InvalidStatus();
        }
        L.auditScoreBps = auditScoreBps;
        L.status = ListingStatus.UnderAudit;
        emit ListingAudited(listingId, auditScoreBps, msg.sender);
    }

    function approveListing(
        bytes32 listingId,
        string calldata name,
        string calldata symbol,
        uint256 maxSupply
    ) external override onlyOwner whenNotPaused returns (address shareToken) {
        return address(_approveListing(listingId, name, symbol, maxSupply));
    }

    /// @notice Approve a listing and vest a tranche of the founder allocation: lock
    ///         `lockBps` of `maxSupply` in the agent wallet for `lockSeconds` (cliff),
    ///         blocking an immediate 100% dump on the AMM (anti-rug).
    function approveListingWithVesting(
        bytes32 listingId,
        string calldata name,
        string calldata symbol,
        uint256 maxSupply,
        uint256 lockBps,
        uint64 lockSeconds
    ) external onlyOwner whenNotPaused returns (address shareToken) {
        if (lockBps > BPS) revert LockBpsTooHigh();
        AgentShareToken token = _approveListing(listingId, name, symbol, maxSupply);
        if (lockBps > 0 && lockSeconds > 0) {
            token.setInitialLock(
                listings[listingId].agentWallet,
                (maxSupply * lockBps) / BPS,
                uint64(block.timestamp) + lockSeconds
            );
        }
        return address(token);
    }

    function _approveListing(
        bytes32 listingId,
        string calldata name,
        string calldata symbol,
        uint256 maxSupply
    ) internal returns (AgentShareToken token) {
        Listing storage L = listings[listingId];
        if (L.status != ListingStatus.UnderAudit && L.status != ListingStatus.Pending) {
            revert InvalidStatus();
        }
        if (L.auditScoreBps < MIN_AUDIT_SCORE_BPS) revert AuditScoreTooLow();

        token = new AgentShareToken(address(this), listingId, name, symbol, maxSupply);
        token.mintTo(L.agentWallet, maxSupply);
        token.enableTrading();

        L.shareToken = address(token);
        L.maxSupply = maxSupply;
        L.status = ListingStatus.Approved;
        L.listedAt = uint64(block.timestamp);

        if (auditPool != address(0)) {
            IAgentAuditPool(auditPool).onListingApproved(listingId);
        }

        emit ListingApproved(listingId, address(token), maxSupply);
    }

    function rejectListing(bytes32 listingId, string calldata reason)
        external
        override
        onlyOwner
        whenNotPaused
    {
        Listing storage L = listings[listingId];
        if (L.status == ListingStatus.Approved || L.status == ListingStatus.Delisted) {
            revert InvalidStatus();
        }
        L.status = ListingStatus.Rejected;
        if (auditPool != address(0)) {
            IAgentAuditPool(auditPool).onListingRejected(listingId);
        }
        emit ListingRejected(listingId, reason);
    }

    /// @notice Issue a series of AgentNotes for an approved listing.
    /// @dev Two invariants, both learned the hard way (2026-08 audit):
    ///
    ///      1. Only the listing's own agent may issue. This used to be callable by
    ///         anyone: a stranger passed `collateralUsdc = 0` (so no allowance was
    ///         needed — a zero-value transferFrom always succeeds) and used the
    ///         `lockForNote` below to move a live borrower's collateral out from under
    ///         its loan, pushing a healthy position into liquidation and taking the 8%
    ///         bonus, or locking ALL of it so the debt became unliquidatable.
    ///      2. A note series must be backed by the collateral posted WITH IT. The face
    ///         value was locked from the listing's whole vault balance, which is the
    ///         same pot that backs {AgentLendingPool} debt — so the same USDC could be
    ///         pledged twice, once to lenders and once to note holders. Requiring
    ///         `collateralUsdc >= faceTotal` also makes repeat issuance safe: each
    ///         series brings its own backing, so Σ locked always covers Σ face value.
    function issueAgentNotes(
        bytes32 listingId,
        string calldata name,
        string calldata symbol,
        uint256 supply,
        uint64 maturity,
        uint256 faceValue,
        uint256 collateralUsdc
    ) external whenNotPaused returns (address noteToken) {
        Listing storage L = listings[listingId];
        if (L.status != ListingStatus.Approved) revert InvalidStatus();
        if (msg.sender != L.agentWallet) revert NotListingAgent();

        uint256 faceTotal = (supply * faceValue) / 1e18;
        if (collateralUsdc < faceTotal) revert NotesUndercollateralized();

        usdc.safeTransferFrom(L.agentWallet, address(vault), collateralUsdc);
        vault.creditCollateral(listingId, collateralUsdc);
        noteToken = address(
            new AgentNoteToken(
                address(vault),
                address(this),
                L.agentWallet,
                listingId,
                name,
                symbol,
                supply,
                maturity,
                faceValue
            )
        );
        vault.registerNote(listingId, noteToken);
        vault.lockForNote(listingId, faceTotal);
        if (auditPool != address(0)) {
            AgentNoteToken(noteToken).setAuditPool(auditPool);
        }
        return noteToken;
    }

    function getListing(bytes32 listingId) external view override returns (Listing memory) {
        return listings[listingId];
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
