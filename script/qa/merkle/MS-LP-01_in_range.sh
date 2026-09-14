#!/usr/bin/env bash
# MS-LP-01: 区间内做市 — 穿透有值
#
# 用法:
#   bash MS-LP-01_in_range.sh           # 完整流程: mint + swap + 等确认 + 快照
#   bash MS-LP-01_in_range.sh --skip-mint  # 跳过 mint，直接用已有仓位出快照验证
#
# 期望: holding > balanceOf，差额 = LP 穿透量

cd "$(dirname "$0")/../../.." || exit 1
source .env
source script/qa/merkle/common.sh
source script/qa/merkle/lp-common.sh

SKIP_MINT=false
[[ "${1:-}" == "--skip-mint" ]] && SKIP_MINT=true

LOGFILE="$LOGDIR/MS-LP-01.log"
exec > >(tee "$LOGFILE") 2>&1

log_case "MS-LP-01: 区间内做市 — 穿透有值"

CURRENT_TICK=$(get_current_tick)
log_step "当前 tick = $CURRENT_TICK"

if [[ "$SKIP_MINT" == "false" ]]; then
    # ── mint 阶段 ──
    TICK_LOWER=$(align_tick $((CURRENT_TICK - 10)) $TICK_SPACING)
    TICK_UPPER=$(align_tick $((CURRENT_TICK + 10)) $TICK_SPACING)
    log_step "区间: [$TICK_LOWER, $TICK_UPPER] (包含当前 tick)"

    QATST_BEFORE=$(chain_balance "$TOKEN1" "$USER_A_ADDR")
    TOKEN_ID=$(mint_position "$TICK_LOWER" "$TICK_UPPER" 100000000 100000000000000000000 "$USER_A_PK")

    if [[ "$TOKEN_ID" == "0" || -z "$TOKEN_ID" ]]; then
        log_fail "添加流动性失败"
        log_summary
        exit 1
    fi
    log_pass "添加流动性成功, tokenId=$TOKEN_ID"

    QATST_AFTER=$(chain_balance "$TOKEN1" "$USER_A_ADDR")
    log_step "QATST 锁入: $(python3 -c "print(int('$QATST_BEFORE') - int('$QATST_AFTER'))")"

    # swap 制造手续费
    log_step "执行 swap 制造手续费"
    do_swap "true" 10000000 "$USER_A_PK"
    do_swap "false" 10000000000000000000 "$USER_A_PK"

    # 等确认
    mark_block
    RB=$(wait_and_get_record_block 150)
else
    log_step "跳过 mint，使用已有仓位"
    RB=$(safe_record_block)
    log_step "使用 recordBlock=$RB"
fi

# ── 快照验证阶段 ──
SNAP_RESP=$(snapshot_with_lp "$RB")

SNAP_STATUS=$(echo "$SNAP_RESP" | jq -r '.status')
if [[ "$SNAP_STATUS" != "SNAPSHOT_STATUS_READY" ]]; then
    log_fail "快照失败: $SNAP_STATUS"
    echo "$SNAP_RESP" | jq '.failureReason'
    log_summary
    exit 1
fi

SID=$(echo "$SNAP_RESP" | jq -r '.snapshotId')
POOL_COUNT=$(echo "$SNAP_RESP" | jq -r '.stats.poolCount')
POSITION_COUNT=$(echo "$SNAP_RESP" | jq -r '.stats.positionCount')
log_step "snapshotId: $SID, poolCount: $POOL_COUNT, positionCount: $POSITION_COUNT"
assert_eq "$POOL_COUNT" "1" "poolCount"

HOLDING=$(get_allocation_holding "$SID" "$USER_A_ADDR")
CHAIN_BAL=$(chain_balance "$TOKEN1" "$USER_A_ADDR")
log_step "快照 holding: $HOLDING"
log_step "链上 balanceOf: $CHAIN_BAL"

if [[ -n "$HOLDING" && "$HOLDING" != "0" && -n "$CHAIN_BAL" ]]; then
    DIFF=$(python3 -c "print(int('$HOLDING') - int('$CHAIN_BAL'))")
    log_step "穿透量 (holding - balanceOf): $DIFF"

    IS_GREATER=$(python3 -c "print('yes' if int('$HOLDING') > int('$CHAIN_BAL') else 'no')")
    if [[ "$IS_GREATER" == "yes" ]]; then
        log_pass "holding > balanceOf，穿透量 = $DIFF"
    else
        log_fail "holding <= balanceOf，期望 holding > balanceOf"
    fi
else
    log_fail "无法获取 holding 或 balanceOf"
fi

CONSERVATION=$(echo "$SNAP_RESP" | jq -r '.stats.conservationOk')
RESIDUAL_BPS=$(echo "$SNAP_RESP" | jq -r '.stats.poolResidualBps')
log_step "conservationOk: $CONSERVATION, poolResidualBps: $RESIDUAL_BPS"

log_summary
