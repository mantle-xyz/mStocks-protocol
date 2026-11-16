use anchor_lang::prelude::*;

pub const CONFIG_SEED: &[u8] = b"config";
pub const ROLE_SEED: &[u8] = b"role";
pub const MINT_SEED: &[u8] = b"mint";
/// Seed of the index that maps one Mantle token to the one mint registered for it.
pub const MANTLE_TOKEN_SEED: &[u8] = b"mantle_token";
/// Seed of the PDA that holds every Token-2022 authority (multiplier, pause, freeze, metadata,
/// permanent delegate) of every registered mint. Only this program can sign for it.
pub const AUTHORITY_SEED: &[u8] = b"authority";

/// Mantle's `ScaledToken` is 18 decimals; Solana amounts are u64, so mints use 9 (1e9 conversion).
pub const REQUIRED_DECIMALS: u8 = 9;

/// Mirrors Mantle `ScaledToken`: multiplier is 1e18 fixed point within [1e9, 1e27] (1e-9x .. 1e9x).
pub const MULTIPLIER_ONE: u128 = 1_000_000_000_000_000_000;
pub const MULTIPLIER_MIN: u128 = 1_000_000_000;
pub const MULTIPLIER_MAX: u128 = 1_000_000_000_000_000_000_000_000_000;
/// Token-2022 stores the multiplier as an f64, which holds 15 significant decimal digits exactly.
/// Anything finer would be rounded here while Mantle keeps it, so it is rejected instead.
pub const MULTIPLIER_MAX_SIGNIFICANT_DIGITS: u32 = 15;

/// Mirrors Mantle `minMultiplierNotice` (config.toml) and the 365-day scheduling horizon.
pub const DEFAULT_MIN_NOTICE: i64 = 300;
pub const DEFAULT_MAX_HORIZON: i64 = 365 * 24 * 60 * 60;

/// Two admins, split like Mantle's: `admin` mirrors the token and factory admin (multisig 1) and
/// governs the token roles and the mint registry; `compliance_admin` mirrors the compliance and
/// pause registries' admin (multisig 4) and governs the pause, freeze and clawback roles. Neither
/// ever operates. The compliance fields are appended last so the account keeps its prefix.
#[account]
#[derive(InitSpace)]
pub struct Config {
    /// Squads multisig (Mantle multisig 1). Grants/revokes the token roles, governs the mint registry.
    pub admin: Pubkey,
    /// Two-step admin handover target.
    pub pending_admin: Option<Pubkey>,
    /// Squads multisig that must hold every mint's (dormant) Transfer Hook authority.
    pub hook_authority: Pubkey,
    pub min_notice: i64,
    pub max_horizon: i64,
    pub bump: u8,
    pub authority_bump: u8,
    /// Squads multisig (Mantle multisig 4). Grants/revokes the compliance roles.
    pub compliance_admin: Pubkey,
    /// Two-step compliance admin handover target.
    pub pending_compliance_admin: Option<Pubkey>,
}

impl Config {
    /// The admin that grants and revokes `role`.
    pub fn role_admin(&self, role: Role) -> Pubkey {
        if role.is_compliance() {
            self.compliance_admin
        } else {
            self.admin
        }
    }

    /// Either admin: neither may operate or hold a role.
    pub fn is_admin(&self, key: &Pubkey) -> bool {
        *key == self.admin || *key == self.compliance_admin
    }
}

/// Existence of `["role", role, member]` means `member` holds `role` (like Mantle's AccessControl).
#[account]
#[derive(InitSpace)]
pub struct RoleEntry {
    pub role: Role,
    pub member: Pubkey,
    pub bump: u8,
}

/// A mint the program has validated and is allowed to operate on.
#[account]
#[derive(InitSpace)]
pub struct MintState {
    pub mint: Pubkey,
    /// The Mantle `ScaledToken` this mint mirrors.
    pub mantle_token: [u8; 20],
    pub bump: u8,
}

/// `["mantle_token", mantle_token]`: the mint registered for a Mantle token. Its existence is what
/// stops a second mint from being registered for the same token.
#[account]
#[derive(InitSpace)]
pub struct MantleTokenIndex {
    pub mint: Pubkey,
    pub bump: u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug, InitSpace)]
pub enum Role {
    /// Schedules multiplier changes (Mantle `MULTIPLIER_SCHEDULER_ROLE`).
    MultiplierScheduler,
    /// Pauses mints (Mantle `PAUSE_ROLE`).
    Pauser,
    /// Resumes mints (Mantle `UNPAUSE_ROLE`).
    Unpauser,
    /// Freezes token accounts of blacklisted wallets — compliance backend KMS.
    Freezer,
    /// Thaws token accounts once a wallet leaves the blacklist — the same backend KMS by default,
    /// like the Mantle `ComplianceRegistry` OPS role, which both sanctions and unsanctions.
    Unfreezer,
    /// Moves tokens out of an account via the permanent delegate — multisig.
    Clawback,
    /// Updates name / symbol / ISIN metadata.
    MetadataOps,
    /// Registers new mints — operations KMS, like the `OPS_ROLE` that deploys tokens through
    /// Mantle's `ScaledTokenFactory`. Appended last: a role's seed is its index, so existing
    /// role accounts keep their addresses.
    MintRegistrar,
}

impl Role {
    pub fn seed(self) -> [u8; 1] {
        [self as u8]
    }

    /// Pause, freeze and clawback roles, governed by the compliance admin (Mantle's compliance and
    /// pause registries); the rest are token roles, governed by the admin.
    pub fn is_compliance(self) -> bool {
        matches!(self, Role::Pauser | Role::Unpauser | Role::Freezer | Role::Unfreezer | Role::Clawback)
    }
}
