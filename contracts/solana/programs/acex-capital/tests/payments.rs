//! Local entrypoint tests. The host implements only SPL Transfer; every other
//! CPI fails closed. This verifies the actual instruction bytes and PDA signing
//! seeds sent by Anchor, rather than returning success for a no-op token CPI.
use ::acex_capital::instruction;
use ::acex_capital::*;
use anchor_lang::{
    prelude::*,
    solana_program::{
        instruction::Instruction, program_error::ProgramError, program_option::COption,
        program_pack::Pack,
    },
    AccountDeserialize, AccountSerialize, InstructionData,
};
use anchor_spl::token::{
    spl_token::{
        instruction::TokenInstruction,
        state::{Account as SplAccount, AccountState, Mint as SplMint},
    },
    ID as TOKEN_ID,
};
use solana_sysvar::program_stubs::{set_syscall_stubs, SyscallStubs};
use std::sync::Mutex;

static SYSCALL_LOCK: Mutex<()> = Mutex::new(());
const NOW: i64 = 100;
const LISTING_ID: [u8; 32] = [17; 32];
fn pda(seeds: &[&[u8]]) -> (Pubkey, u8) {
    Pubkey::find_program_address(seeds, &ID)
}

struct TokenRuntime;
impl SyscallStubs for TokenRuntime {
    fn sol_get_clock_sysvar(&self, out: *mut u8) -> u64 {
        // The syscall ABI supplies writable aligned storage for a Clock.
        unsafe {
            (out as *mut Clock).write(Clock {
                unix_timestamp: NOW,
                ..Clock::default()
            });
        }
        0
    }
    fn sol_get_rent_sysvar(&self, out: *mut u8) -> u64 {
        unsafe {
            (out as *mut Rent).write(Rent::default());
        }
        0
    }
    fn sol_invoke_signed(
        &self,
        ix: &Instruction,
        infos: &[AccountInfo],
        seeds: &[&[&[u8]]],
    ) -> std::result::Result<(), ProgramError> {
        assert_eq!(
            ix.program_id, TOKEN_ID,
            "unexpected CPI must not silently succeed"
        );
        let TokenInstruction::Transfer { amount } = TokenInstruction::unpack(&ix.data)? else {
            panic!("only real SPL transfer CPI expected")
        };
        assert_eq!(ix.accounts.len(), 3);
        assert_eq!(infos.len(), 3);
        for (meta, info) in ix.accounts.iter().zip(infos) {
            assert_eq!(meta.pubkey, *info.key);
        }
        assert!(
            ix.accounts[0].is_writable && ix.accounts[1].is_writable && ix.accounts[2].is_signer
        );
        let authority = &infos[2];
        let signed = authority.is_signer
            || seeds.iter().any(|signer| {
                Pubkey::create_program_address(signer, &ID).ok() == Some(*authority.key)
            });
        if !signed {
            return Err(ProgramError::MissingRequiredSignature);
        }
        let mut from = SplAccount::unpack(&infos[0].try_borrow_data()?)?;
        let mut to = SplAccount::unpack(&infos[1].try_borrow_data()?)?;
        assert_eq!(from.owner, *authority.key, "wrong token transfer authority");
        assert_eq!(from.mint, to.mint, "settlement mint mismatch");
        assert_ne!(
            infos[0].key, infos[1].key,
            "self transfer must not create credit"
        );
        from.amount = from
            .amount
            .checked_sub(amount)
            .ok_or(ProgramError::InsufficientFunds)?;
        to.amount = to
            .amount
            .checked_add(amount)
            .ok_or(ProgramError::ArithmeticOverflow)?;
        SplAccount::pack(from, &mut infos[0].try_borrow_mut_data()?)?;
        SplAccount::pack(to, &mut infos[1].try_borrow_mut_data()?)?;
        Ok(())
    }
}
struct RuntimeGuard(Box<dyn SyscallStubs>);
impl Drop for RuntimeGuard {
    fn drop(&mut self) {
        let old = std::mem::replace(&mut self.0, Box::new(TokenRuntime));
        set_syscall_stubs(old);
    }
}
fn runtime() -> RuntimeGuard {
    RuntimeGuard(set_syscall_stubs(Box::new(TokenRuntime)))
}

fn raw(
    key: Pubkey,
    owner: Pubkey,
    data: Vec<u8>,
    signer: bool,
    writable: bool,
    executable: bool,
) -> AccountInfo<'static> {
    AccountInfo::new(
        Box::leak(Box::new(key)),
        signer,
        writable,
        Box::leak(Box::new(10_000_000_000)),
        Box::leak(data.into_boxed_slice()),
        Box::leak(Box::new(owner)),
        executable,
    )
}
fn state(key: Pubkey, value: &impl AccountSerialize, writable: bool) -> AccountInfo<'static> {
    let mut data = vec![];
    value.try_serialize(&mut data).unwrap();
    raw(key, ID, data, false, writable, false)
}
fn read<T: AccountDeserialize>(account: &AccountInfo) -> T {
    T::try_deserialize(&mut account.data.borrow().as_ref()).unwrap()
}
fn write(account: &AccountInfo, value: &impl AccountSerialize) {
    let mut data = account.try_borrow_mut_data().unwrap();
    value.try_serialize(&mut data.as_mut()).unwrap();
}
fn user(key: Pubkey) -> AccountInfo<'static> {
    raw(
        key,
        anchor_lang::system_program::ID,
        vec![],
        true,
        true,
        false,
    )
}
fn unchecked(key: Pubkey) -> AccountInfo<'static> {
    raw(
        key,
        anchor_lang::system_program::ID,
        vec![],
        false,
        false,
        false,
    )
}
fn program(key: Pubkey) -> AccountInfo<'static> {
    raw(
        key,
        anchor_lang::solana_program::bpf_loader_upgradeable::ID,
        vec![],
        false,
        false,
        true,
    )
}
fn token(key: Pubkey, mint: Pubkey, owner: Pubkey, amount: u64) -> AccountInfo<'static> {
    let value = SplAccount {
        mint,
        owner,
        amount,
        delegate: COption::None,
        state: AccountState::Initialized,
        is_native: COption::None,
        delegated_amount: 0,
        close_authority: COption::None,
    };
    let mut data = vec![0; SplAccount::LEN];
    SplAccount::pack(value, &mut data).unwrap();
    raw(key, TOKEN_ID, data, false, true, false)
}
fn mint(key: Pubkey) -> AccountInfo<'static> {
    let mut data = vec![0; SplMint::LEN];
    SplMint::pack(
        SplMint {
            mint_authority: COption::None,
            supply: 1_000_000_000_000,
            decimals: 6,
            is_initialized: true,
            freeze_authority: COption::None,
        },
        &mut data,
    )
    .unwrap();
    raw(key, TOKEN_ID, data, false, false, false)
}
fn balance(account: &AccountInfo) -> u64 {
    SplAccount::unpack(&account.data.borrow()).unwrap().amount
}
fn call(
    accounts: Vec<AccountInfo<'static>>,
    ix: impl InstructionData,
) -> std::result::Result<(), ProgramError> {
    ::acex_capital::entry(
        &ID,
        Box::leak(accounts.into_boxed_slice()),
        Box::leak(ix.data().into_boxed_slice()),
    )
}
fn config(admin: Pubkey, mint: Pubkey) -> AccountInfo<'static> {
    state(
        pda(&[b"config"]).0,
        &ProgramConfig {
            admin,
            usdc_mint: mint,
            initialized: true,
            paused: false,
        },
        false,
    )
}
fn listing() -> AccountInfo<'static> {
    let (key, bump) = pda(&[b"listing", &LISTING_ID]);
    state(
        key,
        &Listing {
            agent: Pubkey::new_from_array([1; 32]),
            listing_id: LISTING_ID,
            metadata_hash: [3; 32],
            audit_score_bps: 8000,
            status: ListingStatus::Approved as u8,
            share_mint: Pubkey::new_from_array([4; 32]),
            max_supply: 1000,
            listed_at: 1,
            bump,
        },
        false,
    )
}

#[test]
fn collateral_payments_preserve_amounts_pda_signing_and_mint_binding() {
    let _lock = SYSCALL_LOCK.lock().unwrap();
    let _runtime = runtime();
    let admin = user(Pubkey::new_from_array([51; 32]));
    let depositor = user(Pubkey::new_from_array([52; 32]));
    let mint_key = Pubkey::new_from_array([53; 32]);
    let cfg = config(*admin.key, mint_key);
    let listed = listing();
    let (c_key, c_bump) = pda(&[b"collateral", &LISTING_ID]);
    let collateral = state(
        c_key,
        &CollateralAccount {
            listing_id: LISTING_ID,
            usdc_balance: 0,
            locked_for_notes: 0,
            bump: c_bump,
        },
        true,
    );
    let vault_auth = unchecked(pda(&[b"vault", &LISTING_ID]).0);
    let vault = token(
        pda(&[b"vault_ata", &LISTING_ID]).0,
        mint_key,
        *vault_auth.key,
        0,
    );
    let source = token(
        Pubkey::new_from_array([54; 32]),
        mint_key,
        *depositor.key,
        10_000_000,
    );
    let mint_account = mint(mint_key);
    let token_program = program(TOKEN_ID);
    let system = program(anchor_lang::system_program::ID);
    let deposit_accounts = || {
        vec![
            depositor.clone(),
            cfg.clone(),
            listed.clone(),
            collateral.clone(),
            vault_auth.clone(),
            vault.clone(),
            source.clone(),
            mint_account.clone(),
            token_program.clone(),
            system.clone(),
        ]
    };
    let mut no_signature = deposit_accounts();
    no_signature[0].is_signer = false;
    assert!(call(
        no_signature,
        instruction::DepositCollateral {
            listing_id: LISTING_ID,
            amount: 1_000_000
        }
    )
    .is_err());
    assert_eq!(balance(&source), 10_000_000);
    let mut wrong_mint = deposit_accounts();
    wrong_mint[7] = mint(Pubkey::new_from_array([55; 32]));
    assert!(call(
        wrong_mint,
        instruction::DepositCollateral {
            listing_id: LISTING_ID,
            amount: 1_000_000
        }
    )
    .is_err());
    assert_eq!(balance(&source), 10_000_000);
    call(
        deposit_accounts(),
        instruction::DepositCollateral {
            listing_id: LISTING_ID,
            amount: 1_000_000,
        },
    )
    .unwrap();
    assert_eq!((balance(&source), balance(&vault)), (9_000_000, 1_000_000));
    assert_eq!(
        read::<CollateralAccount>(&collateral).usdc_balance,
        1_000_000
    );
    call(
        vec![admin.clone(), cfg.clone(), collateral.clone()],
        instruction::LockCollateral {
            listing_id: LISTING_ID,
            amount: 600_000,
        },
    )
    .unwrap();
    let recipient = user(Pubkey::new_from_array([56; 32]));
    let recipient_ata = token(
        Pubkey::new_from_array([57; 32]),
        mint_key,
        *recipient.key,
        0,
    );
    call(
        vec![
            admin,
            cfg,
            collateral.clone(),
            vault_auth,
            vault.clone(),
            recipient,
            recipient_ata.clone(),
            token_program,
        ],
        instruction::ReleaseCollateral {
            listing_id: LISTING_ID,
            amount: 600_000,
        },
    )
    .unwrap();
    assert_eq!(
        (balance(&vault), balance(&recipient_ata)),
        (400_000, 600_000)
    );
    let state = read::<CollateralAccount>(&collateral);
    assert_eq!((state.usdc_balance, state.locked_for_notes), (400_000, 0));
}

#[test]
fn option_quotes_require_authority_signature_and_pay_the_exact_intrinsic_value() {
    let _lock = SYSCALL_LOCK.lock().unwrap();
    let _runtime = runtime();
    let admin = user(Pubkey::new_from_array([61; 32]));
    let buyer = user(Pubkey::new_from_array([62; 32]));
    let mint_key = Pubkey::new_from_array([63; 32]);
    let cfg = config(*admin.key, mint_key);
    let strike = 10_000u64;
    let expiry = 1000i64;
    let strike_bytes = strike.to_le_bytes();
    let expiry_bytes = expiry.to_le_bytes();
    let (series_key, series_bump) = pda(&[b"capsense", &LISTING_ID, &strike_bytes, &expiry_bytes]);
    let series = state(
        series_key,
        &CapsenseSeries {
            listing_id: LISTING_ID,
            strike_index_bps: strike,
            expiry_ts: expiry,
            open_interest: 0,
            premium_pool: 0,
            settled: false,
            bump: series_bump,
        },
        true,
    );
    let (position_key, position_bump) =
        pda(&[b"capsense_pos", buyer.key.as_ref(), &series_key.to_bytes()]);
    let position = state(
        position_key,
        &CapsensePosition {
            buyer: *buyer.key,
            series: series_key,
            contracts: 0,
            premium_paid: 0,
            exercised: false,
            bump: position_bump,
        },
        true,
    );
    let authority =
        unchecked(pda(&[b"capsense_vault", &LISTING_ID, &strike_bytes, &expiry_bytes]).0);
    let vault = token(
        pda(&[
            b"capsense_vault_ata",
            &LISTING_ID,
            &strike_bytes,
            &expiry_bytes,
        ])
        .0,
        mint_key,
        *authority.key,
        0,
    );
    let buyer_ata = token(
        Pubkey::new_from_array([64; 32]),
        mint_key,
        *buyer.key,
        2_000_000,
    );
    let mint_account = mint(mint_key);
    let tp = program(TOKEN_ID);
    let system = program(anchor_lang::system_program::ID);
    let buy_accounts = || {
        vec![
            buyer.clone(),
            cfg.clone(),
            series.clone(),
            position.clone(),
            authority.clone(),
            vault.clone(),
            buyer_ata.clone(),
            mint_account.clone(),
            tp.clone(),
            system.clone(),
        ]
    };
    let buy = || instruction::BuyCapsenseOption {
        listing_id: LISTING_ID,
        strike_index_bps: strike,
        expiry_ts: expiry,
        contracts: 100_000,
        premium_per_contract: 10,
    };
    assert!(call(buy_accounts(), buy()).is_err());
    let mut forged = buy_accounts();
    let mut unsigned_admin = admin.clone();
    unsigned_admin.is_signer = false;
    forged.push(unsigned_admin);
    assert!(call(forged, buy()).is_err());
    assert_eq!(balance(&buyer_ata), 2_000_000);
    let mut signed = buy_accounts();
    signed.push(admin.clone());
    call(signed, buy()).unwrap();
    assert_eq!(
        (balance(&buyer_ata), balance(&vault)),
        (1_000_000, 1_000_000)
    );
    let exercise_accounts = || {
        vec![
            buyer.clone(),
            cfg.clone(),
            series.clone(),
            position.clone(),
            authority.clone(),
            vault.clone(),
            buyer_ata.clone(),
            tp.clone(),
        ]
    };
    let exercise = || instruction::ExerciseCapsenseOption {
        listing_id: LISTING_ID,
        strike_index_bps: strike,
        expiry_ts: expiry,
        index_level_bps: 20_000,
    };
    assert!(call(exercise_accounts(), exercise()).is_err());
    let original_position = read::<CapsensePosition>(&position);
    let mut oversized_position = read::<CapsensePosition>(&position);
    oversized_position.contracts = u64::MAX;
    write(&position, &oversized_position);
    let mut overflow = exercise_accounts();
    overflow.push(admin.clone());
    assert!(call(
        overflow,
        instruction::ExerciseCapsenseOption {
            listing_id: LISTING_ID,
            strike_index_bps: strike,
            expiry_ts: expiry,
            index_level_bps: u64::MAX,
        },
    )
    .is_err());
    assert_eq!(balance(&vault), 1_000_000);
    write(&position, &original_position);
    let mut signed = exercise_accounts();
    signed.push(admin.clone());
    call(signed, exercise()).unwrap();
    assert_eq!((balance(&buyer_ata), balance(&vault)), (1_100_000, 900_000));
    assert!(read::<CapsensePosition>(&position).exercised);
    let mut rebuy = buy_accounts();
    rebuy.push(admin.clone());
    assert!(call(rebuy, buy()).is_err());
    assert_eq!((balance(&buyer_ata), balance(&vault)), (1_100_000, 900_000));
    assert_eq!(read::<CapsensePosition>(&position).premium_paid, 1_000_000);
    let mut replay = exercise_accounts();
    replay.push(admin);
    assert!(call(replay, exercise()).is_err());
    assert_eq!(balance(&vault), 900_000);
}

#[test]
fn audit_stake_coverage_rewards_and_authorized_prices_preserve_balances() {
    let _lock = SYSCALL_LOCK.lock().unwrap();
    let _runtime = runtime();
    let admin = user(Pubkey::new_from_array([71; 32]));
    let auditor = user(Pubkey::new_from_array([72; 32]));
    let mint_key = Pubkey::new_from_array([73; 32]);
    let cfg = config(*admin.key, mint_key);
    let listed = listing();
    let (pool_key, pool_bump) = pda(&[b"audit_pool"]);
    let pool = state(
        pool_key,
        &AuditPoolConfig {
            initialized: true,
            audit_fee_bps: 100,
            bump: pool_bump,
        },
        false,
    );
    let (stake_key, stake_bump) = pda(&[b"auditor_stake", auditor.key.as_ref()]);
    let stake = state(
        stake_key,
        &AuditorStakeAccount {
            auditor: *auditor.key,
            staked: 0,
            locked_stake: 0,
            bump: stake_bump,
        },
        true,
    );
    let authority = unchecked(pda(&[b"audit_pool_vault"]).0);
    let vault = token(
        pda(&[b"audit_pool_vault_ata"]).0,
        mint_key,
        *authority.key,
        0,
    );
    let auditor_ata = token(
        Pubkey::new_from_array([74; 32]),
        mint_key,
        *auditor.key,
        20_000_000_000,
    );
    let tp = program(TOKEN_ID);
    let system = program(anchor_lang::system_program::ID);
    call(
        vec![
            auditor.clone(),
            cfg.clone(),
            pool.clone(),
            stake.clone(),
            authority.clone(),
            vault.clone(),
            auditor_ata.clone(),
            tp.clone(),
            system.clone(),
        ],
        instruction::StakeAudit {
            amount: 10_000_000_000,
        },
    )
    .unwrap();
    assert_eq!(
        (balance(&auditor_ata), balance(&vault)),
        (10_000_000_000, 10_000_000_000)
    );
    assert_eq!(read::<AuditorStakeAccount>(&stake).staked, 10_000_000_000);
    let (coverage_key, coverage_bump) = pda(&[b"coverage", &LISTING_ID, auditor.key.as_ref()]);
    let coverage = state(
        coverage_key,
        &CoverageRecord {
            listing_id: LISTING_ID,
            auditor: *auditor.key,
            cover_amount: 0,
            score_bps: 0,
            phase: CoveragePhase::Open as u8,
            pending_rewards: 0,
            claimed_rewards: 0,
            bump: coverage_bump,
        },
        true,
    );
    let (audit_key, audit_bump) = pda(&[b"listing_audit", &LISTING_ID]);
    let audit = state(
        audit_key,
        &ListingAuditState {
            listing_id: LISTING_ID,
            aggregate_score_bps: 0,
            total_cover: 0,
            defaulted: false,
            approved_at: 1,
            baseline_price_e6: 0,
            twap_price_e6: 0,
            compensation_pool: 0,
            bump: audit_bump,
        },
        true,
    );
    let cover_accounts = || {
        vec![
            auditor.clone(),
            cfg.clone(),
            listed.clone(),
            stake.clone(),
            coverage.clone(),
            audit.clone(),
            system.clone(),
        ]
    };
    for cover_amount in [1_000_000_000, 1_000_000_000, 2_000_000_000] {
        call(
            cover_accounts(),
            instruction::CoverListing {
                listing_id: LISTING_ID,
                cover_amount,
                score_bps: 8000,
            },
        )
        .unwrap();
    }
    assert_eq!(
        read::<AuditorStakeAccount>(&stake).locked_stake,
        2_000_000_000
    );
    assert_eq!(read::<ListingAuditState>(&audit).total_cover, 2_000_000_000);
    let funder = user(Pubkey::new_from_array([75; 32]));
    let funder_ata = token(
        Pubkey::new_from_array([76; 32]),
        mint_key,
        *funder.key,
        1_000_000,
    );
    call(
        vec![
            funder.clone(),
            cfg.clone(),
            pool,
            audit.clone(),
            unchecked(*auditor.key),
            coverage.clone(),
            authority.clone(),
            vault.clone(),
            funder_ata.clone(),
            tp.clone(),
        ],
        instruction::FundAuditRewards {
            listing_id: LISTING_ID,
            reward_auditor: *auditor.key,
            gross_amount: 1_000_000,
        },
    )
    .unwrap();
    assert_eq!(balance(&funder_ata), 990_000);
    assert_eq!(read::<CoverageRecord>(&coverage).pending_rewards, 10_000);
    let claim_accounts = || {
        vec![
            auditor.clone(),
            cfg.clone(),
            coverage.clone(),
            authority.clone(),
            vault.clone(),
            auditor_ata.clone(),
            tp.clone(),
        ]
    };
    call(
        claim_accounts(),
        instruction::ClaimAuditReward {
            listing_id: LISTING_ID,
        },
    )
    .unwrap();
    assert_eq!(balance(&auditor_ata), 10_000_010_000);
    assert!(call(
        claim_accounts(),
        instruction::ClaimAuditReward {
            listing_id: LISTING_ID
        }
    )
    .is_err());
    call(
        vec![
            auditor.clone(),
            cfg.clone(),
            stake.clone(),
            authority.clone(),
            vault.clone(),
            auditor_ata.clone(),
            tp.clone(),
        ],
        instruction::UnstakeAudit {
            amount: 8_000_000_000,
        },
    )
    .unwrap();
    assert_eq!(
        (balance(&auditor_ata), balance(&vault)),
        (18_000_010_000, 2_000_000_000)
    );
    assert_eq!(read::<AuditorStakeAccount>(&stake).staked, 2_000_000_000);
    let observe = || instruction::ObserveListingPrice {
        listing_id: LISTING_ID,
        baseline_price_e6: 1_000_000,
        twap_price_e6: 900_000,
    };
    assert!(call(
        vec![auditor.clone(), cfg.clone(), audit.clone(), system.clone()],
        observe()
    )
    .is_err());
    assert_eq!(read::<ListingAuditState>(&audit).baseline_price_e6, 0);
    call(
        vec![admin.clone(), cfg.clone(), audit.clone(), system.clone()],
        observe(),
    )
    .unwrap();
    assert_eq!(read::<ListingAuditState>(&audit).twap_price_e6, 900_000);
    call(
        vec![admin.clone(), cfg.clone(), audit.clone(), system],
        instruction::ObserveListingPrice {
            listing_id: LISTING_ID,
            baseline_price_e6: 1_000_000,
            twap_price_e6: 400_000,
        },
    )
    .unwrap();
    let slash_accounts = || {
        vec![
            admin.clone(),
            cfg.clone(),
            audit.clone(),
            unchecked(*auditor.key),
            coverage.clone(),
            stake.clone(),
        ]
    };
    call(
        slash_accounts(),
        instruction::TriggerListingDefault {
            listing_id: LISTING_ID,
            slashed_auditor: *auditor.key,
        },
    )
    .unwrap();
    assert_eq!(read::<AuditorStakeAccount>(&stake).staked, 0);
    assert_eq!(
        read::<ListingAuditState>(&audit).compensation_pool,
        2_000_000_000
    );
    assert!(call(
        slash_accounts(),
        instruction::TriggerListingDefault {
            listing_id: LISTING_ID,
            slashed_auditor: *auditor.key
        }
    )
    .is_err());
    assert!(call(
        vec![
            auditor.clone(),
            cfg.clone(),
            stake,
            authority,
            vault.clone(),
            auditor_ata,
            tp
        ],
        instruction::UnstakeAudit { amount: 1 }
    )
    .is_err());
    assert_eq!(balance(&vault), 2_000_000_000);
    let mut writable_cfg = cfg.clone();
    writable_cfg.is_writable = true;
    call(
        vec![admin, writable_cfg],
        instruction::SetPaused { paused: true },
    )
    .unwrap();
    assert!(read::<ProgramConfig>(&cfg).paused);
}
