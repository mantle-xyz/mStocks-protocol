#!/usr/bin/env bash
# Basic-function smoke on a CCIP-connected Core mint (devnet ↔ Mantle Sepolia): the mint's
# authority already belongs to the CCIP pool, as in production. Checks, on real chains:
#   A transfer between holders             E metadata update
#   B pause blocks transfers and ccip_send  F same multiplier scheduled on both chains → reconcile,
#   C freeze blocks transfers and ccip_send   then both show the same UI amounts once effective
#   D clawback (source ends frozen)         G ccip_send after the multiplier change keeps UI amounts
#   H a holder can burn their own tokens (Token-2022; unlike Mantle, where burning needs BURN_ROLE)
#
# Environment:
#   RPC_URL, MANTLE_RPC_URL          Solana devnet and Mantle Sepolia RPCs
#   MINT, MANTLE_TOKEN               the CCIP-registered pair
#   HOLDER                           keypair holding at least 0.3 tokens of MINT (and some SOL)
#   MANTLE_SCHEDULER_KEY             file with the hex key holding MULTIPLIER_SCHEDULER_ROLE on MANTLE_TOKEN
#   MANTLE_RECEIVER                  EVM address for the ccip_send in G
#   KEYS                             devnet Core role keys (ops.json: Pauser/Unpauser/Freezer/Unfreezer/
#                                    Clawback/MetadataOps, scheduler.json: MultiplierScheduler);
#                                    default ~/.config/solana/mstocks-devnet
#   MULTIPLIER_1E18                  default 2000000000000000000 (2x)
set -euo pipefail
cd "$(dirname "$0")/.."
: "${RPC_URL:?}" "${MANTLE_RPC_URL:?}" "${MINT:?}" "${MANTLE_TOKEN:?}" "${HOLDER:?}" "${MANTLE_SCHEDULER_KEY:?}" "${MANTLE_RECEIVER:?}"
export RPC_URL
KEYS=${KEYS:-$HOME/.config/solana/mstocks-devnet}
M1E18=${MULTIPLIER_1E18:-2000000000000000000}
PAYER=${PAYER:-$HOME/.config/solana/id.json}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

st() { spl-token -u "$RPC_URL" --program-2022 "$@"; }
run() { # runs a step; on failure prints its output and stops
  if ! "$@" >"$WORK/step" 2>&1; then
    echo "FAIL: $*"; grep -v "npm warn" "$WORK/step" | tail -20; exit 1
  fi
}
ts() { npx tsx "$@" 2>&1 | grep -v "npm warn"; }
pk() { solana-keygen pubkey "$1"; }
ata() { st address --token "$MINT" --owner "$1" --verbose | awk '/Associated token address/{print $NF}'; }
amount() { # raw | ui of a token account
  curl -s --max-time 20 -X POST "$RPC_URL" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTokenAccountBalance\",\"params\":[\"$1\",{\"commitment\":\"confirmed\"}]}" |
    python3 -I -c 'import sys,json; v=json.load(sys.stdin)["result"]["value"]; print(v["amount"], v["uiAmountString"])'
}
expect_fail() { # label, command...
  local label=$1; shift
  if "$@" >"$WORK/out" 2>&1; then echo "FAIL: $label succeeded"; tail -5 "$WORK/out"; exit 1; fi
  echo "   $label rejected: $(grep -oE 'Account is frozen|AccountFrozen|is paused|MintPaused|custom program error: 0x[0-9a-f]+|Error Message: [^.]*' "$WORK/out" | head -1)"
}
ccip_send() { # holder keypair, raw amount
  ts scripts/ccip-send.ts --sender "$1" --mint "$MINT" --amount "$2" --dest-selector 8236463271206331221 --receiver "$MANTLE_RECEIVER"
}

H=$(pk "$HOLDER"); H_ATA=$(ata "$H")
solana-keygen new --no-bip39-passphrase --silent -o "$WORK/user2.json" >/dev/null
U2=$(pk "$WORK/user2.json")
solana -u "$RPC_URL" -k "$PAYER" transfer --allow-unfunded-recipient "$U2" 0.05 >/dev/null
echo "holder $H ($(amount "$H_ATA")), user2 $U2"

echo "== A: holder → user2 0.1"
run st transfer "$MINT" 0.1 "$U2" --owner "$HOLDER" --fee-payer "$HOLDER" --fund-recipient --allow-unfunded-recipient
U2_ATA=$(ata "$U2")
echo "   user2: $(amount "$U2_ATA")"

echo "== B: pause blocks transfers and ccip_send; resume restores"
run npx tsx scripts/pause.ts --operator "$KEYS/ops.json" --mint "$MINT"
expect_fail "transfer while paused" st transfer "$MINT" 0.01 "$U2" --owner "$HOLDER" --fee-payer "$HOLDER"
expect_fail "ccip_send while paused" ccip_send "$HOLDER" 10000000
run npx tsx scripts/pause.ts --operator "$KEYS/ops.json" --mint "$MINT" --resume
run st transfer "$MINT" 0.01 "$U2" --owner "$HOLDER" --fee-payer "$HOLDER" && echo "   transfer after resume ok"

echo "== C: freezing user2 blocks its transfers and ccip_send; thaw restores"
run npx tsx scripts/freeze.ts --operator "$KEYS/ops.json" --mint "$MINT" --owner "$U2"
expect_fail "transfer from a frozen account" st transfer "$MINT" 0.01 "$H" --owner "$WORK/user2.json" --fee-payer "$WORK/user2.json"
expect_fail "ccip_send from a frozen account" ccip_send "$WORK/user2.json" 10000000
run npx tsx scripts/freeze.ts --operator "$KEYS/ops.json" --mint "$MINT" --owner "$U2" --thaw
run st transfer "$MINT" 0.01 "$H" --owner "$WORK/user2.json" --fee-payer "$WORK/user2.json" && echo "   transfer after thaw ok"

echo "== D: clawback 0.05 from user2 to holder (source ends frozen)"
run npx tsx scripts/clawback.ts --operator "$KEYS/ops.json" --mint "$MINT" --source "$U2_ATA" --destination "$H_ATA" --amount 50000000
echo "   user2: $(amount "$U2_ATA"); state $(st display "$U2_ATA" | awk '/State/{print $2}')"
run npx tsx scripts/freeze.ts --operator "$KEYS/ops.json" --mint "$MINT" --owner "$U2" --thaw

echo "== E: metadata"
run npx tsx scripts/update-metadata.ts --operator "$KEYS/ops.json" --mint "$MINT" --field name --value "mStocks CCIP Test (smoke $(date +%m%d))"
echo "   name: $(ts scripts/show-mint.ts --mint "$MINT" | grep -o '"name":"[^"]*"' | head -1)"

echo "== F: schedule ${M1E18} on both chains, reconcile, wait for it"
AT=$(( $(date +%s) + 420 ))
run cast send "$MANTLE_TOKEN" "setUIMultiplier(uint256,uint256)" "$M1E18" "$AT" --rpc-url "$MANTLE_RPC_URL" --private-key "$(cat "$MANTLE_SCHEDULER_KEY")"
run npx tsx scripts/schedule-multiplier.ts --scheduler "$KEYS/scheduler.json" --mint "$MINT" --multiplier-1e18 "$M1E18" --effective-at "$AT"
MANTLE_RPC_URL="$MANTLE_RPC_URL" ts scripts/check-multiplier.ts --mints "$MINT" | tail -2
echo "   waiting until $(date -r "$AT" +%H:%M:%S) ..."
while [ "$(date +%s)" -lt $(( AT + 15 )) ]; do sleep 15; done
read -r RAW UI <<<"$(amount "$H_ATA")"
echo "   holder on Solana: raw $RAW, ui $UI"
MANTLE_UI_ONE=$(cast call "$MANTLE_TOKEN" "toUIAmount(uint256)(uint256)" 1000000000000000000 --rpc-url "$MANTLE_RPC_URL" | awk '{print $1}')
echo "   Mantle toUIAmount(1e18) = $MANTLE_UI_ONE (expect $M1E18)"
[ "$MANTLE_UI_ONE" = "$M1E18" ] || { echo "FAIL: Mantle multiplier not effective"; exit 1; }
python3 -I -c "import sys; raw,ui,m=int('$RAW'),float('$UI'),int('$M1E18')/1e18; sys.exit(0 if abs(ui-raw/1e9*m)<1e-9 else 1)" || { echo "FAIL: Solana UI amount != raw x multiplier"; exit 1; }
echo "   Solana UI = raw × multiplier ✓"

echo "== G: ccip_send 0.1 (raw) after the multiplier change"
BEFORE_RAW=$(cast call "$MANTLE_TOKEN" "balanceOf(address)(uint256)" "$MANTLE_RECEIVER" --rpc-url "$MANTLE_RPC_URL" | awk '{print $1}')
ccip_send "$HOLDER" 100000000 | grep -E "^ccip_send"
for _ in $(seq 60); do
  NOW_RAW=$(cast call "$MANTLE_TOKEN" "balanceOf(address)(uint256)" "$MANTLE_RECEIVER" --rpc-url "$MANTLE_RPC_URL" | awk '{print $1}')
  [ "$NOW_RAW" != "$BEFORE_RAW" ] && break; sleep 15
done
python3 -I -c "d=$NOW_RAW-$BEFORE_RAW; print(f'   Mantle received raw {d} (expect 1e17), ui {d*$M1E18//10**18}'); assert d==10**17"

echo "== H: holder burns 0.01 of its own tokens (no role needed on Solana)"
SUPPLY_BEFORE=$(st supply "$MINT")
run st burn "$H_ATA" 0.01 --owner "$HOLDER" --fee-payer "$HOLDER" && echo "   burn succeeded: supply $SUPPLY_BEFORE → $(st supply "$MINT") (UI)"
echo PASS
