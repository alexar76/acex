// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title AgentNoteToken — AgentNotes (bond instrument ERC-20)
/// @notice Fixed supply at issuance; redeemable at maturity via CollateralVault.
///         Transfers freeze on default so only pre-default holders may claim slash payouts.
contract AgentNoteToken is ERC20, Ownable2Step {
    error Matured();
    error NotMatured();
    error NotVault();
    error NotRegistry();
    error NotAuditPool();
    error TransfersFrozen();
    error AuditPoolAlreadySet();

    address public immutable vault;
    address public immutable listingRegistry;
    bytes32 public immutable listingId;
    uint64 public immutable maturity;
    uint256 public immutable faceValue; // USDC 6-decimal units per 1 note token

    address public auditPool;
    bool public defaultFrozen;

    /// @notice Cumulative note units redeemed so far. AgentNotes support partial
    ///         redemption by multiple holders up to the vault's locked collateral,
    ///         so this is a running total (not a one-shot flag).
    uint256 public redeemedAmount;

    constructor(
        address vault_,
        address registry_,
        address beneficiary_,
        bytes32 listingId_,
        string memory name_,
        string memory symbol_,
        uint256 supply_,
        uint64 maturity_,
        uint256 faceValue_
    ) ERC20(name_, symbol_) Ownable(vault_) {
        if (beneficiary_ == address(0) || registry_ == address(0)) revert();
        vault = vault_;
        listingRegistry = registry_;
        listingId = listingId_;
        maturity = maturity_;
        faceValue = faceValue_;
        _mint(beneficiary_, supply_);
    }

    modifier onlyRegistry() {
        if (msg.sender != listingRegistry) revert NotRegistry();
        _;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    modifier onlyAuditPool() {
        if (msg.sender != auditPool) revert NotAuditPool();
        _;
    }

    function setAuditPool(address pool_) external onlyRegistry {
        if (auditPool != address(0) || pool_ == address(0)) revert AuditPoolAlreadySet();
        auditPool = pool_;
    }

    /// @notice Freeze secondary transfers when a listing defaults (claim window only).
    function freezeForDefault() external onlyAuditPool {
        defaultFrozen = true;
    }

    /// @notice Burn notes from a holder during default compensation (not locked in pool).
    function burnForDefault(address holder, uint256 amount) external onlyAuditPool {
        if (!defaultFrozen) revert TransfersFrozen();
        _burn(holder, amount);
    }

    function burnOnRedeem(address holder, uint256 amount) external onlyVault {
        if (block.timestamp < maturity) revert NotMatured();
        redeemedAmount += amount;
        _burn(holder, amount);
    }

    function isMatured() external view returns (bool) {
        return block.timestamp >= maturity;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (defaultFrozen) {
            if (to != address(0) || from == address(0)) revert TransfersFrozen();
            // Burns only: audit-pool default claims, or vault redemption after maturity.
            if (msg.sender == auditPool) {
                super._update(from, to, value);
                return;
            }
            if (msg.sender == vault && block.timestamp >= maturity) {
                super._update(from, to, value);
                return;
            }
            revert TransfersFrozen();
        }
        super._update(from, to, value);
    }
}
