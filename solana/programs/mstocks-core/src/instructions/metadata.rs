use anchor_lang::prelude::*;
use anchor_spl::compat::spl_token_metadata_interface::state::Field;
use anchor_spl::token_2022::{spl_token_2022, Token2022};

use crate::errors::CoreError;
use crate::events::MetadataUpdated;
use crate::state::*;
use crate::token2022::{self, Authority};

/// Token metadata field to update. `Key` covers additional metadata such as the ISIN.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, Debug)]
pub enum MetadataField {
    Name,
    Symbol,
    Uri,
    Key(String),
}

impl MetadataField {
    fn label(&self) -> String {
        match self {
            MetadataField::Name => "name".into(),
            MetadataField::Symbol => "symbol".into(),
            MetadataField::Uri => "uri".into(),
            MetadataField::Key(key) => key.clone(),
        }
    }
}

impl From<MetadataField> for Field {
    fn from(field: MetadataField) -> Self {
        match field {
            MetadataField::Name => Field::Name,
            MetadataField::Symbol => Field::Symbol,
            MetadataField::Uri => Field::Uri,
            MetadataField::Key(key) => Field::Key(key),
        }
    }
}

#[derive(Accounts)]
pub struct UpdateMetadata<'info> {
    #[account(constraint = operator.key() != config.admin @ CoreError::AdminCannotOperate)]
    pub operator: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(
        seeds = [ROLE_SEED, &Role::MetadataOps.seed(), operator.key().as_ref()],
        bump = role_entry.bump,
    )]
    pub role_entry: Account<'info, RoleEntry>,
    /// CHECK: registered Token-2022 mint (enforced by `mint_state` seeds).
    #[account(mut, owner = spl_token_2022::ID)]
    pub mint: UncheckedAccount<'info>,
    #[account(seeds = [MINT_SEED, mint.key().as_ref()], bump = mint_state.bump)]
    pub mint_state: Account<'info, MintState>,
    /// CHECK: signer PDA holding the metadata update authority.
    #[account(seeds = [AUTHORITY_SEED], bump = config.authority_bump)]
    pub authority: UncheckedAccount<'info>,
    pub token_program: Program<'info, Token2022>,
}

/// Token-2022 resizes the mint when a value grows but does not add lamports, so a longer value must
/// be preceded (in the same transaction) by a system transfer that keeps the mint rent-exempt.
pub fn update_metadata(ctx: Context<UpdateMetadata>, field: MetadataField, value: String) -> Result<()> {
    let label = field.label();
    token2022::update_metadata_field(
        &ctx.accounts.token_program.to_account_info(),
        &ctx.accounts.mint.to_account_info(),
        &Authority { account: &ctx.accounts.authority.to_account_info(), bump: ctx.accounts.config.authority_bump },
        field.into(),
        value.clone(),
    )?;
    emit!(MetadataUpdated { mint: ctx.accounts.mint.key(), field: label, value });
    Ok(())
}
