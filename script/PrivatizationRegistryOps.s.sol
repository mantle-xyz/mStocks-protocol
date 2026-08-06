// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PrivatizationRegistry} from "../src/privatization/PrivatizationRegistry.sol";
import {ScaledToken} from "../src/scaledToken/ScaledToken.sol";

/// @notice Deploy + operate the upgradeable PrivatizationRegistry (docs/corporate-actions-td.md
///         §4, privatization-runbook.md §2). Deployed behind a TransparentUpgradeableProxy, like
///         TokenIssuer. Each entrypoint is broadcast by the appropriate role — run them in order.
///
///         1) deploy         — deployer (proxyAdmin owns upgrades; admin = DEFAULT_ADMIN_ROLE)
///         2) wire           — OLD token admin (freeze supply + grant registry ISSUER_ROLE)
///         3) createProgram  — registry admin (DEFAULT_ADMIN_ROLE)
///         4) fund           — OPS (holds reward tokens)
///         5) sweep          — registry admin, after the program deadline
contract PrivatizationRegistryOps is Script {
    /// @notice Step 1 — deploy behind a TransparentUpgradeableProxy. `proxyAdmin` owns the
    ///         auto-created ProxyAdmin (sole upgrade authority); `admin` gets DEFAULT_ADMIN_ROLE.
    function deploy(address proxyAdmin, address admin) external returns (address registry) {
        require(proxyAdmin != address(0) && admin != address(0), "zero addr");
        vm.startBroadcast();
        PrivatizationRegistry impl = new PrivatizationRegistry();
        bytes memory initData = abi.encodeWithSelector(PrivatizationRegistry.initialize.selector, admin);
        registry = address(new TransparentUpgradeableProxy(address(impl), proxyAdmin, initData));
        vm.stopBroadcast();
        console.log("PrivatizationRegistry impl: ", address(impl));
        console.log("PrivatizationRegistry proxy:", registry);
        console.log("proxyAdmin (upgrade auth):  ", proxyAdmin);
        console.log("admin (DEFAULT_ADMIN_ROLE): ", admin);
    }

    /// @notice Step 2 — freeze the old token's supply and grant the registry BURN_ROLE on it
    ///         (burn-only: it can burn surrendered balances but never mint). Broadcaster must be
    ///         the OLD token admin.
    function wire(address oldToken, address registry) external {
        bytes32 burnRole = ScaledToken(oldToken).BURN_ROLE();
        vm.startBroadcast();
        ScaledToken(oldToken).grantRole(burnRole, registry);
        ScaledToken(oldToken).setMintAllowed(false);
        vm.stopBroadcast();
        console.log("Granted BURN_ROLE to registry + froze old supply:", oldToken);
    }

    /// @notice Step 3 — register a delisting program from parallel reward-leg arrays
    ///         (`tokens[i]` at `rates[i]`, rate = reward raw per 1e18 old raw). Broadcaster must
    ///         hold DEFAULT_ADMIN_ROLE on the registry.
    function createProgram(
        address registry,
        address oldToken,
        address[] calldata tokens,
        uint256[] calldata rates,
        uint64 deadline
    ) external returns (uint256 programId) {
        require(tokens.length == rates.length && tokens.length > 0, "legs mismatch");
        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            legs[i] = PrivatizationRegistry.Leg({token: tokens[i], rate: rates[i]});
        }
        vm.startBroadcast();
        programId = PrivatizationRegistry(registry).createProgram(oldToken, legs, deadline);
        vm.stopBroadcast();
        console.log("createProgram id:", programId);
        console.log("  oldToken:", oldToken);
        console.log("  legs:", tokens.length);
        console.log("  deadline:", deadline);
    }

    /// @notice Step 4 — fund + reserve a reward token for a program. Broadcaster must hold
    ///         OPS_ROLE on the registry and own `amount` of `token`; this approves + funds.
    function fund(address registry, uint256 programId, address token, uint256 amount) external {
        vm.startBroadcast();
        IERC20(token).approve(registry, amount);
        PrivatizationRegistry(registry).fund(programId, token, amount);
        vm.stopBroadcast();
        console.log("Funded program", programId);
        console.log("  token/amount:", token, amount);
        console.log("  reserved now:", PrivatizationRegistry(registry).reserved(programId, token));
    }

    /// @notice Step 5 — after the program deadline, sweep unclaimed reserve to custody.
    ///         Broadcaster must hold DEFAULT_ADMIN_ROLE.
    function sweep(address registry, uint256 programId, address to) external {
        vm.startBroadcast();
        PrivatizationRegistry(registry).sweepUnclaimed(programId, to);
        vm.stopBroadcast();
        console.log("Swept program", programId);
        console.log("  to:", to);
    }
}
