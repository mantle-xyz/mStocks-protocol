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
typecheck of the scripts on every change under `solana/`.

## Scripts

Admin steps accept `--admin <keypair.json>` (devnet/local: signs directly) or `--admin <pubkey>`
(mainnet: prints the instruction to submit as a Squads proposal, with the vault as payer).

| Script | Who signs | Purpose |
| --- | --- | --- |
| `init-core.ts` | Program upgrade authority | One-time setup: admin (Squads, Mantle multisig 1's role), compliance admin (Squads, multisig 4's role) and hook authority (Squads). On mainnet: deploy with the deployer as upgrade authority, run this, then transfer the upgrade authority to Squads + Timelock |
| `grant-role.ts` | Admin or compliance admin | Grant a role. The admin grants `MultiplierScheduler`, `MetadataOps`, `MintRegistrar`; the compliance admin grants `Pauser`, `Unpauser`, `Freezer`, `Unfreezer` |
| `create-mint.ts` | Deployer + `MintRegistrar` (`--registrar`, defaults to the deployer) | Create a mint with all extensions and metadata (incl. ISIN), then `register_mint`. A Mantle token can be registered for one mint only |
| `unregister-mint.ts` | Admin | Undo a registration made in error (wrong mint or Mantle token) so it can be redone; only while the mint's supply is 0 |
| `schedule-multiplier.ts` | `MultiplierScheduler` | Schedule the same `(multiplier, effectiveAt)` sent to Mantle |
| `check-multiplier.ts` | — | Reconcile each mint's multiplier with its Mantle `ScaledToken` (address read from Core); exits 1 on mismatch for alerting. Needs `MANTLE_RPC_URL` |
| `check-config.ts` | — | Check a deployment against `config.mainnet.toml` / `config.devnet.toml`: admins, hook authority, notice and horizon, the program's upgrade authority, and every role's holders (no missing, no extra; the retired Clawback has none). Exits 1 on a problem. Listing holders needs `getProgramAccounts` (`--roles-rpc`) |
| `check-supply.ts` | — | Check each mint's Solana supply against the tokens locked in its Mantle pool (token from Core, pool from `--registry`, the Mantle TokenAdminRegistry); exits 1 if Solana holds more than is locked. Needs `MANTLE_RPC_URL` |
| `ccip-mantle-setup.sh` | Deployer, then the multisigs | Mantle side of CCIP for one token: `deploy` the LockRelease pool (pinned CCIP 1.6.4) and point it at Solana; `multisig` writes Safe Transaction Builder files for the token admin's timelock (CCIP admin registration, `setPool`) and the pool owner; `verify`. `NETWORK=mainnet` (default) or `testnet`; needs `MANTLE_RPC_URL` |
| `ccip-handoff.ts` | Deployer, then Squads | Hand a mint's CCIP token admin and BurnMint pool ownership to the Squads vault: proposes, then signs the acceptance (keypair) or prints it for a Squads proposal (vault address) |
| `handoff-mint-authority.ts` | Deployer (current mint authority) | Give the mint authority to the CCIP pool signer PDA (dry run unless `--yes`) |
| `ccip-register.ts` | Deployer (current mint authority) | Register the mint with CCIP for one remote EVM chain: token admin (propose + accept), BurnMint pool, pool token account, remote chain (token, pool, decimals), rate limits, pool lookup table, `set_pool`. Skips steps already done |
| `ccip-send.ts` | Token holder | Send tokens to an EVM address through CCIP, paying in SOL (testing / ops checks) |
| `ccip-send-evm.sh` | Token holder on Mantle | The other direction: send a Mantle token to a Solana wallet through CCIP, paying in MNT; prints the message id |
| `ccip-manual-exec.ts` | Anyone (pays the fee) | Re-execute an inbound CCIP message whose automatic execution failed (e.g. it arrived while the mint was paused; the DON does not retry), from the failed execution transaction. Allowed 20 minutes after the commit; a second run is skipped by the OffRamp |
| `ccip-manual-exec-evm.sh` | Anyone (pays the gas) | Same for the Mantle side (Solana → Mantle): re-execute a message whose execution failed (Mantle token paused, receiver sanctioned, inbound rate limit, or out of gas), from the failed execution transaction. `TOKEN_GAS` raises the per-token gas, e.g. 150000 for a receiver that has never held the token |
| `devnet-ccip-smoke.sh` | Role keys + a holder | Basic-function smoke on a CCIP-connected mint against devnet and Mantle Sepolia: transfer, pause, freeze, clawback, metadata, the same multiplier on both chains, `ccip_send` after it, holder burn |
| `pause.ts` | `Pauser` / `Unpauser` (`--resume`) | Pause or resume one mint |
| `pause-all.ts` | `Pauser` | Emergency pause of every registered mint, 8 per transaction (`--dry-run` lists them; `--mints` if the RPC rejects `getProgramAccounts`) |
| `freeze.ts` | `Freezer` / `Unfreezer` (`--thaw`) | Freeze or thaw token accounts, 20 per transaction; `--owner <wallet>` finds every account the wallet holds for the mint (what the backend does on blacklisting) |
| `clawback.ts` | Compliance admin (`--compliance-admin`; a Squads address prints the instruction for a proposal) | Move tokens from an account to custody as permanent delegate; the source ends frozen. Freeze the account first |
| `update-metadata.ts` | `MetadataOps` | Update name / symbol / uri / any key (e.g. isin); tops up the mint's rent first |
| `revoke-role.ts` | Admin or compliance admin | Revoke a role (the admin that governs it) |
| `set-default-account-state.ts` | Admin | Compliance policy switch: new token accounts start frozen (`--frozen`) or usable (default) |
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

1. `create-mint.ts` with `--initial-multiplier-1e18` = Mantle `uiMultiplier()`. If Mantle has a
   pending multiplier, run `schedule-multiplier.ts` with the same values right after.
2. Mantle pool: `ccip-mantle-setup.sh deploy <deployer key> <token> <mint> <pool-owner multisig>
   --rate-capacity … --rate-per-second …` deploys the LockRelease pool, points it at the Solana pool
   and mint, sets rate limits and proposes the multisig as owner.
3. `ccip-register.ts` with the Mantle token, the pool from step 2 and the Mantle chain selector. It
   needs the current mint authority (the deployer) to sign, so it must run before step 5.
4. Multisigs. Mantle: `ccip-mantle-setup.sh multisig <token> <pool> <pool-owner>` writes the Safe
   Transaction Builder files: the token admin's timelock registers the token's CCIP admin and sets
   the pool (schedule, then execute after the delay), and the pool owner accepts ownership. Solana:
   `ccip-handoff.ts --to <Squads vault>` proposes the vault as CCIP token admin and pool owner and
   prints the two acceptances for a Squads proposal; re-run it once executed to confirm.
5. `handoff-mint-authority.ts --yes`: the CCIP pool signer becomes the only minter.
6. `ccip-mantle-setup.sh verify <token> <pool> <mint>` and `show-mint.ts` to confirm the final
   configuration.

The whole sequence was rehearsed on Mantle Sepolia ↔ Solana devnet (2026-11-16) with a token whose
admin is a timelock, as on mainnet (TD §6.2).

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
