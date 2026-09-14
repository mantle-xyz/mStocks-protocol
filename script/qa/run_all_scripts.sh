#!/bin/bash
# 全量执行 QA 链上测试
# Usage: ./script/qa/run_all_scripts.sh
#
# QAInfo ~ QAOperatorWallet 用 run() 全量执行
# QAE2E 调用 run_e2e_full.sh 处理时间等待验证

set -uo pipefail
source .env

LOGDIR="logs/script"
mkdir -p "$LOGDIR"

SCRIPTS=(
  QAInfo
  QAMint
  QATransfer
  QAPause
  QABlocklist
  QASanctions
  QAMultiplier
  QAPermit
  QARole
  QAFactory
  QAMetadata
  QAOperatorWallet
  QANewFeatures
  QABurnRole
  QAPrivatization
  QACustodyClaimRouter
)

PASS=0
FAIL=0
FAILED_LIST=""

for s in "${SCRIPTS[@]}"; do
  echo ""
  echo "==========================================="
  echo "  Running: ${s}"
  echo "==========================================="
  LOGFILE="$LOGDIR/${s}_run.log"
  if forge script "script/qa/${s}.s.sol" \
    --sig "run()" \
    --rpc-url "$RPC_URL" \
    --private-key "$ADMIN_PK" \
    --broadcast \
    -vv 2>&1 | tee "$LOGFILE"; then
    echo "  [OK] ${s}"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${s}"
    FAIL=$((FAIL + 1))
    FAILED_LIST="$FAILED_LIST $s"
  fi
done

# ── E2E 单独处理（含时间等待验证）──
echo ""
echo "==========================================="
echo "  Running: QAE2E (via run_e2e_full.sh)"
echo "==========================================="
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if bash "$SCRIPT_DIR/run_e2e_full.sh"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  FAILED_LIST="$FAILED_LIST QAE2E"
fi

# ── 汇总 ──
TOTAL=$((PASS + FAIL))
echo ""
echo "==========================================="
echo "  Total: ${TOTAL} scripts"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
if [[ -n "$FAILED_LIST" ]]; then
  echo "  Failed:${FAILED_LIST}"
fi
echo "==========================================="
echo "  Logs: $LOGDIR/"
