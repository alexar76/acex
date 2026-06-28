# ACEX Capital Markets Protocol (ALP + extensions)

**Version:** 0.1.0-draft  
**Chains:** EVM (Base, Ethereum) · Solana

## Abstract

Extends [AIMarket Protocol v2](https://github.com/alexar76/aimarket-protocol/blob/main/spec.md) with **capital markets**: agents list as issuers (ALP), mint **CapShares**, issue **AgentNotes** against collateral, borrow via **LiquidityMesh**, trade on **Pulse AMM**.

## Agent Listing Protocol (ALP)

```
Agent → apply(listing_id, metadata_hash)
Auditor(s) → AgentAuditPool.coverListing(cover_usdc, score_bps)   [Proof-of-Audit]
           OR legacy allowlisted auditor → record_audit(score_bps)
Admin → approve(name, symbol, max_supply) → CapShare ERC-20 / SPL mint
Agent/MM → create PulseAMM pool + captureBaseline (≤30d after approve)
Optional → issue_agent_notes(collateral_usdc, maturity, face_value)
  → AgentNoteToken.setAuditPool wired by registry
Revenue → fundAuditRewards → auditors claimAuditReward
Default → triggerDefault (TWAP −50%, baseline required) → note holders claimDefaultCompensation
```

| Field | Rule |
|-------|------|
| `MIN_AUDIT_SCORE_BPS` | 7000 (70%) |
| `MIN_STAKE_USDC` | 10_000 (Proof-of-Audit) |
| Collateral | USDC / USDC-SPL only |
| Listing status | Pending → UnderAudit → Approved \| Rejected |

See [proof-of-audit.md](./proof-of-audit.md) for the staked auditor market.

## On-chain deployments

| Module | EVM | Solana |
|--------|-----|--------|
| Registry | `AgentListingRegistry` | `acex_capital::apply/approve` |
| Audit pool | `AgentAuditPool` | Phase 2 |
| Vault | `AgentCollateralVault` | `deposit_collateral` |
| Shares | `AgentShareToken` | SPL mint (off-chain + approve ix) |
| Notes | `AgentNoteToken` | Phase 2 |
| Lending | `AgentLendingPool` | Phase 2 |
| AMM | `PulseAMM` | Jupiter route (Solana) — see [jupiter-routing.md](../docs/jupiter-routing.md) |
| Options | CapSense | Solana program (Phase 2) |

## Hub integration

- `GET /api/v2/capital/pricing` — Factory + Hub alias
- `GET /ai-market/v2/capital/pricing` — AIMarket Hub canonical path

Real-time capability indices for [Pulse Terminal](https://github.com/alexar76/pulse-terminal/blob/main/README.md).

See [../docs/security/audit-2026-05.md](../docs/security/audit-2026-05.md).
