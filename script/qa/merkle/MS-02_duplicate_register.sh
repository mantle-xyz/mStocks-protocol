#!/usr/bin/env bash
# MS-02: 重复注册（幂等）
# 前提: MS-01 已注册 + MS-03 已禁用
# 步骤: 用 MS-01 相同参数再 POST /v1/pools → GET 查 enabled
# 期望: 200 成功（不报错），enabled 保持 false（不被重置为 true）

cd "$(dirname "$0")/../../.." || exit 1
source .env
source script/qa/merkle/common.sh

LOGFILE="$LOGDIR/MS-02.log"
exec > >(tee "$LOGFILE") 2>&1

log_case "MS-02: 重复注册（幂等）"

# ── Step 0: 确认当前为 disabled 状态 ──
log_step "前置检查: 确认池子当前 enabled=false"

POOL_LOWER=$(echo "$POOL" | tr '[:upper:]' '[:lower:]')
PRE_CHECK=$(curl -sf "$H/v1/pools?chain_id=5000&token=$TOKEN&include_disabled=true" -H "X-API-Key: $K")
PRE_ENABLED=$(echo "$PRE_CHECK" | jq -r ".pools[]? | select(.address == \"$POOL_LOWER\") | .enabled")

if [[ "$PRE_ENABLED" != "false" ]]; then
    log_fail "前置条件不满足: 池子 enabled=$PRE_ENABLED，需要先运行 MS-03 禁用"
    log_summary
    exit 1
fi
log_pass "前置条件: enabled=false"

# ── Step 1: POST /v1/pools 重复注册 ──
log_step "POST /v1/pools — 重复注册（与 MS-01 相同参数）"

REQ_BODY='{
  "address": "'$POOL'",
  "chain_id": "5000",
  "kind": "slipstream",
  "created_block": "'$POOL_CREATED_BLOCK'"
}'
log_request "POST $H/v1/pools"
echo "  Body: $REQ_BODY"

HTTP_CODE=$(curl -s -o /tmp/ms02_register.json -w "%{http_code}" \
    -X POST "$H/v1/pools" \
    -H "Content-Type: application/json" -H "X-API-Key: $K" \
    -d "$REQ_BODY")

RESP=$(cat /tmp/ms02_register.json)
log_response "$RESP"

assert_http_ok "$HTTP_CODE" "重复注册 HTTP 状态"

# ── Step 2: GET 确认 enabled 仍为 false ──
log_step "GET /v1/pools?include_disabled=true — 确认 enabled 未被重置"

QUERY_URL="$H/v1/pools?chain_id=5000&token=$TOKEN&include_disabled=true"
log_request "GET $QUERY_URL"

LIST_CODE=$(curl -s -o /tmp/ms02_list.json -w "%{http_code}" \
    "$QUERY_URL" -H "X-API-Key: $K")

LIST_RESP=$(cat /tmp/ms02_list.json)
log_response "$LIST_RESP"

ENABLED=$(echo "$LIST_RESP" | jq -r ".pools[]? | select(.address == \"$POOL_LOWER\") | .enabled")
assert_eq "$ENABLED" "false" "重复注册后 enabled 保持 false"

log_summary
