# First CapShare market launch (Hub float → PulseAMM)

Off-chain CapShares on the Hub are **not** a market. A market needs (1) Hub IPO
with `ai-auditor:acex-v1`, (2) Postgres-backed ACEX ledgers, (3) an on-chain
PulseAMM pool with ≥ 1 000 USDC seed.

## 0. Prerequisites

- Hub prod: `AIFACTORY_PROD=1`, `DATABASE_URL=postgresql://…`
- `ACEX_REQUIRE_AI_AUDIT=1`, `ACEX_AUTO_IPO=0` in durable `deploy/hub-payment.env`
- `AIMARKET_ADMIN_TOKEN` available to the operator
- Redeployed Hub image that includes Postgres ACEX ledgers (`acex_*` tables)

## 1. Probe the AI-audit gate

```bash
# Must return human_audit_override_forbidden (gate is live):
curl -sS -X POST https://modelmarket.dev/ai-market/v2/capital/ipo \
  -H "Authorization: Bearer $AIMARKET_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"product_id":"atlas.products","audit_score_bps":9000}'
```

## 2. Admin float (Hub runs the AI pack)

```bash
# Dry-run pack locally, then float on Hub (no audit_score_bps in the POST):
python scripts/launch_first_capshare.py --product atlas.products --hub-float
```

Confirm:

```bash
curl -sS https://modelmarket.dev/ai-market/v2/capital/listings | jq .
```

Listing should show `auditor_id=ai-auditor:acex-v1` and a non-empty `audit_pack_sha256`.

## 3. On-chain PulseAMM (separate deployer step)

Base mainnet addresses (see `config/deployments/base-mainnet.json`):

| Contract | Address |
|----------|---------|
| PulseAMM | `0x0A70AA84903ecB2E0aF5c435AFd9EDd178559E47` |
| AgentListingRegistry | `0x3636A636262940Ff4E49aC1BCf34b958F589acC9` |
| AgentAuditPool | `0xE0C711Ef82F9C97eefBF4C0e715de1b09F8a6160` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

Operator sequence (after CapShare token exists on-chain via registry approve/mint):

1. Owner: `PulseAMM.setMarketMaker(mm, true)`
2. MM: approve CapShare + USDC to PulseAMM
3. MM: `createPool(shareToken, usdc, shareAmount, usdcAmount)` with **usdcAmount ≥ 1000e6**
4. Anyone: `AgentAuditPool.captureBaseline(listingId)` within 30 days of approve

Dry-run calldata (no broadcast):

```bash
python acex/scripts/pulse_amm_create_pool_plan.py \
  --share-token 0x... \
  --share-amount 1000000000000000000000 \
  --usdc-amount 1000000000
```

Add `--broadcast` only with `ACEX_DEPLOYER_KEY` / `PRIVATE_KEY` set and confirmed balances.

## 4. ARGUS trade check

After the pool is `active`, enable ARGUS economy ACEX and confirm `acex_trade` no longer
returns "No active PulseAMM pool".

## Explicit non-goals until seed is funded

- Do not set `ACEX_AUTO_IPO=1` fleet-wide.
- Do not enable `ACEX_MIN_LISTING_REVENUE_USD` until `prior_revenue_usd` is wired into
  `POST /capital/ipo` and auto-listing.
