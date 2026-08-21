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

echo ">>> Running $TEST_NAME ($FILE)"
echo ">>> Log: $LOGFILE"

if $READONLY; then
    forge script "$FILE" \
      --sig "${TEST_NAME}()" \
      --rpc-url "$RPC_URL" \
      -v 2>&1 | tee "$LOGFILE"
else
    forge script "$FILE" \
      --sig "${TEST_NAME}()" \
      --rpc-url "$RPC_URL" \
      --private-key "$ADMIN_PK" \
      --broadcast --slow \
      -vv 2>&1 | tee "$LOGFILE"
fi

SCRIPT_NAME=$(basename "$FILE" .s.sol)
BROADCAST="broadcast/${SCRIPT_NAME}.s.sol/${CHAIN_ID}/${TEST_NAME}-latest.json"
[[ -f "$BROADCAST" ]] && jq -r '.transactions[].hash' "$BROADCAST" | while read h; do echo "tx: $h"; done | tee -a "$LOGFILE"

echo ">>> Done. Log: $LOGFILE"
