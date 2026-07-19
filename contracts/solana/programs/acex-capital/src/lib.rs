//! ACEX Capital — Solana programs for Agent Listing Protocol (ALP) + collateral.
//!
//! Mirrors EVM: apply → audit → approve → deposit USDC collateral → lock for notes.
//! CapShares SPL mint is recorded on approval (mint created in same tx via CPI or pre-created).

use anchor_lang::prelude::*;
use anchor_spl::token::{self, Mint, Token, TokenAccount, Transfer};

declare_id!("9BkXiRFMB5bAMMqAXxTzaLPYspiGxoUTEeX8kih9ne73");

pub const MIN_AUDIT_SCORE_BPS: u16 = 7000;
pub const MIN_AUDIT_STAKE_USDC: u64 = 10_000_000_000; // 10k USDC (6 decimals)
pub const MIN_COVER_USDC: u64 = 1_000_000_000; // 1k USDC
pub const DEFAULT_DROP_BPS: u16 = 5000;
pub const DEFAULT_AUDIT_FEE_BPS: u16 = 100;

#[program]
pub mod acex_capital {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>) -> Result<()> {
        let cfg = &mut ctx.accounts.config;
        require!(!cfg.initialized, AcexError::AlreadyInitialized);
        cfg.admin = ctx.accounts.admin.key();
        cfg.usdc_mint = ctx.accounts.usdc_mint.key();
        cfg.initialized = true;
        cfg.paused = false;
        Ok(())
    }

    pub fn set_paused(ctx: Context<AdminOnly>, paused: bool) -> Result<()> {
        ctx.accounts.config.paused = paused;
        Ok(())
    }

    pub fn set_auditor(ctx: Context<SetAuditor>, is_auditor: bool) -> Result<()> {
        ctx.accounts.auditor_record.is_auditor = is_auditor;
        Ok(())
    }

    pub fn apply_listing(
        ctx: Context<ApplyListing>,
        listing_id: [u8; 32],
        metadata_hash: [u8; 32],
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        let listing = &mut ctx.accounts.listing;
        listing.agent = ctx.accounts.agent.key();
        listing.listing_id = listing_id;
        listing.metadata_hash = metadata_hash;
        listing.status = ListingStatus::Pending as u8;
        listing.audit_score_bps = 0;
        listing.share_mint = Pubkey::default();
        listing.bump = ctx.bumps.listing;
        emit!(ListingApplied {
            listing_id,
            agent: listing.agent,
            metadata_hash,
        });
        Ok(())
    }

    pub fn record_audit(ctx: Context<RecordAudit>, listing_id: [u8; 32], score_bps: u16) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        require!(ctx.accounts.auditor_record.is_auditor, AcexError::Unauthorized);
        let listing = &mut ctx.accounts.listing;
        require!(listing.agent != Pubkey::default(), AcexError::ListingNotFound);
        listing.audit_score_bps = score_bps;
        listing.status = ListingStatus::UnderAudit as u8;
        emit!(ListingAudited {
            listing_id,
            score_bps,
            auditor: ctx.accounts.auditor.key(),
        });
        Ok(())
    }

    pub fn approve_listing(
        ctx: Context<ApproveListing>,
        listing_id: [u8; 32],
        share_mint: Pubkey,
        max_supply: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        let listing = &mut ctx.accounts.listing;
        require!(
            listing.status == ListingStatus::Pending as u8
                || listing.status == ListingStatus::UnderAudit as u8,
            AcexError::InvalidStatus
        );
        require!(listing.audit_score_bps >= MIN_AUDIT_SCORE_BPS, AcexError::AuditScoreTooLow);

        listing.share_mint = share_mint;
        listing.max_supply = max_supply;
        listing.status = ListingStatus::Approved as u8;
        listing.listed_at = Clock::get()?.unix_timestamp;

        emit!(ListingApproved {
            listing_id,
            share_mint,
            max_supply,
        });
        Ok(())
    }

    pub fn reject_listing(ctx: Context<RejectListing>, listing_id: [u8; 32]) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        let listing = &mut ctx.accounts.listing;
        listing.status = ListingStatus::Rejected as u8;
        emit!(ListingRejected { listing_id });
        Ok(())
    }

    /// Deposit USDC collateral into listing vault PDA.
    pub fn deposit_collateral(
        ctx: Context<DepositCollateral>,
        listing_id: [u8; 32],
        amount: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        require!(amount > 0, AcexError::ZeroAmount);

        let listing = &ctx.accounts.listing;
        require!(listing.status == ListingStatus::Approved as u8, AcexError::InvalidStatus);

        token::transfer(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.depositor_ata.to_account_info(),
                    to: ctx.accounts.vault_ata.to_account_info(),
                    authority: ctx.accounts.depositor.to_account_info(),
                },
            ),
            amount,
        )?;

        let collateral = &mut ctx.accounts.collateral;
        if collateral.listing_id == [0u8; 32] {
            collateral.listing_id = listing_id;
            collateral.bump = ctx.bumps.collateral;
        }
        collateral.usdc_balance = collateral
            .usdc_balance
            .checked_add(amount)
            .ok_or(AcexError::MathOverflow)?;

        emit!(CollateralDeposited {
            listing_id,
            amount,
            depositor: ctx.accounts.depositor.key(),
        });
        Ok(())
    }

    /// Lock collateral backing AgentNotes (admin/registry only).
    pub fn lock_collateral(
        ctx: Context<LockCollateral>,
        listing_id: [u8; 32],
        amount: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        let collateral = &mut ctx.accounts.collateral;
        require!(collateral.usdc_balance >= amount, AcexError::InsufficientCollateral);
        collateral.usdc_balance = collateral
            .usdc_balance
            .checked_sub(amount)
            .ok_or(AcexError::MathOverflow)?;
        collateral.locked_for_notes = collateral
            .locked_for_notes
            .checked_add(amount)
            .ok_or(AcexError::MathOverflow)?;
        emit!(CollateralLocked { listing_id, amount });
        Ok(())
    }

    /// Release locked collateral to agent (maturity / admin).
    pub fn release_collateral(
        ctx: Context<ReleaseCollateral>,
        listing_id: [u8; 32],
        amount: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        let collateral = &mut ctx.accounts.collateral;
        require!(collateral.locked_for_notes >= amount, AcexError::InsufficientCollateral);
        collateral.locked_for_notes = collateral
            .locked_for_notes
            .checked_sub(amount)
            .ok_or(AcexError::MathOverflow)?;

        let seeds: &[&[u8]] = &[b"vault", listing_id.as_ref(), &[ctx.bumps.vault_authority]];
        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.vault_ata.to_account_info(),
                    to: ctx.accounts.recipient_ata.to_account_info(),
                    authority: ctx.accounts.vault_authority.to_account_info(),
                },
                &[seeds],
            ),
            amount,
        )?;
        emit!(CollateralReleased {
            listing_id,
            amount,
            recipient: ctx.accounts.recipient.key(),
        });
        Ok(())
    }

    // ── CapSense Options (Phase 2) ─────────────────────────────

    /// Create a CapSense call option series on a listing revenue index.
    pub fn create_capsense_series(
        ctx: Context<CreateCapsenseSeries>,
        listing_id: [u8; 32],
        strike_index_bps: u64,
        expiry_ts: i64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        let listing = &ctx.accounts.listing;
        require!(listing.status == ListingStatus::Approved as u8, AcexError::InvalidStatus);
        require!(expiry_ts > Clock::get()?.unix_timestamp, AcexError::OptionExpired);

        let series = &mut ctx.accounts.series;
        series.listing_id = listing_id;
        series.strike_index_bps = strike_index_bps;
        series.expiry_ts = expiry_ts;
        series.open_interest = 0;
        series.premium_pool = 0;
        series.settled = false;
        series.bump = ctx.bumps.series;

        emit!(CapsenseSeriesCreated {
            listing_id,
            strike_index_bps,
            expiry_ts,
            series: series.key(),
        });
        Ok(())
    }

    /// Buy CapSense contracts; premium USDC flows to series vault.
    pub fn buy_capsense_option(
        ctx: Context<BuyCapsenseOption>,
        listing_id: [u8; 32],
        strike_index_bps: u64,
        expiry_ts: i64,
        contracts: u64,
        premium_per_contract: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        require!(contracts > 0, AcexError::ZeroAmount);
        require!(premium_per_contract > 0, AcexError::ZeroAmount);

        let series = &mut ctx.accounts.series;
        require!(!series.settled, AcexError::OptionSettled);
        require!(Clock::get()?.unix_timestamp < series.expiry_ts, AcexError::OptionExpired);

        let total_premium = premium_per_contract
            .checked_mul(contracts)
            .ok_or(AcexError::MathOverflow)?;

        token::transfer(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.buyer_ata.to_account_info(),
                    to: ctx.accounts.series_vault_ata.to_account_info(),
                    authority: ctx.accounts.buyer.to_account_info(),
                },
            ),
            total_premium,
        )?;

        let position = &mut ctx.accounts.position;
        if position.contracts == 0 {
            position.buyer = ctx.accounts.buyer.key();
            position.series = series.key();
            position.exercised = false;
            position.bump = ctx.bumps.position;
        }
        position.contracts = position
            .contracts
            .checked_add(contracts)
            .ok_or(AcexError::MathOverflow)?;
        position.premium_paid = position
            .premium_paid
            .checked_add(total_premium)
            .ok_or(AcexError::MathOverflow)?;

        series.open_interest = series
            .open_interest
            .checked_add(contracts)
            .ok_or(AcexError::MathOverflow)?;
        series.premium_pool = series
            .premium_pool
            .checked_add(total_premium)
            .ok_or(AcexError::MathOverflow)?;

        emit!(CapsenseOptionPurchased {
            listing_id,
            buyer: ctx.accounts.buyer.key(),
            contracts,
            premium: total_premium,
        });
        Ok(())
    }

    /// Exercise in-the-money CapSense calls against index level (bps × 1e-4 USD).
    pub fn exercise_capsense_option(
        ctx: Context<ExerciseCapsenseOption>,
        listing_id: [u8; 32],
        strike_index_bps: u64,
        expiry_ts: i64,
        index_level_bps: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        let series = &ctx.accounts.series;
        require!(!series.settled, AcexError::OptionSettled);
        let now = Clock::get()?.unix_timestamp;
        require!(now <= series.expiry_ts, AcexError::OptionExpired);
        require!(index_level_bps > series.strike_index_bps, AcexError::OptionOutOfMoney);

        let position = &mut ctx.accounts.position;
        require!(!position.exercised, AcexError::OptionAlreadyExercised);
        require!(position.contracts > 0, AcexError::ZeroAmount);

        let intrinsic_bps = index_level_bps
            .checked_sub(series.strike_index_bps)
            .ok_or(AcexError::MathOverflow)?;
        let payout = (intrinsic_bps as u128)
            .checked_mul(position.contracts as u128)
            .ok_or(AcexError::MathOverflow)?
            .checked_div(10_000)
            .ok_or(AcexError::MathOverflow)? as u64;
        require!(payout > 0, AcexError::ZeroAmount);
        require!(ctx.accounts.series_vault_ata.amount >= payout, AcexError::InsufficientCollateral);

        let seeds: &[&[u8]] = &[
            b"capsense_vault",
            listing_id.as_ref(),
            &strike_index_bps.to_le_bytes(),
            &expiry_ts.to_le_bytes(),
            &[ctx.bumps.series_vault_authority],
        ];
        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.series_vault_ata.to_account_info(),
                    to: ctx.accounts.buyer_ata.to_account_info(),
                    authority: ctx.accounts.series_vault_authority.to_account_info(),
                },
                &[seeds],
            ),
            payout,
        )?;

        position.exercised = true;
        emit!(CapsenseOptionExercised {
            listing_id,
            buyer: position.buyer,
            payout,
            index_level_bps,
        });
        Ok(())
    }

    // ── Proof-of-Audit (Phase 2) ────────────────────────────────

    pub fn initialize_audit_pool(ctx: Context<InitializeAuditPool>, audit_fee_bps: u16) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        let pool = &mut ctx.accounts.audit_pool;
        require!(!pool.initialized, AcexError::AlreadyInitialized);
        pool.initialized = true;
        pool.audit_fee_bps = audit_fee_bps;
        pool.bump = ctx.bumps.audit_pool;
        Ok(())
    }

    pub fn stake_audit(ctx: Context<StakeAudit>, amount: u64) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        require!(amount > 0, AcexError::ZeroAmount);
        let pool = &ctx.accounts.audit_pool;
        require!(pool.initialized, AcexError::AuditPoolNotInitialized);

        token::transfer(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.auditor_ata.to_account_info(),
                    to: ctx.accounts.pool_vault_ata.to_account_info(),
                    authority: ctx.accounts.auditor.to_account_info(),
                },
            ),
            amount,
        )?;

        let stake = &mut ctx.accounts.auditor_stake;
        if stake.auditor == Pubkey::default() {
            stake.auditor = ctx.accounts.auditor.key();
            stake.bump = ctx.bumps.auditor_stake;
        }
        stake.staked = stake.staked.checked_add(amount).ok_or(AcexError::MathOverflow)?;

        emit!(AuditStaked {
            auditor: stake.auditor,
            amount,
            total_staked: stake.staked,
        });
        Ok(())
    }

    pub fn unstake_audit(ctx: Context<UnstakeAudit>, amount: u64) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        require!(amount > 0, AcexError::ZeroAmount);
        let stake = &mut ctx.accounts.auditor_stake;
        let free = stake.staked.saturating_sub(stake.locked_stake);
        require!(amount <= free, AcexError::InsufficientFreeStake);
        stake.staked = stake.staked.checked_sub(amount).ok_or(AcexError::MathOverflow)?;

        let seeds: &[&[u8]] = &[b"audit_pool_vault", &[ctx.bumps.pool_vault_authority]];
        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.pool_vault_ata.to_account_info(),
                    to: ctx.accounts.auditor_ata.to_account_info(),
                    authority: ctx.accounts.pool_vault_authority.to_account_info(),
                },
                &[seeds],
            ),
            amount,
        )?;
        emit!(AuditUnstaked {
            auditor: stake.auditor,
            amount,
            total_staked: stake.staked,
        });
        Ok(())
    }

    pub fn cover_listing(
        ctx: Context<CoverListing>,
        listing_id: [u8; 32],
        cover_amount: u64,
        score_bps: u16,
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        require!(cover_amount >= MIN_COVER_USDC, AcexError::CoverTooLow);
        require!(score_bps >= MIN_AUDIT_SCORE_BPS, AcexError::AuditScoreTooLow);

        let listing = &ctx.accounts.listing;
        require!(listing.status == ListingStatus::Approved as u8, AcexError::InvalidStatus);

        let stake = &mut ctx.accounts.auditor_stake;
        require!(stake.auditor == ctx.accounts.auditor.key(), AcexError::Unauthorized);
        let free = stake.staked.saturating_sub(stake.locked_stake);
        require!(cover_amount <= free, AcexError::InsufficientFreeStake);
        require!(stake.staked >= MIN_AUDIT_STAKE_USDC, AcexError::InsufficientStake);

        stake.locked_stake = stake
            .locked_stake
            .checked_add(cover_amount)
            .ok_or(AcexError::MathOverflow)?;

        let coverage = &mut ctx.accounts.coverage;
        if coverage.listing_id == [0u8; 32] {
            coverage.listing_id = listing_id;
            coverage.auditor = ctx.accounts.auditor.key();
            coverage.bump = ctx.bumps.coverage;
        }
        coverage.cover_amount = cover_amount;
        coverage.score_bps = score_bps;
        coverage.phase = CoveragePhase::Insuring as u8;

        let audit_state = &mut ctx.accounts.listing_audit;
        if audit_state.listing_id == [0u8; 32] {
            audit_state.listing_id = listing_id;
            audit_state.approved_at = listing.listed_at;
            audit_state.bump = ctx.bumps.listing_audit;
        }
        audit_state.total_cover = audit_state
            .total_cover
            .checked_add(cover_amount)
            .ok_or(AcexError::MathOverflow)?;
        audit_state.aggregate_score_bps = score_bps;

        emit!(ListingCovered {
            listing_id,
            auditor: ctx.accounts.auditor.key(),
            cover_amount,
            score_bps,
        });
        Ok(())
    }

    pub fn fund_audit_rewards(
        ctx: Context<FundAuditRewards>,
        listing_id: [u8; 32],
        reward_auditor: Pubkey,
        gross_amount: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        require!(gross_amount > 0, AcexError::ZeroAmount);
        let pool = &ctx.accounts.audit_pool;
        let fee = (gross_amount as u128)
            .checked_mul(pool.audit_fee_bps as u128)
            .ok_or(AcexError::MathOverflow)?
            .checked_div(10_000)
            .ok_or(AcexError::MathOverflow)? as u64;
        require!(fee > 0, AcexError::ZeroAmount);

        token::transfer(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.funder_ata.to_account_info(),
                    to: ctx.accounts.pool_vault_ata.to_account_info(),
                    authority: ctx.accounts.funder.to_account_info(),
                },
            ),
            fee,
        )?;

        let audit_state = &ctx.accounts.listing_audit;
        require!(!audit_state.defaulted, AcexError::AlreadyDefaulted);
        require!(audit_state.total_cover > 0, AcexError::CoverageNotFound);

        let coverage = &mut ctx.accounts.coverage;
        require!(coverage.auditor == reward_auditor, AcexError::Unauthorized);
        require!(coverage.phase == CoveragePhase::Insuring as u8, AcexError::InvalidCoveragePhase);
        coverage.pending_rewards = coverage
            .pending_rewards
            .checked_add(fee)
            .ok_or(AcexError::MathOverflow)?;

        emit!(AuditRewardsFunded {
            listing_id,
            gross_amount,
            fee_amount: fee,
            funder: ctx.accounts.funder.key(),
        });
        Ok(())
    }

    pub fn claim_audit_reward(ctx: Context<ClaimAuditReward>, listing_id: [u8; 32]) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        let coverage = &mut ctx.accounts.coverage;
        let pending = coverage.pending_rewards;
        require!(pending > 0, AcexError::NothingToClaim);
        coverage.pending_rewards = 0;
        coverage.claimed_rewards = coverage
            .claimed_rewards
            .checked_add(pending)
            .ok_or(AcexError::MathOverflow)?;

        let seeds: &[&[u8]] = &[b"audit_pool_vault", &[ctx.bumps.pool_vault_authority]];
        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.pool_vault_ata.to_account_info(),
                    to: ctx.accounts.auditor_ata.to_account_info(),
                    authority: ctx.accounts.pool_vault_authority.to_account_info(),
                },
                &[seeds],
            ),
            pending,
        )?;
        emit!(AuditRewardClaimed {
            listing_id,
            auditor: ctx.accounts.auditor.key(),
            amount: pending,
        });
        Ok(())
    }

    pub fn observe_listing_price(
        ctx: Context<ObserveListingPrice>,
        listing_id: [u8; 32],
        baseline_price_e6: u64,
        twap_price_e6: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        let audit_state = &mut ctx.accounts.listing_audit;
        if audit_state.listing_id == [0u8; 32] {
            audit_state.listing_id = listing_id;
            audit_state.bump = ctx.bumps.listing_audit;
        }
        if audit_state.baseline_price_e6 == 0 {
            audit_state.baseline_price_e6 = baseline_price_e6;
        }
        audit_state.twap_price_e6 = twap_price_e6;
        emit!(ListingPriceObserved {
            listing_id,
            baseline_price_e6: audit_state.baseline_price_e6,
            twap_price_e6,
        });
        Ok(())
    }

    pub fn trigger_listing_default(
        ctx: Context<TriggerListingDefault>,
        listing_id: [u8; 32],
        slashed_auditor: Pubkey,
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, AcexError::Paused);
        let audit_state = &mut ctx.accounts.listing_audit;
        require!(!audit_state.defaulted, AcexError::AlreadyDefaulted);
        require!(audit_state.baseline_price_e6 > 0, AcexError::BaselineNotSet);
        require!(audit_state.twap_price_e6 > 0, AcexError::DefaultConditionsNotMet);

        let drawdown_bps = ((audit_state.baseline_price_e6 as u128)
            .saturating_sub(audit_state.twap_price_e6 as u128)
            .checked_mul(10_000)
            .ok_or(AcexError::MathOverflow)?
            .checked_div(audit_state.baseline_price_e6 as u128)
            .ok_or(AcexError::MathOverflow)?) as u16;
        require!(drawdown_bps >= DEFAULT_DROP_BPS, AcexError::DefaultConditionsNotMet);

        audit_state.defaulted = true;
        let coverage = &mut ctx.accounts.coverage;
        require!(coverage.auditor == slashed_auditor, AcexError::Unauthorized);
        if coverage.phase == CoveragePhase::Insuring as u8 {
            coverage.phase = CoveragePhase::Slashed as u8;
            let stake = &mut ctx.accounts.auditor_stake;
            stake.locked_stake = stake.locked_stake.saturating_sub(coverage.cover_amount);
            audit_state.compensation_pool = audit_state
                .compensation_pool
                .checked_add(coverage.cover_amount)
                .ok_or(AcexError::MathOverflow)?;
        }

        emit!(ListingDefaultTriggered {
            listing_id,
            drawdown_bps,
        });
        Ok(())
    }
}

// ── Accounts ─────────────────────────────────────────────────────

#[account]
pub struct ProgramConfig {
    pub admin: Pubkey,
    pub usdc_mint: Pubkey,
    pub initialized: bool,
    pub paused: bool,
}

#[account]
pub struct AuditorRecord {
    pub is_auditor: bool,
}

#[account]
pub struct Listing {
    pub agent: Pubkey,
    pub listing_id: [u8; 32],
    pub metadata_hash: [u8; 32],
    pub audit_score_bps: u16,
    pub status: u8,
    pub share_mint: Pubkey,
    pub max_supply: u64,
    pub listed_at: i64,
    pub bump: u8,
}

#[account]
pub struct CollateralAccount {
    pub listing_id: [u8; 32],
    pub usdc_balance: u64,
    pub locked_for_notes: u64,
    pub bump: u8,
}

#[account]
pub struct CapsenseSeries {
    pub listing_id: [u8; 32],
    pub strike_index_bps: u64,
    pub expiry_ts: i64,
    pub open_interest: u64,
    pub premium_pool: u64,
    pub settled: bool,
    pub bump: u8,
}

#[account]
pub struct CapsensePosition {
    pub buyer: Pubkey,
    pub series: Pubkey,
    pub contracts: u64,
    pub premium_paid: u64,
    pub exercised: bool,
    pub bump: u8,
}

#[account]
pub struct AuditPoolConfig {
    pub initialized: bool,
    pub audit_fee_bps: u16,
    pub bump: u8,
}

#[account]
pub struct AuditorStakeAccount {
    pub auditor: Pubkey,
    pub staked: u64,
    pub locked_stake: u64,
    pub bump: u8,
}

#[account]
pub struct ListingAuditState {
    pub listing_id: [u8; 32],
    pub aggregate_score_bps: u16,
    pub total_cover: u64,
    pub defaulted: bool,
    pub approved_at: i64,
    pub baseline_price_e6: u64,
    pub twap_price_e6: u64,
    pub compensation_pool: u64,
    pub bump: u8,
}

impl ListingAuditState {
    pub fn recompute_aggregate_score(&mut self) {
        // Single-coverage listings use score directly; multi-auditor aggregation
        // is done off-chain for Pulse Terminal and mirrored on fund/claim paths.
        if self.total_cover > 0 && self.aggregate_score_bps == 0 {
            self.aggregate_score_bps = MIN_AUDIT_SCORE_BPS;
        }
    }
}

#[account]
pub struct CoverageRecord {
    pub listing_id: [u8; 32],
    pub auditor: Pubkey,
    pub cover_amount: u64,
    pub score_bps: u16,
    pub phase: u8,
    pub pending_rewards: u64,
    pub claimed_rewards: u64,
    pub bump: u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq)]
pub enum CoveragePhase {
    Open = 0,
    Insuring = 1,
    Slashed = 2,
    Released = 3,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq)]
pub enum ListingStatus {
    Pending = 0,
    UnderAudit = 1,
    Approved = 2,
    Rejected = 3,
    Delisted = 4,
}

// ── Contexts ─────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(init, payer = admin, space = 8 + 32 + 32 + 1 + 1, seeds = [b"config"], bump)]
    pub config: Account<'info, ProgramConfig>,
    pub usdc_mint: Account<'info, Mint>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AdminOnly<'info> {
    pub admin: Signer<'info>,
    #[account(seeds = [b"config"], bump, has_one = admin @ AcexError::Unauthorized)]
    pub config: Account<'info, ProgramConfig>,
}

#[derive(Accounts)]
pub struct SetAuditor<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(seeds = [b"config"], bump, has_one = admin @ AcexError::Unauthorized)]
    pub config: Account<'info, ProgramConfig>,
    /// CHECK: auditor pubkey in seeds
    pub auditor: UncheckedAccount<'info>,
    #[account(init_if_needed, payer = admin, space = 8 + 1, seeds = [b"auditor", auditor.key().as_ref()], bump)]
    pub auditor_record: Account<'info, AuditorRecord>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(listing_id: [u8; 32])]
pub struct ApplyListing<'info> {
    #[account(mut)]
    pub agent: Signer<'info>,
    #[account(seeds = [b"config"], bump)]
    pub config: Account<'info, ProgramConfig>,
    #[account(
        init,
        payer = agent,
        space = 8 + 32 + 32 + 2 + 1 + 32 + 8 + 8 + 1,
        seeds = [b"listing", listing_id.as_ref()],
        bump
    )]
    pub listing: Account<'info, Listing>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(listing_id: [u8; 32])]
pub struct RecordAudit<'info> {
    pub auditor: Signer<'info>,
    #[account(seeds = [b"config"], bump)]
    pub config: Account<'info, ProgramConfig>,
    #[account(seeds = [b"auditor", auditor.key().as_ref()], bump)]
    pub auditor_record: Account<'info, AuditorRecord>,
    #[account(mut, seeds = [b"listing", listing_id.as_ref()], bump = listing.bump)]
    pub listing: Account<'info, Listing>,
}

#[derive(Accounts)]
#[instruction(listing_id: [u8; 32])]
pub struct ApproveListing<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(seeds = [b"config"], bump, has_one = admin @ AcexError::Unauthorized)]
    pub config: Account<'info, ProgramConfig>,
    #[account(mut, seeds = [b"listing", listing_id.as_ref()], bump = listing.bump)]
    pub listing: Account<'info, Listing>,
}

#[derive(Accounts)]
#[instruction(listing_id: [u8; 32])]
pub struct RejectListing<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(seeds = [b"config"], bump, has_one = admin @ AcexError::Unauthorized)]
    pub config: Account<'info, ProgramConfig>,
    #[account(mut, seeds = [b"listing", listing_id.as_ref()], bump = listing.bump)]
    pub listing: Account<'info, Listing>,
}

#[derive(Accounts)]
#[instruction(listing_id: [u8; 32])]
pub struct DepositCollateral<'info> {
    #[account(mut)]
    pub depositor: Signer<'info>,
    #[account(seeds = [b"config"], bump)]
    pub config: Account<'info, ProgramConfig>,
    #[account(seeds = [b"listing", listing_id.as_ref()], bump = listing.bump)]
    pub listing: Account<'info, Listing>,
    #[account(
        init_if_needed,
        payer = depositor,
        space = 8 + 32 + 8 + 8 + 1,
        seeds = [b"collateral", listing_id.as_ref()],
        bump
    )]
    pub collateral: Account<'info, CollateralAccount>,
    /// CHECK: PDA authority for vault ATA
    #[account(seeds = [b"vault", listing_id.as_ref()], bump)]
    pub vault_authority: UncheckedAccount<'info>,
    #[account(
        init_if_needed,
        payer = depositor,
        token::mint = usdc_mint,
        token::authority = vault_authority,
        seeds = [b"vault_ata", listing_id.as_ref()],
        bump,
    )]
    pub vault_ata: Account<'info, TokenAccount>,
    #[account(mut)]
    pub depositor_ata: Account<'info, TokenAccount>,
    pub usdc_mint: Account<'info, Mint>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(listing_id: [u8; 32])]
pub struct LockCollateral<'info> {
    pub admin: Signer<'info>,
    #[account(seeds = [b"config"], bump, has_one = admin @ AcexError::Unauthorized)]
    pub config: Account<'info, ProgramConfig>,
    #[account(mut, seeds = [b"collateral", listing_id.as_ref()], bump)]
    pub collateral: Account<'info, CollateralAccount>,
}

#[derive(Accounts)]
#[instruction(listing_id: [u8; 32], strike_index_bps: u64, expiry_ts: i64)]
pub struct CreateCapsenseSeries<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(seeds = [b"config"], bump, has_one = admin @ AcexError::Unauthorized)]
    pub config: Account<'info, ProgramConfig>,
    #[account(seeds = [b"listing", listing_id.as_ref()], bump = listing.bump)]
    pub listing: Account<'info, Listing>,
    #[account(
        init,
        payer = admin,
        space = 8 + 32 + 8 + 8 + 8 + 8 + 1 + 1,
        seeds = [
            b"capsense",
            listing_id.as_ref(),
            &strike_index_bps.to_le_bytes(),
            &expiry_ts.to_le_bytes(),
        ],
        bump
    )]
    pub series: Account<'info, CapsenseSeries>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(listing_id: [u8; 32], strike_index_bps: u64, expiry_ts: i64)]
pub struct BuyCapsenseOption<'info> {
    #[account(mut)]
    pub buyer: Signer<'info>,
    #[account(seeds = [b"config"], bump)]
    pub config: Account<'info, ProgramConfig>,
    #[account(
        mut,
        seeds = [
            b"capsense",
            listing_id.as_ref(),
            &strike_index_bps.to_le_bytes(),
            &expiry_ts.to_le_bytes(),
        ],
        bump = series.bump
    )]
    pub series: Account<'info, CapsenseSeries>,
    #[account(
        init_if_needed,
        payer = buyer,
        space = 8 + 32 + 32 + 8 + 8 + 1 + 1,
        seeds = [b"capsense_pos", buyer.key().as_ref(), series.key().as_ref()],
        bump
    )]
    pub position: Account<'info, CapsensePosition>,
    /// CHECK: series vault authority
    #[account(
        seeds = [
            b"capsense_vault",
            listing_id.as_ref(),
            &strike_index_bps.to_le_bytes(),
            &expiry_ts.to_le_bytes(),
        ],
        bump
    )]
    pub series_vault_authority: UncheckedAccount<'info>,
    #[account(
        init_if_needed,
        payer = buyer,
        token::mint = usdc_mint,
        token::authority = series_vault_authority,
        seeds = [
            b"capsense_vault_ata",
            listing_id.as_ref(),
            &strike_index_bps.to_le_bytes(),
            &expiry_ts.to_le_bytes(),
        ],
        bump,
    )]
    pub series_vault_ata: Account<'info, TokenAccount>,
    #[account(mut)]
    pub buyer_ata: Account<'info, TokenAccount>,
    pub usdc_mint: Account<'info, Mint>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(listing_id: [u8; 32], strike_index_bps: u64, expiry_ts: i64)]
pub struct ExerciseCapsenseOption<'info> {
    #[account(mut)]
    pub buyer: Signer<'info>,
    #[account(seeds = [b"config"], bump)]
    pub config: Account<'info, ProgramConfig>,
    #[account(
        seeds = [
            b"capsense",
            listing_id.as_ref(),
            &strike_index_bps.to_le_bytes(),
            &expiry_ts.to_le_bytes(),
        ],
        bump = series.bump
    )]
    pub series: Account<'info, CapsenseSeries>,
    #[account(
        mut,
        seeds = [b"capsense_pos", buyer.key().as_ref(), series.key().as_ref()],
        bump = position.bump,
        has_one = buyer @ AcexError::Unauthorized
    )]
    pub position: Account<'info, CapsensePosition>,
    /// CHECK: vault PDA
    #[account(
        seeds = [
            b"capsense_vault",
            listing_id.as_ref(),
            &strike_index_bps.to_le_bytes(),
            &expiry_ts.to_le_bytes(),
        ],
        bump
    )]
    pub series_vault_authority: UncheckedAccount<'info>,
    #[account(
        mut,
        seeds = [
            b"capsense_vault_ata",
            listing_id.as_ref(),
            &strike_index_bps.to_le_bytes(),
            &expiry_ts.to_le_bytes(),
        ],
        bump
    )]
    pub series_vault_ata: Account<'info, TokenAccount>,
    #[account(mut)]
    pub buyer_ata: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
#[instruction(listing_id: [u8; 32])]
pub struct ReleaseCollateral<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(seeds = [b"config"], bump, has_one = admin @ AcexError::Unauthorized)]
    pub config: Account<'info, ProgramConfig>,
    #[account(mut, seeds = [b"collateral", listing_id.as_ref()], bump)]
    pub collateral: Account<'info, CollateralAccount>,
    /// CHECK: vault PDA
    #[account(seeds = [b"vault", listing_id.as_ref()], bump)]
    pub vault_authority: UncheckedAccount<'info>,
    #[account(mut, seeds = [b"vault_ata", listing_id.as_ref()], bump)]
    pub vault_ata: Account<'info, TokenAccount>,
    #[account(mut)]
    pub recipient: Signer<'info>,
    #[account(mut)]
    pub recipient_ata: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
}

// ── Proof-of-Audit contexts ──────────────────────────────────────

#[derive(Accounts)]
pub struct InitializeAuditPool<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(seeds = [b"config"], bump, has_one = admin @ AcexError::Unauthorized)]
    pub config: Account<'info, ProgramConfig>,
    #[account(
        init,
        payer = admin,
        space = 8 + 1 + 2 + 1,
        seeds = [b"audit_pool"],
        bump
    )]
    pub audit_pool: Account<'info, AuditPoolConfig>,
    /// CHECK: vault authority
    #[account(seeds = [b"audit_pool_vault"], bump)]
    pub pool_vault_authority: UncheckedAccount<'info>,
    #[account(
        init,
        payer = admin,
        token::mint = usdc_mint,
        token::authority = pool_vault_authority,
        seeds = [b"audit_pool_vault_ata"],
        bump,
    )]
    pub pool_vault_ata: Account<'info, TokenAccount>,
    pub usdc_mint: Account<'info, Mint>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct StakeAudit<'info> {
    #[account(mut)]
    pub auditor: Signer<'info>,
    #[account(seeds = [b"config"], bump)]
    pub config: Account<'info, ProgramConfig>,
    #[account(seeds = [b"audit_pool"], bump = audit_pool.bump)]
    pub audit_pool: Account<'info, AuditPoolConfig>,
    #[account(
        init_if_needed,
        payer = auditor,
        space = 8 + 32 + 8 + 8 + 1,
        seeds = [b"auditor_stake", auditor.key().as_ref()],
        bump
    )]
    pub auditor_stake: Account<'info, AuditorStakeAccount>,
    /// CHECK: vault authority
    #[account(seeds = [b"audit_pool_vault"], bump)]
    pub pool_vault_authority: UncheckedAccount<'info>,
    #[account(
        mut,
        seeds = [b"audit_pool_vault_ata"],
        bump,
    )]
    pub pool_vault_ata: Account<'info, TokenAccount>,
    #[account(mut)]
    pub auditor_ata: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct UnstakeAudit<'info> {
    #[account(mut)]
    pub auditor: Signer<'info>,
    #[account(seeds = [b"config"], bump)]
    pub config: Account<'info, ProgramConfig>,
    #[account(
        mut,
        seeds = [b"auditor_stake", auditor.key().as_ref()],
        bump = auditor_stake.bump,
        has_one = auditor @ AcexError::Unauthorized
    )]
    pub auditor_stake: Account<'info, AuditorStakeAccount>,
    /// CHECK: vault authority
    #[account(seeds = [b"audit_pool_vault"], bump)]
    pub pool_vault_authority: UncheckedAccount<'info>,
    #[account(mut, seeds = [b"audit_pool_vault_ata"], bump)]
    pub pool_vault_ata: Account<'info, TokenAccount>,
    #[account(mut)]
    pub auditor_ata: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
#[instruction(listing_id: [u8; 32])]
pub struct CoverListing<'info> {
    #[account(mut)]
    pub auditor: Signer<'info>,
    #[account(seeds = [b"config"], bump)]
    pub config: Account<'info, ProgramConfig>,
    #[account(seeds = [b"listing", listing_id.as_ref()], bump = listing.bump)]
    pub listing: Account<'info, Listing>,
    #[account(
        mut,
        seeds = [b"auditor_stake", auditor.key().as_ref()],
        bump,
    )]
    pub auditor_stake: Account<'info, AuditorStakeAccount>,
    #[account(
        init_if_needed,
        payer = auditor,
        space = 8 + 32 + 32 + 8 + 2 + 1 + 8 + 8 + 1,
        seeds = [b"coverage", listing_id.as_ref(), auditor.key().as_ref()],
        bump
    )]
    pub coverage: Account<'info, CoverageRecord>,
    #[account(
        init_if_needed,
        payer = auditor,
        space = 8 + 32 + 2 + 8 + 1 + 8 + 8 + 8 + 8 + 1,
        seeds = [b"listing_audit", listing_id.as_ref()],
        bump
    )]
    pub listing_audit: Account<'info, ListingAuditState>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(listing_id: [u8; 32], reward_auditor: Pubkey)]
pub struct FundAuditRewards<'info> {
    #[account(mut)]
    pub funder: Signer<'info>,
    #[account(seeds = [b"config"], bump)]
    pub config: Account<'info, ProgramConfig>,
    #[account(seeds = [b"audit_pool"], bump = audit_pool.bump)]
    pub audit_pool: Account<'info, AuditPoolConfig>,
    #[account(
        mut,
        seeds = [b"listing_audit", listing_id.as_ref()],
        bump = listing_audit.bump
    )]
    pub listing_audit: Account<'info, ListingAuditState>,
    /// CHECK: auditor pubkey for coverage PDA seeds
    pub reward_auditor: UncheckedAccount<'info>,
    #[account(
        mut,
        seeds = [b"coverage", listing_id.as_ref(), reward_auditor.key().as_ref()],
        bump = coverage.bump,
        constraint = coverage.auditor == reward_auditor.key() @ AcexError::Unauthorized,
    )]
    pub coverage: Account<'info, CoverageRecord>,
    /// CHECK: vault authority
    #[account(seeds = [b"audit_pool_vault"], bump)]
    pub pool_vault_authority: UncheckedAccount<'info>,
    #[account(mut, seeds = [b"audit_pool_vault_ata"], bump)]
    pub pool_vault_ata: Account<'info, TokenAccount>,
    #[account(mut)]
    pub funder_ata: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
#[instruction(listing_id: [u8; 32])]
pub struct ClaimAuditReward<'info> {
    #[account(mut)]
    pub auditor: Signer<'info>,
    #[account(seeds = [b"config"], bump)]
    pub config: Account<'info, ProgramConfig>,
    #[account(
        mut,
        seeds = [b"coverage", listing_id.as_ref(), auditor.key().as_ref()],
        bump = coverage.bump,
        has_one = auditor @ AcexError::Unauthorized
    )]
    pub coverage: Account<'info, CoverageRecord>,
    /// CHECK: vault authority
    #[account(seeds = [b"audit_pool_vault"], bump)]
    pub pool_vault_authority: UncheckedAccount<'info>,
    #[account(mut, seeds = [b"audit_pool_vault_ata"], bump)]
    pub pool_vault_ata: Account<'info, TokenAccount>,
    #[account(mut)]
    pub auditor_ata: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
#[instruction(listing_id: [u8; 32])]
pub struct ObserveListingPrice<'info> {
    #[account(mut)]
    pub observer: Signer<'info>,
    #[account(seeds = [b"config"], bump)]
    pub config: Account<'info, ProgramConfig>,
    #[account(
        init_if_needed,
        payer = observer,
        space = 8 + 32 + 2 + 8 + 1 + 8 + 8 + 8 + 8 + 1,
        seeds = [b"listing_audit", listing_id.as_ref()],
        bump
    )]
    pub listing_audit: Account<'info, ListingAuditState>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(listing_id: [u8; 32], slashed_auditor: Pubkey)]
pub struct TriggerListingDefault<'info> {
    pub caller: Signer<'info>,
    #[account(seeds = [b"config"], bump)]
    pub config: Account<'info, ProgramConfig>,
    #[account(
        mut,
        seeds = [b"listing_audit", listing_id.as_ref()],
        bump = listing_audit.bump
    )]
    pub listing_audit: Account<'info, ListingAuditState>,
    /// CHECK: auditor whose insuring coverage is slashed
    pub slashed_auditor: UncheckedAccount<'info>,
    #[account(
        mut,
        seeds = [b"coverage", listing_id.as_ref(), slashed_auditor.key().as_ref()],
        bump = coverage.bump,
        constraint = coverage.auditor == slashed_auditor.key() @ AcexError::Unauthorized,
    )]
    pub coverage: Account<'info, CoverageRecord>,
    #[account(
        mut,
        seeds = [b"auditor_stake", slashed_auditor.key().as_ref()],
        bump = auditor_stake.bump
    )]
    pub auditor_stake: Account<'info, AuditorStakeAccount>,
}

// ── Events / Errors ──────────────────────────────────────────────

#[event]
pub struct ListingApplied {
    pub listing_id: [u8; 32],
    pub agent: Pubkey,
    pub metadata_hash: [u8; 32],
}

#[event]
pub struct ListingAudited {
    pub listing_id: [u8; 32],
    pub score_bps: u16,
    pub auditor: Pubkey,
}

#[event]
pub struct ListingApproved {
    pub listing_id: [u8; 32],
    pub share_mint: Pubkey,
    pub max_supply: u64,
}

#[event]
pub struct ListingRejected {
    pub listing_id: [u8; 32],
}

#[event]
pub struct CollateralDeposited {
    pub listing_id: [u8; 32],
    pub amount: u64,
    pub depositor: Pubkey,
}

#[event]
pub struct CollateralLocked {
    pub listing_id: [u8; 32],
    pub amount: u64,
}

#[event]
pub struct CollateralReleased {
    pub listing_id: [u8; 32],
    pub amount: u64,
    pub recipient: Pubkey,
}

#[event]
pub struct CapsenseSeriesCreated {
    pub listing_id: [u8; 32],
    pub strike_index_bps: u64,
    pub expiry_ts: i64,
    pub series: Pubkey,
}

#[event]
pub struct CapsenseOptionPurchased {
    pub listing_id: [u8; 32],
    pub buyer: Pubkey,
    pub contracts: u64,
    pub premium: u64,
}

#[event]
pub struct CapsenseOptionExercised {
    pub listing_id: [u8; 32],
    pub buyer: Pubkey,
    pub payout: u64,
    pub index_level_bps: u64,
}

#[event]
pub struct AuditStaked {
    pub auditor: Pubkey,
    pub amount: u64,
    pub total_staked: u64,
}

#[event]
pub struct AuditUnstaked {
    pub auditor: Pubkey,
    pub amount: u64,
    pub total_staked: u64,
}

#[event]
pub struct ListingCovered {
    pub listing_id: [u8; 32],
    pub auditor: Pubkey,
    pub cover_amount: u64,
    pub score_bps: u16,
}

#[event]
pub struct AuditRewardsFunded {
    pub listing_id: [u8; 32],
    pub gross_amount: u64,
    pub fee_amount: u64,
    pub funder: Pubkey,
}

#[event]
pub struct AuditRewardClaimed {
    pub listing_id: [u8; 32],
    pub auditor: Pubkey,
    pub amount: u64,
}

#[event]
pub struct ListingPriceObserved {
    pub listing_id: [u8; 32],
    pub baseline_price_e6: u64,
    pub twap_price_e6: u64,
}

#[event]
pub struct ListingDefaultTriggered {
    pub listing_id: [u8; 32],
    pub drawdown_bps: u16,
}

#[error_code]
pub enum AcexError {
    #[msg("Unauthorized")]
    Unauthorized,
    #[msg("Already initialized")]
    AlreadyInitialized,
    #[msg("Paused")]
    Paused,
    #[msg("Listing not found")]
    ListingNotFound,
    #[msg("Invalid status")]
    InvalidStatus,
    #[msg("Audit score too low")]
    AuditScoreTooLow,
    #[msg("Insufficient collateral")]
    InsufficientCollateral,
    #[msg("Math overflow")]
    MathOverflow,
    #[msg("Zero amount")]
    ZeroAmount,
    #[msg("Option expired")]
    OptionExpired,
    #[msg("Option settled")]
    OptionSettled,
    #[msg("Option out of the money")]
    OptionOutOfMoney,
    #[msg("Option already exercised")]
    OptionAlreadyExercised,
    #[msg("Audit pool not initialized")]
    AuditPoolNotInitialized,
    #[msg("Insufficient stake")]
    InsufficientStake,
    #[msg("Insufficient free stake")]
    InsufficientFreeStake,
    #[msg("Cover too low")]
    CoverTooLow,
    #[msg("Coverage not found")]
    CoverageNotFound,
    #[msg("Invalid coverage phase")]
    InvalidCoveragePhase,
    #[msg("Nothing to claim")]
    NothingToClaim,
    #[msg("Already defaulted")]
    AlreadyDefaulted,
    #[msg("Baseline not set")]
    BaselineNotSet,
    #[msg("Default conditions not met")]
    DefaultConditionsNotMet,
}
