#!/usr/bin/env bash
# Merkle 服务测试 — 公共函数
# source 此文件前需先 source .env

set -euo pipefail

: "${MERKLE_HOST:?MERKLE_HOST not set}"
: "${API_KEY:?API_KEY not set}"
: "${TOKEN_ADDR:?TOKEN_ADDR not set}"
: "${RPC_URL:?RPC_URL not set}"

export H="$MERKLE_HOST"
export K="$API_KEY"
export TOKEN="$TOKEN_ADDR"
export RPC="$RPC_URL"
export POOL="0xd70eE5f83288ADF183E06fa04dAbC859ba8aCFBD"
export POOL_CREATED_BLOCK="100315751"

LOGDIR="logs/merkle"
mkdir -p "$LOGDIR"

# ── 颜色 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

log_case() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}========================================${NC}"
}

log_step() {
    echo -e "${YELLOW}  [Step] $1${NC}"
}

log_request() {
    echo -e "  ${CYAN}>>> REQUEST:${NC} $1"
}

log_response() {
    echo -e "  ${CYAN}<<< RESPONSE:${NC}"
    echo "$1" | jq . 2>/dev/null || echo "$1"
}

log_pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    ((PASS_COUNT++)) || true
}

log_fail() {
    echo -e "  ${RED}[FAIL]${NC} $1"
    ((FAIL_COUNT++)) || true
}

log_summary() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "  PASS: ${GREEN}${PASS_COUNT}${NC}  FAIL: ${RED}${FAIL_COUNT}${NC}"
    echo -e "${CYAN}========================================${NC}"
    if [[ $FAIL_COUNT -gt 0 ]]; then
        return 1
    fi
}

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [[ "$actual" == "$expected" ]]; then
        log_pass "$label: $actual == $expected"
    else
        log_fail "$label: expected '$expected', got '$actual'"
    fi
}

assert_not_empty() {
    local actual="$1" label="$2"
    if [[ -n "$actual" && "$actual" != "null" ]]; then
        log_pass "$label: '$actual' (not empty)"
    else
        log_fail "$label: empty or null"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    if echo "$haystack" | grep -qi "$needle"; then
        log_pass "$label: contains '$needle'"
    else
        log_fail "$label: '$needle' not found"
    fi
}

assert_http_ok() {
    local code="$1" label="$2"
    if [[ "$code" == "200" || "$code" == "201" ]]; then
        log_pass "$label: HTTP $code"
    else
        log_fail "$label: expected 200/201, got HTTP $code"
    fi
}

# 安全 recordBlock（当前块 - 200）
safe_record_block() {
    echo $(( $(cast block-number --rpc-url "$RPC") - 200 ))
}

# 出快照并等待完成，返回完整响应 JSON
snapshot_and_wait() {
    local body="$1"
    local sid
    sid=$(curl -sf -X POST "$H/v1/programs/snapshot" \
        -H "Content-Type: application/json" -H "X-API-Key: $K" \
        -d "$body" | jq -r '.snapshotId')

    if [[ -z "$sid" || "$sid" == "null" ]]; then
        echo '{"error":"failed to create snapshot"}'
        return 1
    fi

    for i in $(seq 1 60); do
        local res
        res=$(curl -sf "$H/v1/snapshots/$sid" -H "X-API-Key: $K")
        local status
        status=$(echo "$res" | jq -r '.status')
        if [[ "$status" == "SNAPSHOT_STATUS_READY" || "$status" == "SNAPSHOT_STATUS_FAILED" ]]; then
            echo "$res"
            return 0
        fi
        sleep 3
    done
    echo '{"error":"snapshot timeout"}'
    return 1
}
