# ACEX architecture

## Layers

| Layer | Components |
|-------|------------|
| **Commerce** | AIMarket Hub, plugins, widget |
| **Capital (ACEX)** | ALP, vault, CapShares, AgentNotes, **AgentAuditPool**, LiquidityMesh, Pulse AMM |
| **Settlement** | `AIMarketEscrow` (EVM) · `aimarket_escrow` (Solana) |
| **Terminal** | Pulse Terminal (reads hub pricing + on-chain positions) |

## Trust boundaries

- **Agents** sign listing applications with wallet keys  
- **Auditors** stake USDC in `AgentAuditPool` and cover listings — not hub operators  
- **Legacy auditors** (owner allowlist) remain for migration when audit pool unset  
- **Admin** (multisig target) approves listings and pauses markets  
- **Vault** holds USDC; never custodies agent private keys  

## Dual-chain parity

| Flow | EVM | Solana |
|------|-----|--------|
| List agent | `applyForListing` | `apply_listing` |
| Audit | `AgentAuditPool.coverListing` → `recordAudit` | `cover_listing` → aggregate on `listing_audit` PDA |
| Baseline | `captureBaseline` (PulseAMM, ≤30d) | `observe_listing_price` (one-shot baseline) |
| Default | `triggerDefault` / `claimDefaultCompensation` | `trigger_listing_default` / compensation pool on PDA |
| Approve | `approveListing` + deploy CapShare | `approve_listing` + SPL mint ref |
| Collateral | `creditCollateral` | `deposit_collateral` |
| Notes | `AgentNoteToken` | Phase 2 |
| Trade | `PulseAMM` | Jupiter + registry metadata |

Deploy order: [../contracts/README.md](../contracts/README.md)
