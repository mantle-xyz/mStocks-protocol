#!/usr/bin/env bash
# MS-LP-04: 窄区间 vs 宽区间
#
# 用法:
#   bash MS-LP-04_narrow_vs_wide.sh              # 完整: mint + 等确认 + 快照
#   bash MS-LP-04_narrow_vs_wide.sh --skip-mint   # 跳过 mint，用已有仓位
#
# USER_A 窄区间 (±2), USER_B 宽区间 (±50)
# 期望: 两者穿透量不同 (窄区间集中度更高)

cd "$(dirname "$0")/../../.." || exit 1
source .env
source script/qa/merkle/common.sh
source script/qa/merkle/lp-common.sh

SKIP_MINT=false
[[ "${1:-}" == "--skip-mint" ]] && SKIP_MINT=true

LOGFILE="$LOGDIR/MS-LP-04.log"
exec > >(tee "$LOGFILE") 2>&1

log_case "MS-LP-04: 窄区间 vs 宽区间"

CURRENT_TICK=$(get_current_tick)
log_step "当前 tick = $CURRENT_TICK"

if [[ "$SKIP_MINT" == "false" ]]; then
    # 前置: USER_B 需要余额
    USER_B_MUSD=$(chain_balance "$TOKEN0" "$USER_B_ADDR")
    NEED_MUSD=$(python3 -c "print('yes' if int('$USER_B_MUSD') < 100000000 else 'no')")
    if [[ "$NEED_MUSD" == "yes" ]]; then
        log_step "USER_B mUSD 不足，mint 200 mUSD"
        cast send "$TOKEN0" "mint(address,uint256)" "$USER_B_ADDR" 200000000 \
            --rpc-url "$RPC" --private-key "$ADMIN_PK" > /dev/null 2>&1 || true
    fi

    # USER_A 窄区间
    log_step "USER_A: 窄区间 (±2 tickSpacing)"
    NARROW_LOWER=$(align_tick $((CURRENT_TICK - 2)) $TICK_SPACING)
    NARROW_UPPER=$(align_tick $((CURRENT_TICK + 2)) $TICK_SPACING)
    log_step "窄区间: [$NARROW_LOWER, $NARROW_UPPER]"

    A_TOKEN_ID=$(mint_position "$NARROW_LOWER" "$NARROW_UPPER" 50000000 50000000000000000000 "$USER_A_PK")
    if [[ "$A_TOKEN_ID" == "0" || -z "$A_TOKEN_ID" ]]; then
        log_fail "USER_A 添加窄区间失败"
        log_summary
        exit 1
    fi
    log_pass "USER_A 窄区间 tokenId=$A_TOKEN_ID"

    # USER_B 宽区间
    log_step "USER_B: 宽区间 (±50 tickSpacing)"
    WIDE_LOWER=$(align_tick $((CURRENT_TICK - 50)) $TICK_SPACING)
    WIDE_UPPER=$(align_tick $((CURRENT_TICK + 50)) $TICK_SPACING)
    log_step "宽区间: [$WIDE_LOWER, $WIDE_UPPER]"

    B_TOKEN_ID=$(mint_position "$WIDE_LOWER" "$WIDE_UPPER" 50000000 50000000000000000000 "$USER_B_PK")
    if [[ "$B_TOKEN_ID" == "0" || -z "$B_TOKEN_ID" ]]; then
        log_fail "USER_B 添加宽区间失败"
        log_summary
        exit 1
    fi
    log_pass "USER_B 宽区间 tokenId=$B_TOKEN_ID"

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

A_HOLDING=$(get_allocation_holding "$SID" "$USER_A_ADDR")
A_CHAIN_BAL=$(chain_balance "$TOKEN1" "$USER_A_ADDR")
A_DIFF=$(python3 -c "print(int('$A_HOLDING') - int('$A_CHAIN_BAL'))")
log_step "USER_A (窄): holding=$A_HOLDING, balanceOf=$A_CHAIN_BAL, 穿透量=$A_DIFF"

B_HOLDING=$(get_allocation_holding "$SID" "$USER_B_ADDR")
B_CHAIN_BAL=$(chain_balance "$TOKEN1" "$USER_B_ADDR")
B_DIFF=$(python3 -c "print(int('$B_HOLDING') - int('$B_CHAIN_BAL'))")
log_step "USER_B (宽): holding=$B_HOLDING, balanceOf=$B_CHAIN_BAL, 穿透量=$B_DIFF"

IS_DIFF=$(python3 -c "print('yes' if int('$A_DIFF') != int('$B_DIFF') else 'no')")
if [[ "$IS_DIFF" == "yes" ]]; then
    log_pass "窄区间与宽区间穿透量不同 (A=$A_DIFF, B=$B_DIFF)"
else
    log_fail "窄区间与宽区间穿透量相同，期望不同"
fi

log_summary
