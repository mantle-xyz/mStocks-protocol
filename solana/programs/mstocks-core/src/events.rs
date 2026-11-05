use anchor_lang::prelude::*;

use crate::state::Role;

#[event]
pub struct AdminProposed {
    pub current: Pubkey,
    pub proposed: Pubkey,
}

#[event]
pub struct AdminAccepted {
    pub previous: Pubkey,
    pub admin: Pubkey,
}

#[event]
pub struct RoleGranted {
    pub role: Role,
    pub member: Pubkey,
}

#[event]
pub struct RoleRevoked {
    pub role: Role,
    pub member: Pubkey,
}

#[event]
pub struct MintRegistered {
    pub mint: Pubkey,
    pub mantle_token: [u8; 20],
}

#[event]
pub struct MultiplierScheduled {
    pub mint: Pubkey,
    pub multiplier_1e18: u128,
    pub effective_at: i64,
}

#[event]
pub struct Paused {
    pub mint: Pubkey,
}

#[event]
pub struct Resumed {
    pub mint: Pubkey,
}

#[event]
pub struct Frozen {
    pub mint: Pubkey,
    pub account: Pubkey,
}

#[event]
pub struct Thawed {
    pub mint: Pubkey,
    pub account: Pubkey,
}

#[event]
pub struct ClawedBack {
    pub mint: Pubkey,
    pub source: Pubkey,
    pub destination: Pubkey,
    pub amount: u64,
}

#[event]
pub struct DefaultAccountStateSet {
    pub mint: Pubkey,
    pub frozen: bool,
}

#[event]
pub struct MetadataUpdated {
    pub mint: Pubkey,
    pub field: String,
    pub value: String,
}
