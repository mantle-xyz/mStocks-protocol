# 提测文档 — mStocks Protocol

给 QA 的完整自测/提测说明。覆盖全部链上合约 + 链下 Merkle 服务。

| | |
|---|---|
| 提测日期 | 2026-09-02 |
| 合约仓库 | `mStocks-protocol` @ `feat/warrant-plus-privatization` |
| 服务仓库 | `mstocks-merkle-service` @ `develop` |
| 自动化基线 | 合约 **199 passed / 0 failed**;服务 **13 个包全过** |
| 已过审计 | Blocksec、Spearbit(`docs/security-news/`)—— 覆盖 §6.1–§6.3,**不含** privatization 模块 |

---

## 1. 这个系统做什么

代币化证券。三层:

**代币层** —— `ScaledToken` 是一个 ERC-20,额外实现 EIP-8056 的"显示乘数"
(`uiMultiplier`):拆股/合股/分红时不给每个人改余额,而是改一个全局乘数。所以
**链上余额(raw)和用户看到的数(UI)是两个不同的数**,`UI = raw × uiMultiplier / 1e18`。
这是全系统最容易搞混的一点。

代币通过 `ScaledTokenFactory` 部署在**共享 beacon 代理**后面 —— 一个实现,多个代币。

**管控层** —— `ComplianceRegistry`(按代币的封禁名单 + 全局制裁名单)、
`PauseRegistry`(按代币 + 全局暂停)、`TokenIssuer`(托管式铸销路由,白名单收款人)。

**公司行动层**(本次新增,未过审计):
- `PrivatizationRegistry` —— 私有化退市。旧代币换一篮子奖励(USDC / 新代币 / CVR)
- `WarrantRegistry` —— Warrant 发放(按记录日快照的 Merkle 树领取)+ 配资(只存证不发钱)
- `CustodyClaimRouter` —— 让只能 `transfer` 的 CEX 热钱包也能参与私有化换币

**链下服务** —— `mstocks-merkle-service`。按记录日区块给持有人出快照(含 Uniswap V3
风格 LP 穿透)、算额度、建 OpenZeppelin 兼容的 Merkle 树、对外发 proof。
**它不发交易** —— root 上链始终是运营的动作。

---

## 2. 提测范围

### 在范围

| 模块 | 章节 | 是否过审计 |
|---|---|---|
| ScaledToken + Factory | §6.1 | ✅ |
| ComplianceRegistry / PauseRegistry | §6.2 | ✅ |
| TokenIssuer | §6.3 | ✅ |
| 链下 Merkle 服务 | §6.4 | — |
| WarrantRegistry(warrant + 配资) | §6.5 | ❌ 本次新增 |
| PrivatizationRegistry | §6.6 | ❌ 本次新增 |
| CustodyClaimRouter | §6.7 | ❌ 本次新增 |
| 端到端主流程 | §7 | — |

**测试重点放在 §6.4–§6.7 和 §7** —— 前三个模块过了两轮审计且有 151 个自动化用例,
后面四个是新的。

### 不在范围

- 合约升级流程(ProxyAdmin / beacon 升级本身)
- 前端
- CEX 侧的对账流程(`CustodyClaimRouter` 只测到链上那一段)
- 多链部署(当前只在 Mantle 主网)

---

## 3. 环境与准入

### 链

```
Mantle 主网, chainId 5000
RPC:  https://rpc.mantle.xyz
浏览器: https://mantlescan.xyz
```

### 合约地址

| 合约 | 地址 |
|---|---|
| WarrantRegistry | `0x086C53f310274499C2960EA66632B1860919968c` |
| AAPL(测试标的,ScaledToken) | `0xe38c5939cC1cF8cfa426A43c23A02782A1DE1118` |
| Mock USDC(结算资产) | `0x242e2B1A4c693170Ef559EFa96Dc026a266226F5` |
| Slipstream 池子 mUSDC/AAPL | `0xfbbf1b3d495BD925Cf7b42A2E3B53DaDfA868578` |
| Slipstream NPM | `0xB65EDa352dF237089Cfc9647A8Ed7C159Cc8fE1E` |
| Slipstream factory | `0xF39196CEf9B5Bf90B23cfAE2eBeeFDf9a9F42604` |

> `PrivatizationRegistry` / `CustodyClaimRouter` / `ScaledTokenFactory` /
> `ComplianceRegistry` / `PauseRegistry` / `TokenIssuer` **在主网上还没有测试部署**。
> 这几个模块目前只能用 `forge test` 和本地 anvil 测(§5.3)。需要主网实例的话找研发部一套。

### 服务

```
https://mstocks-merkle-service-sepolia-qa8.qa4.gomantle.org
写接口 header:  X-API-Key: dev
```

### 需要谁给什么

| 需要 | 找谁 | 用途 |
|---|---|---|
| `OPS_ROLE` 私钥 | 研发 | §6.5–§6.7 全部写操作 |
| `DEFAULT_ADMIN_ROLE` 私钥 | 研发 | 角色分离的反向用例 |
| Mock USDC | 不用要 | `faucet()` 任何人可调,自己拿 |
| AAPL | 研发 | 需要多个持有人时 |

当前角色分布(已核对):

```
WarrantRegistry OPS_ROLE  → 0x1521d8796334fF0A73a233B88f52cB65719DCca9
WarrantRegistry admin     → 0x3905e39fc43885335284dC4572eE414E0a10D8A3
```

两个是不同地址 —— **职责分离必须验**:admin 不能做任何运营动作,OPS 不能改角色。

### 工具

```bash
foundry     # cast / forge      https://getfoundry.sh
jq
node + npm  # 独立重算 Merkle root 用
```

---

## 4. 先跑自动化基线

提测前确认基线是绿的,否则手工测的结果没有参照。

```bash
cd mStocks-protocol && forge test
# 预期:199 passed; 0 failed
#   ScaledToken 105 / TokenIssuer 46 / WarrantRegistry 24
#   PrivatizationRegistry 16 / CustodyClaimRouter 8

cd mstocks-merkle-service && go test ./...
# 预期:13 个包 ok
```

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| 4.1 | `forge test` | 199 passed / 0 failed | |
| 4.2 | `go test ./...` | 13 个包 ok,无 FAIL | |

---

## 5. 冒烟(15 分钟)

### 5.1 服务活着

```bash
export H=https://mstocks-merkle-service-sepolia-qa8.qa4.gomantle.org
curl -s $H/healthz                                                       # {"status":"ok"}
curl -s "$H/v1/pools?chain_id=5000"                                      # {"pools":[...]}
curl -so /dev/null -w '%{http_code}\n' -X POST $H/v1/pools -d '{}'       # 401
curl -so /dev/null -w '%{http_code}\n' -H 'X-API-Key: wrong' $H/healthz  # 200
```

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| 5.1.1 | `/healthz` | 200 `{"status":"ok"}` | |
| 5.1.2 | 读接口无 key | 200(用户取自己的 proof 不需要 key) | |
| 5.1.3 | 写接口无 key / 错 key | **401** | |
| 5.1.4 | `/healthz` 带错 key | **200** | |

5.1.4 是有意的:健康检查注册在鉴权链之外,否则一个配错的 key 会让 k8s 以为 pod 死了。

### 5.2 链上合约在

```bash
export ETH_RPC_URL=https://rpc.mantle.xyz
cast call 0x086C53f310274499C2960EA66632B1860919968c 'programCount()(uint256)'
cast call 0xe38c5939cC1cF8cfa426A43c23A02782A1DE1118 'symbol()(string)'      # "AAPL"
cast call 0xe38c5939cC1cF8cfa426A43c23A02782A1DE1118 'uiMultiplier()(uint256)' # 1e18
cast call 0x242e2B1A4c693170Ef559EFa96Dc026a266226F5 'decimals()(uint8)'     # 6
```

### 5.3 本地环境(测未部署的模块)

```bash
cd mStocks-protocol
anvil &                                                # 本地链
forge script script/Deploy.s.sol --broadcast --rpc-url http://localhost:8545
```

`script/` 下的脚本:

| 脚本 | 用途 |
|---|---|
| `Deploy.s.sol` | 全套部署 |
| `PrivatizationRegistryOps.s.sol` | 私有化 program 的运营动作(§6.6) |
| `CustodyClaimRouterOps.s.sol` | 热钱包注册 / claimFor(§6.7) |
| `SetUIMultiplier.s.sol` | 调度拆股(§6.1.2) |
| `DeployTimelock.s.sol` | 时间锁 |

§6.1–§6.3 和 §6.6–§6.7 在主网无实例,用这个环境测。

---

## 6. 分模块用例

每张表的「自动化」列表示是否已有 forge 用例覆盖 —— 有的可以只抽验,没有的必须手工过。

### 6.1 ScaledToken + Factory(105 个自动化用例)

**核心概念:raw vs UI**。链上余额是 raw,用户看到的是 `raw × uiMultiplier / 1e18`。
`uiMultiplier` 初始 1e18(1.0x),拆股改它。

| # | 用例 | 预期 | 自动化 | 实测 |
|---|---|---|---|---|
| 6.1.1 | `toUIAmount(raw)` 随乘数变化 | `raw × mult / 1e18` | ✅ | |
| 6.1.2 | 调度拆股 `setUIMultiplier(2e18, T)` | T 之后 UI 余额翻倍,**raw 不变** | ✅ | |
| 6.1.3 | 通知期不足的调度 | revert —— 有最小提前期 `minMultiplierNotice` | ✅ | |
| 6.1.4 | 通知期为 0 或超过 365 天(部署参数) | revert `InvalidNoticePeriod` | ✅ | |
| 6.1.5 | 覆盖一个待生效的调度 | 允许,发事件 | ✅ | |
| 6.1.6 | 非 `MULTIPLIER_SCHEDULER_ROLE` 调度 | revert | ✅ | |
| 6.1.7 | admin 调度 | **revert** —— admin 不做运营动作 | ✅ | |
| 6.1.8 | `ISSUER_ROLE` 授给 EOA | **revert** —— 必须是合约 | ✅ | |
| 6.1.9 | admin 自授任何角色 | revert `SelfGrantNotAllowed` | ✅ | |
| 6.1.10 | 最后一个 admin renounce | revert | ✅ | |
| 6.1.11 | 非最后一个 admin renounce | 允许 | ✅ | |
| 6.1.12 | EIP-2612 `permit` | 签名转账授权生效;nonce 递增 | ✅ | |
| 6.1.13 | Factory 部署重复 symbol / assetCode | revert | ✅ | |
| 6.1.14 | Factory 部署时 issuer 是 EOA | revert | ✅ | |
| 6.1.15 | `renameSymbol` / `renameAssetCode` 顺序 | 必须先在代币上改,注册表才认 | ✅ | |
| 6.1.16 | beacon 升级 | 已部署代币的 notice 一并更新 | ✅ | |

**手工重点**:6.1.2 要在**真实时间推进**下验(自动化用 `vm.warp`)。QA 应当调度一个
几分钟后生效的乘数,等到时间点,确认 UI 余额确实变了而 raw 没变。

### 6.2 ComplianceRegistry / PauseRegistry

| # | 用例 | 预期 | 自动化 | 实测 |
|---|---|---|---|---|
| 6.2.1 | 封禁地址后转账 | revert | ✅ | |
| 6.2.2 | 封禁名单**按代币隔离** | A 代币封的人在 B 代币能转 | ✅ | |
| 6.2.3 | 全局制裁 | 所有代币都禁 | ✅ | |
| 6.2.4 | `clearSanctions` | O(1) 清空 | ✅ | |
| 6.2.5 | 重复封禁同一地址 | 事件和状态都去重 | ✅ | |
| 6.2.6 | `replaceSanctions` 传空列表 | revert | ✅ | |
| 6.2.7 | 单代币暂停后转账 | revert | ✅ | |
| 6.2.8 | 全局暂停 | 所有代币转账 revert | ✅ | |
| 6.2.9 | 未暂停时 unpause | revert | ✅ | |
| 6.2.10 | unpause 后恢复转账 | 成功 | ✅ | |
| 6.2.11 | 非 `OPS_ROLE` 操作名单/暂停 | revert | ✅ | |

**手工重点**:6.2.1 和 6.2.7 要验**被封禁/暂停期间 §6.5 的 claim 也会失败**
—— 跨模块的相互作用自动化里没覆盖。

### 6.3 TokenIssuer(46 个自动化用例)

托管式铸销:只能铸给**白名单收款人**或自己。

| # | 用例 | 预期 | 自动化 | 实测 |
|---|---|---|---|---|
| 6.3.1 | OPS 铸给白名单收款人 | 成功,发 `Minted` | ✅ | |
| 6.3.2 | OPS 铸给非白名单地址 | revert `RecipientNotApproved` | ✅ | |
| 6.3.3 | OPS 铸给自己(库存) | 成功 | ✅ | |
| 6.3.4 | **admin 铸/销** | **revert** —— admin 不做运营动作 | ✅ | |
| 6.3.5 | 加白名单:重复 / 零地址 / 自己 | 全部 revert | ✅ | |
| 6.3.6 | 移除白名单后铸 | revert | ✅ | |
| 6.3.7 | 暂停后铸/销 | revert | ✅ | |
| 6.3.8 | issuer 没有代币的 `ISSUER_ROLE` | **原子** revert,无部分状态 | ✅ | |
| 6.3.9 | 代币 `setMintAllowed(false)` 后铸 | revert | ✅ | |
| 6.3.10 | 从非白名单地址销 | revert `FromNotApproved` | ✅ | |
| 6.3.11 | 非 admin `withdraw` | revert | ✅ | |
| 6.3.12 | issuer 收原生币 | 拒收 | ✅ | |
| 6.3.13 | `initialize` 二次调用 | revert | ✅ | |

### 6.4 链下 Merkle 服务

#### ⚠️ 6.4.0 开始之前必须知道:`total` 不是"发多少钱"

`WarrantRegistry.claim` 算的是:

```
到账 = 叶子amount × settleTotal / 1e18
```

所以叶子里的 `amount` 是**归一化份额**,全部叶子加起来必须等于 **1e18**。调服务时:

```json
"total": "1000000000000000000"
```

**传别的值不会报错**,只会让 claim 支付按 `叶子/1e18` 缩放、金额全错。这是全系统唯一
一处"填错不报错只算错钱"的地方,也是本次提测第一优先级 —— 它**从未在真链上验过**。

#### 6.4.1 池子注册

```bash
curl -s -X POST $H/v1/pools -H 'X-API-Key: dev' -H 'Content-Type: application/json' -d '{
  "address": "0xfbbf1b3d495BD925Cf7b42A2E3B53DaDfA868578",
  "chain_id": 5000, "created_block": 99541746
}' | jq
```

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| 6.4.1.1 | `kind` | `"slipstream"` —— **服务自动识别**,不是传进去的 | |
| 6.4.1.2 | `fee` / `tickSpacing` | `0` / `1` | |
| 6.4.1.3 | 传一个不同 factory 的 NPM(`0x46A15B0b27311cedF172AB29E4f4766fbE7F4364`) | **409**,消息里给出两个 factory 地址 | |
| 6.4.1.4 | 重复注册同一池子 | 成功(幂等),`enabled` 不被重置 | |
| 6.4.1.5 | `POST /v1/pools/{addr}/disable` 后出快照 | 该池子不参与穿透 | |

6.4.1.1 的意义:这一族池子按 `(token0, token1, tickSpacing)` 建键而不是 fee。识别错会
让 position 过滤一个都不命中 —— 池子余额整块变成"未归属残差",LP 一分拿不到,而快照
**仍然是 READY**。

#### 6.4.2 重组保护

```bash
HEAD=$(cast block-number)
# 用 record_block = $HEAD 发一次
```

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| 6.4.2.1 | 记录块 = 链头 | FAILED,`... has 0 confirmations, need 120` | |
| 6.4.2.2 | 记录块 = 链头 − 200 | 正常进入 PENDING | |

#### 6.4.3 出快照与轮询

```bash
RB=$((HEAD-200))
curl -s -X POST $H/v1/programs/snapshot -H 'X-API-Key: dev' -H 'Content-Type: application/json' -d "{
  \"token\": \"0xe38c5939cC1cF8cfa426A43c23A02782A1DE1118\",
  \"record_block\": $RB, \"chain_id\": 5000,
  \"kind\": \"PROGRAM_KIND_WARRANT\",
  \"total\": \"1000000000000000000\"
}" | jq
export SID=<snapshotId>

watch -n 5 "curl -s $H/v1/snapshots/$SID | jq '{status, stage, root, n: .stats.holderCount}'"
```

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| 6.4.3.1 | 立刻返回 | `snapshotId` + `PENDING`(异步) | |
| 6.4.3.2 | stage 依次前进 | `CANDIDATES → BALANCES → CLASSIFY → PASSTHROUGH → TREE → DONE`,不倒退 | |
| 6.4.3.3 | RUNNING 期间 stats | 逐步增长,不是全零 | |
| 6.4.3.4 | 幂等:同参数再发一次 | 返回**同一个** `snapshotId`,不重跑 | |
| 6.4.3.5 | 改 `total` 再发 | 产生**新**快照 | |

#### 6.4.4 核对结果

```bash
curl -s $H/v1/snapshots/$SID | jq .stats
```

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| 6.4.4.1 | `totalSupply − totalHolding` | 精确等于 `poolResidual`(守恒恒等式) | |
| 6.4.4.2 | Σ 叶子 `amount` | **精确 1e18** | |
| 6.4.4.3 | `poolCount` / `positionCount` | ≥ 1 / ≥ 1 | |
| 6.4.4.4 | `candidateSource` | `dune:query/…/exec/…`(走主路径而非日志兜底) | |
| 6.4.4.5 | `uiMultiplier` | `1000000000000000000` | |
| 6.4.4.6 | `poolResidualBps` | 很小;大 = position 没找全 | |
| 6.4.4.7 | 池子地址查 allocation | **404** —— 它被展开成 LP 叶子,自己不在树里 | |
| 6.4.4.8 | 既持币又做 LP 的地址 | `holding` = 链上 `balanceOf` + LP 穿透金额 | |

```bash
# 6.4.4.2
curl -s -H 'X-API-Key: dev' "$H/v1/snapshots/$SID/tree" | jq '[.values[].amount|tonumber]|add'

# 6.4.4.7
curl -so /dev/null -w '%{http_code}\n' \
  "$H/v1/snapshots/$SID/allocation?account=0xfbbf1b3d495BD925Cf7b42A2E3B53DaDfA868578"

# 6.4.4.8
A=0x1521d8796334fF0A73a233B88f52cB65719DCca9
curl -s "$H/v1/snapshots/$SID/allocation?account=$A" | jq '{holding, amount}'
cast call 0xe38c5939cC1cF8cfa426A43c23A02782A1DE1118 'balanceOf(address)(uint256)' $A --block $RB
```

#### 6.4.5 独立重算 root(**最重要的一条**)

这是整套系统里唯一**不依赖服务自证**的检查。

```bash
ROOT=$(curl -s $H/v1/snapshots/$SID | jq -r .root)
curl -s -H 'X-API-Key: dev' "$H/v1/snapshots/$SID/tree" -o /tmp/tree.json

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
console.log("sum = 1e18   :", sum===10n**18n);
console.log("proofs       :", ok+"/"+d.values.length);
' $ROOT
```

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| 6.4.5.1 | `load match` | true | |
| 6.4.5.2 | `rebuild match` | true —— **只用叶子重建,完全不看服务写的节点数组** | |
| 6.4.5.3 | `sum = 1e18` | true | |
| 6.4.5.4 | proofs | 全部通过 | |
| 6.4.5.5 | 篡改任意一片叶子的 amount 再验 | 该 proof **不通过** | |

6.4.5.2 是关键那条。6.4.5.5 是为了证明前四条不是恒真的。

#### 6.4.6 上链前的绿灯

```bash
curl -s -X POST -H 'X-API-Key: dev' "$H/v1/snapshots/$SID/verify" | jq
```

逐叶重验。这是 `configureProgram` 之前的最后一道检查。

### 6.5 WarrantRegistry(24 个自动化用例)

```bash
export REG=0x086C53f310274499C2960EA66632B1860919968c
export AAPL=0xe38c5939cC1cF8cfa426A43c23A02782A1DE1118
export MUSDC=0x242e2B1A4c693170Ef559EFa96Dc026a266226F5
export PK=<OPS 私钥>
```

#### 状态机:`None(0) → Created(1) → Active(2) → Closed(3)`

| # | 用例 | 预期 | 自动化 | 实测 |
|---|---|---|---|---|
| 6.5.1 | `createProgram(AAPL, mUSDC)` | 返回 programId,`state = 1` | ✅ | |
| 6.5.2 | 非 OPS 调 `createProgram` | revert | ✅ | |
| 6.5.3 | **admin** 调 `createProgram` | **revert** | ✅ | |
| 6.5.4 | `configureProgram(root, settleTotal, window, state=2)` | `state = 2`,root 生效 | ✅ | |
| 6.5.5 | 状态回退 `state=1` | revert `InvalidStateTransition` | ✅ | |
| 6.5.6 | 直接跳 `state=3` | revert `InvalidStateTransition` | ✅ | |
| 6.5.7 | sweep 之后再 `state=2` | revert | ✅ | |
| 6.5.8 | 只传 `deadline`(其余 0) | 只改 deadline,其余保留 | ✅ | |
| 6.5.9 | 未 configure 就 claim | revert `NotActive` | ✅ | |

#### 注资与冻结

| # | 用例 | 预期 | 自动化 | 实测 |
|---|---|---|---|---|
| 6.5.10 | `fund` | `settleReserve` 增加 | ✅ | |
| 6.5.11 | fund 后改 `settleTotal` / `settlementToken` | revert `SettlementTermsLocked` | ✅ | |
| 6.5.12 | 非 OPS `fund` | revert | ✅ | |
| 6.5.13 | `settlementToken` 为零时 fund | revert `NotConvertibleYet` | ✅ | |

#### claim

| # | 用例 | 预期 | 自动化 | 实测 |
|---|---|---|---|---|
| 6.5.14 | 正常 claim | 到账 = `previewClaim`;`warrant[pid][account]` = 叶子 amount | ✅ | |
| 6.5.15 | 窗口开始前 | revert `ClaimNotStarted` | ✅ | |
| 6.5.16 | 窗口结束后 | revert `ClaimClosed` | ✅ | |
| 6.5.17 | 同一 index 二次 claim | revert `AlreadyClaimed` | ✅ | |
| 6.5.18 | 篡改 amount | revert `InvalidProof` | ✅ | |
| 6.5.19 | 未设结算资产时 claim | revert `NotConvertibleYet`,**index 不消耗** | ✅ | |
| 6.5.20 | reserve 不足时 claim | revert `InsufficientReserved`,**index 不消耗** | ✅ | |
| 6.5.21 | 补齐资金后重试 6.5.19/20 | 成功 | ✅ | |
| 6.5.22 | **代他人 claim** | 任意地址提交 alice 的 proof → 钱和记录都归 **alice**,提交者拿 0 | ✅ | |
| 6.5.23 | 份额小到取整为 0 | revert `NothingToSettle`,index 不消耗 | ✅ | |

6.5.19/20 的"index 不消耗"是关键性质:持有人可以在运营补齐资金后重试,而不是把额度
烧掉。**手工务必确认 `isClaimed(pid, index)` 仍是 false。**

#### ⚠️ 6.5.24 / 6.5.25 —— 本次修复的缺陷,重点验

```bash
# claim 成功之后,尝试换掉 root
cast send $REG 'configureProgram(uint256,(address,bytes32,address,uint256,uint64,uint64,uint8))' \
  $PID "(0x0,0x<任意别的root>,0x0,0,0,0,0)" --private-key $PK
```

| # | 用例 | 预期 | 自动化 | 实测 |
|---|---|---|---|---|
| 6.5.24 | 首笔 claim 后换 `merkleRoot` | revert **`ConfigureLockedAfterClaim`** | ✅ | |
| 6.5.25 | 首笔 claim 后延长 `deadline` | revert `ConfigureLockedAfterClaim` | ✅ | |

**修复前的行为**:6.5.24 会**成功** —— 整份持有人名单被换掉,已承诺的资金改派给原
root 里不存在的地址,原受益人 `InvalidProof`,而 `state` 仍是 `Active`、链上没有任何
迹象。6.5.25 是这个整体锁的代价:第一笔 claim 之后窗口不能再延长,只能新开 program。

**仍然开放**:`merkleRoot` 在 fund 之后、**首笔 claim 之前**可以替换。这是有意留的
修正窗口 —— 请确认这符合运营预期。

#### sweep

| # | 用例 | 预期 | 自动化 | 实测 |
|---|---|---|---|---|
| 6.5.26 | deadline 前 sweep | revert `ClaimStillOpen` | ✅ | |
| 6.5.27 | `to = 0x0` | revert `ZeroAddress` | ✅ | |
| 6.5.28 | deadline 后 sweep | reserve 归零,`state = 3` | ✅ | |
| 6.5.29 | **扫走的金额** | 等于每笔 claim 向下取整的损失之和 | ❌ | |

6.5.29 是 §6.4.0 精度问题的落地检查,没有自动化用例,**必须手工算一遍**。

#### 配资(record-only)

| # | 用例 | 预期 | 自动化 | 实测 |
|---|---|---|---|---|
| 6.5.30 | `createProgram(token, 0x0)` + configure(root, Active) | 成功,root 上链存证 | ✅ | |
| 6.5.31 | 对它 claim | revert `NotConvertibleYet` | ✅ | |

配资只做存证,永不注资、永不 claim。快照侧用 `kind: PROGRAM_KIND_LEVERAGE` + `ratio`
(不是 `total`)。

### 6.6 PrivatizationRegistry(16 个自动化用例,主网无实例)

核心公式:`到账_i = 交回量 × leg.total / oldSupplySnapshot`

| # | 用例 | 预期 | 自动化 | 实测 |
|---|---|---|---|---|
| 6.6.1 | 多腿篮子:create → configure → fund 每条腿 → claim | 按比例拿到每种奖励 | ✅ | |
| 6.6.2 | 两个持有人各自 claim | 合计不超过 `leg.total` | ✅ | |
| 6.6.3 | 两个 program 用同一 token | reserve 不互串 | ✅ | |
| 6.6.4 | CVR 二次赎回(CVR 作为新 program 的 oldToken) | 复用同一机制 | ✅ | |
| 6.6.5 | `createProgram(legs=[])` | revert | ✅ | |
| 6.6.6 | 被合规封禁的持有人 claim | **整笔** revert | ✅ | |
| 6.6.7 | 首笔 claim 后 configure | revert | ✅ | |
| 6.6.8 | fund 后改 `oldToken` / `oldSupplySnapshot` | revert | ✅ | |

#### ⚠️ 契约不校验、只能靠流程保证的两条

| # | 用例 | 怎么验 | 实测 |
|---|---|---|---|
| 6.6.9 | `setMintAllowed(false)` 必须在取 `oldSupplySnapshot` **之前** | 人工核对操作顺序 + 交易时间 | |
| 6.6.10 | `oldSupplySnapshot` 必须等于冻结后的 `totalSupply()` | `cast call oldToken totalSupply` 与配置值逐位比对 | |

6.6.10 填错的后果:填大了少发,**填小了超发直到 reserve 耗尽**。契约完全无从判断。
这是本模块最高风险项。

### 6.7 CustodyClaimRouter(8 个自动化用例,主网无实例)

CEX 热钱包只能 `transfer`、不能调合约,所以需要这个路由。

| # | 用例 | 预期 | 自动化 | 实测 |
|---|---|---|---|---|
| 6.7.1 | 热钱包 transfer → OPS `claimFor` | 篮子**原子**转给热钱包 | ✅ | |
| 6.7.2 | `claimFor` 未注册地址 | revert | ✅ | |
| 6.7.3 | 注销后 `claimFor` | revert | ✅ | |
| 6.7.4 | `claimFor` 金额 > router 持有量 | revert | ✅ | |
| 6.7.5 | 非 admin 注册热钱包 | revert | ✅ | |
| 6.7.6 | 非 OPS 调 `claimFor` | revert | ✅ | |
| 6.7.7 | admin `rescue` 误转的代币 | 成功取回 | ✅ | |
| 6.7.8 | **OPS 密钥泄露的边界** | 既不能加热钱包、也不能付给未注册地址 → 无法转移资产 | ✅ | |

6.7.8 是这个设计的核心承诺,建议专门验一遍:用 OPS 权限尝试一切能想到的取钱路径。

---

## 7. 端到端主流程

前六节是分模块。这一节是**一条完整业务流**,按执行顺序,链上链下交替。

前置:§6.4.1 池子已注册,§6.4.3 快照已 READY 且 `total` 是 1e18。

| 步 | 动作 | 命令 | 检查 |
|---|---|---|---|
| 1 | 建 program | `cast send $REG 'createProgram(address,address)(uint256)' $AAPL $MUSDC --private-key $PK` | `state=1`,root 全零 |
| 2 | 绑定到服务(可选) | `POST /v1/programs {snapshot_id, program_id}` | 返回的 `root` 等于快照的 root |
| 3 | 轮询 program | `GET /v1/programs/{pid}` | 一个请求拿到 `root` + `snapshotStatus`,**不用传 registry** |
| 4 | 上链 root | `configureProgram(pid, {root, settleTotal, startTime, deadline, state:2})` | `state=2` |
| 5 | 领结算资产 | `cast send $MUSDC 'faucet()' --private-key $PK` | 拿到 1,000,000 mUSDC |
| 6 | 注资 | `approve` + `fund(pid, amount)` | `settleReserve` = amount |
| 7 | 取 proof | `GET /v1/snapshots/{sid}/allocation?account=…` | 返回 index / amount / proof |
| 8 | 预览 | `previewClaim(pid, amount)` | 与下一步实际到账一致 |
| 9 | claim | `claim(pid, index, account, amount, proof)` | 无 `InvalidProof`;到账 = 第 8 步 |
| 10 | 验锁 | 再 `configureProgram` 换 root | revert `ConfigureLockedAfterClaim` |
| 11 | 等过 deadline | | |
| 12 | 扫尾 | `sweepUnclaimed(pid, custody)` | reserve 归零,`state=3` |
| 13 | 对账 | 手算 | 扫走的 = Σ 每笔取整损失 |

**三个必须验到的数**:

| # | 检查 | 预期 | 实测 |
|---|---|---|---|
| 7.1 | 服务给的 proof 被链上接受 | 无 `InvalidProof` | |
| 7.2 | 实际到账 = `previewClaim` | 完全相等 | |
| 7.3 | 全部 claim 后 reserve 余额 | ≥ 0,且等于取整损失之和 | |

---

## 8. 已知问题与限制

**提测时已知,不需要重复报**:

| # | 项 | 影响 |
|---|---|---|
| 8.1 | `total` 传错不报错 | §6.4.0。金额全错但流程正常 |
| 8.2 | `merkleRoot` 在 fund 后、首笔 claim 前仍可换 | §6.5。有意留的修正窗口,待产品确认 |
| 8.3 | `oldSupplySnapshot` 无链上校验 | §6.6.10。填错会超发 |
| 8.4 | 首笔 claim 后 deadline 不能延长 | §6.5.25。整体锁的代价 |
| 8.5 | 池子里缺**区间外**的 position | 无法验证"手续费按 position 各自算而不摊平" |
| 8.6 | READY 的快照无法重跑 | 只有 FAILED 同参重提才重排队 |
| 8.7 | `API_KEY: "dev"` | 公网 ingress + 可猜密钥。自测期可接受,**上生产必须换** |
| 8.8 | `treeUri`(S3 直连)可能 403 | bucket 的对象读策略未确认。改用 `GET /tree`(带 key) |
| 8.9 | "零值 = 保留原值" | 无法把 `settleTotal` / `startTime` / `deadline` 改回 0 |
| 8.10 | `docs/corporate-actions-td.md` 缺失 | 两个契约的注释引用了它 |
| 8.11 | §6.1–6.3、§6.6–6.7 主网无实例 | 只能本地 anvil 测(§5.3) |

---

## 9. 缺陷报告需要什么

链上问题:

```
交易 hash + 区块高度
合约地址 + 调用的函数 + 全部参数
预期 / 实际(revert 的话贴 error 名)
mantlescan 链接
```

服务问题:

```
snapshotId(或 programId)
完整的 curl 命令(隐去 API key)
响应 body
时间点(便于查 pod 日志)
```

`snapshotId` 是最重要的一个 —— 服务侧所有状态都能从它查到,包括
`stats.candidateSource`(实际用了哪个候选源)和 `stage`(卡在哪一步)。

---

## 10. 附:复现基线

```bash
cd mStocks-protocol      && forge test    # 199 passed / 0 failed
cd mstocks-merkle-service && go test ./...  # 13 个包
```

2026-09-02。合约 `feat/warrant-plus-privatization`,服务 `develop`。
