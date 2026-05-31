# Testing

## EVM (Foundry)

```bash
cd contracts/evm
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts --no-git
forge test -vv
```

**Coverage:** ALP listing, audit/reject/pause, CapShares lock, AgentNotes redeem, LiquidityMesh borrow/repay, Pulse AMM swaps, **AgentAuditPool** (stake, cover, rewards, default slash).

Hub Proof-of-Audit ledger:

```bash
cd aimarket-hub
pytest tests/test_acex_audit.py tests/test_acex_ipo_api.py -q
```

## Python (monorepo root)

```bash
pytest tests/test_acex_docs.py tests/test_desktop_sku_manifest.py tests/test_killer_features_docs.py tests/test_ai_market_protocol_v2.py -q
```

## Solana

### Prerequisites (ACEX `acex_capital`)

| Tool | Minimum | Why |
|------|---------|-----|
| Rust (host) | **1.85+** | crates.io `edition2024` manifests |
| Solana CLI | **stable (Agave 2.x+)** | `cargo-build-sbf`, platform-tools |
| Anchor CLI | **0.30.1** (optional) | IDL + `anchor test` |

See [../contracts/solana/README.md](../contracts/solana/README.md) for install commands and lockfile notes.

```bash
cd acex/contracts/solana
source "$HOME/.cargo/env"   # rustup 1.85+
export PATH="$HOME/.local/share/solana/install/active_release/bin:$PATH"
cargo build-sbf --manifest-path programs/acex-capital/Cargo.toml --locked
```

### Escrow program (monorepo root)

```bash
cd contracts/solana
anchor build
# anchor test when local validator available
```

ACEX `acex_capital` CI: job **`acex-solana-build`** in `.github/workflows/contracts-ci.yml`.
