use anchor_lang::prelude::*;
use anchor_spl::compat::spl_token_metadata_interface::state::TokenMetadata;
use anchor_spl::token_2022::spl_token_2022::{
    self,
    extension::{
        default_account_state::DefaultAccountState, metadata_pointer::MetadataPointer, pausable::PausableConfig,
        permanent_delegate::PermanentDelegate, scaled_ui_amount::ScaledUiAmountConfig, transfer_hook::TransferHook,
        BaseStateWithExtensions, ExtensionType, StateWithExtensions,
    },
    state::{AccountState, Mint},
};

use crate::errors::CoreError;
use crate::events::MintRegistered;
use crate::state::*;

#[derive(Accounts)]
pub struct RegisterMint<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    pub admin: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump, has_one = admin)]
    pub config: Account<'info, Config>,
    /// CHECK: owner checked here, layout and extensions checked in `validate_mint`.
    #[account(owner = spl_token_2022::ID @ CoreError::NotToken2022)]
    pub mint: UncheckedAccount<'info>,
    #[account(
        init,
        payer = payer,
        space = 8 + MintState::INIT_SPACE,
        seeds = [MINT_SEED, mint.key().as_ref()],
        bump,
    )]
    pub mint_state: Account<'info, MintState>,
    /// CHECK: PDA that must hold the mint's authorities.
    #[account(seeds = [AUTHORITY_SEED], bump = config.authority_bump)]
    pub authority: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn register_mint(ctx: Context<RegisterMint>, mantle_token: [u8; 20]) -> Result<()> {
    let mint = ctx.accounts.mint.key();
    validate_mint(
        &ctx.accounts.mint.to_account_info(),
        &ctx.accounts.authority.key(),
        &ctx.accounts.config.hook_authority,
    )?;
    ctx.accounts.mint_state.set_inner(MintState { mint, mantle_token, bump: ctx.bumps.mint_state });
    emit!(MintRegistered { mint, mantle_token });
    Ok(())
}

/// The only extensions an mStocks mint may carry. Anything else (e.g. MintCloseAuthority, transfer
/// fees, confidential transfers) would add an authority this program does not control.
const ALLOWED_EXTENSIONS: [ExtensionType; 7] = [
    ExtensionType::ScaledUiAmount,
    ExtensionType::Pausable,
    ExtensionType::MetadataPointer,
    ExtensionType::TokenMetadata,
    ExtensionType::DefaultAccountState,
    ExtensionType::TransferHook,
    ExtensionType::PermanentDelegate,
];

/// A mint is only accepted if, from the moment it is registered, every privileged capability is
/// held by this program (or, for the dormant Transfer Hook, by the configured multisig), it carries
/// no other extension, and the mint authority belongs to someone else (the CCIP pool).
fn validate_mint(mint_info: &AccountInfo, authority: &Pubkey, hook_authority: &Pubkey) -> Result<()> {
    let data = mint_info.try_borrow_data()?;
    let mint = StateWithExtensions::<Mint>::unpack(&data)?;
    let is_authority = |key: Option<Pubkey>| key == Some(*authority);

    require!(mint.base.decimals == REQUIRED_DECIMALS, CoreError::WrongDecimals);
    for extension in mint.get_extension_types()? {
        require!(ALLOWED_EXTENSIONS.contains(&extension), CoreError::UnexpectedExtension);
    }
    require!(!is_authority(Option::<Pubkey>::from(mint.base.mint_authority)), CoreError::MintAuthorityIsCore);
    require!(is_authority(Option::<Pubkey>::from(mint.base.freeze_authority)), CoreError::WrongFreezeAuthority);

    let scaled = mint.get_extension::<ScaledUiAmountConfig>().map_err(|_| CoreError::WrongScaledUiConfig)?;
    require!(is_authority(Option::<Pubkey>::from(scaled.authority)), CoreError::WrongScaledUiConfig);

    let pausable = mint.get_extension::<PausableConfig>().map_err(|_| CoreError::WrongPausableConfig)?;
    require!(is_authority(Option::<Pubkey>::from(pausable.authority)), CoreError::WrongPausableConfig);

    let pointer = mint.get_extension::<MetadataPointer>().map_err(|_| CoreError::WrongMetadataPointer)?;
    require!(
        Option::<Pubkey>::from(pointer.metadata_address) == Some(*mint_info.key)
            && is_authority(Option::<Pubkey>::from(pointer.authority)),
        CoreError::WrongMetadataPointer
    );
    let metadata = mint.get_variable_len_extension::<TokenMetadata>().map_err(|_| CoreError::WrongTokenMetadata)?;
    require!(
        metadata.mint == *mint_info.key && is_authority(Option::<Pubkey>::from(metadata.update_authority)),
        CoreError::WrongTokenMetadata
    );

    let hook = mint.get_extension::<TransferHook>().map_err(|_| CoreError::WrongTransferHook)?;
    require!(
        Option::<Pubkey>::from(hook.program_id).is_none()
            && Option::<Pubkey>::from(hook.authority) == Some(*hook_authority),
        CoreError::WrongTransferHook
    );

    let default_state = mint.get_extension::<DefaultAccountState>().map_err(|_| CoreError::WrongDefaultAccountState)?;
    require!(default_state.state == AccountState::Initialized as u8, CoreError::WrongDefaultAccountState);

    let delegate = mint.get_extension::<PermanentDelegate>().map_err(|_| CoreError::WrongPermanentDelegate)?;
    require!(is_authority(Option::<Pubkey>::from(delegate.delegate)), CoreError::WrongPermanentDelegate);

    Ok(())
}
