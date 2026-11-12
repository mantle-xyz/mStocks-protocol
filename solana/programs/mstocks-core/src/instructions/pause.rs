use anchor_lang::prelude::*;
use anchor_spl::token_2022::{spl_token_2022, Token2022};

use crate::errors::CoreError;
use crate::events::{Paused, Resumed};
use crate::state::*;
use crate::token2022::{self, Authority};

/// Accounts shared by `pause` (Pauser role) and `resume` (Unpauser role). The two roles stay
/// separate, mirroring Mantle's PAUSE_ROLE / UNPAUSE_ROLE.
macro_rules! toggle_accounts {
    ($name:ident, $role:expr) => {
        #[derive(Accounts)]
        pub struct $name<'info> {
            #[account(constraint = operator.key() != config.admin @ CoreError::AdminCannotOperate)]
            pub operator: Signer<'info>,
            #[account(seeds = [CONFIG_SEED], bump = config.bump)]
            pub config: Account<'info, Config>,
            #[account(seeds = [ROLE_SEED, &$role.seed(), operator.key().as_ref()], bump = role_entry.bump)]
            pub role_entry: Account<'info, RoleEntry>,
            /// CHECK: registered Token-2022 mint (enforced by `mint_state` seeds).
            #[account(mut, owner = spl_token_2022::ID)]
            pub mint: UncheckedAccount<'info>,
            #[account(seeds = [MINT_SEED, mint.key().as_ref()], bump = mint_state.bump)]
            pub mint_state: Account<'info, MintState>,
            /// CHECK: signer PDA holding the Pausable authority.
            #[account(seeds = [AUTHORITY_SEED], bump = config.authority_bump)]
            pub authority: UncheckedAccount<'info>,
            pub token_program: Program<'info, Token2022>,
        }
    };
}

toggle_accounts!(Pause, Role::Pauser);
toggle_accounts!(Resume, Role::Unpauser);

pub fn pause(ctx: Context<Pause>) -> Result<()> {
    let a = &ctx.accounts;
    toggle(&a.token_program, &a.mint, &a.authority, a.config.authority_bump, true)
}

pub fn resume(ctx: Context<Resume>) -> Result<()> {
    let a = &ctx.accounts;
    toggle(&a.token_program, &a.mint, &a.authority, a.config.authority_bump, false)
}

fn toggle<'info>(
    token_program: &Program<'info, Token2022>,
    mint: &UncheckedAccount<'info>,
    authority: &UncheckedAccount<'info>,
    bump: u8,
    paused: bool,
) -> Result<()> {
    token2022::set_paused(
        &token_program.to_account_info(),
        &mint.to_account_info(),
        &Authority { account: &authority.to_account_info(), bump },
        paused,
    )?;
    if paused {
        emit!(Paused { mint: mint.key() });
    } else {
        emit!(Resumed { mint: mint.key() });
    }
    Ok(())
}

#[derive(Accounts)]
pub struct PauseAll<'info> {
    #[account(constraint = operator.key() != config.admin @ CoreError::AdminCannotOperate)]
    pub operator: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(
        seeds = [ROLE_SEED, &Role::Pauser.seed(), operator.key().as_ref()],
        bump = role_entry.bump,
    )]
    pub role_entry: Account<'info, RoleEntry>,
    /// CHECK: signer PDA holding the Pausable authority.
    #[account(seeds = [AUTHORITY_SEED], bump = config.authority_bump)]
    pub authority: UncheckedAccount<'info>,
    pub token_program: Program<'info, Token2022>,
}

/// Pauses every `(mint, mint_state)` pair passed as remaining accounts. A transaction only fits a
/// limited number of mints, so a global pause is sent as several of these.
pub fn pause_all<'info>(ctx: Context<'info, PauseAll<'info>>) -> Result<()> {
    let remaining = ctx.remaining_accounts;
    require!(!remaining.is_empty() && remaining.len().is_multiple_of(2), CoreError::BadRemainingAccounts);
    let token_program = ctx.accounts.token_program.to_account_info();
    let authority_info = ctx.accounts.authority.to_account_info();
    let authority = Authority { account: &authority_info, bump: ctx.accounts.config.authority_bump };

    for pair in remaining.chunks(2) {
        let (mint, mint_state) = (&pair[0], &pair[1]);
        require_registered(mint, mint_state, ctx.program_id)?;
        token2022::set_paused(&token_program, mint, &authority, true)?;
        emit!(Paused { mint: mint.key() });
    }
    Ok(())
}

/// Checks that `mint_state` is this program's MintState PDA for `mint`.
pub fn require_registered(mint: &AccountInfo, mint_state: &AccountInfo, program_id: &Pubkey) -> Result<()> {
    require_keys_eq!(*mint.owner, spl_token_2022::ID, CoreError::NotToken2022);
    let (expected, _) = Pubkey::find_program_address(&[MINT_SEED, mint.key.as_ref()], program_id);
    require_keys_eq!(*mint_state.key, expected, CoreError::BadRemainingAccounts);
    require_keys_eq!(*mint_state.owner, *program_id, CoreError::BadRemainingAccounts);
    let state = MintState::try_deserialize(&mut &mint_state.try_borrow_data()?[..])?;
    require_keys_eq!(state.mint, *mint.key, CoreError::MintMismatch);
    Ok(())
}
