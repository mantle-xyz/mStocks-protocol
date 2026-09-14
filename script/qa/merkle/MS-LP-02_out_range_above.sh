#!/usr/bin/env bash
# MS-LP-02: 区间外做市 — mStock 全部换出 (当前价格高于区间)
#
# 用法:
#   bash MS-LP-02_out_range_above.sh              # 完整: mint + 等确认 + 快照
#   bash MS-LP-02_out_range_above.sh --skip-mint   # 跳过 mint，用已有仓位
#
# 区间整体在当前 tick 下方 → mStock(token1) 全部换成 mUSD
# 期望: 穿透量很小 (锁定本金 ≈ 0)

cd "$(dirname "$0")/../../.." || exit 1
source .env
source script/qa/merkle/common.sh
source script/qa/merkle/lp-common.sh

SKIP_MINT=false
[[ "${1:-}" == "--skip-mint" ]] && SKIP_MINT=true

LOGFILE="$LOGDIR/MS-LP-02.log"
exec > >(tee "$LOGFILE") 2>&1

log_case "MS-LP-02: 区间外做市 — mStock 全部换出 (价格高于区间)"

CURRENT_TICK=$(get_current_tick)
log_step "当前 tick = $CURRENT_TICK"

if [[ "$SKIP_MINT" == "false" ]]; then
    TICK_UPPER=$(align_tick $((CURRENT_TICK - 10)) $TICK_SPACING)
    TICK_LOWER=$(align_tick $((CURRENT_TICK - 30)) $TICK_SPACING)
    log_step "区间: [$TICK_LOWER, $TICK_UPPER] (整体在当前 tick 下方)"

    QATST_BEFORE=$(chain_balance "$TOKEN1" "$USER_A_ADDR")
    # 当前 tick 高于区间 → 只需 token0 (mUSD)
    TOKEN_ID=$(mint_position "$TICK_LOWER" "$TICK_UPPER" 100000000 0 "$USER_A_PK")

    if [[ "$TOKEN_ID" == "0" || -z "$TOKEN_ID" ]]; then
        log_fail "添加流动性失败"
        log_summary
        exit 1
    fi
    log_pass "添加流动性成功, tokenId=$TOKEN_ID"

    QATST_AFTER=$(chain_balance "$TOKEN1" "$USER_A_ADDR")
    QATST_DIFF=$(python3 -c "print(int('$QATST_BEFORE') - int('$QATST_AFTER'))")
    log_step "QATST 减少量: $QATST_DIFF (期望 ≈ 0)"

    mark_block
    RB=$(wait_and_get_record_block 150)
else
    log_step "跳过 mint，使用已有仓位"
    RB=$(safe_record_block)
    log_step "使用 recordBlock=$RB"
fi

# ── 快照验证 ──
SNAP_RESP=$(snapshot_with_lp "$RB")

SNAP_STATUS=$(echo "$SNAP_RESP" | jq -r '.status')
if [[ "$SNAP_STATUS" != "SNAPSHOT_STATUS_READY" ]]; then
    log_fail "快照失败: $SNAP_STATUS"
    echo "$SNAP_RESP" | jq '.failureReason'
    log_summary
    exit 1
fi

SID=$(echo "$SNAP_RESP" | jq -r '.snapshotId')
log_step "snapshotId: $SID"

HOLDING=$(get_allocation_holding "$SID" "$USER_A_ADDR")
CHAIN_BAL=$(chain_balance "$TOKEN1" "$USER_A_ADDR")
DIFF=$(python3 -c "print(int('$HOLDING') - int('$CHAIN_BAL'))" 2>/dev/null || echo "N/A")
log_step "快照 holding: $HOLDING"
log_step "链上 balanceOf: $CHAIN_BAL"
log_step "穿透量 (holding - balanceOf): $DIFF"

IS_SMALL=$(python3 -c "
diff = int('$HOLDING') - int('$CHAIN_BAL')
total = int('$HOLDING') if int('$HOLDING') > 0 else 1
ratio = abs(diff) / total
print('yes' if ratio < 0.01 else 'no')
" 2>/dev/null || echo "no")

if [[ "$IS_SMALL" == "yes" ]]; then
    log_pass "穿透量很小 ($DIFF)，mStock 锁定本金 ≈ 0（符合预期）"
else
    log_fail "穿透量 ($DIFF) 超出预期"
fi

log_summary
