//! mStocks core program for Solana.
//!
//! Holds every privileged Token-2022 authority of each mStocks mint (multiplier, pause, freeze,
//! metadata, permanent delegate) behind a single PDA and exposes them only through role-checked
//! instructions that mirror the Mantle contracts' rules and separation of duties. Minting belongs
//! to the CCIP BurnMint pool and is not handled here.

use anchor_lang::prelude::*;

pub mod errors;
pub mod events;
pub mod instructions;
pub mod state;
pub mod token2022;

use instructions::*;
use state::Role;

declare_id!("3jBxe42f83ruvVZsoCQdgMtGc6nSEGGpkia2Egm6tbwd");

#[program]
pub mod mstocks_core {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>, admin: Pubkey, hook_authority: Pubkey) -> Result<()> {
        instructions::admin::initialize(ctx, admin, hook_authority)
    }

    pub fn propose_admin(ctx: Context<AdminOnly>, new_admin: Pubkey) -> Result<()> {
        instructions::admin::propose_admin(ctx, new_admin)
    }

    pub fn accept_admin(ctx: Context<AcceptAdmin>) -> Result<()> {
        instructions::admin::accept_admin(ctx)
    }

    pub fn grant_role(ctx: Context<GrantRole>, role: Role, member: Pubkey) -> Result<()> {
        instructions::admin::grant_role(ctx, role, member)
    }

    pub fn revoke_role(ctx: Context<RevokeRole>, role: Role, member: Pubkey) -> Result<()> {
        instructions::admin::revoke_role(ctx, role, member)
    }

    pub fn renounce_role(ctx: Context<RenounceRole>, role: Role) -> Result<()> {
        instructions::admin::renounce_role(ctx, role)
    }

    pub fn register_mint(ctx: Context<RegisterMint>, mantle_token: [u8; 20]) -> Result<()> {
        instructions::register_mint::register_mint(ctx, mantle_token)
    }

    pub fn schedule_multiplier(
        ctx: Context<ScheduleMultiplier>,
        multiplier_1e18: u128,
        effective_at: i64,
    ) -> Result<()> {
        instructions::multiplier::schedule_multiplier(ctx, multiplier_1e18, effective_at)
    }

    pub fn pause(ctx: Context<Pause>) -> Result<()> {
        instructions::pause::pause(ctx)
    }

    pub fn resume(ctx: Context<Resume>) -> Result<()> {
        instructions::pause::resume(ctx)
    }

    pub fn pause_all<'info>(ctx: Context<'info, PauseAll<'info>>) -> Result<()> {
        instructions::pause::pause_all(ctx)
    }

    /// Token accounts to freeze are passed as remaining accounts.
    pub fn freeze<'info>(ctx: Context<'info, Freeze<'info>>) -> Result<()> {
        instructions::compliance::freeze(ctx)
    }

    /// Token accounts to thaw are passed as remaining accounts.
    pub fn thaw<'info>(ctx: Context<'info, Thaw<'info>>) -> Result<()> {
        instructions::compliance::thaw(ctx)
    }

    pub fn clawback(ctx: Context<Clawback>, amount: u64) -> Result<()> {
        instructions::compliance::clawback(ctx, amount)
    }

    /// Admin-only policy switch: `frozen = true` makes new token accounts start frozen.
    pub fn set_default_account_state(ctx: Context<SetDefaultAccountState>, frozen: bool) -> Result<()> {
        instructions::account_state::set_default_account_state(ctx, frozen)
    }

    pub fn update_metadata(ctx: Context<UpdateMetadata>, field: MetadataField, value: String) -> Result<()> {
        instructions::metadata::update_metadata(ctx, field, value)
    }
}
