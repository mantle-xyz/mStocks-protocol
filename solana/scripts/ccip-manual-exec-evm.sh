#!/usr/bin/env bash
# Manually executes a CCIP message on the EVM side (Solana → Mantle) whose automatic execution
# failed, e.g. the Mantle token was paused, the receiver sanctioned, or the pool's inbound rate
# limit exceeded; the DON does not retry such a message. Takes the failed execution transaction
# (the CCIP explorer shows it on the message page), reuses its execution report and calls the
# OffRamp's manuallyExecute. A FAILURE message can be re-executed at once; messages in the report
# that already succeeded are skipped by the OffRamp. TOKEN_GAS raises the gas for each token
# transfer (releaseOrMint) when the original destGasAmount was too low; 0 keeps it.
#   MANTLE_RPC_URL=<rpc> [TOKEN_GAS=150000] scripts/ccip-manual-exec-evm.sh <failed execution tx hash> <private key file>
set -euo pipefail
: "${MANTLE_RPC_URL:?set MANTLE_RPC_URL}"
TX=${1:?failed execution tx hash}
KEY=${2:?file with the hex private key that pays the gas}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
TARGET=$(cast tx "$TX" to --rpc-url "$MANTLE_RPC_URL")
cast tx "$TX" input --rpc-url "$MANTLE_RPC_URL" >"$WORK/input"
EXECUTE=$(cast sig "execute(bytes32[2],bytes)")
REPORT='(uint64,((bytes32,uint64,uint64,uint64,uint64),bytes,bytes,address,uint256,(bytes,address,uint32,bytes,uint256)[])[],bytes[][],bytes32[],uint256)[]'
MANUAL=$(cast sig "manuallyExecute(${REPORT},(uint256,uint32[])[][])")

# execute(bytes32[2] reportContext, bytes report), report = abi.encode(ExecutionReport[]).
# manuallyExecute(ExecutionReport[] reports, GasLimitOverride[][] overrides) reuses the reports'
# encoding as is; overrides must match their shape (one per message, one gas value per token).
python3 -I - "$WORK/input" "$EXECUTE" "$MANUAL" "${TOKEN_GAS:-0}" >"$WORK/calldata" <<'EOF'
import sys
inp, execute, manual = open(sys.argv[1]).read().strip()[2:], sys.argv[2][2:], sys.argv[3][2:]
token_gas = int(sys.argv[4])
if inp[:8] != execute: sys.exit(f"not an OffRamp execute call (selector 0x{inp[:8]})")
b = bytes.fromhex(inp[8:])
w = lambda buf, at: int.from_bytes(buf[at:at + 32], "big")
report_at = w(b, 64)  # head: reportContext (2 words), offset of report
report = b[report_at + 32:report_at + 32 + w(b, report_at)]
assert w(report, 0) == 32
reports = report[32:]  # ExecutionReport[] encoding

def word(v): return v.to_bytes(32, "big")
def dyn_array(items):  # array of dynamic elements
    head, tail = b"", b""
    for it in items:
        head += word(32 * len(items) + len(tail)); tail += it
    return word(len(items)) + head + tail

shape, msgs = [], []
for i in range(w(reports, 0)):
    r = 32 + w(reports, 32 + 32 * i)
    m_at = r + w(reports, r + 32)
    per = []
    for j in range(w(reports, m_at)):
        m = m_at + 32 + w(reports, m_at + 32 + 32 * j)
        msgs.append("0x" + reports[m:m + 32].hex())
        t_at = m + w(reports, m + 32 * 9)  # header (5 words), sender, data, receiver, gasLimit, tokenAmounts
        per.append(w(reports, t_at))
    shape.append(per)
overrides = dyn_array([dyn_array([word(0) + word(64) + word(t) + word(token_gas) * t for t in per]) for per in shape])
print("messages in the report: " + " ".join(msgs), file=sys.stderr)
print("0x" + manual + (word(64) + word(64 + len(reports)) + reports + overrides).hex())
EOF
echo "OffRamp $TARGET"
cast send "$TARGET" "$(cat "$WORK/calldata")" --rpc-url "$MANTLE_RPC_URL" --private-key "$(cat "$KEY")" --json |
  python3 -I -c '
import sys, json
r = json.load(sys.stdin)
if "status" not in r: sys.exit("manuallyExecute failed: " + "; ".join(e["message"] for e in r.get("errors", [])))
print("manuallyExecute status", int(r["status"], 16), r["transactionHash"])'
