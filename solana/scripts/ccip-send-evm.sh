#!/usr/bin/env bash
# Sends a Mantle token to a Solana wallet through CCIP (the LockRelease pool on Mantle locks; the
# BurnMint pool on Solana mints into the wallet's associated token account, created if missing).
# Pays the CCIP fee in native MNT and prints the CCIP message id. Mantle → Solana waits for Mantle
# finality, so delivery takes about 20–25 minutes on Sepolia.
#   MANTLE_RPC_URL=<rpc> scripts/ccip-send-evm.sh <private key file> <mantle token> <solana wallet> <amount wei>
#   [ROUTER=0xFd33fd627017fEf041445FC19a2B6521C9778f86] [DEST_SELECTOR=16423721717087811551]
set -euo pipefail
: "${MANTLE_RPC_URL:?set MANTLE_RPC_URL}"
KEY=${1:?file with the sender hex private key}
TOKEN=${2:?mantle token address}
WALLET=${3:?solana wallet (base58)}
AMOUNT=${4:?amount in wei (18 decimals)}
ROUTER=${ROUTER:-0xFd33fd627017fEf041445FC19a2B6521C9778f86} # Mantle Sepolia router
DEST_SELECTOR=${DEST_SELECTOR:-16423721717087811551}       # Solana devnet

# The token receiver is the wallet (not its token account) as bytes32.
RECEIVER=$(python3 -I - "$WALLET" <<'EOF'
import sys
alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n = 0
for c in sys.argv[1]:
    n = n * 58 + alphabet.index(c)
print("0x" + n.to_bytes(32, "big").hex())
EOF
)
# SVMExtraArgsV1 (tag 0x1f3b3aba): compute units 0, writable bitmap 0, out-of-order execution,
# token receiver, no extra accounts.
EXTRA=0x1f3b3aba$(cast abi-encode "f((uint32,uint64,bool,bytes32,bytes32[]))" "(0,0,true,$RECEIVER,[])" | cut -c3-)
MSG="(0x0000000000000000000000000000000000000000000000000000000000000000,0x,[($TOKEN,$AMOUNT)],0x0000000000000000000000000000000000000000,$EXTRA)"
SIG="(bytes,bytes,(address,uint256)[],address,bytes)"

FEE=$(cast call "$ROUTER" "getFee(uint64,$SIG)(uint256)" "$DEST_SELECTOR" "$MSG" --rpc-url "$MANTLE_RPC_URL" | awk '{print $1}')
[ -n "$FEE" ] || { echo "getFee failed" >&2; exit 1; }
echo "fee $(cast from-wei "$FEE") MNT"
cast send "$TOKEN" "approve(address,uint256)" "$ROUTER" "$AMOUNT" --rpc-url "$MANTLE_RPC_URL" --private-key "$(cat "$KEY")" >/dev/null
cast send "$ROUTER" "ccipSend(uint64,$SIG)" "$DEST_SELECTOR" "$MSG" --value "$FEE" \
  --rpc-url "$MANTLE_RPC_URL" --private-key "$(cat "$KEY")" --json |
  python3 -I -c '
import sys, json
r = json.load(sys.stdin)
if "status" not in r: sys.exit("ccipSend failed: " + "; ".join(e["message"] for e in r.get("errors", [])))
print("ccipSend status", int(r["status"], 16), r["transactionHash"])
# CCIPMessageSent(uint64 indexed destChainSelector, uint64 indexed sequenceNumber, message):
# the message starts with its header, whose first word is the message id.
for l in r["logs"]:
    if l["topics"][0].lower() == "0x192442a2b2adb6a7948f097023cb6b57d29d3a7a5dd33e6666d33c39cc456f32":
        print("messageId 0x" + l["data"][2 + 64:2 + 128])'
