use anchor_lang::prelude::*;
use anchor_spl::token_2022::{spl_token_2022, Token2022};

use crate::errors::CoreError;
use crate::events::MultiplierScheduled;
use crate::state::*;
use crate::token2022::{self, Authority};

#[derive(Accounts)]
pub struct ScheduleMultiplier<'info> {
    #[account(constraint = operator.key() != config.admin @ CoreError::AdminCannotOperate)]
    pub operator: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(
        seeds = [ROLE_SEED, &Role::MultiplierScheduler.seed(), operator.key().as_ref()],
        bump = role_entry.bump,
    )]
    pub role_entry: Account<'info, RoleEntry>,
    /// CHECK: registered Token-2022 mint (enforced by `mint_state` seeds).
    #[account(mut, owner = spl_token_2022::ID)]
    pub mint: UncheckedAccount<'info>,
    #[account(seeds = [MINT_SEED, mint.key().as_ref()], bump = mint_state.bump)]
    pub mint_state: Account<'info, MintState>,
    /// CHECK: signer PDA holding the Scaled UI Amount authority.
    #[account(seeds = [AUTHORITY_SEED], bump = config.authority_bump)]
    pub authority: UncheckedAccount<'info>,
    pub token_program: Program<'info, Token2022>,
}

/// Schedules the same `(multiplier, effectiveAt)` that operations send to Mantle's
/// `ScaledToken.setUIMultiplier`, with the same rules. Token-2022 itself would accept any positive
/// value and apply past timestamps immediately, so all checks live here.
pub fn schedule_multiplier(ctx: Context<ScheduleMultiplier>, multiplier_1e18: u128, effective_at: i64) -> Result<()> {
    require!((MULTIPLIER_MIN..=MULTIPLIER_MAX).contains(&multiplier_1e18), CoreError::MultiplierOutOfRange);
    require!(fits_f64(multiplier_1e18), CoreError::MultiplierTooPrecise);
    let config = &ctx.accounts.config;
    let now = Clock::get()?.unix_timestamp;
    require!(effective_at >= now.saturating_add(config.min_notice), CoreError::NoticeTooShort);
    require!(effective_at <= now.saturating_add(config.max_horizon), CoreError::EffectiveTooFar);

    // At most 15 significant digits (checked above), so the f64 holds the same value as Mantle.
    let multiplier = multiplier_1e18 as f64 / MULTIPLIER_ONE as f64;
    token2022::update_multiplier(
        &ctx.accounts.token_program.to_account_info(),
        &ctx.accounts.mint.to_account_info(),
        &Authority { account: &ctx.accounts.authority.to_account_info(), bump: config.authority_bump },
        multiplier,
        effective_at,
    )?;

    emit!(MultiplierScheduled { mint: ctx.accounts.mint.key(), multiplier_1e18, effective_at });
    Ok(())
}

/// Whether `multiplier_1e18` (non-zero) has at most 15 significant decimal digits.
fn fits_f64(multiplier_1e18: u128) -> bool {
    let mut digits = multiplier_1e18;
    while digits.is_multiple_of(10) {
        digits /= 10;
    }
    digits < 10u128.pow(MULTIPLIER_MAX_SIGNIFICANT_DIGITS)
}
