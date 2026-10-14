# ACEX Solana — `acex_capital`

Agent Listing Protocol + collateral + Proof-of-Audit mirror (`stake_audit`, `cover_listing`, `fund_audit_rewards`, …).

**Program ID (dev):** `9BkXiRFMB5bAMMqAXxTzaLPYspiGxoUTEeX8kih9ne73` — in `declare_id!` and `Anchor.toml`.

## Why `cargo build-sbf` fails on old Rust

Recent crates.io releases (`cpufeatures` 0.3, `toml_parser`, `wit-bindgen`, …) declare **`edition2024`**. Solana **1.18** platform-tools still bundle **Cargo 1.75**, which cannot even *parse* those manifests.

**Fix (all three):**

1. **Host Rust ≥ 1.85** — `rust-toolchain.toml` pins `1.85.0` (install via [rustup](https://rustup.rs)).
2. **Solana CLI stable (Agave 2.x / 4.x)** — `curl -sSfL https://release.anza.xyz/stable/install | sh`
3. **Committed `Cargo.lock`** — pins `blake3` ≤1.5.5 so `solana-program` does not pull `cpufeatures` 0.3.
4. **`anchor-lang` feature `init-if-needed`** — required for `init_if_needed` account constraints.

```bash
curl -sSfL https://release.anza.xyz/stable/install | sh
curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.85.0
source "$HOME/.cargo/env"
export PATH="$HOME/.local/share/solana/install/active_release/bin:$PATH"

cd acex/contracts/solana
cargo build-sbf --manifest-path programs/acex-capital/Cargo.toml
cargo test-sbf -p acex-capital    # Anchor test_id + future integration tests
```

## CI

`.github/workflows/contracts-ci.yml` job **`acex-solana-build`** — Rust 1.85 + Solana stable + `build-sbf` + `test-sbf`.

## Spec

[../../protocol/proof-of-audit.md](../../protocol/proof-of-audit.md)
