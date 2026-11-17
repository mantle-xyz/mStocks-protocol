# mStocks Solana Core Program Design

> Status: reviewed (decisions in §10), first version implemented · 2026-11-05 · branch `feat/solana-core`
> Background and option analysis are in the Solana research report; this document covers the implementation only.

## 1. Scope

**In scope:**
- `mstocks-core`: the only in-house program on Solana (Anchor).
- Issuance and setup scripts: create a mint with extensions, hook it up to Core, register the CCIP pool.
- The Mantle side of CCIP for each token: deploy and configure the LockRelease pool, and produce the multisig transactions that register it (§6.2).
- Tests: LiteSVM, running against the mainnet Token-2022 build.
- Solana support in the compliance backend `mstocks-aml`: watch transfers, check the blacklist, call Core to freeze / thaw (§11).

**Out of scope:** changes to the Mantle contracts (the CCIP pool is a standard Chainlink contract and ScaledToken needs no change), scheduling and alerting for multiplier reconciliation, frontend.

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
| `Config` | `["config"]` | `admin`, `pending_admin`, `compliance_admin`, `pending_compliance_admin`, `hook_authority` (Squads, checked by `register_mint`), `min_notice` (300 s), `max_horizon` (365 days), `bump` | Singleton. `hook_authority`, `min_notice` and `max_horizon` are set at `initialize` and have no setter (on Mantle the notice period is fixed per implementation too) |
| `RoleEntry` | `["role", role_id, member]` | `role`, `member`, `bump` | The account existing means the member holds the role; mirrors Mantle's `AccessControl`, several members per role |
| `MintState` | `["mint", mint]` | `mint`, `mantle_token` (20 bytes), `bump` | Only registered stocks can be operated by Core |
| `MantleTokenIndex` | `["mantle_token", mantle_token]` | `mint`, `bump` | One per Mantle token: a token can be registered for one mint only |
| Authority PDA | `["authority"]` | No data | Holds the Token-2022 authorities and signs the CPIs |

**Why one global Authority PDA instead of one per mint:** every operation goes through the same role checks, so splitting by mint does not reduce risk, it only complicates setup. Isolation between mints comes from `MintState` registration and account checks.

---

## 4. Roles

Same separation of duties, admins and time locks as on Mantle (decided 2026-11-16). The Mantle column is the production configuration in `config.toml`; Mantle's admin addresses are OpenZeppelin `TimelockController`s whose proposers are 3/6 multisigs. Each Solana multisig mirrors one Mantle multisig, with the same signer group, threshold and time lock (Squads v4 time lock).

| Solana role | Can do | Solana holder | Mantle equivalent | Mantle holder |
| --- | --- | --- | --- | --- |
| Program upgrade authority | Upgrade Core; run `initialize` once | Squads mirroring multisig 2: 3/6 + 24 h time lock | Beacon / ProxyAdmin owner | Multisig 2, 3/6 + 24 h timelock |
| Admin (`Config.admin`) | Grant / revoke `MINT_REGISTRAR`, `MULTIPLIER_SCHEDULER`, `METADATA_OPS`; unregister an empty mint registered in error; switch the default account state; **no operational actions** | Squads mirroring multisig 1: 3/6 + 12 h time lock | `DEFAULT_ADMIN_ROLE` of the factory and ScaledToken | Multisig 1, 3/6 + 12 h timelock |
| Compliance admin (`Config.compliance_admin`) | Grant / revoke `PAUSER`, `UNPAUSER`, `FREEZER`, `UNFREEZER`; **clawback** (signed directly, no role); otherwise no operational actions | Squads mirroring multisig 4: 3/6 + 12 h time lock | `DEFAULT_ADMIN_ROLE` of the compliance and pause registries | Multisig 4, 3/6 + 12 h timelock |
| `MINT_REGISTRAR` | Register new mints | RWA-Bycustody key (as EOA1) | Factory `OPS_ROLE` (`createToken`) | EOA1 (RWA-Bycustody) |
| `MULTIPLIER_SCHEDULER` | Schedule the multiplier | RWA-Bycustody key (as EOA3) | `MULTIPLIER_SCHEDULER_ROLE` | EOA3 (RWA-Bycustody) |
| `METADATA_OPS` | Update name, symbol, ISIN | RWA-Bycustody key (as EOA2) | ScaledToken `OPS_ROLE` | EOA2 (RWA-Bycustody) |
| `PAUSER` | Pause | RWA-Bycustody key (as EOA6) | `PAUSE_ROLE` | EOA6 (RWA-Bycustody) |
| `UNPAUSER` | Resume | Squads mirroring multisig 5, no time lock (resuming must be fast) | `UNPAUSE_ROLE` | Multisig 5, no timelock |
| `FREEZER` | Freeze accounts (blacklist) | Mantle's compliance backend KMS (as EOA5) | `ComplianceRegistry` `OPS_ROLE` (`sanctionUsers`) | EOA5 (Mantle) |
| `UNFREEZER` | Thaw accounts (automatically after removal from the blacklist) | Same key as `FREEZER` | `ComplianceRegistry` `OPS_ROLE` (`unsanctionUsers`) | EOA5 (Mantle) |
| Transfer Hook authority (Token-2022, not Core) | Attach / remove a program that checks every transfer | The admin's Squads (multisig 1's group, 12 h) | ScaledToken admin's `updateCompliance` / `updatePauseManager` | Multisig 1, 3/6 + 12 h timelock |
| CCIP token admin, per mint (router's token admin registry) | Point the mint at a different pool | The admin's Squads (`ccip-handoff.ts`) | CCIP token admin (`TokenAdminRegistry`) | The token's `DEFAULT_ADMIN_ROLE`: multisig 1 (§6.2) |
| CCIP pool owner (BurnMint pool) | Remote chains and pools, rate limits | The admin's Squads (`ccip-handoff.ts`) | LockRelease pool owner | Multisig 1 (§6.2) |
| — | Rate limits only | Pool owner | Pool `rateLimitAdmin` (optional) | Operations multisig, or unset |
| — | — | — | Pool `rebalancer` (can withdraw every locked token) | **Unset** |

Mantle's multisig 3 (TokenIssuer admin) has no Solana counterpart: minting on Solana belongs only to the CCIP pool. Clawback has no Mantle counterpart either; it moves a holder's tokens without their signature, so it is signed by the compliance admin itself (3/6 + 12 h) rather than delegated to an operations role. The `Clawback` role value is retired: it cannot be granted (`RoleRetired`) and stays in the enum only so later roles keep their seeds.

**Guards carried over:**
- Each admin grants and revokes only its own roles (`NotRoleAdmin`).
- No self-grant: neither admin can be given any role.
- Operational instructions reject either admin's signature, even if it still holds a role from before.
- Admin changes take two steps, separately for each admin: `propose_admin` → `accept_admin`, `propose_compliance_admin` → `accept_compliance_admin`; the two admins must differ.
- Role members can renounce their own role; the admins cannot.

---

## 5. Instructions

### 5.1 Administration

| Instruction | Signer | Checks | Action |
| --- | --- | --- | --- |
| `initialize(admin, compliance_admin, hook_authority)` | Program upgrade authority | Once only; the signer must be the program's upgrade authority, so nobody can initialize first after deployment | Create `Config` |
| `propose_admin(new)` / `accept_admin` | Current admin / new admin | Two-step confirmation; `new` ≠ compliance admin | Change the admin |
| `propose_compliance_admin(new)` / `accept_compliance_admin` | Current compliance admin / new one | Two-step confirmation; `new` ≠ admin | Change the compliance admin |
| `grant_role(role, member)` | The role's admin (compliance admin for `PAUSER`, `UNPAUSER`, `FREEZER`, `UNFREEZER`; admin for the others); the retired `Clawback` cannot be granted | `member` is neither admin | Create `RoleEntry` |
| `revoke_role(role, member)` | The role's admin | — | Close `RoleEntry` |
| `renounce_role(role)` | The member | — | Close their own `RoleEntry` |
| `register_mint(mantle_token)` | `MINT_REGISTRAR` | See below; `mantle_token` non-zero and not yet registered for another mint | Create `MintState` and `MantleTokenIndex` |
| `unregister_mint` | Admin | The mint's supply is 0 | Close `MintState` and `MantleTokenIndex`, so a registration made in error (wrong mint or wrong Mantle token) can be redone. Once tokens exist Core must keep operating the mint, so it stays registered |
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
| Checks | `1e9 ≤ multiplier_1e18 ≤ 1e27`; at most 15 significant decimal digits; `now + min_notice ≤ effective_at ≤ now + max_horizon` |
| Conversion | `multiplier_f64 = multiplier_1e18 / 1e18`. Token-2022 stores an f64, which holds 15 significant digits exactly; a finer value would be rounded on Solana but kept on Mantle, so Core rejects it (`MultiplierTooPrecise`) and operations send both chains a value within that precision |
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
| `freeze(mint, token_accounts…)` | `FREEZER` | Batch CPI `FreezeAccount` on every given token account of the registered mint. Skipped without failing the batch: accounts already frozen (so the backend can resend), and accounts that are not, or no longer, token accounts of this mint (a wallet can close an empty account or re-create it for another mint between the backend's lookup and the freeze; that must not leave its funded accounts usable). Up to about 23 accounts per transaction; the script sends batches of 20 (measured 92k CU, 1132 bytes) |
| `thaw(mint, token_accounts…)` | `UNFREEZER` | Batch CPI `ThawAccount`; same skipping rules as `freeze` |
| `clawback(source, destination, amount)` | Compliance admin | In one instruction: thaw source → `transfer_checked` to destination as Permanent Delegate → freeze source again |

`clawback` thaws first because a frozen account cannot send even when the Permanent Delegate initiates the transfer (tested: a direct transfer fails with `AccountFrozen`; "thaw → transfer → freeze" in one transaction succeeds). The destination should be a custody account. Three consequences of how Token-2022 works: `clawback` fails while the mint is paused (a pause rejects every transfer, including the permanent delegate's; freeze and thaw still work, so freeze first and claw back after resuming); it fails if the Transfer Hook is ever given a program (the CPI passes no hook accounts; Core would need an upgrade first); and with `amount = 0` it succeeds and leaves the source frozen.

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
4. Core.register_mint(mantle_token), signed by the MINT_REGISTRAR (operations KMS)
5. Mantle: deploy the LockRelease pool, point it at the Solana pool and mint, set rate limits,
     propose the pool owner (multisig)                                                 (§6.2)
6. Solana CCIP: self-register with the deployer (current mint authority) → initialize the BurnMint
     pool → configure the Mantle remote chain and rate limits
7. Multisigs: on Mantle the token admin's timelock registers the token's CCIP admin and sets the
     pool, and the pool owner accepts; on Solana the CCIP token admin and the pool owner move to Squads
8. Hand the mint authority to the CCIP pool signer PDA
9. Verify both sides
```

**Why step 6 must come before step 8:** CCIP self-registration needs the mint authority's signature, which is no longer possible once it belongs to a PDA.

**Initial multiplier:** a new mint's initial value must equal Mantle's current `uiMultiplier()`. If Mantle has a pending value, schedule it on Solana right after launch.

**Why the deployer writes the metadata first:** extra fields such as the ISIN can only be written with `update_field`, which needs the update authority's signature. Writing them with the deployer before handing the authority to Core avoids a separate `METADATA_OPS` step at launch.

**Scripts (`solana/scripts/`):**

| Step | Script |
| --- | --- |
| Deploy and initialize Core (once) | Deploy with the deployer as upgrade authority → `init-core.ts` (signed by the upgrade authority) → hand the upgrade authority to the upgrade multisig's vault (Squads, 24 h time lock); later upgrades are Squads proposals (`squads.ts upgrade`) |
| Grant roles | `grant-role.ts` / `revoke-role.ts` |
| Steps 1–4 | `create-mint.ts` |
| Schedule a pending multiplier | `schedule-multiplier.ts` |
| Compare the multiplier on both chains (option B) | `check-multiplier.ts` |
| Step 6, CCIP registration | `ccip-register.ts`: token admin registration (propose + accept), BurnMint pool initialization, pool token account, remote chain config (token, pool, decimals), rate limits, address lookup table, `set_pool`; steps already done are skipped. On mainnet the token admin role and pool ownership are then handed to the admin's Squads (`ccip-handoff.ts`, step 7) |
| Step 5, Mantle pool | `ccip-mantle-setup.sh deploy` (deployer key) |
| Step 7, multisigs | Mantle: `ccip-mantle-setup.sh multisig` writes Safe Transaction Builder files (timelock schedule, then execute after the delay; pool owner acceptance). Solana: `ccip-handoff.ts` proposes the Squads vault and puts both acceptances in one Squads proposal |
| Step 8 | `handoff-mint-authority.ts` (dry run by default, `--yes` to execute) |
| Step 9 | `ccip-mantle-setup.sh verify` (exits 1 on a problem), `show-mint.ts` |
| Check the result | `show-mint.ts` |

**CCIP testnet (Solana devnet ↔ Mantle Sepolia, open since 2026-11):** on both chains the OnRamp / OffRamp addresses are shared by all lanes.

| | Solana devnet | Mantle Sepolia |
| --- | --- | --- |
| Chain selector | `16423721717087811551` | `8236463271206331221` |
| Router | `Ccip842gzYHhvdDkSyi2YVCoAWPbYJoApMFzSxQroE9C` | `0xFd33fd627017fEf041445FC19a2B6521C9778f86` |
| OnRamp | The Router itself | `0xCAC5826F878b3BfEE32404619C762b33ae199c1b` |
| OffRamp | `offqSMQWgQud6WJz694LRzkeN5kMYpCHTpXQr3Rkcjm` | `0x4d8193f845Eb3540e0BdA9451296600362E22B15` |
| Token pool | BurnMint program `41FGToCmdaWa1dgZLKFAjvmx6e6AjVTX7SVRibvsMGVB` (same as mainnet) | LockReleaseTokenPool per token, deployed by `ccip-mantle-setup.sh` |
| Registration | Token admin registry inside the Router | Token Admin Registry `0x0F1eE88A582f31d92510E300fc1330AA5a525D51`, Registry Module `0xf76cE612250eeEb8889F49FBCB11f1c2705305F6` |
| Other | Fee Quoter `FeeQPGkKDeRV1MgoYfMH6L8o3KeuYjwUZrgn4LRKfjHi`, RMN `RmnXLft1mSEwDgMKu2okYuHkiazxntFFcZFrrcXxYg7` | RMN `0xcCB84Ec3F6AFdD2052134f74aaAc95Ae41A7B333` |
| Fee tokens | LINK, WSOL | LINK, WMNT |

**Per-token gas on Solana → Mantle (must be handled before launch):** our mints have no per-token config on the Solana Fee Quoter, so they use the lane default `defaultTokenDestGasOverhead = 90000`, i.e. the pool's `releaseOrMint` on Mantle gets at most 90,000 gas. A ScaledToken transfer makes two external calls (pause and compliance checks); when the receiver holds the token for the first time, its balance is written from zero, the total goes over 90,000 and the execution fails, and the DON does not retry it. Only the Fee Quoter owner (Chainlink) can raise it with `set_token_transfer_fee_config`, so Chainlink has to set it for this lane before launch (150,000 suggested). Chainlink has agreed to raise the lane default on mainnet and testnet. Until then the CCIP retry service (§12) re-executes these messages automatically; `ccip-manual-exec-evm.sh` (`TOKEN_GAS=150000`) is the manual fallback.

**Admin actions and Squads:** scripts that need a multisig's signature (`grant-role`, `revoke-role`, `unregister-mint`, `set-default-account-state`, `clawback`, `pause --resume` for the Unpauser, the acceptances in `ccip-handoff`) take a keypair file, which signs and sends (devnet / local), or a Squads v4 multisig account address (mainnet). For a multisig the signer is its vault (index 0); with `--squads-member <member keypair>` the script creates the vault transaction and its proposal in one transaction, approved by that member, and `squads.ts` takes it the rest of the way (`approve`, `status`, `execute` once the time lock has passed); without a member key it prints the instruction. In a proposal the vault is also the payer, because a vault transaction can only be signed by the vault and cannot carry local signers, so each vault keeps some SOL for rent. Every address stored as a signer (`init-core` admins and hook authority, `create-mint --hook-authority`, a role `--member`, the `check-config` entries) is converted from a multisig account to its vault: the multisig account cannot sign, so storing it would brick that authority. Program upgrades go through the upgrade multisig: write a buffer, `solana program set-buffer-authority <buffer> --new-buffer-authority <vault>`, then `squads.ts upgrade` proposes the BPF loader `Upgrade` signed by the vault. `local-squads-e2e.sh` rehearses all of this against the mainnet Squads v4 program on a local validator.

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
| Supply reconciliation | `check-supply.ts` | For each mint: Solana supply (scaled to Mantle's 18 decimals) ≤ balance of its Mantle LockRelease pool (token from Core's registration, pool from the Mantle TokenAdminRegistry). It always holds, because Mantle locks before Solana mints and Solana burns before Mantle releases; the difference is tokens in flight to Solana plus tokens burned by holders on Solana. Exits with 1 if Solana holds more than is locked, so a scheduled job can alert |
| Multiplier reconciliation | `check-multiplier.ts` | Option B reconciliation: reads the Mantle token address from Core's registration and compares the current and pending values (value + effective time) on both chains at the same moment; exits with 1 on a mismatch so a scheduled job can alert; a mismatch within 60 seconds of the effective time only warns, since the two chains' clocks can differ by a few seconds |
| Inspect an account | `show-account.ts` | Balance and freeze state |
| Test minting | `dev-mint-to.ts` | Local / devnet only, before the mint authority is handed off |

### 6.2 CCIP on the Mantle side

Mantle is the issuing chain, so each token gets a **LockReleaseTokenPool**: sending to Solana locks the token in the pool, receiving from Solana releases it. The pool only calls `transfer`, so ScaledToken needs no change and no new role; `ISSUER_ROLE` / `BURN_ROLE` are never granted to it. The pool is pinned to `@chainlink/contracts-ccip` 1.6.4 (the version mantle-cross uses for its pools) and compiled with the mStocks contracts' settings (solc 0.8.24, cancun, via-IR, 200 runs).

**What the token's code implies:**
- `ScaledToken._update` checks the pause state and the sanctions of `from`, `to` and, for a third-party `transferFrom`, the caller. Sending to Solana is a `transferFrom` by the CCIP Router into the pool, so **the Router and the pool must never be sanctioned**. A sanctioned receiver makes the release fail until it is unsanctioned; a paused token blocks both directions (tested on testnet).
- ScaledToken has neither `owner()` nor `getCCIPAdmin()`. The only way to become its CCIP token admin is `RegistryModuleOwnerCustom.registerAccessControlDefaultAdmin(token)`, called by the holder of the token's `DEFAULT_ADMIN_ROLE` — on mainnet multisig 1's 12 h timelock. It then calls `acceptAdminRole` and `setPool`; the script puts the three calls in one timelock batch. The admin can later move the role with `transferAdminRole`.

**Pool permissions:**

| Permission | Can do | Holder |
| --- | --- | --- |
| Owner | Add / remove remote chains and pools (`applyChainUpdates`), rate limits, set the other admins. A wrong remote pool would let another chain release tokens locked on Mantle | Multisig; proposed by the deployer, accepted by the multisig (two-step ownership) |
| `rateLimitAdmin` | Rate limits only | Optional, an operations multisig for fast reaction |
| `rebalancer` | `withdrawLiquidity` can take every locked token | **Never set**; the issuing chain needs no external liquidity. `verify` fails if it is set |

**Steps (`ccip-mantle-setup.sh`, `NETWORK=mainnet` by default):**
1. `deploy` (deployer key): deploys the pool, `applyChainUpdates` for Solana (remote pool = the Solana pool config PDA `["ccip_tokenpool_config", mint]`, remote token = the mint, both as 32 bytes), rate limits both ways in 18-decimal units, optional `setRateLimitAdmin`, and `transferOwnership(<multisig>)`.
2. `multisig`: writes Safe Transaction Builder JSON. For a timelock it wraps the calls as `scheduleBatch` (file 1) and `executeBatch` (file 2, after the delay; the operation id is printed); for a Safe or EOA they are plain calls. Steps already done on chain are left out.
3. Solana: `ccip-register.ts` with this pool, `ccip-handoff.ts --to <Squads vault>`, then `handoff-mint-authority.ts --yes`.
4. `verify`: pool token, router, RMN, remote pool and token, rebalancer unset, allowlist off, registry admin = token admin, registry pool = this pool, Router and pool not sanctioned.

**Mantle mainnet CCIP addresses** (Chainlink CCIP directory, checked on chain): chain selector `1556008542357238666`; Router `0x670052635a9850bb45882Cb2eCcF66bCff0F41B7`; RMN proxy `0x91E2186E93F0ECeDDCdf9850078F104daB085E79`; TokenAdminRegistry `0x000A744940eB5D857c0d61d97015DFc83107404F`; RegistryModuleOwnerCustom `0xf49f81b3d2F2a79b706621FA2D5934136352140c`. The Mantle mainnet Router supports the Solana mainnet lane (selector `124615329519749607`).

**Rehearsal (2026-11-16, Mantle Sepolia ↔ Solana devnet):** a new ScaledToken whose admin is a TimelockController (60 s delay standing in for 12 h), a separate pool owner standing in for a Safe, and a key standing in for the Squads vault. The deploy, the timelock batch (an early execute was rejected; it executed after the delay), the pool owner acceptance, the Solana handoff in both modes (printing the Squads instructions, then signing them), the mint authority handoff and `verify` all passed. Then 0.01 went Mantle → Solana (delivered in about 26 minutes) and 0.005 came back (released on Mantle within a minute), and `check-supply.ts` reconciled exactly (0.005 on Solana, 0.005 locked).

**Squads handoff (2026-11-17, devnet):** the rehearsal mint's CCIP token admin and pool ownership then moved from the stand-in key to a real Squads v4 multisig (2/3, 60 s time lock): `ccip-handoff.ts --to <multisig> --squads-member <m1>` proposed the vault and created one Squads proposal with both acceptances; executing it with one approval (`InvalidProposalStatus`) and inside the time lock (`TimeLockNotReleased`) was rejected; after the second approval and the time lock it executed, and the vault now holds both roles.

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
- Scripts: `npm run local-e2e` (local validator), `scripts/local-squads-e2e.sh` (the runbook with real Squads v4 multisigs on a local validator), `scripts/test-check-multiplier.sh` (reconciliation against a ScaledToken on anvil), `scripts/test-check-supply.sh` (supply reconciliation: backed and over-minted), `scripts/devnet-smoke.sh` (devnet).
- Compliance backend: mstocks-aml's `scripts/solana-e2e.sh` (both chains locally) and `scripts/solana-devnet-check.sh` (devnet).

---

## 9. Security notes

- Every account's owner and PDA seeds are checked: the Token-2022 program ID, that `MintState` belongs to the mint, that a token account's mint is registered.
- The Authority PDA only signs inside Core; there is no generic CPI entry point.
- Multiplier conversion: Core rejects multipliers with more than 15 significant digits, so the f64 Token-2022 stores carries the same value as Mantle.
- Core's upgrade authority goes to the vault of the upgrade multisig (Squads v4, 24 h time lock). `initialize` requires the upgrade authority's signature, so the order is: deployer deploys → `init-core` → hand off the upgrade authority.
- `register_mint` uses an extension allowlist: any extension on the mint that Core does not control is rejected, so no back-door authority is left behind.
- The backend KMS key holds both `FREEZER` and `UNFREEZER`, matching OPS on EVM, which can both sanction and unsanction: a leaked key can freeze / thaw any account but cannot move assets (clawback is signed by the compliance admin multisig). The compliance admin can revoke its roles at any time.
- If `set_default_account_state` is later used to switch to "screen before use", every new account has to be thawed first. The backend already holds `UNFREEZER` and could thaw new accounts directly, but that role can thaw any account; to limit it to opening new accounts, a separate "account opening" role can be added then. It also stops CCIP deliveries to new wallets (tested on devnet): the executor creates the receiver's token account, which starts frozen, so the pool's MintTo fails (`Account is frozen`) and the message waits for a manual execution. Nothing thaws that account automatically, because the backend only learns about a wallet from a successful transfer. Before switching a CCIP-connected mint to screen before use, the backend needs a way to screen and thaw new accounts (for example by watching the mint's account creations), and failed deliveries need `ccip-manual-exec.ts` after the thaw.
- Holders can burn their own tokens: Token-2022 allows it and it cannot be turned off (on Mantle burning needs `BURN_ROLE`). Tokens burned on Solana stay locked in Mantle's LockRelease pool for good. This only affects the holder and is not a security issue; supply reconciliation therefore checks Solana total supply ≤ the amount locked in the Mantle pool rather than strict equality (`check-supply.ts`).
- Privileged roles are trusted with every token account of a mint, including the CCIP pool's own token account: freezing it (or clawing back from it, which leaves it frozen) stops Solana → Mantle transfers until it is thawed.
- Registration is an operations task (`MINT_REGISTRAR`, like the `OPS_ROLE` that deploys tokens through Mantle's `ScaledTokenFactory`). A compromised registrar key cannot register a mint with a back door (`register_mint` rejects any authority outside Core), touch existing mints, change roles, or create Mantle-backed tokens (which Mantle pool is linked to which mint is CCIP configuration); at worst it registers junk mints or claims an unused Mantle token for a wrong mint. Each Mantle token maps to one mint, and the Admin can unregister a mint only while its supply is 0, so a mistake is fixed before launch and a live mint can never be detached from Core. `register_mint` checks the mint's configuration, not its initial multiplier or supply; the launch procedure sets the initial multiplier to Mantle's and hands the mint authority to the CCIP pool.
- A proposed admin cannot be withdrawn, only replaced by proposing another address. If the new admin already holds a role, its role account remains but every operational instruction rejects the admin (`AdminCannotOperate`).
- An independent Solana audit before launch.

---

## 10. Review decisions

| # | Topic | Decision |
| --- | --- | --- |
| 1 | Multiplier sync | Option B: each chain schedules its own; CCIP only moves tokens |
| 2 | Permanent Delegate | Enabled, delegate = Authority PDA; `clawback` implemented, signed by the compliance admin (decided 2026-11-16) |
| 3 | Transfer Hook | Dormant (no program), authority held directly by the Squads multisig |
| 4 | Code location | This repo, `solana/` directory |
| 5 | Toolchain | Upgrade to Agave + Anchor 1.x |
| 6 | Role keys | As on Mantle: the operations roles' keys are held by RWA-Bycustody (registrar, scheduler, metadata, pauser); the freezer / unfreezer is Mantle's compliance backend KMS (Ed25519) |
| 7 | Compliance backend | Add Solana to the existing `mstocks-aml`, changing the EVM logic as little as possible (§11) |
| 8 | Thaw | Same as EVM: after removal from the blacklist the backend signer thaws automatically; `UNFREEZER` is held by the backend KMS |
| 9 | Mint registration | An operations role (`MINT_REGISTRAR`, KMS), like Mantle's factory `OPS_ROLE`, instead of the Admin multisig; one mint per Mantle token; Admin can unregister a mint with zero supply |
| 10 | Admins and time locks | Split and timed like Mantle: an admin for the token roles and the mint registry (multisig 1's group, 12 h), a compliance admin for the pause, freeze and clawback roles (multisig 4's group, 12 h), the upgrade authority with multisig 2's group (24 h), `UNPAUSER` with multisig 5's group (no time lock) |

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
- **Freezes that run out of retries**: a freeze that keeps failing (for example while the signer has no SOL) is retried with backoff and, after `sync_max_retries`, parked for a year. The reconciler also re-checks parked blacklisted wallets and the indexer requeues them on a new transfer, so once the cause is fixed the freeze lands within one `reconcile_interval` (fault test: signer drained to 0 SOL; frozen 34 s after funding it, with a 60 s interval).
- **Whether to send a transaction**: a wallet can be partly frozen, so the syncer checks against the target state: blacklisting requires no unfrozen accounts, unblacklisting requires no frozen ones; if already satisfied, nothing is sent. Core skips accounts already in the target state, so retries are safe. 20 accounts per transaction; priority fees configurable.
- **Addresses returned by the AML gateway**: the production gateway lowercases the addresses in its results. EVM addresses are unaffected, but Solana addresses are case-sensitive and become invalid, or even another wallet, when lowercased. The service only uses the result to map back to the address it requested, and always stores and queries the original address.
- **Thaw**: same as EVM. When the AML gateway no longer flags an address (on a recheck or a new transaction), the database marks it pending removal and the syncer thaws all its accounts with Core `thaw`, signed by the backend signer. By default the same key as freezing (it must hold both `FREEZER` and `UNFREEZER`); a separate `unfreezer` can be configured. As on EVM: an address frozen manually by ops but judged clean by AML is thawed automatically the next time the service processes it (e.g. when it appears in a new transaction).
- **Signing and startup checks**: production uses AWS KMS Ed25519 (`ED25519_SHA_512`, raw message), verified locally after signing. At startup the service checks that the signer holds the roles and that the configured mints are registered in Core. The signer pays its own fees and needs a SOL balance.
- **Changes to EVM code**: lowercasing addresses in the processor is now configurable (Solana addresses are case-sensitive, EVM still lowercases); the syncer gains an optional interface for target-state checks (the EVM client does not implement it, behavior unchanged); database migration 006 widens the address and transaction hash columns and adds a cursor table; pending transfers and recheck queries filter by chain (same results with a single chain); at startup a set of components runs for each enabled chain (`evm.enabled` defaults to on, existing configs need no change).

**Chain name:** the `solana.chain_name` setting (shared by the database and the AML gateway) is `solana` on mainnet and `solana_devnet` on devnet.

**qa8 deployment (live):** the existing `mantle-mstocks-aml` service on sepolia-qa8 runs EVM (Mantle mainnet mirror, production AML gateway) and Solana devnet (QA AML gateway `mantle-aml-gateway` sepolia-qa7, whose test blacklist drives the freeze tests); see [mantle-config#17082](https://github.com/mantlenetworkio/mantle-config/pull/17082) and [#17092](https://github.com/mantlenetworkio/mantle-config/pull/17092). Signing uses the KMS Ed25519 key shared with retry-service (`5dc8b92b`, address `E8SV8n…`), which holds `FREEZER` / `UNFREEZER` on devnet. Note: `mantle-manual-awsres` does not update the IAM role of an existing service, so ops must add a new KMS key to the role's `kmsAccess` by hand; qa8 deploys from the feature branch, and the deploy workflow's token needs read access to `mantle-xyz/mstocks-aml`.

**Monitoring:** the service exports the signer's balance as `solana_signer_balance_lamports`. The alert `mstocksAmlSolanaSignerBalanceLow` (monitoring-v2 `ccip` rules, [mantle-config#17165](https://github.com/mantlenetworkio/mantle-config/pull/17165); qa8 threshold 0.05 SOL) fires before the signer runs out of fees, because once it does, freeze transactions stop and blacklisted wallets keep moving tokens. Rules under `infra-infra` take effect only after ops run `kubectl apply -k` on them.

**Before launch:** a backend KMS Ed25519 key, granted `FREEZER` and `UNFREEZER` by the compliance admin (Squads), with a SOL balance for fees, and a mainnet threshold for the balance alert.

---

## 12. Companion service: CCIP retry service (mantle-cross)

The DON does not retry a message whose execution failed on the destination chain, so the tokens stay locked in the source pool until someone executes it. The existing CCIP retry service (`mantle-cross`, `packages/auto-retry-service`) watches the OffRamps of the configured chains for failed messages of the watched tokens, classifies each failure and re-executes the retryable ones.

| Change | What it does | Where |
| --- | --- | --- |
| Per-token gas retry | A failure where the destination pool runs out of per-token gas (`TokenHandlingError` with an empty reason, `FailedCall`, `NotEnoughGasForCall` or `SafeERC20: low-level call failed`) is classified `TOKEN_OOG` and re-executed with `tokenGasOverrides` = the message's `destGasAmount` × the gas ladder (first retry 1.5×, i.e. 135,000 for the lane default). A simulation that still runs out of gas moves up the ladder; any other simulation failure relabels it `TOKEN_ERROR`. Previously every token failure was `TOKEN_ERROR` and parked | [mantle-cross#48](https://github.com/mantle-xyz/mantle-cross/pull/48) |
| Signer balance monitor | Exports `ccip_retry_signer_balance{chain,chain_selector,address}` and the per-chain threshold `ccip_retry_signer_balance_min`; the alert `retrySignerBalanceLow` fires when a signer drops below its chain's `min_signer_balance` | [mantle-cross#49](https://github.com/mantle-xyz/mantle-cross/pull/49), [mantle-config#17148](https://github.com/mantlenetworkio/mantle-config/pull/17148) |
| qa8 configuration | Adds Mantle Sepolia and the test token `0x5a338AD5…`; thresholds Sepolia 0.02 ETH, HyperEVM 0.02 HYPE, Solana 0.5 SOL, Mantle Sepolia 5 MNT | [mantle-config#17144](https://github.com/mantlenetworkio/mantle-config/pull/17144), [#17148](https://github.com/mantlenetworkio/mantle-config/pull/17148) |

On Mantle, failures that need a fix first (token paused, receiver sanctioned, inbound rate limit exceeded) stay `TOKEN_ERROR` and are not retried automatically: once the cause is removed, operations run `ccip-manual-exec-evm.sh`. Messages that failed on Solana (mint paused, receiver account frozen, rate limit exceeded) are executed with `ccip-manual-exec.ts`. The service's rate-limit monitor only exports pool bucket metrics (`ccip_ratelimit_*`); it does not re-execute anything.

**Before launch:** the mainnet configuration (Mantle mainnet chain, every launched mStocks token on the watch list, signer funding in MNT, `signer_balance_monitor` with mainnet thresholds).
