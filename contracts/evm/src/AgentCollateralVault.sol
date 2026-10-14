// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {AgentNoteToken} from "./AgentNoteToken.sol";

/// @dev Just enough of {AgentLendingPool} to ask whether collateral is still pledged.
///      Declared locally: the pool already imports this vault, so importing it back
///      would be a cycle.
interface IListingAgent {
    struct Listing {
        bytes32 listingId;
        address agentWallet;
        bytes32 metadataHash;
        uint256 auditScoreBps;
        address shareToken;
        uint256 maxSupply;
        uint8 status;
        uint64 listedAt;
    }

    function getListing(bytes32 listingId) external view returns (Listing memory);
}

interface ILendingPoolDebt {
    function debtOf(bytes32 listingId) external view returns (uint256);
    function MAX_LTV_BPS() external view returns (uint256);
    function BPS() external view returns (uint256);
}

/// @title AgentCollateralVault — collateral for AgentNotes + lending health
contract AgentCollateralVault is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error InsufficientCollateral();
    error NoteNotFound();
    error AlreadyRedeemed();
    error CollateralPledgedToPool();
    error LendingPoolAlreadySet();
    error InvalidAmount();
    error UnknownListing();
    error NotListingAgent();

    event CollateralDeposited(bytes32 indexed listingId, uint256 amount);
    event CollateralWithdrawn(bytes32 indexed listingId, uint256 amount, address to);
    event NoteRegistered(bytes32 indexed listingId, address noteToken);
    event NoteRedeemed(bytes32 indexed listingId, address holder, uint256 payout);

    struct CollateralPosition {
        uint256 usdcBalance;
        uint256 lockedForNotes;
    }

    IERC20 public immutable usdc;
    address public registry;
    address public lendingPool;

    mapping(bytes32 => CollateralPosition) public positions;
    /// @notice USDC an eviction returned, claimable by the wallet it belongs to. Pulled, not
    ///         pushed: a wallet that cannot receive USDC (blacklisted by the issuer) would
    ///         otherwise make the eviction revert and keep the squatted id forever.
    mapping(address => uint256) public evictionRefunds;
    mapping(address => bytes32) public noteToListing;
    mapping(bytes32 => address) public listingNote;

    modifier onlyRegistry() {
        if (msg.sender != registry) revert Unauthorized();
        _;
    }

    modifier onlyLendingPool() {
        if (msg.sender != lendingPool) revert Unauthorized();
        _;
    }

    bool private _registrySet;
    bool private _lendingPoolSet;

    constructor(address usdc_) Ownable(msg.sender) {
        usdc = IERC20(usdc_);
    }

    function setRegistry(address registry_) external onlyOwner {
        if (_registrySet || registry_ == address(0)) revert();
        registry = registry_;
        _registrySet = true;
    }

    /// @notice One-shot, like {setRegistry}. The lending pool is the only address that
    ///         may call {seizeTo}, i.e. move any listing's collateral anywhere — so a
    ///         re-pointable setter is a standing rug vector. `setRegistry` was already
    ///         one-shot; this one was not, which was an inconsistency rather than a
    ///         decision.
    function setLendingPool(address pool) external onlyOwner {
        if (_lendingPoolSet || pool == address(0)) revert LendingPoolAlreadySet();
        lendingPool = pool;
        _lendingPoolSet = true;
    }

    /// @dev Collateral can only ever leave through the lending pool, on behalf of the
    ///      listing's `agentWallet`. A deposit against an id that has no agent is therefore
    ///      unreclaimable by anyone — so it is refused rather than silently swallowed.
    function depositCollateral(bytes32 listingId, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        if (listingId == bytes32(0)) revert UnknownListing();
        // Before {setRegistry} nothing can say whose id this is, and a deposit nobody can
        // attribute is one nobody can reclaim: refuse it rather than accept it unchecked.
        if (registry == address(0)) revert Unauthorized();
        IListingAgent.Listing memory L = IListingAgent(registry).getListing(listingId);
        if (L.agentWallet == address(0)) revert UnknownListing();
        // Unless the listing is live (Approved = 2) only its agent funds the id. A
        // stranger's deposit on an unapproved or rejected id is what made a squatted id
        // un-evictable for one base unit, and eviction returns the id's collateral to the
        // agent wallet. A delisted id (4) is never evicted and keeps the old rule.
        if (L.status != 2 && L.status != 4 && msg.sender != L.agentWallet) revert NotListingAgent();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        _credit(listingId, amount);
        emit CollateralDeposited(listingId, amount);
    }

    /// @notice Registry credits collateral after pulling from agent wallet.
    function creditCollateral(bytes32 listingId, uint256 amount) external onlyRegistry nonReentrant whenNotPaused {
        _credit(listingId, amount);
        emit CollateralDeposited(listingId, amount);
    }

    function _credit(bytes32 listingId, uint256 amount) internal {
        positions[listingId].usdcBalance += amount;
    }

    function registerNote(bytes32 listingId, address noteToken) external onlyRegistry {
        listingNote[listingId] = noteToken;
        noteToListing[noteToken] = listingId;
        emit NoteRegistered(listingId, noteToken);
    }

    /// @notice Move `amount` of a listing's free collateral behind a note series.
    /// @dev The registry enforces that a series is backed by the collateral posted with
    ///      it. This is the second line: whatever the caller asks for, the collateral
    ///      LEFT OVER must still cover the listing's lending-pool debt at the pool's own
    ///      origination LTV. Without it, `usdcBalance` is one fungible pot and note
    ///      issuance could pledge USDC that lenders were already relying on — pushing a
    ///      healthy loan into liquidation, or (if all of it moved) leaving a debt with no
    ///      collateral to seize, which makes the position unliquidatable and the loss
    ///      unrecoverable.
    function lockForNote(bytes32 listingId, uint256 amount) external onlyRegistry {
        CollateralPosition storage p = positions[listingId];
        if (p.usdcBalance < amount) revert InsufficientCollateral();
        uint256 remaining = p.usdcBalance - amount;
        address pool = lendingPool;
        if (pool != address(0)) {
            uint256 debt = ILendingPoolDebt(pool).debtOf(listingId);
            if (debt != 0) {
                uint256 bps = ILendingPoolDebt(pool).BPS();
                uint256 maxLtv = ILendingPoolDebt(pool).MAX_LTV_BPS();
                if (debt * bps > remaining * maxLtv) revert CollateralPledgedToPool();
            }
        }
        p.usdcBalance = remaining;
        p.lockedForNotes += amount;
    }

    /// @notice Redeem matured notes — pays USDC pro-rata to face value.
    function redeemNote(address noteToken, uint256 noteAmount) external nonReentrant whenNotPaused {
        bytes32 listingId = noteToListing[noteToken];
        if (listingId == bytes32(0)) revert NoteNotFound();

        AgentNoteToken note = AgentNoteToken(noteToken);
        if (!note.isMatured()) revert();

        uint256 payout = (noteAmount * note.faceValue()) / 1e18;
        CollateralPosition storage p = positions[listingId];
        if (p.lockedForNotes < payout) revert InsufficientCollateral();

        p.lockedForNotes -= payout;
        note.burnOnRedeem(msg.sender, noteAmount);
        usdc.safeTransfer(msg.sender, payout);
        emit NoteRedeemed(listingId, msg.sender, payout);
    }

    /// @notice Lending pool seizes collateral on liquidation.
    function seizeTo(
        bytes32 listingId,
        uint256 amount,
        address recipient
    ) external onlyLendingPool nonReentrant {
        CollateralPosition storage p = positions[listingId];
        if (p.usdcBalance < amount) revert InsufficientCollateral();
        p.usdcBalance -= amount;
        usdc.safeTransfer(recipient, amount);
    }

    /// @notice Return a never-approved id's free collateral to its agent wallet as the
    ///         registry evicts the id. Notes and loans exist only after approval, so there is
    ///         nothing else on such an id; if there is, the eviction is refused.
    function releaseOnEviction(bytes32 listingId, address to)
        external
        onlyRegistry
        nonReentrant
        returns (uint256 amount)
    {
        CollateralPosition storage p = positions[listingId];
        if (p.lockedForNotes != 0) revert CollateralPledgedToPool();
        if (lendingPool != address(0) && ILendingPoolDebt(lendingPool).debtOf(listingId) != 0) {
            revert CollateralPledgedToPool();
        }
        amount = p.usdcBalance;
        if (amount != 0) {
            p.usdcBalance = 0;
            evictionRefunds[to] += amount;
            emit CollateralWithdrawn(listingId, amount, to);
        }
    }

    /// @notice Collect what evictions returned to the caller.
    function claimEvictionRefund() external nonReentrant returns (uint256 amount) {
        amount = evictionRefunds[msg.sender];
        if (amount == 0) revert InvalidAmount();
        evictionRefunds[msg.sender] = 0;
        usdc.safeTransfer(msg.sender, amount);
    }

    function availableCollateral(bytes32 listingId) external view returns (uint256) {
        return positions[listingId].usdcBalance;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
