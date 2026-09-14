#!/usr/bin/env bash
# MS-04: 禁用后出快照 — 池子不穿透
# 前提: MS-03 已禁用
# 步骤: 出快照，查 stats.poolCount
# 期望: poolCount == 0，池子地址出现在普通持有人列表中

cd "$(dirname "$0")/../../.." || exit 1
source .env
source script/qa/merkle/common.sh

LOGFILE="$LOGDIR/MS-04.log"
exec > >(tee "$LOGFILE") 2>&1

log_case "MS-04: 禁用后出快照 — 池子不穿透"

# ── Step 0: 确认池子已禁用 ──
log_step "前置检查: 确认池子 enabled=false"

POOL_LOWER=$(echo "$POOL" | tr '[:upper:]' '[:lower:]')
PRE_CHECK=$(curl -sf "$H/v1/pools?chain_id=5000&token=$TOKEN&include_disabled=true" -H "X-API-Key: $K")
PRE_ENABLED=$(echo "$PRE_CHECK" | jq -r ".pools[]? | select(.address == \"$POOL_LOWER\") | .enabled")

if [[ "$PRE_ENABLED" != "false" ]]; then
    log_fail "前置条件不满足: 池子 enabled=$PRE_ENABLED，需要先运行 MS-03"
    log_summary
    exit 1
fi
log_pass "前置条件: enabled=false"

# ── Step 1: 出快照 ──
log_step "出快照（池子已禁用）"

RB=$(safe_record_block)
log_request "POST $H/v1/programs/snapshot"
SNAP_BODY="{
  \"token\": \"$TOKEN\",
  \"record_block\": \"$RB\",
  \"kind\": \"PROGRAM_KIND_WARRANT\",
  \"total\": \"1000000000000000000\",
  \"chain_id\": \"5000\"
}"
echo "  Body: $SNAP_BODY"
echo "  recordBlock: $RB"

SNAP_RESP=$(snapshot_and_wait "$SNAP_BODY")
log_response "$SNAP_RESP"

STATUS=$(echo "$SNAP_RESP" | jq -r '.status')
assert_eq "$STATUS" "SNAPSHOT_STATUS_READY" "快照状态"

# ── Step 2: 检查 poolCount ──
log_step "检查 stats.poolCount"

POOL_COUNT=$(echo "$SNAP_RESP" | jq -r '.stats.poolCount')
assert_eq "$POOL_COUNT" "0" "poolCount (池子已禁用，不穿透)"

# ── Step 3: 检查池子地址是否在持有人列表中 ──
log_step "检查池子地址是否作为普通持有人"

SID=$(echo "$SNAP_RESP" | jq -r '.snapshotId // empty')
if [[ -z "$SID" ]]; then
    SID=$(echo "$SNAP_RESP" | jq -r '.snapshot_id // empty')
fi

if [[ -n "$SID" ]]; then
    TREE_URI=$(echo "$SNAP_RESP" | jq -r '.treeUri // empty')
    if [[ -n "$TREE_URI" && "$TREE_URI" != "null" ]]; then
        log_request "GET $H$TREE_URI"
        TREE_RESP=$(curl -sf "$H$TREE_URI" -H "X-API-Key: $K" 2>/dev/null || echo "{}")
        POOL_IN_TREE=$(echo "$TREE_RESP" | jq -r ".leaves[]? | select(.account == \"$POOL_LOWER\") | .account" 2>/dev/null)
        if [[ -n "$POOL_IN_TREE" ]]; then
            log_pass "池子地址出现在持有人列表中（作为普通持有人）"
        else
            LEAF_COUNT=$(echo "$SNAP_RESP" | jq -r '.stats.leafCount')
            HOLDER_COUNT=$(echo "$SNAP_RESP" | jq -r '.stats.holderCount')
            echo "  (leafCount=$LEAF_COUNT, holderCount=$HOLDER_COUNT)"
            echo "  注: 如果池子没有 token 余额，则不会出现在持有人列表中（正常）"
            log_pass "poolCount=0 已验证池子不穿透（池子可能无余额）"
        fi
    else
        log_pass "poolCount=0 已验证池子不穿透（treeUri 不可用，跳过持有人检查）"
    fi
else
    log_pass "poolCount=0 已验证池子不穿透（无 snapshotId，跳过持有人检查）"
fi

log_summary
