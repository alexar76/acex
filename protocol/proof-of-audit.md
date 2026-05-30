# Proof-of-Audit — Agent Audit Pool

**Version:** 0.1.1  
**Contract:** `AgentAuditPool.sol` · `AgentNoteToken.sol` (default freeze) · Solana `acex_capital` PoA instructions  
**Status:** EVM + Hub ledger + Pulse Terminal + Solana mirror **shipped**

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
5. Agent (or MM) createPool on PulseAMM + captureBaseline(listingId) within 30d
6. observeSharePrice(listingId) — keep TWAP fresh (anyone; does not set baseline)
7. Hub / PulseDistributor fundAuditRewards(listingId, fee)
8. Auditor claimAuditReward(listingId)
9. On rug (CapShare TWAP −50% after 7d **and baseline captured**) OR note insolvency:
   triggerDefault / triggerNoteDefault → freezeForDefault → slash
10. Note holders claimDefaultCompensation (burnForDefault in-place)
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
| `getListingAuditState(id)` | Aggregate cover, score, baseline, TWAP, default flags (view) |
| `twapPriceE18(id)` | Current TWAP from observations (view) |
| `freeStake(auditor)` | Unlocked stake available to withdraw (view) |
| `coverages(id, i)` / `coverageCount(id)` | Per-auditor insurance rows (view) |
| `setPulseAMM(addr)` | Wire PulseAMM for price oracle (owner, once) |
| `pause()` / `unpause()` | Emergency circuit breaker (owner) |

### Registry hooks (only `AgentListingRegistry`)

| Function | When |
|----------|------|
| `onListingApproved(id)` | Coverage → Insuring; seed baseline if AMM pool already exists |
| `onListingRejected(id)` | Release locked auditor stake (idempotent) |

### AgentNoteToken (default path)

| Function | Purpose |
|----------|---------|
| `setAuditPool(pool)` | Registry wires audit pool at note issuance |
| `freezeForDefault()` | Audit pool only — blocks secondary transfers after slash |
| `burnForDefault(holder, amt)` | Audit pool burns notes on compensation claim (not locked in pool) |

Vault `redeemNote` still works after maturity when notes are frozen.

## Security fixes (v0.1.1)

- **Baseline:** `observeSharePrice` never seeds baseline; `captureBaseline()` required before `triggerDefault` (prevents rug-before-observe bypass). **30-day** capture window (AMM seeding grace period).
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
- `issueAgentNotes` calls `AgentNoteToken.setAuditPool` when pool is configured

## Deploy order

```
Vault → Registry → Lending → PulseAMM → AgentAuditPool → registry.setAuditPool
```

See `script/DeployACEX.s.sol`.

## Hub / Pulse integration (Phase 2 — shipped)

### Hub ledger (`aimarket_hub/acex_audit.py`)

Off-chain SQLite mirror of `AgentAuditPool` economics for invoke routing and Pulse overlay. When an IPO listing has no on-chain coverage yet, the hub bootstraps synthetic **`hub-auditor-pool`** coverage from the approved IPO audit score.

| Function | Purpose |
|----------|---------|
| `accrue_audit_rewards(listing_id, gross_usd)` | Split `ACEX_AUDIT_FEE_BPS` of paid invoke to insuring auditors (pro-rata by cover) |
| `sync_coverage(...)` | Admin/indexer sync of on-chain or external auditor rows |
| `claim_audit_reward(listing_id, auditor)` | Mark pending rewards claimed (off-chain; on-chain via pool when bridged) |
| `listing_audit_state` / `list_audit_states` | Aggregate score, cover, default risk, auditor table |

**Invoke hook:** paid `/invoke` → `acex_ipo.accrue_revenue` then `acex_audit.accrue_audit_rewards`. Response field: `acex_audit_rewards.to_auditors_usd`.

**Pricing overlay:** `acex/integrations/pricing.py` merges hub audit state into each listing as `proof_of_audit` and snapshot summary `proof_of_audit.listings_with_coverage`.

### Hub API (also under `/api/v2/capital/…` Pulse alias)

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| `GET` | `/capital/audit` | — | All listing audit states |
| `GET` | `/capital/audit/{listing_id}` | — | Detail: coverages, default risk, rewards |
| `POST` | `/capital/audit/{listing_id}/sync` | Admin | Upsert auditor coverage |
| `POST` | `/capital/audit/{listing_id}/claim` | — | Claim pending rewards for auditor |

### Env (hub)

| Variable | Default | Role |
|----------|---------|------|
| `ACEX_AUDIT_FEE_BPS` | `100` (1%) | Share of gross invoke → auditors |
| `ACEX_AUDIT_DB_PATH` | `data/acex_audit.db` | SQLite ledger path |
| `ACEX_AUDIT_BRIDGE_MODE` | `offchain` | `offchain` \| `onchain` \| `both` (future worker → `fundAuditRewards`) |
| `ACEX_AUDIT_POOL_ADDRESS` | — | EVM `AgentAuditPool` for indexer / bridge |
| `AIMARKET_ADMIN_TOKEN` | — | Required for `/capital/audit/…/sync` |

### Pulse Terminal

Detail rail panel **Proof-of-Audit**: aggregate score, total cover, default risk badge, note spread suggestion, per-auditor cover/score/phase/rewards. Listings table **Audit** column when `proof_of_audit.enabled`.

Fields from pricing API: `coverages`, `default_risk`, `aggregate_score_bps`, `total_cover_usd` (see `pulse_terminal.audit_detail_fields` in pricing snapshot).

### Solana mirror (`acex_capital`)

| Instruction | EVM equivalent |
|-------------|----------------|
| `initialize_audit_pool` | deploy + fee config |
| `stake_audit` / `unstake_audit` | `stake` / `unstake` |
| `cover_listing` | `coverListing` |
| `fund_audit_rewards` | `fundAuditRewards` (per-coverage accrual in tx) |
| `claim_audit_reward` | `claimAuditReward` |
| `observe_listing_price` | `observeSharePrice` + baseline seed |
| `trigger_listing_default` | `triggerDefault` (−50% drawdown) |

PDAs: `audit_pool`, `audit_pool_vault_ata`, `auditor_stake`, `listing_audit`, `coverage` (per listing + auditor).

### Tests

```bash
cd aimarket-hub && pytest tests/test_acex_audit.py tests/test_acex_ipo_api.py -q
cd acex/contracts/evm && forge test -q
pytest tests/test_acex_phase2.py -q
cd apps/pulse-terminal && npm run build
```

### Planned (post Phase 2)

- On-chain bridge worker: hub accrue → EVM `fundAuditRewards` when `ACEX_AUDIT_BRIDGE_MODE=onchain`
- Index `ListingCovered`, `ListingDefaulted`, `AuditRewardClaimed` from chain into hub DB
- PulseAMM hedging: auditors delta-hedge CapShare insurance book

## Economics

- **TVL:** N auditors × 10k+ USDC stake + locked cover
- **Capital auction:** higher aggregate score → lower `suggestedNoteSpreadBps` → cheaper agent capital
- **Real protection:** slash flows to note holders, not a vanity rating
