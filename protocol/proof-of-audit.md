# Proof-of-Audit — Agent Audit Pool

**Version:** 0.1.0  
**Contract:** `AgentAuditPool.sol`  
**Status:** EVM implemented · Hub bridge Phase 2

## Problem

Legacy ALP auditors are **owner-allowlisted**. A one-shot score (≥7000 bps) does not bind auditor capital — agents can rug after approval.

## Solution

Replace centralized auditors with a **staked insurance market**:

| Actor | Gains | Risks |
|-------|-------|-------|
| **Auditor** | Revenue share on covered listings | Stake slashed on default |
| **Agent** | Lower note spread under high aggregate score | Pays auditors from listing revenue |
| **Note holder** | Pro-rata payout from slashed stake | Fixed yield (no extra risk) |

## Flow

```
1. Auditor stake(≥10k USDC)
2. Agent applyForListing(listingId)
3. Auditor coverListing(listingId, coverUsdc, scoreBps≥7000)
   → weighted aggregate score → registry.recordAudit()
4. Admin approveListing → CapShares mint; coverage → Insuring
5. Hub / PulseDistributor fundAuditRewards(listingId, fee)
6. Auditor claimAuditReward(listingId)
7. On rug (CapShare TWAP −50% / 7d OR note default):
   triggerDefault / triggerNoteDefault → slash → note holders claimDefaultCompensation
```

## On-chain API

| Function | Purpose |
|----------|---------|
| `stake(amount)` | Deposit USDC; min 10k to cover |
| `unstake(amount)` | Withdraw free stake (not locked as insurance) |
| `coverListing(id, cover, scoreBps)` | Insure listing + publish score |
| `fundAuditRewards(id, usdc)` | Revenue bridge (pro-rata by cover) |
| `claimAuditReward(id)` | Pull accrued auditor fees |
| `observeSharePrice(id)` | PulseAMM TWAP oracle poke (never sets baseline) |
| `captureBaseline(id)` | One-shot baseline when AMM pool exists (within 30d of approve; required before default) |
| `triggerDefault(id)` | Permissionless if TWAP drawdown ≥50% after 7d **and baseline captured** |
| `triggerNoteDefault(id)` | Owner path for note insolvency |
| `claimDefaultCompensation(id, noteAmt)` | Note holders burn notes in-place; transfers frozen at default |
| `suggestedNoteSpreadBps(id)` | Score → note rate curve (view) |

## Security fixes (v0.1.1)

- **Baseline:** `observeSharePrice` never seeds baseline; `captureBaseline()` required before `triggerDefault` (prevents rug-before-observe bypass).
- **Claims:** Notes `freezeForDefault()` at slash; `burnForDefault()` instead of locking ERC20 in pool; cap by `defaultNoteSupply`.
- **Release:** `_releaseListingCoverage()` idempotent when cover already zero.

## Constants

| Param | Value |
|-------|-------|
| `MIN_STAKE_USDC` | 10_000 USDC |
| `MIN_COVER_USDC` | 1_000 USDC per coverage |
| `MIN_AUDIT_SCORE_BPS` | 7000 |
| `DEFAULT_DROP_BPS` | 5000 (−50% from baseline TWAP) |
| `DEFAULT_WINDOW` | 7 days post-approval (earliest `triggerDefault`) |
| `BASELINE_CAPTURE_WINDOW` | 30 days post-approval (latest `captureBaseline`) |

## Registry integration

`AgentListingRegistry.setAuditPool(pool)` (one-shot):

- `recordAudit` accepts `msg.sender == auditPool` (legacy allowlist still works when pool unset)
- `approveListing` / `rejectListing` call `onListingApproved` / `onListingRejected`

## Deploy order

```
Vault → Registry → Lending → PulseAMM → AgentAuditPool → registry.setAuditPool
```

See `script/DeployACEX.s.sol`.

## Hub / Pulse integration (Phase 2)

- Index `ListingCovered`, `ListingDefaulted`, `AuditRewardClaimed`
- Route `ACEX_AUDIT_FEE_BPS` of invoke revenue → `fundAuditRewards`
- Pulse Terminal DetailRail: show auditors, cover, aggregate score, default risk
- PulseAMM hedging: auditors trade CapShares to delta-hedge insurance book

## Economics

- **TVL:** N auditors × 10k+ USDC stake + locked cover
- **Capital auction:** higher aggregate score → lower `suggestedNoteSpreadBps` → cheaper agent capital
- **Real protection:** slash flows to note holders, not a vanity rating
