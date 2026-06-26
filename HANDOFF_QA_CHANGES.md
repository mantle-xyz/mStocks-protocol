# HANDOFF_QA.md 更新清单

**变更日期：** 2026-06-25
**变更原因：** 协议引入了**严格的职责分离** —— `DEFAULT_ADMIN_ROLE` 现在**只**负责发放角色，不再能直接执行任何操作。`Compliance` / `PauseManager` / `SecuritiesToken` 的所有操作类函数从"admin OR ops"改为"仅 ops"。

下面按 HANDOFF_QA.md 的章节顺序列出需要修改的部分。

---

## 第 3.2 节 测试账户

**新增一个角色：**

| 角色 | 用途 | 所需余额 |
|---|---|---|
| **QA ops** | 持有所有运维角色（token ISSUER + OPS、Compliance OPS、PauseManager OPS），实际执行 mint/burn/pause/合规/multiplier 等 | ≥ 0.5 MNT |

**修改 QA admin 描述：**

旧：~~"持有 DEFAULT_ADMIN_ROLE，部署 + 操作"~~
新：**"仅持有 DEFAULT_ADMIN_ROLE。只能 grantRole / revokeRole，以及修改配置项（setName/setMintEnabled 等）。不能直接 mint/burn/pause/setUIMultiplier/管 blocklist。"**

---

## 第 3.3 节 QA 自部署流程

**新增步骤 5（在记录地址之后）：**

```bash
# 5. admin 把所需 role grant 给 ops EOA（一次性，运维设置）
export OPS=0xYourOpsEOA

cast send $TOKEN "grantRole(bytes32,address)" \
  $(cast keccak "ISSUER_ROLE") $OPS \
  --rpc-url $RPC --private-key $PK

cast send $TOKEN "grantRole(bytes32,address)" \
  $(cast keccak "OPS_ROLE") $OPS \
  --rpc-url $RPC --private-key $PK

cast send $COMPLIANCE "grantRole(bytes32,address)" \
  $(cast keccak "OPS_ROLE") $OPS \
  --rpc-url $RPC --private-key $PK

cast send $PAUSE_MANAGER "grantRole(bytes32,address)" \
  $(cast keccak "OPS_ROLE") $OPS \
  --rpc-url $RPC --private-key $PK

# 给 ops EOA 充一些 MNT 作为 gas
cast send $OPS --value 0.1ether \
  --rpc-url $RPC --private-key $PK
```

> 提示：如果用我们的 `script/Smoke.s.sol`，**不用手动 grant**——脚本内置确定性 ops 钱包，第一次跑时 admin 会自动 grant 这 4 个 role 并充 gas（幂等，再跑时跳过）。手动 grant 适用于 QA 想用 cast / Mantlescan UI 直接调用的场景。

---

## 第 4 节 角色与权限矩阵

**整张表改成：**

| 操作 | DEFAULT_ADMIN | ISSUER | OPS | 任意人 |
|---|:---:|:---:|:---:|:---:|
| mint / burn | ❌ | ✅ | ❌ | ❌ |
| setUIMultiplier | ❌ | ❌ | ✅ (token) | ❌ |
| pause / unpause (PauseManager) | ❌ | ❌ | ✅ (PauseManager) | ❌ |
| 管理 blocklist / sanctions (Compliance) | ❌ | ❌ | ✅ (Compliance) | ❌ |
| setMintEnabled / setBurnEnabled | ✅ | ❌ | ❌ | ❌ |
| setName / setSymbol / setIdentifier | ✅ | ❌ | ❌ | ❌ |
| setCompliance / setPauseManager | ✅ | ❌ | ❌ | ❌ |
| grantRole（给**他人**） | ✅ | ❌ | ❌ | ❌ |
| grantRole（**给自己**） | ❌ (见 4.1) | ❌ | ❌ | ❌ |
| revokeRole / renounceRole | ✅ | ❌ | ❌ | ❌ |
| transfer / approve / transferFrom | 自己的余额 | 自己的余额 | 自己的余额 | 自己的余额 |

**3 条说明改写：**

旧：~~"Compliance 合约：DEFAULT_ADMIN 或 OPS_ROLE 可管理 blocklist / sanctions"~~
新：**"Compliance 合约：仅 OPS_ROLE 可管理 blocklist / sanctions。admin 只负责 grant/revoke 该 role。"**

旧：~~"PauseManager 合约：DEFAULT_ADMIN 或 OPS_ROLE 可 pause / unpause"~~
新：**"PauseManager 合约：仅 OPS_ROLE 可 pause / unpause。"**

**Factory 一行保留不变**（admin 才能 deployToken，这是治理决策不是运维操作）。

---

## 第 4.1 节 Self-grant guard

**无变化**，但加一段补充说明：

> **配合职责分离一起看：** admin 不能给自己 grant 任何 role + admin 本身不能执行操作 = admin 必须委派给独立的 ops 账号才能让协议跑起来。这两条规则共同强制了 multisig / 治理与运维的物理分离。

---

## 第 5 节 测试用例

### 5.2 Mint / Burn —— **反向断言**

旧：~~"admin 可以 mint / burn"~~
新：

- [ ] **admin 调用 mint / burn revert `UnauthorizedRole`**（admin 没有 ISSUER_ROLE）
- [ ] issuer 可以 mint / burn（不变）
- [ ] **operator 调用 mint / burn revert `UnauthorizedRole`**（OPS_ROLE 不管 mint/burn）
- [ ] 非 admin / 非 issuer 调用 revert（不变）
- [ ] `setMintEnabled(false)` 后即使 issuer 也 revert `MintDisabled`（不变）
- [ ] `setBurnEnabled(false)` 同上
- [ ] totalSupply / 调用者 balance 正确变化（不变）

### 5.3 Pause —— **反向断言**

旧：~~"非 admin / 非 OPS revert"~~
新：

- [ ] **admin 调用 pauseToken / pauseAllTokens revert `MissingPauseRole`**
- [ ] pauseOps（持有 OPS_ROLE 的 EOA）可以 pause / unpause
- [ ] `isTokenPaused` view 返回正确（不变）
- [ ] pause 后任意 transfer revert `TokenPaused`（不变）

### 5.4 Compliance —— **反向断言**

旧：~~"非 admin / 非 OPS revert"~~
新：

- [ ] **admin 调用 addToBlocklist / addToSanctionsList 等 revert `MissingBlocklistRole`**
- [ ] complianceOps（持有 OPS_ROLE 的 EOA）可以管理 blocklist / sanctions
- [ ] 其余检查项不变（blocklist 阻断、sanctions 阻断、epoch reset、token-scoped）

### 5.5 UI Multiplier —— **反向断言**

旧：~~"admin 可以调用 `setUIMultiplier`"~~
新：

- [ ] **admin 调用 setUIMultiplier revert `UnauthorizedRole`**（admin 没有 OPS_ROLE）
- [ ] operator (OPS_ROLE) 可以调用
- [ ] issuer (ISSUER_ROLE) 调用 revert `UnauthorizedRole`（不变）
- [ ] 其余边界检查不变（1e9–1e27 范围、365 天上限、past 时间戳）

### 5.6 Role 管理 —— 保留 self-grant 那 5 项，新增 1 项

- [ ] **admin 调用 token.mint / token.burn / token.setUIMultiplier / pauseManager.pauseToken / compliance.addToBlocklist 全部 revert**（说明 admin 真的没法直接干活）

---

## 第 6 节 自测结论

**数字 + 一段措辞更新：**

旧：~~"Forge 单元/集成测试 (`test/SecuritiesToken.t.sol`) | 42 | 42/42 PASS"~~
新：**"Forge 单元/集成测试 (`test/SecuritiesToken.t.sol`) | 45 | 45/45 PASS"**（新增 5 个 admin-cannot-X 反向断言）

链上 Smoke 数据保留旧的；脚本逻辑改了但行为对外可观察的是一样的（22 笔 tx 仍然成功，只是签名者从 admin 变成了内部派生的 ops 钱包）。可以加一句：

> **本次更新：** Smoke 脚本现在内部派生一个确定性 ops 钱包，自动从 admin 那拿到所需的 4 个 role + 一笔 gas（幂等）。运维侧只需要传 admin 的私钥，跟之前命令一样：
> ```bash
> forge script script/Smoke.s.sol:Smoke --sig "runAll(address)" $TOKEN \
>   --rpc-url $RPC --private-key $ADMIN_PK --broadcast
> ```
> 第一次跑会比之前多 5 笔 tx（4 个 grantRole + 1 个 native gas top-up），之后跑没变化。

---

## 第 7 节 QA 测试建议

**新增一条优先级 P0：**

> **职责分离边界测试** —— 必须验证 admin **不能**直接执行任何运维操作（mint/burn/pause/compliance/multiplier）。这是协议的核心安全保障，回归时绝对不能丢。

---

## 第 8 节 已知限制 / 设计取舍

**新增一行：**

| 项 | 说明 |
|---|---|
| 严格职责分离 | admin 仅负责 grant/revoke role + 修改配置，**不能直接执行任何运维操作**。所有 mint/burn/pause/合规/multiplier 操作必须由 admin 单独 grant role 给其它 EOA 之后，由那个 EOA 签名执行。 |

---

## 第 10.1 节 关键命令速查

**不变。** Smoke 命令保持兼容（脚本内部自动 setup ops），admin 私钥就能跑通整套测试。

如果 QA 想手动用 cast 测试（不通过 Smoke 脚本），需要先用 admin 把 role grant 给一个 ops 私钥账号，然后用那个账号调 mint/burn/pause/etc.。参考第 3.3 节步骤 5。

---

## 第 10.2 节 自定义错误一览

**新增 2 行：**

| 来源 | 错误 | 触发场景 |
|---|---|---|
| Compliance | `MissingBlocklistRole` | **任何非 OPS_ROLE 调用 blocklist/sanctions 管理函数（admin 也会 revert）** |
| PauseManager | `MissingPauseRole` | **任何非 OPS_ROLE 调用 pause/unpause（admin 也会 revert）** |

> （上面 2 个错误原表里已有，但触发条件更严格 —— 强调"admin 也会 revert"。）

旧表里 `SecuritiesToken.UnauthorizedRole` 的描述也要更新：

旧：~~"mint/burn 非 admin/issuer，或 multiplier 非 admin/ops"~~
新：**"mint/burn 调用者非 ISSUER_ROLE，或 multiplier 调用者非 OPS_ROLE"**

---

## 总结

| 影响范围 | 必须改 | 可以保留 |
|---|---|---|
| 权限矩阵（第 4 节） | ✅ 整张表反转 | — |
| 角色定义（第 3.2 节） | ✅ 加 ops 角色 | admin / user 描述 |
| 部署流程（第 3.3 节） | ✅ 加 grant 步骤 | 1-4 步部署 |
| 测试用例（第 5.2 / 5.3 / 5.4 / 5.5） | ✅ 反向断言 | 边界 / 业务路径 |
| 自测结论（第 6 节） | ✅ 数字 + Smoke 说明 | tx hash 表 |
| 已知限制（第 8 节） | ✅ 加 "严格职责分离" 一行 | 其余 |
| 错误清单（第 10.2 节） | ✅ 修措辞 | — |

需要我直接应用这些改动到 `HANDOFF_QA.md` 里、还是先你审完再来？
