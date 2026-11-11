# mStocks Solana Core Program Design

> Status: reviewed (decisions in §10), first version implemented · 2026-11-05 · branch `feat/solana-core`
> Background and option analysis are in the Solana research report; this document covers the implementation only.

## 1. Scope

**In scope:**
- `mstocks-core`: the only in-house program on Solana (Anchor).
- Issuance and setup scripts: create a mint with extensions, hook it up to Core, register the CCIP pool.
- Tests: LiteSVM, running against the mainnet Token-2022 build.
- Solana support in the compliance backend `mstocks-aml`: watch transfers, check the blacklist, call Core to freeze / thaw (§11).

**Out of scope:** deploying and configuring the CCIP LockRelease pool on Mantle (standard CCIP contracts, nothing to build), scheduling and alerting for multiplier reconciliation, frontend.

**Settled assumptions:**
- 9 decimals; Mantle is the only issuing chain; CCIP uses lock / mint: the LockRelease pool on Mantle locks / releases, the BurnMint pool on Solana mints / burns. Tokens on Solana are minted only by the CCIP BurnMint pool, so the Solana supply equals the amount locked in the Mantle pool (÷1e9).
- Compliance is "screen after use": the blacklist lives in the backend, which calls Core to freeze accounts.
- No Transfer Hook; the mint carries a dormant Hook extension whose authority is held directly by the Squads multisig.
- Multiplier option B: each chain schedules its own; CCIP only moves tokens.
- Permanent Delegate enabled (delegate = Authority PDA), for clawback.

---

## 2. Overall structure

```
          Squads multisig (Admin)     Backend / ops (one key per role)
                 │                            │
                 ▼                            ▼
          ┌────────────────── mstocks-core ──────────────────┐
          │ Config · roles · MintState                        │
          │ Authority PDA (holds the token authorities, signs  │
          │ the CPIs)                                         │
          └───────────────────────┬──────────────────────────┘
                                  ▼ CPI
                          Token-2022 mint (one per stock)
                                  ▲
                    CCIP BurnMint pool (holds the mint authority)
```

**Core principle:** every token authority (multiplier, pause, freeze, metadata, clawback) is given to Core's Authority PDA. No private key can act on the token directly, only through Core; Core checks roles and rules first, then CPIs into Token-2022.

---

## 3. Account model

| Account | PDA seeds | Fields | Notes |
| --- | --- | --- | --- |
| `Config` | `["config"]` | `admin`, `pending_admin`, `hook_authority` (Squads, checked by `register_mint`), `min_notice` (default 300 s), `max_horizon` (default 365 days), `bump` | Singleton |
| `RoleEntry` | `["role", role_id, member]` | `role`, `member`, `bump` | The account existing means the member holds the role; mirrors Mantle's `AccessControl`, several members per role |
| `MintState` | `["mint", mint]` | `mint`, `mantle_token` (20 bytes), `bump` | Only registered stocks can be operated by Core |
| Authority PDA | `["authority"]` | No data | Holds the Token-2022 authorities and signs the CPIs |

**Why one global Authority PDA instead of one per mint:** every operation goes through the same role checks, so splitting by mint does not reduce risk, it only complicates setup. Isolation between mints comes from `MintState` registration and account checks.

---

## 4. Roles

Same separation of duties as on Mantle:

| Role | Holder | Can do | Mantle equivalent |
| --- | --- | --- | --- |
| Admin | Squads multisig | Grant / revoke roles, register mints, change config; **no operational actions** | `DEFAULT_ADMIN_ROLE` |
| `MULTIPLIER_SCHEDULER` | Scheduling KMS | Schedule the multiplier | `MULTIPLIER_SCHEDULER_ROLE` |
| `PAUSER` | Ops EOA / KMS | Pause | `PAUSE_ROLE` |
| `UNPAUSER` | Multisig | Resume | `UNPAUSE_ROLE` |
| `FREEZER` | Backend KMS | Freeze accounts (blacklist) | `ComplianceRegistry` OPS (`sanctionUsers`) |
| `UNFREEZER` | Backend KMS (same key as `FREEZER` by default) | Thaw accounts (automatically after removal from the blacklist) | `ComplianceRegistry` OPS (`unsanctionUsers`) |
| `CLAWBACK` | Multisig | Clawback (Permanent Delegate) | — |
| `METADATA_OPS` | Ops | Update name, symbol, ISIN | `ScaledToken` OPS |

**Guards carried over:**
- No self-grant: the Admin cannot grant a role to itself.
- Operational instructions reject an Admin signature, even if the Admin also holds the role.
- Admin changes take two steps: `propose_admin` → `accept_admin`.
- Role members can renounce their own role; the Admin cannot.

---

## 5. Instructions

### 5.1 Administration

| Instruction | Signer | Checks | Action |
| --- | --- | --- | --- |
| `initialize(admin, hook_authority)` | Program upgrade authority | Once only; the signer must be the program's upgrade authority, so nobody can initialize first after deployment | Create `Config` |
| `propose_admin(new)` / `accept_admin` | Current Admin / new Admin | Two-step confirmation | Change the Admin |
| `grant_role(role, member)` | Admin | `member != admin` | Create `RoleEntry` |
| `revoke_role(role, member)` | Admin | — | Close `RoleEntry` |
| `renounce_role(role)` | The member | — | Close their own `RoleEntry` |
| `register_mint(mantle_token)` | Admin | See below | Create `MintState` |
| `set_default_account_state(frozen)` | Admin | Mint registered | Switch the compliance policy: new accounts start frozen (screen before use) or usable (screen after use, current). A policy change, so it is the Admin's (Squads) call, like the admin-only `updateCompliance` on Mantle |

Mint checks in `register_mint` (so a token is under control from launch):
- Owned by the Token-2022 program, 9 decimals;
- **Only these extensions**: Scaled UI Amount, Pausable, Metadata Pointer, Token Metadata, Default Account State, Transfer Hook, Permanent Delegate. Any other extension (e.g. MintCloseAuthority, transfer fees, confidential transfers) brings an authority Core does not control and is rejected;
- The authorities of Scaled UI Amount, Pausable, Metadata Pointer and Token Metadata are the Authority PDA (a Metadata Pointer held by someone else could be pointed at other metadata);
- The freeze authority is the Authority PDA;
- The Transfer Hook extension is present **with no program**, and its authority is the Squads address recorded in the config;
- The Default Account State extension is present with state "initialized";
- The Permanent Delegate extension is present and the delegate is the Authority PDA;
- The mint authority is **not** the Authority PDA (minting belongs to the CCIP pool).

### 5.2 Multiplier

**`schedule_multiplier(multiplier_1e18: u128, effective_at: i64)`** (option B)

| Item | Detail |
| --- | --- |
| Signer | `MULTIPLIER_SCHEDULER` (not the Admin) |
| Checks | `1e9 ≤ multiplier_1e18 ≤ 1e27`; `now + min_notice ≤ effective_at ≤ now + max_horizon` |
| Conversion | `multiplier_f64 = multiplier_1e18 / 1e18` (off-chain scheduling limits it to 15 significant digits) |
| Action | CPI `UpdateMultiplier(multiplier_f64, effective_at)`, signed by the Authority PDA |
| Event | `MultiplierScheduled { mint, multiplier_1e18, effective_at }` |

The parameters use the same units as Mantle's `setUIMultiplier` (1e18 fixed point + Unix seconds), so both chains get the same values.

Consistency comes from the operating process and reconciliation: ops send the same parameters on Mantle and Solana, and `check-multiplier.ts` compares the two chains (one-shot; scheduled runs and alerting belong to the backend and are out of scope). Option A (sync via CCIP messages) is not implemented.

**Amount units:** balances, transfer instructions and CCIP transfers all use the raw amount; the displayed amount = raw amount × multiplier. With the same multiplier on both chains, the displayed amount is the same before and after a transfer. Wallets and ops tools must be clear about which one an input means (the `spl-token` CLI uses raw amounts).

### 5.3 Pause

| Instruction | Signer | Action |
| --- | --- | --- |
| `pause(mint)` | `PAUSER` | CPI Pausable `pause` |
| `resume(mint)` | `UNPAUSER` | CPI Pausable `resume` |
| `pause_all` | `PAUSER` | Pause every registered mint passed as remaining accounts; up to about 12 mints per transaction (64 bytes each), the script sends batches of 8 |

**Effect of a pause on CCIP:** while paused, a user's `ccip_send` fails, and messages arriving from Mantle fail to execute too (the pool's MintTo is rejected and the whole execution rolls back, so no tokens are lost); the DON does not retry them. After resuming, ops must execute those messages manually with `ccip-manual-exec.ts`, one by one: anyone can do so 20 minutes after the commit, and a repeated execution of the same message is skipped by the OffRamp.

### 5.4 Compliance

| Instruction | Signer | Action |
| --- | --- | --- |
| `freeze(mint, token_accounts…)` | `FREEZER` | Check that each account belongs to the registered mint, then batch CPI `FreezeAccount`; accounts already frozen are skipped, so the backend can resend. Up to about 23 accounts per transaction; the script sends batches of 20 (measured 92k CU, 1132 bytes) |
| `thaw(mint, token_accounts…)` | `UNFREEZER` | Batch CPI `ThawAccount`; accounts already thawed are skipped |
| `clawback(source, destination, amount)` | `CLAWBACK` | In one instruction: thaw source → `transfer_checked` to destination as Permanent Delegate → freeze source again |

`clawback` thaws first because a frozen account cannot send even when the Permanent Delegate initiates the transfer (tested: a direct transfer fails with `AccountFrozen`; "thaw → transfer → freeze" in one transaction succeeds). The destination should be a custody account.

### 5.5 Metadata

| Instruction | Signer | Action |
| --- | --- | --- |
| `update_metadata(field, value)` | `METADATA_OPS` | CPI Token Metadata `update_field` (name / symbol / ISIN, etc.); when a value gets longer, the client tops up the mint's rent in the same transaction first |

### 5.6 Events

Every operational instruction emits an event (`RoleGranted`, `MultiplierScheduled`, `Paused`, `Resumed`, `Frozen`, `Thawed`, `ClawedBack`, `MetadataUpdated`, etc.) for backend indexing and audit.

---

## 6. Issuance and setup (scripts)

Run once per stock, in this order:

```
1. Create the mint account and initialize its extensions:
     Scaled UI Amount (authority = Authority PDA, initial multiplier = Mantle's current value)
     Pausable (authority = Authority PDA)
     Metadata Pointer (points to itself)
     Default Account State (initialized)
     Transfer Hook (authority = Squads, program = none)
     Permanent Delegate (= Authority PDA)
2. InitializeMint2: 9 decimals; mint authority = deployer (temporary); freeze authority = Authority PDA
3. Initialize Token Metadata (update authority = deployer at first) → write ISIN and other fields
     → hand the update authority to the Authority PDA
4. Core.register_mint(mantle_token)
5. CCIP: self-register with the deployer (current mint authority) → Squads accepts the token admin role
     → initialize the BurnMint pool → configure the Mantle remote chain and rate limits
6. Hand the mint authority to the CCIP pool signer PDA
```

**Why step 5 must come before step 6:** CCIP self-registration needs the mint authority's signature, which is no longer possible once it belongs to a PDA.

**Initial multiplier:** a new mint's initial value must equal Mantle's current `uiMultiplier()`. If Mantle has a pending value, schedule it on Solana right after launch.

**Why the deployer writes the metadata first:** extra fields such as the ISIN can only be written with `update_field`, which needs the update authority's signature. Writing them with the deployer before handing the authority to Core avoids a separate `METADATA_OPS` step at launch.

**Scripts (`solana/scripts/`):**

| Step | Script |
| --- | --- |
| Deploy and initialize Core (once) | Deploy with the deployer as upgrade authority → `init-core.ts` (signed by the upgrade authority) → hand the upgrade authority to Squads + Timelock |
| Grant roles | `grant-role.ts` / `revoke-role.ts` |
| Steps 1–4 | `create-mint.ts` |
| Schedule a pending multiplier | `schedule-multiplier.ts` |
| Compare the multiplier on both chains (option B) | `check-multiplier.ts` |
| Step 5, CCIP registration | `ccip-register.ts`: token admin registration (propose + accept), BurnMint pool initialization, pool token account, remote chain config (token, pool, decimals), rate limits, address lookup table, `set_pool`; steps already done are skipped. On mainnet the token admin role and pool ownership must then be handed to Squads (not scripted) |
| Step 6 | `handoff-mint-authority.ts` (dry run by default, `--yes` to execute) |
| Check the result | `show-mint.ts` |

**CCIP testnet (Solana devnet ↔ Mantle Sepolia, open since 2026-11):** on both chains the OnRamp / OffRamp addresses are shared by all lanes.

| | Solana devnet | Mantle Sepolia |
| --- | --- | --- |
| Chain selector | `16423721717087811551` | `8236463271206331221` |
| Router | `Ccip842gzYHhvdDkSyi2YVCoAWPbYJoApMFzSxQroE9C` | `0xFd33fd627017fEf041445FC19a2B6521C9778f86` |
| OnRamp | The Router itself | `0xCAC5826F878b3BfEE32404619C762b33ae199c1b` |
| OffRamp | `offqSMQWgQud6WJz694LRzkeN5kMYpCHTpXQr3Rkcjm` | `0x4d8193f845Eb3540e0BdA9451296600362E22B15` |
| Token pool | BurnMint program `41FGToCmdaWa1dgZLKFAjvmx6e6AjVTX7SVRibvsMGVB` (same as mainnet) | LockRelease, deployed through Token Pool Factory `0x9fCd83bC7F67ADa1fB51a4caBEa333c72B641bd1` |
| Registration | Token admin registry inside the Router | Token Admin Registry `0x0F1eE88A582f31d92510E300fc1330AA5a525D51`, Registry Module `0xf76cE612250eeEb8889F49FBCB11f1c2705305F6` |
| Other | Fee Quoter `FeeQPGkKDeRV1MgoYfMH6L8o3KeuYjwUZrgn4LRKfjHi`, RMN `RmnXLft1mSEwDgMKu2okYuHkiazxntFFcZFrrcXxYg7` | RMN `0xcCB84Ec3F6AFdD2052134f74aaAc95Ae41A7B333` |
| Fee tokens | LINK, WSOL | LINK, WMNT |

**Per-token gas on Solana → Mantle (must be handled before launch):** our mints have no per-token config on the Solana Fee Quoter, so they use the lane default `defaultTokenDestGasOverhead = 90000`, i.e. the pool's `releaseOrMint` on Mantle gets at most 90,000 gas. A ScaledToken transfer makes two external calls (pause and compliance checks); when the receiver holds the token for the first time, its balance is written from zero, the total goes over 90,000 and the execution fails, and the DON does not retry it. Only the Fee Quoter owner (Chainlink) can raise it with `set_token_transfer_fee_config`, so Chainlink has to set it for this lane before launch (150,000 suggested). Until then, failed messages are executed manually with `ccip-manual-exec-evm.sh` (`TOKEN_GAS=150000`).

**Admin actions and Squads:** scripts that need the Admin's signature (`grant-role`, `revoke-role`, `register_mint` in `create-mint`) have two modes: given a keypair file they sign and send (devnet / local); given a Squads address they only print the instruction for a Squads proposal. In print mode the payer is the vault itself, because a Squads proposal can only be signed by the vault and cannot carry local signers.

### 6.1 Operations scripts

Day-to-day operations after launch; backend services can follow how they call Core:

| Operation | Script | Notes |
| --- | --- | --- |
| Pause / resume | `pause.ts` (`--resume`) | `PAUSER` / `UNPAUSER` |
| Global emergency pause | `pause-all.ts` (`--dry-run`) | Finds every registered mint on chain and calls `pause_all` in batches of 8; pass `--mints` explicitly when the RPC does not support `getProgramAccounts` |
| Execute an inbound CCIP message manually | `ccip-manual-exec.ts` | Takes the failed execution transaction (linked from the message page in the CCIP Explorer), reuses its execution report and accounts, and calls the OffRamp's `manually_execute` instead; anyone can run it, the payer only pays the fee |
| Execute an outbound CCIP message on Mantle manually | `ccip-manual-exec-evm.sh` | For a Solana → Mantle message that failed on Mantle (token paused, receiver sanctioned, rate limit, out of gas): reuses the failed transaction's execution report and calls the OffRamp's `manuallyExecute`; a failed message can be executed right away, and `TOKEN_GAS` raises the gas for each token |
| Blacklist / unblacklist | `freeze.ts` (`--thaw`) | `--owner <wallet>` finds all of the wallet's token accounts for this mint over RPC (including non-ATAs) and sends batches of 20, the same flow the backend uses |
| Clawback | `clawback.ts` | To a custody account; the source account stays frozen |
| Update metadata | `update-metadata.ts` | Tops up the mint's rent when a field gets longer, then calls Core |
| Multiplier reconciliation | `check-multiplier.ts` | Option B reconciliation: reads the Mantle token address from Core's registration and compares the current and pending values (value + effective time) on both chains at the same moment; exits with 1 on a mismatch so a scheduled job can alert; a mismatch within 60 seconds of the effective time only warns, since the two chains' clocks can differ by a few seconds |
| Inspect an account | `show-account.ts` | Balance and freeze state |
| Test minting | `dev-mint-to.ts` | Local / devnet only, before the mint authority is handed off |

---

## 7. Directory layout

```
solana/
  Anchor.toml / Cargo.toml / rust-toolchain.toml   toolchain: Anchor 1.2.2, Agave 4.4.0, Rust 1.97.1
  programs/mstocks-core/
    src/
      lib.rs              instruction entry points
      state.rs            Config / RoleEntry / MintState, role definitions, constants
      errors.rs
      events.rs
      token2022.rs        CPI wrappers (UpdateMultiplier / Pause / Freeze / Transfer / Metadata)
      instructions/       admin / register_mint / multiplier / pause / compliance / metadata
    tests/core.rs         LiteSVM integration tests (mainnet Token-2022 build)
  scripts/                issuance, setup and ops scripts (TypeScript, @solana/kit; Core instructions built from the IDL)
  tests/fixtures/         mainnet Token-2022 binary (fetched by a script, not committed)
  README.md               build, test and script usage
```

It lives in this repo's `solana/` directory, separate from the EVM code, and builds on its own.

---

## 8. Testing

Test runs and results are recorded in a separate [test report](https://skfc4x16la.larksuite.com/wiki/Sohpww2abiDlMUkSCoXu4lvfshg) and not repeated here. Entry points:

- Program: `cargo test -p mstocks-core` (LiteSVM, mainnet Token-2022 build); CI in `.github/workflows/solana.yml`.
- Scripts: `npm run local-e2e` (local validator), `scripts/test-check-multiplier.sh` (reconciliation against a ScaledToken on anvil), `scripts/devnet-smoke.sh` (devnet).
- Compliance backend: mstocks-aml's `scripts/solana-e2e.sh` (both chains locally) and `scripts/solana-devnet-check.sh` (devnet).

---

## 9. Security notes

- Every account's owner and PDA seeds are checked: the Token-2022 program ID, that `MintState` belongs to the mint, that a token account's mint is registered.
- The Authority PDA only signs inside Core; there is no generic CPI entry point.
- Multiplier conversion: the u128 → f64 precision loss is controlled at off-chain scheduling (at most 15 significant digits).
- Core's upgrade authority goes to the Squads multisig + Timelock. `initialize` requires the upgrade authority's signature, so the order is: deployer deploys → `init-core` → hand off the upgrade authority.
- `register_mint` uses an extension allowlist: any extension on the mint that Core does not control is rejected, so no back-door authority is left behind.
- The backend KMS key holds both `FREEZER` and `UNFREEZER`, matching OPS on EVM, which can both sanction and unsanction: a leaked key can freeze / thaw any account but cannot move assets (`CLAWBACK` is with the multisig). The Admin can revoke its roles at any time.
- If `set_default_account_state` is later used to switch to "screen before use", every new account has to be thawed first. The backend already holds `UNFREEZER` and could thaw new accounts directly, but that role can thaw any account; to limit it to opening new accounts, a separate "account opening" role can be added then.
- Holders can burn their own tokens: Token-2022 allows it and it cannot be turned off (on Mantle burning needs `BURN_ROLE`). Tokens burned on Solana stay locked in Mantle's LockRelease pool for good. This only affects the holder and is not a security issue; supply reconciliation should check Solana total supply ≤ the amount locked in the Mantle pool rather than strict equality.
- An independent Solana audit before launch.

---

## 10. Review decisions

| # | Topic | Decision |
| --- | --- | --- |
| 1 | Multiplier sync | Option B: each chain schedules its own; CCIP only moves tokens |
| 2 | Permanent Delegate | Enabled, delegate = Authority PDA; `clawback` implemented |
| 3 | Transfer Hook | Dormant (no program), authority held directly by the Squads multisig |
| 4 | Code location | This repo, `solana/` directory |
| 5 | Toolchain | Upgrade to Agave + Anchor 1.x |
| 6 | Role keys | The backend KMS supports Ed25519; each operational role uses a KMS key |
| 7 | Compliance backend | Add Solana to the existing `mstocks-aml`, changing the EVM logic as little as possible (§11) |
| 8 | Thaw | Same as EVM: after removal from the blacklist the backend signer thaws automatically; `UNFREEZER` is held by the backend KMS |

---

## 11. Companion service: compliance backend (mstocks-aml)

The backend half of "screen after use". Repo `mstocks-aml` (Go, previously EVM only), branch `feat/solana-support`. One process runs EVM and Solana with one database: each chain has its own indexer, processor, syncer and recheck, and data is keyed by chain name; the database, AML client and HTTP API are shared, and one recheck request sweeps every chain. It deploys as the existing `mantle-mstocks-aml` service, not a new one.

```
Solana RPC ──► indexer ──► transfer_events ──► processor ──► aml-gateway (blacklist)
                                                  │
                                                  ▼
                                    sanctioned_addresses (target state, pending sync)
                                                  │
                                                  ▼
                       syncer ──► Core freeze / thaw (signed by FREEZER / UNFREEZER)
```

| | EVM (unchanged) | Solana |
| --- | --- | --- |
| Indexing | ERC20 `Transfer` logs | Transaction history per mint (`getSignaturesForAddress`); transfers rebuilt from pre / post token balances; one signature cursor per mint |
| Blacklist | `ComplianceRegistry.sanctionUsers` | Core `freeze`: freeze all of the wallet's token accounts under every registered mint |
| Unblacklist | `unsanctionUsers` | Core `thaw`: thaw all of the wallet's token accounts |
| Signing | secp256k1 (local / AWS KMS) | Ed25519 (local keypair / AWS KMS `ECC_NIST_EDWARDS25519`) |

**Key points:**
- **Complete indexing**: for a mint with these extensions, Token-2022 rejects the legacy `Transfer` that omits the mint account (test `transfers_must_carry_the_mint_account`), so the mint's transaction history covers every transfer, CCIP mint / burn and clawback. Wallets (owners) are recorded, not token accounts. Reads are finalized by default, so no rollback handling is needed.
- **New accounts**: a frozen wallet can still gain new token accounts (one under another mint, or an ATA created by a CCIP mint). A frozen account cannot receive, so new tokens always land in a new account. When the indexer sees funds move for a sanctioned wallet, it marks the wallet pending again and the syncer freezes the new account.
- **Account ownership transfer**: a non-ATA token account's owner can be changed to another wallet with `SetAuthority`. That transaction carries no mint account and changes no balance, so it does not appear in the mint's history (tested); someone could "give" an account with a balance to a blacklisted wallet without it being indexed. A frozen account cannot change owner, so a blacklisted wallet can only gain accounts this way, never move them out. Countermeasure: every `reconcile_interval` (default 10 minutes) the reconciler checks all blacklisted wallets and requeues any with unfrozen accounts; one `getTokenAccountsByOwner` per wallet per round.
- **Whether to send a transaction**: a wallet can be partly frozen, so the syncer checks against the target state: blacklisting requires no unfrozen accounts, unblacklisting requires no frozen ones; if already satisfied, nothing is sent. Core skips accounts already in the target state, so retries are safe. 20 accounts per transaction; priority fees configurable.
- **Addresses returned by the AML gateway**: the production gateway lowercases the addresses in its results. EVM addresses are unaffected, but Solana addresses are case-sensitive and become invalid, or even another wallet, when lowercased. The service only uses the result to map back to the address it requested, and always stores and queries the original address.
- **Thaw**: same as EVM. When the AML gateway no longer flags an address (on a recheck or a new transaction), the database marks it pending removal and the syncer thaws all its accounts with Core `thaw`, signed by the backend signer. By default the same key as freezing (it must hold both `FREEZER` and `UNFREEZER`); a separate `unfreezer` can be configured. As on EVM: an address frozen manually by ops but judged clean by AML is thawed automatically the next time the service processes it (e.g. when it appears in a new transaction).
- **Signing and startup checks**: production uses AWS KMS Ed25519 (`ED25519_SHA_512`, raw message), verified locally after signing. At startup the service checks that the signer holds the roles and that the configured mints are registered in Core. The signer pays its own fees and needs a SOL balance.
- **Changes to EVM code**: lowercasing addresses in the processor is now configurable (Solana addresses are case-sensitive, EVM still lowercases); the syncer gains an optional interface for target-state checks (the EVM client does not implement it, behavior unchanged); database migration 006 widens the address and transaction hash columns and adds a cursor table; pending transfers and recheck queries filter by chain (same results with a single chain); at startup a set of components runs for each enabled chain (`evm.enabled` defaults to on, existing configs need no change).

**Chain name:** the `solana.chain_name` setting (shared by the database and the AML gateway) is `solana` on mainnet and `solana_devnet` on devnet.

**qa8 deployment (live):** the existing `mantle-mstocks-aml` service on sepolia-qa8 runs EVM (Mantle mainnet mirror, production AML gateway) and Solana devnet (QA AML gateway `mantle-aml-gateway` sepolia-qa7, whose test blacklist drives the freeze tests); see [mantle-config#17082](https://github.com/mantlenetworkio/mantle-config/pull/17082) and [#17092](https://github.com/mantlenetworkio/mantle-config/pull/17092). Signing uses the KMS Ed25519 key shared with retry-service (`5dc8b92b`, address `E8SV8n…`), which holds `FREEZER` / `UNFREEZER` on devnet. Note: `mantle-manual-awsres` does not update the IAM role of an existing service, so ops must add a new KMS key to the role's `kmsAccess` by hand; qa8 deploys from the feature branch, and the deploy workflow's token needs read access to `mantle-xyz/mstocks-aml`.

**Before launch:** a backend KMS Ed25519 key, granted `FREEZER` and `UNFREEZER` by the Admin (Squads), with a SOL balance for fees.
