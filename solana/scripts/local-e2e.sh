#!/usr/bin/env bash
# End-to-end run of the deployment scripts on a local validator:
# start validator (mainnet Token-2022 + Core with a known upgrade authority) → init-core →
# grant roles → create-mint → schedule-multiplier → show-mint.
# Prerequisites: `anchor build`, `scripts/fetch-fixtures.sh`, `npm install`.
set -euo pipefail
cd "$(dirname "$0")/.."
# Local mode: every address on the command line, RPC = the local validator (no network config).
unset NETWORK RPC_URL DEPLOYER

WORK=$(mktemp -d)
VALIDATOR=""  # set below; the trap runs from here on, also if a setup step fails
trap 'kill $VALIDATOR 2>/dev/null; rm -rf "$WORK"' EXIT
wait_for() { local i; for i in $(seq 1 90); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done; echo "FAIL: timed out waiting for: $*"; exit 1; }
LEDGER="$WORK/ledger"
CORE_ID=$(solana-keygen pubkey target/deploy/mstocks_core-keypair.json)
for k in deployer admin compliance hook scheduler ops user custody; do solana-keygen new --no-bip39-passphrase --silent -o "$WORK/$k.json" >/dev/null; done
pk() { solana-keygen pubkey "$WORK/$1.json"; }

solana-test-validator --reset --quiet --ledger "$LEDGER" \
  --bpf-program TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb tests/fixtures/token2022.so \
  --upgradeable-program "$CORE_ID" target/deploy/mstocks_core.so "$WORK/deployer.json" &
VALIDATOR=$!
wait_for solana -u l cluster-version
for k in deployer admin compliance scheduler ops; do solana -u l airdrop 100 "$(pk $k)" >/dev/null; done

echo "== init-core"
npx tsx scripts/init-core.ts --upgrade-authority "$WORK/deployer.json" --admin "$(pk admin)" --compliance-admin "$(pk compliance)" --hook-authority "$(pk hook)"

echo "== grant MultiplierScheduler, and MintRegistrar to the deployer"
npx tsx scripts/grant-role.ts --payer "$WORK/deployer.json" --admin "$WORK/admin.json" --role MultiplierScheduler --member "$(pk scheduler)"
npx tsx scripts/grant-role.ts --payer "$WORK/deployer.json" --admin "$WORK/admin.json" --role MintRegistrar --member "$(pk deployer)"

echo "== create-mint (--dry-run prints the instructions, the backend's test vectors, and sends nothing)"
DRY=$(npx tsx scripts/create-mint.ts --dry-run --payer "$WORK/deployer.json" --registrar "$WORK/deployer.json" --hook-authority "$(pk hook)" \
  --name "Apple mStock" --symbol AAPLm --uri https://example.com/aaplm.json --isin US0378331005 \
  --mantle-token 0x00000000000000000000000000000000000000aa --initial-multiplier-1e18 1000000000000000000)
echo "$DRY" | grep -E "^12\. program|^rent " || { echo "$DRY"; echo "FAIL: dry run"; exit 1; }
DRY_MINT=$(echo "$DRY" | awk '/^rent /{print $(NF-2)}')
if solana -u l account "$DRY_MINT" >/dev/null 2>&1; then echo "FAIL: the dry run created $DRY_MINT"; exit 1; fi
OUT=$(npx tsx scripts/create-mint.ts --payer "$WORK/deployer.json" --registrar "$WORK/deployer.json" --hook-authority "$(pk hook)" \
  --name "Apple mStock" --symbol AAPLm --uri https://example.com/aaplm.json --isin US0378331005 \
  --mantle-token 0x00000000000000000000000000000000000000aa --initial-multiplier-1e18 1000000000000000000)
echo "$OUT"
MINT=$(echo "$OUT" | awk '/^mint: /{print $2}')

echo "== registration correction: a second mint for the same Mantle token is rejected; an empty mint can be unregistered"
if npx tsx scripts/create-mint.ts --payer "$WORK/deployer.json" --registrar "$WORK/deployer.json" --hook-authority "$(pk hook)" \
  --name Dup --symbol DUP --uri https://example.com --mantle-token 0x00000000000000000000000000000000000000aa \
  --initial-multiplier-1e18 1000000000000000000 >/dev/null 2>&1; then echo "UNEXPECTED: duplicate Mantle token registered"; exit 1; fi
WRONG=$(npx tsx scripts/create-mint.ts --payer "$WORK/deployer.json" --registrar "$WORK/deployer.json" --hook-authority "$(pk hook)" \
  --name Wrong --symbol WRONG --uri https://example.com --mantle-token 0x00000000000000000000000000000000000000bb \
  --initial-multiplier-1e18 1000000000000000000 | awk '/^mint: /{print $2}')
npx tsx scripts/unregister-mint.ts --payer "$WORK/deployer.json" --admin "$WORK/admin.json" --mint "$WRONG"
# A mint the CCIP pool can mint into is never unregistered: here its mint authority is the 1-of-2
# Token-2022 multisig of the pool signer and the admin that mStocks uses (handoff-mint-authority.ts
# needs a CCIP lookup table, absent locally, so the multisig is set up with spl-token).
POOLED=$(npx tsx scripts/create-mint.ts --payer "$WORK/deployer.json" --registrar "$WORK/deployer.json" --hook-authority "$(pk hook)" \
  --name Pooled --symbol POOLED --uri https://example.com --mantle-token 0x00000000000000000000000000000000000000cc \
  --initial-multiplier-1e18 1000000000000000000 | awk '/^mint: /{print $2}')
POOL_SIGNER=$(npx tsx -e "import('./scripts/lib/ccip.ts').then(async (c) => console.log((await c.ccipAccounts('$POOLED')).poolSigner))")
solana-keygen new --no-bip39-passphrase --silent -o "$WORK/multisig.json" >/dev/null; MULTISIG=$(pk multisig)
spl-token -u l --program-2022 create-multisig 1 "$POOL_SIGNER" "$(pk admin)" --address-keypair "$WORK/multisig.json" --fee-payer "$WORK/deployer.json" >/dev/null
spl-token -u l --program-2022 authorize "$POOLED" mint "$MULTISIG" --authority "$WORK/deployer.json" --fee-payer "$WORK/deployer.json" >/dev/null
if npx tsx scripts/unregister-mint.ts --payer "$WORK/deployer.json" --admin "$WORK/admin.json" --mint "$POOLED" >"$WORK/out" 2>&1; then
  echo "UNEXPECTED: a mint the CCIP pool can mint into was unregistered (pool signer $POOL_SIGNER, multisig $MULTISIG)"
  spl-token -u l --program-2022 display "$POOLED" | grep -i "mint authority"; cat "$WORK/out"; exit 1; fi
grep -q "the CCIP pool can mint" "$WORK/out" || { echo "UNEXPECTED refusal:"; cat "$WORK/out"; exit 1; }
echo "   unregistering a mint held by the pool's multisig refused"
echo "== escape hatch: the admin, the multisig's other member, moves the mint authority without the pool"
if npx tsx scripts/move-mint-authority.ts --payer "$WORK/deployer.json" --admin "$WORK/compliance.json" --mint "$POOLED" --to "$(pk deployer)" >"$WORK/out" 2>&1; then
  echo "UNEXPECTED: a key outside the multisig moved the mint authority"; exit 1; fi
grep -q "cannot move the authority alone" "$WORK/out" || { echo "UNEXPECTED refusal:"; cat "$WORK/out"; exit 1; }
npx tsx scripts/move-mint-authority.ts --payer "$WORK/deployer.json" --admin "$WORK/admin.json" --mint "$POOLED" --to "$(pk deployer)" >/dev/null
spl-token -u l --program-2022 display "$POOLED" | grep -q "Mint authority: $(pk deployer)" || { echo "FAIL: the mint authority did not move"; exit 1; }
spl-token -u l --program-2022 authorize "$POOLED" mint "$MULTISIG" --authority "$WORK/deployer.json" --fee-payer "$WORK/deployer.json" >/dev/null
echo "   a key outside the multisig is refused; the admin alone moved the authority, and it went back"

echo "== schedule-multiplier (2x in 10 minutes)"
NOW=$(date +%s)
npx tsx scripts/schedule-multiplier.ts --scheduler "$WORK/scheduler.json" --mint "$MINT" \
  --multiplier-1e18 2000000000000000000 --effective-at $((NOW + 600))

echo "== show-mint"
npx tsx scripts/show-mint.ts --mint "$MINT"

echo "== grant operational roles to ops"
for r in Pauser Unpauser Freezer Unfreezer; do
  npx tsx scripts/grant-role.ts --payer "$WORK/deployer.json" --admin "$WORK/compliance.json" --role $r --member "$(pk ops)" >/dev/null
done
npx tsx scripts/grant-role.ts --payer "$WORK/deployer.json" --admin "$WORK/admin.json" --role MetadataOps --member "$(pk ops)" >/dev/null
echo "== the admin cannot grant a compliance role"
if npx tsx scripts/grant-role.ts --payer "$WORK/deployer.json" --admin "$WORK/admin.json" --role Freezer --member "$(pk user)" >/dev/null 2>&1; then
  echo "UNEXPECTED: the admin granted Freezer"; exit 1; fi

echo "== mint to user, open custody account (dev only, deployer is still mint authority)"
USER_ATA=$(npx tsx scripts/dev-mint-to.ts --mint-authority "$WORK/deployer.json" --mint "$MINT" --owner "$(pk user)" --amount 5000000000 | awk '/^ata: /{print $2}')
CUSTODY_ATA=$(npx tsx scripts/dev-mint-to.ts --mint-authority "$WORK/deployer.json" --mint "$MINT" --owner "$(pk custody)" --amount 0 | awk '/^ata: /{print $2}')

echo "== blacklist user: freeze every account of the wallet"
npx tsx scripts/freeze.ts --operator "$WORK/ops.json" --mint "$MINT" --owner "$(pk user)"
npx tsx scripts/show-account.ts --account "$USER_ATA"

echo "== clawback 2 tokens to custody (source stays frozen)"
npx tsx scripts/clawback.ts --payer "$WORK/deployer.json" --compliance-admin "$WORK/compliance.json" --mint "$MINT" --source "$USER_ATA" --destination "$CUSTODY_ATA" --amount 2000000000
npx tsx scripts/show-account.ts --account "$USER_ATA"
npx tsx scripts/show-account.ts --account "$CUSTODY_ATA"

echo "== unblacklist: thaw"
npx tsx scripts/freeze.ts --operator "$WORK/ops.json" --mint "$MINT" --owner "$(pk user)" --thaw
npx tsx scripts/show-account.ts --account "$USER_ATA"

echo "== pause / resume"
npx tsx scripts/pause.ts --operator "$WORK/ops.json" --mint "$MINT"
npx tsx scripts/show-mint.ts --mint "$MINT" | grep PausableConfig
npx tsx scripts/pause.ts --operator "$WORK/ops.json" --mint "$MINT" --resume
npx tsx scripts/show-mint.ts --mint "$MINT" | grep PausableConfig

echo "== emergency global pause (finds every registered mint), then resume"
npx tsx scripts/pause-all.ts --operator "$WORK/ops.json" --dry-run
npx tsx scripts/pause-all.ts --operator "$WORK/ops.json"
npx tsx scripts/show-mint.ts --mint "$MINT" | grep PausableConfig
npx tsx scripts/pause.ts --operator "$WORK/ops.json" --mint "$MINT" --resume
npx tsx scripts/pause.ts --operator "$WORK/ops.json" --mint "$POOLED" --resume
echo "== pause-all with a kept list that includes an unregistered mint: skipped, the others paused"
npx tsx scripts/pause-all.ts --operator "$WORK/ops.json" --mints "$WRONG,$MINT" | tee "$WORK/out"
grep -q "skipped $WRONG" "$WORK/out" && grep -q "^pause 1:" "$WORK/out" || { echo "FAIL: pause-all list"; exit 1; }
npx tsx scripts/pause.ts --operator "$WORK/ops.json" --mint "$MINT" --resume

echo "== update metadata (new key grows the mint; script tops up rent)"
npx tsx scripts/update-metadata.ts --operator "$WORK/ops.json" --mint "$MINT" --field name --value "Apple Inc. mStock"
npx tsx scripts/update-metadata.ts --operator "$WORK/ops.json" --mint "$MINT" --field cusip --value 037833100
if npx tsx scripts/update-metadata.ts --operator "$WORK/ops.json" --mint "$MINT" --field symbol --value "AAPL m!" >/dev/null 2>&1; then
  echo "UNEXPECTED: a symbol Mantle rejects was accepted"; exit 1; fi
echo "   a symbol Mantle would reject is refused"
if npx tsx scripts/grant-role.ts --payer "$WORK/deployer.json" --admin "$WORK/compliance.json" --role Clawback --member "$(pk ops)" >/dev/null 2>&1; then
  echo "UNEXPECTED: the retired Clawback role was granted"; exit 1; fi
echo "   granting the retired Clawback role is refused"
npx tsx scripts/show-mint.ts --mint "$MINT" | grep TokenMetadata

echo "== policy switch: new accounts start frozen, then back to usable"
npx tsx scripts/set-default-account-state.ts --payer "$WORK/deployer.json" --admin "$WORK/admin.json" --mint "$MINT" --frozen
npx tsx scripts/show-mint.ts --mint "$MINT" | grep DefaultAccountState
npx tsx scripts/set-default-account-state.ts --payer "$WORK/deployer.json" --admin "$WORK/admin.json" --mint "$MINT"
npx tsx scripts/show-mint.ts --mint "$MINT" | grep DefaultAccountState

echo "== revoke MetadataOps from ops"
npx tsx scripts/revoke-role.ts --payer "$WORK/deployer.json" --admin "$WORK/admin.json" --role MetadataOps --member "$(pk ops)"

echo "== the mint authority multisig is created even after someone funded its address (CreateAccount would refuse it)"
# ccip-register.ts creates it with createMintAuthorityMultisigIxs; its address is predictable from the
# registering key and the mint, so a third party can send it lamports first.
msig() { npx tsx -e "import('./scripts/lib/ccip.ts').then(async (c) => {
  const { loadKeypair, send } = await import('./scripts/lib/env.ts');
  const base = await loadKeypair('$WORK/deployer.json'); const pool = (await c.ccipAccounts('$MINT')).poolSigner;
  const ms = await c.mintAuthorityMultisig(base.address, '$MINT');
  if ('$1' === 'address') return console.log(ms);
  const ixs = await c.createMintAuthorityMultisigIxs(base, '$MINT', pool, '$(pk admin)');
  if (ixs.length) await send(base, ixs);
  console.log((await c.mintAuthorityMultisigProblem(ms, pool, '$(pk admin)')) ?? 'multisig ok', ixs.length);
})"; }
solana -u l transfer --allow-unfunded-recipient "$(msig address)" 0.001 --keypair "$WORK/deployer.json" >/dev/null
msig create >"$WORK/out" 2>&1 || { cat "$WORK/out"; echo "FAIL: creating the funded multisig"; exit 1; }
grep -q "^multisig ok 3$" "$WORK/out" || { cat "$WORK/out"; echo "FAIL: funded multisig (expected top-up, allocate, initialize)"; exit 1; }
msig create | grep -q "^multisig ok 0$" || { echo "FAIL: a second run should find the multisig"; exit 1; }
echo "   topped up, allocated and initialized; a re-run leaves it as it is"

echo "== handoff without CCIP registration is refused (the multisig must be in the pool's lookup table)"
if npx tsx scripts/handoff-mint-authority.ts --mint-authority "$WORK/deployer.json" --mint "$MINT" --mint-authority-admin "$(pk admin)" >"$WORK/out" 2>&1; then
  echo "UNEXPECTED: handoff accepted without a CCIP lookup table"; exit 1; fi
grep -q "no CCIP lookup table yet" "$WORK/out" || { echo "UNEXPECTED refusal:"; cat "$WORK/out"; exit 1; }
echo "   refused: run ccip-register.ts first"
