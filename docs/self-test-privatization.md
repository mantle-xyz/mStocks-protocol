# 自测文档 — 私有化退市 / Warrant / 配资

范围:`src/privatization/` 三个契约(`WarrantRegistry` / `PrivatizationRegistry` /
`CustodyClaimRouter`),分支 `feat/warrant-plus-privatization`。

不含 `scaledToken` / `complianceRegistry` / `pauseRegistry` / `tokenIssuer` —— 那几个
已在 README 里文档化并经过两轮审计(`docs/security-news/`)。

基线:`forge test` → **199 passed, 0 failed**(2026-09-01)。
privatization 三件:`forge test --match-path "test/{WarrantRegistry,PrivatizationRegistry,CustodyClaimRouter}.t.sol"`
→ **48 passed**(原 42 + 本轮新增 6)。

---

## 0. 必须先对齐的一件事:leaf 里的 `amount` 是份额,不是金额

这是链上与链下之间唯一一处**语义**约定,写错不会报错,只会算错钱。

`WarrantRegistry` 的 claim 逻辑:

```solidity
out = amount * settleTotal / RATE_SCALE      // RATE_SCALE = 1e18
```

所以 leaf 里的 `amount` 必须是**归一化份额**:`holding_i / Σholding × 1e18`,
**全部叶子加起来等于 1e18**。契约注释和 `test_claim_recordsAndSettles` 都是这个约定
(alice `0.6e18` + `settleTotal 500e6` → 拿到 `300e6`)。

而 `mstocks-merkle-service` 的 `POST /v1/programs/snapshot` 里 `total` 参数的含义是
"叶子加起来等于这个数"。所以:

| 调用 | 叶子之和 | 用于本契约 |
|---|---|---|
| `total: "1000000000000000000"` | 1e18 | ✅ 正确 |
| `total: "1000000000000000000000000"` | 1e24 | ❌ 支付会放大 10⁶ 倍,reserve 立刻不足 |

**目前为止所有的联调跑测用的都是 1e24**(BSC 那轮、Mantle 那轮),也就是说
**"服务产出的树能被这个契约正确消费"这件事还没被验证过一次**。这是本文档第一优先级。

采用份额而不是绝对金额是契约的有意设计:root 定下来之后 `settleTotal` 还能改
(未 fund 之前),换资金池不需要重算树。代价是每笔 claim 各自向下取整,合计支付会比
`settleTotal` 少一点点,余数留在 reserve 里由 `sweepUnclaimed` 收走 —— 这是正常的,
不是 bug。

### 精度边界(需实测)

份额 = `floor(holding_i × 1e18 / Σholding)`,再由最大余额法补齐到 1e18。持仓极小的
地址份额可能取整为 0;服务默认 `keep_zero_amounts: false`,这些地址**不会进树**。

- 待测:1e18 基数下,多少持仓会被抹成 0
- 待测:被抹掉的那部分份额去哪了(应当留在 reserve,由 sweep 收走)

---

## 1. 环境

| 项 | 值 |
|---|---|
| 链 | Mantle 主网 5000 |
| WarrantRegistry | `0x086C53f310274499C2960EA66632B1860919968c` |
| 测试标的 | AAPL `0xe38c5939cC1cF8cfa426A43c23A02782A1DE1118`(ScaledToken,`uiMultiplier` 1e18) |
| 测试稳定币 | Mock USDC `0x242e2B1A4c693170Ef559EFa96Dc026a266226F5`(6 位,**开放铸造**,已 verify) |
| LP 池子 | Slipstream mUSDC/AAPL `0xfbbf1b3d495BD925Cf7b42A2E3B53DaDfA868578`(tickSpacing 1) |
| 链下服务 | `mstocks-merkle-service`,配置见 mantle-config PR #16343 |

角色分离必须在测试前确认(这是审计过的仓库约定,不是新东西):

- `DEFAULT_ADMIN_ROLE` 只管角色,**不能**做任何运营动作
- 全部 program 生命周期(create / configure / fund / sweep)是 `OPS_ROLE`
- `grantRole` 不允许自授;最后一个 admin 不允许 renounce

---

## 2. WarrantRegistry

### 2.1 状态机

`None(0)` → `Created(1)` → `Active(2)` → `Closed(3)`

`configureProgram` 的 `state` 只能**严格向前**且**永远到不了 Closed**;`Closed` 只能由
`sweepUnclaimed` 设置,和"把剩余 reserve 扫走"原子配对。

| 用例 | 步骤 | 预期 | 覆盖 | 实测 |
|---|---|---|---|---|
| 正常路径 | create → configure(Active) → fund → claim | 成功 | `test_claim_recordsAndSettles` | |
| 状态不能回退 | Active 后 configure(state=Created) | revert `InvalidStateTransition` | `test_configureProgram_cannotRegressState` | |
| 不能跳到 Closed | configure(state=Closed) | revert `InvalidStateTransition` | `test_configureProgram_cannotJumpToClosed` | |
| 不能重开 | sweep 后 configure(state=Active) | revert `InvalidStateTransition` | `test_configureProgram_cannotReopenClosedProgram` | |
| 未 configure 不可 claim | create 后直接 claim | revert `NotActive` | `test_claim_beforeConfigureReverts` | ✅ 已补 |

### 2.2 "零值 = 保留原值" 的 patch 语义

`configureProgram` 每个字段为零表示不改。这是**故意的**,但也意味着:

- 无法把 `settleTotal` 改回 0
- 无法把 `settlementToken` 改回零地址
- 无法把 `startTime` / `deadline` 改回 0

| 用例 | 步骤 | 预期 | 覆盖 | 实测 |
|---|---|---|---|---|
| 只改 deadline | configure 只传 deadline | 其余字段不变 | `test_configure_patchKeepsZeroFields` | |
| 待确认 | 是否存在"需要把某字段清零"的运营场景 | —— | ⚠️ 设计问题,非缺陷 | |

### 2.3 结算条款的冻结

`settlementToken` / `settleTotal` 在 `settleReserve != 0`(即 fund 过)之后冻结。
理由:reserve 只按 fund 当时的 token 记账,改了会让旧 token 余额搁死、新 token 的
claim 从别的 program 的余额里出钱。

| 用例 | 步骤 | 预期 | 覆盖 | 实测 |
|---|---|---|---|---|
| fund 后锁 settleTotal | fund → configure(settleTotal=X) | revert `SettlementTermsLocked` | `test_configureProgram_settlementTermsLockedAfterFund` | |
| fund 前可改 | configure(settleTotal=A) → configure(settleTotal=B) | 成功,B 生效 | `test_configure_patchKeepsZeroFields` 部分覆盖 | |
| root 在 claim 之后不可替换 | 见下 | revert `ConfigureLockedAfterClaim` | `test_configureProgram_rootCannotBeSwappedAfterAClaim` | ✅ 已修 |
| deadline 在 claim 之后不可延长 | 同上 | revert `ConfigureLockedAfterClaim` | `test_configureProgram_deadlineCannotBeExtendedAfterAClaim` | ✅ 已修 |

### ✅ 已修:`merkleRoot` 曾可在注资并且已有 claim 之后被 OPS 替换

`WarrantRegistry.configureProgram` 只锁两件事:state 只能前进,以及
`settlementToken`/`settleTotal` 在 fund 后冻结。**`merkleRoot` 没有任何锁** ——
任何时候都能整块换掉,包括资金已到位、并且已经有人成功 claim 之后。

同分支同一个 commit(`d92fdac`)给 `PrivatizationRegistry` 加了
`claimStarted` + `ConfigureLockedAfterClaim`,`WarrantRegistry` **两个都没有**。这个不
对称更像是漏掉了,而不是刻意的设计差异。

**修复**:加了 `claimStarted` 映射 + `ConfigureLockedAfterClaim`,和
`PrivatizationRegistry` 同形。一次成功的 `claim` 之后,`configureProgram` 整体拒绝。

存储布局按**只追加不插入**处理:`claimStarted` 放在 `programCount` 之后(而不是像
`PrivatizationRegistry` 那样和其他 mapping 放一起),gap 从 45 减到 44 —— 这个合约已经
部署在代理后面,插槽位会把后面每个变量都挪位。当前 `programCount == 0` 所以插入恰好
无害,但不能依赖这个。

修复前的行为(已用测试证明,摘 `configureProgram` 那行锁之后两个新用例都会红):

```solidity
// Tree A: alice 60% @index0, bob 30% @index1
// Tree B: mallory 60% @index0(同一个 index),bob 30% @index1
id = createProgram(oldStock, usd);
configureProgram(id, {merkleRoot: rootA, settleTotal: 1000e6, window, state: Active});
fund(id, 1000e6);

claim(id, 1, bob, 0.3e18, proofBob);       // ✅ bob 拿到 300e6,claim 已落地

configureProgram(id, {merkleRoot: rootB}); // ✅ 不 revert,root 被换掉

claim(id, 0, alice, 0.6e18, proofAlice);   // ❌ InvalidProof —— 原受益人失去资格
claim(id, 0, mallory, 0.6e18, proofMal);   // ✅ mallory 拿到 600e6
```

结果:**已承诺的资金被改派给一个原始 root 里根本不存在的地址,原受益人一分没有**,
而链上没有任何状态变化能提示这件事发生过(`state` 仍是 `Active`,`ProgramConfigured`
事件里只有新 root)。

**代价**:锁是整体的,所以**第一笔 claim 之后 deadline 也不能再延长**。claim 之前
延长仍然可以(有用例)。窗口必须在开始 claim 之后调整的场景,只能新开一个 program。
这和 `PrivatizationRegistry` 的行为一致。

**仍然开放的一段**:`merkleRoot` 在 **fund 之后、第一笔 claim 之前**依然可以替换。
这是有意留的口子(资金到位后发现快照有误还能修),但它意味着"资金已承诺"本身不构成
对 root 的保护。要不要连这段也锁,取决于运营是否需要这个修正窗口。

### 2.4 claim

| 用例 | 步骤 | 预期 | 覆盖 | 实测 |
|---|---|---|---|---|
| 窗口前 | `block.timestamp < startTime` | revert `ClaimNotStarted` | `test_claim_beforeStartReverts` | |
| 窗口后 | `> deadline` | revert `ClaimClosed` | `test_claim_afterDeadlineReverts_and_sweep` | |
| 重复 claim | 同一 index 两次 | revert `AlreadyClaimed` | `test_claim_doubleClaimReverts` | |
| 错 proof | 篡改 amount | revert `InvalidProof` | `test_claim_invalidProofReverts` | |
| 未设结算资产 | `settlementToken == 0` | revert `NotConvertibleYet`,**index 不消耗** | `test_claim_notConvertibleYet_thenRetry` | |
| reserve 不足 | fund 不够 | revert `InsufficientReserved`,**index 不消耗** | `test_claim_insufficientReservedReverts_thenRetry` | |
| 代他人 claim | 任意地址提交 alice 的 proof | 成功,钱和记录都归 alice | `test_claim_onBehalfOfAnotherAccount` | ✅ 已补 |
| 份额取整为 0 | `amount × settleTotal / 1e18 == 0` | revert `NothingToSettle`,index 不消耗 | `test_claim_dustShareRoundingToZeroReverts` | ✅ 已补 |

"revert 时 index 不被消耗"是关键性质:它让持有人可以在运营补齐资金后重试,而不是
把额度烧掉。这两个用例已有,但**要确认它们断言了 `isClaimed` 仍为 false**。

### 2.5 sweepUnclaimed

| 用例 | 步骤 | 预期 | 覆盖 | 实测 |
|---|---|---|---|---|
| deadline 前不可扫 | `<= deadline` 调用 | revert `ClaimStillOpen` | `test_claim_afterDeadlineReverts_and_sweep` | |
| 扫完即 Closed | deadline 后调用 | reserve 归零,state=Closed | 同上 | |
| 只能 OPS | 非 OPS 调用 | revert | `test_sweepUnclaimed_onlyOps` | |
| 扫到零地址 | `to == 0` | revert `ZeroAddress` | `test_sweepUnclaimed_rejectsZeroAddress` | ✅ 已补 |

### 2.6 配资(record-only)

`settlementToken` 保持零、永不 fund、永不 claim,只做 root 上链存证。

| 用例 | 步骤 | 预期 | 覆盖 | 实测 |
|---|---|---|---|---|
| 只存根 | create(settlementToken=0) → configure(root, Active) | 成功,任何 claim revert `NotConvertibleYet` | `test_leverage_recordAnchorOnly` | |

---

## 3. PrivatizationRegistry

核心公式:`out_i = amount × leg.total / oldSupplySnapshot`

`oldSupplySnapshot` 必须是**冻结后的固定快照**,不能用实时 `totalSupply()` —— claim 会
销毁交回的旧 token,实时供应量会缩小,除以缩小的分母会超发。

| 用例 | 步骤 | 预期 | 覆盖 | 实测 |
|---|---|---|---|---|
| 多腿篮子 | create(多 leg) → configure → fund 每条腿 → claim | 按比例拿到每种奖励 | `test_createConfigureFundClaim_multiLegBasket` | |
| 不超发 | 两个持有人各自 claim | 合计不超过 leg.total | `test_proRata_twoHolders_noOverDistribution` | |
| program 隔离 | 两个 program 用同一 token | 各自 reserve 不互串 | `test_programIsolation` | |
| CVR 二次赎回 | 用 CVR-mStock 作为新 program 的 oldToken | 复用同一套机制 | `test_cvrRedemption_reusesRegistry` | |
| 空 legs | create(legs=[]) | revert | `test_createProgram_rejectsEmptyLegs` | |
| 被封禁持有人 | 合规名单里的地址 claim | 整笔 revert | `test_claim_blockedHolderRevertsWhole` | |
| claim 后锁 configure | 一次 claim 成功后 configure | revert | `test_configureProgram_lockedAfterClaimStarted` | |

**必须人工确认的运营前置条件**(契约不校验,只能靠流程):

1. `setMintAllowed(false)` 必须在取 `oldSupplySnapshot` **之前**执行
2. `oldSupplySnapshot` 必须等于冻结后的 `totalSupply()`

第 2 条如果填错(填大了会少发,填小了会超发到 reserve 耗尽),契约无从判断。
**待补:一个链上/脚本层的对账检查。**

---

## 4. CustodyClaimRouter

CEX 热钱包只能 `transfer`,不能调合约,所以需要这个路由。

| 用例 | 步骤 | 预期 | 覆盖 | 实测 |
|---|---|---|---|---|
| 正常路径 | 热钱包 transfer → OPS claimFor | 篮子原子转给热钱包 | `test_claimFor_forwardsBasketToHotWallet` | |
| 未注册地址 | claimFor(未注册) | revert | `test_claimFor_rejectsUnregisteredHotWallet` | |
| 注销后不可用 | deregister → claimFor | revert | `test_deregisteredHotWalletCannotClaim` | |
| 金额上限 | claimFor 超过 router 持有量 | revert | `test_claimFor_amountBoundedByRouterBalance` | |
| 权限分离 | 注册是 admin,claimFor 是 OPS | 各自越权 revert | `test_registerHotWallet_onlyAdmin` / `test_claimFor_onlyOps` | |
| 误转回收 | rescue | admin 可取回 | `test_rescue_recoversStrayOldTokens` | |

信任边界的四条(allowlist / 职责分离 / 金额上限 / 原子性)都有用例覆盖,这部分是三个
契约里最完整的。

---

## 5. 端到端联调(最高优先级,尚未做过)

前置:AAPL 池子当前 `liquidity = 0`、池内 AAPL 余额 0,100,000 AAPL 全在部署者一个
地址上。**必须先分币 + 加流动性**,否则快照只有一片叶子、`positionCount: 0`,验不到
任何东西。

### 步骤

1. **造持有人**:把 AAPL 分给 ≥5 个地址,其中至少 1 个既持币又做 LP
2. **加流动性**:通过 NPM `0xB65EDa352dF237089Cfc9647A8Ed7C159Cc8fE1E` 往
   `0xfbbf1b3d…8578` 加至少 2 个 position,一个在区间内、一个在区间外
   (区间外的手续费应为 0 —— 用来验证手续费是按 position 各自算而不是摊平)
3. **注册池子**:`POST /v1/pools`,确认返回 `kind: "slipstream"` / `fee: 0`
4. **出快照**:`POST /v1/programs/snapshot`,**`total` 必须是 `"1000000000000000000"`**
   (见 §0)
5. **核对**:
   - `Σ leaf amount == 1e18`(精确)
   - `Σ balanceOf == totalSupply`(服务的守恒检查,零容差)
   - 池子地址不在树里(`/allocation` 返回 404)
   - 既持币又做 LP 的地址:`balanceOf + LP 穿透 == 叶子 holding`
   - 用 `@openzeppelin/merkle-tree` 独立重算 root
6. **上链**:`createProgram` → `configureProgram(root, settleTotal, window, Active)`
7. **注资**:`fund`,金额 ≥ `settleTotal`
8. **claim**:用服务 `/allocation` 返回的 proof 调 `claim`
9. **核对支付**:`out == amount × settleTotal / 1e18`,与 `previewClaim` 一致
10. **扫尾**:等 deadline 后 `sweepUnclaimed`,确认剩余归零、state=Closed

### 必须验到的三个数

| 检查 | 期望 |
|---|---|
| 服务算出的 proof 能被链上 `claim` 接受 | 无 `InvalidProof` |
| 实际到账 = `previewClaim` | 完全相等 |
| 全部 claim 完后 reserve 剩余 | ≥ 0,且等于取整损失之和 |

第三条是 §0 那个精度问题的落地检查。

---

## 6. 已知缺口

| 项 | 说明 |
|---|---|
| `docs/corporate-actions-td.md` 缺失 | `PrivatizationRegistry` 和 `CustodyClaimRouter` 的注释都引用了它(§4 / §5.1),文件不在仓库里 |
| ~~root 在 fund + claim 后仍可替换~~ | **已修**,见 §2.3。仍可在 fund 后、首笔 claim 前替换 —— 有意留的修正窗口 |
| `oldSupplySnapshot` 无链上校验 | 见 §3。填错会超发或少发,契约无从判断 |
| 份额取整为 0 的持有人 | 见 §0。1e18 基数下的边界需实测 |
| 链下服务与契约的 `amount` 语义 | 见 §0。**从未联调验证过** |


---

## 7. 复现基线

```bash
cd /Users/user/mStocks-protocol
forge test --match-path "test/{WarrantRegistry,PrivatizationRegistry,CustodyClaimRouter}.t.sol" -vv
```

2026-09-01:全仓 199 passed;privatization 三件 48 passed。

本轮新增 6 个用例:

```
test_configureProgram_rootCannotBeSwappedAfterAClaim        ← 回归,摘掉锁会红
test_configureProgram_deadlineCannotBeExtendedAfterAClaim   ← 记录锁的代价
test_claim_beforeConfigureReverts
test_claim_onBehalfOfAnotherAccount
test_claim_dustShareRoundingToZeroReverts
test_sweepUnclaimed_rejectsZeroAddress
```
