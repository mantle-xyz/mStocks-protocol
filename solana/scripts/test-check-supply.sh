#!/usr/bin/env bash
# Local test of check-supply.ts: anvil on the EVM side, local validator + Core on Solana.
#   1. Mantle pool holds 2.0, Solana supply 1.5   → OK (exit 0)
#   2. Solana mints 1.0 more (supply 2.5 > 2.0)   → VIOLATION (exit 1)
# The Mantle token is OpenZeppelin's ERC20Mock (18 decimals); the TokenAdminRegistry is a stub whose
# code returns the pool address for any call. Prerequisites: anchor build, scripts/fetch-fixtures.sh,
# npm install, Foundry.
set -euo pipefail
cd "$(dirname "$0")/.."
# Every address is passed explicitly: no network config, no Mantle reads by create-mint.
unset NETWORK MANTLE_RPC_URL
REPO=$(cd .. && pwd)
WORK=$(mktemp -d)
free_port() { python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
ANVIL_PORT=${ANVIL_PORT:-$(free_port)}
EVM=http://127.0.0.1:$ANVIL_PORT
ADMIN_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 # anvil test key #0
POOL=0x00000000000000000000000000000000000000b0
REGISTRY=0x00000000000000000000000000000000000000c0

anvil --silent --port "$ANVIL_PORT" &
ANVIL=$!
CORE_ID=$(solana-keygen pubkey target/deploy/mstocks_core-keypair.json)
for k in deployer admin compliance hook holder; do solana-keygen new --no-bip39-passphrase --silent -o "$WORK/$k.json" >/dev/null; done
pk() { solana-keygen pubkey "$WORK/$1.json"; }
solana-test-validator --reset --quiet --ledger "$WORK/ledger" \
  --bpf-program TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb tests/fixtures/token2022.so \
  --upgradeable-program "$CORE_ID" target/deploy/mstocks_core.so "$WORK/deployer.json" &
VALIDATOR=$!
trap 'kill $ANVIL $VALIDATOR 2>/dev/null; rm -rf "$WORK"' EXIT

# --- EVM: token with 2.0 in the pool; registry stub: PUSH20 pool, MSTORE at 0, RETURN 32 bytes ---
until cast block-number --rpc-url $EVM >/dev/null 2>&1; do sleep 1; done
TOKEN=$(cd "$REPO" && forge create --rpc-url $EVM --private-key $ADMIN_PK --broadcast --json \
  lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol:ERC20Mock \
  | python3 -I -c "import sys,json; print(json.loads(sys.stdin.read())['deployedTo'])")
cast send "$TOKEN" "mint(address,uint256)" $POOL 2000000000000000000 --rpc-url $EVM --private-key $ADMIN_PK >/dev/null
cast rpc anvil_setCode $REGISTRY "0x73${POOL#0x}60005260206000f3" --rpc-url $EVM >/dev/null
echo "mantle (anvil) token: $TOKEN, pool $POOL holds 2.0"

# --- Solana: Core + registered mint mirroring that token; the deployer keeps the mint authority ---
until solana -u l cluster-version >/dev/null 2>&1; do sleep 1; done
for k in deployer admin; do solana -u l airdrop 100 "$(pk $k)" >/dev/null; done
npx tsx scripts/init-core.ts --upgrade-authority "$WORK/deployer.json" --admin "$(pk admin)" --compliance-admin "$(pk compliance)" --hook-authority "$(pk hook)" >/dev/null
npx tsx scripts/grant-role.ts --payer "$WORK/deployer.json" --admin "$WORK/admin.json" --role MintRegistrar --member "$(pk deployer)" >/dev/null
MINT=$(npx tsx scripts/create-mint.ts --payer "$WORK/deployer.json" --registrar "$WORK/deployer.json" --hook-authority "$(pk hook)" \
  --name "Apple mStock" --symbol AAPLm --uri https://example.com --mantle-token "$TOKEN" --initial-multiplier-1e18 1000000000000000000 \
  | awk '/^mint: /{print $2}')
echo "solana mint: $MINT"
mint_to() { npx tsx scripts/dev-mint-to.ts --mint-authority "$WORK/deployer.json" --mint "$MINT" --owner "$(pk holder)" --amount "$1" >/dev/null; }
check() { MANTLE_RPC_URL=$EVM npx tsx scripts/check-supply.ts --registry $REGISTRY --mints "$MINT"; }

# --- 1. backed: 1.5 on Solana, 2.0 locked ---
mint_to 1500000000
echo "== solana supply 1.5, locked 2.0"
check && echo "exit 0 (expected)"

# --- 2. unbacked: 2.5 on Solana ---
mint_to 1000000000
echo "== solana supply 2.5, locked 2.0"
if check; then echo "UNEXPECTED exit 0"; exit 1; else echo "exit 1 (expected)"; fi
echo PASS
