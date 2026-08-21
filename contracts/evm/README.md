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

Live + **source-verified on Basescan** (chainId 8453), owned by the demo wallet
`0x1218ff36C5d2e3B6A565CdB1A8B1AcCFc606Ad0a`:

| Contract | Address |
|---|---|
| AgentCollateralVault | [`0xA29d019F3B706B83C19f36E9BaCD83d22100fF45`](https://basescan.org/address/0xA29d019F3B706B83C19f36E9BaCD83d22100fF45) |
| AgentListingRegistry | [`0x04B8Ed69768b567F66c7473f1Ad53748D78a627D`](https://basescan.org/address/0x04B8Ed69768b567F66c7473f1Ad53748D78a627D) |
| AgentLendingPool | [`0x0ee6599bE35F9AbaFAB4c2182301a15016265B32`](https://basescan.org/address/0x0ee6599bE35F9AbaFAB4c2182301a15016265B32) |
| PulseAMM | [`0x96201B1A9eFC563293A1579dAaaDb038f728BFc9`](https://basescan.org/address/0x96201B1A9eFC563293A1579dAaaDb038f728BFc9) |
| AgentAuditPool | [`0x84991b78d3874e080aeDe1A4F7746c60eBe4039c`](https://basescan.org/address/0x84991b78d3874e080aeDe1A4F7746c60eBe4039c) |
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
