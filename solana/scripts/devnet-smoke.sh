#!/usr/bin/env bash
# Runs the deployment and operations scripts against devnet with persistent test keys.
#   RPC_URL=<devnet rpc> scripts/devnet-smoke.sh
# Keys live in $KEYS (default ~/.config/solana/mstocks-devnet, created on first run). The
# deployer (program upgrade authority) funds the other keys. Core is initialized only once.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${RPC_URL:?set RPC_URL to a devnet RPC endpoint}"
KEYS=${KEYS:-$HOME/.config/solana/mstocks-devnet}
DEPLOYER=${DEPLOYER:-$HOME/.config/solana/id.json}
EXPLORER="https://explorer.solana.com/address/%s?cluster=devnet"
mkdir -p "$KEYS"
for k in admin hook scheduler ops user custody; do
  [ -f "$KEYS/$k.json" ] || solana-keygen new --no-bip39-passphrase --silent -o "$KEYS/$k.json" >/dev/null
done
pk() { solana-keygen pubkey "$KEYS/$1.json"; }
sol() { solana -u "$RPC_URL" -k "$DEPLOYER" "$@"; }

echo "== fund test keys from the deployer"
for k in admin:0.2 scheduler:0.05 ops:0.2; do
  name=${k%%:*}; amount=${k##*:}
  bal=$(sol balance "$(pk $name)" | awk '{print $1}')
  awk "BEGIN{exit !($bal < $amount)}" && sol transfer --allow-unfunded-recipient "$(pk $name)" "$amount" >/dev/null
  echo "$name $(pk $name): $(sol balance "$(pk $name)")"
done

CONFIG=$(npx tsx -e 'import("./scripts/lib/core.ts").then(async m => console.log(await m.configPda()))')
if sol account "$CONFIG" >/dev/null 2>&1; then
  echo "== Core already initialized (config $CONFIG)"
else
  echo "== init-core"
  npx tsx scripts/init-core.ts --upgrade-authority "$DEPLOYER" --admin "$(pk admin)" --hook-authority "$(pk hook)"
fi

echo "== grant roles (scheduler + ops)"
npx tsx scripts/grant-role.ts --payer "$DEPLOYER" --admin "$KEYS/admin.json" --role MultiplierScheduler --member "$(pk scheduler)" || true
for r in Pauser Unpauser Freezer Unfreezer Clawback MetadataOps; do
  npx tsx scripts/grant-role.ts --payer "$DEPLOYER" --admin "$KEYS/admin.json" --role $r --member "$(pk ops)" >/dev/null 2>&1 || true
done

echo "== create-mint"
OUT=$(npx tsx scripts/create-mint.ts --payer "$DEPLOYER" --admin "$KEYS/admin.json" --hook-authority "$(pk hook)" \
  --name "Apple mStock (devnet)" --symbol AAPLm --uri https://example.com/aaplm.json --isin US0378331005 \
  --mantle-token 0x00000000000000000000000000000000000000aa --initial-multiplier-1e18 1000000000000000000)
echo "$OUT"
MINT=$(echo "$OUT" | awk '/^mint: /{print $2}')
printf "explorer: $EXPLORER\n" "$MINT"

echo "== schedule-multiplier (1.5x in 10 minutes)"
npx tsx scripts/schedule-multiplier.ts --scheduler "$KEYS/scheduler.json" --mint "$MINT" \
  --multiplier-1e18 1500000000000000000 --effective-at $(( $(date +%s) + 600 ))

echo "== mint to user, open custody account (deployer is still mint authority)"
USER_ATA=$(npx tsx scripts/dev-mint-to.ts --mint-authority "$DEPLOYER" --mint "$MINT" --owner "$(pk user)" --amount 5000000000 | awk '/^ata: /{print $2}')
CUSTODY_ATA=$(npx tsx scripts/dev-mint-to.ts --mint-authority "$DEPLOYER" --mint "$MINT" --owner "$(pk custody)" --amount 0 | awk '/^ata: /{print $2}')

echo "== blacklist user → clawback 2 → thaw"
npx tsx scripts/freeze.ts --operator "$KEYS/ops.json" --mint "$MINT" --owner "$(pk user)"
npx tsx scripts/clawback.ts --operator "$KEYS/ops.json" --mint "$MINT" --source "$USER_ATA" --destination "$CUSTODY_ATA" --amount 2000000000
npx tsx scripts/show-account.ts --account "$USER_ATA"
npx tsx scripts/show-account.ts --account "$CUSTODY_ATA"
npx tsx scripts/freeze.ts --operator "$KEYS/ops.json" --mint "$MINT" --owner "$(pk user)" --thaw

echo "== pause-all (explicit mint list) → resume"
npx tsx scripts/pause-all.ts --operator "$KEYS/ops.json" --mints "$MINT"
npx tsx scripts/pause.ts --operator "$KEYS/ops.json" --mint "$MINT" --resume

echo "== update metadata"
npx tsx scripts/update-metadata.ts --operator "$KEYS/ops.json" --mint "$MINT" --field cusip --value 037833100

echo "== final state"
npx tsx scripts/show-mint.ts --mint "$MINT"
npx tsx scripts/show-account.ts --account "$USER_ATA"
