# mStocks on Solana

Solana side of mStocks: one Anchor program (`mstocks-core`) plus scripts that create and configure
Token-2022 mints. Design: [docs/solana-core-design.md](../docs/solana-core-design.md).

Every privileged Token-2022 authority of an mStocks mint (multiplier, pause, freeze, metadata,
permanent delegate) is held by Core's authority PDA and exercised only through role-checked
instructions that mirror the Mantle contracts. Mantle is the issuing chain and CCIP runs lock/mint:
a LockRelease pool on Mantle locks and releases, and the BurnMint pool on Solana — the only minter
— mints and burns, so Solana's supply always equals the amount locked on Mantle (÷1e9). The
Transfer Hook extension is present but dormant and controlled by a Squads multisig.

## Layout

```
programs/mstocks-core/   Anchor program + LiteSVM integration tests (tests/core.rs)
scripts/                 Deployment / operations scripts (TypeScript, @solana/kit)
tests/fixtures/          Mainnet Token-2022 binary used by tests (fetched, gitignored)
```

## Toolchain

| Tool | Version |
| --- | --- |
| Agave (Solana CLI, `cargo build-sbf`) | 4.4.0 |
| Anchor CLI / anchor-lang | 1.2.2 |
| Rust (host, pinned by `rust-toolchain.toml`) | 1.97.1 |
| Node | ≥ 20 |

## Build and test

```bash
anchor build                       # program + IDL (target/idl/mstocks_core.json; the scripts read the committed copy idl/mstocks_core.json, which program.ts build checks against the build)
scripts/fetch-fixtures.sh          # mainnet Token-2022 → tests/fixtures/token2022.so
cargo test -p mstocks-core         # LiteSVM integration tests
npm install && npm run local-e2e   # every script end-to-end on a local validator
scripts/test-check-multiplier.sh   # reconciliation against a real ScaledToken on anvil
scripts/test-check-supply.sh       # supply reconciliation: backed → exit 0, over-minted → exit 1
cargo fmt --check && cargo clippy -p mstocks-core --all-targets -- -D warnings
```

CI (`.github/workflows/solana.yml`) runs rustfmt, `cargo build-sbf`, clippy, the LiteSVM tests and a
typecheck of the scripts on every change under `solana/`. CI installs with Node 22's npm 10, which
keeps a nested `typescript@5` for `@solana/web3.js` in the lockfile that npm 11 drops; after changing
dependencies, refresh the lockfile with `npx npm@10 install --package-lock-only`.

## Network configuration

`config.mainnet.toml` (Solana mainnet ↔ Mantle) and `config.testnet.toml` (Solana devnet ↔ Mantle
Sepolia) hold everything that is not a secret, with the same keys in both:

| Section | Holds |
| --- | --- |
| `[solana]` | public RPC, an RPC that allows `getProgramAccounts`, Solana's CCIP chain selector |
| `[mantle]` | chain id, public RPC, Mantle's CCIP chain selector, Router, RMN, TokenAdminRegistry, RegistryModuleOwnerCustom, the expected token admin (multisig 1's timelock) and the pool owner (multisig 1's Safe) |
| `[program]`, `[admins]`, `[roles]` | program id and limits, the Squads multisigs, the role holders |
| `[ccip]` | the Solana CCIP token admin and pool owner (the admin's Squads) |

`NETWORK=mainnet|testnet` selects one, for the TypeScript scripts (`lib/config.ts`) and the Mantle
bash scripts (`lib/config.sh`) alike; a command-line value still overrides it. A network-specific
address lives only in these files, so a new deployment or a changed Chainlink address is a one-line
config change. The operator's whole environment is:

```bash
export NETWORK=mainnet           # or testnet
export RPC_URL=...               # provider URL with an API key (keys never go in files); optional
export DEPLOYER=...              # deployer keypair file or private key (base58 / JSON array), for program.ts and init-core.ts
```

Without `NETWORK` the TypeScript scripts are in local mode (every address on the command line, RPC =
a local validator), which the local tests use; the Mantle scripts (`ccip-mantle-setup.sh`,
`ccip-send-evm.sh`, `ccip-manual-exec-evm.sh`) refuse to run without it. `NETWORK` may also be a
path to a `.toml` file. `MANTLE_RPC_URL` overrides `[mantle].rpc`.

Commands that work from the config alone:

| Command | Does |
| --- | --- |
| `program.ts build` / `deploy` / `verify` / `handoff` / `upgrade` / `idl` | `DEPLOYER` (or `--deployer <kp>`) signs. Build and test; first deployment with the IDL uploaded; verify the program bytes and the IDL; upgrade authority → the upgrade multisig (only after `init-core`); upgrade: program buffer and, when the IDL changed, an IDL buffer handed to the vault, then one base58 transaction message for the Squads app that upgrades the program and replaces (or creates) the IDL; `idl` updates the IDL alone. `upgrade` and `idl` check the Squads message fits before spending anything |
| `init-core.ts` | Initialize with the config's admins and hook authority, signed by `DEPLOYER` (or `--upgrade-authority <kp>`) |
| `sync-roles.ts [--dry-run]` | Grant every configured role holder that is missing and revoke every holder not configured, one transaction or Squads action per admin (split into `1/n`, `2/n`, … when too large; import each) |
| `check-config.ts` | Config vs chain: admins, upgrade authority, every role holder |
| `create-mint.ts --payer <kp> --mantle-token <0x..> --uri <uri>` | Name, symbol, ISIN and initial multiplier read from the Mantle token |
| `check-stock.ts --mint <mint>` | Every check of a launched stock: authorities, CCIP admin and pool owner, Mantle verify, multiplier, supply |
| `squads.ts … --multisig admin` | Config names for multisigs: `admin`, `compliance_admin`, `upgrade_authority`, `unpauser`, `ccip_admin` |

## Scripts

Admin and multisig-held steps (`--admin`, `--compliance-admin`, `--operator` of a multisig role,
ccip-handoff's `--to`) accept:

- `<keypair.json>`: signs and sends (devnet / local);
- a **Squads v4 multisig account address** (mainnet): its vault (index 0) is the signer. The
  script signs nothing: it prints the action as a list of instructions (what the members approve)
  and as a base58 **transaction message** (legacy, the vault as payer and only signer — the format
  of the Squads app's "Import base58 encoded tx", which takes a message, not a transaction). A member
  imports it into the Squads app (TX Builder → Create transaction → Add instruction → Import base58
  encoded tx; Squads' open-source client: Import Transaction) to create the proposal, the
  members approve it with their Ledgers, and it is executed after the multisig's time lock;
- any other address (e.g. the vault itself): the same, with that address as signer.

Addresses stored as signers (`init-core.ts` admins and hook authority, `create-mint.ts
--hook-authority`, a role `--member`, `check-config.ts` config entries) are converted the same
way: a multisig account becomes its vault, since a multisig account cannot sign and storing one
would brick that authority. In a proposal the vault also pays rent, so keep some SOL in each vault.

```bash
NETWORK=mainnet tsx scripts/grant-role.ts --role MintRegistrar --member <registrar>
#   grant MintRegistrar to … : signed by the Squads multisig … (vault …);
#     import the base58 transaction message below into the Squads app (TX Builder → … → Import base58 encoded tx), 1 instruction(s):
#     1. Core grant_role: role MintRegistrar, member … [payer …, admin …]
#   grant MintRegistrar to … base58: 4h3…        ← paste into the Squads app, approve with the Ledgers
tsx scripts/squads.ts status --multisig admin    # anyone: recent proposals, approvals, time lock left
```

With test multisigs whose members are key files, `squads.ts propose --base58 <…> --member <kp>`
imports the same message the way the app does (decoded exactly as in Squads' open-source client), and `approve` / `execute` follow;
`local-squads-e2e.sh` runs every multisig action like this.

`scripts/local-squads-e2e.sh` rehearses this on a local validator with the mainnet Squads v4
and Program Metadata programs (`scripts/fetch-fixtures.sh` dumps them).

| Script | Who signs | Purpose |
| --- | --- | --- |
| `program.ts` | Deployer, then the upgrade multisig | `build` (anchor build + tests + sha256), `deploy` (first deployment, IDL upload, byte and IDL comparison), `verify` (program bytes and on-chain IDL against the build), `handoff` (upgrade authority → the config's upgrade multisig vault; refused before `init-core`), `upgrade` (extends the program account first when the build is larger, then program buffer + IDL buffer → vault → one Squads message upgrading the program and the IDL), `idl` (the IDL alone; directly while the deployer is the upgrade authority; also finishes an interrupted upload). The IDL lives where Anchor 1.x keeps it: the program's canonical account in Solana's Program Metadata program, written only by the upgrade authority (`anchor idl fetch` reads it); `--so <file>` overrides the build for `upgrade` / `verify` |
| `sync-roles.ts` | Admin and compliance admin | Make the on-chain role holders match the config: grants and revokes, one transaction or Squads action per admin, split in order when too large for one (`--dry-run` lists them) |
| `check-stock.ts` | — | Every check of one launched stock against the config, PASS / FAIL |
| `init-core.ts` | Program upgrade authority | One-time setup: admin (Squads, Mantle multisig 1's role), compliance admin (Squads, multisig 4's role) and hook authority (Squads). On mainnet: deploy with the deployer as upgrade authority, run this, then transfer the upgrade authority to the upgrade multisig's vault (Squads, 24 h time lock). Pass multisig addresses; they are stored as their vaults |
| `grant-role.ts` | Admin or compliance admin | Grant a role. The admin grants `MultiplierScheduler`, `MetadataOps`, `MintRegistrar`; the compliance admin grants `Pauser`, `Unpauser`, `Freezer`, `Unfreezer`. The script checks on chain that `--admin` governs the role before it sends or proposes (with a multisig, Core would only reject it when the proposal executes) |
| `create-mint.ts` | Deployer + `MintRegistrar` (`--registrar`, defaults to the deployer) | Create a mint with all extensions and metadata (incl. ISIN) and `register_mint` it, in one transaction (all or nothing; about 1130 bytes when the registrar is the payer, so keep the URI short). A Mantle token can be registered for one mint only. The instructions come from `lib/mint.ts`, the backend's reference; `--dry-run` prints them byte for byte and sends nothing |
| `unregister-mint.ts` | Admin | Undo a registration made in error (wrong mint or Mantle token) so it can be redone; only while the mint's supply is 0 and its mint authority is a plain key: never once the CCIP pool can mint (its signer or the mint authority multisig holds the authority) |
| `schedule-multiplier.ts` | `MultiplierScheduler` | Schedule the same `(multiplier, effectiveAt)` sent to Mantle |
| `check-multiplier.ts` | — | Reconcile each mint's multiplier with its Mantle `ScaledToken` (address read from Core); exits 1 on mismatch for alerting. Needs `MANTLE_RPC_URL` |
| `check-config.ts` | — | Check a deployment against `config.mainnet.toml` / `config.testnet.toml`: admins, hook authority, notice and horizon, the program's upgrade authority, and every role's holders (no missing, no extra; the retired Clawback has none). Exits 1 on a problem. Listing holders needs `getProgramAccounts` (`--roles-rpc`) |
| `check-supply.ts` | — | Check each mint's Solana supply against the tokens locked in its Mantle pool (token from Core, pool from `--registry`, the Mantle TokenAdminRegistry); exits 1 if Solana holds more than is locked. Needs `MANTLE_RPC_URL` |
| `ccip-mantle-setup.sh` | Deployer, then the multisigs | Mantle side of CCIP for one token: `deploy` the LockRelease pool (pinned CCIP 1.6.4) and point it at Solana; `multisig` writes Safe Transaction Builder files for the token admin's timelock (CCIP admin registration, `setPool`) and the pool owner — when the pool owner is a proposer of that timelock (multisig 1's Safe), its acceptance is in the schedule file, so the Safe signs twice; `verify` (also checks the token admin against `[mantle].token_admin`). Network constants and the default pool owner come from the config; `NETWORK` is required. Key files (here and in `ccip-send-evm.sh`, `ccip-manual-exec-evm.sh`) may be a Foundry keystore (password file in `ETH_PASSWORD`, else asked for), which keeps the key out of the process arguments; prefer it on mainnet over a raw hex key file |
| `ccip-handoff.ts` | Deployer, then Squads | Hand a mint's CCIP token admin and BurnMint pool ownership to the Squads vault: proposes, then signs the acceptance (keypair) or prints both acceptances as one base58 transaction message for the Squads app (multisig address). `ccip-register.ts --handoff-to` does the same; re-run this to confirm the handoff |
| `handoff-mint-authority.ts` | Deployer (current mint authority) | Give the mint authority to the 1-of-2 Token-2022 multisig of the CCIP pool signer and the admin's vault (`--mint-authority-admin`, default the config's admin), after checking the multisig and that the pool's lookup table lists it (dry run unless `--yes`); `ccip-register.ts --handoff-mint-authority` does it as part of the registration |
| `move-mint-authority.ts` | Admin (the multisig's other member; a Squads multisig creates a proposal) | Escape hatch when the pool was set up wrong or Chainlink retires it: move the mint authority from that multisig to `--to`, without Chainlink — the admin's vault first (a new pool's initialization needs the mint authority), then the new pool's multisig. Prints whether the target is a token multisig and its members |
| `ccip-register.ts` | Deployer (current mint authority) | Register the mint with CCIP for one remote EVM chain in three transactions: (0) the mint authority multisig (1 of 2: the pool signer and `--mint-authority-admin`, default the config's admin); (1) token admin (propose + accept), BurnMint pool, pool token account, pool lookup table (listing the multisig, where the pool finds it); (2) remote chain (token, pool, decimals), rate limits, `set_pool`, freezing the lookup table (its authority, the registering key, could otherwise close it and stop every transfer), and with `--handoff-to <multisig>` the proposals to the multisig, with `--handoff-mint-authority` the mint authority to the multisig. Then the multisig's acceptance as one base58 transaction message for the Squads app. Skips steps already done; rate limits need `--rate-capacity`/`--rate-per-second` or `--no-rate-limit` when the remote chain is first configured, and a re-run without them leaves them as they are |
| `ccip-send.ts` | Token holder | Send tokens to an EVM address through CCIP, paying in SOL (testing / ops checks) |
| `ccip-send-evm.sh` | Token holder on Mantle | The other direction: send a Mantle token to a Solana wallet through CCIP, paying in MNT; prints the message id. Router, selector and RPC from the config (`NETWORK` required) |
| `ccip-manual-exec.ts` | Anyone (pays the fee) | Re-execute an inbound CCIP message whose automatic execution failed (e.g. it arrived while the mint was paused; the DON does not retry), from the failed execution transaction. Allowed 20 minutes after the commit; a second run is skipped by the OffRamp |
| `ccip-manual-exec-evm.sh` | Anyone (pays the gas) | Same for the Mantle side (Solana → Mantle): re-execute a message whose execution failed (Mantle token paused, receiver sanctioned, inbound rate limit, or out of gas), from the failed execution transaction. `TOKEN_GAS` raises the per-token gas above the lane default of 150,000, e.g. 225000. RPC from the config (`NETWORK` required) |
| `devnet-ccip-smoke.sh` | Role keys + a holder | Basic-function smoke on a CCIP-connected mint against devnet and Mantle Sepolia: transfer, pause, freeze, clawback, metadata, the same multiplier on both chains, `ccip_send` after it, holder burn |
| `pause.ts` | `Pauser` / `Unpauser` (`--resume`) | Pause or resume one mint (the mainnet Unpauser is a multisig: `--resume` prints the base58 for the Squads app) |
| `pause-all.ts` | `Pauser` | Emergency pause of every registered mint, 8 per transaction (`--dry-run` lists them; `--mints` if the RPC rejects `getProgramAccounts`: unregistered entries are skipped). A failed batch does not stop the others; exit code 1 if any mint is left unpaused |
| `freeze.ts` | `Freezer` / `Unfreezer` (`--thaw`) | Freeze or thaw token accounts, 20 per transaction; `--owner <wallet>` finds every account the wallet holds for the mint (what the backend does on blacklisting) |
| `clawback.ts` | Compliance admin (`--compliance-admin`; a Squads multisig creates a proposal) | Move tokens from an account to custody as permanent delegate; the source ends frozen. Freeze the account first |
| `update-metadata.ts` | `MetadataOps` | Update name / symbol / uri / any key (e.g. isin); tops up the mint's rent first; refuses a symbol Mantle would reject |
| `revoke-role.ts` | Admin or compliance admin | Revoke a role (the admin that governs it) |
| `set-default-account-state.ts` | Admin | Compliance policy switch: new token accounts start frozen (`--frozen`) or usable (default) |
| `squads.ts` | Anyone / test members | `status` (members, threshold, time lock, recent proposals); `memo` (a practice proposal: the vault signs a Memo and nothing changes, so members can try the import and their Ledgers first; on devnet use backup.app.squads.so, app.squads.so is mainnet only). For test multisigs with key-file members: `create`, `propose --base58` (import as the Squads app does), `approve` / `reject` / `execute` |
| `local-squads-e2e.sh` | — | Runbook rehearsal with real Squads multisigs on a local validator: init, roles (a split sync), check-config, resume, clawback, unregister, moving the mint authority out of its multisig, the IDL (direct, interrupted upload, created by the vault), a program upgrade, and the negative cases |
| `show-mint.ts` / `show-account.ts` | — | Print a mint's configuration / a token account's balance and state |
| `dev-mint-to.ts` | Mint authority | Local/devnet only: mint before the CCIP handoff |

## Devnet

Core is deployed on devnet at `3jBxe42f83ruvVZsoCQdgMtGc6nSEGGpkia2Egm6tbwd` (upgrade authority:
the deployer key). `scripts/devnet-smoke.sh` runs every script against it with persistent test keys
in `~/.config/solana/mstocks-devnet/` and creates a fresh test mint on each run:

```bash
RPC_URL=<devnet rpc url> scripts/devnet-smoke.sh
```

Scripts send over HTTP and poll for confirmation (no WebSocket needed) and retry on HTTP 429.
Keep provider URLs with API keys in the environment only. Some providers reject
`getProgramAccounts`; pass `pause-all.ts --mints a,b,c` there.

## Launching a stock

With the Mantle token already in place and `NETWORK` set, a stock takes three Solana transactions,
one Mantle command and one approval round from each multisig:

1. `create-mint.ts --payer <MintRegistrar kp> --mantle-token <token> --uri <uri>` (on mainnet a backend
   sends the same transaction; TD §6 lists its instructions, and the runbook starts from the
   registered mint): one transaction
   creates, configures and registers the mint; name, symbol, ISIN and the initial multiplier come
   from the Mantle token. If Mantle has a pending multiplier, run `schedule-multiplier.ts` with the
   same values right after.
2. Mantle pool: `ccip-mantle-setup.sh deploy <deployer key> <token> <mint> --rate-capacity …
   --rate-per-second …` deploys the LockRelease pool, points it at the Solana pool and mint, sets
   rate limits and proposes the config's pool owner (one command, three transactions).
3. `ccip-register.ts --authority <kp> --mint <mint> --remote-token <token> --remote-pool <pool>
   --rate-capacity … --rate-per-second … --handoff-to --handoff-mint-authority`: three transactions
   create the mint authority multisig (1 of 2: the pool signer and the config's admin), register the
   mint with CCIP, propose the config's CCIP admin multisig as token admin and pool owner and give
   the mint authority to the multisig (the pool mints through it; the admin can move it to a
   replacement pool with `move-mint-authority.ts`); then one base58 transaction message for the
   Squads app holds the multisig's two acceptances.
4. Multisigs. Mantle: `ccip-mantle-setup.sh multisig <token> <pool>` writes two Safe Transaction
   Builder files: the first schedules the timelock batch (CCIP admin registration, `setPool`) and
   accepts the pool's ownership, the second executes the batch after the delay. Solana: the multisig
   imports the base58 from step 3 into the Squads app, approves it and executes it after the time lock.
5. `check-stock.ts --mint <mint>`: PASS when every authority, the CCIP roles on both chains, the
   multiplier and the supply are right.

The whole sequence was rehearsed on Mantle Sepolia ↔ Solana devnet with a token whose admin is a
timelock, as on mainnet (TD §6.2): step by step on 2026-11-16, and in this packed form on 2026-11-17
(create 1091 bytes; registration 1067 + 879 bytes). The mint authority multisig was rehearsed the same
way on 2026-11-25 (registration 434 + 1,099 + 827 bytes without `--handoff-to`): the DON minted
through the multisig, and the admin alone moved the authority out and back.

Steps 2–3 ran on Solana devnet ↔ Mantle Sepolia (2026-11-10) with a throwaway token on each side:
Mantle → Solana delivered 1 token in about 24 minutes (CCIP waits for Mantle finality, about 25
minutes behind the head); Solana → Mantle released 0.5 in under a minute. Both chains use the same
onRamp / offRamp for every lane:

| | Solana devnet | Mantle Sepolia |
| --- | --- | --- |
| Chain selector | `16423721717087811551` | `8236463271206331221` |
| Router | `Ccip842gzYHhvdDkSyi2YVCoAWPbYJoApMFzSxQroE9C` | `0xFd33fd627017fEf041445FC19a2B6521C9778f86` |
| OnRamp | the Router | `0xCAC5826F878b3BfEE32404619C762b33ae199c1b` |
| OffRamp | `offqSMQWgQud6WJz694LRzkeN5kMYpCHTpXQr3Rkcjm` | `0x4d8193f845Eb3540e0BdA9451296600362E22B15` |
| Token pool | BurnMint program `41FGToCmdaWa1dgZLKFAjvmx6e6AjVTX7SVRibvsMGVB` (same as mainnet) | LockRelease via Token Pool Factory `0x9fCd83bC7F67ADa1fB51a4caBEa333c72B641bd1` |
| Registry | token admin registry in the Router | Token Admin Registry `0x0F1eE88A582f31d92510E300fc1330AA5a525D51`, Registry Module `0xf76cE612250eeEb8889F49FBCB11f1c2705305F6` |
| Fee tokens | LINK, WSOL | LINK, WMNT |

Source: the [CCIP directory](https://docs.chain.link/ccip/directory/testnet/chain/solana-devnet).
