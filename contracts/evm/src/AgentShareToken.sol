// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title AgentShareToken — CapShares (ERC-20 per agent listing)
/// @notice Minting restricted to listing registry until public float enabled.
contract AgentShareToken is ERC20, Ownable2Step {
    error MintCapExceeded();
    error TradingLocked();
    error NotRegistry();
    error LockAlreadySet();
    error TokensLocked();

    address public immutable registry;
    bytes32 public immutable listingId;
    uint256 public immutable maxSupply;
    bool public tradingEnabled;

    // Anti-rug vesting: a tranche of the founder/agent allocation that cannot be
    // transferred (i.e. dumped on the AMM) until `lockUnlockAt`. Set once at listing
    // approval. Zero `lockedAmount` ⇒ no lock.
    address public lockHolder;
    uint256 public lockedAmount;
    uint64 public lockUnlockAt;

    event InitialLockConfigured(address indexed holder, uint256 amount, uint64 unlockAt);

    constructor(
        address registry_,
        bytes32 listingId_,
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_
    ) ERC20(name_, symbol_) Ownable(registry_) {
        if (registry_ == address(0) || maxSupply_ == 0) revert();
        registry = registry_;
        listingId = listingId_;
        maxSupply = maxSupply_;
    }

    modifier onlyRegistry() {
        if (msg.sender != registry) revert NotRegistry();
        _;
    }

    /// @notice IPO mint to agent treasury wallet (one-shot or tranched via registry).
    function mintTo(address to, uint256 amount) external onlyRegistry {
        if (totalSupply() + amount > maxSupply) revert MintCapExceeded();
        _mint(to, amount);
    }

    function enableTrading() external onlyRegistry {
        tradingEnabled = true;
    }

    /// @notice Lock `amount` of `holder`'s allocation until `unlockAt` (one-shot).
    ///         Used by the registry to vest the founder tranche so it can't be
    ///         dumped on the AMM immediately after listing.
    function setInitialLock(address holder, uint256 amount, uint64 unlockAt) external onlyRegistry {
        if (lockHolder != address(0) || lockedAmount != 0) revert LockAlreadySet();
        lockHolder = holder;
        lockedAmount = amount;
        lockUnlockAt = unlockAt;
        emit InitialLockConfigured(holder, amount, unlockAt);
    }

    /// @notice Amount of `account`'s balance that is currently transfer-locked.
    function lockedBalanceOf(address account) public view returns (uint256) {
        if (account != lockHolder || block.timestamp >= lockUnlockAt) return 0;
        return lockedAmount;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!tradingEnabled && from != address(0) && to != address(0)) {
            revert TradingLocked();
        }
        // Vesting: the locked tranche of the founder allocation cannot leave the
        // holder's wallet before the cliff (mint/burn — from/to == 0 — are exempt).
        if (from != address(0)) {
            uint256 locked = lockedBalanceOf(from);
            if (locked != 0 && balanceOf(from) - value < locked) revert TokensLocked();
        }
        super._update(from, to, value);
    }
}
