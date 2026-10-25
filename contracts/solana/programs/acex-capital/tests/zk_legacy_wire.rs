//! Host crypto/serialization compatibility with the frozen, unmodified old SDK.
//! All seeds and key material here are public disposable test vectors.
use aimarket_legacy_wire as wire;
use anchor_lang::__private::bytemuck;
use anchor_spl::token_2022::spl_token_2022::solana_zk_sdk::{
    encryption::{
        discrete_log::DECODE_PRECOMPUTATION_FOR_G,
        elgamal::{
            DecryptHandle, ElGamalCiphertext, ElGamalKeypair, ElGamalPubkey, ElGamalSecretKey,
        },
        pedersen::{Pedersen, PedersenCommitment, PedersenOpening},
    },
    zk_elgamal_proof_program::proof_data::{
        PubkeyValidityProofData, ZeroCiphertextProofData, ZkProofData,
    },
};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

fn fixture(name: &str) -> Vec<u8> {
    let value = include_str!("fixtures/legacy-zk/wire.tsv")
        .lines()
        .find_map(|line| {
            line.split_once('\t')
                .filter(|(key, _)| *key == name)
                .map(|(_, value)| value)
        })
        .expect("frozen pre-migration vector");
    value
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
        .collect()
}

fn keypair() -> ElGamalKeypair {
    ElGamalKeypair::new(ElGamalSecretKey::from_seed(&[7u8; 32]).unwrap())
}
fn opening() -> PedersenOpening {
    let mut scalar = [0u8; 32];
    scalar[0] = 11;
    PedersenOpening::from_bytes(&scalar).unwrap()
}

#[test]
fn legacy_zk_keys_ciphertexts_and_openings_preserve_wire_and_reject_invalid_encodings() {
    let keypair = keypair();
    let opening = opening();
    macro_rules! check {
        ($ty:ty, $name:literal, $value:expr) => {{
            let expected = fixture($name);
            let actual = wire::serialize(&$value).unwrap();
            assert_eq!(actual, expected, "legacy serialization changed: {}", $name);
            assert_eq!(
                wire::serialized_size(&$value).unwrap(),
                expected.len() as u64
            );
            let mut writer = Vec::new();
            wire::serialize_into(&mut writer, &$value).unwrap();
            assert_eq!(writer, expected);
            let decoded: $ty = wire::deserialize(&expected).unwrap();
            assert_eq!(wire::serialize(&decoded).unwrap(), expected);
            // Legacy default decoders accept account padding after a complete value.
            let mut padded = expected.clone();
            padded.extend([0xaa, 0xbb]);
            let decoded: $ty = wire::deserialize(&padded).unwrap();
            assert_eq!(wire::serialize(&decoded).unwrap(), expected);
            assert!(wire::deserialize::<$ty>(&[]).is_err(), "empty {}", $name);
            assert!(
                wire::deserialize::<$ty>(&expected[..expected.len() - 1]).is_err(),
                "truncated {}",
                $name
            );
            assert!(
                wire::deserialize::<$ty>(&vec![0xff; expected.len()]).is_err(),
                "invalid point/scalar {}",
                $name
            );
        }};
    }
    check!(ElGamalKeypair, "ElGamalKeypair", keypair);
    check!(ElGamalPubkey, "ElGamalPubkey", keypair.pubkey());
    check!(ElGamalSecretKey, "ElGamalSecretKey", keypair.secret());
    check!(
        ElGamalCiphertext,
        "ElGamalCiphertext",
        keypair.pubkey().encrypt_with(77u64, &opening)
    );
    check!(
        DecryptHandle,
        "DecryptHandle",
        keypair.pubkey().decrypt_handle(&opening)
    );
    check!(PedersenOpening, "PedersenOpening", opening);
    check!(
        PedersenCommitment,
        "PedersenCommitment",
        Pedersen::with(77u64, &opening)
    );
}

#[test]
fn sdk_embedded_precomputation_decodes_all_legacy_entries_without_silent_empty_fallback() {
    // The SDK loads its original embedded old-codec blob and uses unwrap_or_default
    // on failure. Its public Serde wrapper exposes the actual initialized table.
    let encoded = wire::serialize(&*DECODE_PRECOMPUTATION_FOR_G).unwrap();
    assert_eq!(encoded.len(), 2_228_232);
    let table: HashMap<[u8; 32], u16> = wire::deserialize(&encoded).unwrap();
    assert_eq!(table.len(), 65_536);
    let mut entries: Vec<_> = table.into_iter().collect();
    entries.sort_by_key(|(key, _)| *key);
    let mut digest = Sha256::new();
    for (key, value) in entries {
        digest.update(key);
        digest.update(value.to_le_bytes());
    }
    assert_eq!(
        digest.finalize().as_slice(),
        fixture("precomputation.sha256")
    );
    assert!(wire::deserialize::<HashMap<[u8; 32], u16>>(&encoded[..encoded.len() - 1]).is_err());
}

#[test]
fn legacy_ciphertexts_decrypt_zero_small_and_u32_edge_amounts() {
    let keypair = keypair();
    let opening = opening();
    for amount in [0u64, 77, 65_536, u32::MAX as u64] {
        let legacy_bytes = fixture(&format!("decrypt.{amount}"));
        let legacy = ElGamalCiphertext::from_bytes(&legacy_bytes).unwrap();
        assert_eq!(legacy.to_bytes().as_slice(), legacy_bytes);
        assert_eq!(keypair.pubkey().encrypt_with(amount, &opening), legacy);
        assert_eq!(keypair.secret().decrypt_u32(&legacy), Some(amount));
    }
}

#[test]
fn frozen_legacy_proofs_verify_and_tampering_preserves_rejection() {
    let pubkey_bytes = include_bytes!("fixtures/legacy-zk/pubkey_validity.proof");
    let zero_bytes = include_bytes!("fixtures/legacy-zk/zero_ciphertext.proof");
    assert_eq!(
        pubkey_bytes.len(),
        std::mem::size_of::<PubkeyValidityProofData>()
    );
    assert_eq!(
        zero_bytes.len(),
        std::mem::size_of::<ZeroCiphertextProofData>()
    );
    let valid = bytemuck::pod_read_unaligned::<PubkeyValidityProofData>(pubkey_bytes);
    let zero = bytemuck::pod_read_unaligned::<ZeroCiphertextProofData>(zero_bytes);
    valid.verify_proof().unwrap();
    zero.verify_proof().unwrap();
    let keypair: ElGamalKeypair = wire::deserialize(&fixture("ElGamalKeypair")).unwrap();
    assert_eq!(
        bytemuck::bytes_of(&valid.context.pubkey),
        fixture("ElGamalPubkey")
    );
    PubkeyValidityProofData::new(&keypair)
        .unwrap()
        .verify_proof()
        .unwrap();
    let mut modified = pubkey_bytes.to_vec();
    let last = modified.len() - 1;
    modified[last] ^= 1;
    let bad = bytemuck::pod_read_unaligned::<PubkeyValidityProofData>(&modified);
    assert_eq!(
        format!("{:?}", bad.verify_proof().unwrap_err()),
        "SigmaProof(PubkeyValidity, AlgebraicRelation)"
    );
    let mut modified = zero_bytes.to_vec();
    let last = modified.len() - 1;
    modified[last] ^= 1;
    let bad = bytemuck::pod_read_unaligned::<ZeroCiphertextProofData>(&modified);
    assert_eq!(
        format!("{:?}", bad.verify_proof().unwrap_err()),
        "SigmaProof(ZeroCiphertext, AlgebraicRelation)"
    );
}
