# mStocks Solana Core 程序设计文档

> 状态：已评审（决策见 §10），首版已实现 · 2026-11-05 · 分支 `feat/solana-core`
> 背景与选型见 [solana-research-report.md](solana-research-report.md)，本文只讲实现。

## 1. 范围

**本次实现：**
- `mstocks-core`：Solana 上唯一的自研程序（Anchor）。
- 发币与配置脚本：创建带扩展的 Mint、接入 Core、注册 CCIP pool。
- 测试：基于 LiteSVM，加载主网版 Token-2022 运行。

**不在本次范围：** Mantle 侧合约（自定义 Token Pool、multiplier 发送合约）、后端服务（事件监听、黑名单、冻结调用）、前端。

**已确定的前提：**
- 精度 9 位；Mantle 为唯一发行链；Solana 上的币只由 CCIP BurnMint pool 铸造。
- 合规采用「先用后查」：黑名单在后端，后端调用 Core 冻结账户。
- 不启用 Transfer Hook；Mint 上预留休眠的 Hook 扩展，其 authority 由 Squads 多签直接持有。
- multiplier 采用方案 B：两条链各自调度，CCIP 只负责代币跨链。
- 开启 Permanent Delegate（delegate = Authority PDA），用于强制划转。

---

## 2. 总体结构

```
          Squads 多签（Admin）        后端 / 运营（各角色密钥）
                 │                            │
                 ▼                            ▼
          ┌────────────────── mstocks-core ──────────────────┐
          │ Config · 角色 · MintState                        │
          │ Authority PDA（代币各项权限的持有者，CPI 签名）    │
          └───────────────────────┬──────────────────────────┘
                                  ▼ CPI
                          Token-2022 Mint（每个股票一个）
                                  ▲
                    CCIP BurnMint pool（持有铸造权）
```

**核心原则：** 代币的每项管理权限（multiplier、暂停、冻结、元数据、强制划转）都交给 Core 的 Authority PDA。任何私钥都不能直接操作代币，只能调用 Core；Core 先检查角色和规则，通过后再 CPI 到 Token-2022。

---

## 3. 账户模型

| 账户 | PDA seeds | 字段 | 说明 |
| --- | --- | --- | --- |
| `Config` | `["config"]` | `admin`、`pending_admin`、`hook_authority`（Squads，用于 `register_mint` 校验）、`min_notice`（默认 300s）、`max_horizon`（默认 365 天）、`bump` | 全局唯一 |
| `RoleEntry` | `["role", role_id, member]` | `role`、`member`、`bump` | 账户存在即表示拥有该角色，对应 Mantle 的 `AccessControl`，支持一个角色多个成员 |
| `MintState` | `["mint", mint]` | `mint`、`mantle_token`（20 字节）、`bump` | 登记过的股票才能被 Core 操作 |
| Authority PDA | `["authority"]` | 无数据 | 作为各项 Token-2022 权限的持有者，用于 CPI 签名 |

**为什么 Authority PDA 是全局一个，不是每个 mint 一个：** 所有操作都要经过同一套角色检查，按 mint 拆分并不能减少风险，只会让配置更复杂。各 mint 之间的隔离由 `MintState` 登记和账户校验来保证。

---

## 4. 角色

沿用 Mantle 的职责分离：

| 角色 | 持有者 | 能做什么 | 对应 Mantle |
| --- | --- | --- | --- |
| Admin | Squads 多签 | 授予 / 撤销角色、登记 mint、修改配置；**不能做任何运营操作** | `DEFAULT_ADMIN_ROLE` |
| `MULTIPLIER_SCHEDULER` | 调度 KMS | 调度 multiplier | `MULTIPLIER_SCHEDULER_ROLE` |
| `PAUSER` | 运营 EOA / KMS | 暂停 | `PAUSE_ROLE` |
| `UNPAUSER` | 多签 | 恢复 | `UNPAUSE_ROLE` |
| `FREEZER` | 后端 KMS | 冻结账户（求快） | `ComplianceRegistry` OPS |
| `UNFREEZER` | 多签 | 解冻账户（求稳） | — |
| `CLAWBACK` | 多签 | 强制划转（Permanent Delegate） | — |
| `METADATA_OPS` | 运营 | 更新名称、代码、ISIN | `ScaledToken` OPS |

**沿用的防护规则：**
- 禁止自授权：Admin 不能把角色授予自己。
- 运营指令拒绝 Admin 签名，即使 Admin 也持有该角色。
- Admin 变更分两步：`propose_admin` → `accept_admin`。
- 角色成员可以自行放弃角色；Admin 不能放弃。

---

## 5. 指令

### 5.1 管理类

| 指令 | 签名人 | 校验 | 动作 |
| --- | --- | --- | --- |
| `initialize(admin, hook_authority)` | 程序 upgrade authority | 只能执行一次；签名人必须是程序的 upgrade authority，防止部署后被抢先初始化 | 创建 `Config` |
| `propose_admin(new)` / `accept_admin` | 当前 Admin / 新 Admin | 两步确认 | 更换 Admin |
| `grant_role(role, member)` | Admin | `member != admin` | 创建 `RoleEntry` |
| `revoke_role(role, member)` | Admin | — | 关闭 `RoleEntry` |
| `renounce_role(role)` | 角色成员本人 | — | 关闭自己的 `RoleEntry` |
| `register_mint(mantle_token)` | Admin | 见下 | 创建 `MintState` |

`register_mint` 的 Mint 配置校验（确保代币一上线就处于受控状态）：
- 属于 Token-2022 程序，精度为 9；
- **只能带以下扩展**：Scaled UI Amount、Pausable、Metadata Pointer、Token Metadata、Default Account State、Transfer Hook、Permanent Delegate。其他扩展（如 MintCloseAuthority、转账手续费、机密转账）会引入 Core 控制不了的权限，一律拒绝；
- Scaled UI Amount、Pausable、Metadata Pointer、Token Metadata 的 authority 都是 Authority PDA（Metadata Pointer 若归他人，可被改指向别的元数据）；
- freeze authority 是 Authority PDA；
- Transfer Hook 扩展存在，**未挂程序**，authority 为配置中登记的 Squads 地址；
- Default Account State 扩展存在，状态为「正常」；
- Permanent Delegate 扩展存在，delegate 是 Authority PDA；
- mint authority **不是** Authority PDA（铸造权属于 CCIP pool）。

### 5.2 Multiplier

**`schedule_multiplier(multiplier_1e18: u128, effective_at: i64)`**（方案 B）

| 项 | 内容 |
| --- | --- |
| 签名人 | `MULTIPLIER_SCHEDULER`（非 Admin） |
| 校验 | `1e9 ≤ multiplier_1e18 ≤ 1e27`；`now + min_notice ≤ effective_at ≤ now + max_horizon` |
| 换算 | `multiplier_f64 = multiplier_1e18 / 1e18`（链下调度时限制最多 15 位有效数字） |
| 动作 | CPI `UpdateMultiplier(multiplier_f64, effective_at)`，由 Authority PDA 签名 |
| 事件 | `MultiplierScheduled { mint, multiplier_1e18, effective_at }` |

参数直接沿用 Mantle `setUIMultiplier` 的单位（1e18 定点 + Unix 秒），两边下发同一组值。

一致性由运营流程和对账保证：运营在 Mantle 与 Solana 下发同一组参数，对账服务比对两链状态（不在本次范围）。方案 A（CCIP 消息同步）本次不实现。

### 5.3 暂停

| 指令 | 签名人 | 动作 |
| --- | --- | --- |
| `pause(mint)` | `PAUSER` | CPI Pausable `pause` |
| `resume(mint)` | `UNPAUSER` | CPI Pausable `resume` |
| `pause_all` | `PAUSER` | 对 remaining accounts 中所有已登记的 mint 逐个暂停；单笔交易最多约 12 个 mint（每个 mint 占 64 字节），脚本按 8 个一批发送 |

### 5.4 合规

| 指令 | 签名人 | 动作 |
| --- | --- | --- |
| `freeze(mint, token_accounts…)` | `FREEZER` | 校验每个账户属于该已登记 mint，批量 CPI `FreezeAccount`；已冻结的跳过，便于后端重发。单笔最多约 23 个账户，脚本按 20 个一批（实测 92k CU、1132 字节） |
| `thaw(mint, token_accounts…)` | `UNFREEZER` | 批量 CPI `ThawAccount`；已解冻的跳过 |
| `clawback(source, destination, amount)` | `CLAWBACK` | 在同一条指令里：解冻 source → 以 Permanent Delegate 身份 `transfer_checked` 到 destination → 重新冻结 source |

`clawback` 需要先解冻，是因为冻结账户即使由 Permanent Delegate 发起也转不出（已实测：直接划转报 `AccountFrozen`；同一笔交易里「解冻 → 划转 → 重新冻结」成功）。destination 应为托管账户。

### 5.5 元数据

| 指令 | 签名人 | 动作 |
| --- | --- | --- |
| `update_metadata(field, value)` | `METADATA_OPS` | CPI Token Metadata `update_field`（name / symbol / ISIN 等）；值变长时，客户端需在同一笔交易里先给 mint 补足租金 |

### 5.6 事件

每条运营指令都 `emit!` 事件（`RoleGranted`、`MultiplierScheduled`、`Paused`、`Resumed`、`Frozen`、`Thawed`、`ClawedBack`、`MetadataUpdated` 等），供后端索引和审计。

---

## 6. 发币与配置流程（脚本）

每上一个股票执行一次，顺序不能乱：

```
1. 创建 Mint 账户，初始化扩展：
     Scaled UI Amount（authority = Authority PDA，初始 multiplier = Mantle 当前值）
     Pausable（authority = Authority PDA）
     Metadata Pointer（指向自身）
     Default Account State（正常）
     Transfer Hook（authority = Squads，program = 无）
     Permanent Delegate（= Authority PDA）
2. InitializeMint2：精度 9；mint authority = 部署者（临时）；freeze authority = Authority PDA
3. 初始化 Token Metadata（update authority 先为部署者）→ 写入 ISIN 等附加字段
     → update authority 移交给 Authority PDA
4. Core.register_mint(mantle_token)
5. CCIP：用部署者（当前 mint authority）自助注册 → Squads 接受 token admin
     → 初始化 BurnMint pool → 配置 Mantle 远端链与限流
6. 把 mint authority 移交给 CCIP pool signer PDA
```

**为什么第 5 步必须在第 6 步之前：** CCIP 自助注册需要 mint authority 签名，移交给 PDA 之后就签不了了。

**初始 multiplier：** 新 Mint 的初始值必须等于 Mantle 当前的 `uiMultiplier()`。如果 Mantle 上有待生效值，上线后要立即补调度一次。

**为什么元数据先由部署者写：** ISIN 等附加字段只能通过 `update_field` 写入，需要 update authority 签名。先由部署者写完再移交给 Core，就不需要为上线专门走一次 `METADATA_OPS`。

**脚本对应关系（`solana/scripts/`）：**

| 步骤 | 脚本 |
| --- | --- |
| 部署与初始化 Core（一次性） | 用部署者作为 upgrade authority 部署 → `init-core.ts`（upgrade authority 签名）→ 将 upgrade authority 移交 Squads + Timelock |
| 授予角色 | `grant-role.ts` / `revoke-role.ts` |
| 第 1–4 步 | `create-mint.ts` |
| 补调度待生效的 multiplier | `schedule-multiplier.ts` |
| 第 5 步 CCIP 注册 | 按 Chainlink 自助流程操作，未脚本化（等 CCIP 就绪后在 devnet 验证） |
| 第 6 步 | `handoff-mint-authority.ts`（默认只演练，`--yes` 才执行） |
| 检查结果 | `show-mint.ts` |

**Admin 操作与 Squads：** 需要 Admin 签名的脚本（`grant-role`、`revoke-role`、`create-mint` 中的 `register_mint`）有两种模式：传 keypair 文件时直接签名发送（devnet / 本地）；传 Squads 地址时只打印指令，供提交 Squads 提案。打印模式下付款人也是 vault 本身，因为 Squads 提案只能由 vault 签名，不能夹带本地签名人。

### 6.1 运营脚本

上线后的日常操作，后端服务可直接参考其调用方式：

| 操作 | 脚本 | 说明 |
| --- | --- | --- |
| 暂停 / 恢复 | `pause.ts`（`--resume`） | `PAUSER` / `UNPAUSER` |
| 全局紧急暂停 | `pause-all.ts`（`--dry-run`） | 从链上找出所有已登记的 mint，8 个一批调用 `pause_all`；RPC 不支持 `getProgramAccounts` 时用 `--mints` 显式传入 |
| 拉黑 / 解除 | `freeze.ts`（`--thaw`） | `--owner <钱包>` 会通过 RPC 找出该钱包在此 mint 下的所有余额账户（含非 ATA），每批 20 个发送，即后端拉黑时的流程 |
| 强制划转 | `clawback.ts` | 划到托管账户，源账户最终保持冻结 |
| 更新元数据 | `update-metadata.ts` | 字段变长时先给 mint 补足租金，再调用 Core |
| 查看账户 | `show-account.ts` | 余额与冻结状态 |
| 测试铸币 | `dev-mint-to.ts` | 仅限本地 / devnet，在交出铸造权之前使用 |

---

## 7. 目录结构

```
solana/
  Anchor.toml / Cargo.toml / rust-toolchain.toml   工具链：Anchor 1.2.2、Agave 4.4.0、Rust 1.97.1
  programs/mstocks-core/
    src/
      lib.rs              指令入口
      state.rs            Config / RoleEntry / MintState、角色定义、常量
      errors.rs
      events.rs
      token2022.rs        CPI 封装（UpdateMultiplier / Pause / Freeze / Transfer / Metadata）
      instructions/       admin / register_mint / multiplier / pause / compliance / metadata
    tests/core.rs         LiteSVM 集成测试（加载主网版 Token-2022）
  scripts/                发币、配置与运营脚本（TypeScript，@solana/kit；Core 指令按 IDL 构造）
  tests/fixtures/         主网版 Token-2022 二进制（脚本拉取，不入库）
  README.md               构建、测试、脚本用法
```

放在本仓库 `solana/` 子目录下，与 EVM 代码隔离，各自独立构建。

---

## 8. 测试计划

**Rust 集成测试（`cargo test -p mstocks-core`，19 个，全部通过）：**

| 类别 | 覆盖内容 | 状态 |
| --- | --- | --- |
| 初始化 | 只有 upgrade authority 能初始化，且只能一次 | ✅ |
| 角色 | 授予 / 撤销 / 放弃后失效；自授权被拒；持有角色的地址成为 Admin 后被拒；Admin 两步变更 | ✅ |
| `register_mint` | 合规配置通过；精度、冻结权、Hook 程序、Hook 管理权、铸造权、Metadata Pointer 管理权、多余扩展七类错误配置被拒；不能重复登记 | ✅ |
| multiplier | 范围上下界、通知期、过去时间、最远生效时间；无角色被拒；覆盖未生效值；到点后 UI 数量正确 | ✅ |
| 暂停 | 暂停后转账、铸造被拒；暂停与恢复角色分离；批量暂停；批量暂停参数不成对被拒 | ✅ |
| 合规 | 批量冻结（重复发送不报错）；冻结后不能转出、不能收币、不能收 CCIP 铸币；冻结员不能解冻；其他 mint 的账户被拒；clawback（源账户冻结或未冻结，最终都冻结） | ✅ |
| 元数据 | 更新名称 | ✅ |
| 兼容性 | 休眠 Hook 下 4 账户转账成功（模拟 CCIP Router） | ✅ |
| 交易限制 | 冻结 20 个账户、暂停 8 个 mint 都在 200k CU 和 1232 字节以内 | ✅ |

**本地端到端（`npm run local-e2e`）：** 在本地验证节点上依次运行全部脚本：初始化 → 授予角色 → 创建并登记 mint → 调度 multiplier → 铸币 → 按钱包拉黑 → 强制划转 → 解冻 → 暂停 / 恢复 → 全局暂停 → 更新元数据（含新增字段）→ 撤销角色 → 交出铸造权演练。全部通过。

**devnet 冒烟测试（`scripts/devnet-smoke.sh`）：** Core 已部署到 devnet（`3jBxe42f83ruvVZsoCQdgMtGc6nSEGGpkia2Egm6tbwd`，链上字节与本地构建一致）。在 devnet 上跑通：初始化 → 授予角色 → 创建并登记测试 mint（`7bopkv9QKKHNiHKbphGrDKJWr5V6tW3iz63NW9EQQLeG`）→ 调度 multiplier（1.5×）→ 铸币 → 按钱包拉黑 → 强制划转 → 解冻 → 全局暂停 / 恢复 → 新增元数据字段。最终链上配置与 §6 逐项一致。

**未覆盖：** 真实 CCIP 环境下的注册、跨链铸币与销毁（等 CCIP 就绪后在 devnet 验证）。

---

## 9. 安全要点

- 每个账户都校验 owner 和 PDA seeds：Token-2022 程序 ID、`MintState` 是否属于该 mint、token account 的 mint 是否已登记。
- Authority PDA 只在 Core 内部签名，不暴露通用 CPI 入口。
- multiplier 换算：u128 → f64 的精度损失在链下调度阶段控制（最多 15 位有效数字）。
- Core 的 upgrade authority 交给 Squads 多签 + Timelock。`initialize` 要求 upgrade authority 签名，所以顺序是：部署者部署 → `init-core` → 移交 upgrade authority。
- `register_mint` 使用扩展白名单：mint 上任何 Core 不掌控的扩展都会被拒绝，避免留下后门权限。
- 上线前做独立的 Solana 审计。

---

## 10. 评审决策

| # | 事项 | 决策 |
| --- | --- | --- |
| 1 | multiplier 同步方案 | 方案 B：两条链各自调度，CCIP 只负责代币跨链 |
| 2 | Permanent Delegate | 开启，delegate = Authority PDA；实现 `clawback` |
| 3 | Transfer Hook | 休眠（不挂程序），authority 由 Squads 多签直接持有 |
| 4 | 代码位置 | 本仓库 `solana/` 子目录 |
| 5 | 工具链 | 升级到 Agave + Anchor 1.x |
| 6 | 角色密钥 | 后端 KMS 支持 Ed25519，各运营角色使用 KMS 密钥 |
