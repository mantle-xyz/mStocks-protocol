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

| Role                                      | Authorized actions                                                                              | Held by                                   |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------- |
| `DEFAULT_ADMIN_ROLE`                      | Only grant / revoke roles + change config (`updateName` / `setMintAllowed`, etc.); **cannot perform any operational action** | Team multisig               |
| `ISSUER_ROLE` (ScaledToken)               | mint / burn. **Must be a contract** (EOAs are rejected)                                          | `TokenIssuer` or another audited issuer contract |
| `MULTIPLIER_SCHEDULER_ROLE` (ScaledToken) | Schedule `setUIMultiplier` (splits / reverse splits / dividends)                                 | Ops EOA / KMS                            |
| `OPS_ROLE` (ComplianceRegistry)           | Manage blocklist + sanctions                                                                     | Compliance EOA / KMS                     |
| `OPS_ROLE` (PauseRegistry)                | pause / unpause (single token + global)                                                          | Ops EOA / KMS                            |
| `OPS_ROLE` (TokenIssuer)                  | mint / burn / transfer through the issuer                                                        | Ops EOA / KMS                            |

Three guards are enforced at every role-granting point:

- **Self-grant guard**: every contract overrides `grantRole`, so an admin cannot grant a role to itself.
- **ISSUER_ROLE must be a contract**: `ScaledToken._grantRole` checks `account.code.length > 0`; EOAs are rejected on both the init and grantRole paths.
- **Admin never touches operations**: `_requireIssuer` / `_requireMultiplierScheduler` / `_requireOps` all reject the admin.

## Prerequisites

- Foundry (≥ 2024.10; use `foundryup` for the latest)
- Solc `0.8.30` (pinned in `foundry.toml`; no manual install needed)

## Build

```bash
forge build
```

`foundry.toml` enables: `via_ir = true`, `evm_version = "cancun"`, optimizer at 200 runs.

## Test

```bash
forge test          # full suite, completes in seconds
forge test -vv      # print per-test pass/fail
forge test --gas-report
```

Run a single suite:

```bash
forge test --match-path test/ScaledToken.t.sol
forge test --match-path test/TokenIssuer.t.sol
```

## Deploy

Deployment is driven by `script/Deploy.s.sol` with parameters from `config.toml` (zero addresses fall back to the broadcaster). Entry points:

| `--sig`                          | Description                                                            |
| -------------------------------- | ---------------------------------------------------------------------- |
| `run()` (default)                | Full stack: ComplianceRegistry → PauseRegistry → Factory → (optional) initial token |
| `deployCompliance()`             | Deploy ComplianceRegistry only                                         |
| `deployPauseManager()`           | Deploy PauseRegistry only                                              |
| `deployFactory(address,address)` | ScaledTokenFactory(compliance, pauseRegistry)                          |
| `deployToken(address)`           | Deploy a token via an existing factory                                 |
| `deployTokenIssuer()`            | ERC1967-proxied TokenIssuer                                            |

```bash
export RPC=https://rpc.sepolia.mantle.xyz
export PRIVATE_KEY=0xYourDeployerPk

# full stack
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast -vvv

# deploy TokenIssuer on its own
forge script script/Deploy.s.sol:Deploy --sig "deployTokenIssuer()" \
  --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast
```

For explorer verification, append: `--verify --etherscan-api-key $VERIFY_API_KEY`.

See `config.toml` for a full example; common fields:

```toml
admin      = "0x..."           # multisig; zero falls back to the broadcaster
proxyAdmin = "0x..."           # beacon owner (can upgrade the implementation)

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
identifier = "US0378331005"    # passed to ScaledToken.assetCode
admin = "0x..."
issuers = []                   # must be contract addresses
multiplierSchedulers = ["0x..."]
```

## Smoke tests (on-chain end-to-end)

Once deployed on-chain, run `script/Smoke.s.sol` to exercise the full mint / burn / transfer / pause / compliance / multiplier / issuer-guard flow. The ops and user EOAs are derived deterministically via `vm.createWallet(label)` (private key = keccak256 of the label, publicly derivable).

> ⚠️ **For throwaway / testnet deployments only — never run against a production or value-bearing deployment.** Because the ops / user wallet private keys are publicly derivable, `runAll` revokes every role granted to those wallets via `teardown` before finishing; if you run an individual `test*` entry point, call `teardown(address)` afterwards so no derivable-key privileged address is left behind.

```bash
# cleanup after running individual tests (revoke ops/user roles)
forge script script/Smoke.s.sol:Smoke --sig "teardown(address)" $TOKEN \
  --rpc-url $RPC --private-key $ADMIN_PK --broadcast
```

```bash
export RPC=https://rpc.sepolia.mantle.xyz
export ADMIN_PK=0x...
export TOKEN=0xDeployedScaledTokenProxy
# optional: reuse an existing issuer
# export SMOKE_TOKEN_ISSUER=0xIssuerProxy

# read-only inspection
forge script script/Smoke.s.sol:Smoke --sig "testInfo(address)" $TOKEN --rpc-url $RPC

# full end-to-end
forge script script/Smoke.s.sol:Smoke --sig "runAll(address)" $TOKEN \
  --rpc-url $RPC --private-key $ADMIN_PK --broadcast -vvv
```

Optional tuning: `SMOKE_OPS_LABEL` / `SMOKE_USER_LABEL` / `SMOKE_USER_GAS_THRESHOLD` / `SMOKE_USER_GAS_TARGET` / `SMOKE_MULTIPLIER_OFFSET`.

## UI Multiplier one-off scheduling (splits / reverse splits / dividends)

```bash
# relative delay (seconds)
forge script script/SetUIMultiplier.s.sol \
  --sig "run(address,uint256,uint256)" \
  <token> <newMultiplier> <delaySeconds> \
  --rpc-url $RPC --private-key $SCHEDULER_PK --broadcast

# absolute timestamp
forge script script/SetUIMultiplier.s.sol \
  --sig "runAt(address,uint256,uint256)" \
  <token> <newMultiplier> <effectiveAt> \
  --rpc-url $RPC --private-key $SCHEDULER_PK --broadcast
```

Multiplier is fixed-point: `2e18` = 2-for-1 split, `5e17` = 1-for-2 reverse. On-chain checks: `1e9 ≤ mul ≤ 1e27`, `effectiveAt ∈ (now, now + 365 days]`.

## EIPs / standards used

- ERC-20 / ERC-165
- EIP-712 typed-data + EIP-2612 permit (`ERC20PermitUpgradeable`)
- EIP-5267 `eip712Domain()` domain introspection
- **EIP-8056 Scaled UI Amount extension** (core of splits / reverse splits / dividends)
- ERC-7201 namespaced storage (built into each OZ v5 module)
- EIP-1967 proxy storage slots (BeaconProxy + UpgradeableBeacon + ERC1967Proxy)

## License

BUSL-1.1 (the vendored `src/ERC8056/` portion is MIT).
