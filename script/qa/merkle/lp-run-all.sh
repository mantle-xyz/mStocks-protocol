#!/usr/bin/env bash
# LP 穿透测试 — 批量执行
#
# 用法:
#   bash script/qa/merkle/lp-run-all.sh                    # 执行全部 LP-01~09
#   bash script/qa/merkle/lp-run-all.sh LP-01 LP-02 LP-05  # 只执行指定用例
#
# 每个用例独立执行（独立 mint + 等确认 + 快照）

cd "$(dirname "$0")/../../.." || exit 1

SCRIPT_DIR="script/qa/merkle"

declare -A SCRIPTS=(
    ["LP-01"]="MS-LP-01_in_range.sh"
    ["LP-02"]="MS-LP-02_out_range_above.sh"
    ["LP-03"]="MS-LP-03_out_range_below.sh"
    ["LP-04"]="MS-LP-04_narrow_vs_wide.sh"
    ["LP-05"]="MS-LP-05_multi_user_diff_range.sh"
    ["LP-06"]="MS-LP-06_same_range_proportional.sh"
    ["LP-07"]="MS-LP-07_nested_range.sh"
    ["LP-08"]="MS-LP-08_overlap_range.sh"
    ["LP-09"]="MS-LP-09_bulk_positions.sh"
)

ORDER=(LP-01 LP-02 LP-03 LP-04 LP-05 LP-06 LP-07 LP-08 LP-09)

# 如果指定了参数，只跑指定的
if [[ $# -gt 0 ]]; then
    RUN_LIST=("$@")
else
    RUN_LIST=("${ORDER[@]}")
fi

TOTAL=${#RUN_LIST[@]}
PASSED=0
FAILED=0
RESULTS=()

echo ""
echo "====================================="
echo "  LP 穿透测试 — 共 $TOTAL 个用例"
echo "====================================="
echo ""

for CASE in "${RUN_LIST[@]}"; do
    SCRIPT="${SCRIPTS[$CASE]:-}"
    if [[ -z "$SCRIPT" ]]; then
        echo "[SKIP] $CASE: 未知用例"
        continue
    fi

    echo "────────────────────────────────────"
    echo "  开始: $CASE ($SCRIPT)"
    echo "────────────────────────────────────"

    if bash "$SCRIPT_DIR/$SCRIPT"; then
        ((PASSED++)) || true
        RESULTS+=("PASS  $CASE")
    else
        ((FAILED++)) || true
        RESULTS+=("FAIL  $CASE")
    fi
    echo ""
done

echo ""
echo "====================================="
echo "  汇总: PASS=$PASSED  FAIL=$FAILED"
echo "====================================="
for R in "${RESULTS[@]}"; do
    echo "  $R"
done
echo "====================================="
