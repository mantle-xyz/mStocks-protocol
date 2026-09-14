#!/usr/bin/env bash
# MS-01: 注册池子
# 前提: 池子已部署，知道 created_block
# 步骤: POST /v1/pools → GET /v1/pools 确认
# 期望: 200 成功，响应含 token0/token1/fee/tickSpacing，enabled=true，列表可见

cd "$(dirname "$0")/../../.." || exit 1
source .env
source script/qa/merkle/common.sh

LOGFILE="$LOGDIR/MS-01.log"
exec > >(tee "$LOGFILE") 2>&1

log_case "MS-01: 注册池子"

# ── Step 1: POST /v1/pools ──
log_step "POST /v1/pools — 注册池子"

REQ_BODY='{
  "address": "'$POOL'",
  "chain_id": "5000",
  "kind": "slipstream",
  "created_block": "'$POOL_CREATED_BLOCK'"
}'
log_request "POST $H/v1/pools"
echo "  Body: $REQ_BODY"

HTTP_CODE=$(curl -s -o /tmp/ms01_register.json -w "%{http_code}" \
    -X POST "$H/v1/pools" \
    -H "Content-Type: application/json" -H "X-API-Key: $K" \
    -d "$REQ_BODY")

RESP=$(cat /tmp/ms01_register.json)
log_response "$RESP"

assert_http_ok "$HTTP_CODE" "注册 HTTP 状态"

TOKEN0=$(echo "$RESP" | jq -r '.token0')
TOKEN1=$(echo "$RESP" | jq -r '.token1')
TICK_SPACING=$(echo "$RESP" | jq -r '.tickSpacing')
KIND=$(echo "$RESP" | jq -r '.kind')
ENABLED=$(echo "$RESP" | jq -r '.enabled')

assert_not_empty "$TOKEN0" "token0"
assert_not_empty "$TOKEN1" "token1"
assert_not_empty "$TICK_SPACING" "tickSpacing"
assert_eq "$KIND" "slipstream" "kind"
assert_eq "$ENABLED" "true" "enabled"

# ── Step 2: GET /v1/pools 确认列表可见 ──
log_step "GET /v1/pools?chain_id=5000&token=$TOKEN — 查询确认"

QUERY_URL="$H/v1/pools?chain_id=5000&token=$TOKEN"
log_request "GET $QUERY_URL"

LIST_CODE=$(curl -s -o /tmp/ms01_list.json -w "%{http_code}" \
    "$QUERY_URL" -H "X-API-Key: $K")

LIST_RESP=$(cat /tmp/ms01_list.json)
log_response "$LIST_RESP"

assert_http_ok "$LIST_CODE" "列表查询 HTTP 状态"

POOL_IN_LIST=$(echo "$LIST_RESP" | jq -r ".pools[]? | select(.address == \"$(echo $POOL | tr '[:upper:]' '[:lower:]')\") | .address")
if [[ -n "$POOL_IN_LIST" ]]; then
    log_pass "池子在列表中可见: $POOL_IN_LIST"
else
    log_fail "池子不在列表中"
fi

log_summary
