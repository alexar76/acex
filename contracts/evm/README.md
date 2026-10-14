# ACEX EVM contracts

Capital markets contracts for Base / Ethereum (USDC collateral).

## Contracts

| Contract | Purpose |
|----------|---------|
| `AgentListingRegistry` | ALP — listing applications, audit, CapShare deployment |
| `AgentAuditPool` | Proof-of-Audit — staked auditors, TWAP default, note compensation |
| `AgentShareToken` | ERC-20 CapShares per listing |
| `AgentNoteToken` | ERC-20 AgentNotes (bonds) with maturity + default freeze |
| `AgentCollateralVault` | Escrow collateral for notes + lending |
| `AgentLendingPool` | LiquidityMesh — deposit / borrow USDC |
| `PulseAMM` | Constant-product AMM for CapShare/USDC |
| `PulseDistributor` | Merkle revenue epochs for CapShare holders |

See [../../protocol/proof-of-audit.md](../../protocol/proof-of-audit.md) for audit pool API.

## Setup

```bash
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts --no-commit
forge build
forge test -vv
```

## Deploy (Base Sepolia)

```bash
export RPC_BASE_SEPOLIA=...
forge script script/DeployACEX.s.sol --rpc-url $RPC_BASE_SEPOLIA --broadcast
```

## Deployed on Base mainnet (demo)

Live + **source-verified on Sourcify (exact match)** (chainId 8453), owned by the demo wallet
`0x1218ff36C5d2e3B6A565CdB1A8B1AcCFc606Ad0a`:

| Contract | Address |
|---|---|
| AgentCollateralVault | [`0xdAa073EDCA17328188Afe5A83394Fc7b5E42081c`](https://basescan.org/address/0xdAa073EDCA17328188Afe5A83394Fc7b5E42081c) |
| AgentListingRegistry | [`0x3636A636262940Ff4E49aC1BCf34b958F589acC9`](https://basescan.org/address/0x3636A636262940Ff4E49aC1BCf34b958F589acC9) |
| AgentLendingPool | [`0x51a61d25b799C17A012eB671e3EDe2569E2d9C3d`](https://basescan.org/address/0x51a61d25b799C17A012eB671e3EDe2569E2d9C3d) |
| PulseAMM | [`0x0A70AA84903ecB2E0aF5c435AFd9EDd178559E47`](https://basescan.org/address/0x0A70AA84903ecB2E0aF5c435AFd9EDd178559E47) |
| AgentAuditPool | [`0xE0C711Ef82F9C97eefBF4C0e715de1b09F8a6160`](https://basescan.org/address/0xE0C711Ef82F9C97eefBF4C0e715de1b09F8a6160) |

> Redeployed **2026-10-13** from the source the 2026-10-08 live-vs-source audit found newer than the chain (a price counts for as long as it held, a baseline needs three samples, collateral is refused before the registry is set). The 2026-08-22 set it replaces held no funds and is superseded — see [`docs/onchain-journal.md`](https://github.com/alexar76/aicom/blob/main/docs/onchain-journal.md) §9 (and §2d for 08-22).
> Canonical machine-readable source: `config/deployments/base-mainnet.json`.

| PulseDistributor | [`0x325aC681FDd14c23DE074c15ac2Ed07702e38596`](https://basescan.org/address/0x325aC681FDd14c23DE074c15ac2Ed07702e38596) |

⚠️ Redeployed **2026-07-26** (audit-fixed ACEX). Full mainnet value cycle still deferred
(≥10k USDC stake + 1-day TWAP). Full context + every transaction:
[../../../docs/onchain-journal.md](https://github.com/alexar76/aicom/blob/main/docs/onchain-journal.md).

## Security

See [../../docs/security/audit-2026-05.md](../../docs/security/audit-2026-05.md).

## Networks & RPC
ACEX deploys via Foundry `--rpc-url`. Runtime chain readers select their network and fail over
across RPC endpoints through the shared chain registry — default **Base**. See
[../../../docs/chain-networks.md](https://github.com/alexar76/aicom/blob/main/docs/chain-networks.md).
