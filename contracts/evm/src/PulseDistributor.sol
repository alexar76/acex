// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title PulseDistributor — on-chain mirror of `acex_ipo.distribute()`
/// @notice Epoch-based revenue distribution to CapShares holders via Merkle claims.
///         The off-chain ACEX ledger snapshots holder balances and computes exact
///         pro-rata payouts; this contract settles them on-chain, gas-safely, with a
///         pull pattern (no holder enumeration / no per-holder push loop).
///
/// Leaf encoding (must match aimarket_hub/acex_merkle.make_leaf):
///   leaf = keccak256(abi.encodePacked(uint256 index, address account, uint256 amount))
/// Inner nodes use OpenZeppelin's commutative (sorted) hashing via MerkleProof.
contract PulseDistributor is Ownable {
    using SafeERC20 for IERC20;

    struct Epoch {
        bytes32 listingId;
        IERC20 token;
        bytes32 merkleRoot;
        uint256 total;
        uint256 claimed;
    }

    uint256 public epochCount;
    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(uint256 => bool)) private _claimed; // epochId => index => claimed

    event EpochPosted(
        uint256 indexed epochId,
        bytes32 indexed listingId,
        address token,
        bytes32 merkleRoot,
        uint256 total
    );
    event Claimed(uint256 indexed epochId, uint256 indexed index, address indexed account, uint256 amount);

    error AlreadyClaimed();
    error InvalidProof();
    error ZeroAddress();
    error ZeroRoot();
    error UnknownEpoch();
    error ExceedsEpochTotal();

    constructor(address owner_) Ownable(owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
    }

    /// @notice Post a distribution epoch and fund it. Caller must `approve(total)` first.
    /// @dev `total` should equal the sum of all leaf amounts in `merkleRoot`.
    function postEpoch(bytes32 listingId, IERC20 token, bytes32 merkleRoot, uint256 total)
        external
        onlyOwner
        returns (uint256 epochId)
    {
        if (address(token) == address(0)) revert ZeroAddress();
        if (merkleRoot == bytes32(0)) revert ZeroRoot();

        epochId = ++epochCount;
        epochs[epochId] = Epoch({
            listingId: listingId,
            token: token,
            merkleRoot: merkleRoot,
            total: total,
            claimed: 0
        });
        token.safeTransferFrom(msg.sender, address(this), total);
        emit EpochPosted(epochId, listingId, address(token), merkleRoot, total);
    }

    function isClaimed(uint256 epochId, uint256 index) public view returns (bool) {
        return _claimed[epochId][index];
    }

    /// @notice Claim a holder's pro-rata payout for an epoch.
    function claim(
        uint256 epochId,
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata proof
    ) external {
        Epoch storage e = epochs[epochId];
        if (e.merkleRoot == bytes32(0)) revert UnknownEpoch();
        if (_claimed[epochId][index]) revert AlreadyClaimed();

        bytes32 leaf = keccak256(abi.encodePacked(index, account, amount));
        if (!MerkleProof.verify(proof, e.merkleRoot, leaf)) revert InvalidProof();

        if (e.claimed + amount > e.total) revert ExceedsEpochTotal();
        _claimed[epochId][index] = true;
        e.claimed += amount;

        e.token.safeTransfer(account, amount);
        emit Claimed(epochId, index, account, amount);
    }
}
