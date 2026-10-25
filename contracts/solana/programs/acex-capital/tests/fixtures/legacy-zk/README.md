# Frozen Solana ZK compatibility vectors

Captured on 2026-10-25 from unmodified registry `bincode 1.3.3`,
`solana-zk-sdk 4.0.0` and `curve25519-dalek 4.1.3`, before replacing the codec.
The isolated baseline generator used `/private/tmp/acex-bincode-baseline`;
its direct dependency versions and output are recorded in `bincode-1.3.3.json`.

The key seed `[7; 32]` and opening scalar `11` are public, disposable test
vectors. They are not credentials or operational keys. Proofs are public
verification data. The two proof files were generated and verified by the old
SDK, then frozen; the new graph must verify these exact bytes and reject the
same last-byte tampering.

`wire.tsv` retains seven deterministic Serde encodings, four ciphertext
vectors and the SHA-256 of every precomputation map entry sorted by key
(`key[32] || value_u16_le`). The embedded legacy table has 65,536 entries and
2,228,232 bytes. Comparing the complete decoded-map fingerprint catches the
SDK's silent `unwrap_or_default()` fallback to an empty map on decode failure.

The original codec accepted trailing bytes, rejected short inputs and rejected
noncanonical scalars or invalid Ristretto encodings. Raw baseline error messages
are retained in JSON; application error mapping is tested separately in the
lottery/system fixtures.
