#!/usr/bin/env bash
# MS-03: 禁用池子
# 前提: MS-01 已注册
# 步骤: POST /v1/pools/{address}/disable → GET 确认
# 期望: enabled=false，不带 include_disabled 时列表不可见

cd "$(dirname "$0")/../../.." || exit 1
source .env
source script/qa/merkle/common.sh

LOGFILE="$LOGDIR/MS-03.log"
exec > >(tee "$LOGFILE") 2>&1

log_case "MS-03: 禁用池子"

# ── Step 1: POST disable ──
log_step "POST /v1/pools/$POOL/disable"

REQ_BODY='{"chain_id":"5000"}'
log_request "POST $H/v1/pools/$POOL/disable"
echo "  Body: $REQ_BODY"

HTTP_CODE=$(curl -s -o /tmp/ms03_disable.json -w "%{http_code}" \
    -X POST "$H/v1/pools/$POOL/disable" \
    -H "Content-Type: application/json" -H "X-API-Key: $K" \
    -d "$REQ_BODY")

RESP=$(cat /tmp/ms03_disable.json)
log_response "$RESP"

assert_http_ok "$HTTP_CODE" "禁用 HTTP 状态"

# ── Step 2: GET with include_disabled=true 确认 enabled=false ──
log_step "GET /v1/pools?chain_id=5000&token=$TOKEN&include_disabled=true"

QUERY_URL="$H/v1/pools?chain_id=5000&token=$TOKEN&include_disabled=true"
log_request "GET $QUERY_URL"

LIST_CODE=$(curl -s -o /tmp/ms03_list_all.json -w "%{http_code}" \
    "$QUERY_URL" -H "X-API-Key: $K")

LIST_RESP=$(cat /tmp/ms03_list_all.json)
log_response "$LIST_RESP"

POOL_LOWER=$(echo "$POOL" | tr '[:upper:]' '[:lower:]')
ENABLED=$(echo "$LIST_RESP" | jq -r ".pools[]? | select(.address == \"$POOL_LOWER\") | .enabled")
assert_eq "$ENABLED" "false" "enabled (include_disabled=true)"

# ── Step 3: GET without include_disabled 确认不可见 ──
log_step "GET /v1/pools?chain_id=5000&token=$TOKEN (不带 include_disabled)"

QUERY_URL2="$H/v1/pools?chain_id=5000&token=$TOKEN"
log_request "GET $QUERY_URL2"

LIST_CODE2=$(curl -s -o /tmp/ms03_list_default.json -w "%{http_code}" \
    "$QUERY_URL2" -H "X-API-Key: $K")

LIST_RESP2=$(cat /tmp/ms03_list_default.json)
log_response "$LIST_RESP2"

POOL_VISIBLE=$(echo "$LIST_RESP2" | jq -r ".pools[]? | select(.address == \"$POOL_LOWER\") | .address")
if [[ -z "$POOL_VISIBLE" ]]; then
    log_pass "禁用后默认列表中不可见"
else
    log_fail "禁用后默认列表中仍可见: $POOL_VISIBLE"
fi

log_summary
