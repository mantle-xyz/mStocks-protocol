#!/usr/bin/env bash
# MS-LP-09: 大量 LP (50+ positions)
#
# 用法:
#   bash MS-LP-09_bulk_positions.sh              # 完整: 批量 mint 55 个 position + 快照
#   bash MS-LP-09_bulk_positions.sh --skip-mint   # 跳过 mint，用已有仓位出快照
#
# 期望: positionCount >= 50, conservation_ok == true

cd "$(dirname "$0")/../../.." || exit 1
source .env
source script/qa/merkle/common.sh
source script/qa/merkle/lp-common.sh

SKIP_MINT=false
[[ "${1:-}" == "--skip-mint" ]] && SKIP_MINT=true

LOGFILE="$LOGDIR/MS-LP-09.log"
exec > >(tee "$LOGFILE") 2>&1

log_case "MS-LP-09: 大量 LP (50+ positions)"

CURRENT_TICK=$(get_current_tick)
log_step "当前 tick = $CURRENT_TICK"

if [[ "$SKIP_MINT" == "false" ]]; then
    # 确保余额够批量 mint
    USER_A_MUSD=$(chain_balance "$TOKEN0" "$USER_A_ADDR")
    USER_A_QATST=$(chain_balance "$TOKEN1" "$USER_A_ADDR")
    log_step "USER_A mUSD=$USER_A_MUSD, QATST=$USER_A_QATST"

    NEED_MUSD=$(python3 -c "print('yes' if int('$USER_A_MUSD') < 500000000 else 'no')")
    if [[ "$NEED_MUSD" == "yes" ]]; then
        log_step "mint 1000 mUSD for USER_A"
        cast send "$TOKEN0" "mint(address,uint256)" "$USER_A_ADDR" 1000000000 \
            --rpc-url "$RPC" --private-key "$ADMIN_PK" > /dev/null 2>&1 || true
    fi
    NEED_QATST=$(python3 -c "print('yes' if int('$USER_A_QATST') < 500000000000000000000 else 'no')")
    if [[ "$NEED_QATST" == "yes" ]]; then
        log_step "mint 1000 QATST for USER_A"
        cast send "$TOKEN1" "mint(address,uint256)" "$USER_A_ADDR" "1000000000000000000000" \
            --rpc-url "$RPC" --private-key "$ADMIN_PK" > /dev/null 2>&1 || true
    fi

    # 一次性大额 approve
    log_step "批量 approve NPM"
    cast send "$TOKEN0" "approve(address,uint256)" "$NPM" "2000000000" \
        --rpc-url "$RPC" --private-key "$USER_A_PK" > /dev/null 2>&1 || true
    cast send "$TOKEN1" "approve(address,uint256)" "$NPM" "2000000000000000000000" \
        --rpc-url "$RPC" --private-key "$USER_A_PK" > /dev/null 2>&1 || true

    # 批量 mint 55 个 position
    TARGET=55
    SUCCESS=0
    FAIL_MINT=0
    RECIPIENT=$(cast wallet address --private-key "$USER_A_PK")

    log_step "开始批量 mint $TARGET 个 position..."

    for i in $(seq 0 $((TARGET - 1))); do
        OFFSET=$(( (i * 4) - 110 ))
        TL=$(align_tick $((CURRENT_TICK + OFFSET)) $TICK_SPACING)
        TU=$(align_tick $((CURRENT_TICK + OFFSET + 4)) $TICK_SPACING)

        if [[ $TU -le $CURRENT_TICK ]]; then
            AMT0=2000000; AMT1=0
        elif [[ $TL -ge $CURRENT_TICK ]]; then
            AMT0=0; AMT1=2000000000000000000
        else
            AMT0=2000000; AMT1=2000000000000000000
        fi

        DEADLINE=$(($(date +%s) + 600))
        RESULT=$(cast send "$NPM" \
            "mint((address,address,int24,int24,int24,uint256,uint256,uint256,uint256,address,uint256,uint256))" \
            "($TOKEN0,$TOKEN1,$TICK_SPACING,$TL,$TU,$AMT0,$AMT1,0,0,$RECIPIENT,$DEADLINE,0)" \
            --rpc-url "$RPC" --private-key "$USER_A_PK" --gas-limit 800000 --json 2>&1) || true

        STATUS=$(echo "$RESULT" | jq -r '.status // empty' 2>/dev/null)
        if [[ "$STATUS" == "0x1" ]]; then
            ((SUCCESS++)) || true
            (( SUCCESS % 10 == 0 )) && log_step "  已成功 $SUCCESS / $TARGET"
        else
            ((FAIL_MINT++)) || true
            log_step "  #$i 失败: [$TL, $TU]"
        fi
    done

    log_step "批量 mint 完成: 成功=$SUCCESS, 失败=$FAIL_MINT"
    if [[ $SUCCESS -lt 50 ]]; then
        log_fail "成功数 < 50 ($SUCCESS)"; log_summary; exit 1
    fi
    log_pass "成功 mint $SUCCESS 个 position"

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
POSITION_COUNT=$(echo "$SNAP_RESP" | jq -r '.stats.positionCount // "0"')
RESIDUAL_BPS=$(echo "$SNAP_RESP" | jq -r '.stats.poolResidualBps // "N/A"')
CONSERVATION=$(echo "$SNAP_RESP" | jq -r '.stats.conservationOk // "N/A"')

log_step "snapshotId: $SID"
log_step "positionCount: $POSITION_COUNT"
log_step "poolResidualBps: $RESIDUAL_BPS"
log_step "conservationOk: $CONSERVATION"

if [[ "$POSITION_COUNT" -ge 50 ]] 2>/dev/null; then
    log_pass "positionCount >= 50 ($POSITION_COUNT)"
else
    log_fail "positionCount < 50 ($POSITION_COUNT)"
fi

if [[ "$RESIDUAL_BPS" != "N/A" ]]; then
    BPS_OK=$(python3 -c "print('yes' if float('$RESIDUAL_BPS') < 100 else 'no')" 2>/dev/null || echo "no")
    [[ "$BPS_OK" == "yes" ]] && log_pass "poolResidualBps < 100 ($RESIDUAL_BPS)" || log_fail "poolResidualBps >= 100 ($RESIDUAL_BPS)"
else
    log_step "poolResidualBps 不可用，跳过"
fi

if [[ "$CONSERVATION" == "true" ]]; then
    log_pass "conservationOk == true"
elif [[ "$CONSERVATION" == "false" ]]; then
    log_fail "conservationOk == false"
else
    log_step "conservationOk 不可用 ($CONSERVATION)，跳过"
fi

log_summary
