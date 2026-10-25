# ACEX Solana — `acex_capital`

Agent Listing Protocol, collateral, CapSense options and Proof-of-Audit mirror.

Program ID: `9BkXiRFMB5bAMMqAXxTzaLPYspiGxoUTEeX8kih9ne73`. The dependency migration preserves this ID, PDA seeds, instruction discriminators/argument encoding and account layouts. The ABI test uses 45 fixtures captured from the original Anchor 0.30.1 build.

## Reproducible local builds

The workspace pins Anchor **1.2.1**, host Rust **1.96.0**, and Agave CLI **4.1.2**. Anchor uses its supported default Solana v3 crate cohort. Agave's platform-tools **v1.54** supplies the SBF compiler (Rust 1.89); the host Rust version does not replace that compiler.

```bash
cd acex/contracts/solana
cargo test --locked --all-targets
cargo build-sbf --manifest-path programs/acex-capital/Cargo.toml --tools-version v1.54 -- --locked
cargo check --locked --features idl-build
```

Use the committed lockfile. Both Anchor crates retain their original SPL default feature coverage, including Token-2022 interfaces. The deployed program continues to accept the original SPL Token program for its settlement accounts.

Official migration references: [Anchor 1.0 breaking changes](https://www.anchor-lang.com/docs/updates/release-notes/1-0-0), [Anchor 1.2.1](https://www.anchor-lang.com/docs/updates/release-notes/1-2-1), [Agave 4.1.2 recommendation](https://www.anchor-lang.com/docs/updates/release-notes/1-2-0).

## Required signing changes

`buy_capsense_option` and `exercise_capsense_option` carry off-chain premium/index quotes. The configured `config.admin` must now co-sign the transaction to attest those values. Append `AccountMeta::new_readonly(config.admin, true)` to the instruction's accounts and have both the buyer and admin sign. If the buyer is the admin, its existing signer account suffices. A public key without its transaction signature is rejected. The instruction arguments and existing account order are unchanged.

`observe_listing_price` now requires the existing observer signer to equal `config.admin`. Prices must be nonzero. `set_paused` requires its existing config account to be writable; regenerate client account metadata accordingly. These are deliberate authorization fixes. There are no checked-in CapSense transaction builders to update.

All settlement mint accounts must match `config.usdc_mint`; source and destination token accounts must also have the expected mint and owner. Audit fees cannot exceed 10,000 bps. Repeated coverage updates lock only the additional coverage. Slashing deducts both staked and locked balances, retains compensation in the pool, and can process each covered auditor once; new coverage after default is rejected. Option payouts reject values outside `u64` rather than truncating. Exercised positions reject purchases before charging another premium.

## What the tests verify

`examples/abi_snapshot.rs` checks all 21 public instruction encodings, all 10 serialized account layouts and 14 PDA/bump derivations against the frozen pre-migration fixtures. `tests/payments.rs` invokes the actual Anchor entrypoint and validates emitted SPL Transfer data, account metas and PDA signing seeds through the official host syscall seam. Its token runtime checks transfer authorities/mints and updates token balances, covering collateral deposit/lock/release, option purchase/exercise/replay, staking/coverage/rewards/withdrawal/slashing, missing signatures, unauthorized prices and pause persistence. It is a host CPI harness, not a validator execution of the SPL Token binary. SBF compilation is checked separately.

The modern graph removes the legacy vulnerable Borsh 0.9, ed25519-dalek 1, curve25519-dalek 3, rand 0.7 and other obsolete Solana 1.18 branches. The final unmaintained bincode 1.3.3 dependency is also removed: four minimal, checksum-verifiable Anchor/Solana patches under `security/vendor-rust` use `aimarket-legacy-wire` over maintained bincode-next 2.1.0. No advisory ignore or warning suppression is used. Existing public APIs and legacy wire bytes are preserved. Four additional ZK regressions verify seven frozen key/ciphertext encodings, all 65,536 precomputation entries, edge-value decryption, old proof verification and tamper rejection. All eight native tests (including 45 ABI cases and payment scenarios), IDL and SBF builds pass. See `security/migrations/2026-10-25-bincode-replacement.md`.

Existing deployed accounts are not rewritten. Before any separately authorized upgrade, reconcile historical coverage/slashing balances affected by the former accounting bugs and follow Anchor's legacy IDL migration instructions. This local migration does not deploy, publish IDLs or submit transactions.

## Spec

[Proof-of-Audit](../../protocol/proof-of-audit.md)


Code authorization hardening (2026-10-25): initialization now appends a read-only
`program_data` account. It must be the canonical PDA derived from this program ID
under `BPFLoaderUpgradeab1e11111111111111111111111`, owned by that loader, contain
`ProgramData`, and name the initializer signer as its current upgrade authority.
Initialize before making a program immutable. This prevents a stranger from
front-running deployment and choosing the singleton admin/authority and treasury.
Existing config/state layouts and instruction argument bytes are unchanged; fresh
initialization clients must append the loader ProgramData account. The local
validator test uses `--upgradeable-program` and a published throwaway authority
seed, confined to loopback. No on-chain deployment was performed.
