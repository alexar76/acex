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

## Security

See [../../docs/security/audit-2026-05.md](../../docs/security/audit-2026-05.md).
