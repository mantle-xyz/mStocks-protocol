#!/usr/bin/env bash
# LP 穿透测试 — 公共函数
# source 此文件前需先 source .env 和 source common.sh

: "${SETTLE_TOKEN_ADDR:?SETTLE_TOKEN_ADDR not set}"
: "${USER_A_PK:?USER_A_PK not set}"

export NPM="0xB65EDa352dF237089Cfc9647A8Ed7C159Cc8fE1E"
export SWAP_ROUTER="0x5de38072ff78Fd4E6B3c937b5859B911B3758dbc"
export POOL="0xd70eE5f83288ADF183E06fa04dAbC859ba8aCFBD"
export TICK_SPACING=1

export USER_A_ADDR=$(cast wallet address --private-key "$USER_A_PK")
export USER_B_ADDR=$(cast wallet address --private-key "$USER_B_PK")

# token0 = mUSD, token1 = QATST (mStock)
export TOKEN0="$SETTLE_TOKEN_ADDR"
export TOKEN1="$TOKEN_ADDR"

# 查当前 tick
get_current_tick() {
    local slot0
    slot0=$(cast call "$POOL" "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)" --rpc-url "$RPC")
    echo "$slot0" | sed -n '2p' | sed 's/\[.*//;s/ //g'
}

# 对齐到 tickSpacing 的倍数（向下取整）
align_tick() {
    local tick=$1
    local ts=${2:-$TICK_SPACING}
    if (( tick >= 0 )); then
        echo $(( (tick / ts) * ts ))
    else
        echo $(( ((tick - ts + 1) / ts) * ts ))
    fi
}

# approve token 给 NPM（如果 allowance 不够）
ensure_approve() {
    local token_addr=$1
    local spender=$2
    local amount=$3
    local pk=$4
    local owner
    owner=$(cast wallet address --private-key "$pk")

    local allowance
    allowance=$(cast call "$token_addr" "allowance(address,address)(uint256)" "$owner" "$spender" --rpc-url "$RPC" | sed 's/\[.*//;s/ //g')

    local need_approve
    need_approve=$(python3 -c "print('yes' if int('$allowance') < int('$amount') else 'no')" 2>/dev/null || echo "yes")
    if [[ "$need_approve" == "yes" ]]; then
        log_step "approve $token_addr -> $spender" >&2
        cast send "$token_addr" "approve(address,uint256)" "$spender" "2000000000000000000000" \
            --rpc-url "$RPC" --private-key "$pk" > /dev/null 2>&1 || true
    fi
}

# 添加流动性 (mint position)
# 参数: tickLower tickUpper amount0Desired amount1Desired pk
# 返回: tokenId (stdout)
mint_position() {
    local tick_lower=$1
    local tick_upper=$2
    local amount0=$3   # mUSD (token0)
    local amount1=$4   # QATST (token1)
    local pk=$5
    local recipient
    recipient=$(cast wallet address --private-key "$pk")
    local deadline=$(($(date +%s) + 600))

    ensure_approve "$TOKEN0" "$NPM" "$amount0" "$pk"
    ensure_approve "$TOKEN1" "$NPM" "$amount1" "$pk"

    log_step "mint position: tickLower=$tick_lower tickUpper=$tick_upper amount0=$amount0 amount1=$amount1" >&2

    local result
    result=$(cast send "$NPM" \
        "mint((address,address,int24,int24,int24,uint256,uint256,uint256,uint256,address,uint256,uint256))" \
        "($TOKEN0,$TOKEN1,$TICK_SPACING,$tick_lower,$tick_upper,$amount0,$amount1,0,0,$recipient,$deadline,0)" \
        --rpc-url "$RPC" --private-key "$pk" --gas-limit 800000 --json 2>&1) || true

    local send_status=$(echo "$result" | jq -r '.status // empty' 2>/dev/null)
    if [[ "$send_status" != "0x1" ]]; then
        log_fail "mint position failed: $result" >&2
        echo "0"
        return 1
    fi

    local tx_hash
    tx_hash=$(echo "$result" | jq -r '.transactionHash')
    local receipt
    receipt=$(cast receipt "$tx_hash" --rpc-url "$RPC" --json 2>/dev/null)

    local token_id
    token_id=$(echo "$receipt" | jq -r '.logs[] | select(.topics[0] == "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" and .address == "'$(echo $NPM | tr '[:upper:]' '[:lower:]')'") | .topics[3]' 2>/dev/null | head -1)

    if [[ -n "$token_id" && "$token_id" != "null" ]]; then
        token_id=$(( token_id ))
        log_step "minted tokenId: $token_id (tx: $tx_hash)" >&2
        echo "$token_id"
    else
        log_step "minted position (tx: $tx_hash), parsing tokenId from logs..." >&2
        token_id=$(echo "$receipt" | jq -r '.logs[0].topics[1] // "0"' 2>/dev/null)
        token_id=$(( token_id ))
        log_step "tokenId (fallback): $token_id" >&2
        echo "$token_id"
    fi
}

# 执行 swap 制造手续费
# 参数: zeroForOne amountIn pk
do_swap() {
    local zero_for_one=$1   # true = mUSD->QATST, false = QATST->mUSD
    local amount_in=$2
    local pk=$3

    local token_in token_out
    if [[ "$zero_for_one" == "true" ]]; then
        token_in="$TOKEN0"
        token_out="$TOKEN1"
    else
        token_in="$TOKEN1"
        token_out="$TOKEN0"
    fi

    ensure_approve "$token_in" "$SWAP_ROUTER" "$amount_in" "$pk"

    log_step "swap: ${zero_for_one} amountIn=$amount_in"

    local swap_result
    swap_result=$(cast send "$SWAP_ROUTER" \
        "exactInputSingle((address,address,int24,address,uint256,uint256,uint160,uint8))" \
        "($token_in,$token_out,$TICK_SPACING,$(cast wallet address --private-key $pk),$amount_in,0,0,0)" \
        --rpc-url "$RPC" --private-key "$pk" --gas-limit 500000 --json 2>&1) || true

    local swap_status=$(echo "$swap_result" | jq -r '.status // empty' 2>/dev/null)
    if [[ "$swap_status" == "0x1" ]]; then
        log_step "swap completed"
    else
        log_fail "swap failed: $swap_result"
    fi
}

# 出快照并返回指定地址的 holding
# 参数: record_block
# 输出: 完整快照 JSON 到 stdout
snapshot_with_lp() {
    local rb=$1
    local snap_body="{
        \"token\": \"$TOKEN\",
        \"record_block\": \"$rb\",
        \"kind\": \"PROGRAM_KIND_WARRANT\",
        \"total\": \"1000000000000000000\",
        \"chain_id\": \"5000\"
    }"

    log_step "出快照 (recordBlock=$rb)" >&2
    log_request "POST $H/v1/programs/snapshot" >&2
    echo "  Body: $snap_body" >&2

    local snap_resp
    snap_resp=$(snapshot_and_wait "$snap_body")
    log_response "$snap_resp" >&2

    local status
    status=$(echo "$snap_resp" | jq -r '.status')
    assert_eq "$status" "SNAPSHOT_STATUS_READY" "快照状态" >&2

    echo "$snap_resp"
}

# 查询指定地址的 allocation
# 参数: snapshot_id address
# 返回: holding 值
get_allocation_holding() {
    local sid=$1
    local address=$2

    local alloc_url="$H/v1/snapshots/$sid/allocation?account=$(echo $address | tr '[:upper:]' '[:lower:]')"
    log_request "GET $alloc_url" >&2

    local alloc_resp
    alloc_resp=$(curl -sf "$alloc_url" -H "X-API-Key: $K" 2>/dev/null || echo '{}')
    log_response "$alloc_resp" >&2

    local holding
    holding=$(echo "$alloc_resp" | jq -r '.holding // .amount // "0"')
    echo "$holding"
}

# 查链上 balanceOf
chain_balance() {
    local token=$1
    local address=$2
    cast call "$token" "balanceOf(address)(uint256)" "$address" --rpc-url "$RPC" | sed 's/\[.*//;s/ //g'
}

# 记录当前块高（在链上操作后调用）
mark_block() {
    MARKED_BLOCK=$(cast block-number --rpc-url "$RPC")
    log_step "标记当前块: $MARKED_BLOCK"
}

# 等待标记块有足够确认（默认 150 块），然后返回可用的 recordBlock
# Merkle 服务要求至少 120 个确认块
wait_and_get_record_block() {
    local min_confirms=${1:-150}
    local target=$((MARKED_BLOCK + min_confirms))
    log_step "等待块高到达 $target (标记块 $MARKED_BLOCK + $min_confirms 确认)..." >&2

    while true; do
        local current
        current=$(cast block-number --rpc-url "$RPC")
        local remaining=$((target - current))
        if [[ $remaining -le 0 ]]; then
            log_step "确认完成，当前块: $current" >&2
            break
        fi
        # Mantle 约 2s 一个块
        local wait_secs=$(( remaining * 2 + 5 ))
        if [[ $wait_secs -gt 120 ]]; then wait_secs=120; fi
        log_step "  还需 $remaining 块 (当前 $current)，等待 ${wait_secs}s..." >&2
        sleep "$wait_secs"
    done

    echo "$MARKED_BLOCK"
}
