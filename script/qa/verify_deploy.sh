#!/bin/bash
# mStocks 部署验证脚本 (DPL-01 ~ DPL-07)
# 用法: source .env && bash script/qa/verify_deploy.sh
set +e

# ── 从 .env 读取，也支持环境变量覆盖 ──
RPC="${RPC:-${RPC_URL:-https://rpc.sepolia.mantle.xyz}}"
COMPLIANCE="${COMPLIANCE:-$COMPLIANCE_ADDR}"
PAUSE_MANAGER="${PAUSE_MANAGER:-$PAUSE_MANAGER_ADDR}"
FACTORY="${FACTORY:-$FACTORY_ADDR}"
TOKEN="${TOKEN:-$TOKEN_ADDR}"
VAULT="${VAULT:-$ISSUER_VAULT_ADDR}"
ADMIN="${ADMIN:-$ADMIN_ADDR}"
QA_VAULT_OPS="${QA_VAULT_OPS:-$QA_VAULT_OPS}"
QA_OPERATOR="${QA_OPERATOR:-$QA_OPERATOR}"
QA_COMPLIANCE_OPS="${QA_COMPLIANCE_OPS:-$QA_COMPLIANCE_OPS}"
QA_PAUSE_OPS="${QA_PAUSE_OPS:-$QA_PAUSE_OPS}"
QA_HOT_WALLET="${QA_HOT_WALLET:-$QA_HOT_WALLET}"

: "${RPC:?需要设置 RPC 或 RPC_URL}"
: "${COMPLIANCE:?需要设置 COMPLIANCE 或 COMPLIANCE_ADDR}"
: "${PAUSE_MANAGER:?需要设置 PAUSE_MANAGER 或 PAUSE_MANAGER_ADDR}"
: "${FACTORY:?需要设置 FACTORY 或 FACTORY_ADDR}"
: "${TOKEN:?需要设置 TOKEN 或 TOKEN_ADDR}"
: "${VAULT:?需要设置 VAULT 或 ISSUER_VAULT_ADDR}"
: "${ADMIN:?需要设置 ADMIN 或 ADMIN_ADDR}"

ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
PASS=0
FAIL=0

check() {
  local name=$1 expected=$2 actual=$3
  actual=$(echo "$actual" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"')
  expected=$(echo "$expected" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"')
  if [ "$actual" = "$expected" ]; then
    echo "  [PASS] $name"
    PASS=$((PASS+1))
  else
    echo "  [FAIL] $name (expected: $expected, got: $actual)"
    FAIL=$((FAIL+1))
  fi
}

check_nonzero() {
  local name=$1 actual=$2
  actual=$(echo "$actual" | tr -d '[:space:]')
  if [ "$actual" -gt 0 ] 2>/dev/null; then
    echo "  [PASS] $name (size: $actual)"
    PASS=$((PASS+1))
  else
    echo "  [FAIL] $name (codesize: $actual)"
    FAIL=$((FAIL+1))
  fi
}

echo "=========================================="
echo "  mStocks 部署验证 (QA)"
echo "=========================================="
echo "  RPC:      $RPC"
echo "  ADMIN:    $ADMIN"
echo "  TOKEN:    $TOKEN"
echo "  VAULT:    $VAULT"
echo "=========================================="

# --- DPL-01: 合约部署 ---
echo ""
echo "--- DPL-01: 合约部署成功 ---"
check_nonzero "ComplianceRegistry" "$(cast codesize $COMPLIANCE --rpc-url $RPC 2>/dev/null)"
check_nonzero "PauseRegistry" "$(cast codesize $PAUSE_MANAGER --rpc-url $RPC 2>/dev/null)"
check_nonzero "ScaledTokenFactory" "$(cast codesize $FACTORY --rpc-url $RPC 2>/dev/null)"
check_nonzero "ScaledToken" "$(cast codesize $TOKEN --rpc-url $RPC 2>/dev/null)"
check_nonzero "TokenIssuer" "$(cast codesize $VAULT --rpc-url $RPC 2>/dev/null)"

# --- DPL-03: config.toml 值 ---
echo ""
echo "--- DPL-03: config.toml 值 ---"
check "name" "Apple Inc." "$(cast call $TOKEN 'name()(string)' --rpc-url $RPC 2>/dev/null)"
check "symbol" "AAPL" "$(cast call $TOKEN 'symbol()(string)' --rpc-url $RPC 2>/dev/null)"
check "assetCode" "US0378331005" "$(cast call $TOKEN 'assetCode()(string)' --rpc-url $RPC 2>/dev/null)"

# --- DPL-04: admin 角色 ---
echo ""
echo "--- DPL-04: admin 角色 ---"
check "ComplianceRegistry admin" "true" "$(cast call $COMPLIANCE 'hasRole(bytes32,address)(bool)' $ADMIN_ROLE $ADMIN --rpc-url $RPC 2>/dev/null)"
check "PauseRegistry admin" "true" "$(cast call $PAUSE_MANAGER 'hasRole(bytes32,address)(bool)' $ADMIN_ROLE $ADMIN --rpc-url $RPC 2>/dev/null)"
check "ScaledToken admin" "true" "$(cast call $TOKEN 'hasRole(bytes32,address)(bool)' $ADMIN_ROLE $ADMIN --rpc-url $RPC 2>/dev/null)"
check "TokenIssuer admin" "true" "$(cast call $VAULT 'hasRole(bytes32,address)(bool)' $ADMIN_ROLE $ADMIN --rpc-url $RPC 2>/dev/null)"
check "ScaledTokenFactory admin" "true" "$(cast call $FACTORY 'hasRole(bytes32,address)(bool)' $ADMIN_ROLE $ADMIN --rpc-url $RPC 2>/dev/null)"

# --- DPL-05: 角色分配 ---
echo ""
echo "--- DPL-05: 角色分配 ---"
TOKEN_ISSUER=$(cast call $TOKEN "ISSUER_ROLE()(bytes32)" --rpc-url $RPC 2>/dev/null)
TOKEN_MULT=$(cast call $TOKEN "MULTIPLIER_SCHEDULER_ROLE()(bytes32)" --rpc-url $RPC 2>/dev/null)
VAULT_OPS_R=$(cast call $VAULT "OPS_ROLE()(bytes32)" --rpc-url $RPC 2>/dev/null)
COMP_OPS=$(cast call $COMPLIANCE "OPS_ROLE()(bytes32)" --rpc-url $RPC 2>/dev/null)
PM_PAUSE_R=$(cast call $PAUSE_MANAGER "PAUSE_ROLE()(bytes32)" --rpc-url $RPC 2>/dev/null)
PM_UNPAUSE_R=$(cast call $PAUSE_MANAGER "UNPAUSE_ROLE()(bytes32)" --rpc-url $RPC 2>/dev/null)

check "vault ISSUER_ROLE" "true" "$(cast call $TOKEN 'hasRole(bytes32,address)(bool)' $TOKEN_ISSUER $VAULT --rpc-url $RPC 2>/dev/null)"

if [ -n "$QA_OPERATOR" ]; then
  check "operator MULTIPLIER_SCHEDULER_ROLE" "true" "$(cast call $TOKEN 'hasRole(bytes32,address)(bool)' $TOKEN_MULT $QA_OPERATOR --rpc-url $RPC 2>/dev/null)"
fi
if [ -n "$QA_VAULT_OPS" ]; then
  check "walletOps vault OPS_ROLE" "true" "$(cast call $VAULT 'hasRole(bytes32,address)(bool)' $VAULT_OPS_R $QA_VAULT_OPS --rpc-url $RPC 2>/dev/null)"
fi
if [ -n "$QA_COMPLIANCE_OPS" ]; then
  check "complianceOps compliance OPS_ROLE" "true" "$(cast call $COMPLIANCE 'hasRole(bytes32,address)(bool)' $COMP_OPS $QA_COMPLIANCE_OPS --rpc-url $RPC 2>/dev/null)"
fi
if [ -n "$QA_PAUSE_OPS" ]; then
  check "pauseOps PAUSE_ROLE" "true" "$(cast call $PAUSE_MANAGER 'hasRole(bytes32,address)(bool)' $PM_PAUSE_R $QA_PAUSE_OPS --rpc-url $RPC 2>/dev/null)"
  check "pauseOps UNPAUSE_ROLE" "true" "$(cast call $PAUSE_MANAGER 'hasRole(bytes32,address)(bool)' $PM_UNPAUSE_R $QA_PAUSE_OPS --rpc-url $RPC 2>/dev/null)"
fi

# --- DPL-06: TokenIssuer ---
echo ""
echo "--- DPL-06: TokenIssuer ---"
check_nonzero "numApprovedRecipients" "$(cast call $VAULT 'numApprovedRecipients()(uint256)' --rpc-url $RPC 2>/dev/null)"
if [ -n "$QA_HOT_WALLET" ]; then
  check "hotWallet registered" "true" "$(cast call $VAULT 'isApprovedRecipient(address)(bool)' $QA_HOT_WALLET --rpc-url $RPC 2>/dev/null)"
fi

# --- 职责分离: admin 不持有操作角色 ---
echo ""
echo "--- 职责分离: admin 无操作角色 ---"
check "admin NO ISSUER_ROLE" "false" "$(cast call $TOKEN 'hasRole(bytes32,address)(bool)' $TOKEN_ISSUER $ADMIN --rpc-url $RPC 2>/dev/null)"
check "admin NO MULTIPLIER_SCHEDULER_ROLE" "false" "$(cast call $TOKEN 'hasRole(bytes32,address)(bool)' $TOKEN_MULT $ADMIN --rpc-url $RPC 2>/dev/null)"
check "admin NO compliance OPS_ROLE" "false" "$(cast call $COMPLIANCE 'hasRole(bytes32,address)(bool)' $COMP_OPS $ADMIN --rpc-url $RPC 2>/dev/null)"
check "admin NO PAUSE_ROLE" "false" "$(cast call $PAUSE_MANAGER 'hasRole(bytes32,address)(bool)' $PM_PAUSE_R $ADMIN --rpc-url $RPC 2>/dev/null)"
check "admin NO UNPAUSE_ROLE" "false" "$(cast call $PAUSE_MANAGER 'hasRole(bytes32,address)(bool)' $PM_UNPAUSE_R $ADMIN --rpc-url $RPC 2>/dev/null)"
check "admin NO vault OPS_ROLE" "false" "$(cast call $VAULT 'hasRole(bytes32,address)(bool)' $VAULT_OPS_R $ADMIN --rpc-url $RPC 2>/dev/null)"

# --- Token 基础状态 ---
echo ""
echo "--- Token 状态 ---"
check "mintAllowed" "true" "$(cast call $TOKEN 'mintAllowed()(bool)' --rpc-url $RPC 2>/dev/null)"
check "burnAllowed" "true" "$(cast call $TOKEN 'burnAllowed()(bool)' --rpc-url $RPC 2>/dev/null)"
check "compliance addr" "$COMPLIANCE" "$(cast call $TOKEN 'compliance()(address)' --rpc-url $RPC 2>/dev/null)"
check "pauseManager addr" "$PAUSE_MANAGER" "$(cast call $TOKEN 'pauseManager()(address)' --rpc-url $RPC 2>/dev/null)"
check "not paused" "false" "$(cast call $PAUSE_MANAGER 'isTokenPaused(address)(bool)' $TOKEN --rpc-url $RPC 2>/dev/null)"

echo ""
echo "=========================================="
echo "  结果: $PASS passed, $FAIL failed"
echo "=========================================="

[ "$FAIL" -eq 0 ] || exit 1
