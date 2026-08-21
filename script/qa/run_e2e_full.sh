#!/usr/bin/env bash
# E2E 全量执行（含时间等待验证）
# 用法: ./script/qa/run_e2e_full.sh
#
# 时间依赖用例 multiplier effectiveTime = t+300s (5min)
#   E2E-02: setup -> (跑其他用例 ~5min) -> verify
#   E2E-03: setup -> (跑其他用例 ~5min) -> verify
#   E2E-14: setup -> (跑其他用例 ~5min) -> verify
#   E2E-23: setup -> wait 300s -> verify
#
# 所有 E2E 用例使用独立 tokenB 或内含 cleanup，不污染主 token 状态

set -uo pipefail
source .env

LOGDIR="logs/script"
mkdir -p "$LOGDIR"

PASS=0
FAIL=0
FAILED_CASES=""

run_case() {
    local fn="$1"
    echo ""
    echo ">>> Running $fn"
    if forge script script/qa/QAE2E.s.sol \
      --sig "${fn}()" \
      --rpc-url "$RPC_URL" \
      --private-key "$ADMIN_PK" \
      --broadcast \
      -vv 2>&1 | tee "$LOGDIR/${fn}.log"; then
        PASS=$((PASS + 1))
        echo ">>> [OK] $fn"
    else
        FAIL=$((FAIL + 1))
        FAILED_CASES="$FAILED_CASES $fn"
        echo ">>> [FAIL] $fn"
    fi
}

# 记录 E2E-02 setup 的开始时间
E2E02_START=0

# ── 阶段 1: E2E-01 ──
run_case test_E2E01

# ── 阶段 2: E2E-02 setup (独立 tokenB: SPTB, multiplier t+300s) ──
E2E02_START=$(date +%s)
run_case test_E2E02

# ── 阶段 3: E2E-03 ~ E2E-13 (无时间依赖, 各自含 cleanup) ──
for i in $(seq -w 3 13); do
    run_case "test_E2E${i}"
done

# ── 阶段 4: E2E-14 setup (独立 tokenB: SCHB, multiplier t+300s) ──
run_case test_E2E14

# ── 等待 multiplier 生效 ──
# E2E-02 设的是 t+300s，计算还需等多久
ELAPSED=$(( $(date +%s) - E2E02_START ))
REMAINING=$(( 310 - ELAPSED ))
if (( REMAINING > 0 )); then
    echo ""
    echo "==========================================="
    echo "  Waiting ${REMAINING}s for multiplier activation (E2E-02, E2E-14)..."
    echo "==========================================="
    sleep "$REMAINING"
else
    echo ""
    echo "  Multiplier already active (${ELAPSED}s elapsed since E2E-02 setup)"
fi

# ── 阶段 5: verify E2E-02, E2E-03, E2E-14 ──
run_case test_E2E02_verify
run_case test_E2E03_verify
run_case test_E2E14_verify

# ── 阶段 6: E2E-15 ~ E2E-22 (各自含 cleanup) ──
for i in $(seq -w 15 22); do
    run_case "test_E2E${i}"
done

# ── 阶段 7: E2E-23 setup (独立 tokenB: MULB, multiplier t+300s) ──
E2E23_START=$(date +%s)
run_case test_E2E23

# ── 等待 E2E-23 multiplier 生效 ──
ELAPSED=$(( $(date +%s) - E2E23_START ))
REMAINING=$(( 310 - ELAPSED ))
if (( REMAINING > 0 )); then
    echo ""
    echo "==========================================="
    echo "  Waiting ${REMAINING}s for multiplier activation (E2E-23)..."
    echo "==========================================="
    sleep "$REMAINING"
fi

# ── 阶段 8: verify E2E-23 ──
run_case test_E2E23_verify

# ── 汇总 ──
TOTAL=$((PASS + FAIL))
echo ""
echo "==========================================="
echo "  E2E Total: ${TOTAL} cases"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
if [[ -n "$FAILED_CASES" ]]; then
    echo "  Failed cases:${FAILED_CASES}"
fi
echo "==========================================="
echo "  Logs: $LOGDIR/"
