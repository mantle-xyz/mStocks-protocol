#!/usr/bin/env bash
# MS-LP-06: 多 LP 同区间按比例
#
# 用法:
#   bash MS-LP-06_same_range_proportional.sh              # 完整: mint + 等确认 + 快照
#   bash MS-LP-06_same_range_proportional.sh --skip-mint   # 跳过 mint，用已有仓位
#
# A 和 B 完全相同区间，B 投入 2 倍
# 期望: B 穿透量 ≈ A 的 2 倍

cd "$(dirname "$0")/../../.." || exit 1
source .env
source script/qa/merkle/common.sh
source script/qa/merkle/lp-common.sh

SKIP_MINT=false
[[ "${1:-}" == "--skip-mint" ]] && SKIP_MINT=true

LOGFILE="$LOGDIR/MS-LP-06.log"
exec > >(tee "$LOGFILE") 2>&1

log_case "MS-LP-06: 多 LP 同区间按比例"

CURRENT_TICK=$(get_current_tick)
log_step "当前 tick = $CURRENT_TICK"

if [[ "$SKIP_MINT" == "false" ]]; then
    # 前置: 确保 USER_B 有余额
    USER_B_MUSD=$(chain_balance "$TOKEN0" "$USER_B_ADDR")
    USER_B_QATST=$(chain_balance "$TOKEN1" "$USER_B_ADDR")
    NEED_MUSD=$(python3 -c "print('yes' if int('$USER_B_MUSD') < 200000000 else 'no')")
    if [[ "$NEED_MUSD" == "yes" ]]; then
        log_step "USER_B mUSD 不足，mint 500 mUSD"
        cast send "$TOKEN0" "mint(address,uint256)" "$USER_B_ADDR" 500000000 \
            --rpc-url "$RPC" --private-key "$ADMIN_PK" > /dev/null 2>&1 || true
    fi
    NEED_QATST=$(python3 -c "print('yes' if int('$USER_B_QATST') < 200000000000000000000 else 'no')")
    if [[ "$NEED_QATST" == "yes" ]]; then
        log_step "USER_B QATST 不足，mint 500 QATST"
        cast send "$TOKEN1" "mint(address,uint256)" "$USER_B_ADDR" "500000000000000000000" \
            --rpc-url "$RPC" --private-key "$ADMIN_PK" > /dev/null 2>&1 || true
    fi

    TICK_LOWER=$(align_tick $((CURRENT_TICK - 10)) $TICK_SPACING)
    TICK_UPPER=$(align_tick $((CURRENT_TICK + 10)) $TICK_SPACING)
    log_step "共同区间: [$TICK_LOWER, $TICK_UPPER]"

    # USER_A: 1x (25 mUSD + 25 QATST)
    log_step "USER_A: 1x 流动性"
    A_TOKEN_ID=$(mint_position "$TICK_LOWER" "$TICK_UPPER" 25000000 25000000000000000000 "$USER_A_PK")
    if [[ "$A_TOKEN_ID" == "0" || -z "$A_TOKEN_ID" ]]; then
        log_fail "USER_A 添加流动性失败"; log_summary; exit 1
    fi
    log_pass "USER_A tokenId=$A_TOKEN_ID"

    # USER_B: 2x (50 mUSD + 50 QATST)
    log_step "USER_B: 2x 流动性"
    B_TOKEN_ID=$(mint_position "$TICK_LOWER" "$TICK_UPPER" 50000000 50000000000000000000 "$USER_B_PK")
    if [[ "$B_TOKEN_ID" == "0" || -z "$B_TOKEN_ID" ]]; then
        log_fail "USER_B 添加流动性失败"; log_summary; exit 1
    fi
    log_pass "USER_B tokenId=$B_TOKEN_ID"

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
    log_summary; exit 1
fi

SID=$(echo "$SNAP_RESP" | jq -r '.snapshotId')
log_step "snapshotId: $SID"

A_HOLDING=$(get_allocation_holding "$SID" "$USER_A_ADDR")
A_CHAIN_BAL=$(chain_balance "$TOKEN1" "$USER_A_ADDR")
A_DIFF=$(python3 -c "print(int('$A_HOLDING') - int('$A_CHAIN_BAL'))")
log_step "USER_A: holding=$A_HOLDING, balanceOf=$A_CHAIN_BAL, 穿透量=$A_DIFF"

B_HOLDING=$(get_allocation_holding "$SID" "$USER_B_ADDR")
B_CHAIN_BAL=$(chain_balance "$TOKEN1" "$USER_B_ADDR")
B_DIFF=$(python3 -c "print(int('$B_HOLDING') - int('$B_CHAIN_BAL'))")
log_step "USER_B: holding=$B_HOLDING, balanceOf=$B_CHAIN_BAL, 穿透量=$B_DIFF"

RATIO_CHECK=$(python3 -c "
a = int('$A_DIFF')
b = int('$B_DIFF')
if a > 0:
    ratio = b / a
    print(f'B/A ratio = {ratio:.4f}')
    print('PASS' if 1.8 <= ratio <= 2.2 else 'FAIL')
else:
    print('A 穿透量 <= 0，无法计算比例')
    print('FAIL')
")
echo "$RATIO_CHECK"

RESULT=$(echo "$RATIO_CHECK" | tail -1)
[[ "$RESULT" == "PASS" ]] && log_pass "B 穿透量 ≈ 2x A (A=$A_DIFF, B=$B_DIFF)" || log_fail "B/A 比例不在 1.8~2.2 范围 (A=$A_DIFF, B=$B_DIFF)"

log_summary
