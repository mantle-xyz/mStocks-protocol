#!/usr/bin/env bash
set -euo pipefail

LOGDIR="logs/qa"
rm -rf "$LOGDIR"
mkdir -p "$LOGDIR"

JOBS=${QA_JOBS:-16}   # 并行数，默认 8，可通过 QA_JOBS=N 调整

TOTAL=0
PIDS=()
TESTS=()

run_test() {
    local file=$1 t=$2
    local logfile="$LOGDIR/${t}.log"
    forge test --match-path "$file" --match-test "^${t}\b" -vvvv > "$logfile" 2>&1
}

for file in test/qa/*.t.sol; do
    [[ "$file" == "test/qa/BaseQA.t.sol" ]] && continue
    [[ -f "$file" ]] || continue

    tests=$(grep -oE 'function (test[A-Za-z_0-9]+)' "$file" | awk '{print $2}')

    for t in $tests; do
        # throttle: wait if we hit the parallel limit
        while (( ${#PIDS[@]} >= JOBS )); do
            wait -n 2>/dev/null || true
            # clean up finished PIDs
            NEW_PIDS=()
            NEW_TESTS=()
            for i in "${!PIDS[@]}"; do
                if kill -0 "${PIDS[$i]}" 2>/dev/null; then
                    NEW_PIDS+=("${PIDS[$i]}")
                    NEW_TESTS+=("${TESTS[$i]}")
                fi
            done
            PIDS=("${NEW_PIDS[@]+"${NEW_PIDS[@]}"}")
            TESTS=("${NEW_TESTS[@]+"${NEW_TESTS[@]}"}")
        done

        run_test "$file" "$t" &
        PIDS+=($!)
        TESTS+=("$t|$file")
        ((TOTAL++))
    done
done

# wait for all remaining
wait

# collect results
PASSED=0
FAILED=0
FAILED_LIST=()

for file in test/qa/*.t.sol; do
    [[ "$file" == "test/qa/BaseQA.t.sol" ]] && continue
    [[ -f "$file" ]] || continue

    tests=$(grep -oE 'function (test[A-Za-z_0-9]+)' "$file" | awk '{print $2}')

    for t in $tests; do
        logfile="$LOGDIR/${t}.log"
        if grep -q "\[PASS\]" "$logfile" 2>/dev/null; then
            echo ">>> $t ($file) — PASSED"
            ((PASSED++))
        else
            echo ">>> $t ($file) — FAILED"
            ((FAILED++))
            FAILED_LIST+=("$t")
        fi
    done
done

echo ""
echo "========================================"
echo "QA Test Summary"
echo "========================================"
echo "PASSED: $PASSED"
echo "FAILED: $FAILED"
echo "TOTAL:  $((PASSED + FAILED))"

if [[ ${#FAILED_LIST[@]} -gt 0 ]]; then
    echo ""
    echo "Failed tests:"
    for f in "${FAILED_LIST[@]}"; do
        echo "  - $f"
    done
    exit 1
fi

echo ""
echo "All tests passed!"
