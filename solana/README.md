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
cargo fmt --check && cargo clippy -p mstocks-core --all-targets -- -D warnings
```

CI (`.github/workflows/solana.yml`) runs rustfmt, `cargo build-sbf`, clippy, the LiteSVM tests and a
typecheck of the scripts on every change under `solana/`.

## Scripts

Admin steps accept `--admin <keypair.json>` (devnet/local: signs directly) or `--admin <pubkey>`
(mainnet: prints the instruction to submit as a Squads proposal, with the vault as payer).

| Script | Who signs | Purpose |
| --- | --- | --- |
| `init-core.ts` | Program upgrade authority | One-time setup: admin (Squads) and hook authority (Squads). On mainnet: deploy with the deployer as upgrade authority, run this, then transfer the upgrade authority to Squads + Timelock |
| `grant-role.ts` | Admin | Grant `MultiplierScheduler`, `Pauser`, `Unpauser`, `Freezer`, `Unfreezer`, `Clawback`, `MetadataOps` |
| `create-mint.ts` | Deployer + admin | Create a mint with all extensions and metadata (incl. ISIN), then `register_mint` |
| `schedule-multiplier.ts` | `MultiplierScheduler` | Schedule the same `(multiplier, effectiveAt)` sent to Mantle |
| `check-multiplier.ts` | — | Reconcile each mint's multiplier with its Mantle `ScaledToken` (address read from Core); exits 1 on mismatch for alerting. Needs `MANTLE_RPC_URL` |
| `handoff-mint-authority.ts` | Deployer (current mint authority) | Give the mint authority to the CCIP pool signer PDA (dry run unless `--yes`) |
| `pause.ts` | `Pauser` / `Unpauser` (`--resume`) | Pause or resume one mint |
| `pause-all.ts` | `Pauser` | Emergency pause of every registered mint, 8 per transaction (`--dry-run` lists them; `--mints` if the RPC rejects `getProgramAccounts`) |
| `freeze.ts` | `Freezer` / `Unfreezer` (`--thaw`) | Freeze or thaw token accounts, 20 per transaction; `--owner <wallet>` finds every account the wallet holds for the mint (what the backend does on blacklisting) |
| `clawback.ts` | `Clawback` | Move tokens from an account to custody as permanent delegate; the source ends frozen |
| `update-metadata.ts` | `MetadataOps` | Update name / symbol / uri / any key (e.g. isin); tops up the mint's rent first |
| `revoke-role.ts` | Admin | Revoke a role |
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
2. Register the token with CCIP and configure the BurnMint pool, following Chainlink's self-serve
   flow for Solana. This needs the current mint authority (the deployer) to sign, so it must happen
   before step 3:
   - propose the token administrator (Squads) on the CCIP Router and accept it from Squads;
   - initialize the BurnMint pool for the mint, create the pool signer's token account, and
     register the pool with the Router;
   - configure the Mantle remote chain (pool + token address, decimals 18) and rate limits.
3. `handoff-mint-authority.ts --yes`: the CCIP pool signer becomes the only minter.
4. `show-mint.ts` to confirm the final configuration.

Steps 2–3 have not yet been exercised against a real CCIP deployment. The Solana devnet ↔ Mantle
Sepolia lane is open (2026-11); both chains use the same onRamp / offRamp for every lane:

| | Solana devnet | Mantle Sepolia |
| --- | --- | --- |
| Chain selector | `16423721717087811551` | `8236463271206331221` |
| Router | `Ccip842gzYHhvdDkSyi2YVCoAWPbYJoApMFzSxQroE9C` | `0xFd33fd627017fEf041445FC19a2B6521C9778f86` |
| OnRamp | the Router | `0xCAC5826F878b3BfEE32404619C762b33ae199c1b` |
| OffRamp | `offqSMQWgQud6WJz694LRzkeN5kMYpCHTpXQr3Rkcjm` | `0xeD8abf93091D3F1Bfb6Ce14E9413F02a358A83E3` |
| Token pool | BurnMint program `41FGToCmdaWa1dgZLKFAjvmx6e6AjVTX7SVRibvsMGVB` (same as mainnet) | LockRelease via Token Pool Factory `0x9fCd83bC7F67ADa1fB51a4caBEa333c72B641bd1` |
| Registry | token admin registry in the Router | Token Admin Registry `0x0F1eE88A582f31d92510E300fc1330AA5a525D51`, Registry Module `0xf76cE612250eeEb8889F49FBCB11f1c2705305F6` |
| Fee tokens | LINK, WSOL | LINK, WMNT |

Source: the [CCIP directory](https://docs.chain.link/ccip/directory/testnet/chain/solana-devnet).
