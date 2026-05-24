<!-- aicom-mirror-notice -->
> **Mirror — read-only.**
> The canonical source for `acex` lives in the AI-Factory monorepo.
> Open issues and PRs at `Superowner/aicom`; commits pushed here are
> overwritten by `scripts/mirror_satellites.sh` on the next sync run.
> See `docs/repository-canonical-policy.md` for the policy.

# ACEX — Agent Capital Exchange

<p align="center">
  <strong>Capital markets layer for the AI economy</strong><br/>
  Agent listings · capability shares · bonds · lending · derivatives · Pulse Terminal
</p>

**ACEX** (*Agent Capital Exchange*) extends [AIMarket Protocol v2](../aimarket-protocol/spec.md) with **capital markets primitives** for autonomous agents: IPO-style listings (ALP), tradeable CapShares, AgentNotes, LiquidityMesh lending, and Pulse Terminal.

> **Positioning:** Hub handles *commerce* (discover → invoke → settle). **ACEX** handles *capital* (list → raise → trade → hedge).
>
> **Integration model:** ACEX extends the AIMarket *Protocol spec* (JSON Schema), not the hub *codebase*. There are zero code imports between ACEX and hub — they integrate at the HTTP/JSON layer (well-known discovery, schema validation). ACEX has its own EVM/Solana contracts, its own docs, and its own deploy pipeline.
>
> **Repo layout:** ACEX core (`acex/`) and Pulse Terminal (`apps/pulse-terminal/`) are separate satellites with independent builds. Pulse Terminal consumes ACEX APIs over HTTP/WS but lives in its own compose stack. See [satellite-map.yaml](../scripts/satellite-map.yaml) for the full mirror topology.

| Former name | Current |
|-------------|---------|
| AISEX (AI Securities Exchange) | **ACEX** (Agent Capital Exchange) |

---

## Naming (canonical)

| Legacy / draft | Canonical name | Role |
|----------------|----------------|------|
| AI-IPO | **ALP** — Agent Listing Protocol | Listing, audit gate, mint agent shares |
| AI-Stocks | **CapShares** | ERC-20 shares tied to an agent listing |
| AI-Bonds | **AgentNotes** | Fixed-income against escrow collateral |
| AI-Lending | **LiquidityMesh** | Agent-to-agent USDC liquidity pool |
| AI-Derivatives | **CapSense Options** (Phase 2) | Options on capability revenue indices |
| AI-MarketMakers | **Pulse AMM** (EVM) · **Jupiter** (Solana Phase 2) | Liquidity for CapShares |
| AI Trading Terminal | **Pulse Terminal** | [`apps/pulse-terminal/`](../apps/pulse-terminal/) — WebSocket dashboard |

---

## Monorepo map

```
acex/
├── README.md                 ← you are here
├── docs/
│   ├── architecture.md
│   ├── testing.md
│   └── security/             ← audits by year
├── protocol/                 ← ALP + capital markets spec
├── contracts/evm/            ← Foundry: registry, shares, bonds, lending, AMM
└── contracts/solana/         ← Anchor: acex_capital program
```

---

## Ecosystem placement

```mermaid
flowchart TB
  subgraph commerce["Commerce layer"]
    HUB["AIMarket Hub"]
    PLG["aimarket-plugins"]
    WGT["aimarket-widget"]
  end

  subgraph capital["Capital layer · ACEX"]
    ALP["Agent Listing Protocol"]
    AMM["Pulse AMM / Jupiter"]
    LEND["LiquidityMesh"]
    TERM["Pulse Terminal"]
  end

  subgraph factory["Factory"]
    AICOM["aicom · Auto-Mesh Pipeline"]
  end

  AICOM --> HUB
  HUB --> ALP
  ALP --> AMM
  LEND --> AMM
  TERM --> HUB
  TERM --> ALP
  PLG --> ALP
```

---

## Phase 2 roadmap

| Item | Status |
|------|--------|
| CapSense Options on Solana | **Shipped** (`create_capsense_series`, `buy_capsense_option`, `exercise_capsense_option`) |
| Hub `GET /api/v2/capital/pricing` for Pulse Terminal | **Shipped** (Hub + Factory) |
| Jupiter route (Solana) vs on-chain AMM | **Shipped** ([jupiter-routing.md](docs/jupiter-routing.md)) |
| External audit before mainnet TVL | **Required** ([checklist](docs/security/pre-mainnet-checklist.md)) |

---

## Quick start (contracts)

**EVM (Foundry):**

```bash
cd acex/contracts/evm
chmod +x deploy.sh
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts --no-git
forge test -vv
./deploy.sh base-sepolia   # USDC_ADDRESS, DEPLOYER_PRIVATE_KEY, RPC
```

**Solana (Anchor):**

```bash
cd acex/contracts/solana
chmod +x deploy.sh
anchor build
./deploy.sh devnet
```

See [contracts/README.md](contracts/README.md) and [protocol/spec-capital-markets.md](protocol/spec-capital-markets.md).

---

## Documentation index

| Doc | Description |
|-----|-------------|
| [Architecture](docs/architecture.md) | C4, modules, trust boundaries |
| [Testing](docs/testing.md) | Forge + pytest commands |
| [Security audit 2026](docs/security/audit-2026-05.md) | Threat model + findings |
| [ALP spec](protocol/spec-capital-markets.md) | Agent Listing Protocol |

---

## License

Apache-2.0 — same as AIMarket Hub contracts.
