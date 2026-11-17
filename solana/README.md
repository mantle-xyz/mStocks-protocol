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
anchor build                       # program + IDL (target/idl/mstocks_core.json)
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

## Scripts

Admin and multisig-held steps (`--admin`, `--compliance-admin`, `--operator` of a multisig role,
ccip-handoff's `--to`) accept:

- `<keypair.json>`: signs and sends (devnet / local);
- a **Squads v4 multisig account address** (mainnet): its vault (index 0) is the signer. With
  `--squads-member <member keypair>` (or `SQUADS_MEMBER`) the script creates the vault transaction
  and its proposal, approved by that member; the other members then approve and execute with
  `squads.ts` (or the Squads app) after the multisig's time lock. Without a member key it prints
  the instruction instead;
- any other address (e.g. the vault itself): prints the instruction for a Squads proposal.

Addresses stored as signers (`init-core.ts` admins and hook authority, `create-mint.ts
--hook-authority`, a role `--member`, `check-config.ts` config entries) are converted the same
way: a multisig account becomes its vault, since a multisig account cannot sign and storing one
would brick that authority. In a proposal the vault also pays rent, so keep some SOL in each vault.

```bash
tsx scripts/grant-role.ts --payer <kp> --admin <admin multisig> --role MintRegistrar --member <registrar> \
  --squads-member <member kp>                 # → Squads proposal #N, approved by the proposer
tsx scripts/squads.ts approve --multisig <admin multisig> --index N --member <another member kp>
tsx scripts/squads.ts status  --multisig <admin multisig> --index N   # approvals, time lock left
tsx scripts/squads.ts execute --multisig <admin multisig> --index N --member <member kp>
```

`scripts/local-squads-e2e.sh` rehearses this on a local validator with the mainnet Squads v4
program (`scripts/fetch-fixtures.sh` dumps it).

| Script | Who signs | Purpose |
| --- | --- | --- |
| `init-core.ts` | Program upgrade authority | One-time setup: admin (Squads, Mantle multisig 1's role), compliance admin (Squads, multisig 4's role) and hook authority (Squads). On mainnet: deploy with the deployer as upgrade authority, run this, then transfer the upgrade authority to the upgrade multisig's vault (Squads, 24 h time lock). Pass multisig addresses; they are stored as their vaults |
| `grant-role.ts` | Admin or compliance admin | Grant a role. The admin grants `MultiplierScheduler`, `MetadataOps`, `MintRegistrar`; the compliance admin grants `Pauser`, `Unpauser`, `Freezer`, `Unfreezer`. The script checks on chain that `--admin` governs the role before it sends or proposes (with a multisig, Core would only reject it when the proposal executes) |
| `create-mint.ts` | Deployer + `MintRegistrar` (`--registrar`, defaults to the deployer) | Create a mint with all extensions and metadata (incl. ISIN) and `register_mint` it, in one transaction (all or nothing; about 1130 bytes when the registrar is the payer, so keep the URI short). A Mantle token can be registered for one mint only |
| `unregister-mint.ts` | Admin | Undo a registration made in error (wrong mint or Mantle token) so it can be redone; only while the mint's supply is 0 |
| `schedule-multiplier.ts` | `MultiplierScheduler` | Schedule the same `(multiplier, effectiveAt)` sent to Mantle |
| `check-multiplier.ts` | — | Reconcile each mint's multiplier with its Mantle `ScaledToken` (address read from Core); exits 1 on mismatch for alerting. Needs `MANTLE_RPC_URL` |
| `check-config.ts` | — | Check a deployment against `config.mainnet.toml` / `config.devnet.toml`: admins, hook authority, notice and horizon, the program's upgrade authority, and every role's holders (no missing, no extra; the retired Clawback has none). Exits 1 on a problem. Listing holders needs `getProgramAccounts` (`--roles-rpc`) |
| `check-supply.ts` | — | Check each mint's Solana supply against the tokens locked in its Mantle pool (token from Core, pool from `--registry`, the Mantle TokenAdminRegistry); exits 1 if Solana holds more than is locked. Needs `MANTLE_RPC_URL` |
| `ccip-mantle-setup.sh` | Deployer, then the multisigs | Mantle side of CCIP for one token: `deploy` the LockRelease pool (pinned CCIP 1.6.4) and point it at Solana; `multisig` writes Safe Transaction Builder files for the token admin's timelock (CCIP admin registration, `setPool`) and the pool owner — when the pool owner is a proposer of that timelock (multisig 1's Safe), its acceptance is in the schedule file, so the Safe signs twice; `verify`. `NETWORK=mainnet` (default) or `testnet`; needs `MANTLE_RPC_URL` |
| `ccip-handoff.ts` | Deployer, then Squads | Hand a mint's CCIP token admin and BurnMint pool ownership to the Squads vault: proposes, then signs the acceptance (keypair) or puts both acceptances in one Squads proposal (multisig address). `ccip-register.ts --handoff-to` does the same; re-run this without a member key to confirm the handoff |
| `handoff-mint-authority.ts` | Deployer (current mint authority) | Give the mint authority to the CCIP pool signer PDA (dry run unless `--yes`); `ccip-register.ts --handoff-mint-authority` does it as part of the registration |
| `ccip-register.ts` | Deployer (current mint authority) | Register the mint with CCIP for one remote EVM chain in two transactions: (1) token admin (propose + accept), BurnMint pool, pool token account, pool lookup table; (2) remote chain (token, pool, decimals), rate limits, `set_pool`, and with `--handoff-to <multisig>` the proposals to the multisig, with `--handoff-mint-authority` the mint authority to the pool. Then the multisig's acceptance as one Squads proposal (`--squads-member`). Skips steps already done |
| `ccip-send.ts` | Token holder | Send tokens to an EVM address through CCIP, paying in SOL (testing / ops checks) |
| `ccip-send-evm.sh` | Token holder on Mantle | The other direction: send a Mantle token to a Solana wallet through CCIP, paying in MNT; prints the message id |
| `ccip-manual-exec.ts` | Anyone (pays the fee) | Re-execute an inbound CCIP message whose automatic execution failed (e.g. it arrived while the mint was paused; the DON does not retry), from the failed execution transaction. Allowed 20 minutes after the commit; a second run is skipped by the OffRamp |
| `ccip-manual-exec-evm.sh` | Anyone (pays the gas) | Same for the Mantle side (Solana → Mantle): re-execute a message whose execution failed (Mantle token paused, receiver sanctioned, inbound rate limit, or out of gas), from the failed execution transaction. `TOKEN_GAS` raises the per-token gas, e.g. 150000 for a receiver that has never held the token |
| `devnet-ccip-smoke.sh` | Role keys + a holder | Basic-function smoke on a CCIP-connected mint against devnet and Mantle Sepolia: transfer, pause, freeze, clawback, metadata, the same multiplier on both chains, `ccip_send` after it, holder burn |
| `pause.ts` | `Pauser` / `Unpauser` (`--resume`) | Pause or resume one mint (the mainnet Unpauser is a multisig: `--operator <multisig> --squads-member <kp>`) |
| `pause-all.ts` | `Pauser` | Emergency pause of every registered mint, 8 per transaction (`--dry-run` lists them; `--mints` if the RPC rejects `getProgramAccounts`) |
| `freeze.ts` | `Freezer` / `Unfreezer` (`--thaw`) | Freeze or thaw token accounts, 20 per transaction; `--owner <wallet>` finds every account the wallet holds for the mint (what the backend does on blacklisting) |
| `clawback.ts` | Compliance admin (`--compliance-admin`; a Squads multisig creates a proposal) | Move tokens from an account to custody as permanent delegate; the source ends frozen. Freeze the account first |
| `update-metadata.ts` | `MetadataOps` | Update name / symbol / uri / any key (e.g. isin); tops up the mint's rent first |
| `revoke-role.ts` | Admin or compliance admin | Revoke a role (the admin that governs it) |
| `set-default-account-state.ts` | Admin | Compliance policy switch: new token accounts start frozen (`--frozen`) or usable (default) |
| `squads.ts` | Squads members | `create` a multisig (test / rehearsal), `status` (members, threshold, time lock, recent proposals), `approve` / `reject` / `execute` a proposal, `upgrade` (propose a Core upgrade from a buffer whose authority is the vault) |
| `local-squads-e2e.sh` | — | Runbook rehearsal with real Squads multisigs on a local validator: init, roles, check-config, resume, clawback, unregister, a program upgrade, and the negative cases |
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

With the Mantle token already in place, a stock takes three transactions from the operators and
one approval round from each multisig:

1. `create-mint.ts` with `--initial-multiplier-1e18` = Mantle `uiMultiplier()`: one transaction
   creates, configures and registers the mint. If Mantle has a pending multiplier, run
   `schedule-multiplier.ts` with the same values right after.
2. Mantle pool: `ccip-mantle-setup.sh deploy <deployer key> <token> <mint> <pool-owner multisig>
   --rate-capacity … --rate-per-second …` deploys the LockRelease pool, points it at the Solana pool
   and mint, sets rate limits and proposes the multisig as owner (one command, three transactions).
3. `ccip-register.ts` with the Mantle token, the pool from step 2, the Mantle chain selector,
   `--handoff-to <admin multisig> --handoff-mint-authority --squads-member <kp>`: two transactions
   register the mint with CCIP, propose the multisig as token admin and pool owner and give the mint
   authority to the pool (the pool signer becomes the only minter); then one Squads proposal holds
   the multisig's two acceptances.
4. Multisigs. Mantle: `ccip-mantle-setup.sh multisig <token> <pool> <pool-owner>` writes two Safe
   Transaction Builder files: the first schedules the timelock batch (CCIP admin registration,
   `setPool`) and accepts the pool's ownership, the second executes the batch after the delay.
   Solana: the multisig approves and executes the proposal from step 3 (`squads.ts`); then re-run
   `ccip-handoff.ts --to <admin multisig>` without a member key to confirm.
5. `ccip-mantle-setup.sh verify <token> <pool> <mint>` and `show-mint.ts` to confirm the final
   configuration.

The whole sequence was rehearsed on Mantle Sepolia ↔ Solana devnet with a token whose admin is a
timelock, as on mainnet (TD §6.2): step by step on 2026-11-16, and in this packed form on 2026-11-17
(create 1091 bytes; registration 1067 + 879 bytes).

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
