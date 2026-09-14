#!/usr/bin/env bash
# MS-05: 重新启用池子
# 前提: MS-03 已禁用
# 步骤: POST /v1/pools/{address}/enable → GET 确认
# 期望: enabled=true，列表中可见

cd "$(dirname "$0")/../../.." || exit 1
source .env
source script/qa/merkle/common.sh

LOGFILE="$LOGDIR/MS-05.log"
exec > >(tee "$LOGFILE") 2>&1

log_case "MS-05: 重新启用池子"

# ── Step 1: POST enable ──
log_step "POST /v1/pools/$POOL/enable"

REQ_BODY='{"chain_id":"5000"}'
log_request "POST $H/v1/pools/$POOL/enable"
echo "  Body: $REQ_BODY"

HTTP_CODE=$(curl -s -o /tmp/ms05_enable.json -w "%{http_code}" \
    -X POST "$H/v1/pools/$POOL/enable" \
    -H "Content-Type: application/json" -H "X-API-Key: $K" \
    -d "$REQ_BODY")

RESP=$(cat /tmp/ms05_enable.json)
log_response "$RESP"

assert_http_ok "$HTTP_CODE" "启用 HTTP 状态"

# ── Step 2: GET 确认 enabled=true ──
log_step "GET /v1/pools?chain_id=5000&token=$TOKEN — 确认 enabled=true"

QUERY_URL="$H/v1/pools?chain_id=5000&token=$TOKEN"
log_request "GET $QUERY_URL"

LIST_CODE=$(curl -s -o /tmp/ms05_list.json -w "%{http_code}" \
    "$QUERY_URL" -H "X-API-Key: $K")

LIST_RESP=$(cat /tmp/ms05_list.json)
log_response "$LIST_RESP"

assert_http_ok "$LIST_CODE" "列表查询 HTTP 状态"

POOL_LOWER=$(echo "$POOL" | tr '[:upper:]' '[:lower:]')
ENABLED=$(echo "$LIST_RESP" | jq -r ".pools[]? | select(.address == \"$POOL_LOWER\") | .enabled")
assert_eq "$ENABLED" "true" "启用后 enabled=true"

# ── Step 3: 确认默认列表可见 ──
log_step "确认默认列表（不带 include_disabled）可见"

POOL_VISIBLE=$(echo "$LIST_RESP" | jq -r ".pools[]? | select(.address == \"$POOL_LOWER\") | .address")
if [[ -n "$POOL_VISIBLE" ]]; then
    log_pass "池子在默认列表中可见"
else
    log_fail "池子在默认列表中不可见"
fi

log_summary
