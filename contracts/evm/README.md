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
| AgentCollateralVault | [`0xF9A387c4e81DE49dB303CE9Bd2489AF54821667E`](https://basescan.org/address/0xF9A387c4e81DE49dB303CE9Bd2489AF54821667E) |
| AgentListingRegistry | [`0xcF28770416294358af286a2E4a2e88d6c1f436C3`](https://basescan.org/address/0xcF28770416294358af286a2E4a2e88d6c1f436C3) |
| AgentLendingPool | [`0xB0BE904642EDE39135A0F1c5e5A811925b1c2F48`](https://basescan.org/address/0xB0BE904642EDE39135A0F1c5e5A811925b1c2F48) |
| PulseAMM | [`0x049B839BD5B30797c27f1806E06172014c5d4337`](https://basescan.org/address/0x049B839BD5B30797c27f1806E06172014c5d4337) |
| AgentAuditPool | [`0x86a4A9A85895AA10B5a8A680a7c95F4a2C060Cee`](https://basescan.org/address/0x86a4A9A85895AA10B5a8A680a7c95F4a2C060Cee) |
| PulseDistributor | [`0x37F17f2B733d9D801C7f03f6A6D1E5cA8898775e`](https://basescan.org/address/0x37F17f2B733d9D801C7f03f6A6D1E5cA8898775e) |

⚠️ Deployed + wired + verified, but **NOT value-tested**: the audit rated AuditPool TWAP +
PulseAMM **HIGH**, so no real value is routed through them. Full context + every transaction:
[../../../docs/onchain-journal.md](../../../docs/onchain-journal.md).

## Security

See [../../docs/security/audit-2026-05.md](../../docs/security/audit-2026-05.md).

## Networks & RPC
ACEX deploys via Foundry `--rpc-url`. Runtime chain readers select their network and fail over
across RPC endpoints through the shared chain registry — default **Base**. See
[../../../docs/chain-networks.md](../../../docs/chain-networks.md).
