use anchor_lang::prelude::*;

use crate::errors::CoreError;
use crate::events::{AdminAccepted, AdminProposed, RoleGranted, RoleRevoked};
use crate::program::MstocksCore;
use crate::state::*;

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(init, payer = payer, space = 8 + Config::INIT_SPACE, seeds = [CONFIG_SEED], bump)]
    pub config: Account<'info, Config>,
    /// CHECK: PDA that will hold every mint authority; only its bump is recorded here.
    #[account(seeds = [AUTHORITY_SEED], bump)]
    pub authority: UncheckedAccount<'info>,
    /// Initialization is restricted to the upgrade authority so nobody can front-run the
    /// deployment and install their own admin.
    #[account(constraint = program.programdata_address()? == Some(program_data.key()))]
    pub program: Program<'info, MstocksCore>,
    #[account(constraint = program_data.upgrade_authority_address == Some(payer.key()) @ CoreError::NotUpgradeAuthority)]
    pub program_data: Account<'info, ProgramData>,
    pub system_program: Program<'info, System>,
}

pub fn initialize(ctx: Context<Initialize>, admin: Pubkey, hook_authority: Pubkey) -> Result<()> {
    ctx.accounts.config.set_inner(Config {
        admin,
        pending_admin: None,
        hook_authority,
        min_notice: DEFAULT_MIN_NOTICE,
        max_horizon: DEFAULT_MAX_HORIZON,
        bump: ctx.bumps.config,
        authority_bump: ctx.bumps.authority,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct AdminOnly<'info> {
    pub admin: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = admin)]
    pub config: Account<'info, Config>,
}

pub fn propose_admin(ctx: Context<AdminOnly>, new_admin: Pubkey) -> Result<()> {
    let config = &mut ctx.accounts.config;
    config.pending_admin = Some(new_admin);
    emit!(AdminProposed { current: config.admin, proposed: new_admin });
    Ok(())
}

#[derive(Accounts)]
pub struct AcceptAdmin<'info> {
    pub new_admin: Signer<'info>,
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = config.pending_admin == Some(new_admin.key()) @ CoreError::NotPendingAdmin,
    )]
    pub config: Account<'info, Config>,
}

pub fn accept_admin(ctx: Context<AcceptAdmin>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    let previous = config.admin;
    config.admin = ctx.accounts.new_admin.key();
    config.pending_admin = None;
    emit!(AdminAccepted { previous, admin: config.admin });
    Ok(())
}

#[derive(Accounts)]
#[instruction(role: Role, member: Pubkey)]
pub struct GrantRole<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    pub admin: Signer<'info>,
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        has_one = admin,
        constraint = member != config.admin @ CoreError::SelfGrantNotAllowed,
    )]
    pub config: Account<'info, Config>,
    #[account(
        init,
        payer = payer,
        space = 8 + RoleEntry::INIT_SPACE,
        seeds = [ROLE_SEED, &role.seed(), member.as_ref()],
        bump,
    )]
    pub role_entry: Account<'info, RoleEntry>,
    pub system_program: Program<'info, System>,
}

pub fn grant_role(ctx: Context<GrantRole>, role: Role, member: Pubkey) -> Result<()> {
    ctx.accounts.role_entry.set_inner(RoleEntry { role, member, bump: ctx.bumps.role_entry });
    emit!(RoleGranted { role, member });
    Ok(())
}

#[derive(Accounts)]
#[instruction(role: Role, member: Pubkey)]
pub struct RevokeRole<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump, has_one = admin)]
    pub config: Account<'info, Config>,
    #[account(
        mut,
        close = admin,
        seeds = [ROLE_SEED, &role.seed(), member.as_ref()],
        bump = role_entry.bump,
    )]
    pub role_entry: Account<'info, RoleEntry>,
}

pub fn revoke_role(_ctx: Context<RevokeRole>, role: Role, member: Pubkey) -> Result<()> {
    emit!(RoleRevoked { role, member });
    Ok(())
}

#[derive(Accounts)]
#[instruction(role: Role)]
pub struct RenounceRole<'info> {
    #[account(mut)]
    pub member: Signer<'info>,
    #[account(
        mut,
        close = member,
        seeds = [ROLE_SEED, &role.seed(), member.key().as_ref()],
        bump = role_entry.bump,
    )]
    pub role_entry: Account<'info, RoleEntry>,
}

pub fn renounce_role(ctx: Context<RenounceRole>, role: Role) -> Result<()> {
    emit!(RoleRevoked { role, member: ctx.accounts.member.key() });
    Ok(())
}
