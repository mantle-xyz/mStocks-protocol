//! Integration tests for mstocks-core, run against the mainnet Token-2022 program in LiteSVM.
//!
//! Prerequisites: `cargo build-sbf` (produces target/deploy/mstocks_core.so) and
//! `scripts/fetch-fixtures.sh` (produces tests/fixtures/token2022.so).

use anchor_lang::{prelude::Pubkey, AccountDeserialize, InstructionData, ToAccountMetas};
use anchor_lang::solana_program::instruction::Instruction;
use litesvm::LiteSVM;
use mstocks_core::{
    instructions::MetadataField,
    state::{Config, Role, AUTHORITY_SEED, CONFIG_SEED, MINT_SEED, ROLE_SEED},
};
use solana_clock::Clock;
use solana_keypair::Keypair;
use solana_signer::Signer;
use solana_transaction::Transaction;
use spl_token_2022_interface::{
    extension::{
        default_account_state, metadata_pointer, pausable, scaled_ui_amount, transfer_hook, BaseStateWithExtensions,
        ExtensionType, StateWithExtensions,
    },
    instruction as token_ix,
    state::{Account as TokenAccount, AccountState, Mint},
    ID as TOKEN_2022,
};

const NOW: i64 = 1_800_000_000;
const ONE: u128 = 1_000_000_000_000_000_000;
const MANTLE_TOKEN: [u8; 20] = [7u8; 20];

fn program_so() -> String {
    format!("{}/../../target/deploy/mstocks_core.so", env!("CARGO_MANIFEST_DIR"))
}

fn token2022_so() -> String {
    format!("{}/../../tests/fixtures/token2022.so", env!("CARGO_MANIFEST_DIR"))
}

fn pda(seeds: &[&[u8]]) -> Pubkey {
    Pubkey::find_program_address(seeds, &mstocks_core::ID).0
}

fn role_pda(role: Role, member: &Pubkey) -> Pubkey {
    pda(&[ROLE_SEED, &role.seed(), member.as_ref()])
}

struct Env {
    svm: LiteSVM,
    payer: Keypair,
    admin: Keypair,
    hook_admin: Keypair,
    config: Pubkey,
    authority: Pubkey,
}

impl Env {
    /// Loads both programs, makes `payer` the Core upgrade authority and initializes Core.
    fn new() -> Self {
        let mut env = Self::bare();
        let (admin, hook) = (env.admin.pubkey(), env.hook_admin.pubkey());
        env.initialize(&env.payer.insecure_clone(), admin, hook).expect("initialize");
        env
    }

    fn bare() -> Self {
        let mut svm = LiteSVM::new();
        svm.add_program_from_file(TOKEN_2022, token2022_so()).expect("token2022 fixture missing: run scripts/fetch-fixtures.sh");
        svm.add_program_from_file(mstocks_core::ID, program_so()).expect("program missing: run cargo build-sbf");
        let mut clock: Clock = svm.get_sysvar();
        clock.unix_timestamp = NOW;
        svm.set_sysvar(&clock);

        let payer = Keypair::new();
        svm.airdrop(&payer.pubkey(), 100_000_000_000).unwrap();
        set_upgrade_authority(&mut svm, &payer.pubkey());
        Self {
            svm,
            payer,
            admin: Keypair::new(),
            hook_admin: Keypair::new(),
            config: pda(&[CONFIG_SEED]),
            authority: pda(&[AUTHORITY_SEED]),
        }
    }

    fn send(&mut self, ixs: &[Instruction], signers: &[&Keypair]) -> Result<litesvm::types::TransactionMetadata, String> {
        self.svm.expire_blockhash();
        let mut all: Vec<&Keypair> = vec![&self.payer];
        all.extend_from_slice(signers);
        let tx = Transaction::new_signed_with_payer(ixs, Some(&self.payer.pubkey()), &all, self.svm.latest_blockhash());
        self.svm.send_transaction(tx).map_err(|e| format!("{:?}\n{}", e.err, e.meta.logs.join("\n")))
    }

    fn core_ix(&self, accounts: impl ToAccountMetas, data: impl InstructionData, remaining: Vec<anchor_lang::solana_program::instruction::AccountMeta>) -> Instruction {
        let mut metas = accounts.to_account_metas(None);
        metas.extend(remaining);
        Instruction { program_id: mstocks_core::ID, accounts: metas, data: data.data() }
    }

    fn initialize(&mut self, signer: &Keypair, admin: Pubkey, hook_authority: Pubkey) -> Result<(), String> {
        let program_data = Pubkey::find_program_address(&[mstocks_core::ID.as_ref()], &bpf_loader_upgradeable()).0;
        let ix = self.core_ix(
            mstocks_core::accounts::Initialize {
                payer: signer.pubkey(),
                config: self.config,
                authority: self.authority,
                program: mstocks_core::ID,
                program_data,
                system_program: system_program(),
            },
            mstocks_core::instruction::Initialize { admin, hook_authority },
            vec![],
        );
        self.svm.airdrop(&signer.pubkey(), 10_000_000_000).unwrap();
        self.svm.expire_blockhash();
        let tx = Transaction::new_signed_with_payer(&[ix], Some(&signer.pubkey()), &[signer], self.svm.latest_blockhash());
        self.svm.send_transaction(tx).map(|_| ()).map_err(|e| format!("{:?}", e.err))
    }

    fn grant(&mut self, role: Role, member: &Pubkey) -> Result<(), String> {
        let admin = self.admin.insecure_clone();
        self.grant_as(&admin, role, member)
    }

    fn grant_as(&mut self, admin: &Keypair, role: Role, member: &Pubkey) -> Result<(), String> {
        let ix = self.core_ix(
            mstocks_core::accounts::GrantRole {
                payer: self.payer.pubkey(),
                admin: admin.pubkey(),
                config: self.config,
                role_entry: role_pda(role, member),
                system_program: system_program(),
            },
            mstocks_core::instruction::GrantRole { role, member: *member },
            vec![],
        );
        self.send(&[ix], &[admin]).map(|_| ())
    }

    /// Creates a funded keypair holding `role`.
    fn operator(&mut self, role: Role) -> Keypair {
        let kp = Keypair::new();
        self.svm.airdrop(&kp.pubkey(), 1_000_000_000).unwrap();
        self.grant(role, &kp.pubkey()).expect("grant");
        kp
    }

    fn create_mint(&mut self, opts: MintOpts) -> TestMint {
        let mint = Keypair::new();
        let mint_authority = Keypair::new();
        let mut exts = vec![
            ExtensionType::ScaledUiAmount,
            ExtensionType::Pausable,
            ExtensionType::MetadataPointer,
            ExtensionType::DefaultAccountState,
            ExtensionType::TransferHook,
            ExtensionType::PermanentDelegate,
        ];
        if opts.close_authority {
            exts.push(ExtensionType::MintCloseAuthority);
        }
        let space = ExtensionType::try_calculate_account_len::<Mint>(&exts).unwrap();
        // Extra rent for the variable-length token metadata written after InitializeMint2.
        let lamports = self.svm.minimum_balance_for_rent_exemption(space + 512);
        let auth = self.authority;
        let hook_authority = opts.hook_authority.unwrap_or(self.hook_admin.pubkey());
        let freeze = opts.freeze_authority.unwrap_or(auth);
        let mint_auth = if opts.mint_authority_is_core { auth } else { mint_authority.pubkey() };
        let m = mint.pubkey();
        let mut ixs = vec![
            create_account(&self.payer.pubkey(), &m, lamports, space as u64, &TOKEN_2022),
            scaled_ui_amount::instruction::initialize(&TOKEN_2022, &m, Some(auth), 1.0).unwrap(),
            pausable::instruction::initialize(&TOKEN_2022, &m, &auth).unwrap(),
            metadata_pointer::instruction::initialize(&TOKEN_2022, &m, Some(opts.pointer_authority.unwrap_or(auth)), Some(m)).unwrap(),
            default_account_state::instruction::initialize_default_account_state(&TOKEN_2022, &m, &AccountState::Initialized).unwrap(),
            transfer_hook::instruction::initialize(&TOKEN_2022, &m, Some(hook_authority), opts.hook_program).unwrap(),
            token_ix::initialize_permanent_delegate(&TOKEN_2022, &m, &auth).unwrap(),
        ];
        if opts.close_authority {
            ixs.push(token_ix::initialize_mint_close_authority(&TOKEN_2022, &m, Some(&Pubkey::new_unique())).unwrap());
        }
        ixs.extend([
            token_ix::initialize_mint2(&TOKEN_2022, &m, &mint_authority.pubkey(), Some(&freeze), opts.decimals).unwrap(),
            spl_token_metadata_interface::instruction::initialize(
                &TOKEN_2022, &m, &auth, &m, &mint_authority.pubkey(), "Apple mStock".into(), "AAPLm".into(), "https://example.com".into(),
            ),
        ]);
        if mint_auth != mint_authority.pubkey() {
            ixs.push(
                token_ix::set_authority(&TOKEN_2022, &m, Some(&mint_auth), token_ix::AuthorityType::MintTokens, &mint_authority.pubkey(), &[]).unwrap(),
            );
        }
        self.send(&ixs, &[&mint, &mint_authority]).expect("create mint");
        TestMint { mint: m, mint_authority }
    }

    fn register(&mut self, mint: &Pubkey) -> Result<(), String> {
        let admin = self.admin.insecure_clone();
        let ix = self.core_ix(
            mstocks_core::accounts::RegisterMint {
                payer: self.payer.pubkey(),
                admin: admin.pubkey(),
                config: self.config,
                mint: *mint,
                mint_state: pda(&[MINT_SEED, mint.as_ref()]),
                authority: self.authority,
                system_program: system_program(),
            },
            mstocks_core::instruction::RegisterMint { mantle_token: MANTLE_TOKEN },
            vec![],
        );
        self.send(&[ix], &[&admin]).map(|_| ())
    }

    /// A registered mint configured exactly as the design requires.
    fn registered_mint(&mut self) -> TestMint {
        let m = self.create_mint(MintOpts::valid());
        self.register(&m.mint).expect("register");
        m
    }

    /// Creates a (non-ATA) token account for `owner`, sized for the mint's required account extensions.
    fn token_account(&mut self, mint: &Pubkey, owner: &Pubkey) -> Pubkey {
        let account = Keypair::new();
        let mint_data = self.svm.get_account(mint).unwrap().data;
        let mint_exts = StateWithExtensions::<Mint>::unpack(&mint_data).unwrap().get_extension_types().unwrap();
        let needed = ExtensionType::get_required_init_account_extensions(&mint_exts);
        let space = ExtensionType::try_calculate_account_len::<TokenAccount>(&needed).unwrap();
        let ixs = [
            create_account(&self.payer.pubkey(), &account.pubkey(), self.svm.minimum_balance_for_rent_exemption(space), space as u64, &TOKEN_2022),
            token_ix::initialize_account3(&TOKEN_2022, &account.pubkey(), mint, owner).unwrap(),
        ];
        self.send(&ixs, &[&account]).expect("token account");
        account.pubkey()
    }

    fn mint_to(&mut self, m: &TestMint, account: &Pubkey, amount: u64) -> Result<(), String> {
        let ix = token_ix::mint_to_checked(&TOKEN_2022, &m.mint, account, &m.mint_authority.pubkey(), &[], amount, 9).unwrap();
        let ma = m.mint_authority.insecure_clone();
        self.send(&[ix], &[&ma]).map(|_| ())
    }

    /// Plain 4-account transfer_checked — the same shape CCIP Router uses.
    fn transfer(&mut self, mint: &Pubkey, from: &Pubkey, owner: &Keypair, to: &Pubkey, amount: u64) -> Result<(), String> {
        let ix = token_ix::transfer_checked(&TOKEN_2022, from, mint, to, &owner.pubkey(), &[], amount, 9).unwrap();
        self.send(&[ix], &[owner]).map(|_| ())
    }

    fn token(&self, account: &Pubkey) -> (u64, AccountState) {
        let data = self.svm.get_account(account).unwrap().data;
        let t = StateWithExtensions::<TokenAccount>::unpack(&data).unwrap();
        (t.base.amount, t.base.state)
    }

    /// UI amount Token-2022 itself reports for `amount` at time `ts`.
    fn ui_amount(&mut self, mint: &Pubkey, amount: u64, ts: i64) -> String {
        self.set_time(ts);
        let ix = token_ix::amount_to_ui_amount(&TOKEN_2022, mint, amount).unwrap();
        let meta = self.send(&[ix], &[]).expect("amount_to_ui_amount");
        String::from_utf8(meta.return_data.data).unwrap()
    }

    fn set_time(&mut self, ts: i64) {
        let mut clock: Clock = self.svm.get_sysvar();
        clock.unix_timestamp = ts;
        self.svm.set_sysvar(&clock);
    }

    fn schedule(&mut self, op: &Keypair, mint: &Pubkey, multiplier_1e18: u128, effective_at: i64) -> Result<(), String> {
        let ix = self.core_ix(
            mstocks_core::accounts::ScheduleMultiplier {
                operator: op.pubkey(),
                config: self.config,
                role_entry: role_pda(Role::MultiplierScheduler, &op.pubkey()),
                mint: *mint,
                mint_state: pda(&[MINT_SEED, mint.as_ref()]),
                authority: self.authority,
                token_program: TOKEN_2022,
            },
            mstocks_core::instruction::ScheduleMultiplier { multiplier_1e18, effective_at },
            vec![],
        );
        self.send(&[ix], &[op]).map(|_| ())
    }

    fn set_paused(&mut self, op: &Keypair, mint: &Pubkey, paused: bool) -> Result<(), String> {
        let role = if paused { Role::Pauser } else { Role::Unpauser };
        let ix = if paused {
            self.core_ix(
                mstocks_core::accounts::Pause {
                    operator: op.pubkey(),
                    config: self.config,
                    role_entry: role_pda(role, &op.pubkey()),
                    mint: *mint,
                    mint_state: pda(&[MINT_SEED, mint.as_ref()]),
                    authority: self.authority,
                    token_program: TOKEN_2022,
                },
                mstocks_core::instruction::Pause {},
                vec![],
            )
        } else {
            self.core_ix(
                mstocks_core::accounts::Resume {
                    operator: op.pubkey(),
                    config: self.config,
                    role_entry: role_pda(role, &op.pubkey()),
                    mint: *mint,
                    mint_state: pda(&[MINT_SEED, mint.as_ref()]),
                    authority: self.authority,
                    token_program: TOKEN_2022,
                },
                mstocks_core::instruction::Resume {},
                vec![],
            )
        };
        self.send(&[ix], &[op]).map(|_| ())
    }

    fn set_frozen(&mut self, op: &Keypair, mint: &Pubkey, accounts: &[Pubkey], frozen: bool) -> Result<(), String> {
        let role = if frozen { Role::Freezer } else { Role::Unfreezer };
        let remaining = accounts.iter().map(|a| anchor_lang::solana_program::instruction::AccountMeta::new(*a, false)).collect();
        let (config, authority) = (self.config, self.authority);
        let mint_state = pda(&[MINT_SEED, mint.as_ref()]);
        let role_entry = role_pda(role, &op.pubkey());
        let ix = if frozen {
            self.core_ix(
                mstocks_core::accounts::Freeze { operator: op.pubkey(), config, role_entry, mint: *mint, mint_state, authority, token_program: TOKEN_2022 },
                mstocks_core::instruction::Freeze {},
                remaining,
            )
        } else {
            self.core_ix(
                mstocks_core::accounts::Thaw { operator: op.pubkey(), config, role_entry, mint: *mint, mint_state, authority, token_program: TOKEN_2022 },
                mstocks_core::instruction::Thaw {},
                remaining,
            )
        };
        self.send(&[ix], &[op]).map(|_| ())
    }

    fn config(&self) -> Config {
        let data = self.svm.get_account(&self.config).unwrap().data;
        Config::try_deserialize(&mut &data[..]).unwrap()
    }
}

#[derive(Default)]
struct MintOpts {
    decimals: u8,
    freeze_authority: Option<Pubkey>,
    hook_authority: Option<Pubkey>,
    hook_program: Option<Pubkey>,
    mint_authority_is_core: bool,
    pointer_authority: Option<Pubkey>,
    close_authority: bool,
}

impl MintOpts {
    fn valid() -> Self {
        Self { decimals: 9, ..Default::default() }
    }
}

struct TestMint {
    mint: Pubkey,
    mint_authority: Keypair,
}

fn system_program() -> Pubkey {
    Pubkey::default()
}

fn bpf_loader_upgradeable() -> Pubkey {
    "BPFLoaderUpgradeab1e11111111111111111111111".parse().unwrap()
}

fn create_account(from: &Pubkey, to: &Pubkey, lamports: u64, space: u64, owner: &Pubkey) -> Instruction {
    // System program CreateAccount: discriminator 0, lamports, space, owner.
    let mut data = vec![0u8, 0, 0, 0];
    data.extend_from_slice(&lamports.to_le_bytes());
    data.extend_from_slice(&space.to_le_bytes());
    data.extend_from_slice(owner.as_ref());
    Instruction {
        program_id: system_program(),
        accounts: vec![
            anchor_lang::solana_program::instruction::AccountMeta::new(*from, true),
            anchor_lang::solana_program::instruction::AccountMeta::new(*to, true),
        ],
        data,
    }
}

/// LiteSVM deploys with no upgrade authority; patch the ProgramData header
/// (`u32 tag=3 | u64 slot | u8 Some | [u8; 32] authority`) so `initialize`'s check can pass.
fn set_upgrade_authority(svm: &mut LiteSVM, authority: &Pubkey) {
    let program_data = Pubkey::find_program_address(&[mstocks_core::ID.as_ref()], &bpf_loader_upgradeable()).0;
    let mut account = svm.get_account(&program_data).unwrap();
    account.data[12] = 1;
    account.data[13..45].copy_from_slice(authority.as_ref());
    svm.set_account(program_data, account).unwrap();
}

fn assert_err(result: Result<(), String>, needle: &str) {
    match result {
        Ok(()) => panic!("expected failure containing {needle:?}, got success"),
        Err(e) => assert!(e.contains(needle), "expected {needle:?} in error:\n{e}"),
    }
}

// ---------------------------------------------------------------------------------------------
// initialize / roles
// ---------------------------------------------------------------------------------------------

#[test]
fn initialize_requires_upgrade_authority_and_runs_once() {
    let mut env = Env::bare();
    let stranger = Keypair::new();
    let (admin, hook) = (env.admin.pubkey(), env.hook_admin.pubkey());
    assert!(env.initialize(&stranger, admin, hook).is_err(), "non-upgrade-authority must not initialize");
    let payer = env.payer.insecure_clone();
    env.initialize(&payer, admin, hook).unwrap();
    assert!(env.initialize(&payer, admin, hook).is_err(), "second initialize must fail");
    let config = env.config();
    assert_eq!(config.admin, admin);
    assert_eq!(config.hook_authority, hook);
    assert_eq!(config.min_notice, 300);
}

#[test]
fn roles_follow_mantle_guards() {
    let mut env = Env::new();
    let admin = env.admin.pubkey();
    assert_err(env.grant(Role::Pauser, &admin), "SelfGrantNotAllowed");

    let not_admin = Keypair::new();
    assert!(env.grant_as(&not_admin, Role::Pauser, &Pubkey::new_unique()).is_err());

    // An admin without a role entry is rejected when the role account fails to load.
    let m = env.registered_mint();
    let admin_kp = env.admin.insecure_clone();
    assert!(env.schedule(&admin_kp, &m.mint, 2 * ONE, NOW + 3600).is_err());

    // A scheduler that later becomes admin keeps its role entry, but the signer guard still stops it.
    let scheduler = env.operator(Role::MultiplierScheduler);
    env.schedule(&scheduler, &m.mint, 2 * ONE, NOW + 3600).unwrap();
    let propose = env.core_ix(
        mstocks_core::accounts::AdminOnly { admin: admin_kp.pubkey(), config: env.config },
        mstocks_core::instruction::ProposeAdmin { new_admin: scheduler.pubkey() },
        vec![],
    );
    env.send(&[propose], &[&admin_kp]).unwrap();
    let accept = env.core_ix(
        mstocks_core::accounts::AcceptAdmin { new_admin: scheduler.pubkey(), config: env.config },
        mstocks_core::instruction::AcceptAdmin {},
        vec![],
    );
    env.send(&[accept], &[&scheduler]).unwrap();
    assert_err(env.schedule(&scheduler, &m.mint, 3 * ONE, NOW + 3600), "AdminCannotOperate");
}

#[test]
fn admin_handover_is_two_step() {
    let mut env = Env::new();
    let new_admin = Keypair::new();
    let admin = env.admin.insecure_clone();
    let propose = env.core_ix(
        mstocks_core::accounts::AdminOnly { admin: admin.pubkey(), config: env.config },
        mstocks_core::instruction::ProposeAdmin { new_admin: new_admin.pubkey() },
        vec![],
    );
    env.send(&[propose], &[&admin]).unwrap();
    assert_eq!(env.config().admin, admin.pubkey(), "admin unchanged until accepted");

    let accept = env.core_ix(
        mstocks_core::accounts::AcceptAdmin { new_admin: new_admin.pubkey(), config: env.config },
        mstocks_core::instruction::AcceptAdmin {},
        vec![],
    );
    env.send(&[accept], &[&new_admin]).unwrap();
    assert_eq!(env.config().admin, new_admin.pubkey());
    assert_eq!(env.config().pending_admin, None);
}

// ---------------------------------------------------------------------------------------------
// register_mint
// ---------------------------------------------------------------------------------------------

#[test]
fn register_mint_accepts_designed_configuration() {
    let mut env = Env::new();
    env.registered_mint();
}

#[test]
fn register_mint_rejects_each_misconfiguration() {
    let cases: Vec<(MintOpts, &str)> = vec![
        (MintOpts { decimals: 18, ..MintOpts::valid() }, "WrongDecimals"),
        (MintOpts { freeze_authority: Some(Pubkey::new_unique()), ..MintOpts::valid() }, "WrongFreezeAuthority"),
        (MintOpts { hook_program: Some(Pubkey::new_unique()), ..MintOpts::valid() }, "WrongTransferHook"),
        (MintOpts { hook_authority: Some(Pubkey::new_unique()), ..MintOpts::valid() }, "WrongTransferHook"),
        (MintOpts { mint_authority_is_core: true, ..MintOpts::valid() }, "MintAuthorityIsCore"),
        (MintOpts { pointer_authority: Some(Pubkey::new_unique()), ..MintOpts::valid() }, "WrongMetadataPointer"),
        (MintOpts { close_authority: true, ..MintOpts::valid() }, "UnexpectedExtension"),
    ];
    for (opts, expected) in cases {
        let mut env = Env::new();
        let m = env.create_mint(opts);
        assert_err(env.register(&m.mint), expected);
    }
}

// ---------------------------------------------------------------------------------------------
// multiplier (plan B)
// ---------------------------------------------------------------------------------------------

#[test]
fn schedule_multiplier_enforces_mantle_rules() {
    let mut env = Env::new();
    let m = env.registered_mint();
    let op = env.operator(Role::MultiplierScheduler);

    assert_err(env.schedule(&op, &m.mint, 1_000_000_000 - 1, NOW + 3600), "MultiplierOutOfRange");
    assert_err(env.schedule(&op, &m.mint, 1_000_000_000 * ONE + 1, NOW + 3600), "MultiplierOutOfRange");
    assert_err(env.schedule(&op, &m.mint, 2 * ONE, NOW + 299), "NoticeTooShort");
    assert_err(env.schedule(&op, &m.mint, 2 * ONE, NOW - 10), "NoticeTooShort");
    assert_err(env.schedule(&op, &m.mint, 2 * ONE, NOW + 365 * 86_400 + 1), "EffectiveTooFar");

    let stranger = Keypair::new();
    env.svm.airdrop(&stranger.pubkey(), 1_000_000_000).unwrap();
    assert!(env.schedule(&stranger, &m.mint, 2 * ONE, NOW + 3600).is_err(), "no role, no schedule");

    env.schedule(&op, &m.mint, 2 * ONE, NOW + 300).unwrap();
    assert_eq!(env.ui_amount(&m.mint, 100_000_000_000, NOW + 299), "100");
    assert_eq!(env.ui_amount(&m.mint, 100_000_000_000, NOW + 300), "200");
}

#[test]
fn rescheduling_overwrites_pending_value() {
    let mut env = Env::new();
    let m = env.registered_mint();
    let op = env.operator(Role::MultiplierScheduler);
    env.schedule(&op, &m.mint, 2 * ONE, NOW + 1000).unwrap();
    env.set_time(NOW);
    env.schedule(&op, &m.mint, 5 * ONE / 2, NOW + 2000).unwrap();
    assert_eq!(env.ui_amount(&m.mint, 100_000_000_000, NOW + 1000), "100");
    assert_eq!(env.ui_amount(&m.mint, 100_000_000_000, NOW + 2000), "250");
}

// ---------------------------------------------------------------------------------------------
// pause
// ---------------------------------------------------------------------------------------------

#[test]
fn pause_and_resume_need_separate_roles() {
    let mut env = Env::new();
    let m = env.registered_mint();
    let alice = Keypair::new();
    let bob = Pubkey::new_unique();
    let (a, b) = (env.token_account(&m.mint, &alice.pubkey()), env.token_account(&m.mint, &bob));
    env.mint_to(&m, &a, 1_000).unwrap();

    let pauser = env.operator(Role::Pauser);
    let unpauser = env.operator(Role::Unpauser);
    assert!(env.set_paused(&unpauser, &m.mint, true).is_err(), "unpauser cannot pause");
    env.set_paused(&pauser, &m.mint, true).unwrap();
    assert!(env.transfer(&m.mint, &a, &alice, &b, 1).is_err(), "transfer blocked while paused");
    assert!(env.mint_to(&m, &a, 1).is_err(), "mint (CCIP inbound) blocked while paused");
    assert!(env.set_paused(&pauser, &m.mint, false).is_err(), "pauser cannot resume");
    env.set_paused(&unpauser, &m.mint, false).unwrap();
    env.transfer(&m.mint, &a, &alice, &b, 1).unwrap();
}

// ---------------------------------------------------------------------------------------------
// compliance: freeze / thaw / clawback
// ---------------------------------------------------------------------------------------------

#[test]
fn freezer_freezes_batch_and_only_unfreezer_thaws() {
    let mut env = Env::new();
    let m = env.registered_mint();
    let (blocked, alice) = (Keypair::new(), Keypair::new());
    let blocked_a = env.token_account(&m.mint, &blocked.pubkey());
    let blocked_b = env.token_account(&m.mint, &blocked.pubkey());
    let alice_a = env.token_account(&m.mint, &alice.pubkey());
    env.mint_to(&m, &blocked_a, 1_000).unwrap();
    env.mint_to(&m, &alice_a, 1_000).unwrap();

    let freezer = env.operator(Role::Freezer);
    let unfreezer = env.operator(Role::Unfreezer);
    env.set_frozen(&freezer, &m.mint, &[blocked_a, blocked_b], true).unwrap();
    assert_eq!(env.token(&blocked_a).1, AccountState::Frozen);
    assert_eq!(env.token(&blocked_b).1, AccountState::Frozen);
    // Resending the same batch is a no-op rather than an error.
    env.set_frozen(&freezer, &m.mint, &[blocked_a, blocked_b], true).unwrap();

    assert!(env.transfer(&m.mint, &blocked_a, &blocked, &alice_a, 1).is_err(), "frozen cannot send");
    assert!(env.transfer(&m.mint, &alice_a, &alice, &blocked_a, 1).is_err(), "frozen cannot receive");
    assert!(env.mint_to(&m, &blocked_a, 1).is_err(), "frozen cannot receive CCIP mint");

    assert!(env.set_frozen(&freezer, &m.mint, &[blocked_a], false).is_err(), "freezer cannot thaw");
    env.set_frozen(&unfreezer, &m.mint, &[blocked_a], false).unwrap();
    assert_eq!(env.token(&blocked_a).1, AccountState::Initialized);
}

#[test]
fn freeze_rejects_accounts_of_another_mint() {
    let mut env = Env::new();
    let m1 = env.registered_mint();
    let m2 = env.registered_mint();
    let other = env.token_account(&m2.mint, &Pubkey::new_unique());
    let freezer = env.operator(Role::Freezer);
    assert_err(env.set_frozen(&freezer, &m1.mint, &[other], true), "MintMismatch");
}

#[test]
fn clawback_moves_frozen_balance_to_custody_and_refreezes() {
    let mut env = Env::new();
    let m = env.registered_mint();
    let blocked = Keypair::new();
    let source = env.token_account(&m.mint, &blocked.pubkey());
    let custody = env.token_account(&m.mint, &Pubkey::new_unique());
    env.mint_to(&m, &source, 1_000).unwrap();
    let freezer = env.operator(Role::Freezer);
    env.set_frozen(&freezer, &m.mint, &[source], true).unwrap();

    let clawer = env.operator(Role::Clawback);
    let ix = env.core_ix(
        mstocks_core::accounts::Clawback {
            operator: clawer.pubkey(),
            config: env.config,
            role_entry: role_pda(Role::Clawback, &clawer.pubkey()),
            mint: m.mint,
            mint_state: pda(&[MINT_SEED, m.mint.as_ref()]),
            source,
            destination: custody,
            authority: env.authority,
            token_program: TOKEN_2022,
        },
        mstocks_core::instruction::Clawback { amount: 1_000 },
        vec![],
    );
    env.send(&[ix], &[&clawer]).unwrap();
    assert_eq!(env.token(&source), (0, AccountState::Frozen));
    assert_eq!(env.token(&custody).0, 1_000);
}

// ---------------------------------------------------------------------------------------------
// metadata / CCIP compatibility
// ---------------------------------------------------------------------------------------------

#[test]
fn metadata_ops_updates_name() {
    let mut env = Env::new();
    let m = env.registered_mint();
    let op = env.operator(Role::MetadataOps);
    let ix = env.core_ix(
        mstocks_core::accounts::UpdateMetadata {
            operator: op.pubkey(),
            config: env.config,
            role_entry: role_pda(Role::MetadataOps, &op.pubkey()),
            mint: m.mint,
            mint_state: pda(&[MINT_SEED, m.mint.as_ref()]),
            authority: env.authority,
            token_program: TOKEN_2022,
        },
        mstocks_core::instruction::UpdateMetadata { field: MetadataField::Name, value: "Apple Inc mStock".into() },
        vec![],
    );
    env.send(&[ix], &[&op]).unwrap();
    let data = env.svm.get_account(&m.mint).unwrap().data;
    let state = StateWithExtensions::<Mint>::unpack(&data).unwrap();
    let md = state.get_variable_len_extension::<spl_token_metadata_interface::state::TokenMetadata>().unwrap();
    assert_eq!(md.name, "Apple Inc mStock");
}

#[test]
fn dormant_hook_keeps_ccip_style_transfers_working() {
    let mut env = Env::new();
    let m = env.registered_mint();
    let alice = Keypair::new();
    let a = env.token_account(&m.mint, &alice.pubkey());
    let pool = env.token_account(&m.mint, &Pubkey::new_unique());
    env.mint_to(&m, &a, 1_000).unwrap();
    env.transfer(&m.mint, &a, &alice, &pool, 400).unwrap();
    assert_eq!(env.token(&pool).0, 400);
}

#[test]
fn pause_all_pauses_every_given_mint() {
    let mut env = Env::new();
    let m1 = env.registered_mint();
    let m2 = env.registered_mint();
    let pauser = env.operator(Role::Pauser);
    let remaining = [m1.mint, m2.mint]
        .iter()
        .flat_map(|m| {
            [
                anchor_lang::solana_program::instruction::AccountMeta::new(*m, false),
                anchor_lang::solana_program::instruction::AccountMeta::new_readonly(pda(&[MINT_SEED, m.as_ref()]), false),
            ]
        })
        .collect();
    let ix = env.core_ix(
        mstocks_core::accounts::PauseAll {
            operator: pauser.pubkey(),
            config: env.config,
            role_entry: role_pda(Role::Pauser, &pauser.pubkey()),
            authority: env.authority,
            token_program: TOKEN_2022,
        },
        mstocks_core::instruction::PauseAll {},
        remaining,
    );
    env.send(&[ix], &[&pauser]).unwrap();
    for m in [&m1, &m2] {
        let a = env.token_account(&m.mint, &Pubkey::new_unique());
        assert!(env.mint_to(m, &a, 1).is_err(), "every listed mint is paused");
    }
}

#[test]
fn revoked_and_renounced_roles_stop_working() {
    let mut env = Env::new();
    let m = env.registered_mint();

    let revoked = env.operator(Role::MultiplierScheduler);
    let admin = env.admin.insecure_clone();
    let revoke = env.core_ix(
        mstocks_core::accounts::RevokeRole {
            admin: admin.pubkey(),
            config: env.config,
            role_entry: role_pda(Role::MultiplierScheduler, &revoked.pubkey()),
        },
        mstocks_core::instruction::RevokeRole { role: Role::MultiplierScheduler, member: revoked.pubkey() },
        vec![],
    );
    env.send(&[revoke], &[&admin]).unwrap();
    assert!(env.schedule(&revoked, &m.mint, 2 * ONE, NOW + 3600).is_err(), "revoked role must not schedule");

    let renouncer = env.operator(Role::MultiplierScheduler);
    let renounce = env.core_ix(
        mstocks_core::accounts::RenounceRole {
            member: renouncer.pubkey(),
            role_entry: role_pda(Role::MultiplierScheduler, &renouncer.pubkey()),
        },
        mstocks_core::instruction::RenounceRole { role: Role::MultiplierScheduler },
        vec![],
    );
    env.send(&[renounce], &[&renouncer]).unwrap();
    assert!(env.schedule(&renouncer, &m.mint, 2 * ONE, NOW + 3600).is_err(), "renounced role must not schedule");
}

#[test]
fn a_mint_registers_only_once() {
    let mut env = Env::new();
    let m = env.registered_mint();
    assert!(env.register(&m.mint).is_err());
}

#[test]
fn pause_all_rejects_unpaired_remaining_accounts() {
    let mut env = Env::new();
    let m = env.registered_mint();
    let pauser = env.operator(Role::Pauser);
    let ix = env.core_ix(
        mstocks_core::accounts::PauseAll {
            operator: pauser.pubkey(),
            config: env.config,
            role_entry: role_pda(Role::Pauser, &pauser.pubkey()),
            authority: env.authority,
            token_program: TOKEN_2022,
        },
        mstocks_core::instruction::PauseAll {},
        vec![anchor_lang::solana_program::instruction::AccountMeta::new(m.mint, false)],
    );
    assert_err(env.send(&[ix], &[&pauser]).map(|_| ()), "BadRemainingAccounts");
}

#[test]
fn clawback_from_unfrozen_account_still_ends_frozen() {
    let mut env = Env::new();
    let m = env.registered_mint();
    let source = env.token_account(&m.mint, &Pubkey::new_unique());
    let custody = env.token_account(&m.mint, &Pubkey::new_unique());
    env.mint_to(&m, &source, 500).unwrap();
    let clawer = env.operator(Role::Clawback);
    let ix = env.core_ix(
        mstocks_core::accounts::Clawback {
            operator: clawer.pubkey(),
            config: env.config,
            role_entry: role_pda(Role::Clawback, &clawer.pubkey()),
            mint: m.mint,
            mint_state: pda(&[MINT_SEED, m.mint.as_ref()]),
            source,
            destination: custody,
            authority: env.authority,
            token_program: TOKEN_2022,
        },
        mstocks_core::instruction::Clawback { amount: 200 },
        vec![],
    );
    env.send(&[ix], &[&clawer]).unwrap();
    assert_eq!(env.token(&source), (300, AccountState::Frozen));
    assert_eq!(env.token(&custody).0, 200);
}

/// Batch sizes used by the scripts must fit the default 200k CU budget and the 1232-byte packet.
#[test]
fn batch_operations_fit_transaction_limits() {
    let mut env = Env::new();
    let m = env.registered_mint();
    let accounts: Vec<Pubkey> = (0..20).map(|_| env.token_account(&m.mint, &Pubkey::new_unique())).collect();
    let freezer = env.operator(Role::Freezer);
    let remaining = accounts.iter().map(|a| anchor_lang::solana_program::instruction::AccountMeta::new(*a, false)).collect();
    let ix = env.core_ix(
        mstocks_core::accounts::Freeze {
            operator: freezer.pubkey(),
            config: env.config,
            role_entry: role_pda(Role::Freezer, &freezer.pubkey()),
            mint: m.mint,
            mint_state: pda(&[MINT_SEED, m.mint.as_ref()]),
            authority: env.authority,
            token_program: TOKEN_2022,
        },
        mstocks_core::instruction::Freeze {},
        remaining,
    );
    let size = tx_size(&env, &[ix.clone()], &[&freezer]);
    let cu = env.send(&[ix], &[&freezer]).unwrap().compute_units_consumed;
    println!("freeze 20 accounts: {cu} CU, {size} bytes");
    assert!(cu < 200_000 && size <= 1232, "freeze batch of 20: {cu} CU, {size} bytes");

    let mints: Vec<Pubkey> = (0..8).map(|_| env.registered_mint().mint).collect();
    let pauser = env.operator(Role::Pauser);
    let remaining = mints
        .iter()
        .flat_map(|m| {
            [
                anchor_lang::solana_program::instruction::AccountMeta::new(*m, false),
                anchor_lang::solana_program::instruction::AccountMeta::new_readonly(pda(&[MINT_SEED, m.as_ref()]), false),
            ]
        })
        .collect();
    let ix = env.core_ix(
        mstocks_core::accounts::PauseAll {
            operator: pauser.pubkey(),
            config: env.config,
            role_entry: role_pda(Role::Pauser, &pauser.pubkey()),
            authority: env.authority,
            token_program: TOKEN_2022,
        },
        mstocks_core::instruction::PauseAll {},
        remaining,
    );
    let size = tx_size(&env, &[ix.clone()], &[&pauser]);
    let cu = env.send(&[ix], &[&pauser]).unwrap().compute_units_consumed;
    println!("pause_all 8 mints: {cu} CU, {size} bytes");
    assert!(cu < 200_000 && size <= 1232, "pause_all batch of 8: {cu} CU, {size} bytes");
}

fn tx_size(env: &Env, ixs: &[Instruction], signers: &[&Keypair]) -> usize {
    let mut all: Vec<&Keypair> = vec![&env.payer];
    all.extend_from_slice(signers);
    let tx = Transaction::new_signed_with_payer(ixs, Some(&env.payer.pubkey()), &all, env.svm.latest_blockhash());
    1 + 64 * tx.signatures.len() + tx.message.serialize().len()
}

#[test]
fn admin_switches_default_account_state() {
    let mut env = Env::new();
    let m = env.registered_mint();
    let set = |env: &Env, signer: &Keypair, frozen: bool| {
        env.core_ix(
            mstocks_core::accounts::SetDefaultAccountState {
                admin: signer.pubkey(),
                config: env.config,
                mint: m.mint,
                mint_state: pda(&[MINT_SEED, m.mint.as_ref()]),
                authority: env.authority,
                token_program: TOKEN_2022,
            },
            mstocks_core::instruction::SetDefaultAccountState { frozen },
            vec![],
        )
    };

    let stranger = env.operator(Role::Freezer);
    let ix = set(&env, &stranger, true);
    assert!(env.send(&[ix], &[&stranger]).is_err(), "only the admin switches the policy");

    let admin = env.admin.insecure_clone();
    let ix = set(&env, &admin, true);
    env.send(&[ix], &[&admin]).unwrap();
    let frozen_new = env.token_account(&m.mint, &Pubkey::new_unique());
    assert_eq!(env.token(&frozen_new).1, AccountState::Frozen, "new accounts start frozen");

    let ix = set(&env, &admin, false);
    env.send(&[ix], &[&admin]).unwrap();
    let usable_new = env.token_account(&m.mint, &Pubkey::new_unique());
    assert_eq!(env.token(&usable_new).1, AccountState::Initialized, "new accounts start usable again");
}
