// Captured under Anchor 0.30.1 before the dependency migration.
use ::acex_capital::*;
use anchor_lang::{prelude::Pubkey, AccountSerialize, InstructionData};
fn emit(name: &str, data: &[u8]) {
    let hex: String = data.iter().map(|b| format!("{b:02x}")).collect();
    println!("{name}\t{hex}");
    #[cfg(test)]
    {
        let baseline = include_str!("../tests/fixtures/anchor-0.30.1-abi.tsv");
        let expected = baseline
            .lines()
            .find_map(|line| {
                line.split_once('\t')
                    .filter(|(key, _)| *key == name)
                    .map(|(_, value)| value)
            })
            .expect("frozen pre-migration fixture");
        assert_eq!(hex, expected, "wire compatibility changed for {name}");
    }
}
fn account(name: &str, value: impl AccountSerialize) {
    let mut bytes = Vec::new();
    value.try_serialize(&mut bytes).unwrap();
    emit(name, &bytes);
}
fn main() {
    emit("instruction.initialize", &instruction::Initialize {}.data());
    emit(
        "instruction.set_paused",
        &instruction::SetPaused { paused: true }.data(),
    );
    emit(
        "instruction.set_auditor",
        &instruction::SetAuditor { is_auditor: true }.data(),
    );
    emit(
        "instruction.apply_listing",
        &instruction::ApplyListing {
            listing_id: [17; 32],
            metadata_hash: [17; 32],
        }
        .data(),
    );
    emit(
        "instruction.record_audit",
        &instruction::RecordAudit {
            listing_id: [17; 32],
            score_bps: 4321,
        }
        .data(),
    );
    emit(
        "instruction.approve_listing",
        &instruction::ApproveListing {
            listing_id: [17; 32],
            share_mint: Pubkey::new_from_array([34; 32]),
            max_supply: 123456789,
        }
        .data(),
    );
    emit(
        "instruction.reject_listing",
        &instruction::RejectListing {
            listing_id: [17; 32],
        }
        .data(),
    );
    emit(
        "instruction.deposit_collateral",
        &instruction::DepositCollateral {
            listing_id: [17; 32],
            amount: 123456789,
        }
        .data(),
    );
    emit(
        "instruction.lock_collateral",
        &instruction::LockCollateral {
            listing_id: [17; 32],
            amount: 123456789,
        }
        .data(),
    );
    emit(
        "instruction.release_collateral",
        &instruction::ReleaseCollateral {
            listing_id: [17; 32],
            amount: 123456789,
        }
        .data(),
    );
    emit(
        "instruction.create_capsense_series",
        &instruction::CreateCapsenseSeries {
            listing_id: [17; 32],
            strike_index_bps: 123456789,
            expiry_ts: -123456789,
        }
        .data(),
    );
    emit(
        "instruction.buy_capsense_option",
        &instruction::BuyCapsenseOption {
            listing_id: [17; 32],
            strike_index_bps: 123456789,
            expiry_ts: -123456789,
            contracts: 123456789,
            premium_per_contract: 123456789,
        }
        .data(),
    );
    emit(
        "instruction.exercise_capsense_option",
        &instruction::ExerciseCapsenseOption {
            listing_id: [17; 32],
            strike_index_bps: 123456789,
            expiry_ts: -123456789,
            index_level_bps: 123456789,
        }
        .data(),
    );
    emit(
        "instruction.initialize_audit_pool",
        &instruction::InitializeAuditPool {
            audit_fee_bps: 4321,
        }
        .data(),
    );
    emit(
        "instruction.stake_audit",
        &instruction::StakeAudit { amount: 123456789 }.data(),
    );
    emit(
        "instruction.unstake_audit",
        &instruction::UnstakeAudit { amount: 123456789 }.data(),
    );
    emit(
        "instruction.cover_listing",
        &instruction::CoverListing {
            listing_id: [17; 32],
            cover_amount: 123456789,
            score_bps: 4321,
        }
        .data(),
    );
    emit(
        "instruction.fund_audit_rewards",
        &instruction::FundAuditRewards {
            listing_id: [17; 32],
            reward_auditor: Pubkey::new_from_array([34; 32]),
            gross_amount: 123456789,
        }
        .data(),
    );
    emit(
        "instruction.claim_audit_reward",
        &instruction::ClaimAuditReward {
            listing_id: [17; 32],
        }
        .data(),
    );
    emit(
        "instruction.observe_listing_price",
        &instruction::ObserveListingPrice {
            listing_id: [17; 32],
            baseline_price_e6: 123456789,
            twap_price_e6: 123456789,
        }
        .data(),
    );
    emit(
        "instruction.trigger_listing_default",
        &instruction::TriggerListingDefault {
            listing_id: [17; 32],
            slashed_auditor: Pubkey::new_from_array([34; 32]),
        }
        .data(),
    );
    account(
        "account.ProgramConfig",
        ProgramConfig {
            admin: Pubkey::new_from_array([34; 32]),
            usdc_mint: Pubkey::new_from_array([34; 32]),
            initialized: true,
            paused: true,
        },
    );
    account("account.AuditorRecord", AuditorRecord { is_auditor: true });
    account(
        "account.Listing",
        Listing {
            agent: Pubkey::new_from_array([34; 32]),
            listing_id: [17; 32],
            metadata_hash: [17; 32],
            audit_score_bps: 4321,
            status: 7,
            share_mint: Pubkey::new_from_array([34; 32]),
            max_supply: 123456789,
            listed_at: -123456789,
            bump: 7,
        },
    );
    account(
        "account.CollateralAccount",
        CollateralAccount {
            listing_id: [17; 32],
            usdc_balance: 123456789,
            locked_for_notes: 123456789,
            bump: 7,
        },
    );
    account(
        "account.CapsenseSeries",
        CapsenseSeries {
            listing_id: [17; 32],
            strike_index_bps: 123456789,
            expiry_ts: -123456789,
            open_interest: 123456789,
            premium_pool: 123456789,
            settled: true,
            bump: 7,
        },
    );
    account(
        "account.CapsensePosition",
        CapsensePosition {
            buyer: Pubkey::new_from_array([34; 32]),
            series: Pubkey::new_from_array([34; 32]),
            contracts: 123456789,
            premium_paid: 123456789,
            exercised: true,
            bump: 7,
        },
    );
    account(
        "account.AuditPoolConfig",
        AuditPoolConfig {
            initialized: true,
            audit_fee_bps: 4321,
            bump: 7,
        },
    );
    account(
        "account.AuditorStakeAccount",
        AuditorStakeAccount {
            auditor: Pubkey::new_from_array([34; 32]),
            staked: 123456789,
            locked_stake: 123456789,
            bump: 7,
        },
    );
    account(
        "account.ListingAuditState",
        ListingAuditState {
            listing_id: [17; 32],
            aggregate_score_bps: 4321,
            total_cover: 123456789,
            defaulted: true,
            approved_at: -123456789,
            baseline_price_e6: 123456789,
            twap_price_e6: 123456789,
            compensation_pool: 123456789,
            bump: 7,
        },
    );
    account(
        "account.CoverageRecord",
        CoverageRecord {
            listing_id: [17; 32],
            auditor: Pubkey::new_from_array([34; 32]),
            cover_amount: 123456789,
            score_bps: 4321,
            phase: 7,
            pending_rewards: 123456789,
            claimed_rewards: 123456789,
            bump: 7,
        },
    );
    let id = [17u8; 32];
    let user = Pubkey::new_from_array([34; 32]);
    let strike = 123456789u64.to_le_bytes();
    let expiry = (-123456789i64).to_le_bytes();
    for (name, seeds) in [
        ("config", vec![b"config".as_ref()]),
        ("listing", vec![b"listing".as_ref(), &id]),
        ("collateral", vec![b"collateral".as_ref(), &id]),
        ("vault", vec![b"vault".as_ref(), &id]),
        ("vault_ata", vec![b"vault_ata".as_ref(), &id]),
        (
            "capsense",
            vec![b"capsense".as_ref(), &id, &strike, &expiry],
        ),
        (
            "capsense_vault",
            vec![b"capsense_vault".as_ref(), &id, &strike, &expiry],
        ),
        (
            "capsense_vault_ata",
            vec![b"capsense_vault_ata".as_ref(), &id, &strike, &expiry],
        ),
        ("audit_pool", vec![b"audit_pool".as_ref()]),
        ("audit_pool_vault", vec![b"audit_pool_vault".as_ref()]),
        (
            "audit_pool_vault_ata",
            vec![b"audit_pool_vault_ata".as_ref()],
        ),
        (
            "auditor_stake",
            vec![b"auditor_stake".as_ref(), user.as_ref()],
        ),
        ("coverage", vec![b"coverage".as_ref(), &id, user.as_ref()]),
        ("listing_audit", vec![b"listing_audit".as_ref(), &id]),
    ] {
        let (key, bump) = Pubkey::find_program_address(&seeds, &ID);
        let mut bytes = key.to_bytes().to_vec();
        bytes.push(bump);
        emit(&format!("pda.{name}"), &bytes);
    }
}

#[test]
fn pre_migration_account_instruction_and_pda_abi_is_unchanged() {
    main();
}
