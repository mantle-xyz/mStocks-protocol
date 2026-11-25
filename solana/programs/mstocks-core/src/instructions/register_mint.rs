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
use crate::events::{MintRegistered, MintUnregistered};
use crate::state::*;

/// Registration is an operations task (the `MintRegistrar` role), like deploying a token through
/// Mantle's `ScaledTokenFactory` with `OPS_ROLE`: `validate_mint` leaves no room for a mint that
/// keeps an authority outside Core, and each Mantle token maps to at most one mint.
#[derive(Accounts)]
#[instruction(mantle_token: [u8; 20])]
pub struct RegisterMint<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(constraint = !config.is_admin(&registrar.key()) @ CoreError::AdminCannotOperate)]
    pub registrar: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(
        seeds = [ROLE_SEED, &Role::MintRegistrar.seed(), registrar.key().as_ref()],
        bump = role_entry.bump,
    )]
    pub role_entry: Account<'info, RoleEntry>,
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
    #[account(
        init,
        payer = payer,
        space = 8 + MantleTokenIndex::INIT_SPACE,
        seeds = [MANTLE_TOKEN_SEED, mantle_token.as_ref()],
        bump,
    )]
    pub mantle_index: Account<'info, MantleTokenIndex>,
    /// CHECK: PDA that must hold the mint's authorities.
    #[account(seeds = [AUTHORITY_SEED], bump = config.authority_bump)]
    pub authority: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn register_mint(ctx: Context<RegisterMint>, mantle_token: [u8; 20]) -> Result<()> {
    require!(mantle_token != [0u8; 20], CoreError::ZeroMantleToken);
    let mint = ctx.accounts.mint.key();
    validate_mint(
        &ctx.accounts.mint.to_account_info(),
        &ctx.accounts.authority.key(),
        &ctx.accounts.config.hook_authority,
    )?;
    ctx.accounts.mint_state.set_inner(MintState { mint, mantle_token, bump: ctx.bumps.mint_state });
    ctx.accounts.mantle_index.set_inner(MantleTokenIndex { mint, bump: ctx.bumps.mantle_index });
    emit!(MintRegistered { mint, mantle_token });
    Ok(())
}

/// Undoes a registration made in error (wrong mint or wrong Mantle token), so it can be registered
/// again correctly. Only while the mint has no supply: once tokens exist, Core must keep operating
/// it (freeze, pause, clawback all require the registration). And only while its mint authority is
/// a plain key: once the CCIP pool can mint (its signer holds the authority, directly or through a
/// token multisig), the pool could mint into the mint after it left Core, so a CCIP-connected mint
/// stays registered.
#[derive(Accounts)]
pub struct UnregisterMint<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump, has_one = admin)]
    pub config: Account<'info, Config>,
    /// CHECK: owner checked here, supply read in the handler.
    #[account(owner = spl_token_2022::ID @ CoreError::NotToken2022)]
    pub mint: UncheckedAccount<'info>,
    #[account(mut, close = admin, seeds = [MINT_SEED, mint.key().as_ref()], bump = mint_state.bump)]
    pub mint_state: Account<'info, MintState>,
    #[account(
        mut,
        close = admin,
        seeds = [MANTLE_TOKEN_SEED, mint_state.mantle_token.as_ref()],
        bump = mantle_index.bump,
        constraint = mantle_index.mint == mint.key() @ CoreError::MintMismatch,
    )]
    pub mantle_index: Account<'info, MantleTokenIndex>,
    /// CHECK: the mint's current mint authority, required when it has one; the handler checks that
    /// it is that key and what kind of account it is. It does not sign: a Squads vault proposes the
    /// unregistration, and the authority may be a key the multisig cannot add as a signer.
    pub mint_authority: Option<UncheckedAccount<'info>>,
}

pub fn unregister_mint(ctx: Context<UnregisterMint>) -> Result<()> {
    let (supply, mint_authority) = {
        let data = ctx.accounts.mint.try_borrow_data()?;
        let base = StateWithExtensions::<Mint>::unpack(&data)?.base;
        (base.supply, Option::<Pubkey>::from(base.mint_authority))
    };
    require!(supply == 0, CoreError::MintHasSupply);
    if let Some(authority) = mint_authority {
        let account = ctx.accounts.mint_authority.as_ref().ok_or(CoreError::MintAuthorityNotAKey)?;
        require_keys_eq!(account.key(), authority, CoreError::MintAuthorityNotAKey);
        // A program address (the CCIP pool's signer) is off the curve, and a token multisig (which
        // can include the pool's signer, the CCIP setup mStocks uses) is an account of a token
        // program; only a key that signs for itself may hold the authority of an unregistered mint.
        let token_multisig = *account.owner == spl_token_2022::ID || *account.owner == anchor_spl::token::ID;
        require!(authority.is_on_curve() && !token_multisig, CoreError::MintAuthorityNotAKey);
    }
    emit!(MintUnregistered { mint: ctx.accounts.mint.key(), mantle_token: ctx.accounts.mint_state.mantle_token });
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
    // Every token must come from the CCIP pool against tokens locked on Mantle; supply minted before
    // registration would be unbacked.
    require!(mint.base.supply == 0, CoreError::MintHasSupply);
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
