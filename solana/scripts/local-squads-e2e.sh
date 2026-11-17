#!/usr/bin/env bash
# Runbook rehearsal with real Squads v4 multisigs on a local validator (mainnet Squads program and
# Token-2022, Core with a known upgrade authority). Time locks are scaled down (12h → TL, 24h → 2×TL).
#   multisigs: admin (2/3, TL), compliance admin (2/3, TL), upgrade authority (2/3, 2×TL),
#              unpauser (2/3, no time lock); EOAs: registrar, scheduler, ops (pauser, metadata),
#              kms (freezer, unfreezer)
# Covers: init-core with multisig addresses (stored as vaults), roles granted through proposals,
# check-config, upgrade authority handed to the multisig and an upgrade through it, resume by the
# unpauser multisig, clawback by the compliance multisig, unregister-mint by the admin multisig,
# and the negative cases (below threshold, inside the time lock, non-member, old upgrade key).
# Prerequisites: `anchor build`, `scripts/fetch-fixtures.sh`, `npm install`.
set -euo pipefail
cd "$(dirname "$0")/.."

TL=${TL:-15}
PORT=${PORT:-18899}
export RPC_URL=http://127.0.0.1:$PORT
WORK=$(mktemp -d)
CORE_ID=$(solana-keygen pubkey target/deploy/mstocks_core-keypair.json)
for k in deployer m1 m2 m3 outsider registrar scheduler ops kms user custody; do
  solana-keygen new --no-bip39-passphrase --silent -o "$WORK/$k.json" >/dev/null
done
pk() { solana-keygen pubkey "$WORK/$1.json"; }
# The deployer key is passed explicitly: the CLI otherwise falls back to the user's configured keypair
# (`program show` and the program authority defaults need one).
sol() { solana -u "$RPC_URL" -k "$WORK/deployer.json" "$@"; }

solana-test-validator --reset --quiet --ledger "$WORK/ledger" --rpc-port "$PORT" --faucet-port $((PORT + 1001)) \
  --bpf-program TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb tests/fixtures/token2022.so \
  --bpf-program SQDS4ep65T869zMMBKyuUq6aD6EgTu8psMjkvj52pCf tests/fixtures/squads_v4.so \
  --account BSTq9w3kZwNwpBXJEvTZz2G9ZTNyKBvoSeXMvwb4cNZr tests/fixtures/squads_program_config.json \
  --upgradeable-program "$CORE_ID" target/deploy/mstocks_core.so "$WORK/deployer.json" &
VALIDATOR=$!
trap 'kill $VALIDATOR 2>/dev/null; rm -rf "$WORK"' EXIT
until sol cluster-version >/dev/null 2>&1; do sleep 1; done
for k in deployer m1 m2 m3 outsider registrar scheduler ops kms; do sol airdrop 100 "$(pk $k)" >/dev/null; done

ts() { npx tsx "$@" 2>&1 | grep -v "npm warn"; }
squads() { ts scripts/squads.ts "$@"; }
fail() { echo "FAIL: $*"; exit 1; }
expect_fail() { # label, expected error pattern, command...
  local label=$1 want=$2; shift 2
  if "$@" >"$WORK/out" 2>&1; then fail "$label succeeded"; fi
  grep -qE "$want" "$WORK/out" || { tail -5 "$WORK/out"; fail "$label: expected $want"; }
  echo "   $label rejected: $(grep -oE "$want" "$WORK/out" | head -1)"
}
# Runs an admin script with --squads-member m1 (creates the proposal, m1 approves); prints the index.
propose() { # label, script args...
  local label=$1; shift
  ts "$@" --squads-member "$WORK/m1.json" >"$WORK/p"
  local idx
  idx=$(awk '/Squads proposal #/{sub(/.*#/, ""); print $1; exit}' "$WORK/p")
  [ -n "$idx" ] || { cat "$WORK/p"; fail "$label: no proposal"; }
  echo "   $label → proposal #$idx" >&2
  echo "$idx"
}
approve() { squads approve --multisig "$1" --index "$2" --member "$WORK/m2.json" >/dev/null; }
execute() { squads execute --multisig "$1" --index "$2" --member "$WORK/m3.json" | grep -E "^execute" || fail "execute $1 #$2"; }
after_time_lock() { sleep $(( $1 + 2 )); }

echo "== Squads multisigs (members m1, m2, m3)"
MEMBERS="$(pk m1),$(pk m2),$(pk m3)"
create() { squads create --creator "$WORK/deployer.json" --members "$MEMBERS" --threshold 2 --time-lock "$1" | awk '/^multisig /{print $2}'; }
vault() { squads status --multisig "$1" | awk '/^multisig /{print $NF}'; }
ADMIN_MS=$(create "$TL"); COMPLIANCE_MS=$(create "$TL"); UPGRADE_MS=$(create $((TL * 2))); UNPAUSER_MS=$(create 0)
for ms in ADMIN_MS COMPLIANCE_MS UPGRADE_MS UNPAUSER_MS; do
  v=$(vault "${!ms}"); printf -v "${ms%_MS}_VAULT" '%s' "$v"
  sol transfer --allow-unfunded-recipient "$v" 1 >/dev/null
  echo "   ${ms%_MS}: multisig ${!ms}, vault $v"
done

echo "== Step: init-core with the admin and compliance multisigs (stored as their vaults)"
ts scripts/init-core.ts --upgrade-authority "$WORK/deployer.json" --admin "$ADMIN_MS" \
  --compliance-admin "$COMPLIANCE_MS" --hook-authority "$ADMIN_MS" | grep -E "Squads multisig|initialize"

echo "== Step: grant roles through proposals"
P=$WORK/deployer.json
A1=$(propose "MintRegistrar → registrar" scripts/grant-role.ts --payer "$P" --admin "$ADMIN_MS" --role MintRegistrar --member "$(pk registrar)")
A2=$(propose "MultiplierScheduler → scheduler" scripts/grant-role.ts --payer "$P" --admin "$ADMIN_MS" --role MultiplierScheduler --member "$(pk scheduler)")
A3=$(propose "MetadataOps → ops" scripts/grant-role.ts --payer "$P" --admin "$ADMIN_MS" --role MetadataOps --member "$(pk ops)")
C1=$(propose "Pauser → ops" scripts/grant-role.ts --payer "$P" --admin "$COMPLIANCE_MS" --role Pauser --member "$(pk ops)")
C2=$(propose "Unpauser → unpauser multisig" scripts/grant-role.ts --payer "$P" --admin "$COMPLIANCE_MS" --role Unpauser --member "$UNPAUSER_MS")
C3=$(propose "Freezer → kms" scripts/grant-role.ts --payer "$P" --admin "$COMPLIANCE_MS" --role Freezer --member "$(pk kms)")
C4=$(propose "Unfreezer → kms" scripts/grant-role.ts --payer "$P" --admin "$COMPLIANCE_MS" --role Unfreezer --member "$(pk kms)")

echo "== negative: below threshold, non-member, inside the time lock"
expect_fail "execute with 1/2 approvals" "InvalidProposalStatus" \
  npx tsx scripts/squads.ts execute --multisig "$ADMIN_MS" --index "$A1" --member "$WORK/m3.json"
expect_fail "approve by a non-member" "NotAMember" \
  npx tsx scripts/squads.ts approve --multisig "$ADMIN_MS" --index "$A1" --member "$WORK/outsider.json"
for i in $A1 $A2 $A3; do approve "$ADMIN_MS" "$i"; done
for i in $C1 $C2 $C3 $C4; do approve "$COMPLIANCE_MS" "$i"; done
squads status --multisig "$ADMIN_MS" --index "$A1" | tail -1
expect_fail "execute inside the time lock" "TimeLockNotReleased" \
  npx tsx scripts/squads.ts execute --multisig "$ADMIN_MS" --index "$A1" --member "$WORK/m3.json"
after_time_lock "$TL"
for i in $A1 $A2 $A3; do execute "$ADMIN_MS" "$i"; done
for i in $C1 $C2 $C3 $C4; do execute "$COMPLIANCE_MS" "$i"; done

echo "== Step: upgrade authority → upgrade multisig vault"
D=$WORK/deployer.json
sol program set-upgrade-authority "$CORE_ID" --upgrade-authority "$D" --new-upgrade-authority "$UPGRADE_VAULT" \
  --skip-new-upgrade-authority-signer-check >/dev/null
echo "   upgrade authority: $(sol program show "$CORE_ID" | awk '/^Authority/{print $2}')"

echo "== Step: check-config"
sed -n '/^\[program\]/,/^max_horizon/p' config.mainnet.toml | sed "s/^id = .*/id = \"$CORE_ID\"/" >"$WORK/config.toml"
cat >>"$WORK/config.toml" <<EOF

[admins]
upgrade_authority = "$UPGRADE_MS"
admin = "$ADMIN_MS"
compliance_admin = "$COMPLIANCE_MS"
hook_authority = "$ADMIN_MS"

[roles]
mint_registrar = ["$(pk registrar)"]
multiplier_scheduler = ["$(pk scheduler)"]
metadata_ops = ["$(pk ops)"]
pauser = ["$(pk ops)"]
unpauser = ["$UNPAUSER_MS"]
freezer = ["$(pk kms)"]
unfreezer = ["$(pk kms)"]
EOF
ts scripts/check-config.ts --config "$WORK/config.toml" | tee "$WORK/check" | grep -vE "^  ok"
grep -q "^PASS" "$WORK/check" || fail "check-config"

echo "== Step: register a mint (registrar EOA, hook authority = admin multisig vault)"
OUT=$(ts scripts/create-mint.ts --payer "$P" --registrar "$WORK/registrar.json" --hook-authority "$ADMIN_MS" \
  --name "Apple mStock" --symbol AAPLm --uri https://example.com/aaplm.json \
  --mantle-token 0x00000000000000000000000000000000000000aa --initial-multiplier-1e18 1000000000000000000)
MINT=$(echo "$OUT" | awk '/^mint: /{print $2}')
[ -n "$MINT" ] || { echo "$OUT"; fail "create-mint"; }
ts scripts/show-mint.ts --mint "$MINT" | grep "^TransferHook" | grep -q "$ADMIN_VAULT" || fail "hook authority is not the admin vault"
echo "   mint $MINT, transfer hook authority $ADMIN_VAULT"
USER_ATA=$(ts scripts/dev-mint-to.ts --mint-authority "$P" --mint "$MINT" --owner "$(pk user)" --amount 5000000000 | awk '/^ata: /{print $2}')
CUSTODY_ATA=$(ts scripts/dev-mint-to.ts --mint-authority "$P" --mint "$MINT" --owner "$(pk custody)" --amount 0 | awk '/^ata: /{print $2}')

echo "== pause (ops EOA) → resume through the unpauser multisig (no time lock)"
ts scripts/pause.ts --operator "$WORK/ops.json" --mint "$MINT" | grep -E "^pause"
expect_fail "resume by the ops key" "AccountNotInitialized" \
  npx tsx scripts/pause.ts --operator "$WORK/ops.json" --mint "$MINT" --resume
R=$(propose "resume" scripts/pause.ts --operator "$UNPAUSER_MS" --mint "$MINT" --resume)
approve "$UNPAUSER_MS" "$R"; execute "$UNPAUSER_MS" "$R"
ts scripts/show-mint.ts --mint "$MINT" | grep "^PausableConfig" | grep -q '"paused":false' || fail "still paused"
echo "   resumed"

echo "== clawback 2 tokens through the compliance multisig (after a kms freeze)"
ts scripts/freeze.ts --operator "$WORK/kms.json" --mint "$MINT" --owner "$(pk user)" | grep -E "^freeze" | head -1
CB=$(propose "clawback" scripts/clawback.ts --payer "$P" --compliance-admin "$COMPLIANCE_MS" --mint "$MINT" \
  --source "$USER_ATA" --destination "$CUSTODY_ATA" --amount 2000000000)
approve "$COMPLIANCE_MS" "$CB"
expect_fail "clawback inside the time lock" "TimeLockNotReleased" \
  npx tsx scripts/squads.ts execute --multisig "$COMPLIANCE_MS" --index "$CB" --member "$WORK/m3.json"
after_time_lock "$TL"; execute "$COMPLIANCE_MS" "$CB"
spl-token -u "$RPC_URL" --program-2022 balance --address "$CUSTODY_ATA" | grep -qx 2 || fail "custody balance"
echo "   custody holds 2; user $(spl-token -u "$RPC_URL" --program-2022 balance --address "$USER_ATA")"

echo "== unregister a wrongly registered mint through the admin multisig"
WRONG=$(ts scripts/create-mint.ts --payer "$P" --registrar "$WORK/registrar.json" --hook-authority "$ADMIN_MS" \
  --name Wrong --symbol WRONG --uri https://example.com --mantle-token 0x00000000000000000000000000000000000000bb \
  --initial-multiplier-1e18 1000000000000000000 | awk '/^mint: /{print $2}')
U=$(propose "unregister $WRONG" scripts/unregister-mint.ts --payer "$P" --admin "$ADMIN_MS" --mint "$WRONG")
approve "$ADMIN_MS" "$U"; after_time_lock "$TL"; execute "$ADMIN_MS" "$U"
expect_fail "unregistered mint" "not registered" npx tsx scripts/unregister-mint.ts --payer "$P" --admin "$ADMIN_MS" --mint "$WRONG"

echo "== upgrade Core through the upgrade multisig"
expect_fail "upgrade by the old deployer key" "does not match" \
  sol program deploy target/deploy/mstocks_core.so --program-id "$CORE_ID" --upgrade-authority "$D"
BUFFER=$(sol program write-buffer target/deploy/mstocks_core.so --buffer-authority "$D" | awk '/^Buffer:/{print $2}')
[ -n "$BUFFER" ] || fail "write-buffer"
sol program set-buffer-authority "$BUFFER" --buffer-authority "$D" --new-buffer-authority "$UPGRADE_VAULT" >/dev/null
SLOT_BEFORE=$(sol program show "$CORE_ID" | awk '/Last Deployed In Slot/{print $NF}')
UP=$(squads upgrade --multisig "$UPGRADE_MS" --member "$WORK/m1.json" --buffer "$BUFFER" --spill "$(pk deployer)" |
  awk '/Squads proposal #/{sub(/.*#/, ""); print $1}')
approve "$UPGRADE_MS" "$UP"
squads status --multisig "$UPGRADE_MS" --index "$UP" | tail -1
after_time_lock $((TL * 2)); execute "$UPGRADE_MS" "$UP"
SLOT_AFTER=$(sol program show "$CORE_ID" | awk '/Last Deployed In Slot/{print $NF}')
[ "$SLOT_AFTER" -gt "$SLOT_BEFORE" ] || fail "program not upgraded"
echo "   deployed slot $SLOT_BEFORE → $SLOT_AFTER; authority $(sol program show "$CORE_ID" | awk '/^Authority/{print $2}')"

echo "== Core still works after the upgrade; check-config still passes"
ts scripts/freeze.ts --operator "$WORK/kms.json" --mint "$MINT" --owner "$(pk user)" --thaw | grep -E "^thaw" | head -1
ts scripts/check-config.ts --config "$WORK/config.toml" | tail -1 | grep -q PASS || fail "check-config after upgrade"
echo PASS
