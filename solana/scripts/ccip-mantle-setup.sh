#!/usr/bin/env bash
# Mantle side of connecting an mStocks ScaledToken to its Solana mint over CCIP. Mantle is the issuing
# chain, so its pool is a LockReleaseTokenPool (pinned to @chainlink/contracts-ccip 1.6.4): it only
# transfers the token, so ScaledToken needs no new role, and its rebalancer stays unset (nobody can
# withdraw the locked tokens).
#
#   deploy   <deployer-key-file> <token> <solana-mint> <pool-owner> (--rate-capacity <wei> --rate-per-second <wei> | --no-rate-limit)
#            [--rate-limit-admin <addr>]
#            Sends from the deployer: deploys the pool, points it at the Solana pool and mint, sets the
#            rate limits (same both ways, in the token's 18-decimal units), optionally a rate limit
#            admin, and proposes <pool-owner> (the multisig) as owner. Prints the pool address.
#   multisig <token> <pool> <pool-owner> [--out <dir>]
#            Writes Safe Transaction Builder JSON files for the multisigs:
#              - the token admin (the token's DEFAULT_ADMIN_ROLE, a TimelockController on mainnet)
#                registers as the token's CCIP admin, accepts, and sets the pool;
#              - <pool-owner> accepts the pool's ownership.
#            For a timelock the calls are wrapped as scheduleBatch (file 1) and executeBatch (file 2,
#            after the timelock's delay); when <pool-owner> is the same timelock, one batch does both.
#            For a Safe or EOA they are plain calls. Steps already done on chain are left out.
#   execute  <key-file> <json>...      Testnet only: sends a JSON file's calls from <key-file>, standing
#                                      in for a multisig that is a plain key in a test deployment.
#   verify   <token> <pool> <solana-mint>
#            Checks registry, pool owner, remote chain, rate limits, rebalancer, sanctions; exits 1 on a
#            problem.
#
# Env: MANTLE_RPC_URL (required), NETWORK=mainnet|testnet (default mainnet: Mantle ↔ Solana mainnet;
# testnet: Mantle Sepolia ↔ Solana devnet). The Solana side is ccip-register.ts / ccip-handoff.ts.
set -euo pipefail
# File arguments (key files, --out, JSON files) are relative to the caller's directory.
CALLER=$PWD
abspath() { case $1 in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$CALLER" "$1" ;; esac; }
cd "$(dirname "$0")/.."
RPC=${MANTLE_RPC_URL:?set MANTLE_RPC_URL}
NETWORK=${NETWORK:-mainnet}
CCIP_VERSION=1.6.4
POOL_PROGRAM=41FGToCmdaWa1dgZLKFAjvmx6e6AjVTX7SVRibvsMGVB
case $NETWORK in
  mainnet) CHAIN_ID=5000; ROUTER=0x670052635a9850bb45882Cb2eCcF66bCff0F41B7; RMN=0x91E2186E93F0ECeDDCdf9850078F104daB085E79
           TAR=0x000A744940eB5D857c0d61d97015DFc83107404F; MODULE=0xf49f81b3d2F2a79b706621FA2D5934136352140c; SOLANA_SELECTOR=124615329519749607 ;;
  testnet) CHAIN_ID=5003; ROUTER=0xFd33fd627017fEf041445FC19a2B6521C9778f86; RMN=0xcCB84Ec3F6AFdD2052134f74aaAc95Ae41A7B333
           TAR=0x0F1eE88A582f31d92510E300fc1330AA5a525D51; MODULE=0xf76cE612250eeEb8889F49FBCB11f1c2705305F6; SOLANA_SELECTOR=16423721717087811551 ;;
  *) echo "NETWORK must be mainnet or testnet" >&2; exit 1 ;;
esac
DEFAULT_ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
ZERO=0x0000000000000000000000000000000000000000
RL="(bool,uint128,uint128)"

die() { echo "error: $*" >&2; exit 1; }
call() { # cast call; retries transport errors (not reverts), drops cast's "[1.6e19]" annotations
  local out i
  for i in 1 2 3 4; do
    if out=$(cast call "$@" --rpc-url "$RPC" 2>&1); then sed -E 's/ \[[0-9.]+e[0-9]+\]//g' <<<"$out"; return 0; fi
    grep -qiE 'error sending request|connection|timed? ?out|429|50[234]' <<<"$out" || break
    sleep 2
  done
  echo "$out" >&2; return 1
}
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
tx_result() { # cast send --json output → "<tx hash>" (exit 0) or "FAILED: <reason>" (exit 1)
  python3 -I -c '
import sys, json
try: r = json.loads(sys.argv[1])
except ValueError: print("FAILED:", sys.argv[1].strip()[:200]); sys.exit(1)
if "status" in r:
    ok = int(r["status"], 16) == 1
    print(r["transactionHash"] if ok else "FAILED: reverted " + r["transactionHash"]); sys.exit(0 if ok else 1)
print("FAILED:", "; ".join(e.get("message", "")[:200] for e in r.get("errors", [])) or sys.argv[1][:200]); sys.exit(1)' "$1"
}
send() { # key-file to sig args... → prints the tx hash; exits on failure
  local key=$1; shift
  local out; out=$(cast send "$@" --rpc-url "$RPC" --private-key "$(cat "$key")" --json 2>&1) || true
  tx_result "$out" || die "transaction failed"
}
is_timelock() { call "$1" "getMinDelay()(uint256)" >/dev/null 2>&1; }
token_admin() { # the token's single DEFAULT_ADMIN_ROLE holder
  local n; n=$(call "$1" "getRoleMemberCount(bytes32)(uint256)" $DEFAULT_ADMIN_ROLE | awk '{print $1}')
  [ "$n" = 1 ] || die "token has $n DEFAULT_ADMIN_ROLE holders; expected exactly one"
  call "$1" "getRoleMember(bytes32,uint256)(address)" $DEFAULT_ADMIN_ROLE 0
}
solana_remote() { # mint → "<pool config PDA as 0x bytes32> <mint as 0x bytes32>"
  MINT=$1 POOL_PROGRAM=$POOL_PROGRAM npx tsx -e '
    import { address, getAddressEncoder, getProgramDerivedAddress } from "@solana/kit";
    (async () => {
      const enc = getAddressEncoder(); const mint = address(process.env.MINT!);
      const [state] = await getProgramDerivedAddress({ programAddress: address(process.env.POOL_PROGRAM!),
        seeds: [new TextEncoder().encode("ccip_tokenpool_config"), enc.encode(mint)] });
      const hex = (a: string) => "0x" + Buffer.from(enc.encode(address(a))).toString("hex");
      console.log(hex(state), hex(mint));
    })();' 2>/dev/null | tail -1
}
ccip_sources() { # pinned CCIP pool sources, compiled with the mStocks contracts' settings
  local dir=${XDG_CACHE_HOME:-$HOME/.cache}/mstocks-ccip/contracts-ccip-$CCIP_VERSION
  if [ ! -f "$dir/node_modules/@chainlink/contracts-ccip/package.json" ]; then
    mkdir -p "$dir/src"
    npm install --silent --no-save --prefix "$dir" "@chainlink/contracts-ccip@$CCIP_VERSION" >&2
  fi
  cat > "$dir/foundry.toml" <<'TOML'
[profile.default]
src = "src"
libs = ["node_modules"]
solc_version = "0.8.24"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
via_ir = true
remappings = [
  "@chainlink/contracts-ccip/=node_modules/@chainlink/contracts-ccip/",
  "@chainlink/contracts/=node_modules/@chainlink/contracts/",
  "@openzeppelin/contracts@4.8.3/=node_modules/@openzeppelin/contracts-4.8.3/",
  "@openzeppelin/contracts@5.0.2/=node_modules/@openzeppelin/contracts-5.0.2/",
]
TOML
  echo "$dir"
}
safe_json() { # out-file name description (target data)... → Safe Transaction Builder batch
  python3 -I - "$@" "$CHAIN_ID" <<'PY'
import json, sys, time
out, name, desc, *rest = sys.argv[1:]
chain_id = rest.pop()
txs = [{"to": rest[i], "value": "0", "data": rest[i + 1], "contractMethod": None, "contractInputsValues": None}
       for i in range(0, len(rest), 2)]
json.dump({"version": "1.0", "chainId": chain_id, "createdAt": int(time.time() * 1000),
           "meta": {"name": name, "description": desc}, "transactions": txs}, open(out, "w"), indent=2)
PY
  echo "  wrote $1"
}

cmd_deploy() {
  [ $# -ge 4 ] || die "usage: deploy <deployer-key-file> <token> <solana-mint> <pool-owner> (--rate-capacity <wei> --rate-per-second <wei> | --no-rate-limit) [--rate-limit-admin <addr>]"
  local key token=$2 mint=$3 owner=$4; key=$(abspath "$1"); shift 4
  local cap="" rate="" nolimit="" rladmin=""
  while [ $# -gt 0 ]; do case $1 in
    --rate-capacity) cap=$2; shift 2 ;; --rate-per-second) rate=$2; shift 2 ;;
    --no-rate-limit) nolimit=1; shift ;; --rate-limit-admin) rladmin=$2; shift 2 ;;
    *) die "unknown option $1" ;; esac; done
  local limit
  if [ -n "$nolimit" ]; then limit="(false,0,0)"
  elif [ -n "$cap" ] && [ -n "$rate" ]; then limit="(true,$cap,$rate)"
  else die "set --rate-capacity and --rate-per-second, or --no-rate-limit"; fi
  local deployer; deployer=$(cast wallet address --private-key "$(cat "$key")")

  echo "== checks ($NETWORK)"
  [ "$(call "$token" "decimals()(uint8)")" = 18 ] || die "token decimals are not 18"
  local admin; admin=$(token_admin "$token")
  echo "  token $token ($(call "$token" "symbol()(string)")), admin $admin$(is_timelock "$admin" && echo " (timelock, delay $(call "$admin" "getMinDelay()(uint256)" | awk '{print $1}') s)")"
  [ "$(call $ROUTER "isChainSupported(uint64)(bool)" $SOLANA_SELECTOR)" = true ] || die "router does not support the Solana lane"
  local pool_in_registry; pool_in_registry=$(call $TAR "getPool(address)(address)" "$token")
  [ "$(lower "$pool_in_registry")" = "$(lower $ZERO)" ] || die "token already has CCIP pool $pool_in_registry"
  local remote; remote=$(solana_remote "$mint") || die "cannot derive the Solana pool address (run from a checkout with npm install)"
  local remote_pool=${remote% *} remote_token=${remote#* }
  echo "  solana mint $mint → remote pool $remote_pool, remote token $remote_token"
  echo "  deployer $deployer ($(cast balance "$deployer" --rpc-url "$RPC" --ether) MNT), pool owner → $owner"

  echo "== deploy LockReleaseTokenPool $CCIP_VERSION"
  local src; src=$(ccip_sources)
  local pool; pool=$(forge create --root "$src" --rpc-url "$RPC" --private-key "$(cat "$key")" --broadcast --json \
    node_modules/@chainlink/contracts-ccip/contracts/pools/LockReleaseTokenPool.sol:LockReleaseTokenPool \
    --constructor-args "$token" 18 "[]" $RMN $ROUTER | python3 -I -c 'import sys,json; print(json.loads(sys.stdin.read())["deployedTo"])')
  echo "  pool $pool ($(call "$pool" "typeAndVersion()(string)"))"

  echo "== remote chain: Solana ($SOLANA_SELECTOR), rate limits $limit both ways"
  send "$key" "$pool" "applyChainUpdates(uint64[],(uint64,bytes[],bytes,$RL,$RL)[])" "[]" \
    "[($SOLANA_SELECTOR,[$remote_pool],$remote_token,$limit,$limit)]" | sed 's/^/  applyChainUpdates /'
  if [ -n "$rladmin" ]; then send "$key" "$pool" "setRateLimitAdmin(address)" "$rladmin" | sed 's/^/  setRateLimitAdmin /'; fi
  echo "== propose the pool owner"
  send "$key" "$pool" "transferOwnership(address)" "$owner" | sed 's/^/  transferOwnership /'
  echo
  echo "POOL=$pool"
  echo "next: NETWORK=$NETWORK scripts/ccip-mantle-setup.sh multisig $token $pool $owner"
  echo "      tsx scripts/ccip-register.ts ... --remote-token $token --remote-pool $pool   (Solana side)"
}

batch_files() { # actor tag (target data)... → JSON files for one actor
  local actor=$1 tag=$2; shift 2
  local n=$(( $# / 2 ))
  if is_timelock "$actor"; then
    local delay targets="" datas="" values=""
    delay=$(call "$actor" "getMinDelay()(uint256)" | awk '{print $1}')
    local args=("$@") i
    for ((i = 0; i < ${#args[@]}; i += 2)); do
      targets+="${targets:+,}${args[i]}"; datas+="${datas:+,}${args[i+1]}"; values+="${values:+,}0"; done
    local salt; salt=$(cast keccak "$(cast abi-encode "f(string,address,address)" mstocks-ccip "$TOKEN_ADDR" "$POOL_ADDR")")
    local sched exec id
    sched=$(cast calldata "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)" "[$targets]" "[$values]" "[$datas]" 0x"$(printf '0%.0s' {1..64})" "$salt" "$delay")
    exec=$(cast calldata "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)" "[$targets]" "[$values]" "[$datas]" 0x"$(printf '0%.0s' {1..64})" "$salt")
    id=$(call "$actor" "hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)(bytes32)" "[$targets]" "[$values]" "[$datas]" 0x"$(printf '0%.0s' {1..64})" "$salt")
    echo "  $actor is a timelock (delay $delay s): $n call(s) as one batch, operation $id"
    safe_json "$OUT/$tag-1-schedule.json" "$tag: schedule" "Proposer Safe of timelock $actor schedules $n call(s); execute file 2 after $delay s" "$actor" "$sched"
    safe_json "$OUT/$tag-2-execute.json" "$tag: execute" "Executor of timelock $actor executes operation $id after $delay s" "$actor" "$exec"
  else
    echo "  $actor is not a timelock: $n plain call(s)"
    safe_json "$OUT/$tag.json" "$tag" "Calls from $actor" "$@"
  fi
}

cmd_multisig() {
  [ $# -ge 3 ] || die "usage: multisig <token> <pool> <pool-owner> [--out <dir>]"
  TOKEN_ADDR=$1; POOL_ADDR=$2; local owner=$3; shift 3
  OUT=$CALLER; while [ $# -gt 0 ]; do case $1 in --out) OUT=$(abspath "$2"); shift 2 ;; *) die "unknown option $1" ;; esac; done
  mkdir -p "$OUT"
  local sym admin; sym=$(call "$TOKEN_ADDR" "symbol()(string)" | tr -d '"'); admin=$(token_admin "$TOKEN_ADDR")
  local cfg; cfg=$(call $TAR "getTokenConfig(address)((address,address,address))" "$TOKEN_ADDR" | tr -d '() ')
  local reg_admin=${cfg%%,*} rest=${cfg#*,}; local reg_pending=${rest%%,*} reg_pool=${rest#*,}
  echo "token $TOKEN_ADDR ($sym), admin $admin; registry admin $reg_admin pending $reg_pending pool $reg_pool"
  local admin_calls=() owner_calls=()
  if [ "$(lower "$reg_admin")" != "$(lower "$admin")" ]; then
    [ "$(lower "$reg_pending")" = "$(lower "$admin")" ] ||
      admin_calls+=($MODULE "$(cast calldata "registerAccessControlDefaultAdmin(address)" "$TOKEN_ADDR")")
    admin_calls+=($TAR "$(cast calldata "acceptAdminRole(address)" "$TOKEN_ADDR")")
  fi
  [ "$(lower "$reg_pool")" = "$(lower "$POOL_ADDR")" ] ||
    admin_calls+=($TAR "$(cast calldata "setPool(address,address)" "$TOKEN_ADDR" "$POOL_ADDR")")
  [ "$(lower "$(call "$POOL_ADDR" "owner()(address)")")" = "$(lower "$owner")" ] ||
    owner_calls+=("$POOL_ADDR" "$(cast calldata "acceptOwnership()")")
  if [ "$(lower "$owner")" = "$(lower "$admin")" ]; then admin_calls+=("${owner_calls[@]}"); owner_calls=(); fi
  [ ${#admin_calls[@]} -gt 0 ] && batch_files "$admin" "ccip-$sym-token-admin" "${admin_calls[@]}"
  [ ${#owner_calls[@]} -gt 0 ] && batch_files "$owner" "ccip-$sym-pool-owner" "${owner_calls[@]}"
  [ ${#admin_calls[@]} -eq 0 ] && [ ${#owner_calls[@]} -eq 0 ] && echo "nothing to do"
  true
}

cmd_execute() {
  [ "$NETWORK" = testnet ] || die "execute is for testnet only; on mainnet import the JSON into the Safe"
  local key; key=$(abspath "$1"); shift
  for f in "$@"; do
    f=$(abspath "$f")
    python3 -I -c 'import sys,json; [print(t["to"], t["data"]) for t in json.load(open(sys.argv[1]))["transactions"]]' "$f" |
      while read -r to data; do
        local out; out=$(cast send "$to" "$data" --rpc-url "$RPC" --private-key "$(cat "$key")" --json 2>&1) || true
        echo "  $f → $to: $(tx_result "$out")"
      done
  done
}

cmd_verify() {
  [ $# -eq 3 ] || die "usage: verify <token> <pool> <solana-mint>"
  local token=$1 pool=$2 mint=$3 bad=0
  check() { if [ "$(lower "$2")" = "$(lower "$3")" ]; then echo "  ok   $1: $2"; else echo "  FAIL $1: $2 (want $3)"; bad=1; fi; }
  local remote; remote=$(solana_remote "$mint"); local remote_pool=${remote% *} remote_token=${remote#* }
  echo "pool $pool: $(call "$pool" "typeAndVersion()(string)")"
  check "pool token" "$(call "$pool" "getToken()(address)")" "$token"
  check "pool router" "$(call "$pool" "getRouter()(address)")" $ROUTER
  check "pool RMN proxy" "$(call "$pool" "getRmnProxy()(address)")" $RMN
  check "rebalancer (must stay unset)" "$(call "$pool" "getRebalancer()(address)")" $ZERO
  check "allowlist enabled" "$(call "$pool" "getAllowListEnabled()(bool)")" false
  check "supported chains" "$(call "$pool" "getSupportedChains()(uint64[])")" "[$SOLANA_SELECTOR]"
  check "remote pools" "$(call "$pool" "getRemotePools(uint64)(bytes[])" $SOLANA_SELECTOR)" "[$remote_pool]"
  check "remote token" "$(call "$pool" "getRemoteToken(uint64)(bytes)" $SOLANA_SELECTOR)" "$remote_token"
  echo "  info outbound limit $(call "$pool" "getCurrentOutboundRateLimiterState(uint64)((uint128,uint32,bool,uint128,uint128))" $SOLANA_SELECTOR)"
  echo "  info inbound limit  $(call "$pool" "getCurrentInboundRateLimiterState(uint64)((uint128,uint32,bool,uint128,uint128))" $SOLANA_SELECTOR)"
  echo "  info pool owner $(call "$pool" "owner()(address)"), rate limit admin $(call "$pool" "getRateLimitAdmin()(address)")"
  local admin; admin=$(token_admin "$token")
  local cfg; cfg=$(call $TAR "getTokenConfig(address)((address,address,address))" "$token" | tr -d '() ')
  check "registry pool" "${cfg##*,}" "$pool"
  check "registry admin (= token admin)" "${cfg%%,*}" "$admin"
  local compliance; compliance=$(call "$token" "compliance()(address)")
  for a in "$pool" $ROUTER; do check "$a not sanctioned" "$(call "$compliance" "isSanctioned(address)(bool)" "$a")" false; done
  [ $bad = 0 ] && echo "PASS" || { echo "FAILED"; exit 1; }
}

case ${1:-} in
  deploy) shift; cmd_deploy "$@" ;;
  multisig) shift; cmd_multisig "$@" ;;
  execute) shift; cmd_execute "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  *) sed -n '2,32p' "$0"; exit 1 ;;
esac
