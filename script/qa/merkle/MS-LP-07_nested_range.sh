#!/usr/bin/env bash
# MS-LP-07: 嵌套区间（大区间包小区间）
#
# 用法:
#   bash MS-LP-07_nested_range.sh              # 完整: mint + 等确认 + 快照
#   bash MS-LP-07_nested_range.sh --skip-mint   # 跳过 mint，用已有仓位
#
# A: 宽区间 (±50), B: 窄区间 (±5)，完全在 A 内部
# 期望: 两者穿透量 > 0，之和 + 残差 ≈ 池子 mStock 余额

cd "$(dirname "$0")/../../.." || exit 1
source .env
source script/qa/merkle/common.sh
source script/qa/merkle/lp-common.sh

SKIP_MINT=false
[[ "${1:-}" == "--skip-mint" ]] && SKIP_MINT=true

LOGFILE="$LOGDIR/MS-LP-07.log"
exec > >(tee "$LOGFILE") 2>&1

log_case "MS-LP-07: 嵌套区间（大区间包小区间）"

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

    # USER_A: 宽区间 (±50)
    A_LOWER=$(align_tick $((CURRENT_TICK - 50)) $TICK_SPACING)
    A_UPPER=$(align_tick $((CURRENT_TICK + 50)) $TICK_SPACING)
    log_step "USER_A 宽区间: [$A_LOWER, $A_UPPER]"
    A_TOKEN_ID=$(mint_position "$A_LOWER" "$A_UPPER" 50000000 50000000000000000000 "$USER_A_PK")
    if [[ "$A_TOKEN_ID" == "0" || -z "$A_TOKEN_ID" ]]; then
        log_fail "USER_A 添加宽区间失败"; log_summary; exit 1
    fi
    log_pass "USER_A 宽区间 tokenId=$A_TOKEN_ID"

    # USER_B: 窄区间 (±5)
    B_LOWER=$(align_tick $((CURRENT_TICK - 5)) $TICK_SPACING)
    B_UPPER=$(align_tick $((CURRENT_TICK + 5)) $TICK_SPACING)
    log_step "USER_B 窄区间: [$B_LOWER, $B_UPPER] (在 A 内部)"
    B_TOKEN_ID=$(mint_position "$B_LOWER" "$B_UPPER" 50000000 50000000000000000000 "$USER_B_PK")
    if [[ "$B_TOKEN_ID" == "0" || -z "$B_TOKEN_ID" ]]; then
        log_fail "USER_B 添加窄区间失败"; log_summary; exit 1
    fi
    log_pass "USER_B 窄区间 tokenId=$B_TOKEN_ID"

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
RESIDUAL_BPS=$(echo "$SNAP_RESP" | jq -r '.stats.poolResidualBps // "N/A"')
CONSERVATION=$(echo "$SNAP_RESP" | jq -r '.stats.conservationOk // "N/A"')
log_step "snapshotId: $SID, residualBps: $RESIDUAL_BPS, conservationOk: $CONSERVATION"

A_HOLDING=$(get_allocation_holding "$SID" "$USER_A_ADDR")
A_CHAIN_BAL=$(chain_balance "$TOKEN1" "$USER_A_ADDR")
A_DIFF=$(python3 -c "print(int('$A_HOLDING') - int('$A_CHAIN_BAL'))")
log_step "USER_A: holding=$A_HOLDING, balanceOf=$A_CHAIN_BAL, 穿透量=$A_DIFF"

B_HOLDING=$(get_allocation_holding "$SID" "$USER_B_ADDR")
B_CHAIN_BAL=$(chain_balance "$TOKEN1" "$USER_B_ADDR")
B_DIFF=$(python3 -c "print(int('$B_HOLDING') - int('$B_CHAIN_BAL'))")
log_step "USER_B: holding=$B_HOLDING, balanceOf=$B_CHAIN_BAL, 穿透量=$B_DIFF"

A_GT=$(python3 -c "print('yes' if int('$A_DIFF') > 0 else 'no')")
[[ "$A_GT" == "yes" ]] && log_pass "USER_A 穿透量 > 0 ($A_DIFF)" || log_fail "USER_A 穿透量 <= 0"

B_GT=$(python3 -c "print('yes' if int('$B_DIFF') > 0 else 'no')")
[[ "$B_GT" == "yes" ]] && log_pass "USER_B 穿透量 > 0 ($B_DIFF)" || log_fail "USER_B 穿透量 <= 0"

POOL_MSTOCK=$(chain_balance "$TOKEN1" "$POOL")
log_step "池子 mStock 总余额: $POOL_MSTOCK"

SUM_CHECK=$(python3 -c "
a = int('$A_DIFF')
b = int('$B_DIFF')
pool = int('$POOL_MSTOCK')
total = a + b
print(f'穿透量之和: {total}')
print(f'池子余额:   {pool}')
if pool > 0:
    ratio = abs(total - pool) / pool
    print(f'偏差比: {ratio:.6f}')
    print('PASS' if ratio < 0.5 else 'FAIL')
else:
    print('FAIL')
")
echo "$SUM_CHECK"

[[ "$(echo "$SUM_CHECK" | tail -1)" == "PASS" ]] && log_pass "穿透量之和与池子余额偏差在合理范围" || log_fail "穿透量之和与池子余额偏差过大"

log_summary
