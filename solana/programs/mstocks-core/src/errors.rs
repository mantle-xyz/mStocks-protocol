use anchor_lang::prelude::*;

#[error_code]
pub enum CoreError {
    #[msg("Only the program upgrade authority can initialize")]
    NotUpgradeAuthority,
    #[msg("Admin cannot grant a role to itself")]
    SelfGrantNotAllowed,
    #[msg("Admin cannot perform operational actions")]
    AdminCannotOperate,
    #[msg("No pending admin, or signer is not the pending admin")]
    NotPendingAdmin,
    #[msg("Multiplier outside [1e9, 1e27] (1e18 fixed point)")]
    MultiplierOutOfRange,
    #[msg("Effective time is earlier than the minimum notice period")]
    NoticeTooShort,
    #[msg("Effective time is beyond the scheduling horizon")]
    EffectiveTooFar,
    #[msg("Mint is not owned by the Token-2022 program")]
    NotToken2022,
    #[msg("Mint must have 9 decimals")]
    WrongDecimals,
    #[msg("Mint authority must belong to the CCIP pool, not this program")]
    MintAuthorityIsCore,
    #[msg("Freeze authority must be the program authority PDA")]
    WrongFreezeAuthority,
    #[msg("Scaled UI Amount extension missing or authority is not the program authority PDA")]
    WrongScaledUiConfig,
    #[msg("Pausable extension missing or authority is not the program authority PDA")]
    WrongPausableConfig,
    #[msg("Metadata pointer must point at the mint itself and be controlled by the program authority PDA")]
    WrongMetadataPointer,
    #[msg("Token metadata missing or update authority is not the program authority PDA")]
    WrongTokenMetadata,
    #[msg("Transfer Hook must exist, be dormant, and be controlled by the configured hook authority")]
    WrongTransferHook,
    #[msg("Default Account State must exist and be Initialized")]
    WrongDefaultAccountState,
    #[msg("Permanent delegate must be the program authority PDA")]
    WrongPermanentDelegate,
    #[msg("Account does not belong to the given registered mint")]
    MintMismatch,
    #[msg("Remaining accounts are missing or malformed")]
    BadRemainingAccounts,
    #[msg("Source and destination must differ")]
    SameAccount,
    #[msg("Mint carries an extension mStocks does not allow")]
    UnexpectedExtension,
    #[msg("Multiplier has more than 15 significant digits")]
    MultiplierTooPrecise,
}
