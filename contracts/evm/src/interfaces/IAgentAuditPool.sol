// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title IAgentAuditPool — Proof-of-Audit market for agent listings
interface IAgentAuditPool {
    enum CoveragePhase {
        Open,
        Insuring,
        Slashed,
        Released
    }

    struct Coverage {
        address auditor;
        uint256 coverAmount;
        uint256 scoreBps;
        uint64 coveredAt;
        CoveragePhase phase;
    }

    struct ListingAuditState {
        uint256 totalCover;
        uint256 aggregateScoreBps;
        uint256 baselinePriceE18;
        uint256 twapPriceE18;
        bool defaulted;
        uint256 compensationPerNoteE6;
    }

    event Staked(address indexed auditor, uint256 amount, uint256 totalStaked);
    event Unstaked(address indexed auditor, uint256 amount, uint256 totalStaked);
    event ListingCovered(
        bytes32 indexed listingId,
        address indexed auditor,
        uint256 coverAmount,
        uint256 scoreBps,
        uint256 aggregateScoreBps
    );
    event CoverageReleased(bytes32 indexed listingId, address indexed auditor, uint256 amount);
    event AuditRewardFunded(bytes32 indexed listingId, uint256 amount);
    event AuditRewardClaimed(bytes32 indexed listingId, address indexed auditor, uint256 amount);
    event SharePriceObserved(bytes32 indexed listingId, uint256 priceE18, uint256 twapE18);
    event ListingDefaulted(
        bytes32 indexed listingId,
        uint256 slashedUsdc,
        uint256 compensationPerNoteE6,
        string reason
    );
    event DefaultCompensationClaimed(
        bytes32 indexed listingId,
        address indexed holder,
        uint256 noteAmount,
        uint256 usdcPayout
    );

    function onListingApproved(bytes32 listingId) external;

    function onListingRejected(bytes32 listingId) external;

    function suggestedNoteSpreadBps(bytes32 listingId) external view returns (uint256);

    function getListingAuditState(bytes32 listingId) external view returns (ListingAuditState memory);
}
