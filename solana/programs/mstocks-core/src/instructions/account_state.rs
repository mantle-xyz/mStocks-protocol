use anchor_lang::prelude::*;
use anchor_spl::token_2022::{spl_token_2022, Token2022};

use crate::events::DefaultAccountStateSet;
use crate::state::*;
use crate::token2022::{self, Authority};

/// Switches a mint between "accounts start usable" (today's screen-after-use compliance) and
/// "accounts start frozen" (screen before use: every new account must be thawed before use). A
/// compliance-policy change, so it is the admin's (Squads) call, like Mantle's admin-only
/// `updateCompliance`.
#[derive(Accounts)]
pub struct SetDefaultAccountState<'info> {
    pub admin: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump, has_one = admin)]
    pub config: Account<'info, Config>,
    /// CHECK: registered Token-2022 mint (enforced by `mint_state` seeds).
    #[account(mut, owner = spl_token_2022::ID)]
    pub mint: UncheckedAccount<'info>,
    #[account(seeds = [MINT_SEED, mint.key().as_ref()], bump = mint_state.bump)]
    pub mint_state: Account<'info, MintState>,
    /// CHECK: signer PDA holding the freeze authority.
    #[account(seeds = [AUTHORITY_SEED], bump = config.authority_bump)]
    pub authority: UncheckedAccount<'info>,
    pub token_program: Program<'info, Token2022>,
}

pub fn set_default_account_state(ctx: Context<SetDefaultAccountState>, frozen: bool) -> Result<()> {
    token2022::set_default_account_state(
        &ctx.accounts.token_program.to_account_info(),
        &ctx.accounts.mint.to_account_info(),
        &Authority { account: &ctx.accounts.authority.to_account_info(), bump: ctx.accounts.config.authority_bump },
        frozen,
    )?;
    emit!(DefaultAccountStateSet { mint: ctx.accounts.mint.key(), frozen });
    Ok(())
}
