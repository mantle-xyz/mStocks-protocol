# mStocks Protocol

Tokenized-securities smart-contract suite: an EIP-8056 Scaled UI Amount ERC-20 with
compliance / pause hooks, deployed behind a shared upgradeable beacon, plus a custodial
issuer contract that routes mint / burn through a whitelist. Built with Foundry, OpenZeppelin v5.6.1.

Certificates issued under section 58(2)(b) of the ADGM Financial Services and Markets Regulations 2015.

## Contract layout

```
src/
├── scaledToken/
│   ├── ScaledToken.sol          — ERC-20 + EIP-8056 UI multiplier + EIP-2612 permit
│   └── ScaledTokenFactory.sol   — BeaconProxy factory; one implementation, many tokens
├── complianceRegistry/
│   ├── ComplianceRegistry.sol   — per-token blocklist + global sanctions (O(1) reset)
│   ├── ComplianceGuardUpgradeable.sol
│   └── IComplianceRegistry.sol
├── pauseRegistry/
│   ├── PauseRegistry.sol        — per-token + global pause
│   ├── PauseGuardUpgradeable.sol
│   └── IPauseRegistry.sol
├── tokenIssuer/
│   ├── TokenIssuer.sol          — custodial mint/burn router (ERC1967Proxy)
│   └── IMintAndBurnable.sol
└── ERC8056/                     — vendored EIP-8056 reference base (MIT)
```

## Role model — strict separation of duties

| Role                                      | 授权动作                                                                                        | 授权方                                 |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------- | -------------------------------------- |
| `DEFAULT_ADMIN_ROLE`                      | 仅 grant / revoke role + 改配置（`updateName` / `setMintAllowed` 等），**不能执行任何运维操作** | 团队 multisig                          |
| `ISSUER_ROLE` (ScaledToken)               | mint / burn。**必须是合约**（EOA 会被拒）                                                       | `TokenIssuer` 或其它经审计的发行方合约 |
| `MULTIPLIER_SCHEDULER_ROLE` (ScaledToken) | 调度 `setUIMultiplier`（拆股 / 合股 / 分红）                                                    | 运维 EOA / KMS                         |
| `OPS_ROLE` (ComplianceRegistry)           | 管理 blocklist + sanctions                                                                      | 合规 EOA / KMS                         |
| `OPS_ROLE` (PauseRegistry)                | pause / unpause（单 token + 全局）                                                              | 运维 EOA / KMS                         |
| `OPS_ROLE` (TokenIssuer)                  | 通过 issuer 调 `mint` / `burn` / `transfer`                                                     | 运维 EOA / KMS                         |

三条护栏在所有 role 授予点强制执行：

- **Self-grant guard**：任何合约都 override 了 `grantRole`，admin 无法给自己授权
- **ISSUER_ROLE must be contract**：`ScaledToken._grantRole` 校验 `account.code.length > 0`，EOA 在 init 与 grantRole 两条路径都会被拒
- **Admin 不接触运维**：`_requireIssuer` / `_requireMultiplierScheduler` / `_requireOps` 全部拒绝 admin

## Prerequisites

- Foundry（≥ 2024.10；用 `foundryup` 拉最新）
- Solc `0.8.30`（`foundry.toml` 里指定，无需手动装）

## Build

```bash
forge build
```

`foundry.toml` 已启用：`via_ir = true`、`evm_version = "cancun"`、200 runs optimizer。

## Test

```bash
forge test          # 96 用例，秒级完成
forge test -vv      # 打印 pass/fail 明细
forge test --gas-report
```

只跑单个 suite：

```bash
forge test --match-path test/ScaledToken.t.sol
forge test --match-path test/TokenIssuer.t.sol
```

## Deploy

部署由 `script/Deploy.s.sol` 驱动、`config.toml` 提供参数（零地址回落到 broadcaster）。入口：

| `--sig`                          | 说明                                                                   |
| -------------------------------- | ---------------------------------------------------------------------- |
| `run()`（默认）                  | 全栈：ComplianceRegistry → PauseRegistry → Factory →（可选）初始 token |
| `deployCompliance()`             | 只部 ComplianceRegistry                                                |
| `deployPauseManager()`           | 只部 PauseRegistry                                                     |
| `deployFactory(address,address)` | ScaledTokenFactory(compliance, pauseRegistry)                          |
| `deployToken(address)`           | 通过既有 factory 部一个 token                                          |
| `deployTokenIssuer()`            | ERC1967-proxied TokenIssuer                                            |

```bash
export RPC=https://rpc.sepolia.mantle.xyz
export PRIVATE_KEY=0xYourDeployerPk

# 全栈
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast -vvv

# 单独部 TokenIssuer
forge script script/Deploy.s.sol:Deploy --sig "deployTokenIssuer()" \
  --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast
```

带浏览器验证：`--verify --etherscan-api-key $VERIFY_API_KEY`。

配置文件示例见 `config.toml`；常用字段：

```toml
admin      = "0x..."           # multisig；留 0 回落到 broadcaster
proxyAdmin = "0x..."           # beacon owner（可升级 implementation）

[compliance]
opsRole = ["0x..."]

[pauseManager]
opsRole = ["0x..."]

[tokenIssuer]
opsRole = ["0x..."]
approvedRecipients = ["0x..."]

[token]
name = "Apple Inc."
symbol = "AAPL"
identifier = "US0378331005"    # 传给 ScaledToken.assetCode
admin = "0x..."
issuers = []                   # 必须是合约地址
multiplierSchedulers = ["0x..."]
```

## Smoke tests (链上端到端)

已部署到链上之后，跑 `script/Smoke.s.sol` 走一遍 mint / burn / transfer / pause / compliance / multiplier / issuer-guard 全流程。ops EOA 与 user EOA 由 `vm.createWallet(label)` 确定性派生。

```bash
export RPC=https://rpc.sepolia.mantle.xyz
export ADMIN_PK=0x...
export TOKEN=0xDeployedScaledTokenProxy
# 可选：复用已有 issuer
# export SMOKE_TOKEN_ISSUER=0xIssuerProxy

# 只读巡检
forge script script/Smoke.s.sol:Smoke --sig "testInfo(address)" $TOKEN --rpc-url $RPC

# 全量端到端
forge script script/Smoke.s.sol:Smoke --sig "runAll(address)" $TOKEN \
  --rpc-url $RPC --private-key $ADMIN_PK --broadcast -vvv
```

可选调参：`SMOKE_OPS_LABEL` / `SMOKE_USER_LABEL` / `SMOKE_USER_GAS_THRESHOLD` / `SMOKE_USER_GAS_TARGET` / `SMOKE_MULTIPLIER_OFFSET`。

## UI Multiplier 一次性调度（拆股 / 合股 / 分红）

```bash
# 相对延迟（秒）
forge script script/SetUIMultiplier.s.sol \
  --sig "run(address,uint256,uint256)" \
  <token> <newMultiplier> <delaySeconds> \
  --rpc-url $RPC --private-key $SCHEDULER_PK --broadcast

# 绝对时间戳
forge script script/SetUIMultiplier.s.sol \
  --sig "runAt(address,uint256,uint256)" \
  <token> <newMultiplier> <effectiveAt> \
  --rpc-url $RPC --private-key $SCHEDULER_PK --broadcast
```

Multiplier 定点小数：`2e18` = 2-for-1 split，`5e17` = 1-for-2 reverse。链上校验：`1e9 ≤ mul ≤ 1e27`、`effectiveAt ∈ (now, now + 365 days]`。

## 使用的 EIP / 标准

- ERC-20 / ERC-165
- EIP-712 typed-data + EIP-2612 permit（`ERC20PermitUpgradeable`）
- EIP-5267 `eip712Domain()` 域自省
- **EIP-8056 Scaled UI Amount extension**（拆股 / 合股 / 分红核心）
- ERC-7201 namespaced storage（OZ v5 各 module 自带）
- EIP-1967 proxy storage slots（BeaconProxy + UpgradeableBeacon + ERC1967Proxy）

## License

BUSL-1.1（`src/ERC8056/` vendored 部分为 MIT）
