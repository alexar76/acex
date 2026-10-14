# Proof-of-Audit — Agent Audit Pool

**Version:** 0.1.1  
**Contract:** `AgentAuditPool.sol` · `AgentNoteToken.sol` (default freeze) · Solana `acex_capital` PoA instructions  
**Status:** EVM + Hub ledger + Pulse Terminal + Solana mirror **shipped**

This contract is **insurance**, not a code scanner. Off-chain technical packs come from
[BASANOS](https://github.com/alexar76/basanos) (`agent.security.contract-assurance@v1`).
`scoreBps` on `coverListing` is an economic assertion by a staker, not a static-analysis grade.
HEPHAESTUS (`forge.modelmarket.dev`) is the capability-chain studio — different product.

## Auditor is an agent (standard as of 2026-09-14)

ALP **score** is produced by **`ai-auditor:acex-v1`**, not by a human committee and not by
an admin typing `audit_score_bps`. The pack (`acex/integrations/ai_audit.py`) scores live
catalog evidence (priced schemas, route, 30d observations) plus **MOMUS** signed FINDINGs
that apply to that product. Integrity FINDING (high/critical) on the listing is a hard
refuse. A human operator may *run* the agent; a human may **not** raise the score.

Hub HTTP `POST /capital/ipo` with `audit_score_bps` returns `human_audit_override_forbidden`
when `ACEX_REQUIRE_AI_AUDIT=1` (default). Empty local catalog falls back to Hub search
(`ACEX_HUB_SEARCH_URL`) so federated products such as `atlas.products` can still be scored.
Pulse Terminal shows overlay-only listings (`nav_source: unpriced_until_pool`) until an
AMM pool exists; factory catalog absence is not a reason to hide a floated CapShare.

**First market ops:** [first-market-launch.md](../docs/first-market-launch.md) — Hub Postgres
cap table + `--hub-float` + PulseAMM `createPool` dry-run.

**First market ops:** [first-market-launch.md](../docs/first-market-launch.md) — Hub Postgres
cap table + `--hub-float` + PulseAMM `createPool` dry-run.

On-chain `AgentAuditPool` stake ($10k) remains the **insurance** layer. The AI pack is the
**admission** layer. They are not interchangeable: a passing pack without cover is an
uninsured listing; cover without a pack is the legacy human/allowlist path and is no
longer how Hub floats CapShares.

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
| `observeSharePrice(id)` | Snapshot of PulseAMM's time-weighted price accumulator (anyone; one sample per block; never sets baseline) |
| `captureBaseline(id)` | One-shot baseline when AMM pool exists (within 30d of approve; required before default) |
| `triggerDefault(id)` | Permissionless if the TWAP **since the baseline** is ≥50% below it after 7d, and the block-start price still is |
| `triggerNoteDefault(id)` | Owner path for note insolvency |
| `claimDefaultCompensation(id, noteAmt)` | Note holders burn notes in-place; transfers frozen at default |
| `suggestedNoteSpreadBps(id)` | Score → note rate curve (view) |
| `getListingAuditState(id)` | Aggregate cover, score, baseline, TWAP, default flags (view) |
| `twapPriceE18(id)` / `twapSinceBaselineE18(id)` | Time-weighted price since the pool was first observed / since the baseline (views) |
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

## Oracle (2026-10-08)

- **PulseAMM accumulates price × time** before every swap moves the reserves (the Uniswap
  v2 shape), so a price counts for exactly as long as it held. The sample-and-hold average
  it replaced weighted a sample until the next observation: a crash held across one block
  boundary, observed once a day, manufactured a default (review PoC).
- **No time before the pool exists** enters the average (it used to, at price 0, and let a
  baseline be captured near zero); two observations in one block are one sample.
- **Only a pool quoted in the audit pool's USDC** prices anything; PulseAMM's quote token is
  set once by its owner.
- The block-start price (reserves as the block began) is the spot check, so a flash swap
  inside the triggering transaction proves nothing.

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
