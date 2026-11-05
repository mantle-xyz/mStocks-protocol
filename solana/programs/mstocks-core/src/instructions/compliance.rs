use anchor_lang::prelude::*;
use anchor_spl::token_2022::{
    spl_token_2022::{
        self,
        extension::StateWithExtensions,
        state::{Account as TokenAccount, AccountState, Mint},
    },
    Token2022,
};

use crate::errors::CoreError;
use crate::events::{ClawedBack, Frozen, Thawed};
use crate::state::*;
use crate::token2022::{self, Authority};

/// Accounts shared by `freeze` (Freezer role: backend KMS, fast) and `thaw` (Unfreezer role:
/// multisig, careful). Token accounts to act on are passed as remaining accounts.
macro_rules! freeze_accounts {
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
            #[account(owner = spl_token_2022::ID)]
            pub mint: UncheckedAccount<'info>,
            #[account(seeds = [MINT_SEED, mint.key().as_ref()], bump = mint_state.bump)]
            pub mint_state: Account<'info, MintState>,
            /// CHECK: signer PDA holding the freeze authority.
            #[account(seeds = [AUTHORITY_SEED], bump = config.authority_bump)]
            pub authority: UncheckedAccount<'info>,
            pub token_program: Program<'info, Token2022>,
        }
    };
}

freeze_accounts!(Freeze, Role::Freezer);
freeze_accounts!(Thaw, Role::Unfreezer);

pub fn freeze<'info>(ctx: Context<'info, Freeze<'info>>) -> Result<()> {
    let a = &ctx.accounts;
    set_frozen(&a.token_program, &a.mint, &a.authority, a.config.authority_bump, ctx.remaining_accounts, true)
}

pub fn thaw<'info>(ctx: Context<'info, Thaw<'info>>) -> Result<()> {
    let a = &ctx.accounts;
    set_frozen(&a.token_program, &a.mint, &a.authority, a.config.authority_bump, ctx.remaining_accounts, false)
}

/// Freezes (or thaws) every given token account. Accounts already in the target state are
/// skipped, so the backend can resend a batch safely.
fn set_frozen<'info>(
    token_program: &Program<'info, Token2022>,
    mint: &UncheckedAccount<'info>,
    authority: &UncheckedAccount<'info>,
    bump: u8,
    accounts: &[AccountInfo<'info>],
    frozen: bool,
) -> Result<()> {
    require!(!accounts.is_empty(), CoreError::BadRemainingAccounts);
    let mint = mint.to_account_info();
    let token_program = token_program.to_account_info();
    let authority_info = authority.to_account_info();
    let authority = Authority { account: &authority_info, bump };

    for account in accounts {
        if account_state(account, mint.key)? == target_state(frozen) {
            continue;
        }
        token2022::set_frozen(&token_program, account, &mint, &authority, frozen)?;
        if frozen {
            emit!(Frozen { mint: *mint.key, account: account.key() });
        } else {
            emit!(Thawed { mint: *mint.key, account: account.key() });
        }
    }
    Ok(())
}

#[derive(Accounts)]
pub struct Clawback<'info> {
    #[account(constraint = operator.key() != config.admin @ CoreError::AdminCannotOperate)]
    pub operator: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(
        seeds = [ROLE_SEED, &Role::Clawback.seed(), operator.key().as_ref()],
        bump = role_entry.bump,
    )]
    pub role_entry: Account<'info, RoleEntry>,
    /// CHECK: registered Token-2022 mint (enforced by `mint_state` seeds).
    #[account(owner = spl_token_2022::ID)]
    pub mint: UncheckedAccount<'info>,
    #[account(seeds = [MINT_SEED, mint.key().as_ref()], bump = mint_state.bump)]
    pub mint_state: Account<'info, MintState>,
    /// CHECK: token account of `mint`, checked in the handler.
    #[account(mut, owner = spl_token_2022::ID, constraint = source.key() != destination.key() @ CoreError::SameAccount)]
    pub source: UncheckedAccount<'info>,
    /// CHECK: custody token account of `mint`, checked in the handler.
    #[account(mut, owner = spl_token_2022::ID)]
    pub destination: UncheckedAccount<'info>,
    /// CHECK: signer PDA holding the freeze authority and the permanent delegate.
    #[account(seeds = [AUTHORITY_SEED], bump = config.authority_bump)]
    pub authority: UncheckedAccount<'info>,
    pub token_program: Program<'info, Token2022>,
}

/// Moves `amount` from `source` to a custody `destination` as the permanent delegate. A frozen
/// account cannot be debited even by the permanent delegate, so the source is thawed, debited and
/// frozen again within this one instruction; it always ends frozen.
pub fn clawback(ctx: Context<Clawback>, amount: u64) -> Result<()> {
    let mint = ctx.accounts.mint.to_account_info();
    let source = ctx.accounts.source.to_account_info();
    let destination = ctx.accounts.destination.to_account_info();
    let token_program = ctx.accounts.token_program.to_account_info();
    let authority_info = ctx.accounts.authority.to_account_info();
    let authority = Authority { account: &authority_info, bump: ctx.accounts.config.authority_bump };

    let source_was_frozen = account_state(&source, mint.key)? == AccountState::Frozen;
    account_state(&destination, mint.key)?;
    let decimals = {
        let data = mint.try_borrow_data()?;
        StateWithExtensions::<Mint>::unpack(&data)?.base.decimals
    };

    if source_was_frozen {
        token2022::set_frozen(&token_program, &source, &mint, &authority, false)?;
    }
    token2022::delegate_transfer(&token_program, &source, &mint, &destination, &authority, amount, decimals)?;
    token2022::set_frozen(&token_program, &source, &mint, &authority, true)?;

    emit!(ClawedBack { mint: *mint.key, source: *source.key, destination: *destination.key, amount });
    Ok(())
}

fn target_state(frozen: bool) -> AccountState {
    if frozen {
        AccountState::Frozen
    } else {
        AccountState::Initialized
    }
}

/// Returns the state of a Token-2022 token account after checking it belongs to `mint`.
fn account_state(account: &AccountInfo, mint: &Pubkey) -> Result<AccountState> {
    require_keys_eq!(*account.owner, spl_token_2022::ID, CoreError::NotToken2022);
    let data = account.try_borrow_data()?;
    let token = StateWithExtensions::<TokenAccount>::unpack(&data)?;
    require_keys_eq!(token.base.mint, *mint, CoreError::MintMismatch);
    Ok(token.base.state)
}
