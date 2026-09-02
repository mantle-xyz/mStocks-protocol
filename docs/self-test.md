# 自测文档 — 私有化退市 / Warrant / 配资(链上 + 链下)

一条流程,两个仓库:`mstocks-merkle-service` 算树,`WarrantRegistry` 消费树。所以这份
文档按**执行顺序**写,链上链下交替,而不是按仓库分开。

- §0 开始之前必须知道的一件事
- §1 环境与前置条件
- §2 端到端 runbook(A → Z,照着敲)
- §3–§5 契约不变量对照表(已有 forge 用例的部分)
- §6 已知缺口

基线:`forge test` → **199 passed**(2026-09-02)。服务侧 `go test ./...` → 13 个包全过。

---

## §0 `total` 不是"发多少钱",是"叶子加起来等于多少"

`WarrantRegistry.claim`:

```solidity
out = amount * settleTotal / RATE_SCALE      // RATE_SCALE = 1e18
```

叶子里的 `amount` 是**归一化份额**,全部叶子加起来必须等于 **1e18**。所以调服务时:

```
"total": "1000000000000000000"
```

最大余额法保证 Σ 精确等于 1e18。传别的值不会报错,只会让 claim 按 `叶子/1e18` 缩放、
金额全错。

**这条从来没在真链上验过** —— 之前所有联调都传 1e24。这是本文档第一优先级。

采用份额而非绝对金额是契约的有意设计:root 定下来后 `settleTotal` 还能改(未 fund
之前),换资金池不用重算树。代价是每笔 claim 各自向下取整,合计支付比 `settleTotal`
少一点,余数留在 reserve 里由 `sweepUnclaimed` 收走 —— 正常,不是 bug。

---

## §1 环境与前置条件

### 链下服务

```
H=https://mstocks-merkle-service-sepolia-qa8.qa4.gomantle.org
写接口 header:  X-API-Key: dev
```

已确认(2026-09-02):`/healthz` 200、读接口无 key 200、写接口无 key/错 key 401、
`/healthz` 带错 key 200(它注册在鉴权链之外,否则错 key 会让 orchestrator 判 pod 死)。
池子注册表为空。

### 链上(Mantle 主网 5000)

| 项 | 地址 | 备注 |
|---|---|---|
| AAPL | `0xe38c5939cC1cF8cfa426A43c23A02782A1DE1118` | 快照标的,18 位,supply 100,000,`uiMultiplier` 1e18 |
| mUSDC | `0x242e2B1A4c693170Ef559EFa96Dc026a266226F5` | 结算资产 + 池子另一腿,**6 位**,`faucet()` 开放 |
| 池子 | `0xfbbf1b3d495BD925Cf7b42A2E3B53DaDfA868578` | Slipstream mUSDC/AAPL,tickSpacing **1** |
| NPM | `0xB65EDa352dF237089Cfc9647A8Ed7C159Cc8fE1E` | 部署块 99,428,654 |
| Slipstream factory | `0xF39196CEf9B5Bf90B23cfAE2eBeeFDf9a9F42604` | `getPool(t0, t1, int24 tickSpacing)` |
| WarrantRegistry | `0x086C53f310274499C2960EA66632B1860919968c` | `programCount = 0` |

### 角色

```
OPS_ROLE  → 0x1521d8796334fF0A73a233B88f52cB65719DCca9   ← 整条 program 生命周期
admin     → 0x3905e39fc43885335284dC4572eE414E0a10D8A3   ← 只管角色
```

OPS 地址同时是最大的 AAPL 持有人和唯一的 LP owner。admin 是另一个地址 —— 职责分离
是真的,不是纸面的。

### 池子里现在有什么

```
liquidity     107,349,821,945,467,589
池内 AAPL     5,710.715653815975875649
当前 tick     276,361
```

**一个 position**:

| tokenId | owner | 区间 | liquidity | 位置 |
|---|---|---|---|---|
| 93 | `0x1521d879…` | 275270 – 277278 | 107,349,821,945,467,589 | **区间内** |

它的 liquidity 正好等于池子的 `liquidity()`,确认是唯一一个。owner 同时是最大直接
持有人,所以顺带覆盖"既持币又做 LP"。

> **缺一个 position**:区间外的。区间外手续费应为 0,是验证"手续费按 position 各自算
> 而不是按池子摊平"最直接的办法。想验这条,加一个区间落在当前 tick 之外的 position
> (如 ticks 280000–281000)。不加也能跑完,只是少一条性质。

### 环境变量

```bash
export H=https://mstocks-merkle-service-sepolia-qa8.qa4.gomantle.org
export ETH_RPC_URL=https://rpc.mantle.xyz
export AAPL=0xe38c5939cC1cF8cfa426A43c23A02782A1DE1118
export MUSDC=0x242e2B1A4c693170Ef559EFa96Dc026a266226F5
export POOL=0xfbbf1b3d495BD925Cf7b42A2E3B53DaDfA868578
export REG=0x086C53f310274499C2960EA66632B1860919968c
export PK=<OPS 私钥>
```

---

## §2 端到端 runbook

### A. 冒烟

```bash
curl -s $H/healthz                                                        # {"status":"ok"}
curl -s "$H/v1/pools?chain_id=5000"                                       # {"pools":[]}
curl -so /dev/null -w '%{http_code}\n' -X POST $H/v1/pools -d '{}'        # 401
curl -so /dev/null -w '%{http_code}\n' -H 'X-API-Key: wrong' $H/healthz   # 200
```

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| A1 | healthz | 200 | |
| A2 | 读接口无 key | 200 | |
| A3 | 写接口无 key / 错 key | 401 | |
| A4 | healthz 带错 key | 200 | |

### B. 注册池子

```bash
curl -s -X POST $H/v1/pools -H 'X-API-Key: dev' -H 'Content-Type: application/json' -d "{
  \"address\": \"$POOL\", \"chain_id\": 5000, \"created_block\": 99541746
}" | jq
```

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| B1 | `kind` | `"slipstream"`(**自动识别**) | |
| B2 | `fee` / `tickSpacing` | `0` / `1` | |
| B3 | `token0` / `token1` | mUSDC / AAPL | |

`kind` 由"池子答不答 `fee()`"推出。这一族按 `(token0, token1, tickSpacing)` 建池子键,
读错会让 position 过滤一个都不命中、池子余额整块变残差、LP 一分拿不到。

**B4 反向用例** —— 不同 factory 的 NPM 必须被拒:

```bash
curl -s -X POST $H/v1/pools -H 'X-API-Key: dev' -H 'Content-Type: application/json' -d "{
  \"address\": \"$POOL\", \"chain_id\": 5000,
  \"position_manager\": \"0x46A15B0b27311cedF172AB29E4f4766fbE7F4364\"
}"
```

预期 **409**,消息里同时给出两个 factory 地址。(那是 PancakeSwap 在 BSC 的 NPM。)

### C. 重组保护

```bash
HEAD=$(cast block-number)
curl -s -X POST $H/v1/programs/snapshot -H 'X-API-Key: dev' -H 'Content-Type: application/json' -d "{
  \"token\": \"$AAPL\", \"record_block\": $HEAD, \"chain_id\": 5000,
  \"kind\": \"PROGRAM_KIND_WARRANT\", \"total\": \"1000000000000000000\"
}" | jq '{status, failureReason}'
```

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| C1 | 记录块 = 链头 | FAILED,`... has 0 confirmations, need 120` | |

### D. 出快照

```bash
RB=$((HEAD-200))
curl -s -X POST $H/v1/programs/snapshot -H 'X-API-Key: dev' -H 'Content-Type: application/json' -d "{
  \"token\": \"$AAPL\", \"record_block\": $RB, \"chain_id\": 5000,
  \"kind\": \"PROGRAM_KIND_WARRANT\", \"total\": \"1000000000000000000\",
  \"note\": \"self-test\"
}" | jq
export SID=<返回的 snapshotId>
```

**`total` 就是 §0。**

### E. 轮询

```bash
watch -n 5 "curl -s $H/v1/snapshots/$SID | jq '{status, stage, root, n: .stats.holderCount}'"
```

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| E1 | stage 依次前进不倒退 | `CANDIDATES → BALANCES → CLASSIFY → PASSTHROUGH → TREE → DONE` | |
| E2 | RUNNING 期间 stats 增长 | 不是全零 | |

### F. 核对树

```bash
curl -s $H/v1/snapshots/$SID | jq .stats
```

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| F1 | `totalSupply − totalHolding` | 等于 `poolResidual`(守恒恒等式) | |
| F2 | Σ 叶子 amount | **精确 1e18** | |
| F3 | `poolCount` / `positionCount` | `1` / `1` | |
| F4 | `candidateSource` | `dune:query/8571945/exec/…`(走主路径不是兜底) | |
| F5 | `uiMultiplier` | `1000000000000000000` | |
| F6 | `poolResidualBps` | 很小(大 = position 没找全) | |

```bash
# F2
curl -s -H 'X-API-Key: dev' "$H/v1/snapshots/$SID/tree" | jq '[.values[].amount|tonumber]|add'

# F7 池子地址不在树里 → 预期 404
curl -so /dev/null -w '%{http_code}\n' "$H/v1/snapshots/$SID/allocation?account=$POOL"

# F8 既持币又做 LP:holding 应当 = 链上 balanceOf + 穿透
A=0x1521d8796334fF0A73a233B88f52cB65719DCca9
curl -s "$H/v1/snapshots/$SID/allocation?account=$A" | jq '{holding, amount}'
cast call $AAPL 'balanceOf(address)(uint256)' $A --block $RB
```

### G. 独立重算 root

唯一不依赖服务自证的检查。

```bash
ROOT=$(curl -s $H/v1/snapshots/$SID | jq -r .root)
curl -s "$(curl -s $H/v1/snapshots/$SID | jq -r .treeUri)" -o /tmp/tree.json
# 若 403(bucket 还没开对象读),改用:
# curl -s -H 'X-API-Key: dev' "$H/v1/snapshots/$SID/tree" -o /tmp/tree.json

npm i @openzeppelin/merkle-tree
node -e '
const {StandardMerkleTree}=require("@openzeppelin/merkle-tree"), fs=require("fs");
const d=JSON.parse(fs.readFileSync("/tmp/tree.json","utf8")), root=process.argv[1];
const loaded=StandardMerkleTree.load(d);
const rebuilt=StandardMerkleTree.of(d.values.map(v=>v.value), d.leafEncoding);
let sum=0n; for(const v of d.values) sum+=BigInt(v.value[2]);
let ok=0; for(const [i,v] of loaded.entries())
  if(StandardMerkleTree.verify(root,d.leafEncoding,v,loaded.getProof(i))) ok++;
console.log("load  match  :", loaded.root===root);
console.log("rebuild match:", rebuilt.root===root);
console.log("Σ = 1e18     :", sum===10n**18n);
console.log("proofs       :", ok+"/"+d.values.length);
' $ROOT
```

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| G1 | `load match` | true | |
| G2 | `rebuild match` | true(**只用叶子重建,不看服务写的节点数组**) | |
| G3 | Σ = 1e18 | true | |
| G4 | proofs | 全过 | |

### H. 上链前的绿灯

```bash
curl -s -X POST -H 'X-API-Key: dev' "$H/v1/snapshots/$SID/verify" | jq
```

逐叶重验 proof,`configureProgram` 之前的最后一道检查。

### I. createProgram

```bash
cast send $REG 'createProgram(address,address)(uint256)' $AAPL $MUSDC --private-key $PK
export PID=$(cast call $REG 'programCount()(uint256)' | awk '{print $1-1}')
cast call $REG 'programs(uint256)(address,bytes32,address,uint256,uint64,uint64,uint8)' $PID
```

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| I1 | `state` | `1`(Created) | |
| I2 | `merkleRoot` | 全零 | |
| I3 | 非 OPS 调用 | revert | |

### J. 绑定到服务(可选但推荐)

```bash
curl -s -X POST $H/v1/programs -H 'X-API-Key: dev' -H 'Content-Type: application/json' -d "{
  \"snapshot_id\": \"$SID\", \"program_id\": \"$PID\", \"create_tx\": \"<tx hash>\"
}" | jq '{programId, registry, root, snapshotStatus}'
```

`registry` 不用传 —— 配置里有缺省值。

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| J1 | `registry` | `0x086c53f3…968c`(来自缺省) | |
| J2 | `root` | 等于 §G 的 `$ROOT` | |
| J3 | `GET /v1/programs/$PID` | 一个请求拿到 root + snapshotStatus,不用传 registry | |

### K. configureProgram

`settleTotal` 用 mUSDC 的 6 位精度。下例 = 1,000,000 mUSDC。

```bash
NOW=$(cast block --field timestamp)
cast send $REG 'configureProgram(uint256,(address,bytes32,address,uint256,uint64,uint64,uint8))' \
  $PID "(0x0000000000000000000000000000000000000000,$ROOT,0x0000000000000000000000000000000000000000,1000000000000,$NOW,$((NOW+604800)),2)" \
  --private-key $PK
```

零值 = 保留原值。这里 `token` 和 `settlementToken` 传零(createProgram 已设),
`state: 2` = Active。

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| K1 | `state` | `2`(Active) | |
| K2 | `merkleRoot` | `$ROOT` | |
| K3 | 状态回退 `state: 1` | revert `InvalidStateTransition` | |
| K4 | 直接跳 `state: 3` | revert `InvalidStateTransition` | |

### L. fund

```bash
cast send $MUSDC 'faucet()' --private-key $PK            # 白拿 1,000,000 mUSDC
cast send $MUSDC 'approve(address,uint256)' $REG 1000000000000 --private-key $PK
cast send $REG 'fund(uint256,uint256)' $PID 1000000000000 --private-key $PK
cast call $REG 'settleReserve(uint256)(uint256)' $PID
```

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| L1 | `settleReserve` | `1000000000000` | |
| L2 | fund 后改 `settleTotal` | revert `SettlementTermsLocked` | |

### M. claim

```bash
A=0x1521d8796334fF0A73a233B88f52cB65719DCca9
curl -s "$H/v1/snapshots/$SID/allocation?account=$A" | jq
# 取出 index / amount / proof

cast call $REG 'previewClaim(uint256,uint256)(uint256)' $PID <amount>
cast send $REG 'claim(uint256,uint256,address,uint256,bytes32[])' \
  $PID <index> $A <amount> "[<proof0>,<proof1>,...]" --private-key $PK
```

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| M1 | claim 成功 | 无 `InvalidProof` | |
| M2 | 实际到账 | 等于 `previewClaim` | |
| M3 | `warrant(PID, A)` | 等于叶子的 `amount` | |
| M4 | `isClaimed(PID, index)` | true | |
| M5 | 重复 claim | revert `AlreadyClaimed` | |
| M6 | 篡改 amount 后 claim | revert `InvalidProof` | |

**M7 —— 这次修的那个锁**:

```bash
cast send $REG 'configureProgram(uint256,(address,bytes32,address,uint256,uint64,uint64,uint8))' \
  $PID "(0x0,0x<任意别的 root>,0x0,0,0,0,0)" --private-key $PK
```

预期 revert **`ConfigureLockedAfterClaim`**。修之前这里会**成功**,把整份持有人名单换掉、
把已承诺的资金改派给原 root 里不存在的地址,而 `state` 仍是 `Active`。

**M8**:同上,只传 `deadline`,也应当 revert —— 锁是整体的,第一笔 claim 之后窗口不能
再延长。这是有意的代价。

### N. sweepUnclaimed

```bash
# 等过 deadline
cast send $REG 'sweepUnclaimed(uint256,address)' $PID <custody 地址> --private-key $PK
```

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| N1 | deadline 前调用 | revert `ClaimStillOpen` | |
| N2 | `to = 0x0` | revert `ZeroAddress` | |
| N3 | deadline 后调用 | reserve 归零,`state = 3` | |
| N4 | **扫走的金额** | 等于每笔 claim 向下取整的损失之和 | |

N4 是 §0 精度问题的落地检查。

---

## §3 WarrantRegistry 不变量对照

已有 forge 用例的部分,`forge test --match-path test/WarrantRegistry.t.sol` → 24 passed。

| 性质 | 用例 |
|---|---|
| 状态只能前进,永远到不了 Closed | `test_configureProgram_cannotRegressState` / `cannotJumpToClosed` / `cannotReopenClosedProgram` |
| fund 后结算条款冻结 | `test_configureProgram_settlementTermsLockedAfterFund` |
| **claim 后整个 patch 冻结** | `test_configureProgram_rootCannotBeSwappedAfterAClaim` |
| claim 后 deadline 不能延长 | `test_configureProgram_deadlineCannotBeExtendedAfterAClaim` |
| 零值 patch 保留原值 | `test_configure_patchKeepsZeroFields` |
| 窗口前/后、重复、错 proof | `test_claim_beforeStartReverts` / `afterDeadlineReverts_and_sweep` / `doubleClaimReverts` / `invalidProofReverts` |
| 未 configure 不可 claim | `test_claim_beforeConfigureReverts` |
| 未设结算资产 / reserve 不足 → **index 不消耗** | `test_claim_notConvertibleYet_thenRetry` / `insufficientReservedReverts_thenRetry` |
| 代他人 claim,钱归 account | `test_claim_onBehalfOfAnotherAccount` |
| 份额取整为 0 → revert 且 index 不消耗 | `test_claim_dustShareRoundingToZeroReverts` |
| sweep 到零地址 | `test_sweepUnclaimed_rejectsZeroAddress` |
| 配资(只存根,永不 claim) | `test_leverage_recordAnchorOnly` |
| 自授 / 最后一个 admin | `test_selfGrantReverts` / `test_lastAdminCannotRenounce` |

**仍然开放的一段**:`merkleRoot` 在 fund 之后、首笔 claim 之前可以替换。有意留的修正
窗口,但意味着"资金已承诺"本身不保护 root。要不要锁取决于运营是否需要这个窗口。

---

## §4 PrivatizationRegistry 不变量对照

核心公式:`out_i = amount × leg.total / oldSupplySnapshot`

`oldSupplySnapshot` 必须是**冻结后的固定快照**。claim 会销毁交回的旧 token,实时
`totalSupply` 会缩小,除以缩小的分母会超发。

| 性质 | 用例 |
|---|---|
| 多腿篮子按比例分发 | `test_createConfigureFundClaim_multiLegBasket` |
| 不超发 | `test_proRata_twoHolders_noOverDistribution` |
| program 之间 reserve 不互串 | `test_programIsolation` |
| CVR 二次赎回复用同一机制 | `test_cvrRedemption_reusesRegistry` |
| 空 legs 被拒 | `test_createProgram_rejectsEmptyLegs` |
| 被合规封禁的持有人整笔 revert | `test_claim_blockedHolderRevertsWhole` |
| claim 后 configure 冻结 | `test_configureProgram_lockedAfterClaimStarted` |

**契约不校验、只能靠流程保证的两条**:

1. `setMintAllowed(false)` 必须在取 `oldSupplySnapshot` **之前**
2. `oldSupplySnapshot` 必须等于冻结后的 `totalSupply()`

第 2 条填错(大了少发,小了超发到 reserve 耗尽),契约无从判断。**待补一个脚本层
对账**,或在契约里要求 `oldSupplySnapshot == totalSupply()` 且 `mintAllowed == false`
—— 后者更硬但会锁死"先配置后冻结"的顺序。

---

## §5 CustodyClaimRouter 不变量对照

CEX 热钱包只能 `transfer`,不能调合约,所以需要这个路由。信任边界四条都有用例,是三个
契约里覆盖最完整的。

| 性质 | 用例 |
|---|---|
| 正常路径:transfer → claimFor → 篮子原子转给热钱包 | `test_claimFor_forwardsBasketToHotWallet` |
| 未注册 / 已注销地址不可用 | `test_claimFor_rejectsUnregisteredHotWallet` / `test_deregisteredHotWalletCannotClaim` |
| 金额上限由 router 持有量约束 | `test_claimFor_amountBoundedByRouterBalance` |
| 注册是 admin,claimFor 是 OPS | `test_registerHotWallet_onlyAdmin` / `test_claimFor_onlyOps` |
| 误转可回收 | `test_rescue_recoversStrayOldTokens` |

---

## §6 已知缺口

| 项 | 说明 |
|---|---|
| **`total` 必须 1e18** | §0。链上从未验过 |
| 缺区间外 position | §1。少验"手续费按 position 各自算" |
| `merkleRoot` 在 fund 后仍可换 | §3。有意留的窗口 |
| `oldSupplySnapshot` 无链上校验 | §4 |
| `docs/corporate-actions-td.md` 缺失 | 两个契约的注释都引用了它(§4 / §5.1),文件不在仓库 |
| 幂等 | 同参数返回同一个快照。想重跑得改参数;`note` 不进哈希 |
| READY 的快照无法重跑 | 只有 FAILED 同参重提才重排队 |
| `API_KEY: "dev"` | 公网 ingress + 可猜密钥,自测期可以,上生产必须换 |
| `treeUri` 可能 403 | §G。bucket 的对象读策略未确认 |
| "零值 = 保留原值" | 无法把 `settleTotal` / `startTime` / `deadline` 改回 0。是否有清零需求待确认 |

---

## §7 复现基线

```bash
cd mStocks-protocol      && forge test              # 199 passed
cd mstocks-merkle-service && go test ./...          # 13 个包
```
