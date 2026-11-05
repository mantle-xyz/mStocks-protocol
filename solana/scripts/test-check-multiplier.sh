#!/usr/bin/env bash
# Local test of check-multiplier.ts against a real Mantle ScaledToken:
# anvil + ScaledToken behind an ERC1967 proxy on the EVM side, local validator + Core on Solana.
#   1. both chains schedule the same multiplier  → OK (exit 0)
#   2. Solana is rescheduled to a different value → MISMATCH (exit 1)
# Prerequisites: anchor build, scripts/fetch-fixtures.sh, npm install, Foundry.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$(cd .. && pwd)
WORK=$(mktemp -d)
# A free port, so the test never collides with a developer's own anvil instances.
ANVIL_PORT=${ANVIL_PORT:-$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}
EVM=http://127.0.0.1:$ANVIL_PORT

# --- EVM: real ScaledToken on anvil (deployed with forge create; nothing written to the repo) ---
# anvil's public test keys: #0 is the token admin, #1 the multiplier scheduler (ScaledToken
# rejects the admin as an operator).
ADMIN_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ADMIN_ADDR=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SCHED_PK=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
SCHED_ADDR=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
anvil --silent --port "$ANVIL_PORT" &
ANVIL=$!
CORE_ID=$(solana-keygen pubkey target/deploy/mstocks_core-keypair.json)
for k in deployer admin hook scheduler; do solana-keygen new --no-bip39-passphrase --silent -o "$WORK/$k.json" >/dev/null; done
pk() { solana-keygen pubkey "$WORK/$1.json"; }
solana-test-validator --reset --quiet --ledger "$WORK/ledger" \
  --bpf-program TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb tests/fixtures/token2022.so \
  --upgradeable-program "$CORE_ID" target/deploy/mstocks_core.so "$WORK/deployer.json" &
VALIDATOR=$!
trap 'kill $ANVIL $VALIDATOR 2>/dev/null; rm -rf "$WORK"' EXIT

until cast block-number --rpc-url $EVM >/dev/null 2>&1; do sleep 1; done
# --constructor-args is variadic, so it (inside "$@") must come last.
create() { (cd "$REPO" && forge create --rpc-url $EVM --private-key $ADMIN_PK --broadcast --json "$@") \
  | python3 -I -c "import sys,json; print(json.loads(sys.stdin.read())['deployedTo'])"; }
COMPLIANCE=$(create src/complianceRegistry/ComplianceRegistry.sol:ComplianceRegistry --constructor-args $ADMIN_ADDR)
PAUSE=$(create src/pauseRegistry/PauseRegistry.sol:PauseRegistry --constructor-args $ADMIN_ADDR)
IMPL=$(create src/scaledToken/ScaledToken.sol:ScaledToken --constructor-args 300)
INIT=$(cast calldata "initialize(string,string,string,address,address,address,address[],address[],address[])" \
  "Apple mStock" AAPLm US0378331005 $COMPLIANCE $PAUSE $ADMIN_ADDR "[]" "[$SCHED_ADDR]" "[]")
TOKEN=$(create lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy --constructor-args $IMPL $INIT)
echo "mantle (anvil) ScaledToken: $TOKEN"

# --- Solana: Core + registered mint mirroring that token ---
until solana -u l cluster-version >/dev/null 2>&1; do sleep 1; done
for k in deployer admin scheduler; do solana -u l airdrop 100 "$(pk $k)" >/dev/null; done
npx tsx scripts/init-core.ts --upgrade-authority "$WORK/deployer.json" --admin "$(pk admin)" --hook-authority "$(pk hook)" >/dev/null
npx tsx scripts/grant-role.ts --payer "$WORK/deployer.json" --admin "$WORK/admin.json" --role MultiplierScheduler --member "$(pk scheduler)" >/dev/null
MINT=$(npx tsx scripts/create-mint.ts --payer "$WORK/deployer.json" --admin "$WORK/admin.json" --hook-authority "$(pk hook)" \
  --name "Apple mStock" --symbol AAPLm --uri https://example.com --mantle-token "$TOKEN" --initial-multiplier-1e18 1000000000000000000 \
  | awk '/^mint: /{print $2}')
echo "solana mint: $MINT"

# --- 1. same schedule on both chains (plan B) ---
AT=$(( $(date +%s) + 3600 ))
cast send "$TOKEN" "setUIMultiplier(uint256,uint256)" 1500000000000000000 $AT --rpc-url $EVM --private-key $SCHED_PK >/dev/null
npx tsx scripts/schedule-multiplier.ts --scheduler "$WORK/scheduler.json" --mint "$MINT" --multiplier-1e18 1500000000000000000 --effective-at $AT >/dev/null
echo "== same schedule on both chains"
MANTLE_RPC_URL=$EVM npx tsx scripts/check-multiplier.ts --mints "$MINT" && echo "exit 0 (expected)"

# --- 2. Solana drifts ---
npx tsx scripts/schedule-multiplier.ts --scheduler "$WORK/scheduler.json" --mint "$MINT" --multiplier-1e18 2000000000000000000 --effective-at $AT >/dev/null
echo "== solana rescheduled to 2.0"
if MANTLE_RPC_URL=$EVM npx tsx scripts/check-multiplier.ts --mints "$MINT"; then echo "UNEXPECTED exit 0"; exit 1; else echo "exit 1 (expected)"; fi
