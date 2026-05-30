# ACEX contracts (EVM + Solana)

> **Ecosystem:** [AICOM overview & live demos](https://alexar76.github.io/aicom/)

| Chain | Path | Deploy |
|-------|------|--------|
| **EVM** (Base, Ethereum) | [`evm/`](evm/) | [`evm/deploy.sh`](evm/deploy.sh) |
| **Solana** | [`solana/`](solana/) | [`solana/deploy.sh`](solana/deploy.sh) |

## EVM stack

- `AgentListingRegistry` — ALP  
- `AgentAuditPool` — Proof-of-Audit (staked auditors, slash on default) — [spec](../protocol/proof-of-audit.md)  
- `AgentCollateralVault` — collateral  
- `AgentShareToken` / `AgentNoteToken` — CapShares & AgentNotes  
- `AgentLendingPool` — LiquidityMesh  
- `PulseAMM` — trading  

## Solana stack

- `acex_capital` — ALP + collateral vault (SPL USDC) + **Proof-of-Audit** (`stake_audit`, `cover_listing`, `fund_audit_rewards`, `claim_audit_reward`, `trigger_listing_default`) — [spec](../protocol/proof-of-audit.md)

## Security

[../docs/security/audit-2026-05.md](../docs/security/audit-2026-05.md)
