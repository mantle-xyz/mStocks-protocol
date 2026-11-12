//! Thin CPI wrappers around Token-2022. Every call is signed by the authority PDA, which holds the
//! corresponding authority on every registered mint.

use anchor_lang::prelude::*;
use anchor_lang::solana_program::program::invoke_signed;
use anchor_spl::compat::spl_token_metadata_interface;
use anchor_spl::token_2022::spl_token_2022;

use crate::state::AUTHORITY_SEED;

pub struct Authority<'a, 'info> {
    pub account: &'a AccountInfo<'info>,
    pub bump: u8,
}

impl<'a, 'info> Authority<'a, 'info> {
    fn invoke(
        &self,
        ix: &anchor_lang::solana_program::instruction::Instruction,
        infos: &[AccountInfo<'info>],
    ) -> Result<()> {
        invoke_signed(ix, infos, &[&[AUTHORITY_SEED, &[self.bump]]]).map_err(Into::into)
    }
}

pub fn update_multiplier<'info>(
    token_program: &AccountInfo<'info>,
    mint: &AccountInfo<'info>,
    authority: &Authority<'_, 'info>,
    multiplier: f64,
    effective_timestamp: i64,
) -> Result<()> {
    let ix = spl_token_2022::extension::scaled_ui_amount::instruction::update_multiplier(
        token_program.key,
        mint.key,
        authority.account.key,
        &[],
        multiplier,
        effective_timestamp,
    )?;
    authority.invoke(&ix, &[mint.clone(), authority.account.clone(), token_program.clone()])
}

pub fn set_paused<'info>(
    token_program: &AccountInfo<'info>,
    mint: &AccountInfo<'info>,
    authority: &Authority<'_, 'info>,
    paused: bool,
) -> Result<()> {
    let build = if paused {
        spl_token_2022::extension::pausable::instruction::pause
    } else {
        spl_token_2022::extension::pausable::instruction::resume
    };
    let ix = build(token_program.key, mint.key, authority.account.key, &[])?;
    authority.invoke(&ix, &[mint.clone(), authority.account.clone(), token_program.clone()])
}

pub fn set_frozen<'info>(
    token_program: &AccountInfo<'info>,
    account: &AccountInfo<'info>,
    mint: &AccountInfo<'info>,
    authority: &Authority<'_, 'info>,
    frozen: bool,
) -> Result<()> {
    let build =
        if frozen { spl_token_2022::instruction::freeze_account } else { spl_token_2022::instruction::thaw_account };
    let ix = build(token_program.key, account.key, mint.key, authority.account.key, &[])?;
    authority.invoke(&ix, &[account.clone(), mint.clone(), authority.account.clone(), token_program.clone()])
}

/// Sets the state every new token account of `mint` starts in (Default Account State extension;
/// the freeze authority signs).
pub fn set_default_account_state<'info>(
    token_program: &AccountInfo<'info>,
    mint: &AccountInfo<'info>,
    authority: &Authority<'_, 'info>,
    frozen: bool,
) -> Result<()> {
    use spl_token_2022::{
        extension::default_account_state::instruction::update_default_account_state, state::AccountState,
    };
    let state = if frozen { AccountState::Frozen } else { AccountState::Initialized };
    let ix = update_default_account_state(token_program.key, mint.key, authority.account.key, &[], &state)?;
    authority.invoke(&ix, &[mint.clone(), authority.account.clone(), token_program.clone()])
}

/// Transfer as the mint's permanent delegate. The mint's Transfer Hook is dormant, so no extra
/// hook accounts are needed.
#[allow(clippy::too_many_arguments)]
pub fn delegate_transfer<'info>(
    token_program: &AccountInfo<'info>,
    source: &AccountInfo<'info>,
    mint: &AccountInfo<'info>,
    destination: &AccountInfo<'info>,
    authority: &Authority<'_, 'info>,
    amount: u64,
    decimals: u8,
) -> Result<()> {
    let ix = spl_token_2022::instruction::transfer_checked(
        token_program.key,
        source.key,
        mint.key,
        destination.key,
        authority.account.key,
        &[],
        amount,
        decimals,
    )?;
    authority.invoke(
        &ix,
        &[source.clone(), mint.clone(), destination.clone(), authority.account.clone(), token_program.clone()],
    )
}

/// Token metadata lives in the mint account itself (metadata pointer → self), so the "metadata
/// program" is Token-2022.
pub fn update_metadata_field<'info>(
    token_program: &AccountInfo<'info>,
    mint: &AccountInfo<'info>,
    authority: &Authority<'_, 'info>,
    field: spl_token_metadata_interface::state::Field,
    value: String,
) -> Result<()> {
    let ix = spl_token_metadata_interface::instruction::update_field(
        token_program.key,
        mint.key,
        authority.account.key,
        field,
        value,
    );
    authority.invoke(&ix, &[mint.clone(), authority.account.clone(), token_program.clone()])
}
