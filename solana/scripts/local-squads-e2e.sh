#!/usr/bin/env bash
# Runbook rehearsal with real Squads v4 multisigs on a local validator (mainnet Squads program and
# Token-2022), driven by a network config like config.mainnet.toml: commands carry no addresses.
# Time locks are scaled down (12h → TL, 24h → 2×TL).
#   multisigs: admin (2/3, TL), compliance admin (2/3, TL), upgrade authority (2/3, 2×TL),
#              unpauser (2/3, no time lock); EOAs: registrar, scheduler, ops (metadata), pauser, kms
# Covers: program.ts deploy / handoff / upgrade / verify, init-core and sync-roles from the config
# (one proposal per admin, grants and a revoke), check-config, a mint, resume by the unpauser
# multisig, clawback by the compliance multisig, unregister by the admin multisig, and the negative
# cases (below threshold, non-member, inside the time lock, wrong admin, handoff before init, old
# upgrade key).
# Prerequisites: `anchor build`, `scripts/fetch-fixtures.sh`, `npm install`.
set -euo pipefail
cd "$(dirname "$0")/.."

TL=${TL:-15}
PORT=${PORT:-18899}
unset RPC_URL MANTLE_RPC_URL
WORK=$(mktemp -d)
for k in deployer m1 m2 m3 outsider registrar scheduler ops pauser kms user custody; do
  solana-keygen new --no-bip39-passphrase --silent -o "$WORK/$k.json" >/dev/null
done
pk() { solana-keygen pubkey "$WORK/$1.json"; }
D=$WORK/deployer.json
LOCAL=http://127.0.0.1:$PORT
sol() { solana -u "$LOCAL" -k "$D" "$@"; }

solana-test-validator --reset --quiet --ledger "$WORK/ledger" --rpc-port "$PORT" --faucet-port $((PORT + 1001)) \
  --bpf-program TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb tests/fixtures/token2022.so \
  --bpf-program SQDS4ep65T869zMMBKyuUq6aD6EgTu8psMjkvj52pCf tests/fixtures/squads_v4.so \
  --account BSTq9w3kZwNwpBXJEvTZz2G9ZTNyKBvoSeXMvwb4cNZr tests/fixtures/squads_program_config.json &
VALIDATOR=$!
trap 'kill $VALIDATOR 2>/dev/null; rm -rf "$WORK"' EXIT
until sol cluster-version >/dev/null 2>&1; do sleep 1; done
for k in deployer m1 m2 m3 outsider registrar scheduler ops pauser kms; do sol airdrop 100 "$(pk $k)" >/dev/null; done

ts() { npx tsx "$@" 2>&1 | grep -v "npm warn"; }
fail() { echo "FAIL: $*"; exit 1; }
expect_fail() { # label, expected error pattern, command...
  local label=$1 want=$2; shift 2
  if "$@" >"$WORK/out" 2>&1; then fail "$label succeeded"; fi
  grep -qE "$want" "$WORK/out" || { grep -v "npm warn" "$WORK/out" | tail -5; fail "$label: expected $want"; }
  echo "   $label rejected: $(grep -oE "$want" "$WORK/out" | head -1)"
}
idx() { awk -v l="$1" 'index($0, l) && /Squads proposal #/ {sub(/.*#/, ""); print $1; exit}'; }
approve() { ts scripts/squads.ts approve --multisig "$1" --index "$2" --member "$WORK/m2.json" >/dev/null; }
execute() { ts scripts/squads.ts execute --multisig "$1" --index "$2" --member "$WORK/m3.json" | grep -E "^execute" || fail "execute $1 #$2"; }
after_time_lock() { sleep $(( $1 + 2 )); }

echo "== Squads multisigs (members m1, m2, m3) and the network config"
MEMBERS="$(pk m1),$(pk m2),$(pk m3)"
create() { RPC_URL=$LOCAL ts scripts/squads.ts create --creator "$D" --members "$MEMBERS" --threshold 2 --time-lock "$1" | awk '/^multisig /{print $2}'; }
ADMIN_MS=$(create "$TL"); COMPLIANCE_MS=$(create "$TL"); UPGRADE_MS=$(create $((TL * 2))); UNPAUSER_MS=$(create 0)
cat >"$WORK/config.toml" <<EOF
[solana]
rpc = "$LOCAL"
roles_rpc = "$LOCAL"
chain_selector = ""
[mantle]
rpc = ""
[program]
id = "$(solana-keygen pubkey target/deploy/mstocks_core-keypair.json)"
min_notice_seconds = 300
max_horizon_seconds = 31536000
[admins]
upgrade_authority = "$UPGRADE_MS"
admin = "$ADMIN_MS"
compliance_admin = "$COMPLIANCE_MS"
hook_authority = "$ADMIN_MS"
[roles]
mint_registrar = ["$(pk registrar)"]
multiplier_scheduler = ["$(pk scheduler)"]
metadata_ops = ["$(pk ops)"]
pauser = ["$(pk pauser)"]
unpauser = ["$UNPAUSER_MS"]
freezer = ["$(pk kms)"]
unfreezer = ["$(pk kms)"]
[ccip]
solana_ccip_admin = ""
EOF
export NETWORK=$WORK/config.toml SQUADS_MEMBER=$WORK/m1.json
for ms in admin compliance_admin upgrade_authority unpauser; do
  v=$(ts scripts/squads.ts status --multisig $ms | awk '/^multisig /{print $NF}')
  sol transfer --allow-unfunded-recipient "$v" 1 >/dev/null
  echo "   $ms: vault $v"
done

echo "== Step: program.ts deploy (deploy + byte comparison)"
ts scripts/program.ts deploy --deployer "$D" | grep -E "matches|DIFFERS|upgrade authority" || fail "deploy"
expect_fail "handoff before init-core" "not initialized" npx tsx scripts/program.ts handoff --deployer "$D"

echo "== Step: init-core (addresses from the config), handoff, sync-roles"
ts scripts/init-core.ts --upgrade-authority "$D" | grep -E "^initialize" || fail "init-core"
ts scripts/program.ts handoff --deployer "$D" | grep "upgrade authority"
ts scripts/sync-roles.ts >"$WORK/sync"; grep -E "change|grant|revoke|Squads proposal" "$WORK/sync"
A=$(idx "admin roles" <"$WORK/sync"); C=$(idx "compliance roles" <"$WORK/sync")
[ -n "$A" ] && [ -n "$C" ] || fail "sync-roles proposals"
expect_fail "execute with 1/2 approvals" "InvalidProposalStatus" \
  npx tsx scripts/squads.ts execute --multisig admin --index "$A" --member "$WORK/m3.json"
expect_fail "approve by a non-member" "NotAMember" \
  npx tsx scripts/squads.ts approve --multisig admin --index "$A" --member "$WORK/outsider.json"
approve admin "$A"; approve compliance_admin "$C"
expect_fail "execute inside the time lock" "TimeLockNotReleased" \
  npx tsx scripts/squads.ts execute --multisig admin --index "$A" --member "$WORK/m3.json"
after_time_lock "$TL"; execute admin "$A"; execute compliance_admin "$C"
ts scripts/check-config.ts | tee "$WORK/check" | grep -vE "^  ok"
grep -q "^PASS" "$WORK/check" || fail "check-config"
ts scripts/sync-roles.ts | grep -q "roles match the config" || fail "sync-roles after execution"
echo "   sync-roles again: roles match the config"
expect_fail "grant-role with the wrong admin" "is governed by the admin" \
  npx tsx scripts/grant-role.ts --admin "$COMPLIANCE_MS" --role MintRegistrar --member "$(pk user)"

echo "== sync-roles revokes a holder dropped from the config"
sed -i.bak '/^multiplier_scheduler/d' "$WORK/config.toml"
ts scripts/sync-roles.ts >"$WORK/sync"; grep -E "revoke" "$WORK/sync"
R=$(idx "admin roles" <"$WORK/sync"); approve admin "$R"; after_time_lock "$TL"; execute admin "$R"
ts scripts/check-config.ts | grep -q "^PASS" || fail "check-config after revoke"
mv "$WORK/config.toml.bak" "$WORK/config.toml"
ts scripts/sync-roles.ts >"$WORK/sync"; R=$(idx "admin roles" <"$WORK/sync"); approve admin "$R"; after_time_lock "$TL"; execute admin "$R"
ts scripts/check-config.ts | grep -q "^PASS" || fail "check-config after re-grant"
echo "   revoked, re-granted, PASS"

echo "== a mint (registrar is the payer; hook authority from the config)"
OUT=$(ts scripts/create-mint.ts --payer "$WORK/registrar.json" --uri https://example.com/aaplm.json \
  --name "Apple mStock" --symbol AAPLm --isin US0378331005 \
  --mantle-token 0x00000000000000000000000000000000000000aa --initial-multiplier-1e18 1000000000000000000)
MINT=$(echo "$OUT" | awk '/^mint: /{print $2}')
[ -n "$MINT" ] || { echo "$OUT"; fail "create-mint"; }
echo "   $(echo "$OUT" | grep '^create and register' | cut -c1-80)…"
USER_ATA=$(ts scripts/dev-mint-to.ts --mint-authority "$WORK/registrar.json" --mint "$MINT" --owner "$(pk user)" --amount 5000000000 | awk '/^ata: /{print $2}')
CUSTODY_ATA=$(ts scripts/dev-mint-to.ts --mint-authority "$WORK/registrar.json" --mint "$MINT" --owner "$(pk custody)" --amount 0 | awk '/^ata: /{print $2}')

echo "== pause (pauser key) → resume through the unpauser multisig from the config"
ts scripts/pause.ts --operator "$WORK/pauser.json" --mint "$MINT" | grep -E "^pause"
P=$(ts scripts/pause.ts --mint "$MINT" --resume | idx "resume"); approve unpauser "$P"; execute unpauser "$P"
ts scripts/show-mint.ts --mint "$MINT" | grep "^PausableConfig" | grep -q '"paused":false' || fail "still paused"
echo "   resumed"

echo "== clawback through the compliance multisig (after a kms freeze)"
ts scripts/freeze.ts --operator "$WORK/kms.json" --mint "$MINT" --owner "$(pk user)" | grep -E "^freeze" | head -1
CB=$(ts scripts/clawback.ts --mint "$MINT" --source "$USER_ATA" --destination "$CUSTODY_ATA" --amount 2000000000 | idx "clawback")
approve compliance_admin "$CB"; after_time_lock "$TL"; execute compliance_admin "$CB"
spl-token -u "$LOCAL" --program-2022 balance --address "$CUSTODY_ATA" | grep -qx 2 || fail "custody balance"
echo "   custody holds 2"

echo "== unregister a wrongly registered mint through the admin multisig"
WRONG=$(ts scripts/create-mint.ts --payer "$WORK/registrar.json" --uri https://example.com --name Wrong --symbol WRONG --isin X \
  --mantle-token 0x00000000000000000000000000000000000000bb --initial-multiplier-1e18 1000000000000000000 | awk '/^mint: /{print $2}')
U=$(ts scripts/unregister-mint.ts --mint "$WRONG" | idx "unregister_mint"); approve admin "$U"; after_time_lock "$TL"; execute admin "$U"
expect_fail "unregistered mint" "not registered" npx tsx scripts/unregister-mint.ts --mint "$WRONG"

echo "== program.ts upgrade through the upgrade multisig"
expect_fail "upgrade by the old deployer key" "does not match" \
  sol program deploy target/deploy/mstocks_core.so --program-id "$(solana-keygen pubkey target/deploy/mstocks_core-keypair.json)" --upgrade-authority "$D"
UP=$(ts scripts/program.ts upgrade --deployer "$D" | tee "$WORK/up" | idx "upgrade:")
[ -n "$UP" ] || { cat "$WORK/up"; fail "upgrade proposal"; }
approve upgrade_authority "$UP"; after_time_lock $((TL * 2)); execute upgrade_authority "$UP"
ts scripts/program.ts verify | grep -E "matches|DIFFERS"
ts scripts/check-config.ts | grep -q "^PASS" || fail "check-config after upgrade"
ts scripts/freeze.ts --operator "$WORK/kms.json" --mint "$MINT" --owner "$(pk user)" --thaw | grep -E "^thaw" | head -1
echo PASS
