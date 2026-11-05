#!/usr/bin/env bash
# End-to-end run of the deployment scripts on a local validator:
# start validator (mainnet Token-2022 + Core with a known upgrade authority) → init-core →
# grant roles → create-mint → schedule-multiplier → show-mint.
# Prerequisites: `anchor build`, `scripts/fetch-fixtures.sh`, `npm install`.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
LEDGER="$WORK/ledger"
CORE_ID=$(solana-keygen pubkey target/deploy/mstocks_core-keypair.json)
for k in deployer admin hook scheduler ops user custody; do solana-keygen new --no-bip39-passphrase --silent -o "$WORK/$k.json" >/dev/null; done
pk() { solana-keygen pubkey "$WORK/$1.json"; }

solana-test-validator --reset --quiet --ledger "$LEDGER" \
  --bpf-program TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb tests/fixtures/token2022.so \
  --upgradeable-program "$CORE_ID" target/deploy/mstocks_core.so "$WORK/deployer.json" &
VALIDATOR=$!
trap 'kill $VALIDATOR 2>/dev/null; rm -rf "$WORK"' EXIT
until solana -u l cluster-version >/dev/null 2>&1; do sleep 1; done
for k in deployer admin scheduler ops; do solana -u l airdrop 100 "$(pk $k)" >/dev/null; done

echo "== init-core"
npx tsx scripts/init-core.ts --upgrade-authority "$WORK/deployer.json" --admin "$(pk admin)" --hook-authority "$(pk hook)"

echo "== grant MultiplierScheduler"
npx tsx scripts/grant-role.ts --payer "$WORK/deployer.json" --admin "$WORK/admin.json" --role MultiplierScheduler --member "$(pk scheduler)"

echo "== create-mint"
OUT=$(npx tsx scripts/create-mint.ts --payer "$WORK/deployer.json" --admin "$WORK/admin.json" --hook-authority "$(pk hook)" \
  --name "Apple mStock" --symbol AAPLm --uri https://example.com/aaplm.json --isin US0378331005 \
  --mantle-token 0x00000000000000000000000000000000000000aa --initial-multiplier-1e18 1000000000000000000)
echo "$OUT"
MINT=$(echo "$OUT" | awk '/^mint: /{print $2}')

echo "== schedule-multiplier (2x in 10 minutes)"
NOW=$(date +%s)
npx tsx scripts/schedule-multiplier.ts --scheduler "$WORK/scheduler.json" --mint "$MINT" \
  --multiplier-1e18 2000000000000000000 --effective-at $((NOW + 600))

echo "== show-mint"
npx tsx scripts/show-mint.ts --mint "$MINT"

echo "== grant operational roles to ops"
for r in Pauser Unpauser Freezer Unfreezer Clawback MetadataOps; do
  npx tsx scripts/grant-role.ts --payer "$WORK/deployer.json" --admin "$WORK/admin.json" --role $r --member "$(pk ops)" >/dev/null
done

echo "== mint to user, open custody account (dev only, deployer is still mint authority)"
USER_ATA=$(npx tsx scripts/dev-mint-to.ts --mint-authority "$WORK/deployer.json" --mint "$MINT" --owner "$(pk user)" --amount 5000000000 | awk '/^ata: /{print $2}')
CUSTODY_ATA=$(npx tsx scripts/dev-mint-to.ts --mint-authority "$WORK/deployer.json" --mint "$MINT" --owner "$(pk custody)" --amount 0 | awk '/^ata: /{print $2}')

echo "== blacklist user: freeze every account of the wallet"
npx tsx scripts/freeze.ts --operator "$WORK/ops.json" --mint "$MINT" --owner "$(pk user)"
npx tsx scripts/show-account.ts --account "$USER_ATA"

echo "== clawback 2 tokens to custody (source stays frozen)"
npx tsx scripts/clawback.ts --operator "$WORK/ops.json" --mint "$MINT" --source "$USER_ATA" --destination "$CUSTODY_ATA" --amount 2000000000
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

echo "== update metadata (new key grows the mint; script tops up rent)"
npx tsx scripts/update-metadata.ts --operator "$WORK/ops.json" --mint "$MINT" --field name --value "Apple Inc. mStock"
npx tsx scripts/update-metadata.ts --operator "$WORK/ops.json" --mint "$MINT" --field cusip --value 037833100
npx tsx scripts/show-mint.ts --mint "$MINT" | grep TokenMetadata

echo "== revoke Clawback from ops"
npx tsx scripts/revoke-role.ts --payer "$WORK/deployer.json" --admin "$WORK/admin.json" --role Clawback --member "$(pk ops)"

echo "== handoff dry run"
npx tsx scripts/handoff-mint-authority.ts --mint-authority "$WORK/deployer.json" --mint "$MINT"
