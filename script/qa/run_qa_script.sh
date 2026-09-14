#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 [-r] <test_function_name>"
    echo "  -r    read-only mode (no broadcast, faster)"
    echo ""
    echo "Examples:"
    echo "  $0 test_INFO01        # broadcast mode (default)"
    echo "  $0 -r test_INFO01     # read-only mode"
    exit 1
}

READONLY=false
while getopts "r" opt; do
    case $opt in
        r) READONLY=true ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[[ $# -lt 1 ]] && usage

TEST_NAME="$1"
LOGDIR="logs/script"
mkdir -p "$LOGDIR"

source .env

FILE=$(grep -rl "function ${TEST_NAME}(" script/qa/*.s.sol 2>/dev/null | head -1)

if [[ -z "$FILE" ]]; then
    echo "Error: test function '$TEST_NAME' not found in script/qa/"
    exit 1
fi

LOGFILE="$LOGDIR/${TEST_NAME}.log"

# Detect target contract: find the contract that contains the test function.
# Walk backwards from the function definition to the nearest "contract ... {" line.
CONTRACT_NAME=$(awk "/contract .* is /{name=\$2} /function ${TEST_NAME}\(/{print name; exit}" "$FILE")
TC_FLAG=""
if [[ -n "$CONTRACT_NAME" ]]; then
    TC_FLAG="--tc $CONTRACT_NAME"
fi

echo ">>> Running $TEST_NAME ($FILE${CONTRACT_NAME:+ :: $CONTRACT_NAME})"
echo ">>> Log: $LOGFILE"

if $READONLY; then
    forge script "$FILE" $TC_FLAG \
      --sig "${TEST_NAME}()" \
      --rpc-url "$RPC_URL" \
      -v 2>&1 | tee "$LOGFILE"
else
    set +e
    forge script "$FILE" $TC_FLAG \
      --sig "${TEST_NAME}()" \
      --rpc-url "$RPC_URL" \
      --private-key "$ADMIN_PK" \
      --broadcast --slow --timeout 120 \
      -vv 2>&1 | tee "$LOGFILE"
    RC=$?
    set -e

    # Auto-resume on broadcast failure (proxyd backend lag: nonce desync or stale state)
    if [[ $RC -ne 0 ]] && grep -q "Failed to send transaction" "$LOGFILE"; then
        for i in 1 2 3; do
            echo ">>> Broadcast failed (proxyd lag), waiting 15s then resume (attempt $i/3)..."
            sleep 15
            set +e
            forge script "$FILE" $TC_FLAG \
              --sig "${TEST_NAME}()" \
              --rpc-url "$RPC_URL" \
              --private-key "$ADMIN_PK" \
              --broadcast --timeout 120 --resume \
              -vv 2>&1 | tee -a "$LOGFILE"
            RC=$?
            set -e
            [[ $RC -eq 0 ]] && break
        done
    fi

    [[ $RC -ne 0 ]] && echo ">>> WARNING: broadcast incomplete (exit code $RC)" >&2
fi

SCRIPT_NAME=$(basename "$FILE" .s.sol)
BROADCAST="broadcast/${SCRIPT_NAME}.s.sol/${CHAIN_ID}/${TEST_NAME}-latest.json"
[[ -f "$BROADCAST" ]] && jq -r '.transactions[].hash' "$BROADCAST" | while read h; do echo "tx: $h"; done | tee -a "$LOGFILE"

echo ">>> Done. Log: $LOGFILE"
